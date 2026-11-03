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
    var dailyOverview: Bool
    var subContractors: Bool
    var projects: Bool
    var smallWorks: Bool
}

struct OperativeUserTypeTransitionConfig: Equatable {
    var materials: Bool
    var siteAudit: Bool
}

enum UserRoleTransitionPolicy {
    static let adminAccessLockedUntilAccountTypeChanges = "Change user type at the bottom of their profile, to enable admin level access."

    /// Maps stored permissions to a coarse account kind for the Change user type UI.
    static func kind(for permissions: UserPermissions) -> ManagedAccountKind {
        if permissions.adminAccess { return .administrator }
        if permissions.manager && !permissions.operativeMode { return .manager }
        return .operative
    }

    /// Initial manager-toggle state when **Manager** or **Administrator** is selected on the change-type sheet.
    static func managerConfigForSheet(current: UserPermissions, selectedKind: ManagedAccountKind) -> ManagerUserTypeTransitionConfig? {
        guard selectedKind == .manager || selectedKind == .administrator else { return nil }
        let actual = kind(for: current)
        switch actual {
        case .manager:
            return ManagerUserTypeTransitionConfig(
                annualLeaveSelfBook: current.annualLeaveSelfBook,
                operatives: current.operatives,
                skills: false,
                qualifications: current.qualifications,
                weeklyReports: current.weeklyReports,
                dailyOverview: current.dailyOverview,
                subContractors: current.subContractors,
                projects: current.projects,
                smallWorks: current.smallWorks
            )
        case .administrator:
            return ManagerUserTypeTransitionConfig(
                annualLeaveSelfBook: current.annualLeaveSelfBook,
                operatives: current.operatives,
                skills: false,
                qualifications: current.qualifications,
                weeklyReports: current.weeklyReports,
                dailyOverview: current.dailyOverview,
                subContractors: current.subContractors,
                projects: current.projects,
                smallWorks: current.smallWorks
            )
        case .operative:
            // Match `AddUserView.applyPermissionsForInvitedType` for `.manager`.
            return ManagerUserTypeTransitionConfig(
                annualLeaveSelfBook: false,
                operatives: false,
                skills: false,
                qualifications: true,
                weeklyReports: false,
                dailyOverview: true,
                subContractors: false,
                projects: false,
                smallWorks: false
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
    /// - Administrator: full manager-style capability flags; annual leave self-book follows the existing permission flag.
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
                skills: false,
                qualifications: true,
                weeklyReports: current.weeklyReports,
                dailyOverview: current.dailyOverview,
                subContractors: current.subContractors,
                projects: true,
                smallWorks: true
            )
            return UserPermissions(
                adminAccess: false,
                manager: true,
                operatives: m.operatives,
                skills: false,
                qualifications: m.qualifications,
                materials: true,
                projects: m.projects,
                smallWorks: m.smallWorks,
                operativeMode: false,
                annualLeaveSelfBook: m.annualLeaveSelfBook,
                weeklyReports: m.weeklyReports,
                dailyOverview: m.dailyOverview,
                subContractors: m.subContractors,
                siteAudit: true
            )
        case .administrator:
            let annualLeaveSelfBook = manager?.annualLeaveSelfBook ?? current.annualLeaveSelfBook
            return UserPermissions(
                adminAccess: true,
                manager: true,
                operatives: true,
                skills: false,
                qualifications: true,
                materials: true,
                projects: true,
                smallWorks: true,
                operativeMode: false,
                annualLeaveSelfBook: annualLeaveSelfBook,
                weeklyReports: true,
                dailyOverview: true,
                subContractors: true,
                siteAudit: true
            )
        }
    }

    /// User was on the self-book path and is moving to request/approval routing.
    /// `CanonicalBusinessEngine.canSelfBookAnnualLeave(user:roster:)` decides each side; pass the person's line managers and the roster
    /// so an admin who has an active line manager is not taken for a self-approved admin.
    static func shouldClearSelfBookedAnnualLeave(
        old: UserPermissions,
        new: UserPermissions,
        oldHasNoLineManager: Bool,
        newHasNoLineManager: Bool,
        oldLineManagerUserIds: [String] = [],
        newLineManagerUserIds: [String] = [],
        users: [AppUser] = []
    ) -> Bool {
        let oldUser = transitionUser("transition-old", permissions: old, hasNoLineManager: oldHasNoLineManager, lineManagerUserIds: oldLineManagerUserIds)
        let newUser = transitionUser("transition-new", permissions: new, hasNoLineManager: newHasNoLineManager, lineManagerUserIds: newLineManagerUserIds)
        return AnnualLeaveSelfBookPolicy.canSelfBookAnnualLeave(for: oldUser, users: users)
            && !AnnualLeaveSelfBookPolicy.canSelfBookAnnualLeave(for: newUser, users: users)
    }

