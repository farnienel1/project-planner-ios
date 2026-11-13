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
import Combine
import FirebaseAuth
@preconcurrency import FirebaseFirestore

/// Why an adjustment was not saved: the rulebook refused it, or there is no organisation or signed-in person.
nonisolated struct AnnualLeaveAdjustmentRefused: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

extension FirebaseBackend {
    /// Live adjustments filed under these users ids — one `userId ==` query per id (review r306 #7): an `in` query is
    /// refused whole when any one id is not readable (a membership-only report, whose users document names another
    /// company, is not line-managed for the security rules), so a refused id never hides the others. Each listener
    /// reports its id's rows, or that its read was refused (`failed`), never an empty list in place of a refusal.
    func listenAnnualLeaveAdjustments(
        userIds: [String],
        onUpdate: @escaping (_ userId: String, _ rows: [AnnualLeaveAdjustmentRecord]?, _ failed: Bool) -> Void
    ) -> [ListenerRegistration] {
        guard let orgId = currentOrganization?.firestoreDocumentId, !orgId.isEmpty else { return [] }
        let ids = userIds.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard !ids.isEmpty else { return [] }
        let collection = db.collection("organizations").document(orgId)
            .collection(CanonicalBusinessEngine.annualLeaveAdjustmentsCollection)
        return ids.map { id in
            collection.whereField("userId", isEqualTo: id).addSnapshotListener { snapshot, error in
                guard let snapshot, error == nil else {
                    Task { @MainActor in onUpdate(id, nil, true) }
                    return
                }
                let rows = snapshot.documents.compactMap { doc in
                    CanonicalBusinessEngine.parseAnnualLeaveAdjustmentDocument(
                        docId: doc.documentID,
                        data: FirebaseBackend.firestoreJSON(doc.data()) as? [String: Any] ?? [:]
                    )
                }
                Task { @MainActor in onUpdate(id, rows, false) }
            }
        }
    }

    /// Adds one adjustment for `subject` in the leave year `yearKey` (online only). Throws when the rulebook refuses it
    /// or the write fails; the caller then tells every admin (`NotificationService.notifyAnnualLeaveAdjusted`).
    func addAnnualLeaveAdjustment(
        subject: AppUser,
        days: Double,
        reason: String,
        yearKey: String
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
            // The screen's current leave year is the only year offered (review r306 #6).
            allowedYearKeys: [yearKey]
        ) else {
            throw AnnualLeaveAdjustmentRefused(message: "That adjustment could not be saved.")
        }
        // The rules require the request time (review r306 #6).
        fields["createdAt"] = FieldValue.serverTimestamp()
        let ref = db.collection("organizations").document(orgId)
            .collection(CanonicalBusinessEngine.annualLeaveAdjustmentsCollection)
            .document(UUID().uuidString)
        try await ref.setData(WriteMetadata.stamped(fields, userId: uid))
        return ref.documentID
    }
}

/// One screen's live adjustments (the people it shows). `stop()` removes the listeners. Review r306 #9: a screen shows
/// a balance only once `isLoaded(for:)` is true, and shows `readError` when `failed(for:)` — never zero adjustments in
/// place of a refused read.
@MainActor
final class AnnualLeaveAdjustmentsModel: ObservableObject {
    static let readError = "Could not load the leave adjustments, so the balance is not shown. Try again."

    @Published private(set) var adjustments: [AnnualLeaveAdjustmentRecord] = []
    @Published private(set) var loadedIds: Set<String> = []
    @Published private(set) var failedIds: Set<String> = []
    private var registrations: [ListenerRegistration] = []
    private var parts: [String: [AnnualLeaveAdjustmentRecord]] = [:]
    private var listenedIds: Set<String> = []
    private var listenedKey = ""

    /// Listens to the adjustments of `userIds` (a no-op when they are the ones already listened to).
    func listen(backend: FirebaseBackend, userIds: [String]) {
        let ids = Array(Set(userIds.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty })).sorted()
        let key = ([backend.currentOrganization?.firestoreDocumentId ?? ""] + ids).joined(separator: "|")
        guard key != listenedKey else { return }
        stop()
        listenedKey = key
        listenedIds = Set(ids.map { $0.lowercased() })
        registrations = backend.listenAnnualLeaveAdjustments(userIds: ids) { [weak self] id, rows, failed in
            guard let self else { return }
            let lower = id.lowercased()
            if failed {
                self.parts[lower] = nil
                self.loadedIds.remove(lower)
                self.failedIds.insert(lower)
            } else {
                self.parts[lower] = rows ?? []
                self.failedIds.remove(lower)
                self.loadedIds.insert(lower)
            }
            self.adjustments = self.parts.keys.sorted().flatMap { self.parts[$0] ?? [] }
        }
    }

    func stop() {
        registrations.forEach { $0.remove() }
        registrations = []
        parts = [:]
        adjustments = []
        loadedIds = []
        failedIds = []
        listenedIds = []
        listenedKey = ""
    }

    /// The adjustments filed under any of `ids` (ids compare without case).
    func rows(for ids: [String]) -> [AnnualLeaveAdjustmentRecord] {
        let keys = Set(ids.map { $0.lowercased() })
        return adjustments
            .filter { keys.contains($0.userId.lowercased()) }
            .sorted { ($0.createdAtMs ?? .greatestFiniteMagnitude) < ($1.createdAtMs ?? .greatestFiniteMagnitude) }
    }

    /// Whether every listened id among `ids` has answered (ids this model does not listen to are not waited for).
    func isLoaded(for ids: [String]) -> Bool {
        let wanted = Set(ids.map { $0.lowercased() }).intersection(listenedIds)
        guard !listenedIds.isEmpty else { return false }
        return wanted.isSubset(of: loadedIds)
    }

    /// Whether the read of any listened id among `ids` was refused.
    func failed(for ids: [String]) -> Bool {
        !Set(ids.map { $0.lowercased() }).intersection(failedIds).isEmpty
    }
}
