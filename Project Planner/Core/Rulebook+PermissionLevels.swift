//
//  Rulebook+PermissionLevels.swift
//  Project Planner
//
//  Rulebook 1.11.0 (docs/RULEBOOK.md §8, §11): permission toggles by user level. Web
//  `lib/canonical/permissionLevels.ts`, called through `CanonicalBusinessEngine`; nothing is decided here.
//    - `permissionLevelOf`, `effectivePermissions`, `lockedPermissionFields`: what is in effect and what is locked
//      (admins and super admins: every toggle on and locked except Annual Leave Management; managers: Materials and
//      Site audit on and locked).
//    - `permissionToggleRows`: the one row set for Add User, its summary and Edit User.
//    - `addUserPermissionDefaults`, `accountTypeChangeWrites`, `canManageOperatives`.
//

import Foundation
import FirebaseFirestore

/// `PermissionLevel`: the level the toggles are decided by.
nonisolated enum RulebookPermissionLevel: String, Sendable, CaseIterable {
    case admin
    case manager
    case operative
}

/// `PermissionToggleMode`: which Manage Users screen the rows are for.
nonisolated enum RulebookPermissionToggleMode: String, Sendable {
    case add
    case edit
    case summary
}

/// One `permissionToggleRows` row.
nonisolated struct RulebookPermissionToggleRow: Identifiable, Equatable, Sendable {
    var field: String
    var label: String
    var help: String
    var visible: Bool
    var editable: Bool
    var value: Bool
    /// RULEBOOK 1.28.0: why a visible row is greyed out when it is not the level lock —
    /// `SUPER_ADMIN_SELF_MANAGE_MESSAGE`, `TIMESHEET_SELF_SIGN_PAYE_NOTE` or `OWN_SELF_MANAGE_MESSAGE`. Nil otherwise.
    var note: String? = nil
    var id: String { field }
}

/// One write of `accountTypeChangeWrites`.
nonisolated enum RulebookAccountTypeWrite: Sendable {
    /// `users/{uid}` (and same-email users documents of this organisation): `role`, the flags and every toggle at the
    /// top level and as `permissions.{key}`. Values are Bool or String only.
    case userProfile(path: String, fields: [String: Sendable])
    /// `organizations/{orgId}` `members.{uid}` = role.
    case organizationMember(path: String, fields: [String: Sendable])
    /// `users/{uid}/orgMemberships/{orgId}`: role and nested permissions (`orgMembershipWriteFields` shape).
    case membership(path: String, role: String, permissions: [String: Bool])
}

/// `accountTypeChangeWrites` result.
nonisolated enum RulebookAccountTypeChange: Sendable {
    case ok(role: RulebookPermissionLevel, permissions: [String: Bool], writes: [RulebookAccountTypeWrite], note: String?)
    case refused(reason: String, message: String)
}

extension UserPermissions {
    /// `USER_PERMISSION_FIELDS`, in the rulebook's order.
    nonisolated static let rulebookFields: [String] = ["adminAccess", "manager", "operatives", "skills", "qualifications", "materials", "projects", "smallWorks", "operativeMode", "siteAudit", "subContractors", "wholesalersOrderHistory", "annualLeaveSelfBook", "timesheetSelfSign", "weeklyReports", "dailyOverview"]

    /// The stored toggle named by a `USER_PERMISSION_FIELDS` key; nil for an unknown key.
    nonisolated func flag(_ field: String) -> Bool? {
        switch field {
        case "adminAccess": return adminAccess
        case "manager": return manager
        case "operatives": return operatives
        case "skills": return skills
        case "qualifications": return qualifications
        case "materials": return materials
        case "projects": return projects
        case "smallWorks": return smallWorks
        case "operativeMode": return operativeMode
        case "siteAudit": return siteAudit
        case "subContractors": return subContractors
        case "wholesalersOrderHistory": return wholesalersOrderHistory
        case "annualLeaveSelfBook": return annualLeaveSelfBook
        case "timesheetSelfSign": return timesheetSelfSign
        case "weeklyReports": return weeklyReports
        case "dailyOverview": return dailyOverview
        default: return nil
        }
    }

