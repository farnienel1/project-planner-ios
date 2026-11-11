import XCTest
@testable import Project_Planner

/// Owner 11 Nov, display only: "Away today" on the Team header, and the annual leave calendar legends wrap by whole
/// item (`PPWrapLayout`), never mid-word.
final class AnnualLeaveLabelsLayoutTests: XCTestCase {
    private var root: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    }

    private func source(_ path: String) throws -> String {
        try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }

    func testTeamHeaderSaysAwayTodayCapitalised() throws {
        let view = try source("Project Planner/Views/HolidayView.swift")
        XCTAssertTrue(view.contains("Text(\"Away today\")"))
        XCTAssertFalse(view.contains("Text(\"away today\")"))
    }

    func testLegendsWrapByWholeItem() throws {
        let dashboard = try source("Project Planner/Views/AnnualLeaveDashboardUI.swift")
        let legend = try XCTUnwrap(dashboard.range(of: "struct AnnualLeaveLegend: View {"))
        XCTAssertTrue(dashboard[legend.upperBound...].prefix(400).contains("PPWrapLayout(spacing: 10)"))
        let operative = try source("Project Planner/Views/OperativeAnnualLeaveViews.swift")
        let row = try XCTUnwrap(operative.range(of: "private var legendRow: some View {"))
        XCTAssertTrue(operative[row.upperBound...].prefix(300).contains("PPWrapLayout(spacing: 12)"))
    }
}
