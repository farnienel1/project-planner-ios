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
            "weeklyReportOverride": ["lines": [["id": "op-B1", "bookingId": "B1", "bookingFingerprint": "fp-B1", "isLeave": false, "isPayeDay": false]]],
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

    /// Review of #427 (finding 1): a signed copy from before 1.46.0 (no `bookingFingerprint`) gets no button, only a line.
    func testOldSignedCopyGetsNoButtonButAHelpLine() {
        var old = counterSigned()
        old["weeklyReportOverride"] = ["lines": [["id": "op-B1", "bookingId": "B1", "isLeave": false, "isPayeDay": false]]]
        XCTAssertNil(action(old))
        XCTAssertEqual(
            CanonicalBusinessEngine.timesheetMakeChangesHelpWithoutAction(sheet: old, viewerIsReviewer: true, viewerIsSubject: false, selfSigned: false, reopened: false),
            CanonicalBusinessEngine.timesheetMakeChangesOldSheetHelp
        )
        XCTAssertEqual(
            CanonicalBusinessEngine.timesheetMakeChangesHelpWithoutAction(sheet: counterSigned(), viewerIsReviewer: true, viewerIsSubject: false, selfSigned: false, reopened: false),
            ""
        )
        // Exported, it is corrected in a revision as any other.
        old["exportedAt"] = Date(timeIntervalSince1970: 1_795_600_000).timeIntervalSince1970 * 1000
        XCTAssertEqual(action(old, revisionAllowed: true), .createRevision)
    }

    /// Review of #427 (finding 9): a revision known only by `revisionOf` counts too.
    func testRevisionKnownByRevisionOf() {
        XCTAssertTrue(CanonicalBusinessEngine.timesheetRevisionReviewerMayEditBookings(
            sheet: ["revisionOf": "timesheet_OP1_1795392000"], viewerIsReviewer: true, viewerIsSubject: false
        ))
    }

    /// Re-check of #427: a signed copy with nothing signed to change gets neither the button nor the old-sheet line;
    /// owner answer 23 Nov (b): one with signed price work or expenses (no labour line) gets the button.
    func testSignedCopyWithoutLabourLinesGetsNoOldSheetLine() {
        var empty = counterSigned()
        empty["weeklyReportOverride"] = ["lines": [[String: Any]]()]
        XCTAssertNil(action(empty))
        XCTAssertEqual(
            CanonicalBusinessEngine.timesheetMakeChangesHelpWithoutAction(sheet: empty, viewerIsReviewer: true, viewerIsSubject: false, selfSigned: false, reopened: false),
            ""
        )
        var extrasOnly = counterSigned()
        extrasOnly["weeklyReportOverride"] = ["lines": [[String: Any]](), "expenses": [["id": "ex1", "amount": 40]]]
        XCTAssertEqual(action(extrasOnly), .reopenReview)
    }

    // MARK: Owner answer 23 Nov (b): Make changes on the signed price work and expenses

    private func signedWithEntries(reviews: [String: Any]? = nil, expenseAmount: Double = 40, priceWorkAmount: Double = 300) -> [String: Any] {
        var sheet = counterSigned()
        sheet["priceWorkEntries"] = [["id": "pw1", "title": "Fit doors", "amount": 300, "jobNumber": "J1", "startDate": "2026-11-18"]]
        sheet["expenseEntries"] = [["id": "ex1", "title": "Parking", "amount": 40, "jobNumber": "J1", "date": "2026-11-18"]]
        sheet["weeklyReportOverride"] = [
            "lines": [["id": "op-B1", "bookingId": "B1", "bookingFingerprint": "fp-B1", "amount": 250]],
            "priceWork": [["id": "pw1", "title": "Fit doors", "amount": priceWorkAmount, "decision": "approved"]],
            "expenses": [["id": "ex1", "title": "Parking", "amount": expenseAmount, "decision": "approved"]],
        ]
        if let reviews { sheet["extraEntryReviews"] = reviews }
        return sheet
    }

    private func changes(_ sheet: [String: Any]) -> RulebookSignedTimesheetChange? {
        let summary = CanonicalBusinessEngine.timesheetLateExtrasSummary(sheet: sheet, entryFingerprints: [:], exportedAtStored: false)
        return CanonicalBusinessEngine.timesheetChangesWithLateExtras(bookingChange: nil, late: summary)
    }

    private func total(_ sheet: [String: Any]) -> Double {
        let rows = CanonicalBusinessEngine.callJSON(
            "timesheetInvoiceRows",
            arguments: [["sheet": sheet, "payrollLines": [Any](), "extrasMode": "decided"]]
        ) as? [[String: Any]] ?? []
        return rows.reduce(0) { $0 + ((($1["amount"]) as? NSNumber)?.doubleValue ?? 0) }
    }

    private var afterSignOffMs: Double { managerSigned.timeIntervalSince1970 * 1000 + 60_000 }

    func testRemovingASignedExpenseWaitsForTheLineManagerAndBlocksExport() {
        let signed = signedWithEntries()
        XCTAssertEqual(total(signed), 590, accuracy: 0.001)
        XCTAssertNil(changes(signed))
        let removed = signedWithEntries(reviews: [
            "ex1": ["decision": "declined", "reviewedAmount": 40, "reviewedByUserId": "lm", "reviewedAtMs": afterSignOffMs],
        ])
        let change = changes(removed)
        XCTAssertEqual(change?.reopened, true)
        XCTAssertEqual(change?.waitingFor, "lineManager")
        XCTAssertNil(change?.message)
        XCTAssertEqual(change?.signedEntriesChanged, true)
        XCTAssertEqual(change?.signedEntriesOnly, true)
        XCTAssertEqual(change?.lateExtrasOnly, false)
        let actions = CanonicalBusinessEngine.signedTimesheetActions(change)
        XCTAssertFalse(actions.mayExport)
        XCTAssertFalse(actions.mayGenerateInvoice)
        XCTAssertFalse(actions.personMaySignAgain)
        // Signed off again: the signed copy holds the expense at 0 and the total goes down.
        var resigned = signedWithEntries(reviews: [
            "ex1": ["decision": "declined", "reviewedAmount": 40, "reviewedByUserId": "lm", "reviewedAtMs": afterSignOffMs],
        ], expenseAmount: 0)
        resigned["managerSignedAt"] = afterSignOffMs + 60_000
        XCTAssertNil(changes(resigned))
        XCTAssertEqual(total(resigned), 550, accuracy: 0.001)
    }

    func testEditingASignedPriceWorkAmountWaitsTheSameWay() {
        let edited = signedWithEntries(reviews: [
            "pw1": ["decision": "edited", "revisedAmount": 250, "reviewedAmount": 300, "reviewedByUserId": "lm", "reviewedAtMs": afterSignOffMs],
        ])
        XCTAssertEqual(changes(edited)?.waitingFor, "lineManager")
        XCTAssertFalse(CanonicalBusinessEngine.signedTimesheetActions(changes(edited)).mayExport)
        var resigned = signedWithEntries(reviews: [
            "pw1": ["decision": "edited", "revisedAmount": 250, "reviewedAmount": 300, "reviewedByUserId": "lm", "reviewedAtMs": afterSignOffMs],
        ], priceWorkAmount: 250)
        resigned["managerSignedAt"] = afterSignOffMs + 60_000
        XCTAssertNil(changes(resigned))
        XCTAssertEqual(total(resigned), 540, accuracy: 0.001)
    }

    /// Review of #278: no clock test — a review whose device clock reads before the counter-signature still counts;
    /// a review that matches the signed copy never reopens. The person's note is the rulebook's.
    func testNoClockTestOnlyWhatIsPaidAgainstTheSignedRow() {
        let skewed = signedWithEntries(reviews: [
            "ex1": ["decision": "declined", "reviewedAmount": 40, "reviewedByUserId": "lm", "reviewedAtMs": afterSignOffMs - 7_200_000],
        ])
        XCTAssertEqual(changes(skewed)?.waitingFor, "lineManager")
        let inStep = signedWithEntries(reviews: [
            "ex1": ["decision": "declined", "reviewedAmount": 40, "reviewedByUserId": "lm", "reviewedAtMs": afterSignOffMs],
        ], expenseAmount: 0)
        XCTAssertNil(changes(inStep))
        XCTAssertEqual(
            CanonicalBusinessEngine.timesheetSignedEntriesChangedPersonMessage,
            "Your line manager changed your price work or expenses — Generate Timesheet unlocks after they sign it off again."
        )
    }

    /// The signed copy keeps its signed price work and expense rows on every save except a signing.
    func testSignedMoneyRowsAreKeptUnlessSigningOff() {
        func line(_ id: String, _ amount: Double, late: Bool = false) -> TimesheetWeeklyReportMoneyLine {
            TimesheetWeeklyReportMoneyLine(
                id: id, title: id, details: "", jobNumber: "", date: Date(), amount: amount, decision: .approved,
                lateExtra: late ? true : nil, entryFingerprint: nil
            )
        }
        let stored = [line("ex1", 40), line("l1", 5, late: true)]
        let fresh = [line("ex1", 0), line("l1", 7, late: true)]
        let kept = TimesheetWeeklyReportOverrideBuilder.signedMoneyRows(stored, fresh: fresh, refresh: false)
        XCTAssertEqual(kept.map(\.amount), [40, 7])
        XCTAssertEqual(TimesheetWeeklyReportOverrideBuilder.signedMoneyRows(stored, fresh: fresh, refresh: true).map(\.amount), [0, 7])
    }
}
