//
//  Rulebook+Ghosts.swift
//  Project Planner
//
//  Rulebook 1.34.0 (docs/RULEBOOK.md §11 "Ghost operatives"): a bookable operative with no app login, no email and
//  no phone. Web `lib/canonical/ghostOperatives.ts` (and `isGhostUser` / `rosterSegment` / `listedRosterUsers` in
//  `userRosterSegment.ts`), called through `CanonicalBusinessEngine`:
//    - `canCreateGhost`, `ghostAddFormRows`, `ghostCreateError`, `ghostCreateWrites` — Add user with Ghost account on;
//    - `ghostBadgeLabel`, `personDedupeKey` — list badges and the picker fold (a ghost has no email);
//    - `canBookLeaveFor`, `ghostLeaveBooking` — leave booked for a ghost (approved, nobody notified);
//    - `canUpgradeGhost`, `ghostUpgradeRefusal`, `ghostUpgradeWrites` — admin-only Give app access;
//    - `rosterSegment` / `listedRosterUsers` with `ghost` (the Canonical/ wrappers' row has no `ghost` key, so a ghost
//      read as a pending leftover there).
//  Nothing is decided here; when the script does not answer, a ghost is never created and nothing is shown as allowed.
//

import Foundation

/// One `ghostAddFormRows` row.
nonisolated struct RulebookGhostFormRow: Equatable, Sendable {
    var field: String
    var visible: Bool
    var required: Bool
}

/// One write of a `ghostCreateWrites` plan: a whole document, plus the fields the app sets to server time.
nonisolated struct RulebookGhostWrite: @unchecked Sendable {
    var path: String
    var fields: [String: Any]
    var serverTimestampFields: [String]
}

/// `ghostCreateWrites(...)`: `users/{ghostId}` and, while `privatePay` is on, `payProfiles/{ghostId}`.
nonisolated struct RulebookGhostCreatePlan: @unchecked Sendable {
    var user: RulebookGhostWrite
    var payProfile: RulebookGhostWrite?
}

/// `ghostUpgradeWrites(...)`: the ghost's partial update, the invitation and the email claim (one batch).
nonisolated struct RulebookGhostUpgradePlan: @unchecked Sendable {
    var userPath: String
    var userSet: [String: Any]
    var userRemove: [String]
    var invitationPath: String
    var invitationFields: [String: Any]
    var claimPath: String
    var claimFields: [String: Any]
}

extension CanonicalBusinessEngine {
    // MARK: Copy

    /// A string constant the script exports, else `fallback` (shown only when the script did not load).
    nonisolated static func ghostText(_ name: String, fallback: String) -> String {
        constant(name, as: String.self) ?? fallback
    }

    nonisolated static var ghostToggleLabel: String { ghostText("GHOST_TOGGLE_LABEL", fallback: "Ghost account") }
    nonisolated static var ghostToggleHelp: String {
        ghostText("GHOST_TOGGLE_HELP", fallback: "For someone who works for you but does not use the app.")
    }
    nonisolated static var ghostOperativeExplanation: String { ghostText("GHOST_OPERATIVE_EXPLANATION", fallback: "") }
    nonisolated static var ghostUpgradeLabel: String { ghostText("GHOST_UPGRADE_LABEL", fallback: "Give app access") }
    nonisolated static var ghostUpgradeHelp: String { ghostText("GHOST_UPGRADE_HELP", fallback: "") }
    nonisolated static var ghostLineManagerRequiredMessage: String {
        ghostText("GHOST_LINE_MANAGER_REQUIRED_MESSAGE", fallback: "")
    }
    nonisolated static var ghostLineManagerInvalidMessage: String {
        ghostText("GHOST_LINE_MANAGER_INVALID_MESSAGE", fallback: "")
    }
    nonisolated static var ghostRateRequiredMessage: String { ghostText("GHOST_RATE_REQUIRED_MESSAGE", fallback: "") }

    /// `GHOST_UPGRADE_REFUSAL_MESSAGES[code]`.
    nonisolated static func ghostUpgradeRefusalMessage(_ code: String) -> String {
        let messages = constant("GHOST_UPGRADE_REFUSAL_MESSAGES", as: [String: String].self) ?? [:]
        return messages[code] ?? "Only an admin can give a ghost app access."
    }

    // MARK: Reading

    /// `isGhostUser(row)`. False when the script did not answer.
    nonisolated static func isGhostUser(_ row: [String: Any]) -> Bool {
        callJSON("isGhostUser", arguments: [row]) as? Bool ?? false
    }

