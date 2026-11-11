//
//  FirebaseBackend+AnnualLeaveAdjustments.swift
//  Project Planner
//
//  RULEBOOK 1.40.0 §4.4 (owner decisions 11 Nov H28–H35): manual annual-leave adjustments, the iOS counterpart of
//  web `lib/annualLeave/leaveAdjustments.ts`. Every rule is in the packed script (`Rulebook+AnnualLeaveTeam.swift`);
//  this file only reads documents through `parseAnnualLeaveAdjustmentDocument` and writes the fields
//  `annualLeaveAdjustmentCreateFields` returns, with write metadata. Online only. A create, never an update or delete.
//

import Foundation
import FirebaseAuth
@preconcurrency import FirebaseFirestore

/// Why an adjustment was not saved: the rulebook refused it, or there is no organisation or signed-in person.
nonisolated struct AnnualLeaveAdjustmentRefused: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

extension FirebaseBackend {
    /// Live adjustments filed under these users ids (`userId in`, at most four per query so the read rule's lookups
    /// stay within Firestore's limit). The person may read their own; a line manager their reports'; admins anyone's.
    func listenAnnualLeaveAdjustments(
        userIds: [String],
        onChunk: @escaping (_ chunk: Int, _ rows: [AnnualLeaveAdjustmentRecord]) -> Void
    ) -> [ListenerRegistration] {
        guard let orgId = currentOrganization?.firestoreDocumentId, !orgId.isEmpty else { return [] }
        let ids = userIds.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard !ids.isEmpty else { return [] }
        let collection = db.collection("organizations").document(orgId)
            .collection(CanonicalBusinessEngine.annualLeaveAdjustmentsCollection)
        var registrations: [ListenerRegistration] = []
        var start = 0
        var chunkIndex = 0
        while start < ids.count {
            let chunk = Array(ids[start..<min(start + 4, ids.count)])
            let index = chunkIndex
            let query = chunk.count == 1
                ? collection.whereField("userId", isEqualTo: chunk[0])
                : collection.whereField("userId", in: chunk)
            registrations.append(query.addSnapshotListener { snapshot, _ in
                let rows = (snapshot?.documents ?? []).compactMap { doc in
                    CanonicalBusinessEngine.parseAnnualLeaveAdjustmentDocument(
                        docId: doc.documentID,
                        data: FirebaseBackend.firestoreJSON(doc.data()) as? [String: Any] ?? [:]
                    )
                }
                Task { @MainActor in onChunk(index, rows) }
            })
            start += 4
            chunkIndex += 1
        }
        return registrations
    }

    /// Adds one adjustment for `subject` in the leave year `yearKey` (online only). Throws when the rulebook refuses it
    /// or the write fails; the caller then tells every admin (`NotificationService.notifyAnnualLeaveAdjusted`).
    func addAnnualLeaveAdjustment(
        subject: AppUser,
        days: Double,
        reason: String,
        yearKey: String,
        actorName: String
    ) async throws -> String {
        guard let orgId = currentOrganization?.firestoreDocumentId, !orgId.isEmpty else {
            throw AnnualLeaveAdjustmentRefused(message: "Organisation not loaded.")
        }
        guard let uid = auth.currentUser?.uid else {
            throw AnnualLeaveAdjustmentRefused(message: "Not signed in.")
        }
        if let problem = CanonicalBusinessEngine.annualLeaveAdjustmentValidationError(days: days, reason: reason) {
            throw AnnualLeaveAdjustmentRefused(message: problem)
        }
        guard var fields = CanonicalBusinessEngine.annualLeaveAdjustmentCreateFields(
            userId: subject.id,
            days: days,
            reason: reason,
            yearKey: yearKey,
            createdBy: uid,
            createdByName: actorName
        ) else {
            throw AnnualLeaveAdjustmentRefused(message: "That adjustment could not be saved.")
        }
        fields["createdAt"] = FieldValue.serverTimestamp()
        let ref = db.collection("organizations").document(orgId)
            .collection(CanonicalBusinessEngine.annualLeaveAdjustmentsCollection)
            .document(UUID().uuidString)
        try await ref.setData(WriteMetadata.stamped(fields, userId: uid))
        return ref.documentID
    }
}

/// One screen's live adjustments (the people it shows). `stop()` removes the listeners.
@MainActor
final class AnnualLeaveAdjustmentsModel: ObservableObject {
    @Published private(set) var adjustments: [AnnualLeaveAdjustmentRecord] = []
    private var registrations: [ListenerRegistration] = []
    private var parts: [Int: [AnnualLeaveAdjustmentRecord]] = [:]
    private var listenedKey = ""

    /// Listens to the adjustments of `userIds` (a no-op when they are the ones already listened to).
    func listen(backend: FirebaseBackend, userIds: [String]) {
        let ids = Array(Set(userIds.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty })).sorted()
        let key = ([backend.currentOrganization?.firestoreDocumentId ?? ""] + ids).joined(separator: "|")
        guard key != listenedKey else { return }
        stop()
        listenedKey = key
        registrations = backend.listenAnnualLeaveAdjustments(userIds: ids) { [weak self] chunk, rows in
            guard let self else { return }
            self.parts[chunk] = rows
            self.adjustments = self.parts.keys.sorted().flatMap { self.parts[$0] ?? [] }
        }
    }

    func stop() {
        registrations.forEach { $0.remove() }
        registrations = []
        parts = [:]
        adjustments = []
        listenedKey = ""
    }

    /// The adjustments filed under any of `ids` (ids compare without case).
    func rows(for ids: [String]) -> [AnnualLeaveAdjustmentRecord] {
        let keys = Set(ids.map { $0.lowercased() })
        return adjustments
            .filter { keys.contains($0.userId.lowercased()) }
            .sorted { ($0.createdAtMs ?? .greatestFiniteMagnitude) < ($1.createdAtMs ?? .greatestFiniteMagnitude) }
    }
}
