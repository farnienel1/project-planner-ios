//
//  ParityGaps24NovTests.swift
//  Two web ↔ iPhone parity gaps (audit 24 Nov), both display only, both answered by the packed rulebook:
//  - web #414b: a live Full day / AM / PM line on the generated invoice and the Email and export PDF names its window
//    (`timesheetLineDisplay`, RULEBOOK 1.70.0 §8); a line with clock times, and every signed snapshot row, read as stored.
//  - web #414c: an admin's "Unknown person" Exported row of a deleted person reads "Former: Jane Smith"
//    (`formerPersonForId` over `parseFormerPersonDocument`, `formerPersonLabel`, chip `FORMER_PERSON_CHIP`).
//

import XCTest
@testable import Project_Planner

@MainActor
final class ParityGaps24NovTests: XCTestCase {
    private let monday = Date(timeIntervalSince1970: 1_795_392_000) // 23 Nov 2026

    override func setUp() {
        super.setUp()
        OrganizationRulebookContext.update(from: Organization(firestoreDocumentId: "TEST-ORG-PG", name: "TEST-Company PG"))
    }

    override func tearDown() {
        OrganizationRulebookContext.update(from: nil)
        super.tearDown()
    }

    // MARK: web #414b — invoice line times

    func testLiveFullDayLineNamesItsWindow() throws {
        let times = try XCTUnwrap(InvoiceLineItem.liveSlotTimes(details: "FULL DAY", projectName: "Station Road", date: monday))
        XCTAssertTrue(times.hasPrefix("Full day"), times)
        XCTAssertNotEqual(times, "FULL DAY")
    }

    func testLineWithClockTimesKeepsItsOwnText() {
        XCTAssertNil(InvoiceLineItem.liveSlotTimes(details: "07:00–16:00", projectName: "Station Road", date: monday))
        XCTAssertNil(InvoiceLineItem.liveSlotTimes(details: "16:00–19:00 · OT 3h × 2 = 6h", projectName: "Station Road", date: monday))
    }

    func testMoneyRowAndSignedRowCarryNoSlotWindow() {
        // Only the live labour branch of `TimesheetInvoiceRows.rows` sets it; a fresh row (signed snapshot or money) has none.
        let item = InvoiceLineItem(
            lineId: "op-B1", date: monday, jobNumber: "J-1", projectName: "Station Road", details: "FULL DAY",
            paidHours: 8.5, payrollBasis: .dayRate, dayRate: 250, hourlyRate: nil, amount: 250, isPayeDay: false
        )
        XCTAssertNil(item.liveSlotTimes)
        XCTAssertEqual(item.amount, 250)
    }

    // MARK: web #414c — former people on Exported

    private var formerJane: [String: Any]? {
        CanonicalBusinessEngine.parseFormerPersonDocument(
            docId: "U-JANE",
            data: ["displayName": "Jane Smith", "email": "jane@example.com", "personIds": ["U-JANE", "OLD-INVITE-2"], "deletedAt": 1_795_000_000_000.0]
        )
    }

    func testDeletedPersonReadsFormerName() throws {
        let jane = try XCTUnwrap(formerJane)
        let stand = PersonTimesheetLookup.unresolvedPerson(storedUserId: "old-invite-2", organizationId: "TEST-ORG-PG", formerPeople: [jane])
        XCTAssertEqual(stand.firstName, "Former: Jane Smith")
        XCTAssertEqual(stand.surname, "")
        XCTAssertTrue(PersonTimesheetLookup.isFormerPerson(storedUserId: "OLD-INVITE-2", formerPeople: [jane]))
        XCTAssertEqual(CanonicalBusinessEngine.formerPersonChip, "Former person")
    }

    func testUnknownIdKeepsUnknownPersonLabel() throws {
        let jane = try XCTUnwrap(formerJane)
        let stand = PersonTimesheetLookup.unresolvedPerson(storedUserId: "6A9632BA-0000", organizationId: "TEST-ORG-PG", formerPeople: [jane])
        XCTAssertEqual(stand.firstName, CanonicalBusinessEngine.unknownBookingPersonLabel)
        XCTAssertTrue(stand.surname.hasPrefix("· "))
        XCTAssertFalse(PersonTimesheetLookup.isFormerPerson(storedUserId: "6A9632BA-0000", formerPeople: [jane]))
        // A failed read passes none: the old label stays.
        let noRead = PersonTimesheetLookup.unresolvedPerson(storedUserId: "U-JANE", organizationId: "TEST-ORG-PG")
        XCTAssertEqual(noRead.firstName, CanonicalBusinessEngine.unknownBookingPersonLabel)
    }

    func testExportedOwnerResolverMarksFormerRows() throws {
        let jane = try XCTUnwrap(formerJane)
        let admin = AppUser(id: "ADMIN-1", email: "a@example.com", organizationId: "TEST-ORG-PG", role: .admin, firstName: "Ann", surname: "Admin", isActive: true, passwordSet: true)
        let owner = PersonTimesheetLookup.exportedOwnerResolver(
            users: [admin], roster: [admin], idsOf: { [$0.id] }, includeUnresolved: true, organizationId: "TEST-ORG-PG", formerPeople: [jane]
        )
        let found = try XCTUnwrap(owner("U-JANE"))
        XCTAssertTrue(found.unresolved)
        XCTAssertTrue(found.former)
        XCTAssertEqual(found.user.firstName, "Former: Jane Smith")
        let unknown = try XCTUnwrap(owner("NOBODY-1"))
        XCTAssertTrue(unknown.unresolved)
        XCTAssertFalse(unknown.former)
    }
}
