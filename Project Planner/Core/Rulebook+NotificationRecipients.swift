//
//  Rulebook+NotificationRecipients.swift
//  Project Planner
//
//  Rulebook 1.3.0 (docs/RULEBOOK.md §8, §9, §13): typed wrappers for the line-manager, self-approval and
//  notification-recipient functions, and the person / roster payloads every one of them reads. Every answer
//  comes from the packed script through `CanonicalBusinessEngine.callJSON`; nothing is decided here.
//

import Foundation

// MARK: - Script calls

extension CanonicalBusinessEngine {
    /// `lineManagerIds(user, roster)`: active line managers other than the person, alias ids resolved to the
    /// roster row's id. Nil when the script did not answer.
    nonisolated static func lineManagerIds(user: [String: Any], roster: [[String: Any]]) -> [String]? {
        callJSON("lineManagerIds", arguments: [user, roster]) as? [String]
    }

    /// `timesheetSelfSigned(user, roster)` (RULEBOOK 1.28.0): an admin with Timesheet self-sign on, or the
    /// organisation's Super Admin — line manager or not. Nil when the script did not answer.
    nonisolated static func timesheetSelfSigned(user: [String: Any], roster: [[String: Any]]) -> Bool? {
        callJSON("timesheetSelfSigned", arguments: [user, roster]) as? Bool
    }

    /// `leaveSubmitLabel(user, roster)`: "Submit" when the leave saves approved, else "Submit request".
    nonisolated static func leaveSubmitLabel(user: [String: Any], roster: [[String: Any]]) -> String? {
        callJSON("leaveSubmitLabel", arguments: [user, roster]) as? String
    }

    /// `personIdSet(person, roster)`: every id of the person (id, `formerUserIds`, `sameEmailUserIds`,
    /// same-email roster rows). Nil when the script did not answer.
    nonisolated static func personIdSet(person: [String: Any], roster: [[String: Any]]) -> [String]? {
        callJSON("personIdSet", arguments: [person, roster]) as? [String]
    }

    /// `excludeActor(ids, actor, roster, catalogue)`: `ids` without any id of the actor or inactive roster members.
    /// `actor` is a person payload or a bare id. RULEBOOK 1.16.0 §13: with a roster every id is first resolved to the
    /// person's signed-in account (`notificationRecipientAccountId`; `catalogue` for operatives rows), one per person,
    /// and an id the roster cannot resolve is dropped. Nil when the script did not answer.
    nonisolated static func excludeActor(
        ids: [String],
        actor: Any,
        roster: [[String: Any]],
        catalogue: [[String: Any]]? = nil
    ) -> [String]? {
        var arguments: [Any] = [ids, actor, roster]
        if let catalogue { arguments.append(catalogue) }
        return callJSON("excludeActor", arguments: arguments) as? [String]
    }

    /// `timesheetSubmittedRecipients(subject, roster)` (`timesheet_pending_manager_signoff`).
    nonisolated static func timesheetSubmittedRecipients(subject: Any, roster: [[String: Any]]) -> [String]? {
        callJSON("timesheetSubmittedRecipients", arguments: [subject, roster]) as? [String]
    }

    /// `timesheetSignedRecipients(subject, signer, roster)` (`timesheet_signed_by_manager`).
    nonisolated static func timesheetSignedRecipients(subject: Any, signer: Any, roster: [[String: Any]]) -> [String]? {
        callJSON("timesheetSignedRecipients", arguments: [subject, signer, roster]) as? [String]
    }

    /// `lineManagerPeerRecipients(subject, actor, roster)` (`line_manager_peer_update`).
    nonisolated static func lineManagerPeerRecipients(subject: Any, actor: Any, roster: [[String: Any]]) -> [String]? {
        callJSON("lineManagerPeerRecipients", arguments: [subject, actor, roster]) as? [String]
    }

    /// `holidayRequestRecipients(requester, roster)` (`holiday_request_submitted`).
    nonisolated static func holidayRequestRecipients(requester: Any, roster: [[String: Any]]) -> [String]? {
        callJSON("holidayRequestRecipients", arguments: [requester, roster]) as? [String]
    }

