//
//  WarningsRefreshHelper.swift
//  Project Planner
//

import Foundation

enum WarningsRefreshHelper {
    @MainActor private static var lastRefreshAt: Date?
    @MainActor private static var inFlightTask: Task<Bool, Never>?
    private static let minRefreshInterval: TimeInterval = 45
    /// Set while Warnings sheet is on screen so Home / background paths avoid heavy work underneath it.
    @MainActor static var isWarningsSheetVisible = false
    /// Set while Weekly Report is on screen — opening it during a warnings recompute jetsams Simulator.
    @MainActor static var isWeeklyReportVisible = false

    @MainActor
    static var isHeavySheetVisible: Bool {
        isWarningsSheetVisible || isWeeklyReportVisible
    }

    /// Cancel any in-flight shared refresh (e.g. before presenting Weekly Report).
    @MainActor
    static func cancelInFlightRefresh() {
        inFlightTask?.cancel()
        inFlightTask = nil
        print("🔥🔥🔥 DEBUG: Warnings refresh in-flight cancelled")
    }

    /// Returns `true` only when `updateWarningsAsync` actually ran and published.
    ///
    /// - Parameters:
    ///   - force: Ignore the min refresh interval.
    ///   - bypassSoftStoreGates: Allow snapshot while holiday / manager-schedule are still
    ///     loading. Hard gates (bootstrap, quiet, bookings/operatives/projects) still apply
    ///     unless `bypassAllStoreGates` is also set.
    ///   - bypassAllStoreGates: Final-attempt escape hatch after callers have waited. Still
    ///     never runs during org bootstrap or the launch quiet period (those jetsam Simulator).
    ///   - includeMaterialsFetch: Load tomorrow's material lines. Off by default — sequential
    ///     Firestore fetches jetsam Simulator when Warnings is open / just after launch.
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
        bypassSoftStoreGates: Bool = false,
        bypassAllStoreGates: Bool = false,
        includeMaterialsFetch: Bool = false
    ) async -> Bool {
        guard userStore.hasAdminAccess() else { return false }

        // Always skip during bootstrap / launch quiet — even when `force` is true.
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
        if isHeavySheetVisible && !force {
            print("🔥🔥🔥 DEBUG: Warnings refresh skipped (Warnings/Weekly Report sheet visible)")
            return false
        }

        let hardBusy = bookingStore.isLoading || operativeStore.isLoading || projectStore.isLoading
        let softBusy = holidayStore.isLoading || managerScheduleStore.isLoading

        if hardBusy && !bypassAllStoreGates {
            print("🔥🔥🔥 DEBUG: Warnings refresh skipped (hard stores still loading)")
            return false
        }
        if softBusy && !bypassSoftStoreGates && !bypassAllStoreGates {
            print("🔥🔥🔥 DEBUG: Warnings refresh skipped (soft stores still loading — holidays/manager schedule)")
            return false
        }

        // Match abort logic: need active operatives and/or org users.
        let activeEmpty = operativeStore.allOperatives.filter(\.isActive).isEmpty
        let usersEmpty = userStore.organizationUsers.isEmpty
        if activeEmpty && usersEmpty && !bypassAllStoreGates {
            print("🔥🔥🔥 DEBUG: Warnings refresh skipped (active users + operatives still empty)")
            return false
        }

        if !force {
            let now = Date()
            if let lastRefreshAt, now.timeIntervalSince(lastRefreshAt) < minRefreshInterval {
                return false
            }
        }

        if let inFlightTask {
            print("🔥🔥🔥 DEBUG: Warnings refresh awaiting in-flight pass (no second snapshot)")
            return await inFlightTask.value
        }

        let task = Task<Bool, Never> { @MainActor in
            await performRefresh(
                operativeStore: operativeStore,
                bookingStore: bookingStore,
                projectStore: projectStore,
                userStore: userStore,
                managerScheduleStore: managerScheduleStore,
                holidayStore: holidayStore,
                firebaseBackend: firebaseBackend,
                appSettings: appSettings,
                includeMaterialsFetch: includeMaterialsFetch
            )
        }
        inFlightTask = task
        lastRefreshAt = Date()
        let didPublish = await task.value
        if inFlightTask == task {
            inFlightTask = nil
        }
        return didPublish
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
        appSettings: AppSettingsStore,
        includeMaterialsFetch: Bool
    ) async -> Bool {
        if userStore.organizationUsers.isEmpty {
            print("🔥🔥🔥 DEBUG: Warnings refresh loading organization users (was empty)…")
            await userStore.loadOrganizationUsers()
        }

        let activeOperatives = operativeStore.allOperatives.filter(\.isActive)
        let users = userStore.organizationUsers
        if activeOperatives.isEmpty && users.isEmpty {
            print("🔥🔥🔥 DEBUG: Warnings refresh aborted (still no users/operatives after load) — keeping prior warnings")
            return false
        }

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

        print(
            "🔥🔥🔥 DEBUG: Warnings refresh snapshot inputs — users=\(users.count) activeOps=\(activeOperatives.count) bookings=\(bookingStore.bookings.count) mgr=\(managerScheduleStore.managerSiteBookings.count) holidays=\(holidayStore.bookings.count) standardPaid=\(policy.standardPaidHours) horizonEnd=\(warningDetection.coverageEnd(from: today, invoicing: invoicingSettings)) materialsFetch=\(includeMaterialsFetch) sheetVisible=\(isHeavySheetVisible)"
        )

        await Task.yield()
        if Task.isCancelled { return false }

        let materialCutOffEnabled = appSettings.settings.notifications.materialOrderCutOff
        let hour = cal.component(.hour, from: Date())
        var materialItemsForTomorrow: [MaterialItem] = []
        var materialsDataLoaded = false
        if includeMaterialsFetch, materialCutOffEnabled, hour >= 16,
           !isHeavySheetVisible,
           let orgId = firebaseBackend.currentOrganization?.firestoreDocumentId {
            materialsDataLoaded = true
            for project in projectsTomorrow.prefix(8) {
                if Task.isCancelled || isHeavySheetVisible {
                    materialsDataLoaded = false
                    materialItemsForTomorrow = []
                    break
                }
                if let items = try? await firebaseBackend.loadMaterialItems(
                    organizationId: orgId,
                    projectId: project.id
                ) {
                    materialItemsForTomorrow.append(
                        contentsOf: items.filter { cal.isDate($0.date, inSameDayAs: tomorrow) }
                    )
                }
                await Task.yield()
            }
        }

        if Task.isCancelled { return false }

        await WarningsService.shared.updateWarningsAsync(
            operatives: activeOperatives,
            bookings: bookingStore.bookings,
            projects: projects,
            users: users,
            managerSiteBookings: managerScheduleStore.managerSiteBookings,
            holidayBookings: holidayStore.bookings,
            payrollTimePolicy: policy,
            warningDetection: warningDetection,
            invoicingSettings: invoicingSettings,
            materialOrderCutOffEnabled: materialCutOffEnabled,
            materialCutOffOnSaturday: appSettings.settings.notifications.materialCutOffOnSaturday,
            materialCutOffOnSunday: appSettings.settings.notifications.materialCutOffOnSunday,
            projectsWithTomorrowBookings: projectsTomorrow,
            materialItemsForTomorrow: materialItemsForTomorrow,
            materialsDataLoaded: materialsDataLoaded,
            pruneDismissals: true
        )

        let unbookedToday = WarningsService.shared.activeWarnings.filter {
            $0.type == .unbookedLabour && ($0.occurrenceDate.map { cal.isDate($0, inSameDayAs: today) } ?? false)
        }.count
        print(
            "🔥🔥🔥 DEBUG: Warnings refresh finished count=\(WarningsService.shared.warningCount) active=\(WarningsService.shared.activeWarnings.count) unbookedToday=\(unbookedToday)"
        )
        postWarningsCountDidChange()
        return true
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
