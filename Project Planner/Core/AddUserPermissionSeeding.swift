//
//  AddUserPermissionSeeding.swift
//  Project Planner
//
//  RULEBOOK §11: Add User starts each level with `addUserPermissionDefaults(level)` (web `AddUserScreen`
//  `selectAccountType`). The defaults are applied only when the level is chosen or changed — never again on a step
//  change, a step re-appearing, or a second tap on the same level — so the toggles the admin picked are the ones
//  `permissionsWriteMap(draft, level)` saves. Nothing is decided here; the defaults come from `CanonicalBusinessEngine`.
//

import Foundation

nonisolated enum AddUserPermissionSeeding {
    /// The Add User toggles after `level` is (re)selected. `seededLevel` is the level the current toggles were seeded
    /// for (nil before the first seed). Same level: the current toggles are kept. Another level: that level's
    /// `addUserPermissionDefaults`. When the script did not answer, the toggles are kept and nothing counts as seeded.
    static func select(
        level: RulebookPermissionLevel,
        current: UserPermissions,
        seededLevel: RulebookPermissionLevel?
    ) -> (permissions: UserPermissions, seededLevel: RulebookPermissionLevel?) {
        if seededLevel == level { return (current, seededLevel) }
        guard let defaults = CanonicalBusinessEngine.addUserPermissionDefaults(level) else {
            return (current, seededLevel)
        }
        return (UserPermissions().applying(defaults), level)
    }
}

/// Add User line-manager picks across steps. The picks are app state and are kept on every step change; when the
/// account type actually changes they go through RULEBOOK 1.24.0 §11 `CanonicalBusinessEngine`
/// `lineManagerSelectionAfterLevelChange(picks, newLevel, roster, person)`: each pick that is still a
/// `lineManagerCandidates` row for the person is kept (one per person), the rest dropped, and "No line manager" kept
/// only for an admin. Whether the picks are enough is still `lineManagerRequiredError`.
nonisolated enum AddUserLineManagerSelection {
    @MainActor
    static func afterAccountTypeSelection(
        previous: RulebookPermissionLevel,
        next: RulebookPermissionLevel,
        lineManagerIds: Set<String>,
        hasNoLineManager: Bool,
        person: AppUser? = nil,
        roster: [AppUser] = []
    ) -> (lineManagerIds: Set<String>, hasNoLineManager: Bool) {
        guard previous != next else { return (lineManagerIds, hasNoLineManager) }
        let picks: [String: Any] = ["lineManagerIds": Array(lineManagerIds).sorted(), "hasNoLineManager": hasNoLineManager]
        let personRow: Any = person.map { LineManagerRulebook.row($0) as Any } ?? NSNull()
        guard let answer = CanonicalBusinessEngine.callJSON(
            "lineManagerSelectionAfterLevelChange",
            arguments: [picks, next.rawValue, LineManagerRulebook.roster(roster), personRow]
        ) as? [String: Any] else {
            // The script did not answer: nothing unchecked is carried to the new type.
            return ([], false)
        }
        return (Set(answer["lineManagerIds"] as? [String] ?? []), answer["hasNoLineManager"] as? Bool ?? false)
    }
}
