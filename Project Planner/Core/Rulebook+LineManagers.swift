//
//  Rulebook+LineManagers.swift
//  Project Planner
//
//  Rulebook 1.11.0 (docs/RULEBOOK.md §8, §11): line manager pickers and labels on Add User and Edit User. Web
//  `lib/canonical/lineManagers.ts`, called through `CanonicalBusinessEngine`:
//    - `lineManagerCandidates(person, roster)`: who may be picked;
//    - `lineManagerOptions(person)`: whether "No line manager" is offered (admins only);
//    - `lineManagerSummary(person, roster)`: the label ("Unknown person" for an unknown id, "+N more" only for N ≥ 1);
//    - `lineManagerSelectedIds(person, roster)` (1.14.0): the picker's selection, a stored id on a folded-away
//      duplicate of a person mapped onto that person's one option.
//  Nothing is decided here.
//

import Foundation

/// One `lineManagerCandidates` row.
nonisolated struct RulebookLineManagerCandidate: Equatable, Sendable {
    var id: String
    var name: String
    var level: String
}

/// `lineManagerOptions(person)`.
nonisolated struct RulebookLineManagerOptions: Equatable, Sendable {
    var required: Bool
    var allowsNoLineManager: Bool
    var noLineManagerLabel: String
    var noLineManagerHelp: String
}

extension CanonicalBusinessEngine {
    /// `lineManagerCandidates(person, roster)`. Nil when the script did not answer.
    nonisolated static func lineManagerCandidates(person: [String: Any], roster: [[String: Any]]) -> [RulebookLineManagerCandidate]? {
        guard let rows = callJSON("lineManagerCandidates", arguments: [person, roster]) as? [[String: Any]] else { return nil }
        return rows.compactMap { row in
            guard let id = row["id"] as? String else { return nil }
            return RulebookLineManagerCandidate(id: id, name: row["name"] as? String ?? "", level: row["level"] as? String ?? "manager")
        }
    }

    /// `INVITE_DRAFT_PERSON_ID` (rulebook 1.27.0 §11): the id Add User gives the invite before it has a document.
    nonisolated static var inviteDraftPersonId: String {
        constant("INVITE_DRAFT_PERSON_ID", as: String.self) ?? "invite-draft"
    }

    /// `inviteDraftLineManagerSubject({ email, level })` (rulebook 1.27.0 §11) → its `email`: the typed email as the
    /// shared rule reads it (trimmed, lower case), so `personIdSet` reaches the roster rows on it and the invitee is
    /// never offered as their own line manager. Falls back to the same trim and lower case when the script did not answer.
    nonisolated static func inviteDraftLineManagerEmail(email: String, level: String) -> String {
        let input: [String: Any] = ["email": email, "level": level]
        if let row = callJSON("inviteDraftLineManagerSubject", arguments: [input]) as? [String: Any],
           let normalized = row["email"] as? String {
            return normalized
        }
        return email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// `lineManagerOptions(person)`. Nil when the script did not answer.
    nonisolated static func lineManagerOptions(person: [String: Any]) -> RulebookLineManagerOptions? {
        guard let row = callJSON("lineManagerOptions", arguments: [person]) as? [String: Any],
              let allows = row["allowsNoLineManager"] as? Bool else { return nil }
        return RulebookLineManagerOptions(
            required: row["required"] as? Bool ?? !allows,
            allowsNoLineManager: allows,
            noLineManagerLabel: row["noLineManagerLabel"] as? String ?? "No line manager",
            noLineManagerHelp: row["noLineManagerHelp"] as? String ?? ""
        )
    }

    /// `lineManagerSelectedIds(person, roster)` (rulebook 1.14.0 §11): the stored line managers as picker option ids,
    /// one per person. Nil when the script did not answer.
    nonisolated static func lineManagerSelectedIds(person: [String: Any], roster: [[String: Any]]) -> [String]? {
        callJSON("lineManagerSelectedIds", arguments: [person, roster]) as? [String]
    }

    /// `lineManagerSummary(person, roster)` → its `label`. Nil when the script did not answer.
    nonisolated static func lineManagerSummaryLabel(person: [String: Any], roster: [[String: Any]]) -> String? {
        (callJSON("lineManagerSummary", arguments: [person, roster]) as? [String: Any])?["label"] as? String
    }
}

/// The Manage Users line-manager row and picker, through the rulebook.
@MainActor
enum LineManagerRulebook {
    /// A roster row as `lineManagerCandidates` / `lineManagerSummary` read it: `RulebookPeople.person` plus the names
    /// and `passwordSet` (an invite not accepted yet is never a candidate).
    static func row(_ user: AppUser) -> [String: Any] {
        var row = RulebookPeople.person(user)
        row["firstName"] = user.firstName
        row["surname"] = user.surname
        row["passwordSet"] = user.passwordSet
        let stored = user.documentName.trimmingCharacters(in: .whitespacesAndNewlines)
        row["name"] = stored.isEmpty ? user.fullName : stored
        if !user.documentDisplayName.isEmpty { row["displayName"] = user.documentDisplayName }
        return row
    }

