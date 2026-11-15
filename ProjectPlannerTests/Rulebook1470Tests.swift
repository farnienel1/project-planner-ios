import XCTest
import FirebaseFirestore
@testable import Project_Planner

/// RULEBOOK 1.47.0 §8 (owner decision 15 Nov, answer 4.2 = (a)): a signed timesheet reopens when its bookings change.
/// Everything goes through `CanonicalBusinessEngine` (`signedTimesheetBookingChanges`, `signedTimesheetBookingRecord`,
/// `signedTimesheetActions`, `timesheetListBucket(…, change)`); the iOS inputs are built by `SignedTimesheetChangeInputs`
/// from the app's own models. Expected values were checked in node against the packed `canonical-business.js` this
/// branch mirrors (web `lib/canonical/canonical.test.ts` and `lib/timesheets/timesheetBookingChanges.test.ts`).
@MainActor
final class Rulebook1470Tests: XCTestCase {
    private let org = "TEST-org-147"
    private let dayKey = "2026-11-18" // a Wednesday
    private let bookingUUID = UUID(uuidString: "6F1E2D3C-4B5A-4978-8695-A4B3C2D1E0F1")!
    private let secondUUID = UUID(uuidString: "7A1E2D3C-4B5A-4978-8695-A4B3C2D1E0F2")!
    private let operativeUUID = UUID(uuidString: "11111111-2222-4333-8444-555555555555")!
    private let jobUUID = UUID(uuidString: "99999999-8888-4777-8666-555555555555")!
    private let otherJobUUID = UUID(uuidString: "99999999-8888-4777-8666-444444444444")!
    /// The signature instant (well after the booking was written).
    private let signedAt = Date(timeIntervalSince1970: 1_795_168_800)

    override func setUp() {
        super.setUp()
        OrganizationRulebookContext.update(from: Organization(firestoreDocumentId: org, name: "TEST-Company 147"))
    }

    override func tearDown() {
        OrganizationRulebookContext.update(from: nil)
        super.tearDown()
    }

    private var day: Date { OrganizationRulebookContext.date(fromDayKey: dayKey)! }

    private var personId: String { Booking.storedOperativeId(for: operativeUUID) }

    private func booking(
        id: UUID? = nil,
        start: String = "07:00",
        end: String = "16:00",
        status: BookingStatus = .confirmed,
        operative: UUID? = nil,
        job: UUID? = nil,
        written: Date? = nil
    ) -> Booking {
        Booking(
            id: id ?? bookingUUID,
            operativeId: operative ?? operativeUUID,
            projectId: job ?? jobUUID,
            date: day,
            timeSlot: .customHours,
            bookedBy: "TEST-Manager",
            status: status,
            workStartTime: start,
            workEndTime: end,
            createdAt: written ?? signedAt.addingTimeInterval(-86_400),
            updatedAt: written ?? signedAt.addingTimeInterval(-86_400)
        )
    }

    private func fingerprint(_ booking: Booking, slot: String? = nil) -> String? {
        CanonicalBusinessEngine.payrollLineBookingFingerprint(
            OvertimeBookingInput(
                id: booking.id.uuidString,
                collection: "bookings",
                personId: "",
                dayKey: dayKey,
                timeSlot: slot ?? booking.timeSlot.rawValue,
                workStartTime: booking.workStartTime,
                workEndTime: booking.workEndTime,
                isBreakRemoved: booking.isBreakRemoved,
                otMultiplierOverride: booking.otMultiplierOverride,
                status: nil,
                jobId: nil
            )
        )
    }

    /// The collector's standard line of `booking` (only the fields the rule reads matter here).
    private func line(_ booking: Booking, isPayeDay: Bool = false, slot: String? = nil) -> TimesheetPayrollLineItem {
        TimesheetPayrollLineItem(
            id: "op-\(booking.id.uuidString)-normal",
            date: day,
            jobNumber: "TEST-1",
            projectName: "TEST-Kitchen refit",
            details: "\(booking.workStartTime ?? "")–\(booking.workEndTime ?? "")",
            paidHours: 8.5,
            payrollBasis: .dayRate,
            dayRate: 250,
            hourlyRate: nil,
            amount: 250,
            isPayeDay: isPayeDay,
            isOvertimeLine: false,
            bookingId: "op-\(booking.id.uuidString)",
            bookingCreatedAt: booking.createdAt,
            bookingUpdatedAt: booking.updatedAt,
            bookingFingerprint: fingerprint(booking, slot: slot),
            bookingCollection: "bookings"
        )
    }

