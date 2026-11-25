//
//  Rulebook1900Tests.swift
//  RULEBOOK 1.90.0 §8 (owner request 24 Nov, point 4; web `canonical.test.ts` "1.90.0 draft revisions"): a reviewer's
//  revision is a draft held with them — the person is never offered Sign, Send is grey until a booking change is
//  recorded on the draft, then blue. Every answer comes from the packed script through `CanonicalBusinessEngine`.
//

import XCTest
@testable import Project_Planner

@MainActor
final class Rulebook1900Tests: XCTestCase {
    private let original = "timesheet_op1_1761955200"

    private func exportedOriginal() -> [String: Any] {
        [
            "userId": "op1",
            "weekStart": 1_761_955_200_000.0,
            "weekStartKey": "2026-11-01",
            "weekEndKey": "2026-11-15",
            "exportedAt": 1_763_300_000_000.0,
        ]
    }

    func testReviewerRevisionIsADraftAndThePersonsNeverIs() throws {
        let reviewer = try XCTUnwrap(CanonicalBusinessEngine.timesheetRevisionCreateFields(
            previousDocumentId: original, previousData: exportedOriginal(), writerUserId: "lm", draft: true
        ))
        XCTAssertEqual(reviewer.fields["revisionDraft"] as? Bool, true)
        let person = try XCTUnwrap(CanonicalBusinessEngine.timesheetRevisionCreateFields(
            previousDocumentId: original, previousData: exportedOriginal(), writerUserId: "op1", writerIsSubject: true, draft: true
        ))
        XCTAssertNil(person.fields["revisionDraft"])
        let legacy = try XCTUnwrap(CanonicalBusinessEngine.timesheetRevisionCreateFields(
            previousDocumentId: original, previousData: exportedOriginal(), writerUserId: "lm"
        ))
        XCTAssertNil(legacy.fields["revisionDraft"], "without draft: as before 1.90.0")
    }

    func testSendIsGreyUntilABookingChangeIsRecorded() {
        let draft: [String: Any] = ["revision": 1, "revisionDraft": true]
        let before = CanonicalBusinessEngine.timesheetRevisionDraftState(
            sheet: draft, viewerIsReviewer: true, viewerIsSubject: false, personName: "Sam Jones", revisionLabel: "REV 1"
        )
        XCTAssertTrue(before.draft)
        XCTAssertTrue(before.reviewerActs)
        XCTAssertFalse(before.canSend)
        XCTAssertTrue(before.canCancel)
        XCTAssertEqual(before.sendLabel, "Save changes and send timesheet to Sam")

        var edited = draft
        edited["reviewerBookingEdits"] = ["bookings__b1": ["bookingId": "b1", "collection": "bookings", "deleted": true, "forSignedAtMs": 0]]
        let after = CanonicalBusinessEngine.timesheetRevisionDraftState(
            sheet: edited, viewerIsReviewer: true, viewerIsSubject: false, personName: "Sam Jones", revisionLabel: "REV 1"
        )
        XCTAssertTrue(after.canSend)
        XCTAssertEqual(after.bookingEdits, 1)

        let person = CanonicalBusinessEngine.timesheetRevisionDraftState(
            sheet: edited, viewerIsReviewer: false, viewerIsSubject: true, personName: nil, revisionLabel: "REV 1"
        )
        XCTAssertFalse(person.personMaySign, "the person is never offered Sign on a draft")
        XCTAssertFalse(person.canSend)
        XCTAssertNotNil(person.personMessage)
    }

    func testSendRemovesTheDraftFieldOnlyWhileADraft() {
        XCTAssertEqual(CanonicalBusinessEngine.timesheetRevisionDraftSendRemovedFields(["revision": 1, "revisionDraft": true]), ["revisionDraft"])
        XCTAssertNil(CanonicalBusinessEngine.timesheetRevisionDraftSendRemovedFields(["revision": 1]))
        XCTAssertTrue(CanonicalBusinessEngine.timesheetRevisionIsDraft(["revision": 1, "revisionDraft": true]))
        XCTAssertFalse(CanonicalBusinessEngine.timesheetRevisionIsDraft(["revision": 1, "revisionDraft": true, "exportedAt": 1_763_300_000_000.0]))
    }

    func testDraftBookingEditIsRecordedWithNoSignature() throws {
        let edit = try XCTUnwrap(CanonicalBusinessEngine.timesheetReviewerBookingEditRecord(
            sheet: ["revision": 1, "revisionDraft": true],
            collection: "bookings",
            bookingId: "B1",
            after: nil,
            deleted: true,
            editedBy: "lm"
        ))
        XCTAssertEqual((edit.value["forSignedAtMs"] as? NSNumber)?.doubleValue, 0)
        XCTAssertEqual(edit.value["forRevisionDraft"] as? Bool, true)
    }

    func testDailyOverviewIsLowerCaseInTheReviewNote() {
        XCTAssertTrue(CanonicalBusinessEngine.timesheetReviewEditBookingNote.contains("daily overview"))
    }
}
