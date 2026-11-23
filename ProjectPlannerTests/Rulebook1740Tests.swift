//
//  Rulebook1740Tests.swift
//  RULEBOOK 1.74.0 §8 / §13 (owner decisions and reports 23 Nov; web `canonical.test.ts` `timesheetLineDisplayOrder`,
//  `timesheetReviewerBookingEditRecord`). The line manager's ⚙ / ✕ is recorded on the sheet so it stays with them; lines
//  are shown booking by booking and an all-overtime booking's empty standard line is not shown. Every answer comes from
//  the packed script through `CanonicalBusinessEngine`.
//

import XCTest
@testable import Project_Planner

@MainActor
final class Rulebook1740Tests: XCTestCase {
    private let signedAt = Date(timeIntervalSince1970: 1_795_514_400) // 24 Nov 2026 10:00 UTC

    override func setUp() {
        super.setUp()
        OrganizationRulebookContext.update(from: Organization(firestoreDocumentId: "TEST-ORG-174", name: "TEST-Company 174"))
    }

    override func tearDown() {
        OrganizationRulebookContext.update(from: nil)
        super.tearDown()
    }

    private func storedBooking(end: String = "19:00") -> [String: Any] {
        [
            "id": "B1",
            "collection": "bookings",
            "date": Date(timeIntervalSince1970: 1_795_392_000).timeIntervalSince1970 * 1000, // 23 Nov 2026
            "operativeId": "OP1",
            "projectId": "J1",
            "timeSlot": "CUSTOM_HOURS",
            "workStartTime": "07:00",
            "workEndTime": end,
            "status": "Confirmed",
        ]
    }

    // MARK: Copy

    func testReviewCopyIsTheRulebooks() {
        XCTAssertEqual(
            CanonicalBusinessEngine.timesheetReviewBookingUpdatedMessage,
            "Booking updated. Keep reviewing — the person sees the changes when you counter-sign."
        )
        XCTAssertTrue(CanonicalBusinessEngine.timesheetReviewBookingNotRecordedMessage.hasPrefix("Booking updated, but the timesheet could not record it"))
        XCTAssertEqual(CanonicalBusinessEngine.timesheetReviewerBookingEditsField, "reviewerBookingEdits")
        XCTAssertTrue(CanonicalBusinessEngine.timesheetReviewEditBookingNote.contains("the person sees the change when you counter-sign"))
    }

    // MARK: The reviewer's record

    func testRecordIsMadeOnlyForASignedUnexportedSheet() {
        guard let before = CanonicalBusinessEngine.timesheetReviewBookingDocument(collection: "bookings", id: "B1", data: storedBooking()),
              let after = CanonicalBusinessEngine.timesheetReviewBookingAfterEdit(before: before, set: ["workEndTime": "16:00"], remove: [])
        else { return XCTFail("script did not answer") }
        XCTAssertEqual(after["workEndTime"] as? String, "16:00")
        XCTAssertEqual(after["dayKey"] as? String, "2026-11-23")

        let signedMs = signedAt.timeIntervalSince1970 * 1000
        let record = CanonicalBusinessEngine.timesheetReviewerBookingEditRecord(
            sheet: ["operativeSignedAt": signedMs, "exportedAt": NSNull()],
            collection: "bookings", bookingId: "B1", after: after, deleted: false, editedBy: "LM"
        )
        XCTAssertEqual(record?.key, "bookings__b1")
        XCTAssertEqual(record?.value["deleted"] as? Bool, false)
        XCTAssertEqual((record?.value["forSignedAtMs"] as? NSNumber)?.doubleValue, signedMs)

        // Not signed by the person: nothing to record. Exported: frozen, nothing to record.
        XCTAssertNil(CanonicalBusinessEngine.timesheetReviewerBookingEditRecord(
            sheet: ["operativeSignedAt": NSNull()], collection: "bookings", bookingId: "B1", after: after, deleted: false, editedBy: "LM"
        ))
        XCTAssertNil(CanonicalBusinessEngine.timesheetReviewerBookingEditRecord(
            sheet: ["operativeSignedAt": signedMs, "exportedAt": signedMs + 1000],
            collection: "bookings", bookingId: "B1", after: nil, deleted: true, editedBy: "LM"
        ))
    }