    /// A draft the person signed against `signed` (with the 1.47.0 record written with the signature).
    private func signedDraft(_ signed: [Booking], exported: Bool = false) -> TimesheetDraft {
        var draft = TimesheetDraft()
        draft.operativeSignedAt = signedAt
        draft.operativeSignedByName = "TEST-Operative"
        XCTAssertTrue(SignedTimesheetChanges.stampSignedBookings(
            on: &draft, lines: signed.map { line($0) }, bookings: signed, managerBookings: []
        ))
        draft.operativeSignedBookingsAt = signedAt.addingTimeInterval(1)
        draft.operativeSignedBookingsAtPending = nil
        if exported {
            draft.managerSignedAt = signedAt.addingTimeInterval(60)
            draft.managerSignedByName = "TEST-Manager"
            draft.exportedAt = signedAt.addingTimeInterval(120)
        }
        return draft
    }

    private func change(
        _ draft: TimesheetDraft,
        lines: [TimesheetPayrollLineItem],
        documents: [Booking],
        personIds: [String]? = nil,
        liveLoaded: Bool = true,
        selfSigned: Bool = false
    ) -> RulebookSignedTimesheetChange? {
        let keys = SignedTimesheetChangeInputs.documentKeys(bookings: documents, managerBookings: [])
        return CanonicalBusinessEngine.signedTimesheetBookingChanges(
            sheet: SignedTimesheetChangeInputs.sheet(draft, keys: keys),
            liveLines: SignedTimesheetChangeInputs.liveLines(lines, keys: keys),
            liveBookings: SignedTimesheetChangeInputs.bookingDocuments(bookings: documents, managerBookings: []),
            personIds: personIds ?? [personId],
            liveLoaded: liveLoaded,
            selfSigned: selfSigned
        )
    }

    // MARK: Texts

    func testThePopupTextIsTheOwnersWordsFromTheScript() {
        XCTAssertEqual(
            CanonicalBusinessEngine.constant("SIGNED_TIMESHEET_CHANGED_MESSAGE", as: String.self),
            "One or more bookings have changed since you signed your timesheet. Please review and sign again, or speak to your line manager if something isn't correct."
        )
        XCTAssertEqual(
            CanonicalBusinessEngine.signedTimesheetChangedMessage,
            "One or more bookings have changed since you signed your timesheet. Please review and sign again, or speak to your line manager if something isn't correct."
        )
        XCTAssertEqual(CanonicalBusinessEngine.signedTimesheetChangedLabel, "Bookings changed since you signed")
        XCTAssertEqual(CanonicalBusinessEngine.signedTimesheetChangedStatus, "Bookings changed — sign again")
        XCTAssertEqual(
            CanonicalBusinessEngine.signedTimesheetExportSkippedMessage,
            "Not exported — bookings changed since it was signed; it is back with the person to sign again."
        )
    }

    // MARK: What reopens a sheet

    func testAnUnchangedSheetIsNotChanged() throws {
        let signed = booking()
        let result = try XCTUnwrap(change(signedDraft([signed]), lines: [line(signed)], documents: [signed]))
        XCTAssertFalse(result.changed)
        XCTAssertFalse(result.reopened)
        XCTAssertNil(result.message)
    }

    func testATimeChangeReopensTheSheetForThePerson() throws {
        let signed = booking()
        let moved = booking(end: "17:00", written: signedAt.addingTimeInterval(3_600))
        let result = try XCTUnwrap(change(signedDraft([signed]), lines: [line(moved)], documents: [moved]))
        XCTAssertTrue(result.changed)
        XCTAssertTrue(result.reopened)
        XCTAssertEqual(result.waitingFor, "person")
        XCTAssertTrue(result.waitingForPerson)
        XCTAssertEqual(result.message, CanonicalBusinessEngine.signedTimesheetChangedMessage)
        XCTAssertEqual(result.changedBookingIds.map { $0.lowercased() }, [bookingUUID.uuidString.lowercased()])
    }

    func testABookingAddedAfterTheSignatureReopensTheSheet() throws {
        let signed = booking()
        let added = booking(id: secondUUID, start: "17:00", end: "19:00", written: signedAt.addingTimeInterval(3_600))
        let result = try XCTUnwrap(change(signedDraft([signed]), lines: [line(signed), line(added)], documents: [signed, added]))
        XCTAssertTrue(result.reopened)
        XCTAssertEqual(result.addedBookingIds.map { $0.lowercased() }, [secondUUID.uuidString.lowercased()])
    }