    /// `ghostBadgeLabel(person)`: "No app login", "No app login · Invited", or "" for anyone else.
    nonisolated static func ghostBadgeLabel(ghost: Bool, email: String) -> String {
        guard ghost else { return "" }
        return callJSON("ghostBadgeLabel", arguments: [["ghost": true, "email": email] as [String: Any]]) as? String ?? ""
    }

    /// `personDedupeKey({ id, email })`: the email (trimmed, lower case), else `id:` + the id. Nil when the script did
    /// not answer.
    nonisolated static func personDedupeKey(id: String, email: String) -> String? {
        callJSON("personDedupeKey", arguments: [["id": id, "email": email] as [String: Any]]) as? String
    }

    /// `rosterSegment(profile)` for a roster row that carries `ghost`. Nil when the script did not answer.
    nonisolated static func rosterSegmentForRow(_ row: [String: Any]) -> String? {
        callJSON("rosterSegment", arguments: [row]) as? String
    }

    /// `listedRosterUsers(rows, claimedEmails)` for rows that carry `ghost`: the ids kept, in order. Nil when the
    /// script did not answer. `claimedEmails` nil means the `userEmails` read failed.
    nonisolated static func listedRosterRowIds(_ rows: [[String: Any]], claimedEmails: [String]?) -> [String]? {
        let claimed: Any = claimedEmails.map { $0 as Any } ?? NSNull()
        guard let listed = callJSON("listedRosterUsers", arguments: [rows, claimed]) as? [[String: Any]] else { return nil }
        return listed.compactMap { $0["id"] as? String }
    }

    // MARK: Creating

    /// `canCreateGhost(viewer)` (= `canManageOperatives`). False when the script did not answer.
    nonisolated static func canCreateGhost(viewer: [String: Any]) -> Bool {
        callJSON("canCreateGhost", arguments: [viewer]) as? Bool ?? false
    }

    /// `ghostAddFormRows({ ghost, canCreateGhost })`. Nil when the script did not answer.
    nonisolated static func ghostAddFormRows(ghost: Bool, canCreateGhost: Bool) -> [RulebookGhostFormRow]? {
        let input: [String: Any] = ["ghost": ghost, "canCreateGhost": canCreateGhost]
        guard let rows = callJSON("ghostAddFormRows", arguments: [input]) as? [[String: Any]] else { return nil }
        return rows.compactMap { row in
            guard let field = row["field"] as? String else { return nil }
            return RulebookGhostFormRow(
                field: field,
                visible: row["visible"] as? Bool ?? false,
                required: row["required"] as? Bool ?? false
            )
        }
    }

    /// `ghostCreateError(draft, { roster })`: `.some(nil)` when the draft is fine, `.some(message)` when refused, nil
    /// when the script did not answer.
    nonisolated static func ghostCreateError(draft: [String: Any], roster: [[String: Any]]?) -> String?? {
        let options: [String: Any] = ["roster": roster.map { $0 as Any } ?? NSNull()]
        guard let answer = callJSON("ghostCreateError", arguments: [draft, options]) else { return nil }
        if answer is NSNull { return .some(nil) }
        return .some(answer as? String)
    }

    private nonisolated static func ghostWrite(_ raw: Any?) -> RulebookGhostWrite? {
        guard let row = raw as? [String: Any],
              let path = row["path"] as? String, !path.isEmpty,
              let fields = row["fields"] as? [String: Any] else { return nil }
        return RulebookGhostWrite(path: path, fields: fields, serverTimestampFields: row["serverTimestampFields"] as? [String] ?? [])
    }

    /// `ghostCreateWrites({ organizationId, ghostId, draft, actorUserId, platform: 'ios', privatePay, roster })`. Nil
    /// when the draft is refused or the script did not answer. The write has `email: ''` and no `isSuperAdmin` key;
    /// keep it exactly (the rules and the emulator depend on that shape).
    nonisolated static func ghostCreateWrites(
        organizationId: String,
        ghostId: String,
        draft: [String: Any],
        actorUserId: String,
        privatePay: Bool,
        roster: [[String: Any]]?
    ) -> RulebookGhostCreatePlan? {
        let input: [String: Any] = [
            "organizationId": organizationId,
            "ghostId": ghostId,
            "draft": draft,
            "actorUserId": actorUserId,
            "platform": "ios",
            "privatePay": privatePay,
            "roster": roster.map { $0 as Any } ?? NSNull(),
        ]
        guard let plan = callJSON("ghostCreateWrites", arguments: [input]) as? [String: Any],
              let user = ghostWrite(plan["user"]) else { return nil }
        return RulebookGhostCreatePlan(user: user, payProfile: ghostWrite(plan["payProfile"]))
    }

