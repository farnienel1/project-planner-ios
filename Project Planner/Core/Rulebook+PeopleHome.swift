//
//  Rulebook+PeopleHome.swift
//  Project Planner
//
//  RULEBOOK 1.23.0 / 1.23.1 "People, Home and per-day hours" (§5, §9, §11, §21, §22, §23; web `lib/canonical/
//  rosterLists.ts`, `homeOverview.ts`, `dueDates.ts`, `leaveCalendar.ts`, `jobBadges.ts`, `scheduleSources.ts`
//  `bookingRequestClashIds`, `payrollPolicySchedule.ts` `bookingStandardDayOn`). Every answer comes from the packed
//  script through `CanonicalBusinessEngine.callJSON`, memoised by its exact input; Swift only maps its models into
//  the script's plain rows and maps the answer back.
//

import Foundation

// MARK: - People lists and levels (§11, §5)

/// `RosterListKind`: the one people list a person is on.
nonisolated enum RulebookRosterListKind: String, Hashable, Sendable {
    case admins, managers, operatives
}

enum RulebookRosterLists {
    nonisolated private static let kindMemo = RulebookAnswerMemo<String, RulebookRosterListKind>(limit: 512)
    nonisolated private static let missingMemo = RulebookAnswerMemo<String, Bool>(limit: 1024)
    nonisolated private static let listMemo = RulebookAnswerMemo<String, [String]>(limit: 16)

    /// The level fields `rosterListKind` / `clashManagerIds` read, from the person as the app holds them (role, super
    /// admin and the toggles, `CanonicalBusinessEngine.permissionSubject`), plus the roster fields.
    static func levelRow(_ user: AppUser) -> [String: Any] {
        var row = user.permissionSubject
        row["id"] = user.id
        row["email"] = user.email
        row["isActive"] = user.isActive
        row["passwordSet"] = user.passwordSet
        row["firstName"] = user.firstName
        row["surname"] = user.surname
        row["formerUserIds"] = user.formerUserIds
        row["sameEmailUserIds"] = user.sameEmailUserIds
        // RULEBOOK 1.34.0 §11: a ghost operative (no app login).
        row["ghost"] = user.isGhost
        if let updated = user.documentUpdatedAt { row["updatedAtMs"] = (updated.timeIntervalSince1970 * 1000).rounded() }
        return row
    }

    /// The level fields exactly as stored on a `users/{uid}` document (only those present): top level and
    /// `permissions.{key}`. A data mapping for `userMissingLevel`, not a rule.
    nonisolated static func storedLevelFlags(_ data: [String: Any]) -> [String: Bool] {
        var out: [String: Bool] = [:]
        let nested = data["permissions"] as? [String: Any] ?? [:]
        for key in ["isSuperAdmin", "adminAccess", "manager", "operativeMode"] {
            if let value = data[key] as? Bool { out[key] = value }
            if let value = nested[key] as? Bool { out["permissions.\(key)"] = value }
        }
        return out
    }

    /// RULEBOOK 1.23.0 §11 `CanonicalBusinessEngine` `rosterListKind(row)`, memoised by the level fields. Falls back to
    /// managers only when the script did not answer (the level a person with no flag reads as).
    static func kind(_ user: AppUser) -> RulebookRosterListKind {
        let subject = user.permissionSubject
        guard let key = CanonicalBusinessEngine.rulebookMemoKey(subject) else { return .managers }
        return kindMemo.value(for: key) {
            (CanonicalBusinessEngine.callJSON("rosterListKind", arguments: [subject]) as? String)
                .flatMap(RulebookRosterListKind.init(rawValue:))
        } ?? .managers
    }

