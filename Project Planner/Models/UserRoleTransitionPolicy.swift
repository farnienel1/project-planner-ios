//
//  UserRoleTransitionPolicy.swift
//  Project Planner
//
//  Single place for “change user type” presets so Firestore user docs stay coherent
//  (role, permissions flags, and holiday behaviour) when promoting/demoting accounts.
//

import Foundation

enum ManagedAccountKind: String, CaseIterable, Identifiable {
    case operative
    case manager
    case administrator

    var id: String { rawValue }

    var title: String {
        switch self {
        case .operative: return "Operative"
        case .manager: return "Manager"
        case .administrator: return "Administrator"
        }
    }
}

struct ManagerUserTypeTransitionConfig: Equatable {
    var annualLeaveSelfBook: Bool
    var operatives: Bool
    var skills: Bool
    var qualifications: Bool
    var weeklyReports: Bool
    var subContractors: Bool
    var projects: Bool
    var smallWorks: Bool
}

struct OperativeUserTypeTransitionConfig: Equatable {
    var materials: Bool
    var siteAudit: Bool
}

enum UserRoleTransitionPolicy {

    /// Maps stored permissions to a coarse account kind for the Change user type UI.
    static func kind(for permissions: UserPermissions) -> ManagedAccountKind {
        if permissions.adminAccess { return .administrator }
        if permissions.manager && !permissions.operativeMode { return .manager }
        return .operative
    }

    /// Initial manager-toggle state when **Manager** is selected on the change-type sheet.
    static func managerConfigForSheet(current: UserPermissions, selectedKind: ManagedAccountKind) -> ManagerUserTypeTransitionConfig? {
        guard selectedKind == .manager else { return nil }
        let actual = kind(for: current)
        switch actual {
        case .manager:
            return ManagerUserTypeTransitionConfig(
                annualLeaveSelfBook: current.annualLeaveSelfBook,
                operatives: current.operatives,
                skills: current.skills,
                qualifications: current.qualifications,
                weeklyReports: current.weeklyReports,
                subContractors: current.subContractors,
                projects: current.projects,
                smallWorks: current.smallWorks
            )
        case .administrator:
            return ManagerUserTypeTransitionConfig(
                annualLeaveSelfBook: current.annualLeaveSelfBook,
                operatives: current.operatives,
                skills: current.skills,
                qualifications: current.qualifications,
                weeklyReports: current.weeklyReports,
                subContractors: current.subContractors,
                projects: current.projects,
                smallWorks: current.smallWorks
            )
        case .operative:
            // Match `AddUserView.applyPermissionsForInvitedType` for `.manager`.
            return ManagerUserTypeTransitionConfig(
                annualLeaveSelfBook: false,
                operatives: true,
                skills: true,
                qualifications: true,
                weeklyReports: false,
                subContractors: false,
                projects: true,
                smallWorks: true
            )
        }
    }

    /// Initial operative toggles when **Operative** is selected on the change-type sheet.
    static func operativeConfigForSheet(current: UserPermissions, selectedKind: ManagedAccountKind) -> OperativeUserTypeTransitionConfig? {
        guard selectedKind == .operative else { return nil }
        let actual = kind(for: current)
        if actual == .operative {
            return OperativeUserTypeTransitionConfig(materials: current.materials, siteAudit: current.siteAudit)
        }
        // Demoting from manager/admin — same defaults as Add user operative.
        return OperativeUserTypeTransitionConfig(materials: false, siteAudit: true)
    }

    /// Permissions bundle aligned with **Add user** defaults, while applying sheet choices for manager / operative.
    /// - Administrator: full manager-style capability flags; annual leave behaves like an admin in `HolidayView` (self-book via `hasAdminAccess`).
    static func permissions(
        for kind: ManagedAccountKind,
        carryingFrom current: UserPermissions,
        manager: ManagerUserTypeTransitionConfig?,
        operative: OperativeUserTypeTransitionConfig?
    ) -> UserPermissions {
        switch kind {
        case .operative:
            let op = operative ?? OperativeUserTypeTransitionConfig(materials: current.materials, siteAudit: current.siteAudit)
            return UserPermissions(
                adminAccess: false,
                manager: false,
                operatives: false,
                skills: false,
                qualifications: false,
                materials: op.materials,
                projects: true,
                smallWorks: true,
                operativeMode: true,
                annualLeaveSelfBook: false,
                weeklyReports: false,
                subContractors: false,
                siteAudit: op.siteAudit
            )
        case .manager:
            let m = manager ?? ManagerUserTypeTransitionConfig(
                annualLeaveSelfBook: current.annualLeaveSelfBook,
                operatives: true,
                skills: true,
                qualifications: true,
                weeklyReports: current.weeklyReports,
                subContractors: current.subContractors,
                projects: true,
                smallWorks: true
            )
            return UserPermissions(
                adminAccess: false,
                manager: true,
                operatives: m.operatives,
                skills: m.skills,
                qualifications: m.qualifications,
                materials: true,
                projects: m.projects,
                smallWorks: m.smallWorks,
                operativeMode: false,
                annualLeaveSelfBook: m.annualLeaveSelfBook,
                weeklyReports: m.weeklyReports,
                subContractors: m.subContractors,
                siteAudit: true
            )
        case .administrator:
            return UserPermissions(
                adminAccess: true,
                manager: true,
                operatives: true,
                skills: true,
                qualifications: true,
                materials: true,
                projects: true,
                smallWorks: true,
                operativeMode: false,
                annualLeaveSelfBook: true,
                weeklyReports: true,
                subContractors: true,
                siteAudit: true
            )
        }
    }

    /// User was on the “request / approval” holiday path and is moving to self-book (manager with self-book, or any administrator path).
    static func shouldClearPendingAnnualLeave(old: UserPermissions, new: UserPermissions) -> Bool {
        let oldRequestFlow = old.operativeMode
            || (old.manager && !old.adminAccess && !old.annualLeaveSelfBook)
        let newSelfBookFlow = !new.operativeMode && (new.adminAccess || new.annualLeaveSelfBook)
        return oldRequestFlow && newSelfBookFlow
    }
}
