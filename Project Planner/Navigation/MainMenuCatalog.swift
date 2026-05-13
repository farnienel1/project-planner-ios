//
//  MainMenuCatalog.swift
//  Project Planner
//
//  Single source of truth for Main Menu (home) and More (tab bar) so both surfaces
//  expose the same eligible options for the current user.
//

import Foundation
import SwiftUI

extension Notification.Name {
    /// Open a home-level sheet or flow. `userInfo["route"]` is `MainMenuSurfaceRoute.rawValue` (String).
    static let mainMenuOpenSurface = Notification.Name("mainMenuOpenSurface")
    /// Turn on bottom tab reorder (jiggle) from the shell.
    static let mainMenuEditTabBar = Notification.Name("mainMenuEditTabBar")
    /// Reset password for the signed-in account (uses Firebase).
    static let mainMenuResetPassword = Notification.Name("mainMenuResetPassword")
    /// Sign out (clears UserStore and Firebase session).
    static let mainMenuSignOut = Notification.Name("mainMenuSignOut")
}

/// Home surfaces opened from either Main Menu or More (HomeView owns the sheets).
enum MainMenuSurfaceRoute: String, CaseIterable {
    case clients
    case createProject
    case createSmallWorks
    case skills
    case qualifications
    case myQualifications
    case jobTypes
    case wholesalers
    case addUser
    case manageUsers
    case tasksDetail
    case generalAppSettings
    case orgSitesMap
    case siteAudit
}

enum MainMenuShellSection: String, CaseIterable, Identifiable {
    case editBar
    case navigate
    case tools
    case team
    case account

    var id: String { rawValue }

    var headerTitle: String {
        switch self {
        case .editBar: return ""
        case .navigate: return "Navigate"
        case .tools: return "Tools"
        case .team: return "Team"
        case .account: return "App & account"
        }
    }
}

enum MainMenuRowAction: Equatable {
    case selectTab(Int)
    case openSurface(MainMenuSurfaceRoute)
    case editTabBar
    case resetPassword
    case signOut
}

struct MainMenuRowSpec: Identifiable, Equatable {
    let id: String
    let section: MainMenuShellSection
    let title: String
    /// Optional second line (e.g. edit tab bar hint).
    let detail: String?
    let icon: String
    let iconBackground: Color
    let iconTint: Color
    let isEligible: (UserStore, ProjectStore, OperativeStore) -> Bool
    let action: MainMenuRowAction

    static func == (lhs: MainMenuRowSpec, rhs: MainMenuRowSpec) -> Bool {
        lhs.id == rhs.id
    }
}

enum MainMenuCatalog {