    /// Sets the toggle named by a `USER_PERMISSION_FIELDS` key (unknown keys and the retired `skills` are ignored).
    nonisolated mutating func setFlag(_ field: String, _ value: Bool) {
        switch field {
        case "adminAccess": adminAccess = value
        case "manager": manager = value
        case "operatives": operatives = value
        case "qualifications": qualifications = value
        case "materials": materials = value
        case "projects": projects = value
        case "smallWorks": smallWorks = value
        case "operativeMode": operativeMode = value
        case "siteAudit": siteAudit = value
        case "subContractors": subContractors = value
        case "wholesalersOrderHistory": wholesalersOrderHistory = value
        case "annualLeaveSelfBook": annualLeaveSelfBook = value
        case "timesheetSelfSign": timesheetSelfSign = value
        case "weeklyReports": weeklyReports = value
        case "dailyOverview": dailyOverview = value
        default: break
        }
    }

    /// Every toggle as `{ field: Bool }`, the shape the permission rules read.
    nonisolated var rulebookMap: [String: Bool] {
        var map: [String: Bool] = [:]
        for field in Self.rulebookFields {
            if let value = flag(field) { map[field] = value }
        }
        return map
    }

    /// `self` with every field the map names set to its value (unnamed fields keep their value).
    nonisolated func applying(_ map: [String: Bool]) -> UserPermissions {
        var out = self
        for (field, value) in map { out.setFlag(field, value) }
        out.skills = false
        return out
    }
}

extension CanonicalBusinessEngine {
    /// The stored permission fields of a person as `permissionLevelOf` / `effectivePermissions` read them: `role`,
    /// `isSuperAdmin` and every toggle at the top level.
    /// RULEBOOK 1.28.0: `employmentType` (a PAYE admin's Timesheet self-sign row is greyed out) and
    /// `organizationSuperAdmin` (`isOrganizationSuperAdmin` for the open organisation; it decides the Super Admin's
    /// locked self-manage toggles when given) are passed through as the script reads them.
    nonisolated static func permissionSubject(
        permissions: UserPermissions,
        role: String?,
        isSuperAdmin: Bool,
        employmentType: String? = nil,
        organizationSuperAdmin: Bool? = nil
    ) -> [String: Any] {
        var row: [String: Any] = [:]
        for (field, value) in permissions.rulebookMap { row[field] = value }
        row["permissions"] = permissions.rulebookMap
        if let role, !role.isEmpty { row["role"] = role }
        row["isSuperAdmin"] = isSuperAdmin
        if let employmentType, !employmentType.isEmpty { row["employmentType"] = employmentType }
        if let organizationSuperAdmin { row["organizationSuperAdmin"] = organizationSuperAdmin }
        return row
    }

    private nonisolated static func boolMap(_ value: Any?) -> [String: Bool]? {
        guard let map = value as? [String: Any] else { return nil }
        var out: [String: Bool] = [:]
        for (key, flag) in map {
            if let bool = flag as? Bool { out[key] = bool }
        }
        return out
    }

    /// `accountTypeWritePermissions(kind, person, screen)` (RULEBOOK 1.15.0 §11): the toggles a "Change user type" save
    /// writes — every stored toggle kept (`accountTypePermissions`), only the level flags changed, then the screen's
    /// values for the toggles the new level can change. Nil when the script did not answer.
    nonisolated static func accountTypeWritePermissions(
        kind: RulebookPermissionLevel,
        person: [String: Any],
        screen: [String: Bool]
    ) -> [String: Bool]? {
        boolMap(callJSON("accountTypeWritePermissions", arguments: [kind.rawValue, person, screen]))
    }

    /// `accountTypePermissions(kind, previous)` (1.15.0): the stored toggles with only the level flags changed.
    nonisolated static func accountTypePermissions(kind: RulebookPermissionLevel, previous: [String: Any]) -> [String: Bool]? {
        boolMap(callJSON("accountTypePermissions", arguments: [kind.rawValue, previous]))
    }

    /// `permissionLevelOf(user)`. Nil when the script did not answer.
    nonisolated static func permissionLevelOf(_ subject: [String: Any]) -> RulebookPermissionLevel? {
        (callJSON("permissionLevelOf", arguments: [subject]) as? String).flatMap(RulebookPermissionLevel.init(rawValue:))
    }

    /// `effectivePermissions(user, level?)`: every `USER_PERMISSION_FIELDS` key. Nil when the script did not answer.
    nonisolated static func effectivePermissions(_ subject: [String: Any], level: RulebookPermissionLevel? = nil) -> [String: Bool]? {
        boolMap(callJSON("effectivePermissions", arguments: [subject, level?.rawValue ?? NSNull()]))
    }

