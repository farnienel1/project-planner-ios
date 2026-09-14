//
//  WarningsRefreshHelper.swift
//  Project Planner
//

import Foundation

enum WarningsRefreshHelper {
    @MainActor private static var lastRefreshAt: Date?
    @MainActor private static var inFlightTask: Task<Void, Never>?
    private static let minRefreshInterval: TimeInterval = 45

    /// Home must not start a live scan while Weekly Report is open.
    @MainActor static var isWeeklyReportVisible = false
    /// Never start a live scan while the Warnings sheet is presented (jetsam).
    @MainActor static var isWarningsSheetVisible = false

    @MainActor
    @discardableResult
    static func refreshSharedWarnings(
        operativeStore: OperativeStore,
        bookingStore: BookingStore,
        projectStore: ProjectStore,
        userStore: UserStore,
        managerScheduleStore: ManagerScheduleStore,
        holidayStore: HolidayStore,
        firebaseBackend: FirebaseBackend,
        appSettings: AppSettingsStore,
        force: Bool = false
    ) async -> Bool {
        guard userStore.hasAdminAccess() else { return false }

        if isWarningsSheetVisible {
            print("🔥🔥🔥 DEBUG: Warnings refresh skipped (Warnings sheet visible)")
            return false
        }
        if isWeeklyReportVisible {
            print("🔥🔥🔥 DEBUG: Warnings refresh skipped (Weekly Report visible)")
            return false
        }

        // Never scan during bootstrap — jetsams Simulator.
        if firebaseBackend.isBootstrappingOrgDataLoad {
            print("🔥🔥🔥 DEBUG: Warnings refresh skipped (org bootstrap in progress)")
            return false
        }
        if !firebaseBackend.hasBootstrappedOrgDataLoad {
            print("🔥🔥🔥 DEBUG: Warnings refresh skipped (org bootstrap not finished)")
            return false
        }

        // Launch quiet blocks *all* scans — including force. Scanning mid-quiet with
        // ~90 bookings jetsams Simulator. Home warms the cache after quiet ends.
        if let quietUntil = firebaseBackend.launchQuietUntil, Date() < quietUntil {
            print("🔥🔥🔥 DEBUG: Warnings refresh skipped (launch quiet period)")
            return false
        }

        // Even force must not scan while bookings are still mid-load — that published
        // false empty live results and made Warnings look broken.
        if bookingStore.isLoading || operativeStore.isLoading || projectStore.isLoading {
            print("🔥🔥🔥 DEBUG: Warnings refresh skipped (stores still loading)")
            return false
        }

        if !force {
            if holidayStore.isLoading {
                return false
            }
            let now = Date()
            if let lastRefreshAt, now.timeIntervalSince(lastRefreshAt) < minRefreshInterval {
                return false
            }
        } else {
            let now = Date()
            if let lastRefreshAt, now.timeIntervalSince(lastRefreshAt) < 8 {
                // Soft coalesce — avoid stacked force scans from dismiss + notification.
                print("🔥🔥🔥 DEBUG: Warnings force coalesced (<8s)")
                return WarningsService.shared.hasCompletedLiveDetection
            }
        }

        if let inFlightTask {
            print("🔥🔥🔥 DEBUG: Warnings refresh awaiting in-flight pass (no second snapshot)")
            await inFlightTask.value
            return true
        }

        let task = Task { @MainActor in
            await performRefresh(
                operativeStore: operativeStore,
                bookingStore: bookingStore,
                projectStore: projectStore,
                userStore: userStore,
                managerScheduleStore: managerScheduleStore,
                holidayStore: holidayStore,
                firebaseBackend: firebaseBackend,
                appSettings: appSettings
            )
        }
        inFlightTask = task
        lastRefreshAt = Date()
        await task.value
        if inFlightTask == task {
            inFlightTask = nil
        }
        return true
    }

    /// Cancel any in-flight Home warnings scan before opening heavy sheets (Weekly Report).
    @MainActor
    static func cancelInFlightRefresh() {
        inFlightTask?.cancel()
        inFlightTask = nil
        WarningsService.shared.cancelInFlightUpdate()
        print("🔥🔥🔥 DEBUG: Warnings refresh in-flight cancelled for sheet open")
    }

