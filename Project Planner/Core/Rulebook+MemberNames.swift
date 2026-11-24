//
//  Rulebook+MemberNames.swift
//  Project Planner
//
//  RULEBOOK 1.81.0 §11 "Names per organisation" (owner decision 24 Nov): one account may have a different name in
//  each company — `organizations/{orgId}/memberNames/{uid}` `{ firstName, surname }`. Which entry names a person
//  (`applyMemberNames` / `memberNameFor`), where an edit is saved (`memberNameEditTarget`), the write shape
//  (`memberNameWriteFields`) and who may write it (`canWriteMemberName`) all come from the packed script through
//  `CanonicalBusinessEngine.callJSON`. Swift only maps Firestore data and `AppUser` rows in and out.
//

import Foundation

/// The organisation name laid over an `AppUser` and the users document's own name under it (not written, not encoded).
struct OrgNameOverlay: Hashable {
    var firstName: String
    var surname: String
    var accountFirstName: String
    var accountSurname: String
}

extension CanonicalBusinessEngine {
    static let memberNamesCollection = "memberNames"

    /// `parseMemberNameDocuments`: lower-case users id → `{ firstName, surname }`. Only the two name strings are passed
    /// to the script (Firestore timestamps are not JSON). Empty when the script did not answer.
    nonisolated static func parseMemberNames(_ docs: [(id: String, data: [String: Any])]) -> [String: [String: String]] {
        let rows: [[String: Any]] = docs.map { doc in
            ["id": doc.id, "data": [
                "firstName": (doc.data["firstName"] as? String) ?? "",
                "surname": (doc.data["surname"] as? String) ?? "",
                "lastName": (doc.data["lastName"] as? String) ?? "",
            ]]
        }
        guard let parsed = callJSON("parseMemberNameDocuments", arguments: [rows]) as? [String: Any] else { return [:] }
        var out: [String: [String: String]] = [:]
        for (key, value) in parsed {
            guard let row = value as? [String: Any] else { continue }
            out[key] = ["userId": (row["userId"] as? String) ?? key, "firstName": (row["firstName"] as? String) ?? "", "surname": (row["surname"] as? String) ?? ""]
        }
        return out
    }

    /// `memberNameEditTarget`: `account` (the users document, the person's home organisation) or `organization`.
    /// Nil when the script did not answer (callers then save as before 1.81.0).
    nonisolated static func memberNameEditTarget(organizationId: String?, homeOrganizationId: String?) -> String? {
        callJSON("memberNameEditTarget", arguments: [["organizationId": organizationId ?? "", "homeOrganizationId": homeOrganizationId ?? ""]]) as? String
    }

    /// `memberNameWriteFields` (without `updatedAt`, which the caller adds as a server timestamp). Nil when refused.
    nonisolated static func memberNameWriteFields(firstName: String, surname: String, writerUserId: String?) -> [String: Any]? {
        callJSON("memberNameWriteFields", arguments: [[
            "firstName": firstName, "surname": surname, "writerUserId": writerUserId ?? "", "platform": "ios",
        ]]) as? [String: Any]
    }

    /// `memberNameValidationError`: the message, or nil when the name may be saved.
    nonisolated static func memberNameValidationError(firstName: String, surname: String) -> String? {
        callJSON("memberNameValidationError", arguments: [["firstName": firstName, "surname": surname]]) as? String
    }

    /// `canWriteMemberName` (1.82.0: an Operatives manager for an operative, `writerManagesOperative`). False when the
    /// script did not answer.
    nonisolated static func canWriteMemberName(writerUserId: String?, subjectUserId: String, writerIsAdmin: Bool, writerManagesOperative: Bool = false) -> Bool {
        (callJSON("canWriteMemberName", arguments: [[
            "writerUserId": writerUserId ?? "", "subjectUserId": subjectUserId, "writerIsAdmin": writerIsAdmin,
            "writerManagesOperative": writerManagesOperative,
        ]]) as? Bool) ?? false
    }

    /// RULEBOOK 1.82.0 §11 `memberNameEditPlan`: every edit writes the open organisation's entry (`writeEntry`); only the
    /// person's home organisation also the users document (`writeAccount`). Nil when the script did not answer.
    nonisolated static func memberNameEditPlan(organizationId: String?, homeOrganizationId: String?) -> (writeEntry: Bool, writeAccount: Bool)? {
        guard let row = callJSON("memberNameEditPlan", arguments: [["organizationId": organizationId ?? "", "homeOrganizationId": homeOrganizationId ?? ""]]) as? [String: Any],
              let entry = row["writeEntry"] as? Bool, let account = row["writeAccount"] as? Bool else { return nil }
        return (entry, account)
    }