    /// RULEBOOK 1.23.0 §11 `rosterListFor(kind, roster, claimedEmails)`: the people on one list — one per email, without
    /// identifiable leftovers of a removed invite, sorted by name. Nil when the script did not answer.
    static func list(_ kind: RulebookRosterListKind, users: [AppUser], claimedEmails: Set<String>? = nil) -> [AppUser]? {
        let rows = users.map(levelRow)
        let claimed: Any = claimedEmails.map { Array($0).sorted() as Any } ?? NSNull()
        let arguments: [Any] = [kind.rawValue, rows, claimed]
        guard let key = CanonicalBusinessEngine.rulebookMemoKey(arguments),
              let ids = listMemo.value(for: key, compute: {
                  (CanonicalBusinessEngine.callJSON("rosterListFor", arguments: arguments) as? [[String: Any]])?
                      .compactMap { $0["id"] as? String }
              }) else {
            return nil
        }
        var byId: [String: AppUser] = [:]
        for user in users where byId[user.id] == nil { byId[user.id] = user }
        return ids.compactMap { byId[$0] }
    }

    /// RULEBOOK 1.23.0 §5 `clashManagerIds(roster)`: the ids whose double bookings are manager (Medium) clashes. Nil
    /// when the script did not answer.
    nonisolated static func clashManagerIds(_ rows: [[String: Any]]) -> [String]? {
        CanonicalBusinessEngine.callJSON("clashManagerIds", arguments: [rows]) as? [String]
    }

    /// The row `userMissingLevel` reads: the stored level fields when the profile was read from its document, else the
    /// level as held.
    static func storedLevelRow(_ user: AppUser) -> [String: Any] {
        guard let flags = user.storedLevelFlags else { return levelRow(user) }
        var row: [String: Any] = ["id": user.id, "email": user.email, "isActive": user.isActive]
        if !user.firstName.isEmpty { row["firstName"] = user.firstName }
        if !user.surname.isEmpty { row["surname"] = user.surname }
        if let role = user.storedRoleText { row["role"] = role }
        var nested: [String: Any] = [:]
        for (key, value) in flags {
            if key.hasPrefix("permissions.") { nested[String(key.dropFirst("permissions.".count))] = value } else { row[key] = value }
        }
        if !nested.isEmpty { row["permissions"] = nested }
        return row
    }

    /// RULEBOOK 1.23.1 §11 `userMissingLevel(user)`: no level flag stored true and not an admin by role. False when the
    /// script did not answer.
    static func userMissingLevel(_ user: AppUser) -> Bool {
        let row = storedLevelRow(user)
        guard let key = CanonicalBusinessEngine.rulebookMemoKey(row) else { return false }
        return missingMemo.value(for: key) {
            (CanonicalBusinessEngine.callJSON("userMissingLevel", arguments: [row]) as? NSNumber)?.boolValue
        } ?? false
    }

    /// RULEBOOK 1.23.1 §11 `usersMissingLevel(roster)`: the Data health list, in roster order.
    static func usersMissingLevel(_ users: [AppUser]) -> [AppUser] {
        let rows = users.map(storedLevelRow)
        guard let answer = CanonicalBusinessEngine.callJSON("usersMissingLevel", arguments: [rows]) as? [[String: Any]] else { return [] }
        let ids = Set(answer.compactMap { $0["id"] as? String })
        return users.filter { ids.contains($0.id) }
    }

    /// `USER_MISSING_LEVEL_MESSAGE`.
    static var missingLevelMessage: String {
        CanonicalBusinessEngine.constant("USER_MISSING_LEVEL_MESSAGE", as: String.self)
            ?? "Has no user level: open in Manage Users and pick one"
    }

    /// RULEBOOK 1.23.1 §11: an invite's level fields (`userMissingLevel` over the flags it writes). True when the
    /// invite has no level and must be refused.
    nonisolated static func inviteHasNoLevel(_ permissions: UserPermissions) -> Bool {
        let row: [String: Any] = [
            "id": "invite", "email": "invite",
            "adminAccess": permissions.adminAccess, "manager": permissions.manager, "operativeMode": permissions.operativeMode,
        ]
        return (CanonicalBusinessEngine.callJSON("userMissingLevel", arguments: [row]) as? NSNumber)?.boolValue ?? false
    }

