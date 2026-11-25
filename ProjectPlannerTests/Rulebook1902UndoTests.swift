//
//  Rulebook1902UndoTests.swift
//  RULEBOOK 1.90.0 §8 "Cancel changes" (owner 24 Nov; web `canonical.test.ts` "1.90.0 Cancel changes"): the reviewer's
//  edits record their before-values, the undo plan restores, re-creates and refuses without overwriting, and the Swift
//  writer turns the script's `{ seconds, nanoseconds }` back into Timestamps. Every answer comes from the packed script.
//

import XCTest
import FirebaseFirestore
@testable import Project_Planner

@MainActor
final class Rulebook1902UndoTests: XCTestCase {
    private let signed: [String: Any] = ["seconds": 1_763_400_000, "nanoseconds": 0]
    private let counter: [String: Any] = ["seconds": 1_763_500_000, "nanoseconds": 0]

    private var base: [String: Any] {
        [
            "date": ["seconds": 1_763_337_600, "nanoseconds": 0],
            "operativeId": "op1",
            "projectId": "J1",
            "timeSlot": "CUSTOM_HOURS",
            "workStartTime": "07:00",
            "status": "Confirmed",
        ]
    }

    func testEditBeforeKeepsOnlyEditFieldsAndTheWholeBookingForARemoval() throws {
        var stored = base
        stored["workEndTime"] = "19:00"
        stored["id"] = "b1"
        stored["collection"] = "bookings"
        stored["createdAt"] = 1
        let before = try XCTUnwrap(CanonicalBusinessEngine.timesheetReviewerEditBefore(data: stored, deleted: false))
        XCTAssertEqual(Set(before.keys), ["timeSlot", "workStartTime", "workEndTime"])
        let whole = try XCTUnwrap(CanonicalBusinessEngine.timesheetReviewerEditBefore(data: stored, deleted: true))
        XCTAssertNil(whole["id"])
        XCTAssertNil(whole["collection"], "the reader's collection key is never written back onto a re-created booking")
        XCTAssertNil(whole["createdAt"])
        XCTAssertEqual(whole["operativeId"] as? String, "op1")
    }

    func testUndoPlanRestoresRecreatesAndRefuses() throws {
        let sheet0: [String: Any] = ["operativeSignedAt": signed, "managerSignedAt": counter]
        var editedDoc = base
        editedDoc["workEndTime"] = "16:00"
        let edited = CanonicalBusinessEngine.timesheetReviewBookingDocument(collection: "bookings", id: "b1", data: editedDoc)
        let r1 = try XCTUnwrap(CanonicalBusinessEngine.timesheetReviewerBookingEditRecord(
            sheet: sheet0, collection: "bookings", bookingId: "b1", after: edited, deleted: false, editedBy: "lm",
            before: ["timeSlot": "CUSTOM_HOURS", "workStartTime": "07:00", "workEndTime": "19:00"]
        ))
        var removedBefore = base
        removedBefore["workEndTime"] = "12:00"
        let r2 = try XCTUnwrap(CanonicalBusinessEngine.timesheetReviewerBookingEditRecord(
            sheet: sheet0, collection: "bookings", bookingId: "b2", after: nil, deleted: true, editedBy: "lm", before: removedBefore
        ))
        let sheet: [String: Any] = sheet0.merging(["reviewerBookingEdits": [r1.key: r1.value, r2.key: r2.value]]) { $1 }
        XCTAssertTrue(CanonicalBusinessEngine.timesheetReviewerCancelChangesOffered(sheet: sheet, viewerIsReviewer: true, viewerIsSubject: false))
        XCTAssertFalse(CanonicalBusinessEngine.timesheetReviewerCancelChangesOffered(sheet: sheet, viewerIsReviewer: false, viewerIsSubject: true))
        XCTAssertEqual(CanonicalBusinessEngine.timesheetReviewerSessionRecords(sheet).count, 2)

        let plan = try XCTUnwrap(CanonicalBusinessEngine.timesheetReviewerUndoPlan(sheet: sheet, bookings: [
            ["collection": "bookings", "bookingId": "b1", "data": editedDoc, "tombstoned": false],
            ["collection": "bookings", "bookingId": "b2", "data": NSNull(), "tombstoned": true],
        ]))
        var sawRestore = false
        var sawRecreate = false
        for action in plan.actions {
            switch action {
            case .restore(_, _, let bookingId, let set, _):
                XCTAssertEqual(bookingId, "b1")
                XCTAssertEqual(set["workEndTime"] as? String, "19:00")
                sawRestore = true
            case .recreate(_, _, let oldBookingId, let data):
                XCTAssertEqual(oldBookingId, "b2")
                XCTAssertEqual(data["workEndTime"] as? String, "12:00")
                sawRecreate = true
            case .refuse(_, _, let bookingId, let message):
                XCTFail("unexpected refusal of \(bookingId): \(message)")
            }
        }
        XCTAssertTrue(sawRestore && sawRecreate)

        let restored = try XCTUnwrap(CanonicalBusinessEngine.timesheetReviewerRestoredRecords(
            sheet: sheet, oldKey: r2.key, oldRecord: r2.value, collection: "bookings", newBookingId: "b2new",
            createdDoc: removedBefore, editedBy: "lm"
        ))
        XCTAssertEqual(restored.old.value["restoredAs"] as? String, "b2new")
        XCTAssertEqual(restored.created.value["restoredFrom"] as? String, "b2")
    }

