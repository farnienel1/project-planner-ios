import Foundation

/// Buttons each role can see, taken from `MainMenuCatalog`, `HomeQuickActionRegistry`, and `UserStore`.
/// Toggle-gated rows (weekly reports, wholesalers, operatives permission, timesheets payroll) are optional:
/// the navigation test exercises them when the identifier is on screen.
enum RoleSurfaces {
    static func homeChrome(role: String) -> [PPButton] {
        var buttons: [PPButton] = [
            PPButton(id: PPID.homeRefresh, kind: .stay),
            PPButton(id: PPID.homeNotifications, kind: .destination(PPID.notifications)),
            PPButton(id: PPID.homeAvatar, kind: .destination(PPID.profile)),
            PPButton(id: PPID.homeCustomise, kind: .customise),
            PPButton(id: PPID.homeSeeAll, kind: .destination(PPID.schedule))
        ]
        if role == "admin" {
            buttons.append(PPButton(id: PPID.homeOverviewSettings, kind: .destination(PPID.homeOverviewSettingsDone)))
        }
        return buttons
    }

    static func homeQuickActions(role: String) -> (required: [PPButton], optional: [PPButton]) {
        switch role {
        case "admin":
            return (
                required: [
                    quick("staff-tasks", PPID.tasks),
                    quick("staff-projects", PPID.projects),
                    quick("staff-small", PPID.smallWorks),
                    quick("staff-leave", PPID.leave),
                    quick("staff-schedule", PPID.schedule),
                    quick("staff-audit", PPID.siteAudit),
                    quick("staff-managers", PPID.peopleManagers),
                    quick("staff-subs", PPID.peopleSubcontractors),
                    quick("staff-map", PPID.siteMap),
                    quick("staff-settings", PPID.settings)
                ],
                optional: [
                    quick("staff-weekly", PPID.weeklyReport),
                    quick("staff-daily", PPID.dailyOverview),
                    quick("staff-operatives", PPID.peopleOperatives),
                    quick("staff-invoicing", PPID.timesheets)
                ]
            )
        case "manager":
            return (
                required: [
                    quick("staff-tasks", PPID.tasks),
                    quick("staff-projects", PPID.projects),
                    quick("staff-small", PPID.smallWorks),
                    quick("staff-schedule", PPID.schedule),
                    quick("staff-audit", PPID.siteAudit),
                    quick("staff-settings", PPID.settings)
                ],
                optional: [
                    quick("staff-weekly", PPID.weeklyReport),
                    quick("staff-daily", PPID.dailyOverview),
                    quick("staff-leave", PPID.leave),
                    quick("staff-operatives", PPID.peopleOperatives),
                    quick("staff-subs", PPID.peopleSubcontractors),
                    quick("staff-invoicing", PPID.timesheets)
                ]
            )
        default:
            return (
                required: [
                    quick("op-projects", PPID.projects),
                    quick("op-small", PPID.smallWorks),
                    quick("op-leave", PPID.leave),
                    quick("op-schedule", PPID.schedule),
                    quick("op-settings", PPID.settings)
                ],
                optional: [
                    quick("op-audit", PPID.siteAudit),
                    quick("staff-invoicing", PPID.timesheets)
                ]
            )
        }
    }

    static func menuRows(role: String) -> (required: [PPButton], optional: [PPButton]) {
        switch role {
        case "admin":
            return (
                required: [
                    PPButton(id: PPID.mainMenuRow("edit_tab_bar"), kind: .editTabBar),
                    row("clients", PPID.libraryClients),
                    row("projects", PPID.projects),
                    row("small_works", PPID.smallWorks),
                    row("managers", PPID.peopleManagers),
                    row("holiday", PPID.leave),
                    row("site_map", PPID.siteMap),
                    row("site_audit", PPID.siteAudit),
                    row("qualifications", PPID.libraryQualifications),
                    row("job_types", PPID.libraryJobTypes),
                    row("material_catalogue", PPID.libraryMaterials),
                    row("subcontractors", PPID.peopleSubcontractors),
                    row("add_user", PPID.peopleAddUser),
                    row("manage_users", PPID.peopleManageUsers),
                    row("settings", PPID.settings),
                    row("help", PPID.help)
                ],
                optional: [
                    row("operatives", PPID.peopleOperatives),
                    row("wholesalers", PPID.libraryWholesalers),
                    row("invoicing", PPID.timesheets)
                ]
            )
        case "manager":
            return (
                required: [
                    PPButton(id: PPID.mainMenuRow("edit_tab_bar"), kind: .editTabBar),
                    row("clients", PPID.libraryClients),
                    row("projects", PPID.projects),
                    row("small_works", PPID.smallWorks),
                    row("holiday", PPID.leave),
                    row("site_audit", PPID.siteAudit),
                    row("qualifications", PPID.libraryQualifications),
                    row("material_catalogue", PPID.libraryMaterials),
                    row("settings", PPID.settings),
                    row("help", PPID.help)
                ],
                optional: [
                    row("operatives", PPID.peopleOperatives),
                    row("wholesalers", PPID.libraryWholesalers),
                    row("invoicing", PPID.timesheets),
                    row("subcontractors", PPID.peopleSubcontractors),
                    row("manage_users", PPID.peopleManageUsers)
                ]
            )
        default:
            return (
                required: [
                    row("projects", PPID.projects),
                    row("small_works", PPID.smallWorks),
                    row("holiday", PPID.leave),
                    row("my_qualifications", PPID.libraryMyQualifications),
                    row("settings", PPID.settings)
                ],
                optional: [
                    row("site_audit", PPID.siteAudit),
                    row("invoicing", PPID.timesheets)
                ]
            )
        }
    }