    /// User was on the “request / approval” holiday path and is moving to self-book.
    static func shouldClearPendingAnnualLeave(
        old: UserPermissions,
        new: UserPermissions,
        oldHasNoLineManager: Bool = false,
        newHasNoLineManager: Bool = false,
        oldLineManagerUserIds: [String] = [],
        newLineManagerUserIds: [String] = [],
        users: [AppUser] = []
    ) -> Bool {
        let oldUser = transitionUser("transition-old", permissions: old, hasNoLineManager: oldHasNoLineManager, lineManagerUserIds: oldLineManagerUserIds)
        let newUser = transitionUser("transition-new", permissions: new, hasNoLineManager: newHasNoLineManager, lineManagerUserIds: newLineManagerUserIds)
        return AnnualLeaveSelfBookPolicy.usesAnnualLeaveRequestFlow(for: oldUser, users: users)
            && AnnualLeaveSelfBookPolicy.canSelfBookAnnualLeave(for: newUser, users: users)
    }

    private static func transitionUser(
        _ id: String,
        permissions: UserPermissions,
        hasNoLineManager: Bool,
        lineManagerUserIds: [String]
    ) -> AppUser {
        var user = AppUser(
            id: id,
            email: "",
            organizationId: "",
            role: .manager,
            permissions: permissions,
            hasNoLineManager: hasNoLineManager
        )
        if !hasNoLineManager && !lineManagerUserIds.isEmpty {
            user.setLineManagerUserIds(lineManagerUserIds)
        }
        return user
    }
}

/// Change user type read-back. After the write, the server copy of `users/{uid}` is read again and the screen
/// shows that copy. This only compares what was asked for with what is stored (`parseUserDocument` reads both
/// sides); it decides nothing about what a role may do.
enum UserTypeChangeReadBack {
    /// True when the stored document carries the role (when one was sent) and the account-type flags the save wrote.
    static func landed(expectedRole: UserRole?, expected: UserPermissions, stored: AppUser) -> Bool {
        if let expectedRole, stored.role != expectedRole { return false }
        return stored.permissions.adminAccess == expected.adminAccess
            && stored.permissions.manager == expected.manager
            && stored.permissions.operativeMode == expected.operativeMode
    }

    static func notSavedMessage(stored: AppUser) -> String {
        "The account type did not save. The server still has \(stored.fullName.isEmpty ? "this person" : stored.fullName) as \(stored.role.displayName). Nothing on this screen was changed."
    }

    /// The reason a write was refused, in words the person can act on.
    static func writeRefusedMessage(_ error: Error) -> String {
        let nsError = error as NSError
        if LaunchStartupPolicy.isPermissionDenied(
            domain: nsError.domain,
            code: nsError.code,
            description: nsError.localizedDescription
        ) {
            return "The server refused this change, so nothing was saved. Their profile may belong to another company, or your admin access may have changed."
        }
        return "Could not save the account type: \(error.localizedDescription). Nothing was changed."
    }
}

/// Edit User saves only what the editor changed: each flag that differs between the draft's starting copy and the
/// draft is laid over the stored copy; every other flag keeps its stored value. No rule is decided here.
enum UserPermissionsDraftMerge {
    static let flags: [WritableKeyPath<UserPermissions, Bool>] = [
        \.adminAccess, \.manager, \.operatives, \.skills, \.qualifications, \.materials, \.projects,
        \.smallWorks, \.operativeMode, \.annualLeaveSelfBook, \.weeklyReports, \.dailyOverview,
        \.subContractors, \.siteAudit, \.wholesalersOrderHistory,
    ]

    static func applyingEdits(from baseline: UserPermissions, to draft: UserPermissions, onto stored: UserPermissions) -> UserPermissions {
        var result = stored
        for flag in flags where draft[keyPath: flag] != baseline[keyPath: flag] {
            result[keyPath: flag] = draft[keyPath: flag]
        }
        return result
    }
}
