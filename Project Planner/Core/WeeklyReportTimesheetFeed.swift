//
//  WeeklyReportTimesheetFeed.swift
//  Project Planner
//
//  Loads fully approved timesheet `weeklyReportOverride` snapshots and tells
//  Weekly Report which live bookings to replace.
//

import Foundation
import FirebaseFirestore

struct WeeklyReportTimesheetFeed {
    struct ApprovedWeek {
        var userId: String
        var personName: String
        var role: String
        var tradeDisplay: String
        var tradeSortKey: String
        var weekStart: Date
        var weekEnd: Date
        var override: TimesheetWeeklyReportOverride
        /// User ids whose live bookings this week already includes. A freshly built
        /// snapshot covers every account on the email. A stored snapshot covers only
        /// the account that approved it, until another approved week is merged in.
        var coveredUserIds: Set<String> = []
    }

    var weeks: [ApprovedWeek]
    /// RULEBOOK 1.46.0 (review of #233): an approved week whose snapshot could not be checked against the rulebook
    /// (`applyIfFullyApproved` refused). The report then stops with this message instead of pricing that week from live
    /// bookings at live rates. Nil when every approved week was read.
    var calculationFailedMessage: String? = nil
    /// Script answers for these weeks, memoised (one call per user and day / per range, never per render).
    private let cache = FeedAnswerCache()

    init(weeks: [ApprovedWeek]) {
        self.weeks = weeks
    }

    static let empty = WeeklyReportTimesheetFeed(weeks: [])

    /// RULEBOOK 1.22.0 §7 `CanonicalBusinessEngine.timesheetFeedCovers`: an approved week of this user id covers the
    /// organisation-zone day. A merged week covers every account it was merged from (`coveredUserIds`).
    func covers(userId: String?, day: Date) -> Bool {
        guard let userId, !userId.isEmpty, !weeks.isEmpty else { return false }
        let dayKey = OrganizationRulebookContext.dayKey(day)
        let weeks = self.weeks
        return cache.covers(key: "\(userId)|\(dayKey)") {
            let rows: [[String: Any]] = weeks.flatMap { week -> [[String: Any]] in
                let ids = week.coveredUserIds.isEmpty ? [week.userId] : week.coveredUserIds.sorted()
                return ids.map { id in
                    [
                        "userId": id,
                        "weekStart": OrganizationRulebookContext.dayKey(week.weekStart),
                        "weekEnd": OrganizationRulebookContext.dayKey(week.weekEnd),
                        "override": ["lines": [Any](), "priceWork": [Any](), "expenses": [Any]()],
                    ] as [String: Any]
                }
            }
            return CanonicalBusinessEngine.timesheetFeedCovers(
                weeks: rows,
                userIds: [userId],
                dayKey: dayKey,
                timeZone: OrganizationRulebookContext.timeZoneIdentifier
            ) ?? false
        }
    }

    /// RULEBOOK 1.22.0 §7 `CanonicalBusinessEngine.timesheetFeedLabourLines`: labour lines in the range, declined out.
    func labourLines(in range: ClosedRange<Date>) -> [(week: ApprovedWeek, line: TimesheetWeeklyReportLabourLine)] {
        let (start, end) = Self.rangeKeys(range)
        let weeks = self.weeks
        let picked = cache.lines(key: "labour|\(start)|\(end)") {
            CanonicalBusinessEngine.timesheetFeedLabourLines(
                weeks: Self.weeksJSON(weeks), startDayKey: start, endDayKey: end,
                timeZone: OrganizationRulebookContext.timeZoneIdentifier
            ).map(Self.pickedIndexes) ?? []
        }
        return picked.compactMap { w, l in
            guard weeks.indices.contains(w), weeks[w].override.lines.indices.contains(l) else { return nil }
            return (weeks[w], weeks[w].override.lines[l])
        }
    }