    nonisolated static let inviteMissingLevelMessage = "Choose a user level (admin, manager or operative) before inviting this person."
}

// MARK: - Home (§23), qualification counts (§5)

nonisolated struct RulebookHomeOverviewMetrics: Hashable, Sendable {
    var dayKey = ""
    var tasksDueToday = 0
    var tasksDueThisWeek = 0
    var tasksOverdue = 0
    var outstandingTasksAllUsers = 0
    var operativesOnSiteToday = 0
    var managersOnSiteToday = 0
    var peopleOnSiteToday = 0
    var operativesOnALToday = 0
    var managersOnALToday = 0
}

nonisolated struct RulebookQualificationExpiryCount: Hashable, Sendable {
    let expired: Int
    let expiringSoon: Int
    let total: Int
}

extension CanonicalBusinessEngine {
    nonisolated private static let homeMemo = RulebookAnswerMemo<String, RulebookHomeOverviewMetrics>(limit: 32)
    nonisolated private static let qualificationCountMemo = RulebookAnswerMemo<String, RulebookQualificationExpiryCount>(limit: 64)

    /// RULEBOOK 1.23.0 §23 `homeOverviewMetrics(input)`: the Home figures on the organisation day, each person once
    /// under all their ids. Nil when the script did not answer.
    nonisolated static func homeOverviewMetrics(_ input: [String: Any]) -> RulebookHomeOverviewMetrics? {
        guard let key = rulebookMemoKey(input) else { return nil }
        return homeMemo.value(for: key) {
            guard let row = callJSON("homeOverviewMetrics", arguments: [input]) as? [String: Any] else { return nil }
            func n(_ key: String) -> Int { (row[key] as? NSNumber)?.intValue ?? 0 }
            return RulebookHomeOverviewMetrics(
                dayKey: row["dayKey"] as? String ?? "",
                tasksDueToday: n("tasksDueToday"), tasksDueThisWeek: n("tasksDueThisWeek"), tasksOverdue: n("tasksOverdue"),
                outstandingTasksAllUsers: n("outstandingTasksAllUsers"), operativesOnSiteToday: n("operativesOnSiteToday"),
                managersOnSiteToday: n("managersOnSiteToday"), peopleOnSiteToday: n("peopleOnSiteToday"),
                operativesOnALToday: n("operativesOnALToday"), managersOnALToday: n("managersOnALToday")
            )
        }
    }

    /// RULEBOOK 1.23.0 §5 `qualificationExpiryCount({ referenceIso, timeZone, operatives, operativeIds? })`: the rows the
    /// Warnings screen lists (active operatives, organisation day, one calendar month, expired included). Nil when the
    /// script did not answer.
    nonisolated static func qualificationExpiryCount(
        operatives: [[String: Any]],
        operativeIds: [String]? = nil,
        reference: Date = Date(),
        timeZone: String = OrganizationRulebookContext.timeZoneIdentifier
    ) -> RulebookQualificationExpiryCount? {
        var input: [String: Any] = [
            "referenceIso": isoString(from: reference),
            "timeZone": timeZone,
            "operatives": operatives,
        ]
        if let operativeIds { input["operativeIds"] = operativeIds }
        // The reference instant changes every call; the answer only changes with the organisation day.
        var keyInput = input
        keyInput["referenceIso"] = OrganizationRulebookContext.dayKey(reference)
        guard let key = rulebookMemoKey(keyInput) else { return nil }
        return qualificationCountMemo.value(for: key) {
            guard let row = callJSON("qualificationExpiryCount", arguments: [input]) as? [String: Any] else { return nil }
            func n(_ key: String) -> Int { (row[key] as? NSNumber)?.intValue ?? 0 }
            return RulebookQualificationExpiryCount(expired: n("expired"), expiringSoon: n("expiringSoon"), total: n("total"))
        }
    }
}

