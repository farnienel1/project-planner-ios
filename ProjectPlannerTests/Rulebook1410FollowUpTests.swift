import XCTest
@testable import Project_Planner

/// 1.41.0 follow-ups: (1) the signed-timesheet warning on Replace and Delete reads every timesheet of the booked
/// person, under every id they go by and sheets stored without `userId` (platform guardrail 1, as web
/// `signedTimesheetWarningForBookings`); (2) the Scheduling week keeps a row for a person who is only in the
/// unfolded users documents (`UserStore.bookingNameRoster`) and drops a truly unknown id (RULEBOOK 1.41.0 §21).
@MainActor
final class Rulebook1410FollowUpTests: XCTestCase {
    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    }

    private func source(_ path: String) throws -> String {
        try String(contentsOf: repoRoot.appendingPathComponent(path), encoding: .utf8)
    }

    // MARK: (1) Signed timesheets under every id

    private func sam() -> AppUser {
        var person = LogicFixtures.selfEmployedUser(id: "TEST-U-SAM", email: "sam@example.test")
        person.firstName = "Sam"
        person.surname = "Booker"
        person.formerUserIds = ["TEST-invite-sam"]
        person.isActive = true
        person.passwordSet = true
        return person
    }

    func testABookingUnderAnOperativesRowAsksForEveryIdThePersonGoesBy() {
        let row = CanonicalBusinessEngine.CanonicalBookingPersonOperative(id: "TEST-OP-ROW", email: "SAM@example.test")
        let ids = SignedTimesheetPeople.timesheetUserIds(personId: "TEST-OP-ROW", users: [sam()], operatives: [row])
        XCTAssertTrue(ids.contains("TEST-U-SAM"), "the account on the row's email")
        XCTAssertTrue(ids.contains("TEST-invite-sam"), "a sheet filed under the former invite id is read too")
        XCTAssertTrue(ids.contains("TEST-OP-ROW"), "the stored id is kept")
    }

    func testAFormerIdAndAnotherLetterCaseResolveToThePerson() {
        XCTAssertTrue(SignedTimesheetPeople.timesheetUserIds(personId: "TEST-invite-sam", users: [sam()], operatives: []).contains("TEST-U-SAM"))
        XCTAssertTrue(SignedTimesheetPeople.timesheetUserIds(personId: "test-u-sam", users: [sam()], operatives: []).contains("TEST-invite-sam"))
    }

    func testNobodyOnTheRosterKeepsTheStoredIdAndBlankGivesNone() {
        XCTAssertEqual(SignedTimesheetPeople.timesheetUserIds(personId: "TEST-CATALOGUE-ONLY", users: [sam()], operatives: []), ["TEST-CATALOGUE-ONLY"])
        XCTAssertEqual(SignedTimesheetPeople.timesheetUserIds(personId: "  ", users: [sam()], operatives: []), [])
    }

    func testDeleteAndReplaceReadTheSameSheets() throws {
        // Every path that warns asks for every id, through the one reader.
        for path in [
            "Project Planner/Core/BookingStore.swift",
            "Project Planner/Core/ManagerScheduleStore.swift",
            "Project Planner/Core/Rulebook+BookingReplace.swift",
        ] {
            let text = try source(path)
            XCTAssertTrue(text.contains("SignedTimesheetPeople.timesheetUserIds(personId:"), path)
            XCTAssertTrue(text.contains("signedTimesheetCandidates(organizationId: organizationId, userIds: userIds)"), path)
            XCTAssertFalse(text.contains("signedTimesheetCandidates(organizationId: organizationId, userId:"), path)
        }
        let reader = try source("Project Planner/Core/FirebaseBackend+OfflineDelete.swift")
        XCTAssertTrue(reader.contains("FieldPath.documentID(), isGreaterThanOrEqualTo: \"timesheet_\\(person)_\""), "sheets stored without userId")
        XCTAssertTrue(reader.contains("CanonicalBusinessEngine.timesheetDocumentSubjectId(doc.documentID)"))
        XCTAssertTrue(reader.contains("CanonicalBusinessEngine.parsePayrunSnapshotSheet(docId: doc.documentID, data: data)"))
    }

    // MARK: (2) Schedule grid rows from the naming roster

    private func listedAdmin() -> AppUser {
        var admin = LogicFixtures.selfEmployedUser(id: "TEST-LISTED-ADMIN", email: "listed.admin@example.test")
        admin.firstName = "Listed"
        admin.surname = "Admin"
        admin.role = .admin
        admin.permissions = UserPermissions(adminAccess: true)
        admin.isActive = true
        admin.passwordSet = true
        return admin
    }

    /// A users document the people list leaves out (an invite whose email claim is gone): only in the documents.
    private func documentOnlyOperative() -> AppUser {
        var person = LogicFixtures.selfEmployedUser(id: "B7C1D2E3-F4A5-4B6C-8D7E-9F0A1B2C3D4E", email: "left.over@example.test")
        person.firstName = "Left"
        person.surname = "Over"
        person.role = .operative
        person.permissions = UserPermissions(operativeMode: true)
        person.passwordSet = false
        person.isActive = true
        return person
    }

    func testAPersonOnlyInTheUsersDocumentsKeepsARowAndAnUnknownIdIsDropped() {
        let listed = [listedAdmin()]
        let leftover = documentOnlyOperative()
        let naming = UserStore.bookingNameRoster(
            listed: listed,
            documents: listed + [leftover],
            documentsOrganizationId: "TEST-org",
            openOrganizationId: "TEST-org",
            aliases: [:]
        )
        XCTAssertTrue(naming.contains { $0.id == leftover.id }, "the naming roster adds the document")
        XCTAssertFalse(listed.contains { $0.id == leftover.id }, "the people list does not have them")

        let stray = UUID()
        let rows = ScheduleWeekGrid.staffRows(
            operativeIds: [Booking.internalOperativeId(for: leftover.id), stray],
            userIds: ["TEST-NOBODY-AT-ALL"],
            operatives: [],
            users: naming
        )
        XCTAssertEqual(rows.map(\.name), ["Left Over"], "the document-only person keeps their row; unknown ids are left off")
        XCTAssertFalse(rows.contains { $0.role == .unknown })

        // With the listed roster alone the same booking names nobody and is left off, as 1.41 does for any unknown id.
        let listedOnly = ScheduleWeekGrid.staffRows(
            operativeIds: [Booking.internalOperativeId(for: leftover.id)],
            userIds: [],
            operatives: [],
            users: listed
        )
        XCTAssertTrue(listedOnly.isEmpty)
    }

    func testTheSchedulingWeekUsesTheNamingRoster() throws {
        let detail = try source("Project Planner/Views/ProjectDetailView.swift")
        XCTAssertTrue(detail.contains("users: userStore.bookingNameUsers"))
    }
}
