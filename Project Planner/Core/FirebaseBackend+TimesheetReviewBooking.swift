//
//  FirebaseBackend+TimesheetReviewBooking.swift
//  Project Planner
//
//  RULEBOOK 1.72.0 §8 / §16 (owner decisions 23 Nov, A and B): the line manager's ⚙ and ✕ on a timesheet line under
//  review write the BOOKING. The writes are the rulebook's (`timesheetReviewBookingEditWrites`,
//  `timesheetReviewOvertimeStrike`, `timesheetReviewBookingDelete`); this file only reads the live booking and sends
//  them. Online only (an approval, §2).
//
//  RULEBOOK 1.74.0 (owner decision 23 Nov): every write also records the edit on the sheet under review in the SAME
//  batch (`reviewerBookingEdits.{key}`, `timesheetReviewerBookingEditRecord`, plus the server `editedAt`), so the sheet
//  stays with the reviewer. Without a record (nothing to record) the booking is written alone and the 1.47.0 rule sends
//  the sheet back to the person, as 1.72.0.
//

import Foundation
import FirebaseFirestore
import FirebaseAuth

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

    /// RULEBOOK 1.74.0: adds `reviewerBookingEdits.{key}` (the record plus the server `editedAt`) and write metadata to
    /// the sheet `settings/{sheetDocumentId}` in `batch` — a field-path update, so no other recorded edit and no other
    /// sheet field is touched. The person never writes it (§16); only a reviewer's booking write calls this.
    private func addReviewerBookingEdit(
        to batch: WriteBatch,
        org: DocumentReference,
        record: TimesheetReviewerEditSheetRecord
    ) {
        var value = record.edit.value
        value["editedAt"] = FieldValue.serverTimestamp()
        var fields: [AnyHashable: Any] = [
            FieldPath([CanonicalBusinessEngine.timesheetReviewerBookingEditsField, record.edit.key]): value,
        ]
        for (key, metadata) in WriteMetadata.fields(userId: auth.currentUser?.uid) { fields[key] = metadata }
        batch.updateData(fields, forDocument: org.collection("settings").document(record.sheetDocumentId))
    }

    /// ⚙ (or ✕ on an overtime line that trims): the rulebook's `set` / `remove` as one partial update with write
    /// metadata. An update never re-creates a booking deleted elsewhere (not-found → the missing message).
    /// RULEBOOK 1.74.0: with `sheetRecord`, the sheet's `reviewerBookingEdits.{key}` is written in the same batch (both
    /// or neither).
    func applyTimesheetReviewBookingUpdate(
        collection: String,
        bookingId: String,
        set: [String: Any],
        remove: [String],
        sheetRecord: TimesheetReviewerEditSheetRecord? = nil
    ) async throws {
        let org = try reviewBookingOrganizationRef()
        var update: [String: Any] = [:]
        for (key, value) in set { update[key] = value is NSNull ? FieldValue.delete() : value }
        for key in remove { update[key] = FieldValue.delete() }
        guard !update.isEmpty else { return }
        let batch = db.batch()
        batch.updateData(WriteMetadata.stamped(update, userId: auth.currentUser?.uid), forDocument: org.collection(collection).document(bookingId))
        if let sheetRecord { addReviewerBookingEdit(to: batch, org: org, record: sheetRecord) }
        do {
            try await batch.commit()
        } catch {
            throw TimesheetReviewBookingWriteError.from(error)
        }
    }

    /// ✕: the booking delete and its tombstone (`timesheetReviewBookingDelete`, plus the server `deletedAt`) in ONE batch.
    /// RULEBOOK 1.74.0: with `sheetRecord`, the sheet's `reviewerBookingEdits.{key}` (recorded deleted) is in that batch.
    func deleteTimesheetReviewBooking(
        _ plan: RulebookTimesheetReviewBookingDelete,
        sheetRecord: TimesheetReviewerEditSheetRecord? = nil
    ) async throws {
        let org = try reviewBookingOrganizationRef()
        var tombstone = plan.tombstone
        tombstone["deletedAt"] = FieldValue.serverTimestamp()
        let batch = db.batch()
        batch.deleteDocument(org.collection(plan.collection).document(plan.bookingId))
        batch.setData(tombstone, forDocument: org.collection(CanonicalBusinessEngine.bookingTombstoneCollection).document(plan.bookingId))
        if let sheetRecord { addReviewerBookingEdit(to: batch, org: org, record: sheetRecord) }
        do {
            try await batch.commit()
        } catch {
            throw TimesheetReviewBookingWriteError.from(error)
        }
    }
}

/// RULEBOOK 1.74.0: the sheet a reviewer's booking write is recorded on — its stored document id (the version the review
/// shows, `TimesheetDraft.versionDocumentId`) and the record (`timesheetReviewerBookingEditRecord`).
nonisolated struct TimesheetReviewerEditSheetRecord {
    var sheetDocumentId: String
    var edit: RulebookTimesheetReviewerBookingEdit
}