    /// RULEBOOK 1.22.0 §7 `CanonicalBusinessEngine.timesheetFeedMoneyLines`: price work or expenses in the range,
    /// declined and amounts of 0.0001 or less out.
    func moneyLines(
        _ keyPath: KeyPath<TimesheetWeeklyReportOverride, [TimesheetWeeklyReportMoneyLine]>,
        in range: ClosedRange<Date>
    ) -> [(week: ApprovedWeek, line: TimesheetWeeklyReportMoneyLine)] {
        let kind = keyPath == \TimesheetWeeklyReportOverride.priceWork ? "priceWork" : "expenses"
        let (start, end) = Self.rangeKeys(range)
        let weeks = self.weeks
        let picked = cache.lines(key: "\(kind)|\(start)|\(end)") {
            CanonicalBusinessEngine.timesheetFeedMoneyLines(
                weeks: Self.weeksJSON(weeks), kind: kind, startDayKey: start, endDayKey: end,
                timeZone: OrganizationRulebookContext.timeZoneIdentifier
            ).map(Self.pickedIndexes) ?? []
        }
        return picked.compactMap { w, l in
            let lines = weeks.indices.contains(w) ? weeks[w].override[keyPath: keyPath] : []
            guard lines.indices.contains(l) else { return nil }
            return (weeks[w], lines[l])
        }
    }

    private static func rangeKeys(_ range: ClosedRange<Date>) -> (String, String) {
        (OrganizationRulebookContext.dayKey(range.lowerBound), OrganizationRulebookContext.dayKey(range.upperBound))
    }

    /// `[{ weekIndex, line: { _l } }]` → (week index, line index).
    private static func pickedIndexes(_ rows: [[String: Any]]) -> [(Int, Int)] {
        rows.compactMap { row in
            guard let w = (row["weekIndex"] as? NSNumber)?.intValue,
                  let line = row["line"] as? [String: Any],
                  let l = (line["_l"] as? NSNumber)?.intValue else { return nil }
            return (w, l)
        }
    }

    /// Weeks as `FeedWeek` rows: organisation-zone day keys, each line tagged with its index (`_l`) so an answer maps
    /// back to the Swift value. `extra` adds fields per week (the merge tags).
    fileprivate static func weeksJSON(_ weeks: [ApprovedWeek], extra: ((Int, ApprovedWeek) -> [String: Any])? = nil) -> [[String: Any]] {
        weeks.enumerated().map { index, week in
            var row: [String: Any] = [
                "userId": week.userId,
                "weekStart": OrganizationRulebookContext.dayKey(week.weekStart),
                "weekEnd": OrganizationRulebookContext.dayKey(week.weekEnd),
                "override": [
                    "lines": week.override.lines.enumerated().map { tagged(labourJSON($1, index: $0), week: index) },
                    "priceWork": week.override.priceWork.enumerated().map { tagged(moneyJSON($1, index: $0), week: index) },
                    "expenses": week.override.expenses.enumerated().map { tagged(moneyJSON($1, index: $0), week: index) },
                ] as [String: Any],
            ]
            if let extra { row.merge(extra(index, week)) { _, new in new } }
            return row
        }
    }

    /// `_s`: the index of the week a line came from (in the list sent), so a merged line maps back.
    private static func tagged(_ row: [String: Any], week: Int) -> [String: Any] {
        var out = row
        out["_s"] = week
        return out
    }

    fileprivate static func labourJSON(_ line: TimesheetWeeklyReportLabourLine, index: Int) -> [String: Any] {
        [
            "_l": index,
            "id": line.id,
            "bookingId": line.bookingId.map { $0 as Any } ?? NSNull(),
            "date": OrganizationRulebookContext.dayKey(line.date),
            "locationKind": line.locationKind,
            "jobNumber": line.jobNumber,
            "projectName": line.projectName,
            "paidHours": line.paidHours,
            "days": line.days,
            "amount": line.amount,
            "isOvertime": line.isOvertime,
            "details": line.details,
            "decision": line.decision.rawValue,
        ]
    }

    fileprivate static func moneyJSON(_ line: TimesheetWeeklyReportMoneyLine, index: Int) -> [String: Any] {
        [
            "_l": index,
            "id": line.id,
            "date": OrganizationRulebookContext.dayKey(line.date),
            "jobNumber": line.jobNumber,
            "title": line.title,
            "amount": line.amount,
            "details": line.details,
            "decision": line.decision.rawValue,
        ]
    }

