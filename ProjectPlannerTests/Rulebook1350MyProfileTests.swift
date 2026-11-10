import XCTest
@testable import Project_Planner

/// RULEBOOK 1.35.0 §12 iOS follow-on (web hand-off v1.35.0): the My Profile figures. Every answer is `myProfileSummary`
/// in the packed script through `CanonicalBusinessEngine`; these tests lock the Swift input mapping
/// (`MyProfileSummaryInput`) and how the answer is read (`parseMyProfileSummary`). TEST data only.
@MainActor
final class Rulebook1350MyProfileTests: XCTestCase {
    override func setUp() {
        super.setUp()
        OrganizationRulebookContext.update(from: Organization(firestoreDocumentId: "TEST-ORG-1350", name: "TEST-Company 1350"))
    }

    /// Wednesday 4 November 2026, midday in London.
    private let wednesdayMs: Double = 1_793_793_600_000

    private func person(_ id: String, first: String, last: String, managers: [String] = []) -> AppUser {
        AppUser(
            id: id,
            email: "\(id.lowercased())@example.com",
            organizationId: "TEST-ORG-1350",
            role: .manager,
            firstName: first,
            surname: last,
            isActive: true,
            passwordSet: true,
            permissions: UserPermissions(manager: true),
            assignedManagerUserIds: managers
        )
    }

    private func input(user: [String: Any], roster: [[String: Any]], extra: [String: Any] = [:]) -> [String: Any] {
        var row: [String: Any] = [
            "nowMs": wednesdayMs,
            "timeZone": "Europe/London",
            "viewer": ["id": user["id"] ?? "", "email": user["email"] ?? ""],
            "user": user,
            "roster": roster,
            "operatives": [],
            "managers": [],
            "leaveDefaults": ["daysPerYear": 25, "startMonth": 1, "endMonth": 12, "carriesOver": false],
            "holidays": [],
            "nonWorkingDayKeys": [],
            "tasks": [],
            "bookings": [],
            "managerSiteBookings": [],
            "policyState": [:] as [String: Any],
        ]
        for (key, value) in extra { row[key] = value }
        return row
    }

    func testScriptAnswersAndEveryFigureIsRead() throws {
        let me = person("TEST-ME", first: "TEST-Sam", last: "Smith", managers: ["TEST-LM1", "TEST-LM2"])
        let roster = [
            me,
            person("TEST-LM1", first: "TEST-Lee", last: "Line"),
            person("TEST-LM2", first: "TEST-Kim", last: "Kerr"),
        ]
        let rows = roster.map(RulebookRosterLists.levelRow)
        let answer = try XCTUnwrap(CanonicalBusinessEngine.myProfileSummary(input(
            user: MyProfileSummaryInput.userRow(me),
            roster: rows,
            extra: [
                "holidays": [
                    ["id": "TEST-H1", "userId": "TEST-ME", "startDayKey": "2026-10-05", "endDayKey": "2026-10-06", "timeSlot": "FULL DAY", "status": "approved"],
                    ["id": "TEST-H2", "userId": "TEST-ME", "startDayKey": "2026-12-01", "endDayKey": "2026-12-01", "timeSlot": "AM", "status": "pending"],
                ],
                "bookings": [
                    // Overlapping bookings count once; next Monday is outside the week.
                    ["operativeId": "TEST-ME", "dayKey": "2026-11-02", "status": "Confirmed", "timeSlot": "CUSTOM_HOURS", "workStartTime": "08:00", "workEndTime": "13:00", "isBreakRemoved": false],
                    ["operativeId": "test-me", "dayKey": "2026-11-02", "status": "Confirmed", "timeSlot": "CUSTOM_HOURS", "workStartTime": "11:00", "workEndTime": "14:00", "isBreakRemoved": false],
                    ["operativeId": "TEST-ME", "dayKey": "2026-11-09", "status": "Confirmed", "timeSlot": "FULL DAY", "isBreakRemoved": false],
                ],
                "tasks": [
                    ["status": "To Do", "dueDate": NSNull(), "assignedOperativeIds": ["TEST-ME"]],
                    ["status": "To Do", "dueDate": "2026-11-01", "assignedOperativeIds": ["TEST-ME"]],
                    ["status": "To Do", "dueDate": "2026-11-01", "assignedOperativeIds": ["TEST-OTHER"]],
                ],
            ]
        )))
        XCTAssertEqual(answer.dayKey, "2026-11-04")
        XCTAssertTrue(answer.leave.hasAllowance)
        XCTAssertEqual(answer.leave.taken, 2)
        XCTAssertEqual(answer.leave.pending, 0.5)
        XCTAssertEqual(answer.leave.remaining, 22.5)
        XCTAssertEqual(answer.weekStartDayKey, "2026-11-02")
        XCTAssertEqual(answer.weekEndDayKey, "2026-11-08")
        XCTAssertEqual(answer.hoursThisWeek, 5.5, accuracy: 0.001)
        XCTAssertEqual(answer.openTasks, 2)
        XCTAssertEqual(answer.overdueTasks, 1)
        XCTAssertEqual(answer.qualificationsTotal, 0)
        // Owner Q5: every line manager by name.
        XCTAssertEqual(answer.lineManagers.map(\.name), ["TEST-Lee Line", "TEST-Kim Kerr"])
    }

