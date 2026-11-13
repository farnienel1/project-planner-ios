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

    // MARK: - People the people lists leave out (owner report 13 Nov)

    /// An invite placeholder whose `userEmails` claim is gone is not listed (`listedRosterUsers`), so it is not in
    /// `organizationUsers`. Web Daily Overview names bookings from its whole roster (no `listedRosterUsers` filter),
    /// so a booking stored under that document read a name on web and "Unknown person" on iOS.
    private func leftoverInvite() -> AppUser {
        var person = LogicFixtures.selfEmployedUser(id: "B7C1D2E3-F4A5-4B6C-8D7E-9F0A1B2C3D4E", email: "left.over@example.com")
        person.firstName = "Left"
        person.surname = "Over"
        person.role = .operative
        person.passwordSet = false
        person.isActive = true
        return person
    }

    /// The naming roster for documents read for org-1 with org-1 open.
    private func namingRoster(listed: [AppUser], documents: [AppUser], aliases: [String: String] = [:]) -> [AppUser] {
        UserStore.bookingNameRoster(
            listed: listed, documents: documents, documentsOrganizationId: "org-1", openOrganizationId: "org-1", aliases: aliases
        )
    }

    /// The document the #181 fold folded into the placeholder row: same email, the booked uid.
    private func foldedAdminDocument() -> AppUser {
        var folded = LogicFixtures.selfEmployedUser(id: bookedUid, email: "test.admin@example.com")
        folded.firstName = "Stale"
        folded.surname = "Copy"
        folded.passwordSet = true
        return folded
    }

    func testABookingUnderAPersonTheListedRosterLeavesOutIsNamedFromTheOrganisationDocuments() throws {
        let leftover = leftoverInvite()
        let listedAdmin = rosterAfterTypeChange()
        let listed = try XCTUnwrap(GhostRulebook.listed(listedAdmin + [leftover], claimedEmails: ["test.admin@example.com"]))
        XCTAssertFalse(listed.contains { $0.id == leftover.id }, "precondition: the people lists leave the leftover invite out")

        let booking = LogicFixtures.booking(
            on: LogicFixtures.day(2026, 11, 13, hour: 8),
            operativeId: Booking.internalOperativeId(for: leftover.id)
        )
        XCTAssertEqual(
            rosterNameForLabourBooking(operativeId: booking.operativeId, operatives: [], users: listed),
            unknownLabourPersonName,
            "the bug: naming against the listed roster"
        )
        XCTAssertEqual(
            rosterNameForLabourBooking(
                operativeId: booking.operativeId, operatives: [], users: namingRoster(listed: listed, documents: listedAdmin + [leftover])
            ),
            "Left Over",
            "web names this booking from the whole roster"
        )
    }

    func testTheNamingRosterSkipsDocumentsFoldedIntoAListedPerson() {
        let listed = rosterAfterTypeChange()
        let other = leftoverInvite()
        let documents = [listed[0], foldedAdminDocument(), other, other]
        // Folded through the listed row's sameEmailUserIds.
        XCTAssertEqual(namingRoster(listed: listed, documents: documents).map(\.id), [placeholderId, other.id])
        // Folded through the fold's alias map only (the listed row lost the stamp).
        var unstamped = listed
        unstamped[0].sameEmailUserIds = []
        XCTAssertEqual(
            namingRoster(listed: unstamped, documents: documents, aliases: [bookedUid.lowercased(): placeholderId]).map(\.id),
            [placeholderId, other.id]
        )
        XCTAssertEqual(namingRoster(listed: listed, documents: documents).first?.sameEmailUserIds, [bookedUid])
    }

    func testABookingUnderTheFoldedUidNamesTheKeptRowNotTheFoldedDocument() {
        let listed = rosterAfterTypeChange()
        let naming = namingRoster(listed: listed, documents: [listed[0], foldedAdminDocument()])
        let booking = LogicFixtures.booking(
            on: LogicFixtures.day(2026, 11, 13, hour: 8),
            operativeId: Booking.internalOperativeId(for: bookedUid)
        )
        XCTAssertEqual(rosterNameForLabourBooking(operativeId: booking.operativeId, operatives: [], users: naming), "Test Admin")
    }

    func testBothIdsOfThePersonGiveOneGroupKey() {
        // ProjectActiveOperativesView groups by the resolved person: the placeholder id and the folded uid are one row.
        let listed = rosterAfterTypeChange()
        let people = LabourBookingPeople(operatives: [], users: namingRoster(listed: listed, documents: [listed[0], foldedAdminDocument()]))
        let underUid = people.person(for: Booking.internalOperativeId(for: bookedUid)).user?.id
        let underPlaceholder = people.person(for: Booking.internalOperativeId(for: placeholderId)).user?.id
        XCTAssertEqual(underUid, placeholderId)
        XCTAssertEqual(underPlaceholder, placeholderId)
    }

    func testASurvivingFormerPlaceholderOnAnotherEmailDoesNotTakeThePersonsBookings() {
        // The live person lists the old invite placeholder in formerUserIds; the placeholder document survived on a
        // different email. `resolveBookingPerson` matches an exact id before former ids, so the placeholder must not be
        // on the naming roster, or it would take the booking (a second row, its stale rate on the weekly report).
        let formerId = "0D9E8F7A-6B5C-4D3E-8F1A-2B3C4D5E6F70"
        var live = rosterAfterTypeChange()
        live[0].formerUserIds = [formerId]
        var placeholder = LogicFixtures.selfEmployedUser(id: formerId, email: "old.invite@example.com", dayRate: 999)
        placeholder.firstName = "Old"
        placeholder.surname = "Invite"
        placeholder.passwordSet = false
        let naming = namingRoster(listed: live, documents: [live[0], placeholder])
        XCTAssertEqual(naming.map(\.id), [placeholderId], "the former placeholder is the live person's own id")

        let booking = LogicFixtures.booking(
            on: LogicFixtures.day(2026, 11, 13, hour: 8),
            operativeId: Booking.internalOperativeId(for: formerId)
        )
        XCTAssertEqual(rosterNameForLabourBooking(operativeId: booking.operativeId, operatives: [], users: naming), "Test Admin")
        let people = LabourBookingPeople(operatives: [], users: naming)
        XCTAssertEqual(people.person(for: booking.operativeId).user?.id, placeholderId)
        XCTAssertEqual(
            people.person(for: Booking.internalOperativeId(for: placeholderId)).user?.id,
            placeholderId,
            "one group key for both ids"
        )
    }

    func testDocumentsReadForAnotherOrganisationAreNotUsed() {
        let listed = rosterAfterTypeChange()
        let other = leftoverInvite()
        XCTAssertEqual(
            UserStore.bookingNameRoster(
                listed: listed, documents: [other], documentsOrganizationId: "org-2", openOrganizationId: "org-1", aliases: [:]
            ).map(\.id),
            [placeholderId]
        )
        XCTAssertEqual(
            UserStore.bookingNameRoster(
                listed: listed, documents: [other], documentsOrganizationId: nil, openOrganizationId: "org-1", aliases: [:]
            ).map(\.id),
            [placeholderId]
        )
    }

    func testTheStorePropertyIgnoresDocumentsWhenNoOrganisationIsOpen() {
        // The instance property's guard: documents for org-1 while no organisation is open (no backend) → listed only.
        let store = UserStore()
        store.organizationUsers = rosterAfterTypeChange()
        store.applyRosterDocumentsForTesting([leftoverInvite()], organizationId: "org-1")
        XCTAssertEqual(store.bookingNameUsers.map(\.id), [placeholderId])
    }

    func testANonUUIDCatalogueRowInAnotherLetterCaseStillNamesThePerson() {
        // The row is stored "abcRow7", the booking "ABCROW7": two in-app ids (`internalOperativeId` hashes the text).
        var row = LogicFixtures.operative(id: Booking.internalOperativeId(for: "abcRow7"), email: "")
        row.firestoreDocumentId = "abcRow7"
        row.firstName = "Casey"
        row.lastName = "Row"
        let booking = LogicFixtures.booking(
            on: LogicFixtures.day(2026, 11, 13, hour: 8),
            operativeId: Booking.internalOperativeId(for: "ABCROW7")
        )
        XCTAssertNotEqual(booking.operativeId, row.id)
        XCTAssertEqual(rosterNameForLabourBooking(operativeId: booking.operativeId, operatives: [row], users: []), "Casey Row")
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