    /// `holidayDecisionRecipients(requester, decider, roster)` (`holiday_request_approved` / `_declined`).
    nonisolated static func holidayDecisionRecipients(requester: Any, decider: Any, roster: [[String: Any]]) -> [String]? {
        callJSON("holidayDecisionRecipients", arguments: [requester, decider, roster]) as? [String]
    }

    /// `bookingCreatedRecipients(bookedIds, booker, roster, catalogue)` (`booking_created`). RULEBOOK 1.16.0: booked ids
    /// may be operatives catalogue ids (`catalogue`), former or same-email ids in any case; each resolves to the
    /// person's account, one per person, never the booker (booking yourself writes nothing).
    nonisolated static func bookingCreatedRecipients(
        bookedIds: [String],
        booker: Any,
        roster: [[String: Any]],
        catalogue: [[String: Any]]? = nil
    ) -> [String]? {
        var arguments: [Any] = [bookedIds, booker, roster]
        if let catalogue { arguments.append(catalogue) }
        return callJSON("bookingCreatedRecipients", arguments: arguments) as? [String]
    }

    /// `deadlineAssignedRecipients(addedIds, actor, roster)` (`deadline_assigned`).
    nonisolated static func deadlineAssignedRecipients(addedIds: [String], actor: Any, roster: [[String: Any]]) -> [String]? {
        callJSON("deadlineAssignedRecipients", arguments: [addedIds, actor, roster]) as? [String]
    }

    /// `toolboxTalkRecipients(ids, issuer, roster)` (`toolbox_talk_issued`).
    nonisolated static func toolboxTalkRecipients(ids: [String], issuer: Any, roster: [[String: Any]]) -> [String]? {
        callJSON("toolboxTalkRecipients", arguments: [ids, issuer, roster]) as? [String]
    }

    /// `timesheetNotificationDedupeKey`: the de-dupe key for a timesheet notice, the period start written as
    /// unix seconds of that day's midnight in the organisation zone. Nil for a bad input or no answer.
    nonisolated static func timesheetNotificationDedupeKey(
        type: String,
        subjectId: String,
        periodStartDayKey: String,
        timeZone: String,
        recipientId: String? = nil
    ) -> String? {
        var input: [String: Any] = [
            "type": type,
            "subjectId": subjectId,
            "periodStartDayKey": periodStartDayKey,
            "timeZone": timeZone,
        ]
        if let recipientId { input["recipientId"] = recipientId }
        return callJSON("timesheetNotificationDedupeKey", arguments: [input]) as? String
    }

    /// `inboxNotificationVisibleToUser(row, ids)`: the row's `userId` is one of the person's ids. Ownerless rows
    /// are not inbox rows. Nil when the script did not answer.
    /// RULEBOOK 1.10.0 §13: with `createdAtMs` and `now`, a row dated after `now` is not listed yet (rows count from
    /// their `createdAt`).
    /// RULEBOOK 1.16.0: with the row `type`, only a scheduled type (`SCHEDULED_NOTIFICATION_TYPES`) waits for its
    /// `createdAt`; any other row is listed unless it is more than `INBOX_CREATED_AT_SKEW_MS` ahead of `now`.
    nonisolated static func inboxNotificationVisibleToUser(
        rowUserId: String?,
        userIds: [String],
        createdAtMs: Double? = nil,
        now: Date? = nil,
        type: String? = nil
    ) -> Bool? {
        var row: [String: Any] = ["userId": rowUserId.map { $0 as Any } ?? NSNull()]
        if let createdAtMs { row["createdAt"] = createdAtMs }
        if let type { row["type"] = type }
        var arguments: [Any] = [row, userIds]
        if let now { arguments.append(now.timeIntervalSince1970 * 1000) }
        return callJSON("inboxNotificationVisibleToUser", arguments: arguments) as? Bool
    }