extension Operative {
    /// This operative as a `qualificationExpiryRows` row (CanonicalBusinessEngine `qualificationExpiryCount`). Each
    /// expiry carries the qualification's name when the catalogue row has it, else its id.
    var rulebookQualificationRow: [String: Any] {
        [
            "id": documentId,
            "isActive": isActive,
            "email": email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
            "name": "\(firstName) \(lastName)".trimmingCharacters(in: .whitespaces),
            "expiries": qualificationExpiryDates.sorted { $0.key < $1.key }.map { id, date in
                let name = qualifications.first(where: { $0.id == id })?.name.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                return [
                    "qualificationId": id,
                    "name": name.isEmpty ? id : name,
                    "expiryIso": CanonicalBusinessEngine.isoString(from: date),
                ] as [String: Any]
            },
        ]
    }
}

/// One `qualificationExpiryRows` row for a reminder banner.
nonisolated struct RulebookQualificationExpiryRow: Equatable, Sendable {
    let id: String
    let operativeId: String
    let qualificationName: String
    let dayKey: String
    /// Negative once expired (rulebook §5: already-expired qualifications are listed too).
    let daysUntilExpiry: Int
    let title: String
}

extension CanonicalBusinessEngine {
    /// RULEBOOK §5 `qualificationExpiryRows({ referenceIso, timeZone, operatives })`: the same rows the Warnings screen
    /// and the Home badge (`qualificationExpiryCount`) count — active operatives, organisation day, one calendar month
    /// ahead, already expired included. Nil when the script did not answer.
    nonisolated static func qualificationExpiryRows(
        operatives: [[String: Any]],
        reference: Date = Date(),
        timeZone: String = OrganizationRulebookContext.timeZoneIdentifier
    ) -> [RulebookQualificationExpiryRow]? {
        guard let rows = objectRows(
            function: "qualificationExpiryRows",
            payload: [
                "referenceIso": isoString(from: reference),
                "timeZone": timeZone,
                "operatives": operatives,
            ]
        ) else { return nil }
        return rows.compactMap { row in
            guard let id = row["id"] as? String, let dayKey = row["dayKey"] as? String else { return nil }
            return RulebookQualificationExpiryRow(
                id: id,
                operativeId: row["operativeId"] as? String ?? "",
                qualificationName: row["qualificationName"] as? String ?? "",
                dayKey: dayKey,
                daysUntilExpiry: (row["daysUntilExpiry"] as? NSNumber)?.intValue ?? 0,
                title: row["title"] as? String ?? ""
            )
        }
    }
}

// MARK: - Tasks and deadlines (§23)

extension CanonicalBusinessEngine {
    nonisolated private static let overdueMemo = RulebookAnswerMemo<String, Bool>(limit: 1024)
    nonisolated private static let urgencyMemo = RulebookAnswerMemo<String, RulebookJSONBox>(limit: 1024)
    nonisolated private static let daysRemainingMemo = RulebookAnswerMemo<String, Int>(limit: 1024)

    /// RULEBOOK 1.23.0 §23 `isTaskOverdue(task, nowMs, timeZone)`: not completed and due before today, organisation
    /// day. Memoised per status, due instant and organisation day. False when the script did not answer.
    nonisolated static func isTaskOverdue(status: String, dueDate: Date?, now: Date = Date(), timeZone: String = OrganizationRulebookContext.timeZoneIdentifier) -> Bool {
        guard let dueDate else { return false }
        let dueMs = (dueDate.timeIntervalSince1970 * 1000).rounded()
        let today = OrganizationRulebookContext.dayKey(now)
        let key = "\(status)|\(dueMs)|\(today)|\(timeZone)"
        return overdueMemo.value(for: key) {
            let task: [String: Any] = ["status": status, "dueDate": dueMs]
            return (callJSON("isTaskOverdue", arguments: [task, (now.timeIntervalSince1970 * 1000).rounded(), timeZone]) as? NSNumber)?.boolValue
        } ?? false
    }

