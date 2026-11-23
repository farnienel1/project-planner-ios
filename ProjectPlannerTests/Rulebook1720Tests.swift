//
//  Rulebook1720Tests.swift
//  RULEBOOK 1.71.0 / 1.72.0 §8 (owner decisions 23 Nov, issue 22A / 22B, A and B; web `canonical.test.ts`
//  `timesheetReviewBookingWrites`, `timesheetLineReviewActionsAllowed`). The line manager's ✓ ✕ ⚙ on a timesheet line
//  under review: none once exported; ⚙ writes the booking; ✕ deletes it with its tombstone (standard line) or trims its
//  overtime (overtime line). Every answer comes from the packed script through `CanonicalBusinessEngine`.
//

import XCTest
@testable import Project_Planner

@MainActor
final class Rulebook1720Tests: XCTestCase {
    private let org: [String: Any] = [
        "countryCode": "GB",
        "payrollTimePolicy": [
            "standardDayStart": "07:30",
            "standardDayEnd": "16:00",
            "unpaidBreakMinutes": 30,
            "breakWindowStart": "12:00",
            "breakWindowEnd": "12:30",
            "weekdayOutsideStandardMultiplier": 1.5,
            "saturday": [
                "allHoursAtMultiplierMode": false, "definedWindowStart": "07:30", "definedWindowEnd": "14:00",
                "countsAsStandardHours": 8, "outsideWindowMultiplier": 1.5,
            ] as [String: Any],
            "sunday": ["allHoursAtMultiplierMode": true, "allHoursMultiplier": 2, "sameAsSaturday": false] as [String: Any],
        ] as [String: Any],
        "invoicing": [String: Any](),
    ]

    override func setUp() {
        super.setUp()
        OrganizationRulebookContext.update(from: Organization(firestoreDocumentId: "TEST-ORG-172", name: "TEST-Company 172"))
    }

    override func tearDown() {
        OrganizationRulebookContext.update(from: nil)
        super.tearDown()
    }

    private func booking(_ id: String, slot: String = "CUSTOM_HOURS", _ start: String?, _ end: String?, override: Double? = nil, collection: String = "bookings") -> [String: Any] {
        var row: [String: Any] = ["id": id, "collection": collection, "timeSlot": slot]
        if let start { row["workStartTime"] = start }
        if let end { row["workEndTime"] = end }
        if let override { row["otMultiplierOverride"] = override }
        return row
    }

    // MARK: 1.71.0

    func testExportedSheetOffersNoLineActions() {
        let exportedAt = Date(timeIntervalSince1970: 1_795_000_000)
        XCTAssertTrue(CanonicalBusinessEngine.timesheetLineReviewActionsAllowed([:]))
        XCTAssertFalse(CanonicalBusinessEngine.timesheetLineReviewActionsAllowed(["exportedAt": exportedAt.timeIntervalSince1970 * 1000]))
        // An `exportedAt` left by an old Generate Invoice (within a minute of `invoiceGeneratedAt`) is not an export.
        XCTAssertTrue(CanonicalBusinessEngine.timesheetLineReviewActionsAllowed([
            "exportedAt": exportedAt.timeIntervalSince1970 * 1000,
            "invoiceGeneratedAt": exportedAt.timeIntervalSince1970 * 1000,
        ]))
        var draft = TimesheetDraft()
        XCTAssertTrue(TimesheetApprovalPolicy.lineReviewActionsAllowed(draft))
        draft.exportedAt = exportedAt
        XCTAssertFalse(TimesheetApprovalPolicy.lineReviewActionsAllowed(draft))
    }

    func testCreateRevisionWordingIsTheRulebooks() {
        XCTAssertEqual(CanonicalBusinessEngine.timesheetCreateRevisionLabel, "Create revision to adjust this timesheet")
        XCTAssertTrue(CanonicalBusinessEngine.timesheetCreateRevisionHelp.hasPrefix("This timesheet has already been exported."))
    }

    // MARK: 1.72.0 — which actions a line gets

    func testLabourLineActions() {
        let all = CanonicalBusinessEngine.timesheetLabourLineReviewActions(
            sheet: [:], bookingId: "op-B1", bookingCollection: "bookings", isPayeDay: false, isLeave: false
        )
        XCTAssertEqual(all, RulebookTimesheetLabourLineReviewActions(approve: true, removeBooking: true, editBooking: true))
        let noBooking = CanonicalBusinessEngine.timesheetLabourLineReviewActions(
            sheet: [:], bookingId: nil, bookingCollection: nil, isPayeDay: false, isLeave: false
        )
        XCTAssertEqual(noBooking, RulebookTimesheetLabourLineReviewActions(approve: true, removeBooking: false, editBooking: false))
        XCTAssertEqual(CanonicalBusinessEngine.timesheetLabourLineReviewActions(
            sheet: [:], bookingId: "op-B1", bookingCollection: "bookings", isPayeDay: true, isLeave: false
        ), RulebookTimesheetLabourLineReviewActions.none)
        XCTAssertEqual(CanonicalBusinessEngine.timesheetLabourLineReviewActions(
            sheet: ["exportedAt": 1_795_000_000_000.0], bookingId: "op-B1", bookingCollection: "bookings", isPayeDay: false, isLeave: false
        ), RulebookTimesheetLabourLineReviewActions.none)
    }

