//
//  Rulebook+OrgLineManagers.swift
//  Project Planner
//
//  RULEBOOK 1.88.0 §8, §11 "Line managers per organisation" (owner decision 24 Nov, before launch; review of web #455
//  fix (a)): a member whose home is another company has this company's own line manager in its own record,
//  `organizations/{orgId}/memberLineManagers/{uid}` (only `assignedManagerUserIds`, `assignedManagerUserId`,
//  `hasNoLineManager` plus write metadata), written by this company's admins and read by every active member. Never on
//  the membership (the rules refuse a `lineManager` key there). Which fields apply in an organisation
//  (`organizationLineManagerFields`), where an edit is saved (`orgLineManagerEditTarget`), the record a save writes
//  (`memberLineManagerWriteFields`) and how the records are read (`parseMemberLineManagerDocuments`) come from the
//  packed script through `CanonicalBusinessEngine.callJSON`. Swift only maps Firestore data and `AppUser` rows in and
//  out. In their home company, and wherever this company holds no record for them, a person reads their users
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
    /// `MEMBER_LINE_MANAGERS_COLLECTION` (same text as the rulebook constant; `OrgLineManagersTests` checks it).
    static let memberLineManagersCollection = "memberLineManagers"

    /// `organizationLineManagerFields`: the person's line-manager fields in `organizationId` and where they came from
    /// (`users` / `record`). `record` is the data of `memberLineManagers/{uid}` here (nil: none / not read). Only plain
    /// values reach the script. Nil when the script did not answer.
    nonisolated static func organizationLineManagerFields(
        organizationId: String,
        homeOrganizationId: String?,
        assignedManagerUserIds: [String],
        assignedManagerUserId: String?,
        hasNoLineManager: Bool,
        record: [String: Any]?
    ) -> (source: String, ids: [String], single: String?, hasNoLineManager: Bool)? {
        var user: [String: Any] = [
            "assignedManagerUserIds": assignedManagerUserIds,
            "hasNoLineManager": hasNoLineManager,
        ]
        if let home = homeOrganizationId, !home.isEmpty { user["organizationId"] = home }
        if let single = assignedManagerUserId { user["assignedManagerUserId"] = single }
        let recordInput: Any
        if let record {
            recordInput = plainLineManagerMap(record)
        } else {
            recordInput = NSNull()
        }
        let input: [String: Any] = ["organizationId": organizationId, "user": user, "record": recordInput]
        guard let row = callJSON("organizationLineManagerFields", arguments: [input]) as? [String: Any] else { return nil }
        return (
            (row["source"] as? String) ?? "users",
            (row["assignedManagerUserIds"] as? [String]) ?? [],
            row["assignedManagerUserId"] as? String,
            (row["hasNoLineManager"] as? Bool) ?? false
        )
    }

    /// `orgLineManagerEditTarget`: `users` (home company), `record` (any other), or nil (unknown home: refuse).
    nonisolated static func orgLineManagerEditTarget(organizationId: String?, homeOrganizationId: String?) -> String? {
        let input: [String: Any] = [
            "organizationId": organizationId ?? "",
            "homeOrganizationId": homeOrganizationId.map { $0 as Any } ?? NSNull(),
        ]
        return callJSON("orgLineManagerEditTarget", arguments: [input]) as? String
    }

    /// `memberLineManagerWriteFields`: the whole `memberLineManagers/{uid}` record an admin writes (the three keys,
    /// `updatedBy`, `updatedFrom: ios`). The caller adds the server `updatedAt`. `assignedManagerUserId` comes back as
    /// `NSNull` when there is none (stored as null). Nil when the script did not answer.
    nonisolated static func memberLineManagerWriteFields(
        assignedManagerUserIds: [String],
        assignedManagerUserId: String?,
        hasNoLineManager: Bool,
        writerUserId: String?
    ) -> [String: Any]? {
        var input: [String: Any] = [
            "assignedManagerUserIds": assignedManagerUserIds,
            "assignedManagerUserId": assignedManagerUserId.map { $0 as Any } ?? NSNull(),
            "hasNoLineManager": hasNoLineManager,
            "platform": "ios",
        ]
        if let writerUserId, !writerUserId.isEmpty { input["writerUserId"] = writerUserId }
        return callJSON("memberLineManagerWriteFields", arguments: [input]) as? [String: Any]
    }

    /// `parseMemberLineManagerDocuments`: the open organisation's records (`memberLineManagers` documents) as lower-case
    /// users id → the three line-manager keys. Records holding none of the three keys are left out. Only plain values
    /// reach the script (`updatedAt` and other metadata are dropped first). Empty when the script did not answer.
    nonisolated static func parseMemberLineManagerDocuments(_ docs: [(id: String, data: [String: Any])]) -> [String: [String: Any]] {
        let input: [[String: Any]] = docs.map { ["id": $0.id, "data": plainLineManagerMap($0.data)] }
        guard let parsed = callJSON("parseMemberLineManagerDocuments", arguments: [input]) as? [String: Any] else { return [:] }
        var out: [String: [String: Any]] = [:]
        for (key, value) in parsed {
            if let fields = value as? [String: Any] { out[key.lowercased()] = fields }
        }
        return out
    }

    /// `ORG_LINE_MANAGER_HOME_UNKNOWN_MESSAGE` (same text as the rulebook constant).
    static let orgLineManagerHomeUnknownMessage = "Couldn't check this person's company — try saving the line manager again."

    /// The record (or any map) with only the three line-manager keys, in JSON-safe values (strings, string lists,
    /// booleans, null). Keys that are absent stay absent, so `parseOrgLineManager` still reads "none of the keys" as no
    /// record.
    nonisolated private static func plainLineManagerMap(_ map: [String: Any]) -> [String: Any] {
        var out: [String: Any] = [:]
        if let ids = map["assignedManagerUserIds"] as? [Any] {
            out["assignedManagerUserIds"] = ids.compactMap { $0 as? String }
        } else if map.keys.contains("assignedManagerUserIds") {
            out["assignedManagerUserIds"] = NSNull()
        }
        if let single = map["assignedManagerUserId"] as? String {
            out["assignedManagerUserId"] = single
        } else if map.keys.contains("assignedManagerUserId") {
            out["assignedManagerUserId"] = NSNull()
        }
        if let none = map["hasNoLineManager"] as? Bool {
            out["hasNoLineManager"] = none
        } else if map.keys.contains("hasNoLineManager") {
            out["hasNoLineManager"] = NSNull()
        }
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
    /// is the users document's stored company (`storedOrganizationId`); `record` this company's
    /// `memberLineManagers/{uid}` data (nil: none). The same value when nothing changes or the script did not answer.
    static func apply(
        _ user: AppUser,
        organizationId: String,
        homeOrganizationId: String?,
        record: [String: Any]?
    ) -> AppUser {
        let base = accountFields(user)
        guard let fields = CanonicalBusinessEngine.organizationLineManagerFields(
            organizationId: organizationId,
            homeOrganizationId: homeOrganizationId,
            assignedManagerUserIds: base.ids,
            assignedManagerUserId: base.single,
            hasNoLineManager: base.hasNoLineManager,
            record: record
        ) else { return user }
        var out = user
        if fields.source == "record" {
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

    /// Rows with this company's records laid over (`records`: lower-case users id → record fields, from
    /// `parseMemberLineManagerDocuments`). Home-company people are never changed; a row whose record went away (or an
    /// empty `organizationId`, no company open) goes back to its users document. Nil when nothing changes.
    static func apply(_ users: [AppUser], organizationId: String, records: [String: [String: Any]]) -> [AppUser]? {
        guard !users.isEmpty else { return nil }
        var changed = false
        var out = users
        for index in users.indices {
            let user = users[index]
            let record = organizationId.isEmpty ? nil : records[user.id.lowercased()]
            guard record != nil || user.orgLineManagerOverlay != nil else { continue }
            let next = apply(user, organizationId: organizationId, homeOrganizationId: user.storedOrganizationId, record: record)
            if next != user {
                out[index] = next
                changed = true
            }
        }
        return changed ? out : nil
    }
}
