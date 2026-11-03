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