    /// `lockedPermissionFields(user, level?)`. Nil when the script did not answer.
    nonisolated static func lockedPermissionFields(_ subject: [String: Any], level: RulebookPermissionLevel? = nil) -> [String]? {
        callJSON("lockedPermissionFields", arguments: [subject, level?.rawValue ?? NSNull()]) as? [String]
    }

    /// `addUserPermissionDefaults(level)`: what Add User starts with. Nil when the script did not answer.
    nonisolated static func addUserPermissionDefaults(_ level: RulebookPermissionLevel) -> [String: Bool]? {
        boolMap(callJSON("addUserPermissionDefaults", arguments: [level.rawValue]))
    }

    /// `permissionsWriteMap(draft, level)`: the `permissions` map a save writes for this level.
    nonisolated static func permissionsWriteMap(_ draft: [String: Any], level: RulebookPermissionLevel) -> [String: Bool]? {
        boolMap(callJSON("permissionsWriteMap", arguments: [draft, level.rawValue]))
    }

    /// `permissionToggleRows({ level, user?, mode, viewerIsSubject? })`. Empty when the script did not answer.
    /// RULEBOOK 1.28.0: `viewerIsSubject` — the viewer's own self-manage rows are not editable
    /// (`OWN_SELF_MANAGE_MESSAGE`); each row carries its `note`.
    nonisolated static func permissionToggleRows(
        level: RulebookPermissionLevel,
        user: [String: Any]?,
        mode: RulebookPermissionToggleMode,
        viewerIsSubject: Bool = false
    ) -> [RulebookPermissionToggleRow] {
        var input: [String: Any] = ["level": level.rawValue, "mode": mode.rawValue, "viewerIsSubject": viewerIsSubject]
        if let user { input["user"] = user }
        guard let rows = callJSON("permissionToggleRows", arguments: [input]) as? [[String: Any]] else { return [] }
        return rows.compactMap { row in
            guard let field = row["field"] as? String else { return nil }
            return RulebookPermissionToggleRow(
                field: field,
                label: row["label"] as? String ?? field,
                help: row["help"] as? String ?? "",
                visible: row["visible"] as? Bool ?? false,
                editable: row["editable"] as? Bool ?? false,
                value: row["value"] as? Bool ?? false,
                note: row["note"] as? String
            )
        }
    }

    /// `canManageOperatives(user)`: add operatives, open Manage Operatives and full profiles, change an operative's pay.
    nonisolated static func canManageOperatives(_ subject: [String: Any]) -> Bool {
        callJSON("canManageOperatives", arguments: [subject]) as? Bool ?? false
    }

    /// `ADMIN_LOCKED_PERMISSION_MESSAGE`.
    nonisolated static var adminLockedPermissionMessage: String {
        constant("ADMIN_LOCKED_PERMISSION_MESSAGE", as: String.self)
            ?? "Administrators have this on. Change user type to remove admin access."
    }

    /// `isOrganizationSuperAdmin(viewer, org)` (1.28.0 §8, §16): the organisation's creator, or a profile of that
    /// organisation flagged `isSuperAdmin`. Nil when the script did not answer.
    nonisolated static func isOrganizationSuperAdmin(
        viewerId: String,
        viewerIsSuperAdmin: Bool,
        viewerOrganizationId: String?,
        organizationId: String,
        creatorUserId: String?
    ) -> Bool? {
        var viewer: [String: Any] = ["id": viewerId, "isSuperAdmin": viewerIsSuperAdmin]
        if let viewerOrganizationId, !viewerOrganizationId.isEmpty { viewer["organizationId"] = viewerOrganizationId }
        var org: [String: Any] = ["id": organizationId]
        if let creatorUserId, !creatorUserId.isEmpty { org["creatorUserId"] = creatorUserId }
        return callJSON("isOrganizationSuperAdmin", arguments: [viewer, org]) as? Bool
    }

    /// `OWN_SELF_MANAGE_MESSAGE` (1.28.0): nobody changes their own self-manage toggles.
    nonisolated static var ownSelfManageMessage: String {
        constant("OWN_SELF_MANAGE_MESSAGE", as: String.self)
            ?? "You cannot change your own self-manage toggles. Ask another admin."
    }

    /// `SUPER_ADMIN_SELF_MANAGE_MESSAGE` (1.28.0): the Super Admin's self-manage toggles are always on.
    nonisolated static var superAdminSelfManageMessage: String? {
        constant("SUPER_ADMIN_SELF_MANAGE_MESSAGE", as: String.self)
    }

