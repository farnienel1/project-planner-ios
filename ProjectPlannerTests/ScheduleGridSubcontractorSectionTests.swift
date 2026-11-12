import XCTest
@testable import Project_Planner

/// Owner 11 Nov: the Scheduling week grid shows the Subcontractors section only on a week with a subcontractor booked;
/// with none, no section and no "No subcontractors booked this week" row. Display only (guardrail 7).
@MainActor
final class ScheduleGridSubcontractorSectionTests: XCTestCase {
    func testNoSectionWhenNoSubcontractorIsBooked() {
        let rows = ScheduleWeekGrid.subcontractorRows(ids: []) { _ in "TEST-Firm" }
        XCTAssertFalse(ScheduleWeekGrid.showsSubcontractorSection(rows))
    }

    func testSectionShownWhenASubcontractorIsBooked() {
        let rows = ScheduleWeekGrid.subcontractorRows(ids: [UUID()]) { _ in "TEST-Firm" }
        XCTAssertTrue(ScheduleWeekGrid.showsSubcontractorSection(rows))
        XCTAssertEqual(rows.map(\.role), [.subcontractor])
    }

    /// The empty placeholder and its Book button are gone from the grid; "Book a sub" stays at the top.
    func testThePlaceholderRowIsGone() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let view = try String(contentsOf: root.appendingPathComponent("Project Planner/Views/ProjectDetailView.swift"), encoding: .utf8)
        XCTAssertFalse(view.contains("No subcontractors booked this week"))
        XCTAssertTrue(view.contains("ScheduleWeekGrid.showsSubcontractorSection("))
        XCTAssertTrue(view.contains("title: \"Book a sub\""))
    }
}