    func testADeletedBookingReopensTheSheet() throws {
        let signed = booking()
        let result = try XCTUnwrap(change(signedDraft([signed]), lines: [], documents: []))
        XCTAssertTrue(result.reopened)
        XCTAssertEqual(result.removedBookingIds.map { $0.lowercased() }, [bookingUUID.uuidString.lowercased()])
    }

    func testACancelledBookingReopensTheSheet() throws {
        let signed = booking()
        let cancelled = booking(status: .cancelled, written: signedAt.addingTimeInterval(3_600))
        let result = try XCTUnwrap(change(signedDraft([signed]), lines: [], documents: [cancelled]))
        XCTAssertTrue(result.reopened)
        XCTAssertFalse(result.removedBookingIds.isEmpty)
    }

    func testAJobChangeReopensTheSheet() throws {
        let signed = booking()
        let moved = booking(job: otherJobUUID, written: signedAt.addingTimeInterval(3_600))
        let result = try XCTUnwrap(change(signedDraft([signed]), lines: [line(moved)], documents: [moved]))
        XCTAssertTrue(result.reopened)
        XCTAssertFalse(result.changedBookingIds.isEmpty)
    }

    func testABookingGivenToSomeoneElseReopensTheSheet() throws {
        let signed = booking()
        let given = booking(operative: UUID(uuidString: "22222222-2222-4333-8444-555555555555")!, written: signedAt.addingTimeInterval(3_600))
        let result = try XCTUnwrap(change(signedDraft([signed]), lines: [], documents: [given]))
        XCTAssertTrue(result.reopened)
        XCTAssertFalse(result.removedBookingIds.isEmpty)
    }

    // MARK: What never reopens a sheet

    func testAScheduleOptionSwitchedOffDoesNotReopen() throws {
        // The collector drops the booking (a filter), its document is unchanged: not a change.
        let signed = booking()
        let result = try XCTUnwrap(change(signedDraft([signed]), lines: [], documents: [signed]))
        XCTAssertFalse(result.changed)
    }

    func testARosterOrEmailChangeThatHidesTheBookingDoesNotReopen() throws {
        // The person's operatives row unlinked / email changed: the collector no longer finds the booking, its
        // document still names one of their ids.
        let signed = booking()
        let result = try XCTUnwrap(change(signedDraft([signed]), lines: [], documents: [signed], personIds: [personId, "TEST-uid"]))
        XCTAssertFalse(result.changed)
    }

    func testTentativeToConfirmedIsNotAChange() throws {
        let signed = booking(status: .tentative)
        let confirmed = booking(status: .confirmed, written: signedAt.addingTimeInterval(3_600))
        let result = try XCTUnwrap(change(signedDraft([signed]), lines: [line(confirmed)], documents: [confirmed]))
        XCTAssertFalse(result.changed)
    }

    func testCustomAndCustomHoursSpellingsAreTheSameBooking() throws {
        let signed = booking()
        let result = try XCTUnwrap(change(signedDraft([signed]), lines: [line(signed, slot: "CUSTOM")], documents: [signed]))
        XCTAssertFalse(result.changed)
    }

    func testAPayeDayLineNeverCounts() throws {
        let signed = booking()
        let payeDay = booking(id: secondUUID, start: "17:00", end: "19:00", written: signedAt.addingTimeInterval(3_600))
        let result = try XCTUnwrap(change(
            signedDraft([signed]), lines: [line(signed), line(payeDay, isPayeDay: true)], documents: [signed, payeDay]
        ))
        XCTAssertFalse(result.changed)
    }

    func testNothingReadsAsChangedBeforeTheWholePayRunLoaded() throws {
        let signed = booking()
        let result = try XCTUnwrap(change(signedDraft([signed]), lines: [], documents: [], liveLoaded: false))
        XCTAssertFalse(result.changed)
        XCTAssertFalse(result.reopened)
    }

    // MARK: Exported sheets stay frozen

