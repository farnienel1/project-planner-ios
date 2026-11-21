import XCTest
@testable import Project_Planner

/// RULEBOOK 1.60.1 (owner report 17 Nov: line managers got no timesheet push on iPhone): each signature of a pay run
/// gets its own notice row — `timesheet_pending_manager_signoff` for the person's signature, `timesheet_signed_by_manager`
/// and `line_manager_peer_update` for the line manager's counter-signature (`…|sig{ms}`) — so a re-sign after a cleared
/// signature or a booking change (1.47.0) writes a new row and push instead of hitting the first one. Expected values
/// checked in node against the packed script (rulebook 1.60.1, web push-ts-lm).
@MainActor
final class Rulebook1601Tests: XCTestCase {
    private let first = Date(timeIntervalSince1970: 1_783_000_000.1237)
    private var again: Date { first.addingTimeInterval(3_600) }

    private func key(signedAt: Date?, revision: Int? = nil) -> String? {
        CanonicalBusinessEngine.timesheetNotificationDedupeKey(
            type: "timesheet_pending_manager_signoff", subjectId: "op-1", periodStartDayKey: "2026-07-02",
            timeZone: "Europe/London", recipientId: "lm-1", revision: revision, signedAt: signedAt)
    }

    func testEachSignatureHasItsOwnPendingNoticeKey() {
        XCTAssertEqual(key(signedAt: first), "timesheetPending|op-1|lm-1|1782946800|sig1783000000123")
        XCTAssertEqual(key(signedAt: first, revision: 1), "timesheetPending|op-1|lm-1|1782946800|rev1|sig1783000000123")
        XCTAssertNotEqual(key(signedAt: first), key(signedAt: again), "a re-sign is a new row, so a new push")
        XCTAssertEqual(key(signedAt: first), key(signedAt: first), "a retry of the same signature is the same row")
        XCTAssertEqual(key(signedAt: nil), "timesheetPending|op-1|lm-1|1782946800", "older builds: key unchanged")
    }

    func testEachCounterSignatureHasItsOwnSignedNoticeKey() {
        func signed(_ at: Date?) -> String? {
            CanonicalBusinessEngine.timesheetNotificationDedupeKey(
                type: "timesheet_signed_by_manager", subjectId: "op-1", periodStartDayKey: "2026-07-02",
                timeZone: "Europe/London", signedAt: at)
        }
        XCTAssertEqual(signed(first), "timesheetSigned|op-1|1782946800|sig1783000000123")
        XCTAssertNotEqual(signed(first), signed(again))
        XCTAssertEqual(signed(nil), "timesheetSigned|op-1|1782946800")
    }

    /// `lineManagerPeerNoticeKey`: a counter-sign again is its own row; a leave decision (no instant) keeps its id.
    func testPeerNoticeKeyComesFromTheRulebook() {
        func peer(_ verb: String, _ summary: String, _ at: Date?) -> String? {
            CanonicalBusinessEngine.lineManagerPeerNoticeKey(
                actorName: "Lee", actionSummary: summary, peerId: "lm-2", actionVerb: verb, signedAt: at)
        }
        let summary = TimesheetSignatureNotices.peerSummary(operativeName: "Sam", weekTitle: "1–15 Nov")
        XCTAssertEqual(peer("signed", summary, nil), "lmPeer|Lee|Sam's timesheet (1–15 Nov)|lm-2|signed")
        XCTAssertEqual(peer("signed", summary, first), "lmPeer|Lee|Sam's timesheet (1–15 Nov)|lm-2|signed|sig1783000000123")
        XCTAssertNotEqual(peer("signed", summary, first), peer("signed", summary, again))
        XCTAssertEqual(peer("approved", "Sam's annual leave", nil), "lmPeer|Lee|Sam's annual leave|lm-2|approved")
    }

    // MARK: - Call paths (review of #252, item 2)

    /// The signature each InvoicingView path passes is read from the signed draft, and the ids the notify paths write
    /// follow it: a second signature is a second row id, a retry of the same signature the same id.
    func testOwnerSignPathWritesOneRowPerSignature() {
        var draft = TimesheetDraft()
        draft.operativeSignedAt = first
        let signature = TimesheetSignatureNotices.ownerSigned(draft)
        XCTAssertEqual(signature.signedAt, first, "the person's signature instant is carried")
        let weekStart = Date(timeIntervalSince1970: 1_782_946_800)
        let id = { (sig: TimesheetSignatureNotices.Signature) in
            TimesheetSignatureNotices.pendingNoticeId(subjectId: "op-1", managerId: "lm-1", weekStart: weekStart, signature: sig)
        }
        XCTAssertNotNil(id(signature))
        XCTAssertEqual(id(signature), id(TimesheetSignatureNotices.ownerSigned(draft)), "retry: same row")
        draft.operativeSignedAt = again
        XCTAssertNotEqual(id(signature), id(TimesheetSignatureNotices.ownerSigned(draft)), "second signature: new row")
    }

    func testCounterSignPathWritesOneSignedAndOnePeerRowPerCounterSignature() {
        var draft = TimesheetDraft()
        draft.managerSignedAt = first
        let signature = TimesheetSignatureNotices.counterSigned(draft)
        XCTAssertEqual(signature.signedAt, first, "the counter-sign instant is carried")
        let weekStart = Date(timeIntervalSince1970: 1_782_946_800)
        let summary = TimesheetSignatureNotices.peerSummary(operativeName: "Sam", weekTitle: "1–15 Nov")
        let signed = { (sig: TimesheetSignatureNotices.Signature) in
            TimesheetSignatureNotices.signedNoticeId(subjectId: "op-1", weekStart: weekStart, signature: sig)
        }
        let peer = { (sig: TimesheetSignatureNotices.Signature) in
            TimesheetSignatureNotices.counterSignPeerNoticeId(signedByName: "Lee", summary: summary, peerId: "lm-2", signature: sig)
        }
        XCTAssertNotNil(signed(signature))
        XCTAssertNotNil(peer(signature))
        XCTAssertEqual(signed(signature), signed(TimesheetSignatureNotices.counterSigned(draft)), "retry: same signed row")
        XCTAssertEqual(peer(signature), peer(TimesheetSignatureNotices.counterSigned(draft)), "retry: same peer row")
        draft.managerSignedAt = again
        XCTAssertNotEqual(signed(signature), signed(TimesheetSignatureNotices.counterSigned(draft)), "counter-sign again: new row")
        XCTAssertNotEqual(peer(signature), peer(TimesheetSignatureNotices.counterSigned(draft)), "counter-sign again: new peer row")
    }

    /// The InvoicingView call sites pass the signature read from the signed draft (fails if a call drops it).
    func testInvoicingViewCallSitesPassTheSignature() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent("Project Planner/Views/InvoicingView.swift"), encoding: .utf8)
        XCTAssertTrue(source.contains("let signature = TimesheetSignatureNotices.ownerSigned(draft)"))
        XCTAssertTrue(source.contains("let counterSignature = TimesheetSignatureNotices.counterSigned(draft)"))
        XCTAssertTrue(source.contains("signature: signature\n"), "notifyTimesheetSubmitted gets the person's signature")
        XCTAssertTrue(source.contains("signature: counterSignature\n"), "notifyTimesheetCounterSigned gets the counter-signature")
        let service = try String(contentsOf: root.appendingPathComponent("Project Planner/Core/NotificationService.swift"), encoding: .utf8)
        XCTAssertTrue(service.contains("signedAt: signature.signedAt\n"), "the peer rows get the counter-sign instant")
    }
}
