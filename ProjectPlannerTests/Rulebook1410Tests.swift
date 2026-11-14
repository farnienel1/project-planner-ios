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

    func testEveryOwnerFlowSavesAReplaceInOneCheckedTransaction() throws {
        let backend = try source("Project Planner/FirebaseBackend.swift")
        XCTAssertTrue(backend.contains("CanonicalBusinessEngine.bookingReplaceWrites("))
        // Review 1.41 #3, #4: one transaction that re-reads each replaced booking and its tombstone and compares the
        // fingerprint the person was shown, bounded by the write wait (never queued for a later replay).
        XCTAssertTrue(backend.contains("try await FirestoreWriteAck.run(\n                timeoutSeconds: FirestoreWriteAck.defaultTimeoutSeconds,"))
        XCTAssertTrue(backend.contains("live = try transaction.getDocument(row.ref)"))
        XCTAssertTrue(backend.contains("tombstone = try transaction.getDocument(row.tombstoneRef)"))
        XCTAssertTrue(backend.contains("let liveFingerprint = BookingWritePatch.stored(data, collection: row.collection)"))
        XCTAssertTrue(backend.contains("throw Self.bookingReplaceError(BookingReplaceMessages.notConfirmed)"))
        // Re-review #4: an empty fingerprint never counts as unchanged; #5: a late commit still sends the follow-ups.
        XCTAssertTrue(backend.contains("if row.expected.isEmpty || liveFingerprint.isEmpty || liveFingerprint != row.expected {"))
        XCTAssertTrue(backend.contains("guard error == nil, outcome.value == \"apply\" else { return }"))
        let replace = try source("Project Planner/Core/Rulebook+BookingReplace.swift")
        XCTAssertTrue(replace.contains("stamped.fingerprint = shown["), "refs carry the fingerprint shown on the row")
        XCTAssertFalse(backend.contains("BOOKING_REPLACE collection=%@ id=%@ replaces=%ld\", collection, documentKey, plan.deletes.count)\n        try await batch.commit()"))
        let detail = try source("Project Planner/Views/ProjectDetailView.swift")
        XCTAssertTrue(
            detail.contains("bookingStore.addBookingReplacing(booking, replaces: replaces, managerBookings: managerScheduleStore.managerSiteBookings)"),
            "Quick Add"
        )
        XCTAssertFalse(detail.contains("if let message = ScheduleWeekGrid.overlapMessage("), "Quick Add lists the overlap as an orange row")
        let labour = try source("Project Planner/Views/BookLabourFlowView.swift")
        XCTAssertTrue(labour.contains("leaveGate.runChoices(rows: clashRows + leaveRows)"), "Book labour (party)")
        XCTAssertTrue(labour.contains("leaveGate.runSingleReplacing(rows: clashRows + leaveRows)"), "Book labour (one operative)")
        XCTAssertFalse(labour.contains("OverlappingBookings("), "Replace sets come from bookingReplaceCandidates (review #8, #9)")
        let wizard = try source("Project Planner/Views/ScheduleOperativeView.swift")
        XCTAssertTrue(wizard.contains("bookingStore.addBookingReplacing(\n                    entry.booking,\n                    replaces: refs,"), "Scheduling wizard")
        XCTAssertTrue(wizard.contains("alreadyReplaced.insert("), "a booking overlapping two days is replaced once (review #10)")
        // Re-review #1: marked only after its day saved; refs captured when Replace was tapped (re-review #3).
        let saveBranch = try XCTUnwrap(wizard.components(separatedBy: "saveResults.append(.refused(problem))\n                } else {").last)
        XCTAssertTrue(saveBranch.hasPrefix("\n                    for ref in refs { alreadyReplaced.insert("))
        XCTAssertTrue(wizard.contains("guard let captured = replacedConflictRefs[row.id]"))
        XCTAssertTrue(wizard.contains("captureReplacedConflictRefs(added: newIds.subtracting(oldIds)"))
    }

    func testAReplaceSendsTheDeleteFollowUps() throws {
        // Review 1.41 #1, #2: the signed-timesheet warning before, the overtime reopen notice after, on both stores.
        for path in ["Project Planner/Core/BookingStore.swift", "Project Planner/Core/ManagerScheduleStore.swift"] {
            let store = try source(path)
            XCTAssertTrue(store.contains("await BookingReplaceNotices.warnIfOnSignedTimesheet(targets,"), path)
            XCTAssertTrue(store.contains("BookingReplaceNotices.reopenOvertime(targets, organizationId:"), path)
            XCTAssertTrue(store.contains("onLateApply: { BookingReplaceNotices.reopenOvertime(targets, organizationId:"), path)
        }
        let notices = try source("Project Planner/Core/Rulebook+BookingReplace.swift")
        XCTAssertTrue(notices.contains("OvertimeReopenNotice.labour(before: booking, after: nil, organizationId: organizationId)"))
        XCTAssertTrue(notices.contains("OvertimeReopenNotice.managerSite(before: booking, after: nil, organizationId: organizationId)"))
        XCTAssertTrue(notices.contains("CanonicalBusinessEngine.bookingDeleteSignedTimesheetWarning("))
    }

    func testAReplacedBookingNoLongerOnThisPhoneReplacesNothing() throws {
        let day = try XCTUnwrap(OrganizationRulebookContext.calendar.date(from: DateComponents(year: 2026, month: 11, day: 17)))
        let shown = Booking(operativeId: UUID(), projectId: UUID(), date: day, timeSlot: .fullDay, bookedBy: "x")
        let ref = RulebookBookingReplaceRef(
            collection: "bookings", bookingId: shown.documentKey, fingerprint: BookingWritePatch.deleteFingerprint(shown)
        )
        // The store has moved on since the row was shown: the shown fingerprint is kept (re-review #3).
        var changed = shown
        changed.workEndTime = "18:00"
        let targets = try XCTUnwrap(BookingReplaceTarget.resolve([ref], bookings: [changed], managerBookings: []))
        XCTAssertEqual(targets.first?.fingerprint, BookingWritePatch.deleteFingerprint(shown))
        XCTAssertNotEqual(targets.first?.fingerprint, BookingWritePatch.deleteFingerprint(changed))
        XCTAssertNil(
            BookingReplaceTarget.resolve(
                [RulebookBookingReplaceRef(collection: "bookings", bookingId: shown.documentKey)],
                bookings: [shown], managerBookings: []
            ),
            "a ref with no shown fingerprint replaces nothing (fail closed)"
        )
        XCTAssertNil(BookingReplaceTarget.resolve([ref], bookings: [], managerBookings: []), "gone from this phone: nothing is replaced")
        XCTAssertNil(BookingReplaceTarget.resolve(
            [ref, RulebookBookingReplaceRef(collection: "managerSiteBookings", bookingId: "MISSING", fingerprint: "x")],
            bookings: [shown], managerBookings: []
        ), "one missing booking stops the whole Replace")
    }

    func testReplaceCandidatesIncludeTheOvernightBookingFromTheNightBefore() throws {
        let calendar = OrganizationRulebookContext.calendar
        let day = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 11, day: 17)))
        let dayBefore = try XCTUnwrap(calendar.date(byAdding: .day, value: -1, to: day))
        let operative = UUID()
        let night = Booking(
            operativeId: operative, projectId: UUID(), date: dayBefore, timeSlot: .customHours, bookedBy: "x",
            workStartTime: "22:00", workEndTime: "06:00"
        )
        let evening = Booking(
            operativeId: operative, projectId: UUID(), date: day, timeSlot: .customHours, bookedBy: "x",
            workStartTime: "18:00", workEndTime: "20:00"
        )
        let hits = CanonicalBusinessEngine.bookingReplaceCandidates(
            request: RulebookClashBooking(
                id: "request", dayKey: OrganizationRulebookContext.dayKey(day), timeSlot: "CUSTOM_HOURS",
                workStartTime: "05:00", workEndTime: "09:00"
            ),
            labour: [night, evening],
            manager: [],
            policy: .default
        )
        XCTAssertEqual(hits.labour.map(\.id), [night.id], "the night shift reaching 06:00 is replaced; 18:00 does not overlap")
        XCTAssertTrue(hits.manager.isEmpty)
    }

    func testTheWizardListsOneRowPerPersonDayAndReplaceRemovesEveryOverlap() throws {
        // Review 1.41 #7: one double-booking row per person-day, Replace with every overlapping booking or none.
        let support = try source("Project Planner/Core/ScheduleBookingConflictSupport.swift")
        XCTAssertTrue(support.contains("kind: rowKind, suffix: \"clash\")"))
        XCTAssertTrue(support.contains(": CanonicalBusinessEngine.bookingReplaceOffer(labour: labourHits, manager: managerHits)"))
        XCTAssertTrue(support.contains("replaceRefs: answered == nil"), "Replace fails closed when the script does not answer (#9)")
    }

    func testTheGridShowsLoadingWhileItsPeopleLoad() throws {
        // Review 1.41 #5: never an empty grid while the roster that names its bookings loads.
        let detail = try source("Project Planner/Views/ProjectDetailView.swift")
        XCTAssertTrue(detail.contains("if staffRows.isEmpty && schedulingRosterStillLoading {"))
        XCTAssertTrue(detail.contains("Text(\"Loading people…\")"))
    }
}