    /// `TIMESHEET_SELF_SIGN_PAYE_NOTE` (1.28.0): a PAYE admin's Timesheet self-sign row is greyed out.
    nonisolated static var timesheetSelfSignPayeNote: String {
        constant("TIMESHEET_SELF_SIGN_PAYE_NOTE", as: String.self) ?? "Not used while PAYE — PAYE has no timesheets."
    }

    /// `ADMIN_ONLY_PERMISSION_FIELDS` (1.28.0): toggles that never take effect below admin. Empty when the script did
    /// not answer.
    nonisolated static var adminOnlyPermissionFields: [String] {
        constant("ADMIN_ONLY_PERMISSION_FIELDS", as: [String].self) ?? []
    }

    /// `keepStoredLockedPermissions(before, next)` (1.28.0 §11): `next` (a `users/{uid}` update) without the toggles
    /// locked for the stored level — and, on a change away from admin, without the admin-only toggles — so a save never
    /// writes a derived or locked value. Nil when the script did not answer.
    nonisolated static func keepStoredLockedPermissions(before: [String: Any], next: [String: Any]) -> [String: Any]? {
        callJSON("keepStoredLockedPermissions", arguments: [before, next]) as? [String: Any]
    }

    /// `PAYE_RATE_NOT_USED_NOTE`.
    nonisolated static var payeRateNotUsedNote: String {
        constant("PAYE_RATE_NOT_USED_NOTE", as: String.self) ?? "Not used while PAYE. Kept for days they are self-employed."
    }

    /// `PAY_BASIS_SAVE_NOTE` (§8): one basis; saving one removes the other.
    nonisolated static var payBasisSaveNote: String {
        constant("PAY_BASIS_SAVE_NOTE", as: String.self)
            ?? "Pay is a day rate or an hourly rate, not both. Saving a day rate removes the hourly rate, and saving an hourly rate removes the day rate."
    }

    /// `accountTypeChangeWrites({ person, kind, organizationId, roster, permissions })` (§11): every write that
    /// changes a person's user type in one organisation. Nil when the script did not answer.
    nonisolated static func accountTypeChangeWrites(
        person: [String: Any],
        kind: RulebookPermissionLevel,
        organizationId: String,
        roster: [[String: Any]],
        permissions: [String: Bool]?
    ) -> RulebookAccountTypeChange? {
        var input: [String: Any] = [
            "person": person,
            "kind": kind.rawValue,
            "organizationId": organizationId,
            "roster": roster,
        ]
        if let permissions { input["permissions"] = permissions }
        guard let result = callJSON("accountTypeChangeWrites", arguments: [input]) as? [String: Any] else { return nil }
        guard result["ok"] as? Bool == true else {
            return .refused(
                reason: result["reason"] as? String ?? "invalid",
                message: result["message"] as? String ?? "Choose a user type."
            )
        }
        let role = (result["role"] as? String).flatMap(RulebookPermissionLevel.init(rawValue:)) ?? kind
        let effective = boolMap(result["permissions"]) ?? [:]
        var writes: [RulebookAccountTypeWrite] = []
        for row in result["writes"] as? [[String: Any]] ?? [] {
            guard let path = row["path"] as? String, let kind = row["kind"] as? String else { continue }
            switch kind {
            case "userProfile", "organizationMember":
                var fields: [String: Sendable] = [:]
                for (key, value) in row["fields"] as? [String: Any] ?? [:] {
                    if let flag = value as? Bool { fields[key] = flag } else if let text = value as? String { fields[key] = text }
                }
                writes.append(kind == "userProfile" ? .userProfile(path: path, fields: fields) : .organizationMember(path: path, fields: fields))
            case "membership":
                writes.append(.membership(path: path, role: row["role"] as? String ?? role.rawValue, permissions: boolMap(row["permissions"]) ?? effective))
            default:
                continue
            }
        }
        return .ok(role: role, permissions: effective, writes: writes, note: result["note"] as? String)
    }
}

// MARK: - The signed-in person and roster rows

/// `effectivePermissions` answers, cached by the stored inputs (screen gates run on every render).
@MainActor
enum EffectivePermissionsCache {
    private struct Key: Hashable {
        let permissions: UserPermissions
        let role: String
        let isSuperAdmin: Bool
        /// RULEBOOK 1.28.0: the per-organisation Super Admin and PAYE change the self-manage toggles in effect.
        let organizationSuperAdmin: Bool?
        let employmentType: String
    }
    private static var cache: [Key: UserPermissions] = [:]
    private static var levels: [Key: RulebookPermissionLevel] = [:]

