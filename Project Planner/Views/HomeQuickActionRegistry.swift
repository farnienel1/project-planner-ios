//
//  HomeQuickActionRegistry.swift
//  Project Planner
//
//  Metadata and permission rules for home quick actions (customizable grid).
//

import SwiftUI

/// Stable IDs for home quick actions. Persisted to UserDefaults; do not rename existing raw values.
enum HomeQuickActionID: String, CaseIterable {
    // Operative
    case opProjects = "op-projects"
    case opSmallWorks = "op-small"
    case opAnnualLeave = "op-leave"
    case opSiteAudit = "op-audit"
    case opSchedule = "op-schedule"
    case opSettings = "op-settings"

    // Staff / shared
    case staffWeeklyReport = "staff-weekly"
    case staffDailyOverview = "staff-daily"
    case staffProjects = "staff-projects"
    case staffSmallWorks = "staff-small"
    case staffAnnualLeave = "staff-leave"
    case staffSchedule = "staff-schedule"
    case staffSiteAudit = "staff-audit"
    case staffManagers = "staff-managers"
    case staffOperatives = "staff-operatives"
    case staffSubcontractors = "staff-subs"
    case staffSiteMap = "staff-map"
    case staffSettings = "staff-settings"

    // Extra (parity with menu / app; never add account reset or sign-out here)
    case staffClients = "staff-clients"
    case staffCreateProject = "staff-create-project"
    case staffCreateSmallWorks = "staff-create-small"
    case staffSkills = "staff-skills"
    case staffQualifications = "staff-qualifications"
    case staffMyQualifications = "staff-my-qualifications"
    case staffJobTypes = "staff-job-types"
    case staffWholesalers = "staff-wholesalers"
    case staffAddUser = "staff-add-user"
    case staffManageUsersSheet = "staff-manage-users"
    case staffHelp = "staff-help"
    case staffHoliday = "staff-holiday"
    case staffGeneralAppSettings = "staff-general-app"
    case staffTasks = "staff-tasks"

    /// Never offer these on the home screen (picker / persistence strip).
    static let barredFromHome: Set<String> = [
        "account-reset-password",
        "account-sign-out"
    ]
}

struct HomeQuickActionMeta {
    let id: String
    let symbol: String
    /// Use `\n` for two-line labels in the grid.
    let title: String
    let tint: (Double, Double, Double)

    var color: Color {
        Color(red: tint.0, green: tint.1, blue: tint.2)
    }
}

enum HomeQuickActionRegistry {

    private static let purple = (0.325, 0.29, 0.718)
    private static let green = (0.059, 0.431, 0.337)
    private static let brown = (0.522, 0.31, 0.043)
    private static let rose = (0.6, 0.208, 0.337)
    private static let rust = (0.6, 0.235, 0.114)
    private static let blue = (0.094, 0.373, 0.647)
    private static let muted = (0.42, 0.45, 0.49)

