import XCTest
@testable import Project_Planner

/// RULEBOOK 1.62.0 §8: the Awaiting sign-off queue and its landing count come from the rulebook's `userTimesheetQueue`
/// (the rule web's User Timesheets list and hub tile use). The shared scenario itself is in `CanonicalParityFixture.json`
/// (run by `CanonicalParityFixtureTests`); these check the Swift side builds an input the rule reads the same way.
@MainActor
final class UserTimesheetQueueRulebookTests: XCTestCase {
    private func admin() -> AppUser {
        var user = AppUser(
            id: "ADMIN-1",
            email: "admin@example.test",
            organizationId: "org-test",
            role: .admin,
            firstName: "Ada",
            surname: "Admin",
            passwordSet: true,
            permissions: UserPermissions(adminAccess: true, manager: true),
            employmentType: .selfEmployed
        )
        user.hasNoLineManager = true
        return user
    }

    private func worker(_ id: String, email: String = "worker@example.test", employment: EmploymentType = .selfEmployed) -> AppUser {
        var user = AppUser(
            id: id,
            email: email,
            organizationId: "org-test",
            role: .operative,
            firstName: "Will",
            surname: "Worker",
            passwordSet: true,
            permissions: UserPermissions(operativeMode: true),
            employmentType: employment
        )
        user.setLineManagerUserIds(["ADMIN-1"])
        return user
    }

    private let awaitingData: [String: Any] = [
        "operativeSignedAt": 1_792_000_000_000.0,
        "operativeSignedByName": "Will Worker",
    ]

    private func rows(roster: [AppUser], sheets: [[String: Any]]) -> [[String: Any]]? {
        var input = UserTimesheetQueueRulebook.payload(viewer: admin(), roster: roster, sheets: [], settings: .default)
        input["sheets"] = sheets
        return CanonicalBusinessEngine.objectRows(function: UserTimesheetQueueRulebook.functionName, payload: input)
    }

    func testTheScriptExportsTheQueue() {
        XCTAssertTrue(UserTimesheetQueueRulebook.isAvailable)
    }

    /// A person with two users documents on one email is one row per pay run (iOS counted them twice before 1.62.0).
    func testTwoRecordsOfOnePersonAreOneRow() throws {
        let roster = [admin(), worker("W-1"), worker("w-1b", email: "Worker@Example.test")]
        let sheet: (String) -> [String: Any] = { id in
            ["userId": id, "startDayKey": "2026-04-01", "endDayKey": "2026-04-15", "data": self.awaitingData,
             "documentId": "timesheet_\(id)_1775001600", "hasActivity": true]
        }
        let result = try XCTUnwrap(rows(roster: roster, sheets: [sheet("W-1"), sheet("w-1b")]))
        XCTAssertEqual(result.filter { ($0["bucket"] as? String) == "awaiting" }.count, 1)
    }

    /// A pay run in which the person was PAYE on every day has no sheet: never awaiting.
    func testPayeRunIsLeftOut() throws {
        let roster = [admin(), worker("P-1", email: "paye@example.test", employment: .paye)]
        let sheets: [[String: Any]] = [
            ["userId": "P-1", "startDayKey": "2026-04-01", "endDayKey": "2026-04-15", "data": awaitingData,
             "documentId": "timesheet_P-1_1775001600", "hasActivity": true],
        ]
        let result = try XCTUnwrap(rows(roster: roster, sheets: sheets))
        XCTAssertTrue(result.isEmpty)
    }

    /// A sheet a year old still waits (no recent-run window), and the viewer's own sheet never does.
    func testOldSheetListedOwnSheetNot() throws {
        let roster = [admin(), worker("W-1")]
        let sheets: [[String: Any]] = [
            ["userId": "W-1", "startDayKey": "2025-11-01", "endDayKey": "2025-11-15", "data": awaitingData,
             "documentId": "timesheet_W-1_1761955200", "hasActivity": true],
            ["userId": "ADMIN-1", "startDayKey": "2026-11-01", "endDayKey": "2026-11-15", "data": awaitingData,
             "documentId": "timesheet_ADMIN-1_1793491200", "hasActivity": true],
        ]
        let result = try XCTUnwrap(rows(roster: roster, sheets: sheets))
        XCTAssertEqual(result.compactMap { $0["personId"] as? String }, ["W-1"])
        XCTAssertEqual(result.first?["bucket"] as? String, "awaiting")
    }

    func testIdsOfAPersonIncludeFormerAndSameEmailIds() {
        var user = worker("W-1")
        user.formerUserIds = ["old-invite"]
        user.sameEmailUserIds = ["w-1b", "W-1"]
        XCTAssertEqual(UserTimesheetQueueRulebook.ids(of: user), ["W-1", "old-invite", "w-1b"])
    }
}