    func testLineIdGivesTheBookingUuid() {
        let uuid = UUID()
        XCTAssertEqual(TimesheetPayrollLineBookingLookup.bookingId(from: "op-\(uuid.uuidString)-normal"), uuid)
        XCTAssertEqual(TimesheetPayrollLineBookingLookup.bookingId(from: "mgr-\(uuid.uuidString)-ot"), uuid)
        XCTAssertEqual(TimesheetPayrollLineBookingLookup.bookingId(from: "op-\(uuid.uuidString)"), uuid)
        XCTAssertNil(TimesheetPayrollLineBookingLookup.bookingId(from: "op-not-a-uuid-normal"))
    }

    // MARK: ⚙ writes the booking (decision A)

    func testEditWritesTheBookingTimes() throws {
        guard case let .write(collection, bookingId, set, remove, changed)? = CanonicalBusinessEngine.timesheetReviewBookingEditWrites(
            booking: booking("B1", "07:30", "16:00"),
            startTime: "07:30",
            endTime: "19:00",
            isBreakRemoved: false,
            overtimeRate: nil,
            slotWindow: nil
        ) else { return XCTFail("expected a write") }
        XCTAssertEqual(collection, "bookings")
        XCTAssertEqual(bookingId, "B1")
        XCTAssertTrue(changed)
        XCTAssertEqual(set["workEndTime"] as? String, "19:00")
        XCTAssertNil(set["otMultiplierOverride"], "a standard line never writes a rate")
        let allowed = Set(["timeSlot", "workStartTime", "workEndTime", "isBreakRemoved", "otMultiplierOverride"])
        XCTAssertTrue(Set(set.keys).isSubset(of: allowed))
        XCTAssertTrue(Set(remove).isSubset(of: allowed))
    }

    func testUnchangedFullDayAndStoredTwelveHourClockWriteNothing() {
        guard case let .write(_, _, _, _, changed)? = CanonicalBusinessEngine.timesheetReviewBookingEditWrites(
            booking: booking("B2", slot: "FULL DAY", nil, nil),
            startTime: "07:30",
            endTime: "16:00",
            isBreakRemoved: false,
            overtimeRate: nil,
            slotWindow: (start: "07:30", end: "16:00")
        ) else { return XCTFail("expected a write") }
        XCTAssertFalse(changed, "an unchanged Full day writes nothing")
        guard case let .write(_, _, _, _, clockChanged)? = CanonicalBusinessEngine.timesheetReviewBookingEditWrites(
            booking: booking("B3", "7:30 AM", "4:00 PM"),
            startTime: "07:30",
            endTime: "16:00",
            isBreakRemoved: false,
            overtimeRate: nil,
            slotWindow: nil
        ) else { return XCTFail("expected a write") }
        XCTAssertFalse(clockChanged, "stored times read with bookingClock")
    }

    func testOvertimeRateWrittenOnlyWhenChanged() {
        // Untouched: the box showed the organisation's rate and still does.
        guard case let .write(_, _, untouched, untouchedRemove, _)? = CanonicalBusinessEngine.timesheetReviewBookingEditWrites(
            booking: booking("B4", "07:30", "19:00"),
            startTime: "07:30", endTime: "19:00", isBreakRemoved: false,
            overtimeRate: (typed: 1.5, opened: 1.5, organizationMultiplier: 1.5), slotWindow: nil
        ) else { return XCTFail("expected a write") }
        XCTAssertNil(untouched["otMultiplierOverride"])
        XCTAssertFalse(untouchedRemove.contains("otMultiplierOverride"))
        // Changed to ×2.
        guard case let .write(_, _, changed, _, _)? = CanonicalBusinessEngine.timesheetReviewBookingEditWrites(
            booking: booking("B4", "07:30", "19:00"),
            startTime: "07:30", endTime: "19:00", isBreakRemoved: false,
            overtimeRate: (typed: 2, opened: 1.5, organizationMultiplier: 1.5), slotWindow: nil
        ) else { return XCTFail("expected a write") }
        XCTAssertEqual(changed["otMultiplierOverride"] as? Double, 2)
        // Back to the organisation's rate over a stored override removes it.
        guard case let .write(_, _, backSet, backRemove, backChanged)? = CanonicalBusinessEngine.timesheetReviewBookingEditWrites(
            booking: booking("B5", "07:30", "19:00", override: 2),
            startTime: "07:30", endTime: "19:00", isBreakRemoved: false,
            overtimeRate: (typed: 1.5, opened: 2, organizationMultiplier: 1.5), slotWindow: nil
        ) else { return XCTFail("expected a write") }
        XCTAssertTrue(backChanged)
        XCTAssertTrue(backRemove.contains("otMultiplierOverride") || backSet["otMultiplierOverride"] is NSNull)
    }