    static func meta(for id: String) -> HomeQuickActionMeta? {
        switch id {
        case HomeQuickActionID.opProjects.rawValue:
            return HomeQuickActionMeta(id: id, symbol: "folder.fill", title: "Projects", tint: green)
        case HomeQuickActionID.opSmallWorks.rawValue:
            return HomeQuickActionMeta(id: id, symbol: "hammer.fill", title: "Small\nworks", tint: brown)
        case HomeQuickActionID.opAnnualLeave.rawValue:
            return HomeQuickActionMeta(id: id, symbol: "sun.max.fill", title: "Annual\nleave", tint: rust)
        case HomeQuickActionID.opSiteAudit.rawValue:
            return HomeQuickActionMeta(id: id, symbol: "doc.text.viewfinder", title: "Site\naudit", tint: blue)
        case HomeQuickActionID.opSchedule.rawValue:
            return HomeQuickActionMeta(id: id, symbol: "calendar", title: "My\nschedule", tint: rose)
        case HomeQuickActionID.opSettings.rawValue:
            return HomeQuickActionMeta(id: id, symbol: "gearshape.fill", title: "Settings", tint: muted)

        case HomeQuickActionID.staffWeeklyReport.rawValue:
            return HomeQuickActionMeta(id: id, symbol: "chart.bar.doc.horizontal", title: "Weekly\nreport", tint: blue)
        case HomeQuickActionID.staffDailyOverview.rawValue:
            return HomeQuickActionMeta(id: id, symbol: "calendar.badge.clock", title: "Daily\noverview", tint: purple)
        case HomeQuickActionID.staffProjects.rawValue:
            return HomeQuickActionMeta(id: id, symbol: "folder.fill", title: "Projects", tint: green)
        case HomeQuickActionID.staffSmallWorks.rawValue:
            return HomeQuickActionMeta(id: id, symbol: "hammer.fill", title: "Small\nworks", tint: brown)
        case HomeQuickActionID.staffAnnualLeave.rawValue:
            return HomeQuickActionMeta(id: id, symbol: "sun.max.fill", title: "Annual\nleave", tint: rust)
        case HomeQuickActionID.staffSchedule.rawValue:
            return HomeQuickActionMeta(id: id, symbol: "calendar", title: "My\nschedule", tint: rose)
        case HomeQuickActionID.staffSiteAudit.rawValue:
            return HomeQuickActionMeta(id: id, symbol: "doc.text.viewfinder", title: "Site\naudit", tint: blue)
        case HomeQuickActionID.staffManagers.rawValue:
            return HomeQuickActionMeta(id: id, symbol: "person.badge.key.fill", title: "Managers", tint: purple)
        case HomeQuickActionID.staffOperatives.rawValue:
            return HomeQuickActionMeta(id: id, symbol: "person.3.fill", title: "Operatives", tint: green)
        case HomeQuickActionID.staffSubcontractors.rawValue:
            return HomeQuickActionMeta(id: id, symbol: "person.2.badge.gearshape.fill", title: "Sub\ncontractors", tint: muted)
        case HomeQuickActionID.staffSiteMap.rawValue:
            return HomeQuickActionMeta(id: id, symbol: "map.fill", title: "Site\nmap", tint: green)
        case HomeQuickActionID.staffSettings.rawValue:
            return HomeQuickActionMeta(id: id, symbol: "gearshape.fill", title: "Settings", tint: muted)

        case HomeQuickActionID.staffClients.rawValue:
            return HomeQuickActionMeta(id: id, symbol: "person.2.fill", title: "Clients", tint: blue)
        case HomeQuickActionID.staffCreateProject.rawValue:
            return HomeQuickActionMeta(id: id, symbol: "plus.square.fill", title: "Create\nproject", tint: green)
        case HomeQuickActionID.staffCreateSmallWorks.rawValue:
            return HomeQuickActionMeta(id: id, symbol: "hammer.fill", title: "Create\nsmall works", tint: brown)
        case HomeQuickActionID.staffSkills.rawValue:
            return HomeQuickActionMeta(id: id, symbol: "wrench.and.screwdriver.fill", title: "Skills", tint: purple)
        case HomeQuickActionID.staffQualifications.rawValue:
            return HomeQuickActionMeta(id: id, symbol: "graduationcap.fill", title: "Qualifi-\ncations", tint: blue)
        case HomeQuickActionID.staffMyQualifications.rawValue:
            return HomeQuickActionMeta(id: id, symbol: "graduationcap.fill", title: "My\nqualifications", tint: blue)
        case HomeQuickActionID.staffJobTypes.rawValue:
            return HomeQuickActionMeta(id: id, symbol: "folder.fill", title: "Job\ntypes", tint: green)
        case HomeQuickActionID.staffWholesalers.rawValue:
            return HomeQuickActionMeta(id: id, symbol: "building.2.fill", title: "Whole-\nsalers", tint: muted)
        case HomeQuickActionID.staffAddUser.rawValue:
            return HomeQuickActionMeta(id: id, symbol: "person.badge.plus.fill", title: "Add\nuser", tint: purple)
        case HomeQuickActionID.staffManageUsersSheet.rawValue:
            return HomeQuickActionMeta(id: id, symbol: "person.2.fill", title: "Manage\nusers", tint: blue)
        case HomeQuickActionID.staffHelp.rawValue:
            return HomeQuickActionMeta(id: id, symbol: "questionmark.circle.fill", title: "Help", tint: muted)
        case HomeQuickActionID.staffHoliday.rawValue:
            return HomeQuickActionMeta(id: id, symbol: "sun.max.fill", title: "Holiday", tint: rust)
        case HomeQuickActionID.staffGeneralAppSettings.rawValue:
            return HomeQuickActionMeta(id: id, symbol: "slider.horizontal.3", title: "General\napp", tint: purple)
        case HomeQuickActionID.staffTasks.rawValue:
            return HomeQuickActionMeta(id: id, symbol: "plus.rectangle.on.rectangle", title: "Tasks", tint: blue)
        default:
            return nil
        }
    }

