//
//  Rulebook+PeopleAccess.swift
//  Project Planner
//
//  Rulebook 1.31.0 (docs/RULEBOOK.md §5, §8, §11, §13, §16; web `lib/canonical/peopleAccess.ts`, `staffAccess.ts`,
//  `bookings.ts`, `userTimesheetAccess.ts`, `permissionLevels.ts`): typed wrappers for the people-and-access rules —
//  line-manager reports and the change block, job-manager removal, a new job's manager, Change Super Admin,
//  deactivate / reactivate, the one permission-flag reader, warning scope rows, an operatives manager's booking
//  delete and the exported timesheet history. Every answer comes from the packed script through
//  `CanonicalBusinessEngine.callJSON`; nothing is decided here.
//

import Foundation

/// A change Manage Users is about to save for a person (`PersonAccessChange`).
nonisolated enum RulebookPersonAccessChange: Equatable, Sendable {
    case level(RulebookPermissionLevel)
    case deactivate
    case delete

    var json: [String: Any] {
        switch self {
        case .level(let to): return ["kind": "level", "to": to.rawValue]
        case .deactivate: return ["kind": "deactivate"]
        case .delete: return ["kind": "delete"]
        }
    }
}

/// One person who reports to someone (`LineManagerReport`).
nonisolated struct RulebookLineManagerReport: Equatable, Hashable, Sendable, Identifiable {
    let id: String
    let name: String
}

/// `lineManagerChangeBlock` result.
nonisolated struct RulebookLineManagerChangeBlock: Equatable, Sendable {
    let blocked: Bool
    let reports: [RulebookLineManagerReport]
    let message: String?
}

/// One job update of `jobManagerRemovalWrites`: fields to set and fields to remove (a partial update).
nonisolated struct RulebookJobManagerRemovalWrite: Equatable, Sendable {
    let path: String
    let collection: String
    let jobId: String
    /// `managerIds` / `managerUserIds` / `assignedManagerUserIds` → [String]; `managerId` → String.
    let setLists: [String: [String]]
    let setManagerId: String?
    let remove: [String]
}

/// One write of `superAdminTransferWrites` / `userActiveWrites`: a document path, its kind and the fields.
nonisolated struct RulebookPathWrite: Sendable {
    let path: String
    /// `organization`, `userProfile` or `membership`.
    let kind: String
    let fields: [String: Sendable]
}

extension CanonicalBusinessEngine {
    // MARK: Line manager reports and the change block (§11)

    /// `lineManagerReports(person, roster)`: the active people whose line manager is `person`, sorted by name.
    /// `roster` is every users document of the organisation (unfolded). Empty when the script did not answer.
    nonisolated static func lineManagerReports(person: [String: Any], roster: [[String: Any]]) -> [RulebookLineManagerReport] {
        let rows = callJSON("lineManagerReports", arguments: [person, roster]) as? [[String: Any]] ?? []
        return rows.compactMap { row in
            guard let id = row["id"] as? String else { return nil }
            return RulebookLineManagerReport(id: id, name: row["name"] as? String ?? id)
        }
    }

    /// `lineManagerChangeBlock({ person, roster, change })`. Nil when the script did not answer.
    nonisolated static func lineManagerChangeBlock(
        person: [String: Any],
        roster: [[String: Any]],
        change: RulebookPersonAccessChange
    ) -> RulebookLineManagerChangeBlock? {
        let input: [String: Any] = ["person": person, "roster": roster, "change": change.json]
        guard let result = callJSON("lineManagerChangeBlock", arguments: [input]) as? [String: Any] else { return nil }
        let reports = (result["reports"] as? [[String: Any]] ?? []).compactMap { row -> RulebookLineManagerReport? in
            guard let id = row["id"] as? String else { return nil }
            return RulebookLineManagerReport(id: id, name: row["name"] as? String ?? id)
        }
        return RulebookLineManagerChangeBlock(
            blocked: result["blocked"] as? Bool ?? false,
            reports: reports,
            message: result["message"] as? String
        )
    }

    /// `LINE_MANAGER_REPORTS_BLOCK_MESSAGE`.
    nonisolated static var lineManagerReportsBlockMessage: String {
        constant("LINE_MANAGER_REPORTS_BLOCK_MESSAGE", as: String.self)
            ?? "This user is the line manager for the users below. Give each of them another line manager first, then try again."
    }

    // MARK: Job managers (§11)

