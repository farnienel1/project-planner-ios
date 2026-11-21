import XCTest
@testable import Project_Planner

/// RULEBOOK 1.66.0 §8: the Awaiting sign-off queue and its landing count come from the rulebook's `userTimesheetQueue`
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

    /// A person with two users documents on one email is one row per pay run (iOS counted them twice before 1.66.0).
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

    /// The ids come from the rulebook's `personIdSet` (as web `timesheetMemberIds`): own, former, stored same-email ids
    /// and every users document on the person's email.
    func testIdsOfAPersonComeFromPersonIdSet() {
        var user = worker("W-1")
        user.formerUserIds = ["old-invite"]
        let second = worker("w-1c", email: "WORKER@example.test")
        let ids = Set(UserTimesheetQueueRulebook.ids(of: user, roster: [admin(), user, second]).map { $0.lowercased() })
        XCTAssertTrue(ids.isSuperset(of: ["w-1", "old-invite", "w-1c"]))
    }

    /// UUID-shaped ids are also asked for in the other letter case (Firestore `in` is exact); other ids as stored.
    func testCaseVariantsOfUuidIdsOnly() {
        let upper = "6A9632BA-1111-4222-8333-444455556666"
        XCTAssertEqual(
            UserTimesheetQueueRulebook.withCaseVariants([upper, "Mixed-Auth-Uid"]),
            [upper, "Mixed-Auth-Uid", upper.lowercased()]
        )
    }

    /// RULEBOOK 1.66.0 §8: Signed off lists a signed, unexported sheet however old (as web), not only the current run.
    func testOldSignedSheetIsSignedOff() throws {
        let roster = [admin(), worker("W-1")]
        var signed = awaitingData
        signed["managerSignedAt"] = 1_792_100_000_000.0
        signed["managerSignedByName"] = "Ada Admin"
        let sheets: [[String: Any]] = [
            ["userId": "W-1", "startDayKey": "2025-11-01", "endDayKey": "2025-11-15", "data": signed,
             "documentId": "timesheet_W-1_1761955200"],
        ]
        let result = try XCTUnwrap(rows(roster: roster, sheets: sheets))
        XCTAssertEqual(result.first?["bucket"] as? String, "signed")
    }

    /// RULEBOOK 1.66.0 §8 `timesheetSheetHasActivity`: with no flag, the copy of a run with activity (here only a signed
    /// snapshot, as `payload` passes it) is picked over the empty copy stored first.
    func testActivityComesFromTheRule() throws {
        let roster = [admin(), worker("W-1"), worker("w-1b", email: "Worker@Example.test")]
        let sheets: [[String: Any]] = [
            ["userId": "w-1b", "startDayKey": "2026-08-01", "endDayKey": "2026-08-15", "data": [String: Any](),
             "documentId": "timesheet_w-1b_1785538800"],
            ["userId": "W-1", "startDayKey": "2026-08-01", "endDayKey": "2026-08-15",
             "data": ["weeklyReportOverride": [String: Any]()], "documentId": "timesheet_W-1_1785538800"],
        ]
        let result = try XCTUnwrap(rows(roster: roster, sheets: sheets))
        XCTAssertEqual(result.first?["documentId"] as? String, "timesheet_W-1_1785538800")
    }
}