    static func isEligible(id: String, userStore: UserStore) -> Bool {
        guard HomeQuickActionID.barredFromHome.contains(id) == false else { return false }
        guard meta(for: id) != nil else { return false }

        switch id {
        case HomeQuickActionID.opProjects.rawValue, HomeQuickActionID.opSmallWorks.rawValue,
             HomeQuickActionID.opSchedule.rawValue,
             HomeQuickActionID.opSettings.rawValue:
            return userStore.isOperativeMode()
        case HomeQuickActionID.opAnnualLeave.rawValue:
            return userStore.isOperativeMode() && userStore.isAnnualLeaveFeatureEnabled()
        case HomeQuickActionID.opSiteAudit.rawValue:
            return userStore.isOperativeMode() && (userStore.canViewSiteAudit() || userStore.isHomeProfileLoading)

        case HomeQuickActionID.staffWeeklyReport.rawValue:
            return !userStore.isOperativeMode()
                && (userStore.hasAdminAccess() || userStore.displayUser?.permissions.weeklyReports == true || userStore.isHomeProfileLoading)
        case HomeQuickActionID.staffDailyOverview.rawValue:
            return !userStore.isOperativeMode()
                && (userStore.hasAdminAccess() || userStore.displayUser?.permissions.weeklyReports == true || userStore.isHomeProfileLoading)
        case HomeQuickActionID.staffProjects.rawValue, HomeQuickActionID.staffSmallWorks.rawValue:
            return !userStore.isOperativeMode() && userStore.canViewProjects()
        case HomeQuickActionID.staffAnnualLeave.rawValue:
            return !userStore.isOperativeMode()
                && userStore.isAnnualLeaveFeatureEnabled()
                && (userStore.hasAdminAccess() || userStore.displayUser?.permissions.manager == true || userStore.isHomeProfileLoading)
        case HomeQuickActionID.staffSchedule.rawValue:
            return !userStore.isOperativeMode() && userStore.canViewProjects()
        case HomeQuickActionID.staffSiteAudit.rawValue:
            return !userStore.isOperativeMode() && (userStore.canViewSiteAudit() || userStore.isHomeProfileLoading)
        case HomeQuickActionID.staffManagers.rawValue:
            return !userStore.isOperativeMode() && userStore.hasAdminAccess()
        case HomeQuickActionID.staffOperatives.rawValue:
            return !userStore.isOperativeMode() && userStore.canViewOperatives()
        case HomeQuickActionID.staffSubcontractors.rawValue:
            return !userStore.isOperativeMode() && userStore.canManageSubcontractors()
        case HomeQuickActionID.staffSiteMap.rawValue:
            return !userStore.isOperativeMode() && userStore.hasAdminAccess()
        case HomeQuickActionID.staffSettings.rawValue:
            return !userStore.isOperativeMode()

        case HomeQuickActionID.staffClients.rawValue:
            return !userStore.isOperativeMode()
        case HomeQuickActionID.staffCreateProject.rawValue:
            return !userStore.isOperativeMode() && canCreateProject(userStore)
        case HomeQuickActionID.staffCreateSmallWorks.rawValue:
            return !userStore.isOperativeMode() && canCreateSmallWorks(userStore)
        case HomeQuickActionID.staffSkills.rawValue:
            return !userStore.isOperativeMode() && userStore.canManageSkills()
        case HomeQuickActionID.staffQualifications.rawValue:
            return !userStore.isOperativeMode() && userStore.canManageQualifications()
        case HomeQuickActionID.staffMyQualifications.rawValue:
            return userStore.isOperativeMode()
        case HomeQuickActionID.staffJobTypes.rawValue, HomeQuickActionID.staffWholesalers.rawValue:
            return !userStore.isOperativeMode() && userStore.hasAdminAccess()
        case HomeQuickActionID.staffAddUser.rawValue, HomeQuickActionID.staffManageUsersSheet.rawValue:
            return !userStore.isOperativeMode()
                && (userStore.canManageUsers()
                    || (!userStore.hasAdminAccess()
                         && userStore.displayUser?.permissions.manager == true
                         && userStore.displayUser?.permissions.operatives == true))
        case HomeQuickActionID.staffHelp.rawValue:
            return !userStore.isOperativeMode()
        case HomeQuickActionID.staffHoliday.rawValue:
            return userStore.isAnnualLeaveFeatureEnabled()
        case HomeQuickActionID.staffGeneralAppSettings.rawValue:
            return !userStore.isOperativeMode() && userStore.hasAdminAccess()
        case HomeQuickActionID.staffTasks.rawValue:
            return !userStore.isOperativeMode()
        default:
            return false
        }
    }