    /// RULEBOOK 1.23.0 §23 `deadlineUrgency(item, nowMs, timeZone)` → `{ kind, days? }`. Memoised per status, due
    /// instant and organisation day. Nil when the script did not answer.
    nonisolated static func deadlineUrgency(status: String, due: Date, now: Date = Date(), timeZone: String = OrganizationRulebookContext.timeZoneIdentifier) -> (kind: String, days: Int)? {
        let dueMs = (due.timeIntervalSince1970 * 1000).rounded()
        let today = OrganizationRulebookContext.dayKey(now)
        let key = "\(status)|\(dueMs)|\(today)|\(timeZone)"
        let box = urgencyMemo.value(for: key) {
            let item: [String: Any] = ["status": status, "due": dueMs]
            return (callJSON("deadlineUrgency", arguments: [item, (now.timeIntervalSince1970 * 1000).rounded(), timeZone]) as? [String: Any])
                .map(RulebookJSONBox.init(object:))
        }
        guard let row = box?.object, let kind = row["kind"] as? String else { return nil }
        return (kind, (row["days"] as? NSNumber)?.intValue ?? 0)
    }

    /// RULEBOOK 1.23.0 §23 `deadlineDaysRemaining(item, nowMs, timeZone)`: whole organisation days to the due day.
    nonisolated static func deadlineDaysRemaining(due: Date, now: Date = Date(), timeZone: String = OrganizationRulebookContext.timeZoneIdentifier) -> Int? {
        let dueMs = (due.timeIntervalSince1970 * 1000).rounded()
        let key = "\(dueMs)|\(OrganizationRulebookContext.dayKey(now))|\(timeZone)"
        return daysRemainingMemo.value(for: key) {
            let item: [String: Any] = ["due": dueMs]
            return (callJSON("deadlineDaysRemaining", arguments: [item, (now.timeIntervalSince1970 * 1000).rounded(), timeZone]) as? NSNumber)?.intValue
        }
    }
}

// MARK: - Leave calendar (§9)

nonisolated enum RulebookLeaveDayKind: String, Hashable, Sendable {
    case none, approvedFull, approvedHalf, pendingFull, pendingHalf
}

nonisolated struct RulebookLeaveDayAnswer: Hashable, Sendable {
    let kind: RulebookLeaveDayKind
    let recordId: String?
}

extension CanonicalBusinessEngine {
    nonisolated private static let leaveDayMemo = RulebookAnswerMemo<String, RulebookLeaveDayAnswer>(limit: 2048)

    /// RULEBOOK 1.23.0 §9 `leaveDayKind(records, dayKey, timeZone, nonWorkingDayKeys)`: a record covers its leave days
    /// only; rejected never; approved with a pending cancellation still approved; pendingFull > approvedFull >
    /// pendingHalf > approvedHalf. Nil when the script did not answer.
    nonisolated static func leaveDayKind(
        records: [RulebookLeaveReportRecord],
        dayKey: String,
        timeZone: String = OrganizationRulebookContext.timeZoneIdentifier,
        nonWorkingDayKeys: [String] = []
    ) -> RulebookLeaveDayKind? {
        leaveDayAnswer(records: records, dayKey: dayKey, timeZone: timeZone, nonWorkingDayKeys: nonWorkingDayKeys)?.kind
    }

    /// `leaveDayKind` with the record that decided it (`recordId`).
    nonisolated static func leaveDayAnswer(
        records: [RulebookLeaveReportRecord],
        dayKey: String,
        timeZone: String = OrganizationRulebookContext.timeZoneIdentifier,
        nonWorkingDayKeys: [String] = []
    ) -> RulebookLeaveDayAnswer? {
        let rows = records.map(\.json)
        let arguments: [Any] = [rows, dayKey, timeZone, nonWorkingDayKeys]
        guard let key = rulebookMemoKey(arguments) else { return nil }
        return leaveDayMemo.value(for: key) {
            guard let row = callJSON("leaveDayKind", arguments: arguments) as? [String: Any],
                  let kind = (row["kind"] as? String).flatMap(RulebookLeaveDayKind.init(rawValue:)) else { return nil }
            return RulebookLeaveDayAnswer(kind: kind, recordId: row["recordId"] as? String)
        }
    }
}

