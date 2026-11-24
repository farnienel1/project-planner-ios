//
//  Rulebook+OrgLineManagers.swift
//  Project Planner
//
//  RULEBOOK 1.88.0 §8, §11 "Line managers per organisation" (owner decision 24 Nov, before launch): a member whose home
//  is another company has this company's own line manager on their membership here
//  (`users/{uid}/orgMemberships/{orgId}.lineManager`), written by this company's admins. Which fields apply in an
//  organisation (`organizationLineManagerFields`) and where an edit is saved (`orgLineManagerEditTarget`) come from the
//  packed script through `CanonicalBusinessEngine.callJSON`. Swift only maps Firestore data and `AppUser` rows in and
//  out. In their home company, and wherever the membership holds no `lineManager` map, a person reads their users
//  document's line manager exactly as before (guardrail 3).
//

import Foundation

/// The users document's own line-manager fields under an organisation line manager laid over an `AppUser`.
struct OrgLineManagerMark: Hashable {
    var accountIds: [String]
    var accountSingle: String?
    var accountHasNoLineManager: Bool
}

extension CanonicalBusinessEngine {
    /// The membership field (`ORG_MEMBERSHIP_LINE_MANAGER_FIELD`).
    static let orgMembershipLineManagerField = "lineManager"

    /// `organizationLineManagerFields`: the person's line-manager fields in `organizationId` and where they came from
    /// (`users` / `membership`). Only plain values reach the script (the `lineManager` map is strings and booleans).
    /// Nil when the script did not answer.
    nonisolated static func organizationLineManagerFields(
        organizationId: String,
        homeOrganizationId: String?,
        assignedManagerUserIds: [String],
        assignedManagerUserId: String?,
        hasNoLineManager: Bool,
        membership: [String: Any]?
    ) -> (source: String, ids: [String], single: String?, hasNoLineManager: Bool)? {
        var user: [String: Any] = [
            "assignedManagerUserIds": assignedManagerUserIds,
            "hasNoLineManager": hasNoLineManager,
        ]
        if let home = homeOrganizationId, !home.isEmpty { user["organizationId"] = home }
        if let single = assignedManagerUserId { user["assignedManagerUserId"] = single }
        var membershipInput: Any = NSNull()
        if let map = membership?["lineManager"] as? [String: Any] {
            membershipInput = ["lineManager": plainLineManagerMap(map)]
        } else if membership != nil {
            membershipInput = [String: Any]()
        }
        let input: [String: Any] = ["organizationId": organizationId, "user": user, "membership": membershipInput]
        guard let row = callJSON("organizationLineManagerFields", arguments: [input]) as? [String: Any] else { return nil }
        return (
            (row["source"] as? String) ?? "users",
            (row["assignedManagerUserIds"] as? [String]) ?? [],
            row["assignedManagerUserId"] as? String,
            (row["hasNoLineManager"] as? Bool) ?? false
        )
    }

    /// `orgLineManagerEditTarget`: `users` (home company), `membership` (any other), or nil (unknown home: refuse).
    nonisolated static func orgLineManagerEditTarget(organizationId: String?, homeOrganizationId: String?) -> String? {
        let input: [String: Any] = [
            "organizationId": organizationId ?? "",
            "homeOrganizationId": homeOrganizationId.map { $0 as Any } ?? NSNull(),
        ]
        return callJSON("orgLineManagerEditTarget", arguments: [input]) as? String
    }

    /// `ORG_LINE_MANAGER_NO_MEMBERSHIP_MESSAGE` (same text as the rulebook constant).
    static let orgLineManagerNoMembershipMessage =
        "This person's company record here could not be found, so their line manager can't be saved yet. Ask them to open this company in the app once, then try again."

    /// `ORG_LINE_MANAGER_HOME_UNKNOWN_MESSAGE` (same text as the rulebook constant).
    static let orgLineManagerHomeUnknownMessage = "Couldn't check this person's company — try saving the line manager again."

    /// The `lineManager` map with only JSON-safe values (strings, string lists, booleans).
    nonisolated private static func plainLineManagerMap(_ map: [String: Any]) -> [String: Any] {
        var out: [String: Any] = [:]
        if let ids = map["assignedManagerUserIds"] as? [Any] { out["assignedManagerUserIds"] = ids.compactMap { $0 as? String } }
        if let single = map["assignedManagerUserId"] as? String { out["assignedManagerUserId"] = single }
        if let none = map["hasNoLineManager"] as? Bool { out["hasNoLineManager"] = none }
        return out
    }
}

/// Lays this organisation's line manager (RULEBOOK 1.88.0) over `AppUser` rows whose home is another company. The
/// users document's own fields are kept in `orgLineManagerOverlay` so the overlay can be undone.
enum OrgLineManagerOverlay {
    /// The users document's own line-manager fields under any organisation line manager laid over `user`.
    static func accountFields(_ user: AppUser) -> (ids: [String], single: String?, hasNoLineManager: Bool) {
        if let mark = user.orgLineManagerOverlay {
            return (mark.accountIds, mark.accountSingle, mark.accountHasNoLineManager)
        }
        return (user.assignedManagerUserIds, user.assignedManagerUserId, user.hasNoLineManager)
    }

    /// `user` with the line manager of `organizationId` laid over (`organizationLineManagerFields`). `homeOrganizationId`
    /// is the users document's stored company (`storedOrganizationId`). The same value when nothing changes or the
    /// script did not answer.
    static func apply(
        _ user: AppUser,
        organizationId: String,
        homeOrganizationId: String?,
        membership: [String: Any]?
    ) -> AppUser {
        let base = accountFields(user)
        guard let fields = CanonicalBusinessEngine.organizationLineManagerFields(
            organizationId: organizationId,
            homeOrganizationId: homeOrganizationId,
            assignedManagerUserIds: base.ids,
            assignedManagerUserId: base.single,
            hasNoLineManager: base.hasNoLineManager,
            membership: membership
        ) else { return user }
        var out = user
        if fields.source == "membership" {
            out.assignedManagerUserIds = fields.ids
            out.assignedManagerUserId = fields.single
            out.hasNoLineManager = fields.hasNoLineManager
            out.orgLineManagerOverlay = OrgLineManagerMark(
                accountIds: base.ids,
                accountSingle: base.single,
                accountHasNoLineManager: base.hasNoLineManager
            )
        } else if user.orgLineManagerOverlay != nil {
            out.assignedManagerUserIds = base.ids
            out.assignedManagerUserId = base.single
            out.hasNoLineManager = base.hasNoLineManager
            out.orgLineManagerOverlay = nil
        }
        return out
    }

    /// Rows with each visiting member's membership here laid over (`memberships`: lower-case users id → membership
    /// data). Home-company people are never changed. Nil when nothing changes.
    static func apply(_ users: [AppUser], organizationId: String, memberships: [String: [String: Any]]) -> [AppUser]? {
        guard !users.isEmpty, !organizationId.isEmpty else { return nil }
        var changed = false
        var out = users
        for index in users.indices {
            let user = users[index]
            let membership = memberships[user.id.lowercased()]
            guard membership != nil || user.orgLineManagerOverlay != nil else { continue }
            let next = apply(user, organizationId: organizationId, homeOrganizationId: user.storedOrganizationId, membership: membership)
            if next != user {
                out[index] = next
                changed = true
            }
        }
        return changed ? out : nil
    }
}
