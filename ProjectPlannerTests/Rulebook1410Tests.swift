import XCTest
@testable import Project_Planner

/// RULEBOOK 1.41.0 (owner decisions 11 Nov): one Scheduling tile per person-day (`scheduleDayCell`), unknown rows left
/// off the grid like web, and Replace on every orange double-booking row (`bookingReplaceOffer`,
/// `bookingReplaceWrites`; online only). The rules are the script's; these tests lock the bridges and the wiring.
@MainActor
final class Rulebook1410Tests: XCTestCase {
    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    }

    private func source(_ path: String) throws -> String {
        try String(contentsOf: repoRoot.appendingPathComponent(path), encoding: .utf8)
    }

    // MARK: One tile per person-day

    func testTwoBookingsReadTheDayTotalAndTheCount() throws {
        let day = try XCTUnwrap(CanonicalBusinessEngine.scheduleDayCell(
            bookings: [
                RulebookScheduleDayBooking(paidHours: 8, overtimeHours: 0, timeSlot: "FULL DAY"),
                RulebookScheduleDayBooking(paidHours: 18, overtimeHours: 8, timeSlot: "CUSTOM", overtimeClockHours: 4, overtimeMultiplier: 2),
            ],
            onLeave: false
        ))
        XCTAssertEqual(day.headline, "26h · 2 bookings")
        XCTAssertEqual(day.hoursText, "26h")
        XCTAssertEqual(day.countText, "2 bookings")
        XCTAssertEqual(day.standardText, "18h Std")
        XCTAssertEqual(day.overtimeText, "8h OT")
        XCTAssertEqual(day.overtimeLines, ["4h × 2 = 8h"])
        XCTAssertEqual(SchedulingV2CellKindBuilder.fromDayCell(day), .split(stdHours: 18, otHours: 8))
    }

    func testOneBookingHasNoCountAndKeepsItsSlotColour() throws {
        let day = try XCTUnwrap(CanonicalBusinessEngine.scheduleDayCell(
            bookings: [RulebookScheduleDayBooking(paidHours: 4, overtimeHours: 0, timeSlot: "AM")],
            onLeave: false
        ))
        XCTAssertEqual(day.headline, "4h")
        XCTAssertNil(day.countText)
        XCTAssertEqual(day.caption, "AM")
        XCTAssertEqual(SchedulingV2CellKindBuilder.fromDayCell(day), .halfDay(hours: 4, label: "AM"))
    }

    func testOnALeaveDayTheStdAndOtWordsAreDropped() throws {
        let day = try XCTUnwrap(CanonicalBusinessEngine.scheduleDayCell(
            bookings: [RulebookScheduleDayBooking(paidHours: 10, overtimeHours: 2, timeSlot: "CUSTOM", overtimeClockHours: 1, overtimeMultiplier: 2)],
            onLeave: true
        ))
        XCTAssertEqual(day.standardText, "8h")
        XCTAssertEqual(day.overtimeText, "2h")
        XCTAssertNil(day.caption)
        XCTAssertNil(CanonicalBusinessEngine.scheduleDayCell(bookings: [], onLeave: false))
    }

    func testTheGridTileCallsTheRuleAndEveryBookingStaysReachable() throws {
        let detail = try source("Project Planner/Views/ProjectDetailView.swift")
        XCTAssertTrue(detail.contains("CanonicalBusinessEngine.scheduleDayCell(bookings: figures, onLeave: leave != nil)"))
        XCTAssertTrue(detail.contains("if day.allBookings.count > 1 {"), "several bookings open a chooser")
        XCTAssertTrue(detail.contains("openSchedulingBooking(row: chooser.row, day: picked)"))
        XCTAssertFalse(detail.contains("if hours >= bestPaid {"), "never only the longest booking")
    }

    // MARK: A booked person is never unknown

    func testAnUnresolvedRowIsDroppedAndLogged() throws {
        let grid = try source("Project Planner/Core/ScheduleWeekGrid.swift")
        XCTAssertTrue(grid.contains("SCHEDULE_BOOKING_PERSON_UNRESOLVED"))
        XCTAssertTrue(grid.contains("guard person.role == .unknown else { return true }"))
    }

    func testFormerSameEmailCatalogueAndGhostIdsAllResolve() {
        var person = AppUser(
            id: "TEST-farnie", email: "farnie@example.test", organizationId: "TEST-org", role: .operative,
            firstName: "Farnie", surname: "Nel", permissions: UserPermissions(operativeMode: true)
        )
        person.formerUserIds = ["TEST-old"]
        var ghost = AppUser(
            id: "TEST-ghost", email: "", organizationId: "TEST-org", role: .operative,
            firstName: "Gus", surname: "Ghost", permissions: UserPermissions(operativeMode: true)
        )
        ghost.isGhost = true
        let rowId = UUID()
        let row = Operative(id: rowId, firstName: "Farnie", lastName: "Nel", email: "FARNIE@example.test", startDate: Date(timeIntervalSince1970: 0))
        let rows = ScheduleWeekGrid.staffRows(
            operativeIds: [
                Booking.internalOperativeId(for: "TEST-old"),
                Booking.internalOperativeId(for: "TEST-ghost"),
                rowId,
            ],
            userIds: [],
            operatives: [row],
            users: [person, ghost]
        )
        XCTAssertEqual(Set(rows.map(\.name)), ["Farnie Nel", "Gus Ghost"], "former id and catalogue row are one person; the ghost resolves")
        XCTAssertFalse(rows.contains { $0.role == .unknown })
    }

    // MARK: Replace

    func testReplaceIsOfferedOnlyWhenEveryOverlappingBookingMayBeDeleted() {
        XCTAssertEqual(
            CanonicalBusinessEngine.bookingReplaceOffer(clashing: [("B1", "bookings", true), ("m1", "managerSiteBookings", true)]),
            [RulebookBookingReplaceRef(collection: "bookings", bookingId: "B1"), RulebookBookingReplaceRef(collection: "managerSiteBookings", bookingId: "m1")]
        )
        XCTAssertNil(CanonicalBusinessEngine.bookingReplaceOffer(clashing: [("B1", "bookings", true), ("B2", "bookings", false)]))
        XCTAssertNil(CanonicalBusinessEngine.bookingReplaceOffer(clashing: [("S1", "subcontractorBookings", true)]))
        XCTAssertNil(CanonicalBusinessEngine.bookingReplaceOffer(clashing: []))
    }

    func testTheReplacePlanIsTheNewBookingAndEachDeleteWithItsTombstone() throws {
        let plan = try XCTUnwrap(CanonicalBusinessEngine.bookingReplaceWrites(
            organizationId: "TEST-ORG",
            bookingCollection: "bookings",
            bookingId: "NEW1",
            replaced: [RulebookBookingReplaceRef(collection: "bookings", bookingId: "OLD1")],
            deletedBy: "TEST-uid"
        ))
        XCTAssertEqual(plan.bookingPath, "organizations/TEST-ORG/bookings/NEW1")
        XCTAssertEqual(plan.deletes.map(\.path), ["organizations/TEST-ORG/bookings/OLD1"])
        XCTAssertEqual(plan.deletes.map(\.tombstonePath), ["organizations/TEST-ORG/deletedBookings/OLD1"])
        XCTAssertEqual(plan.deletes.first?.tombstone["deletedFrom"] as? String, "ios")
        XCTAssertNil(CanonicalBusinessEngine.bookingReplaceWrites(
            organizationId: "TEST-ORG",
            bookingCollection: "bookings",
            bookingId: "NEW1",
            replaced: [RulebookBookingReplaceRef(collection: "bookings", bookingId: "new1")],
            deletedBy: "TEST-uid"
        ), "a booking never replaces itself")
    }

    func testReplaceIsOnlineOnly() {
        XCTAssertEqual(OfflinePolicy.availability(.replaceBooking), .onlineOnly)
        XCTAssertFalse(OfflinePolicy.isEnabled(.replaceBooking, isOnline: false))
        XCTAssertTrue(OfflinePolicy.isEnabled(.replaceBooking, isOnline: true))
        XCTAssertTrue(OfflinePolicy.isEnabled(.createBooking, isOnline: false), "✓ and ✕ still work offline")
    }

    func testReplaceResolvesARowAndCarriesItsBookings() {
        let refs = [RulebookBookingReplaceRef(collection: "bookings", bookingId: "OLD1")]
        let row = BookingConflictItem.doubleBooking(personKey: "OP-1", dayKey: "2026-11-12", personName: "P", detail: "Already booked", replace: refs)
        let plain = BookingConflictItem.doubleBooking(personKey: "OP-2", dayKey: "2026-11-12", personName: "Q", detail: "Already booked")
        XCTAssertTrue(BookingConflictResolution.resolved([row], decisions: [row.id: .replace]))
        XCTAssertFalse(BookingConflictResolution.resolved([plain], decisions: [plain.id: .replace]), "no Replace on a row that does not offer it")
        let choices = BookingConflictResolution.choices([row, plain], decisions: [row.id: .replace, plain.id: .confirm])
        XCTAssertEqual(choices.replaced, ["OP-1|2026-11-12": refs])
        XCTAssertTrue(choices.dropped.isEmpty)
        XCTAssertEqual(choices.allReplaced, refs)
    }

    func testFlowsThatDoNotSaveAReplaceShowItsRowsWithoutIt() {
        let gate = BookingConflictGate()
        let row = BookingConflictItem.doubleBooking(
            personKey: "OP-1", dayKey: "2026-11-12", personName: "P", detail: "Already booked",
            replace: [RulebookBookingReplaceRef(collection: "bookings", bookingId: "OLD1")]
        )
        gate.run(rows: [row]) { _ in }
        XCTAssertNil(gate.pending?.rows.first?.replace)
        gate.pending = nil
        gate.runChoices(rows: [row]) { _ in }
        XCTAssertNotNil(gate.pending?.rows.first?.replace)
    }

    func testEveryOwnerFlowSavesAReplaceInOneBatch() throws {
        let backend = try source("Project Planner/FirebaseBackend.swift")
        XCTAssertTrue(backend.contains("CanonicalBusinessEngine.bookingReplaceWrites("))
        XCTAssertTrue(backend.contains("let batch = db.batch()"))
        let detail = try source("Project Planner/Views/ProjectDetailView.swift")
        XCTAssertTrue(detail.contains("bookingStore.addBookingReplacing(booking, replaces: replaces)"), "Quick Add")
        XCTAssertFalse(detail.contains("if let message = ScheduleWeekGrid.overlapMessage("), "Quick Add lists the overlap as an orange row")
        let labour = try source("Project Planner/Views/BookLabourFlowView.swift")
        XCTAssertTrue(labour.contains("leaveGate.runChoices(rows: clashRows + leaveRows)"), "Book labour (party)")
        XCTAssertTrue(labour.contains("leaveGate.runSingleReplacing(rows: clashRows + leaveRows)"), "Book labour (one operative)")
        let wizard = try source("Project Planner/Views/ScheduleOperativeView.swift")
        XCTAssertTrue(wizard.contains("bookingStore.addBookingReplacing(entry.booking, replaces: entry.refs)"), "Scheduling wizard")
    }
}