extension HolidayBooking {
    /// This record as a `LeaveCalendarRecord` / `LeaveReportRecord` (CanonicalBusinessEngine `leaveDayKind`,
    /// `leaveReportRows`): its parsed organisation-zone day keys, slot and status.
    var rulebookLeaveRecord: RulebookLeaveReportRecord {
        RulebookLeaveReportRecord(
            id: documentId,
            userId: userId,
            operativeId: operativeIdRaw ?? operativeId?.uuidString,
            startDayKey: startDayKey,
            endDayKey: endDayKey,
            timeSlot: timeSlot.rawValue,
            status: status.rawValue
        )
    }
}

// MARK: - Site map, job tiles, variations (§21, §22)

nonisolated struct RulebookSiteMapPin: Hashable, Sendable {
    let jobId: String
    let bookingCount: Int
    let peopleCount: Int
}

nonisolated struct RulebookJobTileBadges: Hashable, Sendable {
    let tentativeBookings: Int
    let openTasks: Int
    let activeUsers: Int
}

extension CanonicalBusinessEngine {
    nonisolated private static let badgeMemo = RulebookAnswerMemo<String, RulebookJobTileBadges>(limit: 128)

    /// RULEBOOK 1.23.0 §21 `siteMapPins({ jobs, bookings, managerSiteBookings, dayKey, timeZone, people })`. Nil when
    /// the script did not answer.
    nonisolated static func siteMapPins(_ input: [String: Any]) -> [RulebookSiteMapPin]? {
        (callJSON("siteMapPins", arguments: [input]) as? [[String: Any]])?.compactMap { row in
            guard let id = row["jobId"] as? String else { return nil }
            return RulebookSiteMapPin(
                jobId: id,
                bookingCount: (row["bookingCount"] as? NSNumber)?.intValue ?? 0,
                peopleCount: (row["peopleCount"] as? NSNumber)?.intValue ?? 0
            )
        }
    }

    /// RULEBOOK 1.23.0 §21 `jobTileBadges({ jobId, bookings, managerSiteBookings, subcontractorBookings, tasks, people })`,
    /// memoised by the exact input. Nil when the script did not answer.
    nonisolated static func jobTileBadges(_ input: [String: Any]) -> RulebookJobTileBadges? {
        guard let key = rulebookMemoKey(input) else { return nil }
        return badgeMemo.value(for: key) {
            guard let row = callJSON("jobTileBadges", arguments: [input]) as? [String: Any] else { return nil }
            func n(_ key: String) -> Int { (row[key] as? NSNumber)?.intValue ?? 0 }
            return RulebookJobTileBadges(tentativeBookings: n("tentativeBookings"), openTasks: n("openTasks"), activeUsers: n("activeUsers"))
        }
    }

    /// RULEBOOK 1.23.0 §22 `mergeVariationSources(collection, fallback, itemDocs)` over `{ id, updatedAtMs, _i }` rows:
    /// the kept rows' `_i` tags in the script's order. Nil when the script did not answer.
    nonisolated static func mergeVariationSources(collection: [[String: Any]], fallback: [[String: Any]], itemDocs: [[String: Any]]) -> [String]? {
        (callJSON("mergeVariationSources", arguments: [collection, fallback, itemDocs]) as? [[String: Any]])?
            .compactMap { $0["_i"] as? String }
    }

    /// RULEBOOK 1.23.0 §22 `openVariationCount(rows)`: not deleted and status `open` (any case).
    nonisolated static func openVariationCount(_ rows: [[String: Any]]) -> Int? {
        (callJSON("openVariationCount", arguments: [rows]) as? NSNumber)?.intValue
    }
}

