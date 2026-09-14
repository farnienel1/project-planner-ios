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
    /// True while Home is running its post-quiet lite warm — blocks roster full-sync writes.
    @MainActor static var isHomeWarningsWarmInFlight = false

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
        force: Bool = false,
        manualUserInitiated: Bool = false
    ) async -> Bool {
        guard userStore.hasAdminAccess() else { return false }

        if isWarningsSheetVisible && !manualUserInitiated {
            print("🔥🔥🔥 DEBUG: Warnings refresh skipped (Warnings sheet visible)")
            return false
        }
        if isWeeklyReportVisible && !manualUserInitiated {
            print("🔥🔥🔥 DEBUG: Warnings refresh skipped (Weekly Report visible)")
            return false
        }

        // Launch quiet blocks automatic scans. Explicit user Refresh may proceed.
        if let quietUntil = firebaseBackend.launchQuietUntil, Date() < quietUntil, !manualUserInitiated {
            print("🔥🔥🔥 DEBUG: Warnings refresh skipped (launch quiet period)")
            return false
        }

        // Avoid scanning while stores/bootstrap are mid-load (publishes false empty results).
        // Manual Refresh (and settings Save) retries briefly — Firestore saves often race a short reload.
        if manualUserInitiated {
            for attempt in 0..<8 {
                let bootstrapping = firebaseBackend.isBootstrappingOrgDataLoad
                let storesBusy = bookingStore.isLoading || operativeStore.isLoading || projectStore.isLoading
                if !bootstrapping && firebaseBackend.hasBootstrappedOrgDataLoad && !storesBusy {
                    break
                }
                print("🔥🔥🔥 DEBUG: Warnings refresh waiting (attempt \(attempt + 1)/8 bootstrapping=\(bootstrapping) storesBusy=\(storesBusy))")
                try? await Task.sleep(nanoseconds: 450_000_000)
            }
        }

        if firebaseBackend.isBootstrappingOrgDataLoad {
            print("🔥🔥🔥 DEBUG: Warnings refresh skipped (org bootstrap in progress)")
            return false
        }
        if !firebaseBackend.hasBootstrappedOrgDataLoad {
            print("🔥🔥🔥 DEBUG: Warnings refresh skipped (org bootstrap not finished)")
            return false
        }
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
        } else if !manualUserInitiated {
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
        let policy = firebaseBackend.currentOrganization?.settings.payrollTimePolicy ?? .default
        let warningDetection = firebaseBackend.currentOrganization?.settings.warningDetection ?? .default
        let invoicingSettings = firebaseBackend.currentOrganization?.settings.invoicing ?? .default
        let activeOperatives = operativeStore.allOperatives.filter(\.isActive)

        // Honor Organisation Warnings detection horizon (days / working week / invoicing period).
        let coverageStart = cal.startOfDay(
            for: warningDetection.coverageStart(from: today, invoicing: invoicingSettings, calendar: cal)
        )
        let coverageEnd = cal.startOfDay(
            for: warningDetection.coverageEnd(from: today, invoicing: invoicingSettings, calendar: cal)
        )
        let dayCount = max(1, (cal.dateComponents([.day], from: coverageStart, to: coverageEnd).day ?? 0) + 1)
        print("🔥🔥🔥 DEBUG: Warnings coverage mode=\(warningDetection.clashLookaheadMode.displayName) days=\(dayCount) \(coverageStart)…\(coverageEnd)")
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

        // Pre-window to the detection horizon before WarningsService snapshot work.
        let liveBookings = bookingStore.bookings.filter {
            let day = cal.startOfDay(for: $0.date)
            return day >= coverageStart && day <= coverageEnd
        }
        let liveManager = managerScheduleStore.managerSiteBookings.filter {
            let day = cal.startOfDay(for: $0.date)
            return day >= coverageStart && day <= coverageEnd
        }
        let liveHolidays = holidayStore.bookings.filter { holiday in
            let start = cal.startOfDay(for: holiday.startDate)
            let end = cal.startOfDay(for: holiday.endDate)
            return end >= coverageStart && start <= coverageEnd
        }
        print("🔥🔥🔥 DEBUG: Warnings helper pre-window \(coverageStart)…\(coverageEnd) bookings=\(liveBookings.count)/\(bookingStore.bookings.count) mgr=\(liveManager.count)/\(managerScheduleStore.managerSiteBookings.count)")

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
            labourCoverageStart: coverageStart,
            labourCoverageEnd: coverageEnd,
            materialOrderCutOffEnabled: appSettings.settings.notifications.materialOrderCutOff,
            materialCutOffOnSaturday: appSettings.settings.notifications.materialCutOffOnSaturday,
            materialCutOffOnSunday: appSettings.settings.notifications.materialCutOffOnSunday,
            projectsWithTomorrowBookings: projectsTomorrow,
            publishToLiveCache: true
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
