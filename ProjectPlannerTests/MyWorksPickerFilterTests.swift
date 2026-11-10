import XCTest
@testable import Project_Planner

/// Owner request 10 Nov: the My Projects / My Small works ⚙ picker filters its rows by All / Active / Upcoming /
/// Completed. The tab is the rulebook's (`worksInTab`, `worksTabCounts`, §21) in the organisation zone; the expected
/// values follow the 1.21.0 parity cases (an inactive job is under Completed; All keeps every row in order).
@MainActor
final class MyWorksPickerFilterTests: XCTestCase {
    private let london = "Europe/London"

    private func job(_ id: String, _ data: [String: Any]) throws -> Project {
        try XCTUnwrap(FirebaseBackend.jobs(fromDocuments: [(id: id, data: data)], smallWorks: false).first)
    }

    private func jobs() throws -> [Project] {
        [
            try job("P-OFF", ["jobNumber": "J-100", "siteName": "Old Mill", "isLive": false, "startDate": "2026-11-01", "endDate": "2026-11-30"]),
            try job("P-LIVE", ["jobNumber": "J-200", "siteName": "High Street", "startDate": "2026-11-01", "endDate": "2026-11-30"]),
            try job("P-LATER", ["jobNumber": "J-300", "siteName": "High Barn", "startDate": "2026-12-01", "endDate": "2026-12-05"]),
            try job("P-DONE", ["jobNumber": "J-400", "siteName": "Quay", "startDate": "2026-10-01", "endDate": "2026-10-20"]),
        ]
    }

    private func now() throws -> Date {
        try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-11-03T12:00:00Z"))
    }

    private func shown(_ chip: ProjectStatus?, search: String = "") throws -> [String] {
        MyWorksPickerFilter.shownJobs(try jobs(), chip: chip, search: search, now: try now(), timeZone: london).map(\.documentId)
    }

    func testEachChipShowsTheRulebooksTab() throws {
        XCTAssertEqual(try shown(nil), ["P-OFF", "P-LIVE", "P-LATER", "P-DONE"], "All keeps every row in order")
        XCTAssertEqual(try shown(.active), ["P-LIVE"])
        XCTAssertEqual(try shown(.upcoming), ["P-LATER"])
        XCTAssertEqual(try shown(.completed), ["P-OFF", "P-DONE"], "an inactive job is under Completed")
    }

    func testSearchNarrowsWithinTheChip() throws {
        XCTAssertEqual(try shown(nil, search: "high"), ["P-LIVE", "P-LATER"])
        XCTAssertEqual(try shown(.upcoming, search: "  HIGH "), ["P-LATER"])
        XCTAssertEqual(try shown(.completed, search: "high"), [])
        XCTAssertEqual(try shown(.completed, search: "j-400"), ["P-DONE"])
    }

    func testChipTitlesAndCountsComeFromWorksTabCounts() throws {
        let counts = try XCTUnwrap(CanonicalBusinessEngine.worksTabCounts(try jobs(), now: try now(), timeZone: london))
        let status = WorksListStatusCounts(all: counts.all, active: counts.active, upcoming: counts.upcoming, completed: counts.completed)
        XCTAssertEqual(MyWorksPickerFilter.chips.map { MyWorksPickerFilter.title($0) }, ["All", "Active", "Upcoming", "Completed"])
        XCTAssertEqual(MyWorksPickerFilter.chips.map { MyWorksPickerFilter.count($0, in: status) }, [4, 1, 1, 2])
        XCTAssertNil(MyWorksPickerFilter.chips[0], "All is first and is the default")
    }

    func testTicksSurviveSwitchingChips() throws {
        // The ticks are the list `myWorksPicksAfterToggle` builds; the chip only narrows what is shown.
        var ids: [String] = []
        ids = CanonicalBusinessEngine.myWorksPicksAfterToggle(ids, jobId: "P-LIVE", picked: true)
        ids = CanonicalBusinessEngine.myWorksPicksAfterToggle(ids, jobId: "P-DONE", picked: true)
        XCTAssertFalse(try shown(.upcoming).contains("P-LIVE"), "hidden by the chip")
        XCTAssertEqual(ids, ["P-LIVE", "P-DONE"], "Save writes every tick, shown or not")
    }
}