// MARK: - A booking being made (§5)

/// One booking as `bookingRequestClashIds` reads it: id, organisation day, slot, clock times, status.
nonisolated struct RulebookClashBooking: Hashable, Sendable {
    var id: String
    var dayKey: String
    var timeSlot: String
    var workStartTime: String?
    var workEndTime: String?
    var status: String = "Confirmed"

    var json: [String: Any] {
        [
            "id": id, "dayKey": dayKey, "timeSlot": timeSlot, "status": status,
            "workStartTime": workStartTime.map { $0 as Any } ?? NSNull(),
            "workEndTime": workEndTime.map { $0 as Any } ?? NSNull(),
        ]
    }
}

extension CanonicalBusinessEngine {
    nonisolated private static let requestClashMemo = RulebookAnswerMemo<String, [String]>(limit: 4096)

    /// The `day` a clash, overlap or leave check reads (RULEBOOK 1.23.0 / 1.23.1 `standardDayOn` /
    /// `bookingStandardDayOn`): the open organisation's working-hours state, so each booked day is read under its own
    /// hours (a weekend day under its own window); `policy` as given only before an organisation is loaded.
    nonisolated static func bookingDayInput(policy: OrgPayrollTimePolicy) -> Any {
        if let state = openOrganizationPayrollPolicyState { return state }
        return payrollPolicyJSON(policy) ?? [
            "standardDayStart": policy.standardDayStart, "standardDayEnd": policy.standardDayEnd,
            "breakWindowStart": policy.breakWindowStart, "breakWindowEnd": policy.breakWindowEnd,
        ]
    }

    /// RULEBOOK 1.23.0 §5 `bookingRequestClashIds({ request, existing, day })`: the existing bookings a booking being
    /// made on `request.dayKey` clashes with, both read under the booked day's working hours (an overnight booking
    /// from the day before reaches that morning; cancelled never). Memoised by the exact input. Nil when the script
    /// did not answer.
    nonisolated static func bookingRequestClashIds(
        request: RulebookClashBooking,
        existing: [RulebookClashBooking],
        day: Any
    ) -> [String]? {
        let input: [String: Any] = [
            "request": [
                "dayKey": request.dayKey, "timeSlot": request.timeSlot,
                "workStartTime": request.workStartTime.map { $0 as Any } ?? NSNull(),
                "workEndTime": request.workEndTime.map { $0 as Any } ?? NSNull(),
            ] as [String: Any],
            "existing": existing.map(\.json),
            "day": day,
        ]
        guard let key = rulebookMemoKey(input) else { return nil }
        return requestClashMemo.value(for: key) {
            callJSON("bookingRequestClashIds", arguments: [input]) as? [String]
        }
    }
}

extension Booking {
    /// This booking as a `bookingRequestClashIds` row (organisation day, stored slot and clock times).
    var rulebookClashBooking: RulebookClashBooking {
        RulebookClashBooking(
            id: id.uuidString, dayKey: OrganizationRulebookContext.dayKey(date), timeSlot: timeSlot.rawValue,
            workStartTime: workStartTime, workEndTime: workEndTime, status: status.rawValue
        )
    }
}

extension ManagerSiteBooking {
    /// This booking as a `bookingRequestClashIds` row (organisation day, stored slot and clock times).
    var rulebookClashBooking: RulebookClashBooking {
        RulebookClashBooking(
            id: id.uuidString, dayKey: OrganizationRulebookContext.dayKey(date), timeSlot: timeSlot.rawValue,
            workStartTime: workStartTime, workEndTime: workEndTime
        )
    }
}

extension UserStore {
    /// RULEBOOK 1.23.0 §11 `CanonicalBusinessEngine` `rosterListFor(kind, roster, claimedEmails)`: the people on the
    /// Operatives, Managers or Admins list. Falls back to the per-person `rosterListKind` only when the script did not
    /// answer.
    func rosterList(_ kind: RulebookRosterListKind) -> [AppUser] {
        RulebookRosterLists.list(kind, users: organizationUsers, claimedEmails: organizationUserEmailClaims)
            ?? organizationUsers.filter { $0.rosterListKind == kind }
    }
}