    static func effective(_ user: AppUser) -> UserPermissions {
        let key = keyFields(user)
        if let hit = cache[key] { return hit }
        guard let map = CanonicalBusinessEngine.effectivePermissions(user.permissionSubject) else {
            // The script did not answer: the stored toggles (what the app showed before 1.11.0).
            return user.permissions
        }
        let value = user.permissions.applying(map)
        if cache.count > 256 { cache.removeAll() }
        cache[key] = value
        return value
    }

    static func level(_ user: AppUser) -> RulebookPermissionLevel {
        let key = keyFields(user)
        if let hit = levels[key] { return hit }
        let fallback: RulebookPermissionLevel = user.isRosterAdmin ? .admin
            : (user.permissions.operativeMode || user.role == .operative) ? .operative : .manager
        guard let level = CanonicalBusinessEngine.permissionLevelOf(user.permissionSubject) else { return fallback }
        if levels.count > 256 { levels.removeAll() }
        levels[key] = level
        return level
    }

    private static func keyFields(_ user: AppUser) -> Key {
        Key(
            permissions: user.permissions,
            role: user.role.rawValue,
            isSuperAdmin: user.isSuperAdmin,
            organizationSuperAdmin: user.organizationSuperAdmin,
            employmentType: user.employmentType.rawValue
        )
    }

    /// Tests: start from an empty cache.
    static func reset() {
        cache.removeAll()
        levels.removeAll()
    }
}

/// `isOrganizationSuperAdmin` answers, memoised by their inputs (screen gates read it on every render).
@MainActor
enum OrganizationSuperAdminCache {
    private struct Key: Hashable {
        let organizationId: String
        let creatorUserId: String?
        let userId: String
        let isSuperAdmin: Bool
        let userOrganizationId: String
    }
    private static var cache: [Key: Bool] = [:]

    static func answer(for user: AppUser) -> Bool? {
        guard let orgId = OrganizationRulebookContext.organizationId else { return nil }
        let key = Key(
            organizationId: orgId,
            creatorUserId: OrganizationRulebookContext.creatorUserId,
            userId: user.id,
            isSuperAdmin: user.isSuperAdmin,
            userOrganizationId: user.organizationId
        )
        if let hit = cache[key] { return hit }
        guard let answer = CanonicalBusinessEngine.isOrganizationSuperAdmin(
            viewerId: user.id,
            viewerIsSuperAdmin: user.isSuperAdmin,
            viewerOrganizationId: user.organizationId,
            organizationId: orgId,
            creatorUserId: OrganizationRulebookContext.creatorUserId
        ) else { return nil }
        if cache.count > 512 { cache.removeAll() }
        cache[key] = answer
        return answer
    }
}

extension AppUser {
    /// The stored permission fields as the permission-level rules read them.
    var permissionSubject: [String: Any] {
        CanonicalBusinessEngine.permissionSubject(
            permissions: permissions,
            role: role.rawValue,
            isSuperAdmin: isSuperAdmin,
            employmentType: employmentType.rawValue,
            organizationSuperAdmin: organizationSuperAdmin
        )
    }

    /// RULEBOOK 1.28.0 `isOrganizationSuperAdmin(viewer, org)`: this person is the Super Admin of the open organisation
    /// (its creator, or `isSuperAdmin` on a profile of that organisation) — never a home company's flag in another
    /// company. Passed to the rules as `organizationSuperAdmin`. Nil before an organisation is open or when the script
    /// did not answer (the stored flags then apply).
    var organizationSuperAdmin: Bool? {
        OrganizationSuperAdminCache.answer(for: self)
    }

    /// `permissionLevelOf(user)`.
    var permissionLevel: RulebookPermissionLevel { EffectivePermissionsCache.level(self) }

    /// `effectivePermissions(user)`: the toggles every screen gate reads (RULEBOOK 1.11.0 §8, §11). Stored toggles
    /// are never rewritten from this; saves keep using `permissions`.
    var effectivePermissions: UserPermissions { EffectivePermissionsCache.effective(self) }
}

// MARK: - Change user type: members entry and membership (accountTypeChangeWrites)

