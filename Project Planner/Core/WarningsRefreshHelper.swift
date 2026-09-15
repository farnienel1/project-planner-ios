//
//  WarningsRefreshHelper.swift
//  Project Planner
//

import Foundation

enum WarningsRefreshHelper {
    @MainActor private static var lastRefreshAt: Date?
    @MainActor private static var inFlightTask: Task<Bool, Never>?
    @MainActor private static var inFlightGeneration = 0
    private static let minRefreshInterval: TimeInterval = 45

    /// Last reason a refresh returned false (manual Refresh / settings Save).
    @MainActor static var lastSkipMessage: String?

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
        if manualUserInitiated {
            lastSkipMessage = nil
            // Stale Home/previous scans must not block or swallow an explicit Refresh.
            if inFlightTask != nil {
                print("🔥🔥🔥 DEBUG: Warnings manual refresh cancelling stale in-flight scan")
                cancelInFlightRefresh()
            }
            // Device/TestFlight Firestore is slower than Simulator (~3.6s used to give up too soon).
            for attempt in 0..<60 {
                if readinessSkipMessage(
                    userStore: userStore,
                    bookingStore: bookingStore,
                    operativeStore: operativeStore,
                    projectStore: projectStore,
                    firebaseBackend: firebaseBackend
                ) == nil {
                    break
                }
                print("🔥🔥🔥 DEBUG: Warnings refresh waiting (attempt \(attempt + 1)/60 bootstrapping=\(firebaseBackend.isBootstrappingOrgDataLoad) storesBusy=\(bookingStore.isLoading || operativeStore.isLoading || projectStore.isLoading) profile=\(userStore.isHomeProfileLoading) bookings=\(bookingStore.bookings.count))")
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
        }

        if !userStore.hasAdminAccess() {
            if manualUserInitiated {
                if userStore.isHomeProfileLoading || userStore.currentUser == nil {
                    return skip("Admin profile is still loading. Try again in a few seconds.")
                }
                return skip("You need admin access to refresh warnings.")
            }
            return false
        }

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

        if let busy = readinessSkipMessage(
            userStore: userStore,
            bookingStore: bookingStore,
            operativeStore: operativeStore,
            projectStore: projectStore,
            firebaseBackend: firebaseBackend
        ) {
            if manualUserInitiated {
                return skip(busy)
            }
            print("🔥🔥🔥 DEBUG: Warnings refresh skipped (\(busy))")
            return false
        }

        if !force {
            if holidayStore.isLoading {
                print("🔥🔥🔥 DEBUG: Warnings refresh skipped (holiday store loading)")
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
            return await inFlightTask.value
        }

        inFlightGeneration += 1
        let generation = inFlightGeneration
        let task = Task<Bool, Never> { @MainActor in
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
        let published = await task.value
        if inFlightGeneration == generation {
            inFlightTask = nil
        }
        if !published && lastSkipMessage == nil {
            lastSkipMessage = "Scan did not finish. Keep this screen open and tap Refresh now again."
        }
        return published
    }

    /// Cancel any in-flight Home warnings scan before opening heavy sheets (Weekly Report).
    @MainActor
    static func cancelInFlightRefresh() {
        inFlightGeneration += 1
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
    private static func skip(_ message: String) -> Bool {
        lastSkipMessage = message
        print("🔥🔥🔥 DEBUG: Warnings refresh skipped (\(message))")
        return false
    }

    @MainActor
    private static func readinessSkipMessage(
        userStore: UserStore,
        bookingStore: BookingStore,
        operativeStore: OperativeStore,
        projectStore: ProjectStore,
        firebaseBackend: FirebaseBackend
    ) -> String? {
        if userStore.isHomeProfileLoading || userStore.currentUser == nil {
            return "Admin profile is still loading. Try again in a few seconds."
        }
        if firebaseBackend.isBootstrappingOrgDataLoad {
            return "Organisation data is still loading. Try again in a few seconds."
        }
        if !firebaseBackend.hasBootstrappedOrgDataLoad {
            return "Organisation data has not finished loading. Try again in a few seconds."
        }
        if bookingStore.isLoading || operativeStore.isLoading || projectStore.isLoading {
            return "Bookings are still loading. Try again in a few seconds."
        }
        // Publishing an empty window before the first bookings fetch finishes made
        // Warnings look like a successful all-clear on TestFlight.
        if !bookingStore.hasCompletedInitialLoad && bookingStore.bookings.isEmpty {
            return "Bookings are still loading. Try again in a few seconds."
        }
        return nil
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
    ) async -> Bool {
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
        let projects = projectStore.projects

        await Task.yield()
        try? await Task.sleep(nanoseconds: 250_000_000)
        await Task.yield()
        if Task.isCancelled { return false }

        // Phase 1: today + tomorrow so TestFlight is not stuck on Refresh now while a
        // full-week / invoicing-period scan is still running (those can hang/jetsam).
        let nearPublished = await runScan(
            start: today,
            end: tomorrow,
            activeOperatives: activeOperatives,
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
            materialCutOffOnSunday: appSettings.settings.notifications.materialCutOffOnSunday
        )
        if nearPublished {
            lastSkipMessage = nil
            postWarningsCountDidChange()
        }
        if Task.isCancelled {
            return nearPublished
        }

        let needsFullWindow = coverageStart < today || coverageEnd > tomorrow
        var published = nearPublished
        if needsFullWindow {
            await Task.yield()
            try? await Task.sleep(nanoseconds: 200_000_000)
            if Task.isCancelled { return published }
            print("🔥🔥🔥 DEBUG: Warnings helper starting full coverage pass \(coverageStart)…\(coverageEnd)")
            let fullPublished = await runScan(
                start: coverageStart,
                end: coverageEnd,
                activeOperatives: activeOperatives,
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
                materialCutOffOnSunday: appSettings.settings.notifications.materialCutOffOnSunday
            )
            if fullPublished {
                lastSkipMessage = nil
                postWarningsCountDidChange()
            }
            published = fullPublished || published
        }
        return published
    }

    @MainActor
    private static func runScan(
        start: Date,
        end: Date,
        activeOperatives: [Operative],
        bookings: [Booking],
        projects: [Project],
        users: [AppUser],
        managerSiteBookings: [ManagerSiteBooking],
        holidayBookings: [HolidayBooking],
        payrollTimePolicy: OrgPayrollTimePolicy,
        warningDetection: OrgWarningDetectionSettings,
        invoicingSettings: OrganizationInvoicingSettings,
        materialOrderCutOffEnabled: Bool,
        materialCutOffOnSaturday: Bool,
        materialCutOffOnSunday: Bool
    ) async -> Bool {
        let cal = Calendar.current
        let tomorrow = cal.startOfDay(for: cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: Date())) ?? Date())
        let tomorrowIds = Set(
            bookings
                .filter {
                    cal.isDate($0.date, inSameDayAs: tomorrow) &&
                        ($0.status == .confirmed || $0.status == .tentative)
                }
                .map(\.projectId)
        )
        let projectsTomorrow = projects.filter { tomorrowIds.contains($0.id) }
        let liveBookings = bookings.filter {
            let day = cal.startOfDay(for: $0.date)
            return day >= start && day <= end
        }
        let liveManager = managerSiteBookings.filter {
            let day = cal.startOfDay(for: $0.date)
            return day >= start && day <= end
        }
        let liveHolidays = holidayBookings.filter { holiday in
            let holidayStart = cal.startOfDay(for: holiday.startDate)
            let holidayEnd = cal.startOfDay(for: holiday.endDate)
            return holidayEnd >= start && holidayStart <= end
        }
        print("🔥🔥🔥 DEBUG: Warnings helper pre-window \(start)…\(end) bookings=\(liveBookings.count)/\(bookings.count) mgr=\(liveManager.count)/\(managerSiteBookings.count)")

        return await WarningsService.shared.updateWarningsAsync(
            operatives: activeOperatives,
            bookings: liveBookings,
            projects: projects,
            users: users,
            managerSiteBookings: liveManager,
            holidayBookings: liveHolidays,
            payrollTimePolicy: payrollTimePolicy,
            warningDetection: warningDetection,
            invoicingSettings: invoicingSettings,
            labourCoverageStart: start,
            labourCoverageEnd: end,
            materialOrderCutOffEnabled: materialOrderCutOffEnabled,
            materialCutOffOnSaturday: materialCutOffOnSaturday,
            materialCutOffOnSunday: materialCutOffOnSunday,
            projectsWithTomorrowBookings: projectsTomorrow,
            publishToLiveCache: true
        )
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