    /// `unreadNotificationBadgeCount(rows, ids)`: unread rows addressed to one of the person's ids.
    /// Nil when the script did not answer.
    /// RULEBOOK 1.16.0: `types` (per row) makes the count skew-tolerant the same way as the inbox list.
    static func unreadNotificationBadgeCount(
        rows: [CanonicalUnreadNotificationRow],
        userIds: [String],
        createdAtMs: [Double?]? = nil,
        now: Date? = nil,
        types: [String]? = nil
    ) -> Int? {
        let payload: [[String: Any]] = rows.enumerated().map { index, row in
            var out: [String: Any] = ["userId": row.userId.map { $0 as Any } ?? NSNull(), "isRead": row.isRead]
            if let list = createdAtMs, index < list.count, let created = list[index] { out["createdAt"] = created }
            if let types, index < types.count { out["type"] = types[index] }
            return out
        }
        var arguments: [Any] = [payload, userIds]
        if let now { arguments.append(now.timeIntervalSince1970 * 1000) }
        return (callJSON("unreadNotificationBadgeCount", arguments: arguments) as? NSNumber)?.intValue
    }
}

// MARK: - People as the rules read them

/// The `users` row as the line-manager, leave and notification rules read it (web `lib/staff/rulebookPeople.ts`):
/// id, email, active flag, resolved role, the role flags, every alias id and the line-manager fields.
/// No rule is decided here.
enum RulebookPeople {
    /// One person (`PersonRosterRow` & `LeaveSelfBookUser`). Pass the user as it will be saved when validating an edit.
    static func person(_ user: AppUser) -> [String: Any] {
        var row: [String: Any] = [
            "id": user.id,
            "email": user.email,
            "isActive": user.isActive,
            "role": AnnualLeaveApproval.rolePayload(user),
            "isSuperAdmin": user.isSuperAdmin,
            "adminAccess": user.permissions.adminAccess,
            "isAdmin": user.permissions.adminAccess,
            "manager": user.permissions.manager,
            // The stored flag, as `adminOutsideOperativeMode` and the security rules read it (RULEBOOK 1.6.0 §8):
            // a stray flag on an admin is ignored on lists (`permissions.operativeMode`) but still counts here.
            "operativeMode": user.permissions.operativeMode || (user.isRosterAdmin && user.operativeModeStored),
            "annualLeaveSelfBook": user.permissions.annualLeaveSelfBook,
            // RULEBOOK 1.28.0 `selfManageToggles`: Timesheet self-sign (admins only) and PAYE (no timesheets).
            "timesheetSelfSign": user.permissions.timesheetSelfSign,
            "employmentType": user.employmentType.rawValue,
            "annualLeaveEnabled": user.annualLeaveEnabled,
            "formerUserIds": user.formerUserIds,
            "sameEmailUserIds": user.sameEmailUserIds,
            "assignedManagerUserIds": user.assignedManagerUserIds,
            "hasNoLineManager": user.hasNoLineManager,
            // RULEBOOK 1.16.0 `notificationRecipientAccountId`: the signed-up row is the person's account.
            "passwordSet": user.passwordSet,
            // RULEBOOK 1.34.0 §11, §13: a ghost operative is never a recipient, a timesheet subject or a candidate.
            "ghost": user.isGhost,
        ]
        if let legacy = user.assignedManagerUserId { row["assignedManagerUserId"] = legacy }
        // RULEBOOK 1.28.0 `isOrganizationSuperAdmin` (web `rulebookPerson.organizationSuperAdmin`): the Super Admin of
        // the open organisation — its creator even without the flag, never another company's Super Admin visiting.
        if let organizationSuperAdmin = user.organizationSuperAdmin { row["organizationSuperAdmin"] = organizationSuperAdmin }
        return row
    }

    /// The organisation roster: one `person` per `users` row.
    static func roster(_ users: [AppUser]) -> [[String: Any]] {
        users.map { person($0) }
    }

    /// Every id the person goes by (`personIdSet`): their inbox owner ids. Falls back to the stored ids when the
    /// script did not answer.
    static func ownerIds(for user: AppUser, users: [AppUser]) -> [String] {
        if let ids = CanonicalBusinessEngine.personIdSet(person: person(user), roster: roster(users)), !ids.isEmpty {
            return ids
        }
        return [user.id] + user.formerUserIds + user.sameEmailUserIds
    }

    /// `timesheetSelfSigned(user, roster)`. Nil when the script did not answer.
    static func timesheetSelfSigned(_ user: AppUser, users: [AppUser]) -> Bool? {
        CanonicalBusinessEngine.timesheetSelfSigned(user: person(user), roster: roster(users))
    }