    /// Rows in display order; eligibility is evaluated per user.
    static func allRowSpecs() -> [MainMenuRowSpec] {
        [
            MainMenuRowSpec(
                id: "edit_tab_bar",
                section: .editBar,
                title: "Edit main menu bar",
                detail: "Icons jiggle — drag onto a slot in the bar below to reorder.",
                icon: "arrow.down.to.line.compact",
                iconBackground: Color(red: 0.902, green: 0.945, blue: 0.984),
                iconTint: Color(red: 0.09, green: 0.373, blue: 0.647),
                isEligible: { u, _, _ in !u.isOperativeMode() },
                action: .editTabBar
            ),

            MainMenuRowSpec(
                id: "clients",
                section: .navigate,
                title: "Clients",
                detail: nil,
                icon: "briefcase.fill",
                iconBackground: Color(red: 0.902, green: 0.945, blue: 0.984),
                iconTint: ProjectWorksRevampColors.blue,
                isEligible: { u, _, _ in !u.isOperativeMode() },
                action: .openSurface(.clients)
            ),
            MainMenuRowSpec(
                id: "projects",
                section: .navigate,
                title: "Projects",
                detail: nil,
                icon: "folder.fill",
                iconBackground: Color(red: 0.882, green: 0.961, blue: 0.933),
                iconTint: ProjectWorksRevampColors.activeGreen,
                isEligible: { u, _, _ in u.canViewProjects() },
                action: .selectTab(1)
            ),
            MainMenuRowSpec(
                id: "small_works",
                section: .navigate,
                title: "Small works",
                detail: nil,
                icon: "hammer.fill",
                iconBackground: Color(red: 0.98, green: 0.933, blue: 0.855),
                iconTint: ProjectWorksRevampColors.upcomingAmber,
                isEligible: { u, _, _ in u.canViewProjects() },
                action: .selectTab(2)
            ),
            MainMenuRowSpec(
                id: "operatives",
                section: .navigate,
                title: "Operatives",
                detail: nil,
                icon: "person.3.fill",
                iconBackground: ProjectWorksRevampColors.jobTypePillBg,
                iconTint: Color(red: 0.325, green: 0.29, blue: 0.718),
                isEligible: { u, _, _ in u.canViewOperatives() },
                action: .selectTab(3)
            ),
            MainMenuRowSpec(
                id: "managers",
                section: .navigate,
                title: "Managers",
                detail: nil,
                icon: "person.badge.shield.checkmark.fill",
                iconBackground: Color(red: 0.984, green: 0.918, blue: 0.941),
                iconTint: Color(red: 0.6, green: 0.208, blue: 0.337),
                isEligible: { u, _, _ in u.canViewManagers() },
                action: .selectTab(4)
            ),
            MainMenuRowSpec(
                id: "holiday",
                section: .navigate,
                title: "Holiday",
                detail: nil,
                icon: "sun.max.fill",
                iconBackground: Color(red: 0.98, green: 0.93, blue: 0.91),
                iconTint: Color(red: 0.6, green: 0.24, blue: 0.11),
                isEligible: { u, _, _ in u.isAnnualLeaveFeatureEnabled() },
                action: .selectTab(8)
            ),
            MainMenuRowSpec(
                id: "site_map",
                section: .navigate,
                title: "Site map",
                detail: nil,
                icon: "map.fill",
                iconBackground: Color(red: 0.98, green: 0.92, blue: 0.94),
                iconTint: Color(red: 0.6, green: 0.21, blue: 0.34),
                isEligible: { u, _, _ in u.hasAdminAccess() },
                action: .openSurface(.orgSitesMap)
            ),
            MainMenuRowSpec(
                id: "site_audit",
                section: .navigate,
                title: "Site audit",
                detail: nil,
                icon: "doc.text.viewfinder",
                iconBackground: Color(red: 0.98, green: 0.93, blue: 0.91),
                iconTint: Color(red: 0.6, green: 0.24, blue: 0.11),
                isEligible: { u, _, _ in u.canViewSiteAudit() || u.isHomeProfileLoading },
                action: .openSurface(.siteAudit)
            ),

            MainMenuRowSpec(
                id: "skills",
                section: .tools,
                title: "Skills",
                detail: nil,
                icon: "wrench.and.screwdriver.fill",
                iconBackground: Color(red: 0.98, green: 0.925, blue: 0.906),
                iconTint: Color(red: 0.6, green: 0.235, blue: 0.114),
                isEligible: { u, _, _ in u.canManageSkills() },
                action: .openSurface(.skills)
            ),
            MainMenuRowSpec(
                id: "qualifications",
                section: .tools,
                title: "Qualifications",
                detail: nil,
                icon: "graduationcap.fill",
                iconBackground: Color(red: 0.902, green: 0.945, blue: 0.984),
                iconTint: ProjectWorksRevampColors.blue,
                isEligible: { u, _, _ in u.canManageQualifications() },
                action: .openSurface(.qualifications)
            ),
            MainMenuRowSpec(
                id: "my_qualifications",
                section: .tools,
                title: "My qualifications",
                detail: nil,
                icon: "graduationcap.fill",
                iconBackground: Color(red: 0.902, green: 0.945, blue: 0.984),
                iconTint: ProjectWorksRevampColors.blue,
                isEligible: { u, _, _ in u.isOperativeMode() },
                action: .openSurface(.myQualifications)
            ),
            MainMenuRowSpec(
                id: "job_types",
                section: .tools,
                title: "Job types",
                detail: nil,
                icon: "square.grid.2x2.fill",
                iconBackground: Color(red: 0.882, green: 0.961, blue: 0.933),
                iconTint: ProjectWorksRevampColors.activeGreen,
                isEligible: { u, _, _ in u.hasAdminAccess() },
                action: .openSurface(.jobTypes)
            ),
            MainMenuRowSpec(
                id: "wholesalers",
                section: .tools,
                title: "Wholesalers",
                detail: nil,
                icon: "building.2.fill",
                iconBackground: Color(red: 0.98, green: 0.933, blue: 0.855),
                iconTint: ProjectWorksRevampColors.upcomingAmber,
                isEligible: { u, _, _ in u.hasAdminAccess() },
                action: .openSurface(.wholesalers)
            ),
            MainMenuRowSpec(
                id: "subcontractors",
                section: .tools,
                title: "Sub contractors",
                detail: nil,
                icon: "person.2.badge.gearshape.fill",
                iconBackground: ProjectWorksRevampColors.jobTypePillBg,
                iconTint: Color(red: 0.325, green: 0.29, blue: 0.718),
                isEligible: { u, _, _ in u.canManageSubcontractors() },
                action: .selectTab(9)
            ),

            MainMenuRowSpec(
                id: "add_user",
                section: .team,
                title: "Add user",
                detail: nil,
                icon: "person.badge.plus.fill",
                iconBackground: ProjectWorksRevampColors.jobTypePillBg,
                iconTint: Color(red: 0.325, green: 0.29, blue: 0.718),
                isEligible: { u, _, _ in
                    u.canManageUsers()
                        || (!u.hasAdminAccess()
                            && u.displayUser?.permissions.manager == true
                            && u.displayUser?.permissions.operatives == true)
                },
                action: .openSurface(.addUser)
            ),
            MainMenuRowSpec(
                id: "manage_users",
                section: .team,
                title: "Manage users",
                detail: nil,
                icon: "person.2.fill",
                iconBackground: Color(red: 0.902, green: 0.945, blue: 0.984),
                iconTint: ProjectWorksRevampColors.blue,
                isEligible: { u, _, _ in
                    u.canManageUsers()
                        || (!u.hasAdminAccess()
                            && u.displayUser?.permissions.manager == true
                            && u.displayUser?.permissions.operatives == true)
                },
                action: .openSurface(.manageUsers)
            ),

            MainMenuRowSpec(
                id: "settings",
                section: .account,
                title: "Settings",
                detail: nil,
                icon: "gearshape.fill",
                iconBackground: Color(red: 0.949, green: 0.953, blue: 0.961),
                iconTint: ProjectWorksRevampColors.muted,
                isEligible: { _, _, _ in true },
                action: .selectTab(5)
            ),
            MainMenuRowSpec(
                id: "general_app",
                section: .account,
                title: "General",
                detail: nil,
                icon: "slider.horizontal.3",
                iconBackground: Color(red: 0.902, green: 0.945, blue: 0.984),
                iconTint: ProjectWorksRevampColors.blue,
                isEligible: { u, _, _ in u.hasAdminAccess() },
                action: .openSurface(.generalAppSettings)
            ),
            MainMenuRowSpec(
                id: "help",
                section: .account,
                title: "Help & support",
                detail: nil,
                icon: "questionmark.circle.fill",
                iconBackground: Color(red: 0.882, green: 0.961, blue: 0.933),
                iconTint: ProjectWorksRevampColors.activeGreen,
                isEligible: { u, _, _ in !u.isOperativeMode() },
                action: .selectTab(6)
            ),
            MainMenuRowSpec(
                id: "reset_password",
                section: .account,
                title: "Reset password",
                detail: nil,
                icon: "key.fill",
                iconBackground: ProjectWorksRevampColors.jobTypePillBg,
                iconTint: Color(red: 0.325, green: 0.29, blue: 0.718),
                isEligible: { _, _, _ in true },
                action: .resetPassword
            ),
            MainMenuRowSpec(
                id: "sign_out",
                section: .account,
                title: "Sign out",
                detail: nil,
                icon: "rectangle.portrait.and.arrow.right",
                iconBackground: Color(red: 0.988, green: 0.922, blue: 0.922),
                iconTint: Color(red: 0.639, green: 0.176, blue: 0.176),
                isEligible: { _, _, _ in true },
                action: .signOut
            ),
        ]
    }