    func testNoAllowanceAndNoLineManager() throws {
        var me = person("TEST-ME", first: "TEST-Sam", last: "Smith")
        me.annualLeaveEnabled = false
        me.hasNoLineManager = true
        let answer = try XCTUnwrap(CanonicalBusinessEngine.myProfileSummary(input(
            user: MyProfileSummaryInput.userRow(me),
            roster: [RulebookRosterLists.levelRow(me)]
        )))
        XCTAssertFalse(answer.leave.hasAllowance)
        XCTAssertNil(answer.leave.remaining)
        XCTAssertEqual(answer.lineManagerLabel, "No line manager")
        XCTAssertTrue(answer.lineManagers.isEmpty)
    }

    func testUnknownLineManagerIsNamedUnknownPerson() throws {
        let me = person("TEST-ME", first: "TEST-Sam", last: "Smith", managers: ["TEST-GONE"])
        let answer = try XCTUnwrap(CanonicalBusinessEngine.myProfileSummary(input(
            user: MyProfileSummaryInput.userRow(me),
            roster: [RulebookRosterLists.levelRow(me)]
        )))
        XCTAssertEqual(answer.lineManagers.map(\.name), ["Unknown person"])
        XCTAssertEqual(answer.lineManagers.first?.resolved, false)
    }

    func testBuilderMapsTheUserDocumentFields() {
        var me = person("TEST-ME", first: "TEST-Sam", last: "Smith", managers: ["TEST-LM1"])
        me.employmentStartDate = "2026-07-01"
        me.annualLeaveYearAllowance = 12
        me.annualLeaveYearAllowanceKey = "2026-01-01"
        let row = MyProfileSummaryInput.userRow(me)
        XCTAssertEqual(row["id"] as? String, "TEST-ME")
        XCTAssertEqual(row["employmentStartDate"] as? String, "2026-07-01")
        XCTAssertEqual(row["annualLeaveYearAllowance"] as? Double, 12)
        XCTAssertEqual(row["assignedManagerUserIds"] as? [String], ["TEST-LM1"])
        let built = MyProfileSummaryInput.build(
            user: me, roster: [me], operatives: [], managers: [], holidays: [], tasks: [], bookings: [], managerBookings: [],
            now: Date(timeIntervalSince1970: wednesdayMs / 1000)
        )
        XCTAssertEqual(built["timeZone"] as? String, OrganizationRulebookContext.timeZoneIdentifier)
        XCTAssertNotNil(CanonicalBusinessEngine.myProfileSummary(built))
    }

    func testDisplayTextIsPlainFormatting() {
        XCTAssertEqual(MyProfileFiguresCard.daysText(1), "1 day")
        XCTAssertEqual(MyProfileFiguresCard.daysText(21.5), "21.5 days")
        XCTAssertEqual(MyProfileFiguresCard.hoursText(19.5), "19.5h")
        XCTAssertEqual(MyProfileFiguresCard.hoursText(8), "8h")
    }