    func testChangedSinceIsRefusedNotOverwritten() throws {
        let sheet0: [String: Any] = ["operativeSignedAt": signed, "managerSignedAt": counter]
        var editedDoc = base
        editedDoc["workEndTime"] = "16:00"
        let edited = CanonicalBusinessEngine.timesheetReviewBookingDocument(collection: "bookings", id: "b3", data: editedDoc)
        let r3 = try XCTUnwrap(CanonicalBusinessEngine.timesheetReviewerBookingEditRecord(
            sheet: sheet0, collection: "bookings", bookingId: "b3", after: edited, deleted: false, editedBy: "lm",
            before: ["workEndTime": "18:00"]
        ))
        let sheet: [String: Any] = sheet0.merging(["reviewerBookingEdits": [r3.key: r3.value]]) { $1 }
        var later = editedDoc
        later["workEndTime"] = "17:00"
        let plan = try XCTUnwrap(CanonicalBusinessEngine.timesheetReviewerUndoPlan(sheet: sheet, bookings: [
            ["collection": "bookings", "bookingId": "b3", "data": later, "tombstoned": false],
        ]))
        guard case .refuse(_, _, let bookingId, _) = plan.actions.first else { return XCTFail("expected a refusal") }
        XCTAssertEqual(bookingId, "b3")
    }

    func testReviewRecordOnlyWhileMakingChanges() {
        let sheet: [String: Any] = ["operativeSignedAt": signed, "managerSignedAt": counter]
        XCTAssertNil(CanonicalBusinessEngine.timesheetReviewerReviewRecord(
            sheet: sheet, entryId: "e1", before: ["decision": "approved"], editedBy: "lm", makingChanges: false, after: nil
        ), "outside a session nothing is recorded")
        let record = CanonicalBusinessEngine.timesheetReviewerReviewRecord(
            sheet: sheet, entryId: "e1", before: ["decision": "approved"], editedBy: "lm", makingChanges: true, after: nil
        )
        XCTAssertEqual(record?.value["kind"] as? String, "extraReview")
        XCTAssertNil(CanonicalBusinessEngine.timesheetReviewerReviewRecord(
            sheet: sheet, entryId: "e1", before: nil, editedBy: "lm", makingChanges: true, after: ["lateExtra": true]
        ), "a late extra's decision is never recorded")
    }

    func testFirestoreValueTurnsTimestampsBack() throws {
        let value = TimesheetReviewerFirestoreValue.map([
            "date": ["seconds": 1_763_337_600, "nanoseconds": 5],
            "before": ["date": ["seconds": 10, "nanoseconds": 0], "workEndTime": "12:00"],
            "plain": ["seconds": 1, "nanoseconds": 2, "other": 3],
            "text": "x",
        ])
        let date = try XCTUnwrap(value["date"] as? Timestamp)
        XCTAssertEqual(date.seconds, 1_763_337_600)
        XCTAssertEqual(date.nanoseconds, 5)
        let nested = try XCTUnwrap(value["before"] as? [String: Any])
        XCTAssertNotNil(nested["date"] as? Timestamp)
        XCTAssertEqual(nested["workEndTime"] as? String, "12:00")
        XCTAssertNil(value["plain"] as? Timestamp, "only an exact { seconds, nanoseconds } map is a Timestamp")
        XCTAssertEqual(value["text"] as? String, "x")
    }
}