extension FirebaseBackend {
    /// RULEBOOK 1.11.0 §11: the `organizationMember` (`organizations/{orgId}` `members.{uid}`) and `membership`
    /// (`users/{uid}/orgMemberships/{orgId}`, `orgMembershipWriteFields` admin, created when missing) writes of an
    /// `accountTypeChangeWrites` plan. The `users/{uid}` writes go through `UserStore.updateUserPermissions`.
    func applyAccountTypeMembershipWrites(_ writes: [RulebookAccountTypeWrite], organizationId: String, actorUserId: String?) async throws {
        let orgId = normalizedOrganizationId(organizationId)
        guard !orgId.isEmpty else { return }
        for write in writes {
            switch write {
            case .userProfile:
                continue
            case .organizationMember(_, let fields):
                var data: [String: Any] = [:]
                for (key, value) in fields { data[key] = value }
                guard !data.isEmpty else { continue }
                try await db.collection("organizations").document(orgId).updateData(WriteMetadata.stamped(data, userId: actorUserId))
            case .membership(let path, let role, let permissions):
                // `users/{uid}/orgMemberships/{orgId}`
                let parts = path.split(separator: "/").map(String.init)
                guard parts.count == 4, parts[0] == "users", parts[2] == "orgMemberships" else { continue }
                try await writeOrgMembership(
                    userId: parts[1],
                    organizationId: orgId,
                    next: ["role": role, "permissions": permissions],
                    writer: "admin",
                    createIfMissing: true
                )
            }
        }
    }
}

// MARK: - Half-applied user type (accountTypeSyncState, RULEBOOK 1.12.2 §11)

/// `accountTypeSyncState` result.
nonisolated struct RulebookAccountTypeSyncState: Equatable, Sendable {
    var inSync: Bool
    var level: RulebookPermissionLevel?
    var membersRole: String?
    /// The level to write on every record when the type was only partly saved; nil when in sync.
    var repair: RulebookPermissionLevel?
}

extension CanonicalBusinessEngine {
    /// `ACCOUNT_TYPE_OUT_OF_SYNC_MESSAGE`.
    nonisolated static var accountTypeOutOfSyncMessage: String {
        constant("ACCOUNT_TYPE_OUT_OF_SYNC_MESSAGE", as: String.self)
            ?? "This person's user type was only partly saved. Press Save to finish it on every record."
    }

    /// `accountTypeSyncState({ person, organizationId, members, membership? })`: whether the user type on the users
    /// document matches `members.{uid}` (and the membership, when read). Nil when the script did not answer.
    nonisolated static func accountTypeSyncState(
        person: [String: Any],
        organizationId: String,
        members: [String: String],
        membershipRole: String? = nil
    ) -> RulebookAccountTypeSyncState? {
        var input: [String: Any] = ["person": person, "organizationId": organizationId, "members": members]
        if let membershipRole { input["membership"] = ["role": membershipRole] }
        guard let row = callJSON("accountTypeSyncState", arguments: [input]) as? [String: Any],
              let inSync = row["inSync"] as? Bool else { return nil }
        return RulebookAccountTypeSyncState(
            inSync: inSync,
            level: (row["level"] as? String).flatMap(RulebookPermissionLevel.init(rawValue:)),
            membersRole: row["membersRole"] as? String,
            repair: (row["repair"] as? String).flatMap(RulebookPermissionLevel.init(rawValue:))
        )
    }
}

extension AppUser {
    /// The person as `accountTypeSyncState` reads them (web `accountTypeSubject`): id, organisation, role, super admin
    /// and the permission flags at the top level and nested.
    var accountTypeSubject: [String: Any] {
        var row = permissionSubject
        row["id"] = id
        row["organizationId"] = organizationId
        return row
    }

    /// `accountTypeSyncState` against the open organisation's live `members` map. Nil when the map is not loaded,
    /// belongs to another organisation, or the script did not answer (nothing is shown or repaired then).
    @MainActor
    func accountTypeSyncState(in backend: FirebaseBackend) -> RulebookAccountTypeSyncState? {
        guard let snapshot = backend.organizationMembersSnapshot,
              let open = backend.currentOrganization?.firestoreDocumentId,
              organizationIdsMatch(snapshot.organizationId, open) else { return nil }
        return CanonicalBusinessEngine.accountTypeSyncState(
            person: accountTypeSubject,
            organizationId: snapshot.organizationId,
            members: snapshot.members
        )
    }
}
