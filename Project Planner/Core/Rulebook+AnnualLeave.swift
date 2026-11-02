//
//  Rulebook+AnnualLeave.swift
//  Project Planner
//
//  Typed wrappers for the rulebook's annual-leave and notification functions (docs/RULEBOOK.md §9,
//  §10, §13). Every answer comes from the packed script through `CanonicalBusinessEngine.callJSON`;
//  nothing is decided here.
//

import Foundation

/// One `holidayRequestRanges` range: calendar-consecutive days with the same slot.
nonisolated struct CanonicalHolidayRequestRange: Equatable, Hashable, Sendable {
    let startDayKey: String
    let endDayKey: String
    /// `FULL DAY`, `AM` or `PM`.
    let timeSlot: String
}

/// `holidayRequestWriteFields`: the fields of a new leave request document.
nonisolated struct CanonicalHolidayRequestFields: Equatable, Sendable {
    let id: String
    let organizationId: String
    let userId: String?
    let operativeId: String?
    /// Organisation-zone midnight of the first day (`startDateMs`).
    let startDate: Date
    /// Organisation-zone midnight of the last day (`endDateMs`).
    let endDate: Date
    let startDayKey: String
    let endDayKey: String
    let status: String
    let timeSlot: String
    let approvedByUserId: String?
}

/// `holidayDecisionWriteFields`: approve or decline in one partial update.
nonisolated struct CanonicalHolidayDecisionFields: Equatable, Sendable {
    /// `approved` or `rejected`.
    let status: String
    let approvedByUserId: String
    /// Trimmed note, nil when blank (the write clears it).
    let decisionNote: String?
}

extension CanonicalBusinessEngine {
    // MARK: - Leave requests (§9)

    /// `holidayRequestRanges(picks, timeZone)`. Nil when the script did not answer.
    nonisolated static func holidayRequestRanges(
        picks: [(dayKey: String, timeSlot: String)],
        timeZone: String = OrganizationRulebookContext.timeZoneIdentifier
    ) -> [CanonicalHolidayRequestRange]? {
        let payload: [[String: Any]] = picks.map { ["dayKey": $0.dayKey, "timeSlot": $0.timeSlot] }
        guard let rows = callJSON("holidayRequestRanges", arguments: [payload, timeZone]) as? [[String: Any]] else {
            return nil
        }
        return rows.compactMap { row in
            guard let start = row["startDayKey"] as? String,
                  let end = row["endDayKey"] as? String,
                  let slot = row["timeSlot"] as? String else { return nil }
            return CanonicalHolidayRequestRange(startDayKey: start, endDayKey: end, timeSlot: slot)
        }
    }

    /// `holidayRequestWriteFields(input)`. Nil when the id, organisation, person or first day is missing,
    /// or the script did not answer.
    nonisolated static func holidayRequestWriteFields(
        id: String,
        organizationId: String,
        userId: String?,
        operativeId: String?,
        startDayKey: String,
        endDayKey: String?,
        timeSlot: String?,
        status: String?,
        approvedByUserId: String?,
        timeZone: String = OrganizationRulebookContext.timeZoneIdentifier
    ) -> CanonicalHolidayRequestFields? {
        var input: [String: Any] = [
            "id": id,
            "organizationId": organizationId,
            "startDayKey": startDayKey,
            "timeZone": timeZone,
        ]
        if let userId { input["userId"] = userId }
        if let operativeId { input["operativeId"] = operativeId }
        if let endDayKey { input["endDayKey"] = endDayKey }
        if let timeSlot { input["timeSlot"] = timeSlot }
        if let status { input["status"] = status }
        if let approvedByUserId { input["approvedByUserId"] = approvedByUserId }
        guard let row = callJSON("holidayRequestWriteFields", arguments: [input]) as? [String: Any],
              let rowId = row["id"] as? String,
              let org = row["organizationId"] as? String,
              let startMs = (row["startDateMs"] as? NSNumber)?.doubleValue,
              let endMs = (row["endDateMs"] as? NSNumber)?.doubleValue,
              let start = row["startDayKey"] as? String,
              let end = row["endDayKey"] as? String,
              let rowStatus = row["status"] as? String,
              let slot = row["timeSlot"] as? String else {
            return nil
        }
        return CanonicalHolidayRequestFields(
            id: rowId,
            organizationId: org,
            userId: row["userId"] as? String,
            operativeId: row["operativeId"] as? String,
            startDate: Date(timeIntervalSince1970: startMs / 1000),
            endDate: Date(timeIntervalSince1970: endMs / 1000),
            startDayKey: start,
            endDayKey: end,
            status: rowStatus,
            timeSlot: slot,
            approvedByUserId: row["approvedByUserId"] as? String
        )
    }