    func testEditRefusesUnusableTimesAndMissingBooking() {
        guard case .refused? = CanonicalBusinessEngine.timesheetReviewBookingEditWrites(
            booking: booking("B6", "07:30", "16:00"),
            startTime: "08:00", endTime: "08:00", isBreakRemoved: false, overtimeRate: nil, slotWindow: nil
        ) else { return XCTFail("equal times are refused") }
        guard case let .refused(message)? = CanonicalBusinessEngine.timesheetReviewBookingEditWrites(
            booking: ["id": "B7", "collection": "subcontractorBookings"],
            startTime: "07:30", endTime: "16:00", isBreakRemoved: false, overtimeRate: nil, slotWindow: nil
        ) else { return XCTFail("only labour and manager site bookings") }
        XCTAssertEqual(message, CanonicalBusinessEngine.timesheetReviewBookingMissingMessage)
    }

    // MARK: ✕ deletes the booking (decision B) or trims its overtime

    func testDeleteIsTheBookingAndItsTombstone() throws {
        let plan = try XCTUnwrap(CanonicalBusinessEngine.timesheetReviewBookingDelete(bookingId: "B8", collection: "bookings", deletedBy: "TEST-LM"))
        XCTAssertEqual(plan.collection, "bookings")
        XCTAssertEqual(plan.bookingId, "B8")
        XCTAssertEqual(plan.tombstone["bookingId"] as? String, "B8")
        XCTAssertEqual(plan.tombstone["collection"] as? String, "bookings")
        XCTAssertEqual(plan.tombstone["deletedBy"] as? String, "TEST-LM")
        XCTAssertEqual(plan.tombstone["deletedFrom"] as? String, "ios")
        XCTAssertNil(CanonicalBusinessEngine.timesheetReviewBookingDelete(bookingId: "B8", collection: "subcontractorBookings", deletedBy: "TEST-LM"))
    }

    func testDeleteWarningCopy() throws {
        let standard = try XCTUnwrap(CanonicalBusinessEngine.timesheetReviewDeleteBookingWarning(summary: "Mon 23 Nov · J-1042", overtimeLine: false))
        XCTAssertEqual(standard.title, "Remove this booking?")
        XCTAssertEqual(standard.confirmLabel, "Remove booking")
        XCTAssertEqual(standard.cancelLabel, "Go back")
        XCTAssertNil(standard.overtimeNote)
        let overtime = try XCTUnwrap(CanonicalBusinessEngine.timesheetReviewDeleteBookingWarning(summary: "", overtimeLine: true))
        XCTAssertNotNil(overtime.overtimeNote)
        let removal = TimesheetReviewRemoval(
            warning: standard,
            action: .delete(try XCTUnwrap(CanonicalBusinessEngine.timesheetReviewBookingDelete(bookingId: "B9", collection: "bookings", deletedBy: "TEST-LM")))
        )
        XCTAssertTrue(removal.messageText.contains("Mon 23 Nov · J-1042"))
        XCTAssertTrue(removal.messageText.contains(standard.undoNote))
    }

    func testOvertimeStrikeTrimsToTheStandardPartOrDeletes() {
        var trimInput = booking("B10", "07:30", "19:00")
        trimInput["dayKey"] = "2026-11-04"
        guard case let .trim(collection, bookingId, set, _, warning)? = CanonicalBusinessEngine.timesheetReviewOvertimeStrike(
            booking: trimInput, organization: org, summary: "Wed 4 Nov · J-1042"
        ) else { return XCTFail("a weekday booking past the day is trimmed") }
        XCTAssertEqual(collection, "bookings")
        XCTAssertEqual(bookingId, "B10")
        XCTAssertEqual(set["workEndTime"] as? String, "16:00")
        XCTAssertNil(set["otMultiplierOverride"], "the rate stays as stored")
        XCTAssertEqual(warning.title, "Remove the overtime from this booking?")
        XCTAssertTrue(warning.summary.contains("07:30–16:00"))

        var allOvertime = booking("B11", "18:00", "21:00")
        allOvertime["dayKey"] = "2026-11-02"
        guard case .delete? = CanonicalBusinessEngine.timesheetReviewOvertimeStrike(
            booking: allOvertime, organization: org, summary: ""
        ) else { return XCTFail("an all-overtime booking can only be removed") }
    }

    func testReviewBookingTextsAreTheRulebooks() {
        XCTAssertEqual(
            CanonicalBusinessEngine.timesheetReviewBookingSentBackMessage,
            "Booking updated. The timesheet has gone back to the person to review and sign again."
        )
        XCTAssertEqual(CanonicalBusinessEngine.timesheetReviewBookingMissingMessage, "This booking was deleted on another device.")
        XCTAssertTrue(CanonicalBusinessEngine.timesheetReviewEditBookingNote.hasPrefix("Saving changes the booking itself"))
        XCTAssertTrue(CanonicalBusinessEngine.timesheetReviewBookingRefusedMessage.hasPrefix("You can't change this booking"))
    }
}