    /// Default order when nothing is saved (matches previous home screen behaviour).
    static func defaultOrderedIds(userStore: UserStore) -> [String] {
        if userStore.isOperativeMode() {
            var a: [String] = [
                HomeQuickActionID.opProjects.rawValue,
                HomeQuickActionID.opSmallWorks.rawValue,
                HomeQuickActionID.opAnnualLeave.rawValue
            ]
            if isEligible(id: HomeQuickActionID.opSiteAudit.rawValue, userStore: userStore) {
                a.append(HomeQuickActionID.opSiteAudit.rawValue)
            }
            a.append(contentsOf: [
                HomeQuickActionID.opSchedule.rawValue,
                HomeQuickActionID.opSettings.rawValue
            ])
            return a.filter { isEligible(id: $0, userStore: userStore) }
        }

        var items: [String] = []
        if isEligible(id: HomeQuickActionID.staffWeeklyReport.rawValue, userStore: userStore) {
            items.append(HomeQuickActionID.staffWeeklyReport.rawValue)
        }
        if isEligible(id: HomeQuickActionID.staffDailyOverview.rawValue, userStore: userStore) {
            items.append(HomeQuickActionID.staffDailyOverview.rawValue)
        }
        if isEligible(id: HomeQuickActionID.staffTasks.rawValue, userStore: userStore) {
            items.append(HomeQuickActionID.staffTasks.rawValue)
        }
        if isEligible(id: HomeQuickActionID.staffProjects.rawValue, userStore: userStore) {
            items.append(HomeQuickActionID.staffProjects.rawValue)
        }
        if isEligible(id: HomeQuickActionID.staffSmallWorks.rawValue, userStore: userStore) {
            items.append(HomeQuickActionID.staffSmallWorks.rawValue)
        }
        if isEligible(id: HomeQuickActionID.staffAnnualLeave.rawValue, userStore: userStore) {
            items.append(HomeQuickActionID.staffAnnualLeave.rawValue)
        }
        if isEligible(id: HomeQuickActionID.staffSchedule.rawValue, userStore: userStore) {
            items.append(HomeQuickActionID.staffSchedule.rawValue)
        }
        if isEligible(id: HomeQuickActionID.staffSiteAudit.rawValue, userStore: userStore) {
            items.append(HomeQuickActionID.staffSiteAudit.rawValue)
        }
        if isEligible(id: HomeQuickActionID.staffManagers.rawValue, userStore: userStore) {
            items.append(HomeQuickActionID.staffManagers.rawValue)
        }
        if isEligible(id: HomeQuickActionID.staffOperatives.rawValue, userStore: userStore) {
            items.append(HomeQuickActionID.staffOperatives.rawValue)
        }
        if isEligible(id: HomeQuickActionID.staffSubcontractors.rawValue, userStore: userStore) {
            items.append(HomeQuickActionID.staffSubcontractors.rawValue)
        }
        if isEligible(id: HomeQuickActionID.staffSiteMap.rawValue, userStore: userStore) {
            items.append(HomeQuickActionID.staffSiteMap.rawValue)
        }
        if isEligible(id: HomeQuickActionID.staffSettings.rawValue, userStore: userStore) {
            items.append(HomeQuickActionID.staffSettings.rawValue)
        }
        return items
    }

    /// All actions the user may add (includes items not on the previous default strip).
    static func allEligibleIds(userStore: UserStore) -> [String] {
        HomeQuickActionID.allCases.map(\.rawValue)
            .filter { isEligible(id: $0, userStore: userStore) }
            .sorted()
    }

    private static func canCreateProject(_ userStore: UserStore) -> Bool {
        guard let user = userStore.currentUser else { return false }
        if user.permissions.operativeMode { return false }
        if user.isSuperAdmin || user.permissions.adminAccess { return true }
        return user.permissions.manager && user.permissions.projects
    }

    private static func canCreateSmallWorks(_ userStore: UserStore) -> Bool {
        guard let user = userStore.currentUser else { return false }
        if user.permissions.operativeMode { return false }
        if user.isSuperAdmin || user.permissions.adminAccess { return true }
        return user.permissions.manager && user.permissions.smallWorks
    }
}