    static func visibleRows(
        userStore: UserStore,
        projectStore: ProjectStore,
        operativeStore: OperativeStore
    ) -> [MainMenuRowSpec] {
        allRowSpecs().filter { $0.isEligible(userStore, projectStore, operativeStore) }
    }

    static func toolBadge(for rowId: String, operativeStore: OperativeStore) -> String? {
        guard rowId == "qualifications" else { return nil }
        let n = qualificationsExpiringSoonCount(operativeStore: operativeStore)
        return n > 0 ? "\(n) expiring" : nil
    }

    static func groupedVisibleRows(
        userStore: UserStore,
        projectStore: ProjectStore,
        operativeStore: OperativeStore
    ) -> [(section: MainMenuShellSection, rows: [MainMenuRowSpec])] {
        MainMenuShellSection.allCases.compactMap { sec in
            let rows = allRowSpecs().filter {
                $0.section == sec && $0.isEligible(userStore, projectStore, operativeStore)
            }
            return rows.isEmpty ? nil : (sec, rows)
        }
    }

    static func displayTitle(for spec: MainMenuRowSpec, userStore: UserStore) -> String {
        switch spec.id {
        case "add_user":
            return userStore.canManageUsers() ? "Add user" : "Add operative"
        case "manage_users":
            return userStore.canManageUsers() ? "Manage users" : "Manage operatives"
        default:
            return spec.title
        }
    }