    func testRecorderNeedsAStoredSheetAndTheNoticeFollowsIt() {
        var draft = TimesheetDraft()
        draft.operativeSignedAt = signedAt
        // No stored document: nothing can be recorded, and nothing really goes back (the sheet is not stored).
        XCTAssertNil(TimesheetReviewerEditRecorder.record(
            draft: draft, collection: "bookings", bookingId: "B1", booking: storedBooking(),
            write: (set: ["workEndTime": "16:00"], remove: []), editedBy: "LM"
        ))
        XCTAssertEqual(TimesheetReviewerEditRecorder.notice(recorded: false, draft: draft), CanonicalBusinessEngine.timesheetReviewBookingUpdatedMessage)

        draft.versionDocumentId = "timesheet_OP1_1795392000"
        let record = TimesheetReviewerEditRecorder.record(
            draft: draft, collection: "bookings", bookingId: "B1", booking: storedBooking(),
            write: (set: ["workEndTime": "16:00"], remove: []), editedBy: "LM"
        )
        XCTAssertEqual(record?.sheetDocumentId, "timesheet_OP1_1795392000")
        XCTAssertEqual(record?.edit.key, "bookings__b1")
        let deleted = TimesheetReviewerEditRecorder.record(
            draft: draft, collection: "bookings", bookingId: "B1", booking: nil, write: nil, editedBy: "LM"
        )
        XCTAssertEqual(deleted?.edit.value["deleted"] as? Bool, true)
        // Signed, stored, not exported and nothing recorded: it really has gone back to the person.
        XCTAssertEqual(TimesheetReviewerEditRecorder.notice(recorded: false, draft: draft), CanonicalBusinessEngine.timesheetReviewBookingNotRecordedMessage)
        XCTAssertEqual(TimesheetReviewerEditRecorder.notice(recorded: true, draft: draft), CanonicalBusinessEngine.timesheetReviewBookingUpdatedMessage)
    }

    func testRecordReachesTheChangeRuleButNeverADraftSave() {
        var draft = TimesheetDraft()
        draft.operativeSignedAt = signedAt
        draft.versionDocumentId = "timesheet_OP1_1795392000"
        guard let record = TimesheetReviewerEditRecorder.record(
            draft: draft, collection: "bookings", bookingId: "B1", booking: storedBooking(),
            write: (set: ["workEndTime": "16:00"], remove: []), editedBy: "LM"
        ) else { return XCTFail("no record") }
        TimesheetReviewerBookingEdits.adding(record.edit, to: &draft)
        let sheet = SignedTimesheetChangeInputs.sheet(draft, keys: [:])
        let edits = sheet["reviewerBookingEdits"] as? [String: Any]
        XCTAssertNotNil(edits?["bookings__b1"])
        // The person's (or reviewer's) draft save never writes it: it is not one of the saved fields.
        XCTAssertNil(TimesheetDraftStore.asFirestoreMap(draft)["reviewerBookingEdits"])
    }

    // MARK: Line order

    private struct Line {
        let id: String
        let booking: String
        let overtime: Bool
        let hours: Double
        let amount: Double
        let start: String
        let end: String
        let details: String
    }

    func testLinesAreBookingByBookingAndTheEmptyStandardLineIsHidden() {
        let day = Date(timeIntervalSince1970: 1_795_392_000 + 12 * 3600)
        let lines = [
            Line(id: "op-B-normal", booking: "B", overtime: false, hours: 6, amount: 150, start: "10:00", end: "19:00", details: "10:00–16:00"),
            Line(id: "op-B-ot", booking: "B", overtime: true, hours: 4.5, amount: 60, start: "10:00", end: "19:00", details: "16:00–19:00"),
            // A: all overtime (05:00–07:00) — its 0h / £0 standard line is not shown.
            Line(id: "op-A-normal", booking: "A", overtime: false, hours: 0, amount: 0, start: "05:00", end: "07:00", details: ""),
            Line(id: "op-A-ot", booking: "A", overtime: true, hours: 3, amount: 40, start: "05:00", end: "07:00", details: "05:00–07:00"),
        ]
        let ordered = TimesheetLineDisplayOrder.ordered(lines) { line in
            TimesheetLineOrderInput(
                id: line.id, bookingId: "op-\(line.booking)", bookingCollection: "bookings", date: day,
                isOvertimeLine: line.overtime, paidHours: line.hours, amount: line.amount,
                bookingStartTime: line.start, bookingEndTime: line.end, details: line.details
            )
        }
        XCTAssertEqual(ordered.map(\.id), ["op-A-ot", "op-B-normal", "op-B-ot"])
        // Display only: the total of every line is unchanged, and the hidden line is £0.
        XCTAssertEqual(lines.reduce(0) { $0 + $1.amount }, ordered.reduce(0) { $0 + $1.amount })
    }
}
