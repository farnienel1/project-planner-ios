import XCTest
@testable import Project_Planner

/// RULEBOOK 1.23.0 / 1.23.1 "People, Home and per-day hours" on iOS through `CanonicalBusinessEngine`, plus the two 1.22
/// follow-ups (PAYE days on totals and invoices, Holiday Report days). Every expected value was checked in node against
/// the packed `canonical-business.js` (rulebook 1.23.1, sha256 c31c421b…c2ac8261) with the JSON these wrappers send.
/// The 1.23 parity-fixture cases themselves run in `CanonicalParityFixtureTests`.
@MainActor
final class Rulebook1230Tests: XCTestCase {
    private let london = "Europe/London"

    private func instant(_ iso: String) throws -> Date {
        try XCTUnwrap(ISO8601DateFormatter().date(from: iso))
    }

    private func fixtureArgument(named name: String) throws -> [String: Any] {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "CanonicalParityFixture", withExtension: "json"))
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let row = try XCTUnwrap((root["cases"] as? [[String: Any]])?.first { $0["name"] as? String == name })
        return try XCTUnwrap((row["args"] as? [Any])?.first as? [String: Any])
    }

    func testThePackedScriptIsRulebook1231OrLater() throws {
        let stamp = try XCTUnwrap(CanonicalBusinessEngine.rulebookStamp())
        let parts = stamp.version.split(separator: ".").compactMap { Int($0) }
        XCTAssertFalse(parts.lexicographicallyPrecedes([1, 23, 1]), "rulebook \(stamp.version) predates 1.23.1")
        let names = Set(CanonicalBusinessEngine.exportNames())
        for name in [
            "rosterListFor", "rosterListKind", "clashManagerIds", "userMissingLevel", "usersMissingLevel",
            "homeOverviewMetrics", "qualificationExpiryCount", "isTaskOverdue", "deadlineUrgency", "deadlineDaysRemaining",
            "leaveDayKind", "siteMapPins", "jobTileBadges", "mergeVariationSources", "openVariationCount",
            "bookingRequestClashIds", "bookingStandardDayOn", "standardDayOn",
        ] {
            XCTAssertTrue(names.contains(name), "\(name) missing from the packed script")
        }
    }

    // MARK: People lists (§11)

    func testEveryPersonIsOnOneListByLevel() {
        let flagless = AppUser(id: "flag", email: "f@x.com", organizationId: "org", role: .viewer, firstName: "Zed", surname: "F", isActive: true, passwordSet: true)
        let admin = AppUser(id: "adm", email: "a@x.com", organizationId: "org", role: .admin, firstName: "Amy", surname: "A", isActive: true, passwordSet: true)
        let manager = AppUser(id: "mgr", email: "m@x.com", organizationId: "org", role: .manager, firstName: "Bob", surname: "M", isActive: true, passwordSet: true, permissions: UserPermissions(manager: true))
        let operativeByRole = AppUser(id: "op", email: "o@x.com", organizationId: "org", role: .operative, isActive: true, passwordSet: true)
        XCTAssertEqual(flagless.rosterListKind, .managers, "no level flag reads as manager level")
        XCTAssertEqual(admin.rosterListKind, .admins)
        XCTAssertEqual(manager.rosterListKind, .managers)
        XCTAssertEqual(operativeByRole.rosterListKind, .operatives, "the operative role is the operative level")
        let roster = [flagless, admin, manager]
        XCTAssertEqual(RulebookRosterLists.list(.managers, users: roster)?.map(\.id), ["mgr", "flag"], "sorted by name; never the admin")
        XCTAssertEqual(RulebookRosterLists.list(.admins, users: roster)?.map(\.id), ["adm"])
    }

    func testClashManagerIdsAreActiveAdminsAndManagerFlags() {
        let rows: [[String: Any]] = [
            ["id": "A", "isActive": true, "isSuperAdmin": false, "adminAccess": true, "manager": false],
            ["id": "M", "isActive": true, "isSuperAdmin": false, "adminAccess": false, "manager": true],
            ["id": "I", "isActive": false, "isSuperAdmin": false, "adminAccess": false, "manager": true],
            ["id": "O", "isActive": true, "isSuperAdmin": false, "adminAccess": false, "manager": false],
            ["id": "R", "isActive": true, "isSuperAdmin": false, "adminAccess": false, "manager": false, "role": "admin"],
        ]
        XCTAssertEqual(RulebookRosterLists.clashManagerIds(rows), ["A", "M", "R"])
    }

    func testUserMissingLevelReadsTheStoredDocument() {
        let roleOnly = FirebaseBackend.parseAppUserDocument(userId: "u1", data: ["email": "u@x.com", "role": "manager"], annualLeaveDefaults: nil)
        XCTAssertEqual(roleOnly.storedRoleText, "manager")
        XCTAssertEqual(roleOnly.storedLevelFlags, [:])
        XCTAssertTrue(RulebookRosterLists.userMissingLevel(roleOnly), "a manager role with no level flag stored is a data fault")
        let flagged = FirebaseBackend.parseAppUserDocument(userId: "u2", data: ["email": "v@x.com", "role": "manager", "permissions": ["manager": true]], annualLeaveDefaults: nil)
        XCTAssertFalse(RulebookRosterLists.userMissingLevel(flagged))
        let admin = FirebaseBackend.parseAppUserDocument(userId: "u3", data: ["email": "w@x.com", "role": "admin"], annualLeaveDefaults: nil)
        XCTAssertFalse(RulebookRosterLists.userMissingLevel(admin))
        XCTAssertEqual(RulebookRosterLists.usersMissingLevel([roleOnly, flagged, admin]).map(\.id), ["u1"])
    }

    func testAnInviteWithoutALevelIsRefused() {
        XCTAssertTrue(RulebookRosterLists.inviteHasNoLevel(UserPermissions()))
        XCTAssertFalse(RulebookRosterLists.inviteHasNoLevel(UserPermissions(operativeMode: true)))
        XCTAssertThrowsError(try RulebookRosterLists.requireInviteLevel(["permissions": ["manager": false, "operativeMode": false]]))
        XCTAssertNoThrow(try RulebookRosterLists.requireInviteLevel(["role": "manager", "permissions": ["manager": true]]))
    }

    // MARK: Home (§23), qualifications (§5)

    func testHomeFiguresCountEachPersonOnce() throws {
        let input = try fixtureArgument(named: "1.23.0 homeOverviewMetrics: New York day, one person under two ids")
        let figures = try XCTUnwrap(CanonicalBusinessEngine.homeOverviewMetrics(input))
        XCTAssertEqual(figures.dayKey, "2026-11-03")
        XCTAssertEqual(figures.tasksDueToday, 1)
        XCTAssertEqual(figures.tasksDueThisWeek, 2)
        XCTAssertEqual(figures.tasksOverdue, 1)
        XCTAssertEqual(figures.operativesOnSiteToday, 1, "OP-ROW and u-op are one person")
        XCTAssertEqual(figures.peopleOnSiteToday, 2)
        XCTAssertEqual(figures.managersOnALToday, 1, "a person with no level flag is on Managers")
    }

    func testQualificationCountIsTheWarningRows() throws {
        let now = try instant("2026-11-03T12:00:00Z")
        func days(_ n: Double) -> String { CanonicalBusinessEngine.isoString(from: now.addingTimeInterval(n * 86_400)) }
        let operatives: [[String: Any]] = [
            ["id": "OP1", "isActive": true, "email": "a@x.com", "name": "A", "expiries": [
                ["qualificationId": "q1", "name": "q1", "expiryIso": days(10)],
                ["qualificationId": "q2", "name": "q2", "expiryIso": days(-3)],
                ["qualificationId": "q3", "name": "q3", "expiryIso": days(90)],
            ]],
            ["id": "OP2", "isActive": false, "email": "b@x.com", "name": "B", "expiries": [
                ["qualificationId": "q1", "name": "q1", "expiryIso": days(5)],
            ]],
        ]
        let count = try XCTUnwrap(CanonicalBusinessEngine.qualificationExpiryCount(operatives: operatives, reference: now, timeZone: london))
        XCTAssertEqual(count, RulebookQualificationExpiryCount(expired: 1, expiringSoon: 1, total: 2), "inactive and 90-day rows left out")
    }

    func testTasksAndDeadlinesOnTheOrganisationDay() throws {
        let now = try instant("2026-11-03T12:00:00Z")
        XCTAssertTrue(CanonicalBusinessEngine.isTaskOverdue(status: "To Do", dueDate: try instant("2026-11-02T12:00:00Z"), now: now, timeZone: london))
        XCTAssertFalse(CanonicalBusinessEngine.isTaskOverdue(status: "Completed", dueDate: try instant("2026-11-02T12:00:00Z"), now: now, timeZone: london))
        XCTAssertFalse(CanonicalBusinessEngine.isTaskOverdue(status: "To Do", dueDate: try instant("2026-11-03T08:00:00Z"), now: now, timeZone: london), "due today is not overdue")
        let overdue = try XCTUnwrap(CanonicalBusinessEngine.deadlineUrgency(status: "blocked", due: try instant("2026-11-01T12:00:00Z"), now: now, timeZone: london))
        XCTAssertEqual(overdue.kind, "overdue")
        XCTAssertEqual(overdue.days, 2, "overdue beats blocked")
        let soon = try XCTUnwrap(CanonicalBusinessEngine.deadlineUrgency(status: "inProgress", due: try instant("2026-11-05T12:00:00Z"), now: now, timeZone: london))
        XCTAssertEqual(soon.kind, "soon")
        XCTAssertEqual(soon.days, 2)
        XCTAssertEqual(CanonicalBusinessEngine.deadlineDaysRemaining(due: try instant("2026-11-10T12:00:00Z"), now: now, timeZone: london), 7)
    }

    // MARK: Leave calendar (§9)

    func testLeaveDayKind() {
        func record(_ id: String, _ start: String, _ end: String, _ slot: String, _ status: String) -> RulebookLeaveReportRecord {
            RulebookLeaveReportRecord(id: id, userId: "u", operativeId: nil, startDayKey: start, endDayKey: end, timeSlot: slot, status: status)
        }
        let week = [record("H1", "2026-11-02", "2026-11-06", "FULL DAY", "approved")]
        XCTAssertEqual(CanonicalBusinessEngine.leaveDayAnswer(records: week, dayKey: "2026-11-04", timeZone: london)?.kind, .approvedFull)
        XCTAssertEqual(
            CanonicalBusinessEngine.leaveDayKind(records: [record("H1", "2026-11-06", "2026-11-09", "FULL DAY", "approved")], dayKey: "2026-11-07", timeZone: london),
            RulebookLeaveDayKind.none,
            "a Saturday inside a multi-day record is not a leave day"
        )
        let halves = [record("am", "2026-11-02", "2026-11-02", "AM", "approved"), record("pm", "2026-11-02", "2026-11-02", "PM", "pending")]
        let answer = CanonicalBusinessEngine.leaveDayAnswer(records: halves, dayKey: "2026-11-02", timeZone: london)
        XCTAssertEqual(answer?.kind, .pendingHalf)
        XCTAssertEqual(answer?.recordId, "pm")
    }

    // MARK: Job tiles, variations (§21, §22)

    func testJobTileBadgesAndVariations() throws {
        let input = try fixtureArgument(named: "1.23.0 jobTileBadges: one person once; open firms; open tasks")
        XCTAssertEqual(CanonicalBusinessEngine.jobTileBadges(input), RulebookJobTileBadges(tentativeBookings: 1, openTasks: 1, activeUsers: 3))
        let kept = CanonicalBusinessEngine.mergeVariationSources(
            collection: [["id": "A", "updatedAtMs": 100, "_i": "c:0"]],
            fallback: [["id": "a", "updatedAtMs": 200, "_i": "f:0"], ["id": "B", "updatedAtMs": 1, "_i": "f:1"]],
            itemDocs: []
        )
        XCTAssertEqual(kept, ["f:0", "f:1"], "the newer copy of A wins, ids without case")
        XCTAssertEqual(CanonicalBusinessEngine.openVariationCount([
            ["isDeleted": false, "status": "open"], ["isDeleted": true, "status": "open"], ["isDeleted": false, "status": "closed"],
        ]), 1)
    }

    // MARK: A booking being made (§5)

    func testBookingRequestClashIdsReadsTheBookedDaysHours() throws {
        let day = try XCTUnwrap(CanonicalBusinessEngine.payrollPolicyJSON(.default))
        let saturdayFull = RulebookClashBooking(id: "SAT-FULL", dayKey: "2026-11-07", timeSlot: "FULL DAY")
        let outside = RulebookClashBooking(id: "new", dayKey: "2026-11-07", timeSlot: "CUSTOM_HOURS", workStartTime: "14:00", workEndTime: "16:00")
        let inside = RulebookClashBooking(id: "new", dayKey: "2026-11-07", timeSlot: "CUSTOM_HOURS", workStartTime: "08:00", workEndTime: "10:00")
        XCTAssertEqual(CanonicalBusinessEngine.bookingRequestClashIds(request: outside, existing: [saturdayFull], day: day), [],
                       "a Saturday Full day is Saturday's own 07:30–13:00 window")
        XCTAssertEqual(CanonicalBusinessEngine.bookingRequestClashIds(request: inside, existing: [saturdayFull], day: day), ["SAT-FULL"])
        let night = RulebookClashBooking(id: "N", dayKey: "2026-11-03", timeSlot: "CUSTOM_HOURS", workStartTime: "22:00", workEndTime: "06:00")
        var cancelled = RulebookClashBooking(id: "X", dayKey: "2026-11-04", timeSlot: "CUSTOM_HOURS", workStartTime: "09:00", workEndTime: "12:00")
        cancelled.status = "Cancelled"
        let early = RulebookClashBooking(id: "new", dayKey: "2026-11-04", timeSlot: "CUSTOM_HOURS", workStartTime: "05:00", workEndTime: "09:00")
        XCTAssertEqual(CanonicalBusinessEngine.bookingRequestClashIds(request: early, existing: [night, cancelled], day: day), ["N"],
                       "an overnight booking reaches the next morning; cancelled never clashes")
    }

    // MARK: 1.22 follow-ups

    /// A PAYE day's expense is left out of the totals and the invoice (`timesheetDaysForPerson` as `timesheetDays`).
    func testPayeDayExtrasAreLeftOutOfTotals() throws {
        var user = LogicFixtures.selfEmployedUser()
        user.employmentType = .selfEmployed
        user.employmentTypeTransitionFrom = .paye
        user.employmentTypeEffectiveAt = try instant("2026-10-20T23:00:00Z")
        let period = try instant("2026-10-19T00:00:00Z")...instant("2026-10-25T12:00:00Z")
        XCTAssertEqual(TimesheetTotalsSource.timesheetDays(for: user, period: period),
                       ["2026-10-21", "2026-10-22", "2026-10-23", "2026-10-24", "2026-10-25"])
        let thursday = try instant("2026-10-22T11:00:00Z")
        let line = TimesheetPayrollLineItem(
            id: "op-B1-normal", date: thursday, jobNumber: "100", projectName: "Site", details: "Full day",
            paidHours: 8, payrollBasis: .dayRate, dayRate: 200, hourlyRate: nil, amount: 200, isPayeDay: false,
            isOvertimeLine: false, bookingId: "op-B1", bookingPaidHours: 8, bookingOvertimeHours: 0
        )
        var draft = TimesheetDraft(
            expenseEntries: [
                TimesheetExpenseEntry(id: UUID(), title: "Mon skip", details: "", jobNumber: "100", date: try instant("2026-10-19T11:00:00Z"), amount: 40, managerDecision: .approved),
                TimesheetExpenseEntry(id: UUID(), title: "Thu parking", details: "", jobNumber: "100", date: thursday, amount: 25, managerDecision: .approved),
            ],
            priceWorkEntries: []
        )
        draft.managerSignedAt = try instant("2026-10-26T10:00:00Z")
        let totals = try XCTUnwrap(TimesheetTotalsSource.totals(lines: [line], draft: draft, decided: true, subject: user, period: period))
        XCTAssertClose(totals.total, 225, "Monday was a PAYE day: its skip is not on the sheet")
        XCTAssertClose(totals.expenses, 25)
        XCTAssertEqual(totals.invoiceRowCount, 2)
        let withoutDays = try XCTUnwrap(TimesheetTotalsSource.totals(lines: [line], draft: draft, decided: true))
        XCTAssertClose(withoutDays.total, 265)
    }
}
