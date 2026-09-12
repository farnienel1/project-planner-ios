//
//  WarningsRefreshHelper.swift
//  Project Planner
//

import Foundation

enum WarningsRefreshHelper {
    @MainActor private static var lastRefreshAt: Date?
    @MainActor private static var inFlightTask: Task<Void, Never>?
    private static let minRefreshInterval: TimeInterval = 45

    /// When true, Home post-quiet / background refreshes must not start (Weekly Report open).
    @MainActor static var isWeeklyReportVisible = false

    @MainActor
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

        if isWeeklyReportVisible {
            print("🔥🔥🔥 DEBUG: Warnings refresh skipped (Weekly Report visible)")
            return false
        }

        // Always skip during bootstrap / launch quiet — even when `force` is true.
        // Opening Warnings used to pass force:true and bypass these guards, which
        // jetsams the Simulator right after Home bootstrap finishes.
        if firebaseBackend.isBootstrappingOrgDataLoad {
            print("🔥🔥🔥 DEBUG: Warnings refresh skipped (org bootstrap in progress)")
            return false
        }
        if let quietUntil = firebaseBackend.launchQuietUntil, Date() < quietUntil {
            print("🔥🔥🔥 DEBUG: Warnings refresh skipped (launch quiet period)")
            return false
        }
        if !firebaseBackend.hasBootstrappedOrgDataLoad {
            print("🔥🔥🔥 DEBUG: Warnings refresh skipped (org bootstrap not finished)")
            return false
        }

        if !force {
            if bookingStore.isLoading || operativeStore.isLoading || holidayStore.isLoading || projectStore.isLoading {
                return false
            }
            let now = Date()
            if let lastRefreshAt, now.timeIntervalSince(lastRefreshAt) < minRefreshInterval {
                return false
            }
        }

        if let inFlightTask {
            // Always join the in-flight pass — never start a second org scan (jetsams Simulator).
            print("🔥🔥🔥 DEBUG: Warnings refresh awaiting in-flight pass (no second snapshot)")
            await inFlightTask.value
            return !inFlightTask.isCancelled
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
        let cancelled = task.isCancelled
        if inFlightTask == task {
            inFlightTask = nil
        }
        if cancelled {
            print("🔥🔥🔥 DEBUG: Warnings refresh finished cancelled — not treating as success")
            return false
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
        // Drain cancelled detached snapshot work before constructing report UI.
        try? await Task.sleep(nanoseconds: 900_000_000)
        await Task.yield()
        cancelInFlightRefresh()
        try? await Task.sleep(nanoseconds: 900_000_000)
        await Task.yield()
        cancelInFlightRefresh()
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
        if Task.isCancelled { return }

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

        // Yield so Home can finish painting before the heavy snapshot work.
        await Task.yield()
        if Task.isCancelled { return }

        await WarningsService.shared.updateWarningsAsync(
            operatives: activeOperatives,
            bookings: bookingStore.bookings,
            projects: projects,
            users: userStore.organizationUsers,
            managerSiteBookings: managerScheduleStore.managerSiteBookings,
            holidayBookings: holidayStore.bookings,
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
