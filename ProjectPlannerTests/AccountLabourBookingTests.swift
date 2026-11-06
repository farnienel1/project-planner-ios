import XCTest
@testable import Project_Planner

/// Checklist 1.42 (owner decision 4 Nov "Judgement call in #262", kept 6 Nov): an operative with an app login but no
/// Operatives-list row is booked under their users id, as web Book labour does, only when the rulebook's
/// `bookingIdsForAccount` counts that id as theirs. Everyone with a catalogue row keeps that row.
@MainActor
final class AccountLabourBookingTests: XCTestCase {
    private func account(
        _ id: String,
        email: String,
        role: UserRole = .operative,
        permissions: UserPermissions = UserPermissions(operativeMode: true)
    ) -> AppUser {
        AppUser(
            id: id,
            email: email,
            organizationId: "TEST-org",
            role: role,
            firstName: "TEST-\(id)",
            surname: "Person",
            permissions: permissions
        )
    }

    private func catalogueRow(email: String, id: UUID = UUID()) -> Operative {
        Operative(id: id, firstName: "TEST-Row", lastName: "Person", email: email, startDate: Date(timeIntervalSince1970: 0))
    }

    // MARK: The rulebook wrapper

    func testAnAccountWithNoCatalogueRowIsBookedUnderItsUsersIdWhenTheRulebookCountsIt() throws {
        let user = account("solo-uid-142", email: "solo142@example.test")
        let counted = try XCTUnwrap(
            CanonicalBusinessEngine.bookingIdsForAccount(
                CanonicalBusinessEngine.CanonicalBookingPersonAccount(id: user.id, email: user.email, formerIds: [], aliasIds: []),
                operatives: []
            ),
            "the packed script answers"
        )
        XCTAssertEqual(counted, ["solo-uid-142"])

        let id = try XCTUnwrap(AccountLabourBooking.bookingOperativeId(for: user, operatives: []))
        XCTAssertEqual(Booking.storedOperativeId(for: id), "solo-uid-142", "the booking's operativeId is the users id, as web stores it")
        let row = try XCTUnwrap(AccountLabourBooking.bookingOperative(for: user, operatives: []))
        XCTAssertEqual(row.id, id)
        XCTAssertEqual(row.documentId, "solo-uid-142")
        XCTAssertEqual(row.email, user.email)
    }

    func testOtherPeoplesCatalogueRowsDoNotChangeTheUsersIdTarget() throws {
        let user = account("solo-uid-142b", email: "solo142b@example.test")
        let someoneElse = catalogueRow(email: "other142b@example.test")
        let id = try XCTUnwrap(AccountLabourBooking.bookingOperativeId(for: user, operatives: [someoneElse]))
        XCTAssertEqual(Booking.storedOperativeId(for: id), "solo-uid-142b")
        XCTAssertNotEqual(id, someoneElse.id)
    }

    func testABlankUsersIdIsNeverBookedUnder() {
        let user = account("   ", email: "blank142@example.test")
        XCTAssertNil(AccountLabourBooking.bookingOperativeId(for: user, operatives: []))
        XCTAssertNil(AccountLabourBooking.bookingOperative(for: user, operatives: []))
    }

    // MARK: Book labour

    func testBookLabourBooksAnOperativeWithNoCatalogueRowUnderTheirUsersId() throws {
        let user = account("bl-uid-142", email: "bl142@example.test")
        let candidate = BookLabourCandidate(
            user: user,
            linkedOperative: nil,
            usesOperativeProjectBookings: true,
            accountBookingOperative: AccountLabourBooking.bookingOperative(for: user, operatives: [])
        )
        let operative = try XCTUnwrap(candidate.bookingOperative, "no \"No operative profile is linked\" for this person")
        XCTAssertEqual(Booking.storedOperativeId(for: operative.id), "bl-uid-142")
    }

    func testBookLabourKeepsTheCatalogueRowWhenThereIsOne() {
        let user = account("bl-uid-142c", email: "bl142c@example.test")
        let row = catalogueRow(email: user.email)
        let candidate = BookLabourCandidate(
            user: user,
            linkedOperative: row,
            usesOperativeProjectBookings: true,
            accountBookingOperative: AccountLabourBooking.bookingOperative(for: user, operatives: [row])
        )
        XCTAssertEqual(candidate.bookingOperative?.id, row.id, "a catalogue row is still booked under its own id")
    }

    func testBookLabourManagersStillUseManagerSiteBookings() {
        let manager = account(
            "bl-mgr-142",
            email: "blmgr142@example.test",
            role: .manager,
            permissions: UserPermissions(manager: true)
        )
        let candidate = BookLabourCandidate(user: manager, linkedOperative: nil, usesOperativeProjectBookings: false)
        XCTAssertNil(candidate.bookingOperative)
    }

    func testTheUnbookedRowsOperativeIdFindsItsCatalogueRowWithoutCase() {
        let uuidRow = catalogueRow(email: "uuidrow142@example.test")
        XCTAssertEqual(
            BookLabourCandidate.catalogueRow(forRowOperativeId: uuidRow.id.uuidString.lowercased(), in: [uuidRow])?.id,
            uuidRow.id
        )

        var textRow = catalogueRow(email: "textrow142@example.test", id: Booking.internalOperativeId(for: "row-text-142"))
        textRow.firestoreDocumentId = "row-text-142"
        XCTAssertEqual(
            BookLabourCandidate.catalogueRow(forRowOperativeId: "ROW-TEXT-142", in: [uuidRow, textRow])?.id,
            textRow.id,
            "a non-UUID document id still names its row, so that person is never booked under their users id instead"
        )

        XCTAssertNil(BookLabourCandidate.catalogueRow(forRowOperativeId: "solo-uid-142", in: [uuidRow, textRow]), "a users id names no row")
        XCTAssertNil(BookLabourCandidate.catalogueRow(forRowOperativeId: "  ", in: [uuidRow, textRow]))
    }

    // MARK: Project / small works scheduling and Quick Add

    func testSchedulingListsTheAccountUnderItsUsersId() {
        let user = account("sched-uid-142", email: "sched142@example.test")
        let rows = ScheduleBookablePersonBuilder.operativesForScheduling(operatives: [], users: [user])
        XCTAssertEqual(rows.map { Booking.storedOperativeId(for: $0.id) }, ["sched-uid-142"])
    }

    func testQuickAddSavesTheAccountAsAnOperativeBookingUnderItsUsersId() throws {
        let user = account("qa-uid-142", email: "qa142@example.test")
        let bookedId = AccountLabourBooking.operativeId(for: user)
        let rows = ScheduleWeekGrid.staffRows(
            operativeIds: [bookedId],
            userIds: ["qa-uid-142"],
            operatives: [],
            users: [user]
        )
        XCTAssertEqual(rows.count, 1)
        let row = try XCTUnwrap(rows.first)
        XCTAssertEqual(row.role, .operative)
        XCTAssertTrue(row.savesAsOperativeBooking)
        XCTAssertEqual(row.saveOperativeId, bookedId)
        let target = try XCTUnwrap(ScheduleWeekGrid.saveTarget(for: row, jobType: .catA))
        XCTAssertEqual(target, ScheduleQuickAddSave.operativeBookings(operativeId: bookedId), "never a manager site booking")
    }
}