    /// Cancel scans and wait briefly so detached snapshot memory can drain before heavy UI.
    @MainActor
    static func prepareForHeavySheet() async {
        isWeeklyReportVisible = true
        cancelInFlightRefresh()
        await Task.yield()
        try? await Task.sleep(nanoseconds: 500_000_000)
        await Task.yield()
        cancelInFlightRefresh()
        try? await Task.sleep(nanoseconds: 700_000_000)
        await Task.yield()
    }

    @MainActor
    private static func performRefresh(
        operativeStore: OperativeStore,
        bookingStore: BookingStore,
        projectStore: ProjectStore,
        userStore: UserStore,
        managerScheduleStore: ManagerScheduleStore,
        holidayStore: HolidayStore,
        firebaseBackend: FirebaseBackend,
        appSettings: AppSettingsStore
    ) async {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let tomorrow = cal.startOfDay(for: cal.date(byAdding: .day, value: 1, to: today) ?? today)
        let tomorrowIds = Set(
            bookingStore.bookings
                .filter {
                    cal.isDate($0.date, inSameDayAs: tomorrow) &&
                        ($0.status == .confirmed || $0.status == .tentative)
                }
                .map(\.projectId)
        )
        let projects = projectStore.projects
        let projectsTomorrow = projects.filter { tomorrowIds.contains($0.id) }
        let policy = firebaseBackend.currentOrganization?.settings.payrollTimePolicy ?? .default
        let warningDetection = firebaseBackend.currentOrganization?.settings.warningDetection ?? .default
        let invoicingSettings = firebaseBackend.currentOrganization?.settings.invoicing ?? .default
        let activeOperatives = operativeStore.allOperatives.filter(\.isActive)

        // Pre-window to the live horizon before crossing into WarningsService so we
        // never hand ~90 bookings + ~70 manager rows into the MainActor snapshot.
        let liveEnd = cal.startOfDay(for: cal.date(byAdding: .day, value: 1, to: today) ?? today)
        let liveBookings = bookingStore.bookings.filter {
            let day = cal.startOfDay(for: $0.date)
            return day >= today && day <= liveEnd
        }
        let liveManager = managerScheduleStore.managerSiteBookings.filter {
            let day = cal.startOfDay(for: $0.date)
            return day >= today && day <= liveEnd
        }
        let liveHolidays = holidayStore.bookings.filter { holiday in
            let start = cal.startOfDay(for: holiday.startDate)
            let end = cal.startOfDay(for: holiday.endDate)
            return end >= today && start <= liveEnd
        }
        print("🔥🔥🔥 DEBUG: Warnings helper pre-window bookings=\(liveBookings.count)/\(bookingStore.bookings.count) mgr=\(liveManager.count)/\(managerScheduleStore.managerSiteBookings.count)")

        await Task.yield()
        try? await Task.sleep(nanoseconds: 250_000_000)
        await Task.yield()
        if Task.isCancelled { return }

        await WarningsService.shared.updateWarningsAsync(
            operatives: activeOperatives,
            bookings: liveBookings,
            projects: projects,
            users: userStore.organizationUsers,
            managerSiteBookings: liveManager,
            holidayBookings: liveHolidays,
            payrollTimePolicy: policy,
            warningDetection: warningDetection,
            invoicingSettings: invoicingSettings,
            materialOrderCutOffEnabled: appSettings.settings.notifications.materialOrderCutOff,
            materialCutOffOnSaturday: appSettings.settings.notifications.materialCutOffOnSaturday,
            materialCutOffOnSunday: appSettings.settings.notifications.materialCutOffOnSunday,
            projectsWithTomorrowBookings: projectsTomorrow
        )
        postWarningsCountDidChange()
    }

    @MainActor
    static func postWarningsCountDidChange() {
        NotificationCenter.default.post(
            name: .warningsDidRecompute,
            object: nil,
            userInfo: ["count": WarningsService.shared.warningCount]
        )
    }
}
