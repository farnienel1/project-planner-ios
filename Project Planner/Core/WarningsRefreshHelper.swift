//
//  WarningsRefreshHelper.swift
//  Project Planner
//

import Foundation

enum WarningsRefreshHelper {
    @MainActor private static var lastRefreshAt: Date?
    @MainActor private static var inFlightTask: Task<Void, Never>?
    private static let minRefreshInterval: TimeInterval = 45

    /// Returns `true` when a recompute ran (or an in-flight one completed under `force`).
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

        // Always skip during bootstrap / launch quiet — even when `force` is true.
        // Callers (Home post-quiet once, Warnings sheet) must wait for quiet + settled
        // stores before invoking; bypassing these guards jetsams Simulator after bootstrap.
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

        // Even with force, do not snapshot while core stores are mid-fetch — empty
        // bookings/operatives produce a false "all clear" that sticks until the next refresh.
        if bookingStore.isLoading || operativeStore.isLoading || holidayStore.isLoading || projectStore.isLoading || managerScheduleStore.isLoading {
            print("🔥🔥🔥 DEBUG: Warnings refresh skipped (stores still loading)")
            return false
        }

        if !force {
            let now = Date()
            if let lastRefreshAt, now.timeIntervalSince(lastRefreshAt) < minRefreshInterval {
                return false
            }
        }

        if let inFlightTask {
            await inFlightTask.value
            if !force { return true }
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

        // Yield so Home can finish painting before the heavy snapshot work.
        await Task.yield()

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
