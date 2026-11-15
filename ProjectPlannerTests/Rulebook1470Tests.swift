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

    // MARK: Review of #234 item 6 — the rest of web's 1.47.0 cases, through the iOS mappers

    private let managerUUID = UUID(uuidString: "8B1E2D3C-4B5A-4978-8695-A4B3C2D1E0F3")!

    private func labour(
        id: UUID? = nil, start: String = "07:00", end: String = "16:00",
        breakRemoved: Bool = false, ot: Double? = nil, written: Date? = nil
    ) -> Booking {
        Booking(
            id: id ?? bookingUUID,
            operativeId: operativeUUID,
            projectId: jobUUID,
            date: day,
            timeSlot: .customHours,
            bookedBy: "TEST-Manager",
            workStartTime: start,
            workEndTime: end,
            isBreakRemoved: breakRemoved,
            otMultiplierOverride: ot,
            createdAt: written ?? signedAt.addingTimeInterval(-86_400),
            updatedAt: written ?? signedAt.addingTimeInterval(-86_400)
        )
    }

    /// A signed line with no booking fingerprint (a sheet signed before 1.46.0), or with one (`fingerprint`).
    private func snapshotLine(_ id: UUID, fingerprint: String?, reviewPartOf: String? = nil, suffix: String = "normal") -> TimesheetWeeklyReportLabourLine {
        TimesheetWeeklyReportLabourLine(
            id: "op-\(id.uuidString)-\(suffix)", date: day, jobNumber: "TEST-1", projectName: "TEST-Kitchen refit",
            locationKind: "project", details: "07:00–16:00", paidHours: 8.5, days: 1, amount: 250, isOvertime: suffix == "ot",
            decision: .approved, bookingId: "op-\(id.uuidString)", bookingFingerprint: fingerprint,
            reviewPartOf: reviewPartOf, isPayeDay: false, isLeave: false
        )
    }

    /// A counter-signed sheet with only its snapshot (no 1.47.0 record).
    private func snapshotDraft(_ lines: [TimesheetWeeklyReportLabourLine]) -> TimesheetDraft {
        var draft = TimesheetDraft()
        draft.operativeSignedAt = signedAt
        draft.operativeSignedByName = "TEST-Operative"
        draft.managerSignedAt = signedAt.addingTimeInterval(60)
        draft.managerSignedByName = "TEST-Manager"
        draft.weeklyReportOverride = TimesheetWeeklyReportOverride(
            approvedAt: signedAt.addingTimeInterval(60), approvedByUserId: "TEST-manager", approvedByName: "TEST-Manager",
            selfSigned: false, lines: lines, priceWork: [], expenses: []
        )
        return draft
    }

    private func managerLine(_ booking: ManagerSiteBooking) -> TimesheetPayrollLineItem {
        TimesheetPayrollLineItem(
            id: "mgr-\(booking.id.uuidString)-normal",
            date: day,
            jobNumber: "TEST-1",
            projectName: "TEST-Kitchen refit",
            details: "07:00–16:00",
            paidHours: 8.5,
            payrollBasis: .dayRate,
            dayRate: 250,
            hourlyRate: nil,
            amount: 250,
            isPayeDay: false,
            isOvertimeLine: false,
            bookingId: "mgr-\(booking.id.uuidString)",
            bookingCreatedAt: booking.createdAt,
            bookingUpdatedAt: booking.updatedAt,
            bookingFingerprint: CanonicalBusinessEngine.payrollLineBookingFingerprint(OvertimeBookingInput(
                id: booking.id.uuidString, collection: "managerSiteBookings", personId: "", dayKey: dayKey,
                timeSlot: booking.timeSlot.rawValue, workStartTime: booking.workStartTime, workEndTime: booking.workEndTime,
                isBreakRemoved: booking.isBreakRemoved, otMultiplierOverride: booking.otMultiplierOverride, status: nil, jobId: nil
            )),
            bookingCollection: "managerSiteBookings"
        )
    }

    private func changeWithManager(
        _ draft: TimesheetDraft, lines: [TimesheetPayrollLineItem], documents: [Booking], managers: [ManagerSiteBooking]
    ) -> RulebookSignedTimesheetChange? {
        let keys = SignedTimesheetChangeInputs.documentKeys(bookings: documents, managerBookings: managers)
        return CanonicalBusinessEngine.signedTimesheetBookingChanges(
            sheet: SignedTimesheetChangeInputs.sheet(draft, keys: keys),
            liveLines: SignedTimesheetChangeInputs.liveLines(lines, keys: keys),
            liveBookings: SignedTimesheetChangeInputs.bookingDocuments(bookings: documents, managerBookings: managers),
            personIds: [personId, "TEST-user-147"],
            liveLoaded: true,
            selfSigned: false
        )
    }

    /// Web "a sheet signed before 1.46.0 (no fingerprints) never reopens for hours; a delete still counts": only an
    /// added or removed booking reopens it.
    func testASheetSignedBefore146ReopensOnlyForAddedOrRemovedBookings() throws {
        let draft = snapshotDraft([snapshotLine(bookingUUID, fingerprint: nil)])
        let longer = labour(end: "18:00", written: signedAt.addingTimeInterval(3_600))
        let hours = try XCTUnwrap(change(draft, lines: [line(longer)], documents: [longer]))
        XCTAssertFalse(hours.changed, "no fingerprint: an hours change is not detectable")
        let deleted = try XCTUnwrap(change(draft, lines: [], documents: []))
        XCTAssertTrue(deleted.reopened)
        XCTAssertEqual(deleted.basis, "bookingIds")
        XCTAssertEqual(deleted.removedBookingIds.map { $0.lowercased() }, [bookingUUID.uuidString.lowercased()])
        let original = labour()
        let added = labour(id: secondUUID, start: "17:00", end: "19:00", written: signedAt.addingTimeInterval(3_600))
        let more = try XCTUnwrap(change(draft, lines: [line(original), line(added)], documents: [original, added]))
        XCTAssertTrue(more.reopened)
        XCTAssertEqual(more.basis, "bookingIds")
        XCTAssertEqual(more.addedBookingIds.map { $0.lowercased() }, [secondUUID.uuidString.lowercased()])
    }

    /// Web "(review nit) a record older than the latest signature is ignored": the snapshot is the reference.
    func testARecordOlderThanTheSignatureIsIgnored() throws {
        let original = labour()
        let short = labour(end: "12:00")
        var draft = snapshotDraft([snapshotLine(bookingUUID, fingerprint: fingerprint(original))])
        XCTAssertTrue(SignedTimesheetChanges.stampSignedBookings(on: &draft, lines: [line(short)], bookings: [short], managerBookings: []))
        draft.operativeSignedBookingsAt = signedAt.addingTimeInterval(1)
        draft.operativeSignedBookingsAtPending = nil
        // An older app signed again a day later without writing a record.
        draft.operativeSignedAt = signedAt.addingTimeInterval(86_400)
        let result = try XCTUnwrap(change(draft, lines: [line(original)], documents: [original]))
        XCTAssertFalse(result.changed, "the stale record (07:00–12:00) is not the reference")
    }

    /// Web "(second review 3) additions use the record server time, conservatively while it is pending": a booking
    /// written 5 minutes before a fast device's signature is still an addition.
    func testABookingWrittenFiveMinutesBeforeAFastDevicesSignatureIsAnAddition() throws {
        let original = labour()
        var draft = TimesheetDraft()
        draft.operativeSignedAt = signedAt
        draft.operativeSignedByName = "TEST-Operative"
        XCTAssertTrue(SignedTimesheetChanges.stampSignedBookings(on: &draft, lines: [line(original)], bookings: [original], managerBookings: []))
        XCTAssertNil(draft.operativeSignedBookingsAt, "the server time is pending")
        let unseen = labour(id: secondUUID, start: "17:00", end: "19:00", written: signedAt.addingTimeInterval(-300))
        let pending = try XCTUnwrap(change(draft, lines: [line(original), line(unseen)], documents: [original, unseen]))
        XCTAssertEqual(pending.addedBookingIds.map { $0.lowercased() }, [secondUUID.uuidString.lowercased()])
        // The server time came back 8 minutes earlier than the (fast) device clock.
        draft.operativeSignedBookingsAt = signedAt.addingTimeInterval(-480)
        draft.operativeSignedBookingsAtPending = nil
        let server = try XCTUnwrap(change(draft, lines: [line(original), line(unseen)], documents: [original, unseen]))
        XCTAssertEqual(server.addedBookingIds.map { $0.lowercased() }, [secondUUID.uuidString.lowercased()])
    }

    /// Web "(second review) a labour booking moved to the manager schedule reopens (removed + added)".
    func testALabourBookingMovedToTheManagerScheduleReopens() throws {
        let original = labour()
        let draft = signedDraft([original])
        let moved = ManagerSiteBooking(
            id: managerUUID, userId: "TEST-user-147", date: day, timeSlot: .customHours, locationType: .project,
            locationId: jobUUID, workStartTime: "07:00", workEndTime: "16:00",
            createdAt: signedAt.addingTimeInterval(3_600), updatedAt: signedAt.addingTimeInterval(3_600)
        )
        let result = try XCTUnwrap(changeWithManager(draft, lines: [managerLine(moved)], documents: [], managers: [moved]))
        XCTAssertTrue(result.reopened)
        XCTAssertEqual(result.waitingFor, "person")
        XCTAssertEqual(result.removedBookingIds.map { $0.lowercased() }, [bookingUUID.uuidString.lowercased()])
        XCTAssertEqual(result.addedBookingIds.map { $0.lowercased() }, [managerUUID.uuidString.lowercased()])
    }

    /// Web "(second review) … overtime rate and break toggle do" reopen.
    func testAnOvertimeRateChangeReopensTheSheet() throws {
        let original = labour()
        let draft = signedDraft([original])
        let rated = labour(ot: 2, written: signedAt.addingTimeInterval(3_600))
        let result = try XCTUnwrap(change(draft, lines: [line(rated)], documents: [rated]))
        XCTAssertTrue(result.reopened)
        XCTAssertEqual(result.changedBookingIds.map { $0.lowercased() }, [bookingUUID.uuidString.lowercased()])
    }

    func testABreakToggleChangeReopensTheSheet() throws {
        let original = labour()
        let draft = signedDraft([original])
        let noBreak = labour(breakRemoved: true, written: signedAt.addingTimeInterval(3_600))
        let result = try XCTUnwrap(change(draft, lines: [line(noBreak)], documents: [noBreak]))
        XCTAssertTrue(result.reopened)
        XCTAssertEqual(result.changedBookingIds.map { $0.lowercased() }, [bookingUUID.uuidString.lowercased()])
    }

    /// Web "(second review) an Edit hours part (reviewPartOf) alone never reopens".
    func testAnEditHoursPartAloneNeverReopens() throws {
        let original = labour()
        let fp = fingerprint(original)
        let draft = snapshotDraft([
            snapshotLine(bookingUUID, fingerprint: fp),
            snapshotLine(bookingUUID, fingerprint: fp, reviewPartOf: "op-\(bookingUUID.uuidString)-normal", suffix: "ot"),
        ])
        let result = try XCTUnwrap(change(draft, lines: [line(original)], documents: [original]))
        XCTAssertFalse(result.changed)
    }

    /// Review of #234 item 4: `invoiceGeneratedAt` reaches the rule. An `exportedAt` written with web's invoice (within
    /// `TIMESHEET_INVOICE_EXPORT_LEFTOVER_MS`) is not an export (`resolveTimesheetExportedAtMs`), on the status fields and
    /// in the booking-change answer alike.
    func testAnInvoiceLeftoverExportIsNotAnExport() throws {
        var draft = signedDraft([labour()])
        draft.managerSignedAt = signedAt.addingTimeInterval(60)
        draft.managerSignedByName = "TEST-Manager"
        draft.exportedAt = signedAt.addingTimeInterval(120)
        XCTAssertTrue(TimesheetApprovalPolicy.isExported(draft))
        XCTAssertEqual(try XCTUnwrap(change(draft, lines: [line(labour())], documents: [labour()])).exported, true)
        draft.invoiceGeneratedAt = signedAt.addingTimeInterval(110)
        XCTAssertFalse(TimesheetApprovalPolicy.isExported(draft), "within the leftover window of the invoice")
        XCTAssertEqual(try XCTUnwrap(change(draft, lines: [line(labour())], documents: [labour()])).exported, false)
    }

    /// Review of #234 item 2: the list memo is keyed by the people and working-hours content, not by counts.
    func testTheListMemoKeyFollowsAnEmailOrWorkingHoursChange() {
        let user = LogicFixtures.selfEmployedUser(id: "TEST-user-147", email: "a@example.com")
        let operative = LogicFixtures.operative(id: operativeUUID, email: "a@example.com")
        let before = SignedTimesheetChangeContext.peopleStamp(user: user, operatives: [operative], users: [user])
        var renamed = operative
        renamed.email = "b@example.com"
        XCTAssertNotEqual(before, SignedTimesheetChangeContext.peopleStamp(user: user, operatives: [renamed], users: [user]))
        var moved = user
        moved.email = "b@example.com"
        XCTAssertNotEqual(before, SignedTimesheetChangeContext.peopleStamp(user: moved, operatives: [operative], users: [moved]))
        var organization = Organization(firestoreDocumentId: org, name: "TEST-Company 147")
        let hoursBefore = SignedTimesheetChangeContext.organizationStamp(organization)
        organization.settings.payrollTimePolicy.standardDayEnd = "17:00"
        XCTAssertNotEqual(hoursBefore, SignedTimesheetChangeContext.organizationStamp(organization))
        var options = Organization(firestoreDocumentId: org, name: "TEST-Company 147")
        options.settings.myScheduleOptions.showOffice.toggle()
        XCTAssertNotEqual(hoursBefore, SignedTimesheetChangeContext.organizationStamp(options))
    }

    /// Re-review of #234 (B): a signed sheet whose bookings failed to load, or whose operatives list stopped without
    /// finishing, says it cannot check right now (with Retry) — never "Checking…" for ever.
    func testTheCheckSaysUnavailableWhenTheBookingsFailOrTheOperativesStall() {
        typealias A = SignedTimesheetCheckAvailability
        XCTAssertTrue(A.unavailable(bookingsFailed: true, operativesLoaded: true, operativesStalled: false), "offline bookings read")
        XCTAssertFalse(A.unavailable(bookingsFailed: false, operativesLoaded: false, operativesStalled: false), "still loading: checking")
        XCTAssertTrue(A.unavailable(bookingsFailed: false, operativesLoaded: false, operativesStalled: true))
        XCTAssertFalse(A.unavailable(bookingsFailed: false, operativesLoaded: true, operativesStalled: true))
        // The operatives list: loading is not stalled; finished for another organisation, never finished, or timed out is.
        XCTAssertFalse(A.operativesStalled(isLoading: true, finishedLoadOrganizationId: nil, errorMessage: nil, organizationId: org))
        XCTAssertFalse(A.operativesStalled(isLoading: false, finishedLoadOrganizationId: org, errorMessage: nil, organizationId: org))
        XCTAssertTrue(A.operativesStalled(isLoading: false, finishedLoadOrganizationId: nil, errorMessage: nil, organizationId: org))
        XCTAssertTrue(A.operativesStalled(isLoading: false, finishedLoadOrganizationId: "TEST-other", errorMessage: nil, organizationId: org))
        XCTAssertTrue(A.operativesStalled(isLoading: false, finishedLoadOrganizationId: org, errorMessage: "Loading timed out.", organizationId: org))
        XCTAssertFalse(A.operativesStalled(isLoading: false, finishedLoadOrganizationId: nil, errorMessage: nil, organizationId: nil))
        XCTAssertTrue(A.unavailableMessage.contains("Can't check the bookings"))
        XCTAssertFalse(A.unavailableMessage.contains("Checking"))
    }
}