    @MainActor
    static func load(
        users: [AppUser],
        range: ClosedRange<Date>,
        settings: OrganizationInvoicingSettings,
        firebaseBackend: FirebaseBackend,
        bookingStore: BookingStore,
        managerScheduleStore: ManagerScheduleStore,
        operativeStore: OperativeStore,
        projectStore: ProjectStore,
        dayRateHistory: OperativeDayRateHistoryCollection,
        payrollPolicy: OrgPayrollTimePolicy,
        scheduleOptions: MyScheduleOptions
    ) async -> WeeklyReportTimesheetFeed {
        let periods = TimesheetPayrollPolicy.payPeriodsOverlapping(range: range, settings: settings)
        let orgId = firebaseBackend.currentOrganization?.firestoreDocumentId
        var weeks: [ApprovedWeek] = []
        var refusal: String?

        for user in users {
            guard user.participatesInTimesheets() else { continue }
            var listedFromCloud = false
            if let orgId {
                if let rows = try? await firebaseBackend.listTimesheetStates(
                    organizationId: orgId,
                    userId: user.id,
                    limit: 80
                ) {
                    listedFromCloud = true
                    for row in rows {
                        if let weekStart = (row["weekStart"] as? Timestamp)?.dateValue(),
                           let decoded = TimesheetDraftStore.decodeFirestoreMap(row) {
                            // The sheet key is the organisation-zone day, never the device's (§1).
                            let day = OrganizationRulebookContext.calendar.startOfDay(for: weekStart)
                            TimesheetDraftStore.save(decoded, userId: user.id, weekStart: day, organizationId: orgId)
                        }
                    }
                }
            }

            let name = user.fullName.isEmpty ? user.email : user.fullName
            let role: String = {
                let adminLike = user.isSuperAdmin || user.permissions.adminAccess || user.role == .admin || user.role == .manager || user.permissions.manager
                return adminLike ? "Admin User" : "Operative"
            }()
            let reportingUser = StaffEmailIdentity.preferredUser(sharing: user.email, in: users) ?? user
            let tradeDisplay = StaffEmailIdentity.reportTrade(for: reportingUser)
            let tradeSortKey = StaffTradeType.sortKey(presetRaw: reportingUser.tradeTypePreset, custom: reportingUser.tradeTypeCustom)

            for period in periods {
                var draft = TimesheetDraftStore.load(userId: user.id, weekStart: period.start, organizationId: orgId)
                if !listedFromCloud, let orgId {
                    if let remote = await TimesheetDraftStore.refreshFromCloud(
                        userId: user.id,
                        weekStart: period.start,
                        firebaseBackend: firebaseBackend,
                        organizationId: orgId
                    ) {
                        draft = remote
                    }
                }
                guard TimesheetApprovalPolicy.isTimesheetFullyApproved(draft: draft, user: user) else { continue }

                let storedAlready = draft.weeklyReportOverride != nil
                var working = draft
                if working.weeklyReportOverride == nil {
                    // RULEBOOK 1.46.0: a week the rulebook could not check stops the report (never priced live).
                    if let failed = TimesheetWeeklyReportOverrideBuilder.applyIfFullyApproved(
                        to: &working,
                        user: user,
                        week: period,
                        bookings: bookingStore.bookings,
                        managerBookings: managerScheduleStore.managerSiteBookings,
                        operatives: operativeStore.allOperatives,
                        projects: projectStore.projects,
                        smallWorks: projectStore.smallWorks,
                        history: dayRateHistory,
                        policy: payrollPolicy,
                        organization: firebaseBackend.currentOrganization,
                        scheduleOptions: scheduleOptions,
                        viewer: nil,
                        relatedUsers: users
                    ) {
                        refusal = failed
                        continue
                    }
                    // Built in memory for this report only. Producing a report never writes anyone's
                    // timesheet (§7: reports are not stored); the snapshot is written by their sign-off.
                }
                guard let override = working.weeklyReportOverride else { continue }
                let aliases = StaffEmailIdentity.userIds(sharing: user.email, in: users)
                weeks.append(
                    ApprovedWeek(
                        userId: user.id,
                        personName: name,
                        role: role,
                        tradeDisplay: tradeDisplay,
                        tradeSortKey: tradeSortKey,
                        weekStart: period.start,
                        weekEnd: period.end,
                        override: override,
                        coveredUserIds: storedAlready ? [user.id] : (aliases.isEmpty ? [user.id] : aliases)
                    )
                )
            }
        }

        var feed = WeeklyReportTimesheetFeed(weeks: mergeApprovedWeeks(weeks, users: users))
        feed.calculationFailedMessage = refusal
        return feed
    }

