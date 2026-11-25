import XCTest
@testable import Project_Planner

/// RULEBOOK 1.94.0 §23 "How a deadline reads" through `CanonicalBusinessEngine`. Expected values checked in node
/// against the packed `canonical-business.js` (rulebook 1.94.0) with the JSON these wrappers send.
@MainActor
final class DeadlineDisplayRulebookTests: XCTestCase {
    private let london = "Europe/London"

    private func instant(_ iso: String) throws -> Date {
        try XCTUnwrap(ISO8601DateFormatter().date(from: iso))
    }

    func testDisplayTabsSummaryAndMovedNote() throws {
        let now = try instant("2026-11-25T12:00:00Z")
        let behind = RulebookDeadlineDisplayInput(status: "inProgress", progress: 0.25, due: try instant("2026-11-27T12:00:00Z"),
                                                  start: try instant("2026-11-01T12:00:00Z"), title: "Fit-out")
        let late = RulebookDeadlineDisplayInput(status: "complete", progress: 1, due: try instant("2026-11-20T12:00:00Z"),
                                                completedAt: try instant("2026-11-23T12:00:00Z"), title: "Done")
        let overdue = RulebookDeadlineDisplayInput(status: "notStarted", progress: 0, due: try instant("2026-11-22T12:00:00Z"), title: "Late")

        let a = try XCTUnwrap(CanonicalBusinessEngine.deadlineDisplay(behind, now: now, timeZone: london))
        XCTAssertEqual(a.status, "behindPace")
        XCTAssertEqual(a.tone, "amber")
        XCTAssertEqual(a.group, "thisWeek")
        XCTAssertEqual(a.dueText, "Due in 2 days")
        XCTAssertEqual(a.pill, "2d")
        XCTAssertEqual(a.paceText, "25% · expected 92%")

        let b = try XCTUnwrap(CanonicalBusinessEngine.deadlineDisplay(late, now: now, timeZone: london))
        XCTAssertEqual(b.group, "completed")
        XCTAssertEqual(b.dueText, "Done 3 days late")
        XCTAssertEqual(b.progressPercent, 100)

        let c = try XCTUnwrap(CanonicalBusinessEngine.deadlineDisplay(overdue, now: now, timeZone: london))
        XCTAssertEqual(c.tone, "red")
        XCTAssertEqual(c.pill, "+3d")

        let counts = try XCTUnwrap(CanonicalBusinessEngine.deadlineTabCounts([behind, late, overdue], now: now, timeZone: london))
        XCTAssertEqual(counts, ["all": 3, "overdue": 1, "thisWeek": 1, "behindPace": 1, "completed": 1])
        XCTAssertEqual(CanonicalBusinessEngine.deadlineSummaryLine([behind, late, overdue], now: now, timeZone: london),
                       "1 of 3 complete · 0 on time · Next: Late, Sun 22 Nov")
        XCTAssertEqual(CanonicalBusinessEngine.deadlineMovedNote(from: try instant("2026-11-27T12:00:00Z"),
                                                                 to: try instant("2026-11-28T12:00:00Z"), timeZone: london),
                       "Moved 1 day from 27 Nov")
        XCTAssertEqual(CanonicalBusinessEngine.deadlineTabs()?.map(\.label), ["All", "Overdue", "This week", "Behind pace", "Completed"])
        XCTAssertEqual(DLFilter.allCases.map(\.rawValue), CanonicalBusinessEngine.deadlineTabs()?.map(\.key))
    }
}
