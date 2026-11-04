//
//  Rulebook+SelfManageFlags.swift
//  Project Planner
//
//  RULEBOOK 1.30.2 (§8, §9, §16): a person's self-manage toggles (`annualLeaveSelfBook`, `timesheetSelfSign`) are
//  read for THIS organisation — web `lib/canonical/orgRoster.ts` `organizationSelfManageFlags`, called through
//  `CanonicalBusinessEngine`; nothing is decided here. The users document when it names this organisation, else the
//  membership here (`users/{uid}/orgMemberships/{orgId}`), else off; the creator both on. Never another company's
//  users document (the security rules `orgSelfManageFlag` read the same sources).
//

import Foundation

/// `organizationSelfManageFlags(...)` result.
nonisolated struct RulebookSelfManageFlags: Equatable, Sendable {
    var source: String
    var superAdmin: Bool
    var admin: Bool
    var active: Bool
    var annualLeaveSelfBook: Bool
    var timesheetSelfSign: Bool
}

extension CanonicalBusinessEngine {
    /// `organizationSelfManageFlags({ organizationId, userId, user, membership, creatorUserId })`. `user` and
    /// `membership` are the stored documents (Firestore values are converted to JSON first). Nil when the script did
    /// not answer.
    nonisolated static func organizationSelfManageFlags(
        organizationId: String,
        userId: String,
        user: [String: Any]?,
        membership: [String: Any]?,
        creatorUserId: String?
    ) -> RulebookSelfManageFlags? {
        let input: [String: Any] = [
            "organizationId": organizationId,
            "userId": userId,
            "user": user.map { FirebaseBackend.firestoreJSON($0) } ?? NSNull(),
            "membership": membership.map { FirebaseBackend.firestoreJSON($0) } ?? NSNull(),
            "creatorUserId": creatorUserId ?? NSNull()
        ]
        guard let row = callJSON("organizationSelfManageFlags", arguments: [input]) as? [String: Any] else { return nil }
        return RulebookSelfManageFlags(
            source: row["source"] as? String ?? "none",
            superAdmin: row["superAdmin"] as? Bool ?? false,
            admin: row["admin"] as? Bool ?? false,
            active: row["active"] as? Bool ?? true,
            annualLeaveSelfBook: row["annualLeaveSelfBook"] as? Bool ?? false,
            timesheetSelfSign: row["timesheetSelfSign"] as? Bool ?? false
        )
    }
}

extension AppUser {
    /// This profile with the self-manage toggles in effect for `organizationId` (`organizationSelfManageFlags`).
    /// When the script did not answer, both toggles are off: another company's toggles are never carried in.
    func applyingOrganizationSelfManageFlags(
        organizationId: String,
        userDocument: [String: Any]?,
        membership: [String: Any]?,
        creatorUserId: String?
    ) -> AppUser {
        let flags = CanonicalBusinessEngine.organizationSelfManageFlags(
            organizationId: organizationId,
            userId: id,
            user: userDocument,
            membership: membership,
            creatorUserId: creatorUserId
        )
        var out = self
        out.permissions.annualLeaveSelfBook = flags?.annualLeaveSelfBook ?? false
        out.permissions.timesheetSelfSign = flags?.timesheetSelfSign ?? false
        return out
    }
}
