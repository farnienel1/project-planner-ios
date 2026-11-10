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

    /// The grid asks the rulebook; the exact-id Swift match is gone.
    func testSchedulingGridUsesTheRulebookForLeave() throws {
        let text = try String(contentsOf: repoRoot.appendingPathComponent("Project Planner/Views/ProjectDetailView.swift"), encoding: .utf8)
        XCTAssertTrue(text.contains("CanonicalBusinessEngine.jobScheduleLeaveMarks"))
        XCTAssertFalse(text.contains("isPersonOnAnnualLeave"))
        XCTAssertFalse(text.contains("approvedBookings(covering"))
        let support = try String(contentsOf: repoRoot.appendingPathComponent("Project Planner/Views/ProjectSchedulingV2Support.swift"), encoding: .utf8)
        for label in ["\"Standard\"", "\"Std + OT\"", "\"OT only\"", "\"Ann. leave\"", "\"Half day\""] {
            XCTAssertTrue(support.contains("legendItem(\(label))"), "legend keeps \(label) (JOB_SCHEDULE_LEGEND)")
        }
    }
}