    /// Review fix: `nowMs` is floored to the whole minute, so the memo key (the exact input) is the same on every
    /// redraw within a minute and never runs ahead of the clock.
    func testNowIsFlooredToTheMinute() {
        let base = Date(timeIntervalSince1970: wednesdayMs / 1000)
        XCTAssertEqual(MyProfileSummaryInput.nowMsFlooredToMinute(base.addingTimeInterval(59.9)), wednesdayMs)
        XCTAssertEqual(MyProfileSummaryInput.nowMsFlooredToMinute(base.addingTimeInterval(60)), wednesdayMs + 60_000)
        let me = person("TEST-ME", first: "TEST-Sam", last: "Smith")
        let first = MyProfileSummaryInput.build(
            user: me, roster: [me], operatives: [], managers: [], holidays: [], tasks: [], bookings: [], managerBookings: [],
            now: base.addingTimeInterval(1)
        )
        let second = MyProfileSummaryInput.build(
            user: me, roster: [me], operatives: [], managers: [], holidays: [], tasks: [], bookings: [], managerBookings: [],
            now: base.addingTimeInterval(42)
        )
        XCTAssertEqual(CanonicalBusinessEngine.rulebookMemoKey(first), CanonicalBusinessEngine.rulebookMemoKey(second))
    }

    /// Review fix (RULEBOOK 1.35.0 `myProfileBankHolidayRange`): the bank-holiday years a leave balance needs include
    /// the previous leave year, for carry-over. The range comes from the script, never Swift.
    func testBankHolidayRangeIncludesThePreviousLeaveYear() throws {
        var me = person("TEST-ME", first: "TEST-Sam", last: "Smith")
        me.annualLeaveEnabled = true
        me.annualLeaveYearStartMonth = 4
        me.annualLeaveYearEndMonth = 3
        let range = try XCTUnwrap(CanonicalBusinessEngine.myProfileBankHolidayRange([
            "nowMs": wednesdayMs,
            "timeZone": "Europe/London",
            "user": MyProfileSummaryInput.userRow(me),
            "leaveDefaults": ["daysPerYear": 25, "startMonth": 1, "endMonth": 12, "carriesOver": true],
        ]))
        XCTAssertEqual(range.startDayKey, "2025-04-01")
        XCTAssertEqual(range.endDayKey, "2027-03-31")
        XCTAssertEqual(range.years, [2025, 2026, 2027])
    }

    /// Carry-over with last year's Easter: Good Friday and Easter Monday 2025 inside a leave record are not leave.
    func testCarryOverUsesLastYearsBankHolidays() throws {
        let user: [String: Any] = [
            "id": "TEST-ME", "email": "test-me@example.com", "annualLeaveEnabled": true, "annualLeaveDaysPerYear": 25,
            "annualLeaveCarriesOver": true, "annualLeaveYearStartMonth": 4, "annualLeaveYearEndMonth": 3,
        ]
        let holidays: [[String: Any]] = [[
            "userId": "TEST-ME", "startDayKey": "2025-04-17", "endDayKey": "2025-04-22", "timeSlot": "FULL DAY", "status": "approved",
        ]]
        let defaults: [String: Any] = ["daysPerYear": 25, "startMonth": 4, "endMonth": 3, "carriesOver": true]
        let without = try XCTUnwrap(CanonicalBusinessEngine.myProfileSummary(
            input(user: user, roster: [user], extra: ["holidays": holidays, "leaveDefaults": defaults])
        ))
        let with = try XCTUnwrap(CanonicalBusinessEngine.myProfileSummary(
            input(user: user, roster: [user], extra: [
                "holidays": holidays, "leaveDefaults": defaults, "nonWorkingDayKeys": ["2025-04-18", "2025-04-21"],
            ])
        ))
        XCTAssertEqual(without.leave.remaining, 46)
        XCTAssertEqual(with.leave.remaining, 48)
    }
}
