import XCTest
@testable import Project_Planner

/// `ios-timesheet-lookups` (guardrails 1 and 3, web `w-timesheet-lookups`): a person's timesheets under every id they go
/// by, deleted people's exported sheets for admins, and people with no level flag on an admin's lists — through
/// `CanonicalBusinessEngine` (`personIdSet`, `timesheetDocumentSubjectId`, `bookingPersonIdHint`,
/// `exportedTimesheetHistorySubjects`, `userTimesheetSubjects`, `rosterListKind`). Real old document shapes: a sheet
/// under a former invite id (upper case, as iOS writes), a second users document on the same email, a sheet stored
/// without `userId`, a deleted person's sheet. Each test also checks nothing previously shown disappears.
@MainActor
final class PersonTimesheetLookupTests: XCTestCase {
    private let org = "TEST-ORG-LOOKUPS"

    private func user(
        _ id: String,
        role: UserRole,
        admin: Bool = false,
        manager: Bool = false,
        operative: Bool = false,
        email: String? = nil,
        formerIds: [String] = []
    ) -> AppUser {
        var person = AppUser(
            id: id,
            email: email ?? "\(id.lowercased())@example.test",
            organizationId: org,
            role: role,
            firstName: "TEST-\(id)",
            surname: "Person",
            isActive: true,
            passwordSet: true,
            permissions: UserPermissions(adminAccess: admin, manager: manager || admin, operativeMode: operative)
        )
        person.formerUserIds = formerIds
        return person
    }

    private var farnie: AppUser { user("U1", role: .operative, operative: true, email: "farnie@example.test", formerIds: ["INVITE-1"]) }
    private var farnieCopy: AppUser { user("U1B", role: .operative, operative: true, email: "Farnie@example.test") }
    private var other: AppUser { user("U2", role: .operative, operative: true) }
    private var roster: [AppUser] { [farnie, farnieCopy, other] }

    private func sheet(_ userId: String?, _ weekStartKey: String) -> [String: Any] {
        var data: [String: Any] = ["weekStartKey": weekStartKey]
        if let userId { data["userId"] = userId }
        return data
    }

    private var documents: [(documentId: String, data: [String: Any])] {
        [
            ("timesheet_U1_1761955200", sheet("U1", "2026-11-01")),
            ("timesheet_INVITE-1_1759276800", sheet("INVITE-1", "2026-10-01")), // former invite id
            ("timesheet_U1B_1760486400", sheet("U1B", "2026-10-15")), // same-email second account
            ("timesheet_invite-1_1756684800", sheet(nil, "2026-09-01")), // no userId, id names the former id
            ("timesheet_U1_1754006400", sheet(nil, "2026-08-01")), // no userId, id names the own id
            ("timesheet_U2_1761955200", sheet("U2", "2026-11-01")), // someone else's
            ("timesheet_U1_1751328000", sheet("U2", "2026-07-01")), // id names Farnie, stored userId says U2
            ("variations_J1", ["userId": "U1"]), // not a timesheet
        ]
    }

    func testOwnerIdsAreThePersonIdSet() {
        let ids = RulebookPeople.ownerIds(for: farnie, users: roster).map { $0.lowercased() }
        XCTAssertEqual(ids.first, "u1")
        XCTAssertTrue(ids.contains("invite-1"))
        XCTAssertTrue(ids.contains("u1b"))
        XCTAssertFalse(ids.contains("u2"))
    }

    func testDocumentOwnerIdReadsTheStoredUserIdFirst() {
        XCTAssertEqual(PersonTimesheetLookup.documentOwnerId(documentId: "timesheet_U1_1751328000", data: ["userId": "U2"]), "U2")
        XCTAssertEqual(
            PersonTimesheetLookup.documentOwnerId(documentId: "timesheet_invite-1_1756684800", data: [:]).lowercased(),
            "invite-1",
            "a sheet stored without userId belongs to the id its document id names (timesheetDocumentSubjectId)"
        )
    }

    func testEverySheetOfThePersonAndNobodyElses() {
        let ids = RulebookPeople.ownerIds(for: farnie, users: roster)
        let kept = PersonTimesheetLookup.documentsForPerson(ids: ids, documents: documents).map(\.documentId).sorted()
        XCTAssertEqual(kept, [
            "timesheet_INVITE-1_1759276800",
            "timesheet_U1B_1760486400",
            "timesheet_U1_1754006400",
            "timesheet_U1_1761955200",
            "timesheet_invite-1_1756684800",
        ].sorted())
        // Before: only `userId == U1`. Everything that read showed is still there.
        let before = documents.filter { $0.documentId.hasPrefix("timesheet_") && ($0.data["userId"] as? String) == "U1" }
        for entry in before { XCTAssertTrue(kept.contains(entry.documentId), "\(entry.documentId) dropped") }
    }

    func testAliasIdsAreAskedInChunksOfTen() {
        let ids = ["own"] + (0..<23).map { "alias\($0)" }
        XCTAssertEqual(PersonTimesheetLookup.aliasChunks(ids).map(\.count), [10, 10, 3])
        XCTAssertEqual(PersonTimesheetLookup.aliasChunks(["own", "OWN"]).count, 0, "ids compare without case")
    }

    func testAnExactIdWinsOverAnAlias() {
        let idsOf: (AppUser) -> [String] = { RulebookPeople.ownerIds(for: $0, users: self.roster) }
        let ownerOf = PersonTimesheetLookup.ownerResolver(candidates: roster, idsOf: idsOf)
        XCTAssertEqual(ownerOf("U1B")?.id, "U1B", "the second account keeps its own sheets")
        XCTAssertEqual(ownerOf("invite-1")?.id, "U1", "a former invite id belongs to the person, in any letter case")
        XCTAssertNil(ownerOf("GONE-PERSON"))
    }

    func testADeletedPersonIsAnUnknownPersonNotADroppedRow() {
        let stand = PersonTimesheetLookup.unresolvedPerson(storedUserId: "6A9632BA-0000-4000-8000-000000000000", organizationId: org)
        XCTAssertEqual(stand.id, "6A9632BA-0000-4000-8000-000000000000")
        XCTAssertEqual(stand.firstName, CanonicalBusinessEngine.unknownBookingPersonLabel)
        XCTAssertTrue(stand.surname.hasPrefix("· "))
        XCTAssertFalse(stand.isActive)
    }

    func testPeopleWithNoLevelFlagAreOnAnAdminsTimesheetLists() throws {
        let admin = user("ADMIN", role: .admin, admin: true)
        let operative = user("OP", role: .operative, operative: true)
        let flagless = user("LEGACY", role: .basic)
        let members = [admin, operative, flagless]
        let exported = try XCTUnwrap(UserTimesheetAccessRulebook.exportedHistoryUserIds(viewer: admin, members: members))
        XCTAssertTrue(exported.contains("LEGACY"), "manager level (RULEBOOK §11, 1.23.1)")
        XCTAssertTrue(exported.contains("OP") && exported.contains("ADMIN"), "nothing previously listed drops out")
        let subjects = try XCTUnwrap(UserTimesheetAccessRulebook.subjectUserIds(viewer: admin, members: members))
        XCTAssertTrue(subjects.contains("LEGACY"))
        XCTAssertTrue(subjects.contains("OP"))
    }
}