    /// `holidayDecisionWriteFields({ status, approverUid, decisionNote })`. Nil when the decision is not
    /// valid or the script did not answer.
    nonisolated static func holidayDecisionWriteFields(
        status: String,
        approverUid: String,
        decisionNote: String?
    ) -> CanonicalHolidayDecisionFields? {
        var input: [String: Any] = ["status": status, "approverUid": approverUid]
        if let decisionNote { input["decisionNote"] = decisionNote }
        guard let row = callJSON("holidayDecisionWriteFields", arguments: [input]) as? [String: Any],
              let rowStatus = row["status"] as? String,
              let approver = row["approvedByUserId"] as? String else {
            return nil
        }
        return CanonicalHolidayDecisionFields(
            status: rowStatus,
            approvedByUserId: approver,
            decisionNote: row["decisionNote"] as? String
        )
    }

    /// `parseHolidayDecisionNote(value)`: trimmed text, nil when missing or blank.
    nonisolated static func parseHolidayDecisionNote(_ value: String?) -> String? {
        callJSON("parseHolidayDecisionNote", arguments: [value ?? NSNull()]) as? String
    }

    /// `leaveRecordDayKeys(record, timeZone, nonWorkingDayKeys)`: the days a record takes from the
    /// allowance. Nil when the script did not answer.
    nonisolated static func leaveRecordDayKeys(
        startDayKey: String,
        endDayKey: String?,
        nonWorkingDayKeys: [String] = [],
        timeZone: String = OrganizationRulebookContext.timeZoneIdentifier
    ) -> [String]? {
        var record: [String: Any] = ["startDayKey": startDayKey]
        if let endDayKey { record["endDayKey"] = endDayKey }
        return callJSON("leaveRecordDayKeys", arguments: [record, timeZone, nonWorkingDayKeys]) as? [String]
    }

    /// `annualLeaveBalance(input)` with `nonWorkingDayKeys` (the organisation's bank holidays), so a
    /// multi-day record does not count a bank holiday. A nil argument is left out of the call, as the
    /// engine's own wrapper does. Nil when the script did not answer.
    nonisolated static func annualLeaveBalance(
        annualLeaveEnabled: Bool?,
        daysPerYear: Double?,
        startMonth: Int?,
        endMonth: Int?,
        orgDaysPerYear: Double?,
        orgStartMonth: Int?,
        orgEndMonth: Int?,
        carriesOver: Bool?,
        yearAllowance: Double?,
        yearAllowanceKey: String?,
        bookings: [CanonicalLeaveBooking],
        onDayKey: String,
        nonWorkingDayKeys: [String],
        timeZone: String = OrganizationRulebookContext.timeZoneIdentifier
    ) -> CanonicalAnnualLeaveBalance? {
        var input: [String: Any] = [
            "onDayKey": onDayKey,
            "timeZone": timeZone,
            "nonWorkingDayKeys": nonWorkingDayKeys,
            "bookings": bookings.map { booking -> [String: Any] in
                var row: [String: Any] = ["startDayKey": booking.startDayKey, "endDayKey": booking.endDayKey]
                if let slot = booking.timeSlot { row["timeSlot"] = slot }
                if let status = booking.status { row["status"] = status }
                return row
            },
        ]
        if let annualLeaveEnabled { input["annualLeaveEnabled"] = annualLeaveEnabled }
        if let daysPerYear, daysPerYear.isFinite { input["daysPerYear"] = daysPerYear }
        if let startMonth { input["startMonth"] = startMonth }
        if let endMonth { input["endMonth"] = endMonth }
        if let orgDaysPerYear, orgDaysPerYear.isFinite { input["orgDaysPerYear"] = orgDaysPerYear }
        if let orgStartMonth { input["orgStartMonth"] = orgStartMonth }
        if let orgEndMonth { input["orgEndMonth"] = orgEndMonth }
        if let carriesOver { input["carriesOver"] = carriesOver }
        if let yearAllowance, yearAllowance.isFinite { input["yearAllowance"] = yearAllowance }
        if let yearAllowanceKey { input["yearAllowanceKey"] = yearAllowanceKey }
        guard let result = callJSON("annualLeaveBalance", arguments: [input]),
              JSONSerialization.isValidJSONObject(result),
              let data = try? JSONSerialization.data(withJSONObject: result) else {
            return nil
        }
        return try? JSONDecoder().decode(CanonicalAnnualLeaveBalance.self, from: data)
    }

