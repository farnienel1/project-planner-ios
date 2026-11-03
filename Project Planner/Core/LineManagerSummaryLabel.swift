//
//  LineManagerSummaryLabel.swift
//  Project Planner
//
//  The line-manager row label on Edit User and Add User. Display only: who the line managers are stays
//  `lineManagerIds` / `lineManagerRequiredError` in the rulebook. Web 1.11.0 adds canonical
//  `lineManagerSummary(person, roster)`; once it is synced, this calls it instead.
//  RULEBOOK-GAP(lineManagerSummary): web 1.11.0 — replace `text(...)` with the packed rule after the sync.
//

import Foundation

enum LineManagerSummaryLabel {
    static let unknownPerson = "Unknown person"
    static let noLineManager = "No line manager"
    static let selectPrompt = "Select manager(s)…"

    /// Every selected id is named: a roster row (by its id, or a stored former / same-email id) gives its name,
    /// an id that resolves to nobody is "Unknown person" — never hidden. The count after "+" is never negative.
    static func text(selectedIds: Set<String>, roster: [AppUser], hasNoLineManager: Bool) -> String {
        if hasNoLineManager { return noLineManager }
        let ids = selectedIds
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .sorted()
        guard !ids.isEmpty else { return selectPrompt }
        var named: [String] = []
        var seenPeople = Set<String>()
        var unknown = 0
        for id in ids {
            guard let person = person(for: id, in: roster) else {
                unknown += 1
                continue
            }
            guard seenPeople.insert(person.id.lowercased()).inserted else { continue }
            let name = person.fullName.trimmingCharacters(in: .whitespacesAndNewlines)
            named.append(name.isEmpty ? person.email : name)
        }
        let labels = named.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
            + Array(repeating: unknownPerson, count: unknown)
        guard let first = labels.first else { return selectPrompt }
        if labels.count == 1 { return first }
        return "\(first) +\(labels.count - 1) more"
    }

    private static func person(for id: String, in roster: [AppUser]) -> AppUser? {
        if let exact = roster.first(where: { $0.id.caseInsensitiveCompare(id) == .orderedSame }) { return exact }
        return roster.first { row in
            (row.sameEmailUserIds + row.formerUserIds).contains { $0.caseInsensitiveCompare(id) == .orderedSame }
        }
    }
}
