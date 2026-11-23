//
//  Rulebook1760Tests.swift
//  RULEBOOK 1.76.0 §8 (owner decisions 23 Nov, A1 and B1; web `canonical.test.ts` "1.76.0"). The reviewer's "Make
//  changes" button: reopen the review on a signed-off, unexported sheet; create the next revision on an exported one;
//  booking edits on an open revision before the person signs. Every answer comes from the packed script through
//  `CanonicalBusinessEngine`.
//

import XCTest
@testable import Project_Planner

@MainActor
final class Rulebook1760Tests: XCTestCase {
    private let personSigned = Date(timeIntervalSince1970: 1_795_514_400) // 24 Nov 2026 10:00 UTC
    private let managerSigned = Date(timeIntervalSince1970: 1_795_518_000)

    private func counterSigned() -> [String: Any] {
        [
            "operativeSignedAt": personSigned.timeIntervalSince1970 * 1000,
            "operativeSignedByName": "Jo Bloggs",
            "managerSignedAt": managerSigned.timeIntervalSince1970 * 1000,
            "managerSignedByName": "Line Manager",
        ]
    }

    private func action(
        _ sheet: [String: Any],
        reviewer: Bool = true,
        subject: Bool = false,
        selfSigned: Bool = false,
        reopened: Bool = false,
        revisionAllowed: Bool = false
    ) -> RulebookTimesheetMakeChangesAction? {
        CanonicalBusinessEngine.timesheetMakeChangesAction(
            sheet: sheet,
            viewerIsReviewer: reviewer,
            viewerIsSubject: subject,
            selfSigned: selfSigned,
            reopened: reopened,
            revisionAllowed: revisionAllowed
        )
    }

    func testCopyIsTheRulebooks() {
        XCTAssertEqual(CanonicalBusinessEngine.timesheetMakeChangesLabel, "Make changes")
        XCTAssertEqual(CanonicalBusinessEngine.timesheetMakeChangesCancelLabel, "Stop making changes")
        XCTAssertTrue(CanonicalBusinessEngine.timesheetMakeChangesHelp(.reopenReview).contains("The person does not sign again"))
        XCTAssertTrue(CanonicalBusinessEngine.timesheetMakeChangesHelp(.createRevision).contains("new revision"))
        XCTAssertEqual(CanonicalBusinessEngine.timesheetMakeChangesHelp(nil), "")
    }

    func testSignedOffNotExportedReopensTheReviewForReviewersOnly() {
        XCTAssertEqual(action(counterSigned()), .reopenReview)
        XCTAssertNil(action(counterSigned(), reviewer: false))
        XCTAssertNil(action(counterSigned(), subject: true))
        XCTAssertNil(action(counterSigned(), selfSigned: true))
        XCTAssertNil(action(counterSigned(), reopened: true))
        // Not counter-signed yet: the reviewer is already reviewing it.
        var notCounterSigned = counterSigned()
        notCounterSigned.removeValue(forKey: "managerSignedAt")
        XCTAssertNil(action(notCounterSigned))
    }

    func testExportedCreatesTheNextRevisionOnlyWhenAllowed() {
        var exported = counterSigned()
        exported["exportedAt"] = Date(timeIntervalSince1970: 1_795_600_000).timeIntervalSince1970 * 1000
        XCTAssertEqual(action(exported, revisionAllowed: true), .createRevision)
        XCTAssertNil(action(exported, revisionAllowed: false))
    }

    func testReviewerMayEditAnOpenRevisionUntilThePersonSigns() {
        let revision: [String: Any] = ["revision": 1]
        XCTAssertTrue(CanonicalBusinessEngine.timesheetRevisionReviewerMayEditBookings(sheet: revision, viewerIsReviewer: true, viewerIsSubject: false))
        XCTAssertFalse(CanonicalBusinessEngine.timesheetRevisionReviewerMayEditBookings(sheet: revision, viewerIsReviewer: false, viewerIsSubject: false))
        var signed = revision
        signed["operativeSignedAt"] = personSigned.timeIntervalSince1970 * 1000
        signed["operativeSignedByName"] = "Jo"
        XCTAssertFalse(CanonicalBusinessEngine.timesheetRevisionReviewerMayEditBookings(sheet: signed, viewerIsReviewer: true, viewerIsSubject: false))
        XCTAssertFalse(CanonicalBusinessEngine.timesheetRevisionReviewerMayEditBookings(sheet: [:], viewerIsReviewer: true, viewerIsSubject: false))
    }
}
