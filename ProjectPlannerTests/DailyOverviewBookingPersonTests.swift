import XCTest
@testable import Project_Planner

/// Owner report (4 Nov, Daily Overview 13 and 14 Nov 2026): web named every booked person; iOS showed "Unknown person"
/// on each booking row, and a Saturday custom 07:30–14:00 booking read "Full standard day · 07:30–14:00" where web
/// reads "Custom 07:30–14:00" (RULEBOOK §6).
///
/// After a user type change writes every same-email `users` document (#181, `accountTypeChangeWrites`), the
/// `rosterPeople` fold may keep the other document: the roster row's id is then not the id the bookings store, which
/// is only on the row's `sameEmailUserIds`. Web resolves the person through the rulebook (`resolveBookingPerson` /
/// `findUserByAnyId` with the fold's aliases); iOS matched the exact id and former ids only.
@MainActor
final class DailyOverviewBookingPersonTests: XCTestCase {
    private let bookedUid = "TestAdminAuthUid9"
    private let placeholderId = "6A1B2C3D-4E5F-4A6B-8C7D-9E0F1A2B3C4D"

    /// The roster after the type change: the fold kept the placeholder document and folded the uid into it.
    private func rosterAfterTypeChange() -> [AppUser] {
        var admin = LogicFixtures.selfEmployedUser(id: placeholderId, email: "test.admin@example.com")
        admin.firstName = "Test"
        admin.surname = "Admin"
        admin.role = .admin
        admin.permissions = UserPermissions(adminAccess: true)
        admin.sameEmailUserIds = [bookedUid]
        admin.passwordSet = true
        admin.isActive = true
        return [admin]
    }

    func testABookingUnderTheFoldedSameEmailIdStillNamesThePerson() {
        let booking = LogicFixtures.booking(
            on: LogicFixtures.day(2026, 11, 13, hour: 8),
            operativeId: Booking.internalOperativeId(for: bookedUid)
        )
        let name = rosterNameForLabourBooking(operativeId: booking.operativeId, operatives: [], users: rosterAfterTypeChange())
        XCTAssertEqual(name, "Test Admin", "web names this booking; iOS showed \(unknownLabourPersonName)")
        XCTAssertEqual(
            emailForLabourBooking(operativeId: booking.operativeId, operatives: [], users: rosterAfterTypeChange()),
            "test.admin@example.com"
        )
    }

    func testABookingUnderAnotherLetterCaseStillNamesThePerson() {
        // iOS writes upper-case UUIDs, web lower case (RULEBOOK §1: ids compare without case).
        let booking = LogicFixtures.booking(
            on: LogicFixtures.day(2026, 11, 13, hour: 8),
            operativeId: Booking.internalOperativeId(for: bookedUid.lowercased())
        )
        let name = rosterNameForLabourBooking(operativeId: booking.operativeId, operatives: [], users: rosterAfterTypeChange())
        XCTAssertEqual(name, "Test Admin")
    }

    func testTheSameRosterCountsThePersonAsBooked() {
        // Guard: the unbooked scan (`unbookedLabourRowsOnDay`) and the row name read the same person.
        let day = LogicFixtures.day(2026, 11, 13, hour: 8)
        let booking = LogicFixtures.booking(on: day, operativeId: Booking.internalOperativeId(for: bookedUid))
        let rows = WarningsComputation.unbookedLabourRowsOnDay(
            day: day,
            users: rosterAfterTypeChange(),
            operatives: [],
            operativeBookings: [booking],
            managerBookings: [],
            holidays: [],
            policy: .default,
            includeWeekends: false,
            excludedUserIds: []
        )
        XCTAssertTrue(rows.isEmpty, "booked under a same-email id: not unbooked (\(rows.map(\.operativeName)))")
    }

    func testAnUnknownIdIsStillUnknownPerson() {
        let booking = LogicFixtures.booking(on: LogicFixtures.day(2026, 11, 13, hour: 8), operativeId: UUID())
        XCTAssertEqual(
            rosterNameForLabourBooking(operativeId: booking.operativeId, operatives: [], users: rosterAfterTypeChange()),
            unknownLabourPersonName,
            "the booking row is never hidden; a person nobody matches stays Unknown person"
        )
    }

    // MARK: - Row times (RULEBOOK §6, web `bookingTimesText`)

    func testCustomHoursCoveringTheStandardDayShowCustomTimes() {
        let booking = LogicFixtures.booking(
            on: LogicFixtures.day(2026, 10, 21, hour: 8),
            slot: .customHours,
            start: "07:30",
            end: "16:30"
        )
        let text = booking.scheduleCoverageSubtitle(policy: LogicFixtures.policy).text
        XCTAssertFalse(text.hasPrefix("Full standard day"), text)
        XCTAssertTrue(text.hasPrefix("Custom 07:30–16:30"), text)
    }

    func testAStoredFullDayStillSaysFullStandardDay() {
        let booking = LogicFixtures.booking(on: LogicFixtures.day(2026, 10, 21, hour: 8))
        XCTAssertTrue(booking.scheduleCoverageSubtitle(policy: LogicFixtures.policy).text.hasPrefix("Full standard day"))
    }

    // MARK: - Change user type keeps stored toggles (audit, 4 Nov)

    /// Admin → manager: the plan gets only the sheet's toggles (`sheetToggles`, web `changeAccountType`). The whole
    /// in-effect map turned `wholesalersOrderHistory` on (an admin has it in effect) over a stored false.
    func testAdminToManagerKeepsAStoredOffToggleTheSheetDoesNotShow() throws {
        let person: [String: Any] = [
            "id": "admin-1", "email": "a@example.com", "organizationId": "org-1", "role": "admin",
            "adminAccess": true, "isSuperAdmin": false, "wholesalersOrderHistory": false,
            "permissions": ["adminAccess": true, "wholesalersOrderHistory": false],
        ]
        let sheet: [String: Bool] = ["annualLeaveSelfBook": false, "operatives": true, "projects": true, "smallWorks": true]
        guard case .ok(_, let fromSheet, _, _) = try XCTUnwrap(CanonicalBusinessEngine.accountTypeChangeWrites(
            person: person, kind: .manager, organizationId: "org-1", roster: [], permissions: sheet
        )) else { return XCTFail("plan refused") }
        XCTAssertEqual(fromSheet["wholesalersOrderHistory"], false, "stored value kept")

        let inEffect = try XCTUnwrap(CanonicalBusinessEngine.effectivePermissions(person))
        guard case .ok(_, let fromWholeMap, _, _) = try XCTUnwrap(CanonicalBusinessEngine.accountTypeChangeWrites(
            person: person, kind: .manager, organizationId: "org-1", roster: [], permissions: inEffect.merging(sheet) { $1 }
        )) else { return XCTFail("plan refused") }
        XCTAssertEqual(fromWholeMap["wholesalersOrderHistory"], true, "why the whole map must not be passed")
    }
}
