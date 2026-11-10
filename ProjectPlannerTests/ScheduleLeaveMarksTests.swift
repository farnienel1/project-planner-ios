import XCTest
@testable import Project_Planner

/// RULEBOOK 1.37.0 §21 (owner decisions 10 Nov): annual leave on a job's Scheduling week comes from the packed
/// script's `jobScheduleLeaveMarks`, never from a Swift match. Before 1.37.0 the grid matched leave by exact id
/// (`HolidayStore.approvedBookings(covering:)`), showed approved full days only, and never marked a booked day.
@MainActor
final class ScheduleLeaveMarksTests: XCTestCase {
    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    }

    private func day(_ year: Int, _ month: Int, _ day: Int) throws -> Date {
        try XCTUnwrap(OrganizationRulebookContext.calendar.date(from: DateComponents(year: year, month: month, day: day)))
    }

    private func leave(
        _ userId: String,
        _ date: Date,
        status: HolidayStatus = .approved,
        slot: HolidayTimeSlot = .fullDay
    ) -> HolidayBooking {
        HolidayBooking(organizationId: "org-test", userId: userId, startDate: date, endDate: date, status: status, timeSlot: slot)
    }

    func testMarksFullHalfPendingAndNeverRejectedUnderEveryIdWithoutCase() throws {
        let mon = try day(2026, 11, 23)
        let tue = try day(2026, 11, 24)
        let wed = try day(2026, 11, 25)
        let thu = try day(2026, 11, 26)
        let input = ScheduleLeaveMarksInput.build(
            people: [ScheduleLeaveMarksInput.Person(key: "row-a", operativeIds: [], userIds: ["user-a"])],
            days: [mon, tue, wed, thu],
            holidays: [
                leave("USER-A", mon),
                leave("user-a", tue, status: .pending, slot: .morning),
                leave("user-a", wed, status: .rejected),
                leave("someone-else", thu),
            ],
            users: [],
            operatives: []
        )
        let marks = try XCTUnwrap(CanonicalBusinessEngine.jobScheduleLeaveMarks(input)?["row-a"], "the script answered")
        XCTAssertEqual(marks.count, 4)
        XCTAssertEqual(marks[0]?.label, "AL")
        XCTAssertEqual(marks[0]?.pending, false)
        XCTAssertEqual(marks[1]?.label, "AL? AM")
        XCTAssertEqual(marks[1]?.pending, true)
        XCTAssertEqual(marks[1]?.isHalfDay, true)
        XCTAssertNil(marks[2], "rejected leave never shows")
        XCTAssertNil(marks[3], "another person's leave never marks this row")
    }

    func testOnlyPeopleGivenComeBackLeaveNeverAddsARow() throws {
        let mon = try day(2026, 11, 23)
        let input = ScheduleLeaveMarksInput.build(
            people: [ScheduleLeaveMarksInput.Person(key: "row-a", operativeIds: [], userIds: ["user-a"])],
            days: [mon],
            holidays: [leave("user-b", mon)],
            users: [],
            operatives: []
        )
        let answer = try XCTUnwrap(CanonicalBusinessEngine.jobScheduleLeaveMarks(input))
        XCTAssertEqual(Array(answer.keys), ["row-a"])
        XCTAssertNil(answer["row-a"]?.first ?? nil)
    }

    /// Review #211 (1): leave an older iOS build stored under the account's email matches the person's grid row,
    /// though the row passes only ids — the rulebook adds the emails of the person's roster rows itself.
    func testLeaveStoredUnderTheEmailMatchesWithoutPassingTheEmail() throws {
        let mon = try day(2026, 11, 23)
        let user = LogicFixtures.selfEmployedUser(id: "user-a", email: "ann@example.com")
        let input = ScheduleLeaveMarksInput.build(
            people: [ScheduleLeaveMarksInput.Person(key: "row-a", operativeIds: [], userIds: ["user-a"])],
            days: [mon],
            holidays: [leave("Ann@Example.com", mon)],
            users: [user],
            operatives: []
        )
        let marks = try XCTUnwrap(CanonicalBusinessEngine.jobScheduleLeaveMarks(input)?["row-a"])
        XCTAssertEqual(marks.first??.label, "AL")
    }

    /// Review #211 (6): AM and PM approved on one day are the whole day.
    func testAmAndPmOnOneDayAreAFullDay() throws {
        let mon = try day(2026, 11, 23)
        let input = ScheduleLeaveMarksInput.build(
            people: [ScheduleLeaveMarksInput.Person(key: "row-a", operativeIds: [], userIds: ["user-a"])],
            days: [mon],
            holidays: [leave("user-a", mon, slot: .morning), leave("user-a", mon, slot: .afternoon)],
            users: [],
            operatives: []
        )
        let mark = try XCTUnwrap(CanonicalBusinessEngine.jobScheduleLeaveMarks(input)?["row-a"]?.first ?? nil)
        XCTAssertEqual(mark.label, "AL")
        XCTAssertFalse(mark.isHalfDay)
    }

    /// Re-review (2): one approved half and one pending half are both shaded, each in its own style, and the mark's
    /// record is the approved half's.
    func testMixedHalvesShadeBothWithTheApprovedRecord() throws {
        let mon = try day(2026, 11, 23)
        let am = HolidayBooking(documentId: "am-rec", organizationId: "org-test", userId: "user-a", startDate: mon, endDate: mon, status: .approved, timeSlot: .morning)
        let pm = HolidayBooking(documentId: "pm-rec", organizationId: "org-test", userId: "user-a", startDate: mon, endDate: mon, status: .pending, timeSlot: .afternoon)
        let input = ScheduleLeaveMarksInput.build(
            people: [ScheduleLeaveMarksInput.Person(key: "row-a", operativeIds: [], userIds: ["user-a"])],
            days: [mon],
            holidays: [am, pm],
            users: [],
            operatives: []
        )
        let mark = try XCTUnwrap(CanonicalBusinessEngine.jobScheduleLeaveMarks(input)?["row-a"]?.first ?? nil)
        XCTAssertEqual(mark.label, "AL AM · AL? PM")
        XCTAssertEqual(mark.am, "approved")
        XCTAssertEqual(mark.pm, "pending")
        XCTAssertEqual(mark.recordId, "am-rec")
        XCTAssertTrue(mark.isHalfDay)
    }

    /// Re-review (3): a 0h AM booking is a Half day 0h chip — the shared rule's figure, the same web asserts in
    /// `canonical.test.ts` (`scheduleCellKind({ paidHours: 0, timeSlot: 'AM' })`).
    func testZeroHourHalfDayChipMatchesWeb() {
        XCTAssertEqual(SchedulingV2CellKindBuilder.fromBooking(paidHours: 0, overtimeHours: 0, timeSlot: .morning), .halfDay(hours: 0, label: "AM"))
    }

    /// Review #211 (3): the chip colour is the rulebook's `scheduleCellKind`; a 0h booking is a Standard 0h chip.
    func testChipColourComesFromTheRulebookAndZeroHoursIsNeverHidden() {
        XCTAssertEqual(SchedulingV2CellKindBuilder.fromBooking(paidHours: 8.5, overtimeHours: 0, timeSlot: .fullDay), .standard(hours: 8.5))
        XCTAssertEqual(SchedulingV2CellKindBuilder.fromBooking(paidHours: 11.875, overtimeHours: 3.375, timeSlot: .customHours), .split(stdHours: 8.5, otHours: 3.38))
        XCTAssertEqual(SchedulingV2CellKindBuilder.fromBooking(paidHours: 4.5, overtimeHours: 4.5, timeSlot: .customHours), .overtimeOnly(hours: 4.5))
        XCTAssertEqual(SchedulingV2CellKindBuilder.fromBooking(paidHours: 4, overtimeHours: 0, timeSlot: .morning), .halfDay(hours: 4, label: "AM"))
        XCTAssertEqual(SchedulingV2CellKindBuilder.fromBooking(paidHours: 0, overtimeHours: 0, timeSlot: .customHours), .standard(hours: 0))
    }

    /// Review follow-up: no leave is marked until the bank holidays have loaded (as web), so a multi-day request never
    /// shows "AL" on a bank holiday for a moment.
    func testNoLeaveMarksUntilBankHolidaysHaveLoaded() {
        var asked = false
        let before = ScheduleLeaveMarksGate.marks(bankHolidaysReady: false) {
            asked = true
            return ["row-a": [nil]]
        }
        XCTAssertTrue(before.isEmpty)
        XCTAssertFalse(asked, "the script is not asked before the bank holidays load")
        let after = ScheduleLeaveMarksGate.marks(bankHolidaysReady: true) { ["row-a": [nil]] }
        XCTAssertEqual(after.keys.sorted(), ["row-a"])
    }

    func testSchedulingGridWaitsForBankHolidays() throws {
        let text = try String(contentsOf: repoRoot.appendingPathComponent("Project Planner/Views/ProjectDetailView.swift"), encoding: .utf8)
        XCTAssertTrue(text.contains("ScheduleLeaveMarksGate.marks(bankHolidaysReady: scheduleBankHolidaysReady)"))
        XCTAssertTrue(text.contains("BankHolidayService.shared.ensureLoaded(region: region, referenceDate: week)"))
        XCTAssertTrue(text.contains("ScheduleLeaveMarksGate.waitForBankHolidays(setReady:"))
        XCTAssertTrue(text.contains(".task(id: OrganizationRulebookContext.dayKey(weekStartDate))"))
    }

    /// Final review (1): each new week starts not ready and is ready once its load finishes.
    func testEachWeekWaitsForItsOwnLoad() async {
        let log = ReadyLog()
        await ScheduleLeaveMarksGate.waitForBankHolidays(capSeconds: 10, setReady: { log.values.append($0) }) {}
        XCTAssertEqual(log.values, [false, true])
    }

    /// Final review (2): a slow load is capped — the marks show (with the cached bank holidays) after the cap, and
    /// again when the load finishes.
    func testASlowLoadIsCapped() async {
        let log = ReadyLog()
        await ScheduleLeaveMarksGate.waitForBankHolidays(capSeconds: 0.05, setReady: { log.values.append($0) }) {
            try? await Task.sleep(nanoseconds: 400_000_000)
            XCTAssertEqual(log.values, [false, true], "ready after the cap, before the load finished")
        }
        XCTAssertEqual(log.values, [false, true, true])
        XCTAssertEqual(ScheduleLeaveMarksGate.bankHolidayWaitCapSeconds, 10)
    }

    /// A week left before its load finished never marks the next week ready.
    func testALeftWeekNeverMarksReady() async {
        let log = ReadyLog()
        let task = Task { @MainActor in
            await ScheduleLeaveMarksGate.waitForBankHolidays(capSeconds: 0.2, setReady: { log.values.append($0) }) {
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
        }
        task.cancel()
        await task.value
        try? await Task.sleep(nanoseconds: 400_000_000)
        XCTAssertFalse(log.values.contains(true), "a cancelled week never sets ready")
    }

    /// The grid asks the rulebook; the exact-id Swift match is gone.
    func testSchedulingGridUsesTheRulebookForLeave() throws {
        let text = try String(contentsOf: repoRoot.appendingPathComponent("Project Planner/Views/ProjectDetailView.swift"), encoding: .utf8)
        XCTAssertTrue(text.contains("CanonicalBusinessEngine.jobScheduleLeaveMarks"))
        XCTAssertFalse(text.contains("isPersonOnAnnualLeave"))
        XCTAssertFalse(text.contains("approvedBookings(covering"))
        XCTAssertEqual(text.components(separatedBy: "CanonicalBusinessEngine.jobScheduleLeaveMarks(").count - 1, 1, "one call per grid render")
        let support = try String(contentsOf: repoRoot.appendingPathComponent("Project Planner/Views/ProjectSchedulingV2Support.swift"), encoding: .utf8)
        for label in ["\"Standard\"", "\"Std + OT\"", "\"OT only\"", "\"Ann. leave\"", "\"Half day\""] {
            XCTAssertTrue(support.contains("legendItem(\(label))"), "legend keeps \(label) (JOB_SCHEDULE_LEGEND)")
        }
    }
}

/// Records the ready flags a bank-holiday wait sets (main actor, so the closures may share it).
@MainActor
private final class ReadyLog {
    var values: [Bool] = []
}
