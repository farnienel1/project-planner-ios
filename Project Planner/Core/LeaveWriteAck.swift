//
//  LeaveWriteAck.swift
//  Project Planner
//
//  1.33.1 (owner device report, 10 Nov): annual leave saves — a new request, an edit, a request to cancel, a decision
//  and a delete — awaited the server's confirmation with no limit, so a save hung for as long as the server did not
//  answer. They now follow the booking pattern (`FirestoreWriteAck`, `BookingWriteSession`): Firestore has already
//  applied the write on this phone and keeps it in its own queue; after the save's short wait it is reported Pending
//  sync, and the confirmation or a refusal follows in the background. What is written is unchanged
//  (`holidayRequestWriteFields`, `holidayDecisionWriteFields`, the partial updates of §9).
//

import Foundation
@preconcurrency import FirebaseFirestore

enum LeaveWriteAck {
    nonisolated static let collection = "holidayBookings"

    /// Runs one leave write. Returns false when the server confirmed it, true when it is Pending sync (the wait timed
    /// out: Firestore holds it). A refusal is thrown, never swallowed. When a Pending sync write settles later, the
    /// approver notices held for it are released (confirmed) or dropped (refused) as for an outbox entry
    /// (`DeferredLeaveNoticeQueue`), and a refusal is announced by `SDKPendingWrites.settle` ("Change not saved").
    @MainActor
    static func run(
        ref: DocumentReference,
        organizationId: String,
        session: BookingWriteSession?,
        _ write: @escaping () async throws -> Void
    ) async throws -> Bool {
        let entityId = ref.documentID
        return try await run(
            path: ref.path,
            entityId: entityId,
            organizationId: organizationId,
            session: session,
            write
        )
    }

    /// `run(ref:…)` without Firestore, so the bookkeeping can be tested.
    @MainActor
    static func run(
        path: String,
        entityId: String,
        organizationId: String,
        session: BookingWriteSession?,
        _ write: @escaping () async throws -> Void
    ) async throws -> Bool {
        let wait = session?.ackSeconds ?? BookingWriteSession.firstWaitSeconds
        do {
            try await FirestoreWriteAck.run(
                timeoutSeconds: wait,
                pendingKey: path,
                onSettledAfterTimeout: { error in
                    settled(entityId: entityId, organizationId: organizationId, error: error)
                },
                write
            )
            return false
        } catch {
            session?.note(error)
            if FirestoreWriteAck.isPendingInSDK(error) { return true }
            throw error
        }
    }

    /// A Pending sync leave write finished: tells the held approver notices, the same way an outbox entry does.
    @MainActor
    static func settled(entityId: String, organizationId: String, error: Error?) {
        let info: [String: String] = [
            "operation": OfflineOutboxEntry.Operation.saveAnnualLeaveRequest.rawValue,
            "entityId": entityId,
            "organizationId": organizationId,
        ]
        NotificationCenter.default.post(
            name: error == nil ? .offlineOutboxEntrySynced : .offlineOutboxEntryRefused,
            object: nil,
            userInfo: info
        )
    }

    /// "Pending sync" for a leave record: queued in the app outbox (offline), or held by Firestore after its wait.
    @MainActor
    static func isPending(documentId: String) -> Bool {
        OfflineOutboxStore.shared.hasPendingSync(entityId: documentId)
            || SDKPendingWrites.shared.contains(collection: collection, documentId: documentId)
    }
}
