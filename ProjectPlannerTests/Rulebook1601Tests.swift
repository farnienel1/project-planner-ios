import XCTest
@testable import Project_Planner

/// RULEBOOK 1.60.1 (owner report 17 Nov: line managers got no timesheet push on iPhone): each signature of a pay run
/// gets its own `timesheet_pending_manager_signoff` key (`…|sig{ms}`), so a re-sign after a cleared signature or a
/// booking change (1.47.0) writes a new row — and push — instead of hitting the first signature's row. Expected values
/// checked in node against the packed script (rulebook 1.60.1, web push-ts-lm).
final class Rulebook1601Tests: XCTestCase {
    private func key(signedAt: Date?, revision: Int? = nil) -> String? {
        CanonicalBusinessEngine.timesheetNotificationDedupeKey(
            type: "timesheet_pending_manager_signoff", subjectId: "op-1", periodStartDayKey: "2026-07-02",
            timeZone: "Europe/London", recipientId: "lm-1", revision: revision, signedAt: signedAt)
    }

    func testEachSignatureHasItsOwnPendingNoticeKey() {
        let first = Date(timeIntervalSince1970: 1_783_000_000.1237)
        let again = first.addingTimeInterval(3_600)
        XCTAssertEqual(key(signedAt: first), "timesheetPending|op-1|lm-1|1782946800|sig1783000000123")
        XCTAssertEqual(key(signedAt: first, revision: 1), "timesheetPending|op-1|lm-1|1782946800|rev1|sig1783000000123")
        XCTAssertNotEqual(key(signedAt: first), key(signedAt: again), "a re-sign is a new row, so a new push")
        XCTAssertEqual(key(signedAt: first), key(signedAt: first), "a retry of the same signature is the same row")
    }

    func testWithoutASignatureInstantTheKeyIsUnchanged() {
        XCTAssertEqual(key(signedAt: nil), "timesheetPending|op-1|lm-1|1782946800")
    }

    /// The counter-signature notice (`timesheet_signed_by_manager`) is keyed by the line manager's counter-sign instant.
    func testEachCounterSignatureHasItsOwnSignedNoticeKey() {
        func signed(_ at: Date?) -> String? {
            CanonicalBusinessEngine.timesheetNotificationDedupeKey(
                type: "timesheet_signed_by_manager", subjectId: "op-1", periodStartDayKey: "2026-07-02",
                timeZone: "Europe/London", signedAt: at)
        }
        let first = Date(timeIntervalSince1970: 1_783_000_000.1237)
        XCTAssertEqual(signed(first), "timesheetSigned|op-1|1782946800|sig1783000000123")
        XCTAssertNotEqual(signed(first), signed(first.addingTimeInterval(60)))
        XCTAssertEqual(signed(nil), "timesheetSigned|op-1|1782946800")
    }

    /// `line_manager_peer_update` (web `timesheetPeerNoticeKey`): a counter-sign again is its own row; leave decisions
    /// (no instant) keep their key.
    func testPeerNoticeKeyAddsTheCounterSignInstant() {
        let first = Date(timeIntervalSince1970: 1_783_000_000.1237)
        func key(_ at: Date?) -> String {
            NotificationService.peerNoticeKey(
                actorName: "Lee", actionSummary: "Sam's timesheet (1–15 Nov)", targetId: "lm-2", actionVerb: "signed", signedAt: at)
        }
        XCTAssertEqual(key(nil), "lmPeer|Lee|Sam's timesheet (1–15 Nov)|lm-2|signed")
        XCTAssertEqual(key(first), "lmPeer|Lee|Sam's timesheet (1–15 Nov)|lm-2|signed|sig1783000000123")
        XCTAssertNotEqual(key(first), key(first.addingTimeInterval(60)))
    }
}
