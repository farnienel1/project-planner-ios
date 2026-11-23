//
//  Rulebook1770Tests.swift
//  RULEBOOK 1.77.0 §8 (owner decisions 23 Nov, points 1, 2, 3, 5; web `canonical.test.ts` "1.77.0"): the timesheet's
//  whose-turn line, the "Correct this timesheet" entry and the counter-signed notice's invoice prompt. Every answer
//  comes from the packed script through `CanonicalBusinessEngine`.
//

import XCTest
@testable import Project_Planner

@MainActor
final class Rulebook1770Tests: XCTestCase {
    private let personSigned = Date(timeIntervalSince1970: 1_795_514_400) // 24 Nov 2026 10:00 UTC
    private let managerSigned = Date(timeIntervalSince1970: 1_795_518_000)

    private func counterSigned() -> [String: Any] {
        [
            "operativeSignedAt": personSigned.timeIntervalSince1970 * 1000,
            "operativeSignedByName": "Jo",
            "managerSignedAt": managerSigned.timeIntervalSince1970 * 1000,
            "managerSignedByName": "Sam",
            "weeklyReportOverride": ["lines": [["id": "op-B1", "bookingId": "B1", "bookingFingerprint": "2026-11-10|CUSTOM HOURS|07:00|16:00|||Confirmed", "isLeave": false, "isPayeDay": false]]],
        ]
    }

    private func next(
        _ sheet: [String: Any],
        role: String,
        change: [String: Any]? = nil,
        changedDay: String? = nil,
        changedCount: Int = 0
    ) -> RulebookTimesheetNextStep? {
        CanonicalBusinessEngine.timesheetNextStep(
            sheet: sheet, viewerRole: role, selfSigned: false, change: change,
            revisionDue: false, revisionDueLabel: nil, revisionLabel: nil,
            personName: "Jo", lineManagerName: "Sam",
            changedDayLabel: changedDay, changedBookingCount: changedCount, hasInvoiceDays: true
        )
    }

    func testWhoseTurnLine() throws {
        XCTAssertEqual(next([:], role: "person")?.text, "Your turn: sign your timesheet")
        let personOnly: [String: Any] = ["operativeSignedAt": personSigned.timeIntervalSince1970 * 1000, "operativeSignedByName": "Jo"]
        XCTAssertEqual(next(personOnly, role: "reviewer")?.text, "Your turn: sign off")

        let mine = try XCTUnwrap(next(counterSigned(), role: "person"))
        XCTAssertEqual(mine.text, "Signed off — next: generate your invoice")
        XCTAssertTrue(mine.generateInvoice)
        XCTAssertEqual(next(counterSigned(), role: "admin")?.text, "Signed off — ready to export")

        let reopened: [String: Any] = ["reopened": true, "waitingFor": "person", "bookingsChanged": true, "exported": false]
        XCTAssertEqual(next(counterSigned(), role: "person", change: reopened, changedDay: "Tue 10 Nov", changedCount: 1)?.text,
                       "Your turn: sign again — a booking changed on Tue 10 Nov")
        XCTAssertEqual(next(counterSigned(), role: "reviewer", change: reopened, changedDay: "Tue 10 Nov", changedCount: 1)?.text,
                       "Waiting for Jo to sign again — a booking changed on Tue 10 Nov")
        XCTAssertEqual(CanonicalBusinessEngine.timesheetGenerateInvoicePrompt, "Next: generate your invoice")
    }

    private func correction(
        _ sheet: [String: Any],
        subject: Bool,
        reviewer: Bool,
        revisionAllowed: Bool = false,
        revisionDue: Bool = false,
        lateExtras: Bool = false
    ) -> RulebookTimesheetCorrectionOption {
        CanonicalBusinessEngine.timesheetCorrectionOption(
            sheet: sheet, viewerIsSubject: subject, viewerIsReviewer: reviewer, selfSigned: false, reopened: false,
            revisionAllowed: revisionAllowed, nextRevisionLabel: "REV 1", revisionDue: revisionDue,
            lateExtrasAllowed: lateExtras, personName: "Jo", lineManagerName: "Sam"
        )
    }

    func testOneCorrectionEntryWrapsTheExistingActions() {
        let late = correction(counterSigned(), subject: true, reviewer: false, lateExtras: true)
        XCTAssertEqual(late.action, "addLateExtras")
        XCTAssertEqual(late.label, "Correct this timesheet")
        XCTAssertTrue(late.hasButton)

        let ask = correction(counterSigned(), subject: true, reviewer: false)
        XCTAssertEqual(ask.action, "askLineManager")
        XCTAssertFalse(ask.hasButton)
        XCTAssertEqual(ask.help, "To change this timesheet, ask Sam.")

        XCTAssertEqual(correction(counterSigned(), subject: false, reviewer: true).action, "makeChanges")

        var exported = counterSigned()
        exported["exportedAt"] = (managerSigned.timeIntervalSince1970 + 86_400) * 1000
        let revision = correction(exported, subject: true, reviewer: false, revisionAllowed: true, revisionDue: true)
        XCTAssertEqual(revision.action, "reviewAndSignAgain")
        XCTAssertEqual(revision.help, "This creates REV 1 — you sign it, then Sam signs it off.")

        // Nothing to correct on a sheet nobody has signed.
        XCTAssertNil(correction([:], subject: true, reviewer: false).action)
    }

    /// Review of 1.77.0: no active line manager names an admin; the reviewer's revision help keeps the B1 sentence.
    func testNoLineManagerAndReviewerRevisionHelp() {
        let personOnly: [String: Any] = ["operativeSignedAt": personSigned.timeIntervalSince1970 * 1000, "operativeSignedByName": "Jo"]
        let noLineManager = CanonicalBusinessEngine.timesheetNextStep(
            sheet: personOnly, viewerRole: "person", selfSigned: false, change: nil,
            revisionDue: false, revisionDueLabel: nil, revisionLabel: nil,
            personName: "Jo", lineManagerName: "Sam",
            changedDayLabel: nil, changedBookingCount: 0, hasInvoiceDays: true, hasLineManager: false
        )
        XCTAssertEqual(noLineManager?.text, "Waiting for an admin to sign off")
        XCTAssertEqual(next(personOnly, role: "person")?.text, "Waiting for Sam to sign off")

        var exported = counterSigned()
        exported["exportedAt"] = (managerSigned.timeIntervalSince1970 + 86_400) * 1000
        let reviewerRevision = CanonicalBusinessEngine.timesheetCorrectionOption(
            sheet: exported, viewerIsSubject: false, viewerIsReviewer: true, selfSigned: false, reopened: false,
            revisionAllowed: true, nextRevisionLabel: "REV 2", revisionDue: false,
            lateExtrasAllowed: false, personName: "Jo", lineManagerName: "Sam"
        )
        XCTAssertEqual(reviewerRevision.action, "createRevision")
        XCTAssertEqual(reviewerRevision.help, "This creates REV 2 — Jo signs it, then you sign it off. You can change its bookings before they sign it.")
    }

    func testCounterSignedNoticeEndsWithTheInvoicePrompt() {
        let plain = CanonicalBusinessEngine.timesheetSignedNoticeText(signedByName: "Sam", changedByReviewer: false)
        XCTAssertEqual(plain?.message, "Sam signed your timesheet. Next: generate your invoice.")
    }
}
