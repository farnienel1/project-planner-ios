import XCTest
@testable import Project_Planner

/// 1.33.1: annual leave saves (create, edit, cancel request, decision, delete) follow the booking pattern — a short
/// wait for the server, then Pending sync while Firestore holds the write, the outcome settling in the background, and
/// refusals surfaced. What is written is unchanged.
@MainActor
final class LeaveWriteAckTests: XCTestCase {
    private var appRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Project Planner")
    }

    private func source(_ rel: String) throws -> String {
        try String(contentsOf: appRoot.appendingPathComponent(rel), encoding: .utf8)
    }

    override func setUp() async throws {
        SDKPendingWrites.shared.removeAll()
    }

    override func tearDown() async throws {
        SDKPendingWrites.shared.removeAll()
    }

    /// A short session: its waits are `afterTimeoutWaitSeconds` (1 s).
    private func shortSession() -> BookingWriteSession {
        let session = BookingWriteSession(organizationId: "TEST-ORG")
        session.noteTimeout()
        return session
    }

    private let path = "organizations/TEST-ORG/holidayBookings/LEAVE-1"

    func testAConfirmedWriteIsNotPending() async throws {
        let pending = try await LeaveWriteAck.run(path: path, entityId: "LEAVE-1", organizationId: "TEST-ORG", session: shortSession()) {}
        XCTAssertFalse(pending)
        XCTAssertFalse(LeaveWriteAck.isPending(documentId: "LEAVE-1"))
    }

    func testARefusalIsThrownNeverSwallowed() async {
        do {
            _ = try await LeaveWriteAck.run(path: path, entityId: "LEAVE-1", organizationId: "TEST-ORG", session: shortSession()) {
                throw NSError(domain: "FIRFirestoreErrorDomain", code: 7, userInfo: [NSLocalizedDescriptionKey: "Missing or insufficient permissions."])
            }
            XCTFail("a refused leave write must throw")
        } catch {
            XCTAssertEqual((error as NSError).code, 7)
        }
        XCTAssertFalse(LeaveWriteAck.isPending(documentId: "LEAVE-1"))
    }

    /// The server does not answer within the wait: the save returns Pending sync at once, the row shows it, and when
    /// the write lands the held approver notices are released (as for an outbox entry) and Pending sync clears.
    func testAnUnansweredWriteReturnsPendingSyncAndSettlesLater() async throws {
        let synced = expectation(forNotification: .offlineOutboxEntrySynced, object: nil) { note in
            let info = note.userInfo as? [String: String] ?? [:]
            return info["entityId"] == "LEAVE-1"
                && info["organizationId"] == "TEST-ORG"
                && info["operation"] == OfflineOutboxEntry.Operation.saveAnnualLeaveRequest.rawValue
        }
        let started = Date()
        let pending = try await LeaveWriteAck.run(path: path, entityId: "LEAVE-1", organizationId: "TEST-ORG", session: shortSession()) {
            try await Task.sleep(nanoseconds: 1_800_000_000)
        }
        XCTAssertTrue(pending)
        XCTAssertLessThan(Date().timeIntervalSince(started), 1.7, "the save never waits for the server's answer")
        XCTAssertTrue(LeaveWriteAck.isPending(documentId: "LEAVE-1"), "the row shows Pending sync")
        await fulfillment(of: [synced], timeout: 5)
        XCTAssertFalse(LeaveWriteAck.isPending(documentId: "LEAVE-1"), "cleared once the server confirmed")
    }

    /// Refused after its wait: the held notices are dropped (nobody is told about leave that was not saved) and the
    /// person sees the late-refusal message.
    func testAWriteRefusedAfterItsWaitIsSurfaced() async throws {
        OfflineOutboxStore.shared.lastRefusalMessage = nil
        let refused = expectation(forNotification: .offlineOutboxEntryRefused, object: nil) { note in
            (note.userInfo as? [String: String])?["entityId"] == "LEAVE-1"
        }
        let late = expectation(forNotification: SDKPendingWrites.lateRefusalNotification, object: nil) { note in
            (note.userInfo?["collection"] as? String) == LeaveWriteAck.collection
        }
        let pending = try await LeaveWriteAck.run(path: path, entityId: "LEAVE-1", organizationId: "TEST-ORG", session: shortSession()) {
            try await Task.sleep(nanoseconds: 1_500_000_000)
            throw NSError(domain: "FIRFirestoreErrorDomain", code: 7, userInfo: [NSLocalizedDescriptionKey: "Missing or insufficient permissions."])
        }
        XCTAssertTrue(pending)
        await fulfillment(of: [refused, late], timeout: 5)
        XCTAssertEqual(OfflineOutboxStore.shared.lastRefusalMessage, SDKPendingWrites.lateRefusalMessage)
        XCTAssertFalse(LeaveWriteAck.isPending(documentId: "LEAVE-1"))
        OfflineOutboxStore.shared.lastRefusalMessage = nil
    }

    func testALeaveRowShowsPendingSyncWhileFirestoreHoldsTheWrite() {
        SDKPendingWrites.shared.mark(path)
        XCTAssertTrue(BookingPendingSync.isPending(entityId: "LEAVE-1", collection: LeaveWriteAck.collection, documentKey: "LEAVE-1"))
        SDKPendingWrites.shared.settle(path, error: nil)
        XCTAssertFalse(BookingPendingSync.isPending(entityId: "LEAVE-1", collection: LeaveWriteAck.collection, documentKey: "LEAVE-1"))
    }

    func testEveryLeaveWriteIsBoundedAndPendingIsShown() throws {
        let backend = try source("FirebaseBackend.swift")
        XCTAssertEqual(
            backend.components(separatedBy: "try await LeaveWriteAck.run(ref: ref, organizationId: orgId, session: session)").count - 1,
            3,
            "create, edit (decisions and cancel requests go through it) and delete"
        )
        XCTAssertFalse(backend.contains(".document(create.documentId).setData(data)"), "no unbounded create")
        let store = try source("Core/HolidayStore.swift")
        XCTAssertTrue(store.contains("LeaveWriteAck.isPending(documentId: booking.documentId)"))
        for call in ["fb.saveHolidayBooking(booking, organizationId: orgId, session: session)",
                     "fb.saveHolidayBooking(draft, organizationId: orgId, session: session)",
                     "session: writeSession(orgId)"] {
            XCTAssertTrue(store.contains(call), call)
        }
        XCTAssertTrue(store.contains("SDKPendingWrites.lateRefusalNotification"), "a late refusal re-reads the server's leave")
        let rows = try source("Views/HolidayView.swift")
        XCTAssertTrue(rows.contains("PendingSyncIndicator(leave: booking)"))
    }
}