    /// `changeRemovesJobManager(person, change)`: made an operative, deactivated or deleted.
    nonisolated static func changeRemovesJobManager(person: [String: Any], change: RulebookPersonAccessChange) -> Bool {
        callJSON("changeRemovesJobManager", arguments: [person, change.json]) as? Bool ?? false
    }

    /// `jobManagerRequiredError(managerIds)`: `JOB_MANAGER_REQUIRED_MESSAGE` when a new job names no manager, else nil.
    nonisolated static func jobManagerRequiredError(managerIds: [String]) -> String? {
        callJSON("jobManagerRequiredError", arguments: [managerIds]) as? String
    }

    /// `jobManagerRemovalWrites({ organizationId, person, change, jobs, roster, managers })`. Empty when nothing changes
    /// or the script did not answer.
    nonisolated static func jobManagerRemovalWrites(
        organizationId: String,
        person: [String: Any],
        change: RulebookPersonAccessChange,
        jobs: [[String: Any]],
        roster: [[String: Any]],
        managers: [[String: Any]]
    ) -> [RulebookJobManagerRemovalWrite] {
        let input: [String: Any] = [
            "organizationId": organizationId,
            "person": person,
            "change": change.json,
            "jobs": jobs,
            "roster": roster,
            "managers": managers,
        ]
        let rows = callJSON("jobManagerRemovalWrites", arguments: [input]) as? [[String: Any]] ?? []
        return rows.compactMap { row in
            guard let path = row["path"] as? String, let jobId = row["jobId"] as? String else { return nil }
            let set = row["set"] as? [String: Any] ?? [:]
            var lists: [String: [String]] = [:]
            for (key, value) in set { if let ids = value as? [String] { lists[key] = ids } }
            return RulebookJobManagerRemovalWrite(
                path: path,
                collection: row["collection"] as? String ?? "",
                jobId: jobId,
                setLists: lists,
                setManagerId: set["managerId"] as? String,
                remove: row["remove"] as? [String] ?? []
            )
        }
    }

    /// `JOB_MANAGER_REMOVED_NOTICE_TYPE` and `jobManagerRemovedNoticeText(name, jobCount)`.
    nonisolated static func jobManagerRemovedNoticeText(name: String, jobCount: Int) -> (title: String, message: String) {
        let row = callJSON("jobManagerRemovedNoticeText", arguments: [name, jobCount]) as? [String: Any]
        return (
            row?["title"] as? String ?? "Manager removed from jobs",
            row?["message"] as? String ?? "\(name) is no longer a manager and was removed from their jobs."
        )
    }

    // MARK: Change Super Admin, deactivate / reactivate (§11)

    private nonisolated static func pathWrites(_ raw: Any?) -> [RulebookPathWrite]? {
        guard let rows = raw as? [[String: Any]] else { return nil }
        return rows.compactMap { row in
            guard let path = row["path"] as? String, let kind = row["kind"] as? String else { return nil }
            var fields: [String: Sendable] = [:]
            for (key, value) in row["fields"] as? [String: Any] ?? [:] {
                if let flag = value as? Bool { fields[key] = flag } else if let text = value as? String { fields[key] = text }
            }
            return RulebookPathWrite(path: path, kind: kind, fields: fields)
        }
    }

    /// `superAdminTransferWrites({ organizationId, fromUserId, toUserId, previousCreatorUserId, roster })`: one batch.
    /// Nil when refused (`to` is `from` or missing) or the script did not answer.
    nonisolated static func superAdminTransferWrites(
        organizationId: String,
        fromUserId: String,
        toUserId: String,
        previousCreatorUserId: String?,
        roster: [[String: Any]]
    ) -> [RulebookPathWrite]? {
        let input: [String: Any] = [
            "organizationId": organizationId,
            "fromUserId": fromUserId,
            "toUserId": toUserId,
            "previousCreatorUserId": previousCreatorUserId ?? NSNull(),
            "roster": roster,
        ]
        guard let writes = pathWrites(callJSON("superAdminTransferWrites", arguments: [input])), !writes.isEmpty else { return nil }
        return writes
    }

