import XCTest
@testable import Project_Planner

/// Review of the timesheet flow (26 Nov): User Timesheets rows open the sheet they list, a save never rewrites a stored
/// `userId`, and the ✕ confirm says who can bring a deleted booking back.
final class TimesheetSheetTargetTests: XCTestCase {
    // MARK: Which document the review screen opens (RULEBOOK 1.66.0 §8)

    func testRowFiledUnderAnotherIdOpensThatId() {
        XCTAssertEqual(
            TimesheetSheetTarget.userId(sheetUserId: "former-invite-id", personId: "auth-uid"),
            "former-invite-id"
        )
    }

    func testRowWithoutSheetIdOpensThePersonsOwnId() {
        XCTAssertEqual(TimesheetSheetTarget.userId(sheetUserId: nil, personId: "auth-uid"), "auth-uid")
        XCTAssertEqual(TimesheetSheetTarget.userId(sheetUserId: "", personId: "auth-uid"), "auth-uid")
        XCTAssertEqual(TimesheetSheetTarget.userId(sheetUserId: "   ", personId: "auth-uid"), "auth-uid")
    }

    func testStoredSheetIdKeepsItsCase() {
        XCTAssertEqual(
            TimesheetSheetTarget.userId(sheetUserId: "6A9632BA-0000-4000-8000-000000000001", personId: "auth-uid"),
            "6A9632BA-0000-4000-8000-000000000001"
        )
    }

    // MARK: `userId` on a save (RULEBOOK §16 `timesheetSubjectFiled`)

    func testNewSheetWritesUserId() {
        XCTAssertEqual(TimesheetSheetTarget.userIdWrite(stored: nil, exists: false, userId: "u1"), "u1")
    }

    func testStoredUserIdIsNeverRewritten() {
        XCTAssertNil(TimesheetSheetTarget.userIdWrite(stored: ["userId": "u1"], exists: true, userId: "u1"))
        // Another letter case or another spelling: still left as stored (the rules refuse any change).
        XCTAssertNil(TimesheetSheetTarget.userIdWrite(stored: ["userId": "U1"], exists: true, userId: "u1"))
        XCTAssertNil(TimesheetSheetTarget.userIdWrite(stored: ["userId": "other"], exists: true, userId: "u1"))
        // A blank or null stored value is a stored key: not rewritten either.
        XCTAssertNil(TimesheetSheetTarget.userIdWrite(stored: ["userId": ""], exists: true, userId: "u1"))
        XCTAssertNil(TimesheetSheetTarget.userIdWrite(stored: ["userId": NSNull()], exists: true, userId: "u1"))
    }

    func testExistingSheetWithoutUserIdGetsTheIdItsDocumentNames() {
        XCTAssertEqual(TimesheetSheetTarget.userIdWrite(stored: ["weekStartKey": "2026-11-01"], exists: true, userId: "u1"), "u1")
    }

    func testExistingSheetWhoseStoredCopyIsUnknownWritesNoUserId() {
        XCTAssertNil(TimesheetSheetTarget.userIdWrite(stored: nil, exists: true, userId: "u1"))
    }

    // MARK: ✕ undo note (owner 26 Nov)

    func testUndoNoteOnlyForViewersWhoCannotRebook() {
        XCTAssertTrue(TimesheetReviewDeleteUndo.showsNote(viewerIsAdmin: false, viewerMayDeleteBooking: false))
        XCTAssertFalse(TimesheetReviewDeleteUndo.showsNote(viewerIsAdmin: true, viewerMayDeleteBooking: false))
        XCTAssertFalse(TimesheetReviewDeleteUndo.showsNote(viewerIsAdmin: false, viewerMayDeleteBooking: true))
        XCTAssertFalse(TimesheetReviewDeleteUndo.note.isEmpty)
        XCTAssertEqual(
            TimesheetReviewDeleteUndo.fallbackNote,
            "If you don't manage this job, only an admin or the job's manager can bring this booking back."
        )
    }

    func testDeleteConfirmAddsTheNoteOnlyWhenAsked() throws {
        let warning = try XCTUnwrap(CanonicalBusinessEngine.timesheetReviewDeleteBookingWarning(summary: "Mon 23 Nov · J-1042", overtimeLine: false))
        let plan = try XCTUnwrap(CanonicalBusinessEngine.timesheetReviewBookingDelete(bookingId: "B9", collection: "bookings", deletedBy: "TEST-LM"))
        let withNote = TimesheetReviewRemoval(warning: warning, action: .delete(plan), showsRebookNote: true)
        XCTAssertTrue(withNote.messageText.contains(TimesheetReviewDeleteUndo.note))
        let without = TimesheetReviewRemoval(warning: warning, action: .delete(plan))
        XCTAssertFalse(without.messageText.contains(TimesheetReviewDeleteUndo.note))
    }
}