    /// `leaveApproverIds(user, roster)`: the requester's active line managers, else every active admin
    /// and super admin; never the requester. Nil when the script did not answer.
    nonisolated static func leaveApproverIds(requester: [String: Any], roster: [[String: Any]]) -> [String]? {
        callJSON("leaveApproverIds", arguments: [requester, roster]) as? [String]
    }

    // MARK: - Self-booking, line-manager requirement, deciders (§8, §9, §11)

    /// `canSelfBookAnnualLeave(user, roster)`: the self-book permission outside operative mode, or an admin /
    /// super admin outside operative mode with no active line manager (§9). Nil when the script did not answer.
    nonisolated static func canSelfBookAnnualLeave(user: [String: Any], roster: [[String: Any]]) -> Bool? {
        callJSON("canSelfBookAnnualLeave", arguments: [user, roster]) as? Bool
    }

    /// `lineManagerRequiredError(user, roster)`: `LINE_MANAGER_REQUIRED_MESSAGE` when this person needs a
    /// current line manager and has none, else nil.
    nonisolated static func lineManagerRequiredError(user: [String: Any], roster: [[String: Any]]) -> String? {
        callJSON("lineManagerRequiredError", arguments: [user, roster]) as? String
    }

    /// `usersMissingLineManager(roster)`: ids that fail `lineManagerRequiredError`. Nil when the script did not answer.
    nonisolated static func usersMissingLineManager(roster: [[String: Any]]) -> [String]? {
        callJSON("usersMissingLineManager", arguments: [roster]) as? [String]
    }

    /// `canDecideLeave(viewer, requester, roster)`. Nil when the script did not answer.
    nonisolated static func canDecideLeave(
        viewer: [String: Any],
        requester: [String: Any],
        roster: [[String: Any]]
    ) -> Bool? {
        callJSON("canDecideLeave", arguments: [viewer, requester, roster]) as? Bool
    }

    /// `leaveDecisionQueue(viewer, requests, roster)`: the request rows kept, in input order (extra keys
    /// on a row come back unchanged). Nil when the script did not answer.
    nonisolated static func leaveDecisionQueue(
        viewer: [String: Any],
        requests: [[String: Any]],
        roster: [[String: Any]]
    ) -> [[String: Any]]? {
        callJSON("leaveDecisionQueue", arguments: [viewer, requests, roster]) as? [[String: Any]]
    }

    // MARK: - Notifications (§13)

    /// `notificationShowsInInbox(prefs, type)`. A toggle never hides an inbox row; true when the script did not answer.
    nonisolated static func notificationShowsInInbox(prefs: [String: Bool]?, type: String) -> Bool {
        let prefsArgument: Any = prefs ?? NSNull()
        return callJSON("notificationShowsInInbox", arguments: [prefsArgument, type]) as? Bool ?? true
    }

    /// `devicePushAllowed(prefs, type)`: the type sends a device push and the toggle for it is on.
    /// Nil when the script did not answer.
    nonisolated static func devicePushAllowed(prefs: [String: Bool], type: String) -> Bool? {
        callJSON("devicePushAllowed", arguments: [prefs, type]) as? Bool
    }
}

/// Who may see and decide a leave request (§9, user decision D6), built on `leaveApproverIds`.
/// Admins and super admins (not in operative mode) may decide every request in the organisation;
/// anyone else only a request whose `leaveApproverIds` names them. Nobody decides their own.
enum AnnualLeaveApproval {
    /// The requester's account: `userId`, else the account on the operative row's email.
    static func requester(
        for booking: HolidayBooking,
        users: [AppUser],
        operatives: [Operative]
    ) -> AppUser? {
        if let uid = booking.userId?.trimmingCharacters(in: .whitespacesAndNewlines), !uid.isEmpty,
           let user = users.first(where: { $0.id == uid || $0.sameEmailUserIds.contains(uid) || $0.formerUserIds.contains(uid) }) {
            return user
        }
        if let oid = booking.operativeId,
           let operative = operatives.first(where: { $0.id == oid }) {
            let email = operative.email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !email.isEmpty else { return nil }
            return users.first(where: { $0.email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == email })
        }
        return nil
    }

    /// `LeaveRequester` for the script. A request with no account found still names its stored user id.
    static func requesterPayload(_ requester: AppUser?, fallbackUserId: String?) -> [String: Any] {
        guard let requester else {
            var payload: [String: Any] = [:]
            if let fallbackUserId, !fallbackUserId.isEmpty { payload["id"] = fallbackUserId }
            return payload
        }
        return RulebookPeople.person(requester)
    }

