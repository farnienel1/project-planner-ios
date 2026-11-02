import XCTest
@testable import Project_Planner

/// The timesheet draft cache is one organisation's copy (§1): its keys carry the organisation id, and a
/// cleared period leaves nothing to show or save back.
@MainActor
final class TimesheetDraftCacheTests: XCTestCase {
    private let monday = LogicFixtures.day(2026, 10, 5, hour: 8)
    private let user = "TEST-cache-user"

    override func tearDown() {
        for org in ["TEST-org-a", "TEST-org-b"] {
            TimesheetDraftStore.clear(userId: user, weekStart: monday, organizationId: org)
        }
        super.tearDown()
    }

    func testKeysCarryTheOrganisationAndIgnoreItsCase() throws {
        let a = try XCTUnwrap(TimesheetDraftStore.key(userId: user, weekStart: monday, organizationId: "TEST-org-a"))
        let b = try XCTUnwrap(TimesheetDraftStore.key(userId: user, weekStart: monday, organizationId: "TEST-org-b"))
        XCTAssertNotEqual(a, b)
        XCTAssertEqual(a, TimesheetDraftStore.key(userId: user, weekStart: monday, organizationId: "TEST-ORG-A"))
        XCTAssertTrue(a.contains("test-org-a"))
    }

    func testAnotherCompanyNeverReadsTheDraft() {
        var draft = TimesheetDraft()
        draft.managerNote = "TEST-company A note"
        TimesheetDraftStore.save(draft, userId: user, weekStart: monday, organizationId: "TEST-org-a")
        XCTAssertEqual(TimesheetDraftStore.load(userId: user, weekStart: monday, organizationId: "TEST-org-a").managerNote, "TEST-company A note")
        XCTAssertEqual(TimesheetDraftStore.load(userId: user, weekStart: monday, organizationId: "TEST-org-b").managerNote, "")
    }

    func testClearingAPeriodRemovesTheLocalCopy() {
        var draft = TimesheetDraft()
        draft.managerNote = "TEST-stale"
        TimesheetDraftStore.save(draft, userId: user, weekStart: monday, weekEnd: monday, organizationId: "TEST-org-a")
        TimesheetDraftStore.clear(userId: user, weekStart: monday, organizationId: "TEST-org-a")
        XCTAssertEqual(TimesheetDraftStore.load(userId: user, weekStart: monday, organizationId: "TEST-org-a").managerNote, "")
        XCTAssertNil(TimesheetDraftStore.storedPeriodEnd(userId: user, weekStart: monday, organizationId: "TEST-org-a"))
    }
}
