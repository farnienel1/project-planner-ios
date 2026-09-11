//
//  WarningsRefreshHelper.swift
//  Project Planner
//

import Foundation

enum WarningsRefreshHelper {
    @MainActor private static var lastRefreshAt: Date?
    @MainActor private static var inFlightTask: Task<Void, Never>?
    private static let minRefreshInterval: TimeInterval = 45

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
    ) async {
        guard userStore.hasAdminAccess() else { return }

        // Always skip during bootstrap / launch quiet — even when `force` is true.
        // Opening Warnings used to pass force:true and bypass these guards, which
        // jetsams the Simulator right after Home bootstrap finishes.
        if firebaseBackend.isBootstrappingOrgDataLoad {
            print("🔥🔥🔥 DEBUG: Warnings refresh skipped (org bootstrap in progress)")
            return
        }
        if let quietUntil = firebaseBackend.launchQuietUntil, Date() < quietUntil {
            print("🔥🔥🔥 DEBUG: Warnings refresh skipped (launch quiet period)")
            return
        }
        if !firebaseBackend.hasBootstrappedOrgDataLoad {
            print("🔥🔥🔥 DEBUG: Warnings refresh skipped (org bootstrap not finished)")
            return
        }

        if !force {
            if bookingStore.isLoading || operativeStore.isLoading || holidayStore.isLoading || projectStore.isLoading {
                return
            }
            let now = Date()
            if let lastRefreshAt, now.timeIntervalSince(lastRefreshAt) < minRefreshInterval {
                return
            }
        }

        if let inFlightTask {
            // Always join the in-flight pass — never start a second org scan (jetsams Simulator).
            print("🔥🔥🔥 DEBUG: Warnings refresh awaiting in-flight pass (no second snapshot)")
            await inFlightTask.value
            return
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