    /// `userActiveWrites({ organizationId, person, isActive, roster, membershipExists })`: `isActive` on every users
    /// document of the person in this organisation and `accountActive` on their membership. RULEBOOK 1.33.0 (owner row
    /// 4 Nov): `person.organizationId` is the person's own company — their users document is written only when it is
    /// this one; `membershipExists` false leaves the membership out (nil: unknown, the app updates an existing one only).
    /// Empty when the script did not answer.
    nonisolated static func userActiveWrites(
        organizationId: String,
        personId: String,
        email: String?,
        personOrganizationId: String? = nil,
        isActive: Bool,
        roster: [[String: Any]],
        membershipExists: Bool? = nil
    ) -> [RulebookPathWrite] {
        var person: [String: Any] = ["id": personId, "email": (email as Any?) ?? NSNull()]
        if let personOrganizationId { person["organizationId"] = personOrganizationId }
        var input: [String: Any] = [
            "organizationId": organizationId,
            "person": person,
            "isActive": isActive,
            "roster": roster,
        ]
        if let membershipExists { input["membershipExists"] = membershipExists }
        return pathWrites(callJSON("userActiveWrites", arguments: [input])) ?? []
    }

    // MARK: Line manager set once, then locked (RULEBOOK 1.33.0 §11, owner decision 6 Nov)

    /// `canChangeLineManager(actor, target, { isCreate, invitation })`: admins any person, any time; a manager with the
    /// Operatives permission only for an operative, and only while adding them (`isCreate`) or on an invitation they
    /// sent that is not accepted yet; everyone else never. False when the script did not answer.
    nonisolated static func canChangeLineManager(
        actor: [String: Any],
        target: [String: Any],
        isCreate: Bool = false,
        invitation: (accepted: Bool, invitedBy: String)? = nil
    ) -> Bool {
        var options: [String: Any] = ["isCreate": isCreate]
        if let invitation { options["invitation"] = ["accepted": invitation.accepted, "invitedBy": invitation.invitedBy] }
        return callJSON("canChangeLineManager", arguments: [actor, target, options]) as? Bool ?? false
    }

    /// `lineManagerChanged(before, after)`: the stored line manager ids or `hasNoLineManager` differ (ids without
    /// case, order ignored). True when the script did not answer, so a locked screen refuses rather than writes.
    nonisolated static func lineManagerChanged(before: [String: Any], after: [String: Any]) -> Bool {
        callJSON("lineManagerChanged", arguments: [before, after]) as? Bool ?? true
    }

    /// `LINE_MANAGER_LOCKED_MESSAGE`.
    nonisolated static var lineManagerLockedMessage: String {
        constant("LINE_MANAGER_LOCKED_MESSAGE", as: String.self)
            ?? "Only an admin can change the line manager once this person has been added."
    }

    // MARK: One flag reader (§11)

    /// `userPermissionFlag(user, key)`: the top-level value when stored, else `permissions.{key}`, else off. Nil when
    /// the script did not answer.
    nonisolated static func userPermissionFlag(_ document: [String: Any], key: String) -> Bool? {
        guard JSONSerialization.isValidJSONObject([document]) else { return nil }
        return callJSON("userPermissionFlag", arguments: [document, key]) as? Bool
    }

    // MARK: Warning scope rows (§5)

    /// `isWarningRowInScope(scope, { jobIds, personIds, email })`. True for no scope or `{ kind: 'all' }`.
    nonisolated static func isWarningRowInScope(_ scope: Any?, jobIds: [String], personIds: [String], email: String? = nil) -> Bool {
        guard let scope, !(scope is NSNull) else { return true }
        let row: [String: Any] = ["jobIds": jobIds, "personIds": personIds, "email": email ?? NSNull()]
        return callJSON("isWarningRowInScope", arguments: [scope, row]) as? Bool ?? true
    }

    /// Whether a scope from `warningScopeFor` can list unbooked labour (`unbookedLabour`; `{ kind: 'all' }` can).
    nonisolated static func warningScopeListsUnbookedLabour(_ scope: [String: Any]?) -> Bool {
        guard let scope, (scope["kind"] as? String) == "jobs" else { return true }
        return scope["unbookedLabour"] as? Bool ?? false
    }
}

extension AppUser {
    /// The person as `canChangeLineManager` / `lineManagerChanged` read them (RULEBOOK 1.33.0 §11): the level flags and
    /// toggles (`permissionSubject`), every id and the line-manager fields (`RulebookPeople.person`).
    var lineManagerAccessRow: [String: Any] {
        var row = permissionSubject
        for (key, value) in RulebookPeople.person(self) where row[key] == nil { row[key] = value }
        return row
    }
}