    /// RULEBOOK 1.22.0 §7 `CanonicalBusinessEngine.mergeTimesheetFeedWeeks`: one approved week per person (email, else
    /// user id) and week start; a shared booking counts once and lines only one account has stay. The preferred
    /// account's week goes first so the script keeps it as the primary (its name, role and trade). Each week carries a
    /// marker line (`bookingId` `__feed-week-{n}`, unique, so the union keeps it) only to learn which weeks were merged
    /// into which — its `coveredUserIds` are their union; the markers are removed again. Empty when the script did
    /// not answer, so the report falls back to live bookings rather than counting a sheet twice.
    static func mergeApprovedWeeks(_ weeks: [ApprovedWeek], users: [AppUser]) -> [ApprovedWeek] {
        guard !weeks.isEmpty else { return [] }
        let weekUserIds = Set(weeks.map(\.userId))
        func preferredId(for userId: String) -> String? {
            let email = StaffEmailIdentity.emailKey(users.first { $0.id == userId }?.email)
            guard !email.isEmpty else { return userId }
            let accounts = users.filter { weekUserIds.contains($0.id) && StaffEmailIdentity.emailKey($0.email) == email }
            return StaffEmailIdentity.preferredUser(accounts)?.id
        }
        let order = weeks.indices.sorted { a, b in
            let pa = preferredId(for: weeks[a].userId) == weeks[a].userId ? 0 : 1
            let pb = preferredId(for: weeks[b].userId) == weeks[b].userId ? 0 : 1
            return pa == pb ? a < b : pa < pb
        }
        let ordered = order.map { weeks[$0] }
        var input = weeksJSON(ordered) { index, _ in ["_w": index] }
        for index in input.indices {
            var override = input[index]["override"] as? [String: Any] ?? [:]
            var lines = override["lines"] as? [[String: Any]] ?? []
            lines.append(["_m": index, "bookingId": "__feed-week-\(index)", "date": input[index]["weekStart"] ?? ""])
            override["lines"] = lines
            input[index]["override"] = override
        }
        let people: [[String: Any]] = users.map { ["id": $0.id, "email": $0.email] }
        guard let merged = CanonicalBusinessEngine.mergeTimesheetFeedWeeks(
            weeks: input, people: people, timeZone: OrganizationRulebookContext.timeZoneIdentifier
        ) else { return [] }

        return merged.compactMap { row -> ApprovedWeek? in
            guard let primaryIndex = (row["_w"] as? NSNumber)?.intValue, ordered.indices.contains(primaryIndex) else { return nil }
            let override = row["override"] as? [String: Any] ?? [:]
            let lineRows = override["lines"] as? [[String: Any]] ?? []
            let members = lineRows.compactMap { ($0["_m"] as? NSNumber)?.intValue }.filter { ordered.indices.contains($0) }
            guard members.count > 1 else { return ordered[primaryIndex] }
            // Each kept line names its source week (`_s`) and its index there (`_l`).
            func lines<Line>(_ rows: [[String: Any]], _ pick: (ApprovedWeek) -> [Line]) -> [Line] {
                rows.compactMap { line -> Line? in
                    guard let source = (line["_s"] as? NSNumber)?.intValue,
                          let l = (line["_l"] as? NSNumber)?.intValue,
                          ordered.indices.contains(source) else { return nil }
                    let all = pick(ordered[source])
                    return all.indices.contains(l) ? all[l] : nil
                }
            }
            var week = ordered[primaryIndex]
            week.coveredUserIds = Set(members.flatMap { index -> [String] in
                let member = ordered[index]
                return member.coveredUserIds.isEmpty ? [member.userId] : Array(member.coveredUserIds)
            })
            week.override.lines = lines(lineRows.filter { $0["_m"] == nil }) { $0.override.lines }
            week.override.priceWork = lines(override["priceWork"] as? [[String: Any]] ?? []) { $0.override.priceWork }
            week.override.expenses = lines(override["expenses"] as? [[String: Any]] ?? []) { $0.override.expenses }
            return week
        }
    }
}

/// Memoised script answers for one loaded feed (a reference, so the value-type feed in `@State` shares it).
private final class FeedAnswerCache {
    private var coverage: [String: Bool] = [:]
    private var picked: [String: [(Int, Int)]] = [:]

    func covers(key: String, compute: () -> Bool) -> Bool {
        if let hit = coverage[key] { return hit }
        let value = compute()
        coverage[key] = value
        return value
    }

    func lines(key: String, compute: () -> [(Int, Int)]) -> [(Int, Int)] {
        if let hit = picked[key] { return hit }
        let value = compute()
        picked[key] = value
        return value
    }
}