    /// `LeaveApproverMember & LeaveRequester` rows for `CanonicalBusinessEngine.leaveApproverIds` / `canDecideLeave` /
    /// `leaveDecisionQueue`: the full person (`RulebookPeople.person`:
    /// email, active flag, role, role flags, alias ids, line-manager fields), as rulebook 1.3.0 reads them.
    static func rosterPayload(_ users: [AppUser]) -> [[String: Any]] {
        RulebookPeople.roster(users)
    }

    /// `StaffAccountRole` for the script.
    static func rolePayload(_ user: AppUser) -> [String: Any] {
        let role = UserStore.staffAccountRole(for: user)
        return [
            "isSuperAdmin": role.isSuperAdmin,
            "isAdmin": role.isAdmin,
            "isManager": role.isManager,
            "isOperativeMode": role.isOperativeMode,
        ]
    }

    /// `LeaveDecisionViewer` for the script: the full person, so their alias ids count too.
    static func viewerPayload(_ viewer: AppUser) -> [String: Any] {
        RulebookPeople.person(viewer)
    }

    /// `LeaveSelfBookUser` fields of `users/{uid}` for `canSelfBookAnnualLeave` / `lineManagerRequiredError`.
    /// Pass the user as it will be saved (edited permissions and line managers).
    static func selfBookPayload(_ user: AppUser) -> [String: Any] {
        RulebookPeople.person(user)
    }

    /// `lineManagerRequiredError(user, roster)` for a user as it will be saved. Nil when no line manager is needed.
    static func lineManagerRequiredError(for user: AppUser, users: [AppUser]) -> String? {
        CanonicalBusinessEngine.lineManagerRequiredError(user: selfBookPayload(user), roster: rosterPayload(users))
    }

    /// `usersMissingLineManager(roster)`: the roster people an admin still has to give a line manager.
    static func usersMissingLineManager(_ users: [AppUser]) -> [AppUser] {
        let roster = RulebookPeople.roster(users)
        guard let ids = CanonicalBusinessEngine.usersMissingLineManager(roster: roster) else { return [] }
        let missing = Set(ids)
        return users.filter { missing.contains($0.id) }
    }

    /// `leaveApproverIds` for this account. Nil when the script did not answer.
    static func approverIds(for requester: AppUser?, fallbackUserId: String? = nil, users: [AppUser]) -> [String]? {
        CanonicalBusinessEngine.leaveApproverIds(
            requester: requesterPayload(requester, fallbackUserId: fallbackUserId),
            roster: rosterPayload(users)
        )
    }