    static func roster(_ users: [AppUser]) -> [[String: Any]] {
        users.map { row($0) }
    }

    /// The person as the screen will save them: their level flags and the selected line managers.
    static func subject(_ person: AppUser, selectedIds: Set<String>, hasNoLineManager: Bool) -> [String: Any] {
        var draft = person
        draft.hasNoLineManager = hasNoLineManager
        draft.setLineManagerUserIds(hasNoLineManager ? [] : Array(selectedIds).sorted())
        return row(draft)
    }

    /// `lineManagerCandidates` as roster users, in the rulebook's order. Empty when the script did not answer.
    static func candidates(for person: AppUser, roster users: [AppUser]) -> [AppUser] {
        guard let rows = CanonicalBusinessEngine.lineManagerCandidates(person: row(person), roster: roster(users)) else { return [] }
        var byId: [String: AppUser] = [:]
        for user in users where byId[user.id.lowercased()] == nil { byId[user.id.lowercased()] = user }
        return rows.compactMap { byId[$0.id.lowercased()] }
    }

    /// `lineManagerSelectedIds(person, roster)`: what the Edit User picker starts with (and the baseline a save compares
    /// against), so a stored id on the other users document of the same person selects that person's one option.
    /// Falls back to the stored ids when the script did not answer.
    static func selectedIds(for person: AppUser, roster users: [AppUser]) -> Set<String> {
        guard let ids = CanonicalBusinessEngine.lineManagerSelectedIds(person: row(person), roster: roster(users)) else {
            return Set(person.lineManagerUserIds)
        }
        return Set(ids)
    }

    /// Whether the picker's selection differs from the person's stored line managers, both read through
    /// `lineManagerSelectedIds` (so the same person under their other users document is no change). The
    /// `hasNoLineManager` flag is compared separately by the screen.
    static func selectionChanged(_ selected: Set<String>, from person: AppUser, roster users: [AppUser]) -> Bool {
        var stored = person
        stored.hasNoLineManager = false
        var draft = stored
        draft.setLineManagerUserIds(Array(selected).sorted())
        return selectedIds(for: draft, roster: users) != selectedIds(for: stored, roster: users)
    }

    /// `lineManagerOptions(person).allowsNoLineManager`: "No line manager" is offered only to admins and super admins.
    static func allowsNoLineManager(for person: AppUser) -> Bool {
        var draft = person
        draft.hasNoLineManager = false
        return CanonicalBusinessEngine.lineManagerOptions(person: row(draft))?.allowsNoLineManager ?? false
    }

    /// `lineManagerSummary(person, roster).label`: "No line manager", "Not set", one name, or "First +N more".
    static func summary(for person: AppUser, selectedIds: Set<String>, hasNoLineManager: Bool, roster users: [AppUser]) -> String {
        CanonicalBusinessEngine.lineManagerSummaryLabel(
            person: subject(person, selectedIds: selectedIds, hasNoLineManager: hasNoLineManager),
            roster: roster(users)
        ) ?? (hasNoLineManager ? "No line manager" : "Not set")
    }
}