    // MARK: - Quick create (same gates as previous QuickMenuSheet)

    static func showQuickCreateSection(userStore: UserStore) -> Bool {
        quickCreateVisibleButtonCount(userStore: userStore) > 0
    }

    static func quickCreateVisibleButtonCount(userStore: UserStore) -> Int {
        (canCreateProject(userStore: userStore) ? 1 : 0)
            + (canCreateSmallWorks(userStore: userStore) ? 1 : 0)
            + (canAddUserQuick(userStore: userStore) ? 1 : 0)
            + 1
    }

    static func canCreateProject(userStore: UserStore) -> Bool {
        guard let user = userStore.currentUser else { return false }
        if user.permissions.operativeMode { return false }
        if user.isSuperAdmin || user.permissions.adminAccess { return true }
        return user.permissions.manager && user.permissions.projects
    }

    static func canCreateSmallWorks(userStore: UserStore) -> Bool {
        guard let user = userStore.currentUser else { return false }
        if user.permissions.operativeMode { return false }
        if user.isSuperAdmin || user.permissions.adminAccess { return true }
        return user.permissions.manager && user.permissions.smallWorks
    }

    static func canAddUserQuick(userStore: UserStore) -> Bool {
        userStore.canManageUsers()
            || (!userStore.hasAdminAccess()
                && userStore.displayUser?.permissions.manager == true
                && userStore.displayUser?.permissions.operatives == true)
    }

    // MARK: - Subtitles (Navigate polish)

    static func subtitle(for rowId: String, projectStore: ProjectStore, operativeStore: OperativeStore) -> String? {
        switch rowId {
        case "clients":
            return "\(projectStore.clients.count) on file"
        case "projects":
            let n = projectStore.projects.filter { $0.jobType != .smallWorks && $0.status == .active }.count
            return "\(n) in progress"
        case "small_works":
            let n = projectStore.smallWorks.filter { $0.status == .active || $0.status == .upcoming }.count
            return "\(n) open"
        case "operatives":
            let n = operativeStore.allOperatives.filter(\.isActive).count
            return "\(n) team members"
        case "managers":
            return "\(operativeStore.allManagers.count) active"
        default:
            return nil
        }
    }

    private static func qualificationsExpiringSoonCount(operativeStore: OperativeStore) -> Int {
        let today = Calendar.current.startOfDay(for: Date())
        guard let horizon = Calendar.current.date(byAdding: .day, value: 30, to: today) else { return 0 }
        var n = 0
        for op in operativeStore.allOperatives {
            for (_, exp) in op.qualificationExpiryDates {
                if exp >= today && exp <= horizon { n += 1 }
            }
        }
        return n
    }

    // MARK: - Emit actions (shell + home)

    static func emit(_ action: MainMenuRowAction) {
        switch action {
        case .selectTab(let tab):
            NotificationCenter.default.post(
                name: NSNotification.Name("selectTab"),
                object: nil,
                userInfo: ["tab": tab]
            )
        case .openSurface(let route):
            NotificationCenter.default.post(
                name: .mainMenuOpenSurface,
                object: nil,
                userInfo: ["route": route.rawValue]
            )
        case .editTabBar:
            NotificationCenter.default.post(name: .mainMenuEditTabBar, object: nil)
        case .resetPassword:
            NotificationCenter.default.post(name: .mainMenuResetPassword, object: nil)
        case .signOut:
            NotificationCenter.default.post(name: .mainMenuSignOut, object: nil)
        }
    }
}
