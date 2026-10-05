//
//  PPMidnightAppearance.swift
//  Project Planner — Midnight UI upgrade (UI ONLY)
//
//  Symbol and colour-family map for Home, Main Menu and More.
//  View layer only. Does not change which rows or tiles exist.
//

import SwiftUI

enum PPMidnightAppearance {

    static func quickActionSymbol(id: String, fallback: String) -> String {
        switch id {
        case "staff-weekly": return "doc.text.fill"
        case "staff-daily": return "calendar.badge.clock"
        case "staff-tasks": return "checklist"
        case "op-schedule", "staff-schedule": return "calendar"
        case "staff-invoicing": return "list.clipboard.fill"
        case "op-leave", "staff-leave", "staff-holiday": return "sun.max.fill"
        case "op-projects", "staff-projects": return "folder.fill"
        case "staff-clients": return "briefcase.fill"
        case "op-audit", "staff-audit": return "doc.viewfinder.fill"
        case "staff-map": return "map.fill"
        case "staff-help": return "questionmark.circle.fill"
        case "op-small", "staff-small": return "hammer.fill"
        case "staff-qualifications", "staff-my-qualifications": return "graduationcap.fill"
        case "staff-job-types": return "square.grid.2x2.fill"
        case "staff-wholesalers": return "building.2.fill"
        case "staff-material-catalogue": return "shippingbox.fill"
        case "staff-operatives": return "person.3.fill"
        case "staff-managers": return "person.badge.shield.checkmark.fill"
        case "staff-subs": return "person.2.badge.gearshape.fill"
        case "staff-add-user": return "person.fill.badge.plus"
        case "staff-manage-users": return "person.2.fill"
        case "op-settings", "staff-settings": return "gearshape.fill"
        default: return fallback
        }
    }

    static func quickActionFamily(id: String) -> PPFamily {
        switch id {
        case "staff-weekly", "staff-daily", "staff-tasks", "op-schedule", "staff-schedule",
             "staff-invoicing", "op-leave", "staff-leave", "staff-holiday":
            return .plan
        case "op-projects", "staff-projects", "staff-clients", "op-audit", "staff-audit",
             "staff-map", "staff-help":
            return .sites
        case "op-small", "staff-small", "staff-qualifications", "staff-my-qualifications",
             "staff-job-types", "staff-wholesalers", "staff-material-catalogue":
            return .trade
        case "staff-operatives", "staff-managers", "staff-subs", "staff-add-user", "staff-manage-users":
            return .people
        case "op-settings", "staff-settings":
            return .system
        default:
            return .system
        }
    }

    static func menuSymbol(rowId: String, fallback: String) -> String {
        switch rowId {
        case "edit_tab_bar": return "dock.arrow.down.rectangle"
        case "clients": return "briefcase.fill"
        case "projects": return "folder.fill"
        case "small_works": return "hammer.fill"
        case "operatives": return "person.3.fill"
        case "managers": return "person.badge.shield.checkmark.fill"
        case "holiday": return "sun.max.fill"
        case "site_map": return "map.fill"
        case "site_audit": return "doc.viewfinder.fill"
        case "invoicing": return "list.clipboard.fill"
        case "qualifications", "my_qualifications": return "graduationcap.fill"
        case "job_types": return "square.grid.2x2.fill"
        case "wholesalers": return "building.2.fill"
        case "material_catalogue": return "shippingbox.fill"
        case "subcontractors": return "person.2.badge.gearshape.fill"
        case "add_user": return "person.fill.badge.plus"
        case "manage_users": return "person.2.fill"
        case "settings": return "gearshape.fill"
        case "help": return "questionmark.circle.fill"
        case "reset_password": return "key.fill"
        case "sign_out": return "rectangle.portrait.and.arrow.right"
        default: return fallback
        }
    }

    static func menuFamily(rowId: String) -> PPFamily {
        switch rowId {
        case "holiday", "invoicing":
            return .plan
        case "clients", "projects", "site_map", "site_audit", "help":
            return .sites
        case "small_works", "qualifications", "my_qualifications", "job_types",
             "wholesalers", "material_catalogue":
            return .trade
        case "operatives", "managers", "subcontractors", "add_user", "manage_users":
            return .people
        default:
            return .system
        }
    }

    static func quickCreateSymbol(title: String, fallback: String) -> String {
        switch title {
        case "Project": return "folder.fill.badge.plus"
        case "Small work": return "hammer.fill"
        case "User": return "person.fill.badge.plus"
        case "Task": return "checklist"
        default: return fallback
        }
    }

    static func quickCreateFamily(title: String) -> PPFamily {
        switch title {
        case "Project": return .sites
        case "Small work": return .trade
        case "User": return .people
        case "Task": return .plan
        default: return .system
        }
    }
}