    static func moreQuickCreate(role: String) -> (required: [PPButton], optional: [PPButton]) {
        let task = PPButton(id: PPID.moreQuick("task"), kind: .destination(PPID.tasks))
        switch role {
        case "admin":
            return (
                required: [task],
                optional: [
                    PPButton(id: PPID.moreQuick("project"), kind: .destination(PPID.projects)),
                    PPButton(id: PPID.moreQuick("smallWorks"), kind: .destination(PPID.smallWorks)),
                    PPButton(id: PPID.moreQuick("user"), kind: .destination(PPID.peopleAddUser))
                ]
            )
        case "manager":
            return (
                required: [task],
                optional: [
                    PPButton(id: PPID.moreQuick("project"), kind: .destination(PPID.projects)),
                    PPButton(id: PPID.moreQuick("smallWorks"), kind: .destination(PPID.smallWorks))
                ]
            )
        default:
            return (required: [task], optional: [])
        }
    }

    /// Identifiers a role must not see. Rules are from `UserStore` / `MainMenuCatalog` / `SettingsView`.
    static func hiddenIdentifiers(role: String) -> [String] {
        switch role {
        case "operative":
            return [
                PPID.mainMenuRow("manage_users"),
                PPID.mainMenuRow("add_user"),
                PPID.mainMenuRow("managers"),
                PPID.mainMenuRow("operatives"),
                PPID.mainMenuRow("job_types"),
                PPID.mainMenuRow("wholesalers"),
                PPID.mainMenuRow("material_catalogue"),
                PPID.mainMenuRow("site_map"),
                PPID.mainMenuRow("clients"),
                PPID.mainMenuRow("help"),
                PPID.mainMenuRow("edit_tab_bar"),
                PPID.mainMenuRow("subcontractors"),
                PPID.homeQuickAction("staff-managers"),
                PPID.homeQuickAction("staff-map"),
                PPID.settingsOrganisationHub,
                PPID.settingsPaymentRuns,
                PPID.moreQuick("user"),
                PPID.moreQuick("project")
            ]
        case "manager":
            return [
                PPID.mainMenuRow("managers"),
                PPID.mainMenuRow("site_map"),
                PPID.mainMenuRow("job_types"),
                PPID.mainMenuRow("add_user"),
                PPID.homeQuickAction("staff-managers"),
                PPID.homeQuickAction("staff-map"),
                PPID.settingsOrganisationHub,
                PPID.settingsPaymentRuns,
                PPID.moreQuick("user")
            ]
        default:
            return []
        }
    }

    static func signOut(on surface: String) -> PPButton {
        let id = surface == "more" ? PPID.moreRow("sign_out") : PPID.mainMenuRow("sign_out")
        return PPButton(id: id, kind: .signOut)
    }

    private static func quick(_ id: String, _ destination: String) -> PPButton {
        PPButton(id: PPID.homeQuickAction(id), kind: .destination(destination))
    }

    private static func row(_ id: String, _ destination: String) -> PPButton {
        PPButton(id: PPID.mainMenuRow(id), kind: .destination(destination))
    }

    static func moreCopy(of button: PPButton) -> PPButton {
        let id = button.id
            .replacingOccurrences(of: "mainMenu.row.", with: "more.row.")
        if id == button.id { return button }
        return PPButton(id: id, kind: button.kind)
    }
}