    func testAnExportedSheetIsFrozenWithAWarningOnly() throws {
        let signed = booking()
        let moved = booking(end: "17:00", written: signedAt.addingTimeInterval(3_600))
        let draft = signedDraft([signed], exported: true)
        let result = try XCTUnwrap(change(draft, lines: [line(moved)], documents: [moved]))
        XCTAssertTrue(result.changed)
        XCTAssertTrue(result.exported)
        XCTAssertFalse(result.reopened)
        XCTAssertNil(result.message)
        XCTAssertEqual(
            result.reviewerMessage,
            CanonicalBusinessEngine.constant("SIGNED_TIMESHEET_EXPORTED_CHANGED_MESSAGE", as: String.self)
        )
        let fields = try XCTUnwrap(TimesheetDraftStore.statusFields(for: draft))
        XCTAssertEqual(CanonicalBusinessEngine.timesheetListBucket(fields, hasLineManager: true, change: result), "exported")
    }

    // MARK: Buckets and actions

    func testBucketsFollowTheChange() throws {
        var draft = signedDraft([booking()])
        draft.managerSignedAt = signedAt.addingTimeInterval(60)
        draft.managerSignedByName = "TEST-Manager"
        let fields = try XCTUnwrap(TimesheetDraftStore.statusFields(for: draft))
        XCTAssertEqual(CanonicalBusinessEngine.timesheetListBucket(fields, hasLineManager: true, change: nil), "signed")

        let moved = booking(end: "17:00", written: signedAt.addingTimeInterval(3_600))
        let reopened = try XCTUnwrap(change(draft, lines: [line(moved)], documents: [moved]))
        XCTAssertTrue(reopened.waitingForPerson)
        XCTAssertEqual(CanonicalBusinessEngine.timesheetListBucket(fields, hasLineManager: true, change: reopened), "unsigned")
        let actions = CanonicalBusinessEngine.signedTimesheetActions(reopened)
        XCTAssertTrue(actions.personMaySignAgain)
        XCTAssertFalse(actions.lineManagerMayCounterSign)
        XCTAssertFalse(actions.mayExport)
        XCTAssertFalse(actions.mayGenerateInvoice)
        XCTAssertTrue(actions.rebuildSnapshot)
    }

    func testAfterThePersonSignsAgainItWaitsForTheLineManager() throws {
        let original = booking()
        let moved = booking(end: "17:00", written: signedAt.addingTimeInterval(3_600))
        var draft = signedDraft([original])
        // Line manager counter-signed against the original booking (the snapshot holds it).
        draft.managerSignedAt = signedAt.addingTimeInterval(60)
        draft.managerSignedByName = "TEST-Manager"
        draft.weeklyReportOverride = TimesheetWeeklyReportOverride(
            approvedAt: signedAt.addingTimeInterval(60),
            approvedByUserId: "TEST-manager",
            approvedByName: "TEST-Manager",
            selfSigned: false,
            lines: [TimesheetWeeklyReportLabourLine(
                id: "op-\(bookingUUID.uuidString)-normal", date: day, jobNumber: "TEST-1", projectName: "TEST-Kitchen refit",
                locationKind: "project", details: "07:00–16:00", paidHours: 8.5, days: 1, amount: 250, isOvertime: false,
                decision: .approved, bookingId: bookingUUID.uuidString, bookingFingerprint: fingerprint(original),
                isPayeDay: false, isLeave: false
            )],
            priceWork: [],
            expenses: []
        )
        // The person re-signs the moved booking: the record is the live bookings.
        draft.operativeSignedAt = signedAt.addingTimeInterval(7_200)
        XCTAssertTrue(SignedTimesheetChanges.stampSignedBookings(on: &draft, lines: [line(moved)], bookings: [moved], managerBookings: []))
        draft.operativeSignedBookingsAt = signedAt.addingTimeInterval(7_201)
        let result = try XCTUnwrap(change(draft, lines: [line(moved)], documents: [moved]))
        XCTAssertTrue(result.reopened)
        XCTAssertEqual(result.waitingFor, "lineManager")
        XCTAssertEqual(
            result.reviewerMessage,
            CanonicalBusinessEngine.constant("SIGNED_TIMESHEET_CHANGED_COUNTERSIGN_MESSAGE", as: String.self)
        )
        let fields = try XCTUnwrap(TimesheetDraftStore.statusFields(for: draft))
        XCTAssertEqual(CanonicalBusinessEngine.timesheetListBucket(fields, hasLineManager: true, change: result), "awaiting")
        XCTAssertTrue(CanonicalBusinessEngine.signedTimesheetActions(result).lineManagerMayCounterSign)
    }

    func testANotReopenedSheetKeepsEveryAction() {
        let actions = CanonicalBusinessEngine.signedTimesheetActions(nil)
        XCTAssertTrue(actions.mayExport)
        XCTAssertTrue(actions.mayGenerateInvoice)
        XCTAssertTrue(actions.lineManagerMayCounterSign)
        XCTAssertFalse(actions.rebuildSnapshot)
    }