// MARK: - Leave cover under each day's hours (§5, §9)

extension CanonicalBusinessEngine {
    /// RULEBOOK 1.23.0 `leaveCoverageRows(input)` with `day` = the working-hours state (`standardDayOn`), so each day of
    /// the window is read under the hours in effect on it. `day` nil keeps the input's own standard day. Nil when the
    /// script did not answer.
    nonisolated static func leaveCoverageRows(_ input: CanonicalLeaveCoverageInput, day: Any?) -> [CanonicalLeaveCoverageRow]? {
        guard let day else { return leaveCoverageRows(input) }
        guard let data = try? JSONEncoder().encode(input),
              var object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        object["day"] = day
        guard let answer = callJSON("leaveCoverageRows", arguments: [object]),
              JSONSerialization.isValidJSONObject(answer),
              let rows = try? JSONSerialization.data(withJSONObject: answer) else { return nil }
        return try? JSONDecoder().decode([CanonicalLeaveCoverageRow].self, from: rows)
    }
}

extension RulebookRosterLists {
    /// RULEBOOK 1.23.1 §11: every invite carries a user level. Throws "Choose a user level …" when
    /// `CanonicalBusinessEngine` `userMissingLevel` over the invitation's role and level flags (top level or in its
    /// `permissions` map) says it has none — before anything is written.
    nonisolated static func requireInviteLevel(_ invitation: [String: Any]) throws {
        var row: [String: Any] = ["id": "invite", "email": "invite"]
        if let role = invitation["role"] as? String { row["role"] = role }
        for key in ["isSuperAdmin", "adminAccess", "manager", "operativeMode"] {
            if let value = invitation[key] as? Bool { row[key] = value }
        }
        if let nested = invitation["permissions"] as? [String: Any] { row["permissions"] = nested }
        let missing = (CanonicalBusinessEngine.callJSON("userMissingLevel", arguments: [row]) as? NSNumber)?.boolValue ?? false
        if missing {
            throw NSError(domain: "UserCreationError", code: 400, userInfo: [NSLocalizedDescriptionKey: inviteMissingLevelMessage])
        }
    }
}

// MARK: - A named slot on its own day (§5, §8, 1.23.1)

extension CanonicalBusinessEngine {
    nonisolated private static let standardDayOnMemo = RulebookAnswerMemo<String, CanonicalStandardDayInput>(limit: 512)

    /// RULEBOOK 1.23.1 `bookingStandardDayOn(day, dayKey)`: the standard day a booking's named slot (Full day, AM, PM) is
    /// measured against on `dayKey` — the working hours in effect that day (`bookingDayInput`: the organisation's
    /// state, else `policy`), and on a Saturday or Sunday that day's own Full day window and lunch break. Memoised per
    /// day and policy; the weekday policy only when the script did not answer.
    nonisolated static func bookingStandardDayOn(policy: OrgPayrollTimePolicy, dayKey: String) -> CanonicalStandardDayInput {
        let source = OrganizationRulebookContext.payrollPolicyDocumentKey.map { "state:\($0)" } ?? "policy:\(policy.hashValue)"
        return standardDayOnMemo.value(for: "\(source)|\(dayKey)") {
            guard let row = callJSON("bookingStandardDayOn", arguments: [bookingDayInput(policy: policy), dayKey]) as? [String: Any] else {
                return nil
            }
            return CanonicalStandardDayInput(
                standardDayStart: row["standardDayStart"] as? String,
                standardDayEnd: row["standardDayEnd"] as? String,
                breakWindowStart: row["breakWindowStart"] as? String,
                breakWindowEnd: row["breakWindowEnd"] as? String
            )
        } ?? CanonicalStandardDayInput(policy: policy)
    }
}