    /// Every id the viewer's account has had (own id, same-email documents, former invite ids).
    private static func viewerIds(_ viewer: AppUser) -> Set<String> {
        Set(([viewer.id] + viewer.sameEmailUserIds + viewer.formerUserIds)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty })
    }

    /// True when the booking is the viewer's own leave.
    static func isOwnRequest(
        _ booking: HolidayBooking,
        viewer: AppUser,
        users: [AppUser],
        operatives: [Operative]
    ) -> Bool {
        let ids = viewerIds(viewer)
        if let uid = booking.userId?.trimmingCharacters(in: .whitespacesAndNewlines), ids.contains(uid) { return true }
        if let requester = requester(for: booking, users: users, operatives: operatives), ids.contains(requester.id) {
            return true
        }
        let email = viewer.email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if !email.isEmpty,
           let oid = booking.operativeId,
           let operative = operatives.first(where: { $0.id == oid }),
           operative.email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == email {
            return true
        }
        return false
    }

    /// Whether the viewer may see this request in an approval queue and approve or decline it.
    static func canDecide(
        _ booking: HolidayBooking,
        viewer: AppUser?,
        users: [AppUser],
        operatives: [Operative]
    ) -> Bool {
        guard let viewer else { return false }
        // Identity only: same-email documents, former invite ids and the operative row's email are the
        // viewer's own account, which `canDecideLeave` (one id) cannot see.
        if isOwnRequest(booking, viewer: viewer, users: users, operatives: operatives) { return false }
        let requesterAccount = requester(for: booking, users: users, operatives: operatives)
        return CanonicalBusinessEngine.canDecideLeave(
            viewer: viewerPayload(viewer),
            requester: requesterPayload(requesterAccount, fallbackUserId: booking.userId),
            roster: rosterPayload(users)
        ) ?? false
    }

    /// `leaveDecisionQueue`: the requests (pending, or approved with a cancellation request) the viewer
    /// may decide. The requester is resolved to its account first, so the row's `userId` is that account.
    static func decidableRequests(
        _ pending: [HolidayBooking],
        viewer: AppUser?,
        users: [AppUser],
        operatives: [Operative]
    ) -> [HolidayBooking] {
        guard let viewer else { return [] }
        let candidates = pending.filter { !isOwnRequest($0, viewer: viewer, users: users, operatives: operatives) }
        var rows: [[String: Any]] = []
        for (index, booking) in candidates.enumerated() {
            var row: [String: Any] = ["queueIndex": index, "status": booking.status.rawValue]
            let storedUid = booking.userId?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let accountId = requester(for: booking, users: users, operatives: operatives)?.id ?? storedUid
            if !accountId.isEmpty { row["userId"] = accountId }
            if let oid = booking.operativeId { row["operativeId"] = oid.uuidString }
            if let at = booking.cancellationRequestedAt { row["cancellationRequestedAt"] = at.timeIntervalSince1970 * 1000 }
            if let by = booking.cancellationRequestedByUserId { row["cancellationRequestedByUserId"] = by }
            rows.append(row)
        }
        guard let kept = CanonicalBusinessEngine.leaveDecisionQueue(
            viewer: viewerPayload(viewer),
            requests: rows,
            roster: rosterPayload(users)
        ) else { return [] }
        let keptIndexes = Set(kept.compactMap { ($0["queueIndex"] as? NSNumber)?.intValue })
        var result: [HolidayBooking] = []
        for (index, booking) in candidates.enumerated() where keptIndexes.contains(index) {
            result.append(booking)
        }
        return result
    }

    /// `canSelfBookAnnualLeave(user, roster)`: the viewer books their own leave approved.
    static func selfBooksOwnLeave(_ user: AppUser, users: [AppUser]) -> Bool {
        AnnualLeaveSelfBookPolicy.canSelfBookAnnualLeave(for: user, users: users)
    }

    /// Shown while `lineManagerRequiredError` says this person is missing a current line manager.
    /// Their requests still reach every active admin through `leaveApproverIds` meanwhile.
    static func showsNoLineManagerNotice(for user: AppUser, users: [AppUser]) -> Bool {
        lineManagerRequiredError(for: user, users: users) != nil
    }
}

/// The organisation's loaded bank holidays as `YYYY-MM-DD` keys: `nonWorkingDayKeys` for
/// `leaveRecordDayKeys` / `annualLeaveBalance`. `BankHolidayService` updates it on every load.
nonisolated enum OrganizationBankHolidays {
    nonisolated(unsafe) private(set) static var dayKeys: [String] = []
    /// Bumped on every change, so memoised day lists know to recompute.
    nonisolated(unsafe) private(set) static var revision = 0

    static func update(_ keys: [String]) {
        let sorted = Array(Set(keys)).sorted()
        guard sorted != dayKeys else { return }
        dayKeys = sorted
        revision &+= 1
    }
}

/// `leaveRecordDayKeys` for a stored leave record, memoised per record range and bank-holiday set.
/// A single-day record is that day; a multi-day record skips weekends and bank holidays (§9).
enum LeaveRecordDays {
    private static var memo: [String: [String]] = [:]
    private static var memoRevision = -1

    static func dayKeys(startDayKey: String, endDayKey: String) -> [String] {
        if memoRevision != OrganizationBankHolidays.revision {
            memo.removeAll()
            memoRevision = OrganizationBankHolidays.revision
        }
        let key = "\(startDayKey)|\(endDayKey)"
        if let cached = memo[key] { return cached }
        let keys = CanonicalBusinessEngine.leaveRecordDayKeys(
            startDayKey: startDayKey,
            endDayKey: endDayKey,
            nonWorkingDayKeys: OrganizationBankHolidays.dayKeys
        ) ?? []
        memo[key] = keys
        return keys
    }

    static func dayKeys(for booking: HolidayBooking) -> [String] {
        dayKeys(
            startDayKey: OrganizationRulebookContext.dayKey(booking.startDate),
            endDayKey: OrganizationRulebookContext.dayKey(booking.endDate)
        )
    }

    /// True when `dayKey` is one of the record's leave days.
    static func covers(_ booking: HolidayBooking, dayKey: String) -> Bool {
        let start = OrganizationRulebookContext.dayKey(booking.startDate)
        let end = OrganizationRulebookContext.dayKey(booking.endDate)
        guard dayKey >= start, dayKey <= max(start, end) else { return false }
        return dayKeys(startDayKey: start, endDayKey: end).contains(dayKey)
    }

    static func covers(_ booking: HolidayBooking, day: Date) -> Bool {
        covers(booking, dayKey: OrganizationRulebookContext.dayKey(day))
    }
}