    // MARK: The stored record

    func testTheRecordHoldsPersonAndPlaceAndTheSignatureItBelongsTo() throws {
        let signed = booking()
        var draft = TimesheetDraft()
        draft.operativeSignedAt = signedAt
        XCTAssertTrue(SignedTimesheetChanges.stampSignedBookings(on: &draft, lines: [line(signed)], bookings: [signed], managerBookings: []))
        let row = try XCTUnwrap(draft.operativeSignedBookings?.first)
        XCTAssertEqual(row.bookingId.lowercased(), bookingUUID.uuidString.lowercased())
        XCTAssertEqual(row.collection, "bookings")
        XCTAssertEqual(row.personId.lowercased(), personId.lowercased())
        XCTAssertEqual(row.place, "job|\(jobUUID.uuidString.lowercased())")
        XCTAssertEqual(row.fingerprint, fingerprint(signed))
        XCTAssertEqual(draft.operativeSignedBookingsSignedAt, signedAt)
        XCTAssertNil(draft.operativeSignedBookingsAt, "server time, written with the save")
        XCTAssertEqual(draft.operativeSignedBookingsAtPending, true)
    }

    func testTheRecordRoundTripsThroughTheStoredShape() throws {
        var draft = signedDraft([booking()])
        let map = TimesheetDraftStore.asFirestoreMap(draft)
        let rows = try XCTUnwrap(map["operativeSignedBookings"] as? [[String: Any]])
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(Set(rows[0].keys), ["bookingId", "collection", "fingerprint", "personId", "place"])
        XCTAssertTrue(map["operativeSignedBookingsSignedAt"] is Timestamp)
        XCTAssertTrue(map["operativeSignedBookingsAt"] is Timestamp)
        let back = try XCTUnwrap(TimesheetDraftStore.decodeFirestoreMap(map))
        XCTAssertEqual(back.operativeSignedBookings, draft.operativeSignedBookings)
        XCTAssertEqual(back.operativeSignedBookingsSignedAt, draft.operativeSignedBookingsSignedAt)
        XCTAssertEqual(back.operativeSignedBookingsAt, draft.operativeSignedBookingsAt)

        // Clearing the signature clears the record with it (written as null on the person's own save).
        TimesheetApprovalPolicy.clearSignatures(draft: &draft)
        XCTAssertNil(draft.operativeSignedBookings)
        let cleared = TimesheetDraftStore.asFirestoreMap(draft)
        XCTAssertTrue(cleared["operativeSignedBookings"] is NSNull)
    }

    func testASheetSignedBefore147KeepsItsStoredShape() throws {
        var draft = TimesheetDraft()
        draft.operativeSignedAt = signedAt
        draft.operativeSignedByName = "TEST-Operative"
        let map = TimesheetDraftStore.asFirestoreMap(draft)
        XCTAssertNil(map["operativeSignedBookings"], "never written onto a signed sheet that has none")
        XCTAssertNil(map["operativeSignedBookingsAt"])
    }

    func testADraftCachedBefore147StillDecodes() throws {
        let cached = Data(#"{"expenseEntries":[],"priceWorkEntries":[],"payrollLineReviews":{},"managerNote":""}"#.utf8)
        let draft = try JSONDecoder().decode(TimesheetDraft.self, from: cached)
        XCTAssertNil(draft.operativeSignedBookings)
        XCTAssertNil(draft.operativeSignedBookingsAt)
    }

    func testTheOwnerMayWriteTheRecordFields() throws {
        let kept = try XCTUnwrap(CanonicalBusinessEngine.timesheetOwnerWritableKeys(
            TimesheetDraftStore.signedBookingsKeys + ["operativeSignedAt"],
            subjectHasLineManager: true,
            managerSigned: false
        ))
        for key in TimesheetDraftStore.signedBookingsKeys { XCTAssertTrue(kept.contains(key), key) }
    }

    // MARK: Booking delete warning (1.47.0 §2 text)

    func testTheBookingDeleteWarningSaysAnUnexportedSheetGoesBack() {
        XCTAssertEqual(
            CanonicalBusinessEngine.constant("BOOKING_DELETE_SIGNED_TIMESHEET_WARNING", as: String.self),
            "This day is on a signed timesheet. If it has not been exported, it goes back to the person to review and sign again. An exported timesheet does not change."
        )
    }
}
