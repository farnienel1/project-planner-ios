//
//  Rulebook+OrgRoster.swift
//  Project Planner
//
//  Rulebook 1.11.0 (docs/RULEBOOK.md §1, §11, §14): who is on an organisation's roster and at what level. Web
//  `lib/canonical/orgRoster.ts` (`organizationLevelFor`, `rosterMembersForOrganization`), called through
//  `CanonicalBusinessEngine`. A person whose `users/{uid}.organizationId` names another company keeps their level in
//  this organisation from their membership, else the `members` role — never another company's flags; the creator is
//  always this organisation's super admin. Nothing is decided here.
//

import Foundation

/// `OrgRosterLevel`.
nonisolated struct RulebookOrgRosterLevel: Equatable, Sendable {
    var level: RulebookPermissionLevel
    var isSuperAdmin: Bool
    /// `users` | `membership` | `members` | `creator`.
    var source: String
}

extension CanonicalBusinessEngine {
    /// `organizationLevelFor({ organizationId, userId, user, membership, membersRole, creatorUserId })`. Nil when the
    /// script did not answer.
    nonisolated static func organizationLevelFor(
        organizationId: String,
        userId: String,
        user: [String: Any]?,
        membership: [String: Any]?,
        membersRole: String?,
        creatorUserId: String?
    ) -> RulebookOrgRosterLevel? {
        var input: [String: Any] = ["organizationId": organizationId, "userId": userId]
        if let user { input["user"] = user }
        if let membership { input["membership"] = membership }
        if let membersRole { input["membersRole"] = membersRole }
        if let creatorUserId { input["creatorUserId"] = creatorUserId }
        guard let row = callJSON("organizationLevelFor", arguments: [input]) as? [String: Any],
              let level = (row["level"] as? String).flatMap(RulebookPermissionLevel.init(rawValue:)) else { return nil }
        return RulebookOrgRosterLevel(level: level, isSuperAdmin: row["isSuperAdmin"] as? Bool ?? false, source: row["source"] as? String ?? "users")
    }

    /// `rosterMembersForOrganization(...)` → `anchoredIds` and `unreadIds` (the people this device must keep on the
    /// roster even when their document could not be read). Nil when the script did not answer.
    nonisolated static func rosterAnchors(
        organizationId: String,
        userDocuments: [[String: Any]],
        members: [String: Any],
        creatorUserId: String?,
        signedInUserId: String?,
        missingIds: [String]
    ) -> (anchoredIds: [String], unreadIds: [String])? {
        var input: [String: Any] = [
            "organizationId": organizationId,
            "users": userDocuments,
            "members": members,
            "missingIds": missingIds,
        ]
        if let creatorUserId { input["creatorUserId"] = creatorUserId }
        if let signedInUserId { input["signedInUserId"] = signedInUserId }
        guard let row = callJSON("rosterMembersForOrganization", arguments: [input]) as? [String: Any] else { return nil }
        return (row["anchoredIds"] as? [String] ?? [], row["unreadIds"] as? [String] ?? [])
    }
}

extension AppUser {
    /// This person shown at `level` in the open organisation (`organizationLevelFor`). Only the in-memory roster row
    /// changes; their users document (another company's) is never rewritten from it.
    func atOrganizationLevel(_ level: RulebookOrgRosterLevel) -> AppUser {
        var user = self
        switch level.level {
        case .admin:
            user.role = .admin
            user.permissions.adminAccess = true
            user.permissions.operativeMode = false
        case .manager:
            user.role = .manager
            user.permissions.adminAccess = false
            user.permissions.manager = true
            user.permissions.operativeMode = false
        case .operative:
            user.role = .operative
            user.permissions.adminAccess = false
            user.permissions.manager = false
            user.permissions.operativeMode = true
        }
        user.isSuperAdmin = level.isSuperAdmin
        return user
    }
}