    // MARK: Leave

    /// `canBookLeaveFor(viewer, person, roster)`. False when the script did not answer.
    nonisolated static func canBookLeaveFor(viewer: [String: Any], person: [String: Any], roster: [[String: Any]]) -> Bool {
        callJSON("canBookLeaveFor", arguments: [viewer, person, roster]) as? Bool ?? false
    }

    /// `ghostLeaveBooking(viewer, ghost, roster)` → `(allowed, status, notify)`. Nil when the script did not answer.
    nonisolated static func ghostLeaveBooking(
        viewer: [String: Any],
        ghost: [String: Any],
        roster: [[String: Any]]
    ) -> (allowed: Bool, status: String, notify: Bool)? {
        guard let row = callJSON("ghostLeaveBooking", arguments: [viewer, ghost, roster]) as? [String: Any] else { return nil }
        return (row["allowed"] as? Bool ?? false, row["status"] as? String ?? "approved", row["notify"] as? Bool ?? false)
    }

    // MARK: Giving app access

    /// `ghostUpgradeRefusal(viewer, ghost, email?)`: `.some(nil)` allowed, `.some(code)` refused, nil when the script did
    /// not answer. Pass `email` nil to ask only whether the button is shown.
    nonisolated static func ghostUpgradeRefusal(viewer: [String: Any], ghost: [String: Any], email: String?) -> String?? {
        var arguments: [Any] = [viewer, ghost]
        if let email { arguments.append(email) }
        guard let answer = callJSON("ghostUpgradeRefusal", arguments: arguments) else { return nil }
        if answer is NSNull { return .some(nil) }
        return .some(answer as? String)
    }

    /// `canUpgradeGhost(viewer, ghost)`. False when the script did not answer.
    nonisolated static func canUpgradeGhost(viewer: [String: Any], ghost: [String: Any]) -> Bool {
        callJSON("canUpgradeGhost", arguments: [viewer, ghost]) as? Bool ?? false
    }

    /// `ghostUpgradeWrites({ ... platform: 'ios' })`. `nowMs` stands in for `createdAt` on the invitation; the app
    /// writes its own server time there. Nil when refused or the script did not answer.
    nonisolated static func ghostUpgradeWrites(
        viewer: [String: Any],
        organizationId: String,
        ghostId: String,
        ghost: [String: Any],
        email: String,
        invitationId: String,
        invitedBy: String,
        nowMs: Double,
        actorUserId: String
    ) -> RulebookGhostUpgradePlan? {
        let input: [String: Any] = [
            "viewer": viewer,
            "organizationId": organizationId,
            "ghostId": ghostId,
            "ghost": ghost,
            "email": email,
            "invitationId": invitationId,
            "invitedBy": invitedBy,
            "now": nowMs,
            "actorUserId": actorUserId,
            "platform": "ios",
        ]
        guard let plan = callJSON("ghostUpgradeWrites", arguments: [input]) as? [String: Any],
              let user = plan["user"] as? [String: Any], let userPath = user["path"] as? String,
              let invitation = plan["invitation"] as? [String: Any], let invitationPath = invitation["path"] as? String,
              let claim = plan["claim"] as? [String: Any], let claimPath = claim["path"] as? String else { return nil }
        return RulebookGhostUpgradePlan(
            userPath: userPath,
            userSet: user["set"] as? [String: Any] ?? [:],
            userRemove: user["remove"] as? [String] ?? [],
            invitationPath: invitationPath,
            invitationFields: invitation["fields"] as? [String: Any] ?? [:],
            claimPath: claimPath,
            claimFields: claim["fields"] as? [String: Any] ?? [:]
        )
    }
}

/// App-side shapes for the ghost rules (rows built from `AppUser`, the folds the screens use). Decides nothing.
@MainActor
enum GhostRulebook {
    /// A roster row as `rosterSegment` / `listedRosterUsers` read it, `ghost` included.
    static func rosterProfileRow(_ user: AppUser) -> [String: Any] {
        var row: [String: Any] = [
            "id": user.id,
            "email": user.email,
            "firstName": user.firstName,
            "surname": user.surname,
            "name": user.documentName,
            "displayName": user.documentDisplayName,
            "passwordSet": user.passwordSet,
            "isActive": user.isActive,
            "ghost": user.isGhost,
        ]
        if let mobile = user.mobileNumber { row["mobileNumber"] = mobile }
        return row
    }

