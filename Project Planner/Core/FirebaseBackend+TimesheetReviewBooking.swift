//
//  FirebaseBackend+TimesheetReviewBooking.swift
//  Project Planner
//
//  RULEBOOK 1.72.0 §8 / §16 (owner decisions 23 Nov, A and B): the line manager's ⚙ and ✕ on a timesheet line under
//  review write the BOOKING. The writes are the rulebook's (`timesheetReviewBookingEditWrites`,
//  `timesheetReviewOvertimeStrike`, `timesheetReviewBookingDelete`); this file only reads the live booking and sends
//  them. Online only (an approval, §2). The sheet then goes back to the person through the 1.47.0
//  `signedTimesheetBookingChanges` rule; nothing is written on the timesheet.
//

import Foundation
import FirebaseFirestore

/// A refused review booking write, with the rulebook's message for the screen.
nonisolated struct TimesheetReviewBookingWriteError: LocalizedError {
    let message: String
    var errorDescription: String? { message }

    /// permission-denied → `TIMESHEET_REVIEW_BOOKING_REFUSED_MESSAGE`; not-found → `TIMESHEET_REVIEW_BOOKING_MISSING_MESSAGE`.
    static func from(_ error: Error) -> TimesheetReviewBookingWriteError {
        if let known = error as? TimesheetReviewBookingWriteError { return known }
        let nsError = error as NSError
        if nsError.domain == "FIRFirestoreErrorDomain" {
            if nsError.code == 7 { return TimesheetReviewBookingWriteError(message: CanonicalBusinessEngine.timesheetReviewBookingRefusedMessage) }
            if nsError.code == 5 { return TimesheetReviewBookingWriteError(message: CanonicalBusinessEngine.timesheetReviewBookingMissingMessage) }
        }
        return TimesheetReviewBookingWriteError(message: error.localizedDescription)
    }
}

extension FirebaseBackend {
    private func reviewBookingOrganizationRef() throws -> DocumentReference {
        guard let orgId = currentOrganization?.firestoreDocumentId, !orgId.isEmpty else {
            throw NSError(domain: "FirebaseBackend", code: 0, userInfo: [NSLocalizedDescriptionKey: "No organization loaded"])
        }
        return db.collection("organizations").document(orgId)
    }

    /// The live booking from the server, read fresh before any review write: the first of `documentIds` (stored
    /// case first) that exists. Its fields as the script reads them (`firestoreJSON`) plus `id` and `collection`.
    /// Throws `TIMESHEET_REVIEW_BOOKING_MISSING_MESSAGE` when none exists.
    func readTimesheetReviewBooking(collection: String, documentIds: [String]) async throws -> [String: Any] {
        let org = try reviewBookingOrganizationRef()
        var seen = Set<String>()
        for id in documentIds where !id.isEmpty && seen.insert(id).inserted {
            let snapshot: DocumentSnapshot
            do {
                snapshot = try await org.collection(collection).document(id).getDocument(source: .server)
            } catch {
                throw TimesheetReviewBookingWriteError.from(error)
            }
            guard snapshot.exists, let data = snapshot.data() else { continue }
            var row = FirebaseBackend.firestoreJSON(data) as? [String: Any] ?? [:]
            row["id"] = snapshot.documentID
            row["collection"] = collection
            return row
        }
        throw TimesheetReviewBookingWriteError(message: CanonicalBusinessEngine.timesheetReviewBookingMissingMessage)
    }

    /// ⚙ (or ✕ on an overtime line that trims): the rulebook's `set` / `remove` as one partial `updateData` with write
    /// metadata. An update never re-creates a booking deleted elsewhere (not-found → the missing message).
    func applyTimesheetReviewBookingUpdate(collection: String, bookingId: String, set: [String: Any], remove: [String]) async throws {
        let org = try reviewBookingOrganizationRef()
        var update: [String: Any] = [:]
        for (key, value) in set { update[key] = value is NSNull ? FieldValue.delete() : value }
        for key in remove { update[key] = FieldValue.delete() }
        guard !update.isEmpty else { return }
        do {
            try await org.collection(collection).document(bookingId)
                .updateData(WriteMetadata.stamped(update, userId: auth.currentUser?.uid))
        } catch {
            throw TimesheetReviewBookingWriteError.from(error)
        }
    }

    /// ✕: the booking delete and its tombstone (`timesheetReviewBookingDelete`, plus the server `deletedAt`) in ONE batch.
    func deleteTimesheetReviewBooking(_ plan: RulebookTimesheetReviewBookingDelete) async throws {
        let org = try reviewBookingOrganizationRef()
        var tombstone = plan.tombstone
        tombstone["deletedAt"] = FieldValue.serverTimestamp()
        let batch = db.batch()
        batch.deleteDocument(org.collection(plan.collection).document(plan.bookingId))
        batch.setData(tombstone, forDocument: org.collection(CanonicalBusinessEngine.bookingTombstoneCollection).document(plan.bookingId))
        do {
            try await batch.commit()
        } catch {
            throw TimesheetReviewBookingWriteError.from(error)
        }
    }
}
