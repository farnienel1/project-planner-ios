import XCTest
@testable import Project_Planner

/// Owner 24 Nov (web #451): User Timesheets → Exported shows short dates in the organisation's zone, keeps each row's
/// versions collapsed until opened, and names the line manager with the rulebook's `lineManagerSummary` over every
/// users document (it read "Unknown" for a line manager stored under a second same-email document).
@MainActor
final class TimesheetListDisplayTests: XCTestCase {
    private let london = TimeZone(identifier: "Europe/London")!
    private let now = ISO8601DateFormatter().date(from: "2026-11-24T21:00:00Z")!

    private func date(_ iso: String) -> Date { ISO8601DateFormatter().date(from: iso)! }

    func testExportedStampLeavesTheCurrentYearOut() {
        XCTAssertEqual(TimesheetListDisplay.exportedStamp(date("2026-11-24T20:07:00Z"), timeZone: london, now: now), "24 Nov, 20:07")
        XCTAssertEqual(TimesheetListDisplay.exportedStamp(date("2025-11-24T20:07:00Z"), timeZone: london, now: now), "24 Nov 2025, 20:07")
        XCTAssertEqual(TimesheetListDisplay.exportedStamp(date("2026-07-01T23:30:00Z"), timeZone: london, now: now), "2 Jul, 00:30")
        XCTAssertEqual(TimesheetListDisplay.exportedStamp(date("2026-03-03T09:05:00Z"), timeZone: london, now: now), "3 Mar, 09:05")
    }

    func testCompactPayRunMatchesWeb() {
        XCTAssertEqual(TimesheetListDisplay.compactPayRun(start: date("2026-11-16T00:00:00Z"), end: date("2026-11-30T00:00:00Z"), timeZone: london), "16–30 Nov 2026")
        XCTAssertEqual(TimesheetListDisplay.compactPayRun(start: date("2026-10-26T00:00:00Z"), end: date("2026-11-25T00:00:00Z"), timeZone: london), "26 Oct – 25 Nov 2026")
        XCTAssertEqual(TimesheetListDisplay.compactPayRun(start: date("2025-12-29T00:00:00Z"), end: date("2026-01-04T00:00:00Z"), timeZone: london), "29 Dec 2025 – 4 Jan 2026")
        // 1 Jun 2026 00:00 BST is 31 May 23:00 UTC.
        XCTAssertEqual(TimesheetListDisplay.compactPayRun(start: date("2026-05-31T23:00:00Z"), end: date("2026-06-14T23:00:00Z"), timeZone: london), "1–15 Jun 2026")
    }

    func testVersionsStartCollapsedAndToggleOneRow() {
        let opened = TimesheetListDisplay.toggled([], rowId: "a")
        XCTAssertEqual(opened, ["a"])
        XCTAssertEqual(TimesheetListDisplay.toggled(opened, rowId: "b"), ["a", "b"])
        XCTAssertEqual(TimesheetListDisplay.toggled(opened, rowId: "a"), [])
    }

    private func person(_ id: String, email: String, first: String, passwordSet: Bool = true, managers: [String] = []) -> AppUser {
        AppUser(
            id: id,
            email: email,
            organizationId: "org-a",
            role: .manager,
            firstName: first,
            surname: "Test",
            isActive: true,
            passwordSet: passwordSet,
            permissions: UserPermissions(manager: true),
            assignedManagerUserId: managers.first,
            assignedManagerUserIds: managers
        )
    }

    func testLineManagerStoredUnderAFoldedAwayDocumentIsNamed() {
        let live = person("MGR-LIVE", email: "jo@example.com", first: "Jo")
        let stale = person("MGR-OLD", email: "JO@example.com", first: "Stale", passwordSet: false)
        let luke = person("LUKE", email: "luke@example.com", first: "Luke", managers: ["MGR-OLD"])
        let cache = LineManagerLabelCache()
        XCTAssertEqual(cache.label(for: luke, roster: [live, stale, luke]), "Jo Test", "the live document names the person")
    }

    func testLineManagerWordsAreTheRulebooks() {
        let cache = LineManagerLabelCache()
        XCTAssertEqual(cache.label(for: person("A", email: "a@example.com", first: "A"), roster: []), "Not set")
        XCTAssertEqual(cache.label(for: person("B", email: "b@example.com", first: "B", managers: ["GONE"]), roster: []), "Unknown person")
        var none = person("C", email: "c@example.com", first: "C")
        none.hasNoLineManager = true
        XCTAssertEqual(cache.label(for: none, roster: []), "No line manager")
    }

    func testCacheResetsWhenTheRosterChanges() {
        let cache = LineManagerLabelCache()
        let op = person("OP", email: "op@example.com", first: "Op", managers: ["M1"])
        XCTAssertEqual(cache.label(for: op, roster: [op]), "Unknown person")
        let manager = person("M1", email: "m1@example.com", first: "Mia")
        XCTAssertEqual(cache.label(for: op, roster: [op, manager]), "Mia Test")
    }
}

@MainActor
final class TimesheetWhoseTurnNameTests: XCTestCase {
    private func person(_ id: String, email: String, first: String, passwordSet: Bool = true, managers: [String] = []) -> AppUser {
        AppUser(
            id: id,
            email: email,
            organizationId: "org-a",
            role: .manager,
            firstName: first,
            surname: "Test",
            isActive: true,
            passwordSet: passwordSet,
            permissions: UserPermissions(manager: true),
            assignedManagerUserId: managers.first,
            assignedManagerUserIds: managers
        )
    }

    /// Over the unfolded roster the whose-turn line names the live document, never the email (web `soleLineManagerName`).
    func testWhoseTurnNamesTheLineManagerStoredUnderAFoldedAwayDocument() {
        let live = person("MGR-LIVE", email: "jo@example.com", first: "Jo")
        let stale = person("MGR-OLD", email: "JO@example.com", first: "Stale", passwordSet: false)
        let luke = person("LUKE", email: "luke@example.com", first: "Luke", managers: ["MGR-OLD"])
        XCTAssertEqual(TimesheetClarityNames.lineManagerName(for: luke, roster: [live, stale, luke]), "Jo Test")
        XCTAssertNil(TimesheetClarityNames.lineManagerName(for: luke, roster: [live, luke]), "the folded roster alone cannot name them")
    }
}
