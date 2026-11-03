//
//  Rulebook+LineManagers.swift
//  Project Planner
//
//  Rulebook 1.11.0 (docs/RULEBOOK.md §8, §11): line manager pickers and labels on Add User and Edit User. Web
//  `lib/canonical/lineManagers.ts`, called through `CanonicalBusinessEngine`:
//    - `lineManagerCandidates(person, roster)`: who may be picked;
//    - `lineManagerOptions(person)`: whether "No line manager" is offered (admins only);
//    - `lineManagerSummary(person, roster)`: the label ("Unknown person" for an unknown id, "+N more" only for N ≥ 1).
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