    /// `leaveSubmitLabel(user, roster)`. Nil when the script did not answer.
    static func leaveSubmitLabel(_ user: AppUser, users: [AppUser]) -> String? {
        CanonicalBusinessEngine.leaveSubmitLabel(user: person(user), roster: roster(users))
    }
}

/// The live organisation roster (`UserStore.organizationUsers`) for rules that run where no store is passed in,
/// such as `TimesheetApprovalPolicy` (`timesheetSelfSigned`). Updated on every roster change; answers are
/// memoised per roster revision.
enum RulebookRosterSnapshot {
    private(set) static var users: [AppUser] = []
    private(set) static var revision = 0
    private static var cachedRoster: [[String: Any]]?
    private static var selfSignedCache: [AppUser: Bool] = [:]
    private static var lineManagerIdsCache: [AppUser: [String]] = [:]

    static func update(_ users: [AppUser]) {
        guard users != self.users else { return }
        self.users = users
        revision &+= 1
        cachedRoster = nil
        selfSignedCache = [:]
        lineManagerIdsCache = [:]
        // RULEBOOK 1.27.0 §8: the catalogue operatives' pay overlay depends on the roster (`OperativeStore`).
        NotificationCenter.default.post(name: .rulebookRosterDidChange, object: nil)
    }

    /// RULEBOOK 1.28.0: the open organisation or its creator changed (`isOrganizationSuperAdmin`): drop memoised
    /// answers so the Super Admin's self-manage toggles are read again.
    static func invalidateAnswers() {
        cachedRoster = nil
        selfSignedCache = [:]
        lineManagerIdsCache = [:]
    }

    /// `RulebookPeople.roster(users)`, built once per revision.
    static var roster: [[String: Any]] {
        if let cachedRoster { return cachedRoster }
        let built = RulebookPeople.roster(users)
        cachedRoster = built
        return built
    }

    /// `timesheetSelfSigned(user, roster)` against the live roster. Nil when the script did not answer.
    static func timesheetSelfSigned(_ user: AppUser) -> Bool? {
        if let known = selfSignedCache[user] { return known }
        guard let answer = CanonicalBusinessEngine.timesheetSelfSigned(user: RulebookPeople.person(user), roster: roster) else {
            return nil
        }
        selfSignedCache[user] = answer
        return answer
    }

    /// `lineManagerIds(user, roster)` against the live roster. Nil when the script did not answer.
    static func lineManagerIds(_ user: AppUser) -> [String]? {
        if let known = lineManagerIdsCache[user] { return known }
        guard let answer = CanonicalBusinessEngine.lineManagerIds(user: RulebookPeople.person(user), roster: roster) else {
            return nil
        }
        lineManagerIdsCache[user] = answer
        return answer
    }
}

/// Annual-leave inbox copy shared with web (`lib/annualLeave/notifyHolidayRequestSubmitted.ts`,
/// `notifyHolidayRequestDecision.ts` `annualLeaveDecisionDateText`): "20 Oct 2026", "20 Oct 2026 (FULL DAY)",
/// "20 Oct 2026 – 22 Oct 2026 (PM)". Fixed en_GB format in the organisation zone, never the device locale, so
/// both apps write the same message and de-dupe key. Presentation only; no rule is decided here.
enum AnnualLeaveNoticeText {
    static func abbreviatedDay(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_GB")
        formatter.timeZone = OrganizationRulebookContext.timeZone
        formatter.dateFormat = "d MMM yyyy"
        return formatter.string(from: date)
    }

    /// `annualLeaveDecisionDateText`: the day (or range) plus the slot raw value.
    static func decisionDateText(_ booking: HolidayBooking) -> String {
        let start = abbreviatedDay(booking.startDate)
        if OrganizationRulebookContext.dayKey(booking.startDate) == OrganizationRulebookContext.dayKey(booking.endDate) {
            return "\(start) (\(booking.timeSlot.rawValue))"
        }
        return "\(start) – \(abbreviatedDay(booking.endDate)) (\(booking.timeSlot.rawValue))"
    }

    /// "{start} – {end}" for a leave request or cancellation request notice.
    static func requestRange(start: Date, end: Date) -> String {
        "\(abbreviatedDay(start)) – \(abbreviatedDay(end))"
    }
}