    /// RULEBOOK 1.82.0 §11 `memberNameEntryMissing`: the signed-in person has no entry here yet (server read only).
    nonisolated static func memberNameEntryMissing(userId: String, aliases: [String], names: [String: [String: String]], serverRead: Bool) -> Bool {
        let entries: [String: Any] = names.mapValues { row in
            ["userId": row["userId"] ?? "", "firstName": row["firstName"] ?? "", "surname": row["surname"] ?? "",
             "displayName": "\(row["firstName"] ?? "") \(row["surname"] ?? "")".trimmingCharacters(in: .whitespaces)]
        }
        return (callJSON("memberNameEntryMissing", arguments: [[
            "person": ["id": userId, "formerUserIds": aliases], "names": entries, "serverRead": serverRead,
        ]]) as? Bool) ?? false
    }

    /// RULEBOOK 1.82.0 §11 `memberNameJoinEntry`: the first candidate name that is a valid entry. Nil when none.
    nonisolated static func memberNameJoinEntry(_ candidates: [(firstName: String, surname: String)]) -> (firstName: String, surname: String)? {
        let rows: [[String: Any]] = candidates.map { ["firstName": $0.firstName, "surname": $0.surname] }
        guard let row = callJSON("memberNameJoinEntry", arguments: [rows]) as? [String: Any] else { return nil }
        return ((row["firstName"] as? String) ?? "", (row["surname"] as? String) ?? "")
    }

    /// `MEMBER_NAME_REFUSED_MESSAGE`.
    nonisolated static var memberNameRefusedMessage: String {
        constant("MEMBER_NAME_REFUSED_MESSAGE", as: String.self) ?? "Only an admin can change this person's name in this company."
    }

    /// The organisation names `applyMemberNames` gives these people (by index), from their users-document names.
    /// Nil when the script did not answer.
    nonisolated static func memberNamesFor(_ people: [(id: String, firstName: String, surname: String, aliases: [String])], names: [String: [String: String]]) -> [(firstName: String, surname: String)]? {
        guard !names.isEmpty else { return people.map { ($0.firstName, $0.surname) } }
        let rows: [[String: Any]] = people.map { ["id": $0.id, "firstName": $0.firstName, "surname": $0.surname, "formerUserIds": $0.aliases] }
        let entries: [String: Any] = names.mapValues { row in
            ["userId": row["userId"] ?? "", "firstName": row["firstName"] ?? "", "surname": row["surname"] ?? "",
             "displayName": "\(row["firstName"] ?? "") \(row["surname"] ?? "")".trimmingCharacters(in: .whitespaces)]
        }
        guard let out = callJSON("applyMemberNames", arguments: [rows, entries]) as? [[String: Any]], out.count == people.count else { return nil }
        return out.map { (($0["firstName"] as? String) ?? "", ($0["surname"] as? String) ?? "") }
    }
}

/// Lays an organisation's `memberNames` entries over `AppUser` rows (RULEBOOK 1.81.0 §11). The entry that applies is
/// the script's (`CanonicalBusinessEngine.memberNamesFor`); this only keeps the users document's name under it so the
/// overlay can be undone and a later edit of the name is never reverted (the web `memberNameOverlay` does the same).
enum MemberNameOverlay {
    /// The users document's own name under any organisation name laid over this user.
    static func accountName(_ user: AppUser) -> (firstName: String, surname: String) {
        if let mark = user.orgNameOverlay, user.firstName == mark.firstName, user.surname == mark.surname {
            return (mark.accountFirstName, mark.accountSurname)
        }
        return (user.firstName, user.surname)
    }

    /// The users with the entries laid over. Returns nil when nothing changes (or the script did not answer).
    static func apply(_ users: [AppUser], names: [String: [String: String]]) -> [AppUser]? {
        guard !users.isEmpty else { return nil }
        if names.isEmpty && !users.contains(where: { $0.orgNameOverlay != nil }) { return nil }
        let bases = users.map(accountName)
        let input = users.enumerated().map { index, user in
            (id: user.id, firstName: bases[index].firstName, surname: bases[index].surname, aliases: user.formerUserIds + user.sameEmailUserIds)
        }
        guard let shown = CanonicalBusinessEngine.memberNamesFor(input, names: names) else { return nil }
        var changed = false
        var out = users
        for index in users.indices {
            let base = bases[index]
            let name = shown[index]
            var user = users[index]
            if name.firstName == base.firstName && name.surname == base.surname {
                // No entry (or one equal to the users document's name): the users document's name, no mark.
                if user.orgNameOverlay != nil || user.firstName != base.firstName || user.surname != base.surname {
                    user.firstName = base.firstName
                    user.surname = base.surname
                    user.orgNameOverlay = nil
                }
            } else {
                let mark = OrgNameOverlay(firstName: name.firstName, surname: name.surname, accountFirstName: base.firstName, accountSurname: base.surname)
                if user.orgNameOverlay != mark || user.firstName != name.firstName || user.surname != name.surname {
                    user.firstName = name.firstName
                    user.surname = name.surname
                    user.orgNameOverlay = mark
                }
            }
            if user != users[index] {
                out[index] = user
                changed = true
            }
        }
        return changed ? out : nil
    }
}