    /// `rosterSegment` for the person, `ghost` included (a ghost is Active or Inactive, never Pending).
    static func segment(_ user: AppUser) -> String? {
        CanonicalBusinessEngine.rosterSegmentForRow(rosterProfileRow(user))
    }

    /// `listedRosterUsers` over the people, `ghost` included (a ghost is never a leftover invite). Nil when the script
    /// did not answer.
    static func listed(_ users: [AppUser], claimedEmails: Set<String>?) -> [AppUser]? {
        guard let ids = CanonicalBusinessEngine.listedRosterRowIds(
            users.map { rosterProfileRow($0) },
            claimedEmails: claimedEmails.map { Array($0).sorted() }
        ) else { return nil }
        var byId: [String: AppUser] = [:]
        for user in users where byId[user.id] == nil { byId[user.id] = user }
        return ids.compactMap { byId[$0] }
    }

    /// `personDedupeKey`: the key pickers fold people on, so every person with no email (ghosts) stays one row each.
    /// Falls back to the same email-else-id key spelling when the script did not answer.
    nonisolated static func dedupeKey(id: String, email: String) -> String {
        if let key = CanonicalBusinessEngine.personDedupeKey(id: id, email: email) { return key }
        let mail = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if !mail.isEmpty { return mail }
        let trimmedId = id.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return trimmedId.isEmpty ? "" : "id:\(trimmedId)"
    }

    /// `ghostBadgeLabel` for a list or picker row ("" for anyone who is not a ghost).
    static func badge(_ user: AppUser) -> String {
        CanonicalBusinessEngine.ghostBadgeLabel(ghost: user.isGhost, email: user.email)
    }

    /// The viewer row the ghost rules read: the level fields (`permissionSubject`) and the active flag.
    static func viewer(_ user: AppUser) -> [String: Any] {
        var row = user.permissionSubject
        row["id"] = user.id
        row["isActive"] = user.isActive
        return row
    }

    /// `canCreateGhost(viewer)`.
    static func canCreateGhost(_ viewer: AppUser?) -> Bool {
        guard let viewer else { return false }
        return CanonicalBusinessEngine.canCreateGhost(viewer: self.viewer(viewer))
    }

    /// The ghost as `ghostUpgradeRefusal` / `ghostUpgradeWrites` read `users/{ghostId}`: the stored fields the app holds.
    static func storedGhostRow(_ user: AppUser) -> [String: Any] {
        var row: [String: Any] = [
            "ghost": user.isGhost,
            "email": user.email,
            "isActive": user.isActive,
            "firstName": user.firstName,
            "surname": user.surname,
            "assignedManagerUserIds": user.assignedManagerUserIds,
            "annualLeaveEnabled": user.annualLeaveEnabled,
        ]
        if let first = user.assignedManagerUserId { row["assignedManagerUserId"] = first }
        if let basis = user.payBasis { row["payBasis"] = basis }
        if let rate = user.dayRate { row["dayRate"] = rate }
        if let rate = user.hourlyRate { row["hourlyRate"] = rate }
        if let preset = user.tradeTypePreset { row["tradeTypePreset"] = preset }
        if let custom = user.tradeTypeCustom { row["tradeTypeCustom"] = custom }
        if let hint = user.inviteEmailHint { row["inviteEmailHint"] = hint }
        return row
    }

    /// Whether Give app access is shown on this person's profile (`canUpgradeGhost`: admins, an active ghost not invited).
    static func canUpgrade(viewer: AppUser?, ghost: AppUser) -> Bool {
        guard let viewer, ghost.isGhost else { return false }
        return CanonicalBusinessEngine.canUpgradeGhost(viewer: self.viewer(viewer), ghost: storedGhostRow(ghost))
    }

    /// `ghostLeaveBooking(viewer, ghost, roster)` with the rulebook person rows.
    static func leaveBooking(viewer: AppUser, ghost: AppUser, roster: [AppUser]) -> (allowed: Bool, status: String, notify: Bool)? {
        CanonicalBusinessEngine.ghostLeaveBooking(
            viewer: RulebookPeople.person(viewer),
            ghost: RulebookPeople.person(ghost),
            roster: RulebookPeople.roster(roster)
        )
    }
}
