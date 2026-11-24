//
//  WarningsRosterFingerprint.swift
//  Project Planner
//
//  Review of #274: the warnings scan reruns when the roster changes in a way the scan reads, never for a colleague's
//  `lastSeenAt` heartbeat, a push-token write or a profile photo. Load timing only: which warnings are listed is still
//  the rulebook's (`unbookedLabourRows`, `unverifiedOperativeRows`, `clashManagerIds`, `warningScopeFor`, …).
//
//  The fields are every `AppUser` field the scan passes to the rulebook: the people rows of `unbookedLabourRows` and
//  `rosterPeople` (`WarningsComputation.makeSnapshot`), the clash roster (`clashManagerIds`), unverified accounts
//  (`createdAt`, `passwordSet`), the warning scope's roster (`RulebookPeople.person`: level, permissions, line managers,
//  employment type, leave) and the names shown on rows. `documentUpdatedAt` counts only for a person who shares an
//  email with another roster row (the only place the scan reads it: the one-per-email fold of `rosterPeople`).
//

import Foundation

enum WarningsRosterFingerprint {
    static func value(_ users: [AppUser]) -> Int {
        var emailCounts: [String: Int] = [:]
        for user in users {
            emailCounts[user.email.lowercased().trimmingCharacters(in: .whitespacesAndNewlines), default: 0] += 1
        }
        var hasher = Hasher()
        hasher.combine(users.count)
        for user in users {
            hasher.combine(user.id)
            hasher.combine(user.email)
            hasher.combine(user.organizationId)
            hasher.combine(user.storedOrganizationId)
            hasher.combine(user.role)
            hasher.combine(user.storedRoleText)
            hasher.combine(user.storedLevelFlags)
            hasher.combine(user.permissions)
            hasher.combine(user.operativeModeStored)
            hasher.combine(user.isSuperAdmin)
            hasher.combine(user.isActive)
            hasher.combine(user.passwordSet)
            hasher.combine(user.status)
            hasher.combine(user.isGhost)
            hasher.combine(user.createdAt)
            hasher.combine(user.firstName)
            hasher.combine(user.surname)
            hasher.combine(user.documentName)
            hasher.combine(user.documentDisplayName)
            hasher.combine(user.formerUserIds)
            hasher.combine(user.sameEmailUserIds)
            hasher.combine(user.assignedManagerUserId)
            hasher.combine(user.assignedManagerUserIds)
            hasher.combine(user.hasNoLineManager)
            hasher.combine(user.employmentType)
            hasher.combine(user.employmentTypeTransitionFrom)
            hasher.combine(user.employmentTypeEffectiveAt)
            hasher.combine(user.annualLeaveEnabled)
            let emailKey = user.email.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
            if emailCounts[emailKey, default: 0] > 1 {
                hasher.combine(user.documentUpdatedAt)
            }
        }
        return hasher.finalize()
    }
}

/// Decides whether a roster publish asks for a warnings rescan: only when `WarningsRosterFingerprint` moved.
struct WarningsRosterRescanGate {
    private var lastFingerprint: Int?

    /// True when the roster differs, in a field the scan reads, from the last one seen (always true the first time).
    mutating func shouldRescan(for users: [AppUser]) -> Bool {
        let fingerprint = WarningsRosterFingerprint.value(users)
        defer { lastFingerprint = fingerprint }
        return fingerprint != lastFingerprint
    }
}
