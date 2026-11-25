//
//  Rulebook+TimesheetReviewerUndo.swift
//  Project Planner
//
//  RULEBOOK 1.90.0 §8 (owner request 24 Nov; web `lib/canonical/timesheetReviewerUndo.ts`,
//  `lib/timesheets/timesheetReviewerUndoWrite.ts`). "Cancel changes" undoes what the line manager (or an admin) changed
//  while making changes to a timesheet:
//  - every reviewer booking write records the booking's values BEFORE the edit (`timesheetReviewerEditBefore`; for ✕ the
//    whole stored booking), keeping the session's first values (`existing`);
//  - a price work / expense decision changed in the session records the review it replaced
//    (`timesheetReviewerReviewRecord`, never a late extra's);
//  - Cancel changes runs `timesheetReviewerUndoPlan`: one transaction per booking (the sheet, the booking and its
//    tombstone read fresh) — a booking put back, a removed booking re-created under a NEW id with the two records of
//    `timesheetReviewerRestoredRecords`, or left as it is and named; then the reviews in one transaction.
//  Swift only builds the script's inputs, reads its answers and writes them (AGENTS.md Rule 0).
//

import Foundation
import FirebaseFirestore
import FirebaseAuth

/// One action of `timesheetReviewerUndoPlan`.
nonisolated enum RulebookTimesheetReviewerUndoAction {
    case restore(key: String, collection: String, bookingId: String, set: [String: Any], remove: [String])
    case recreate(key: String, collection: String, oldBookingId: String, data: [String: Any])
    case refuse(key: String, collection: String, bookingId: String, message: String)

    var key: String {
        switch self {
        case .restore(let key, _, _, _, _), .recreate(let key, _, _, _), .refuse(let key, _, _, _): return key
        }
    }

    init?(json: Any?) {
        guard let row = json as? [String: Any], let kind = row["kind"] as? String,
              let key = row["key"] as? String, !key.isEmpty else { return nil }
        let collection = row["collection"] as? String ?? "bookings"
        switch kind {
        case "restore":
            guard let bookingId = row["bookingId"] as? String else { return nil }
            self = .restore(
                key: key, collection: collection, bookingId: bookingId,
                set: row["set"] as? [String: Any] ?? [:], remove: row["remove"] as? [String] ?? []
            )
        case "recreate":
            guard let oldBookingId = row["oldBookingId"] as? String, let data = row["data"] as? [String: Any] else { return nil }
            self = .recreate(key: key, collection: collection, oldBookingId: oldBookingId, data: data)
        case "refuse":
            self = .refuse(
                key: key, collection: collection, bookingId: row["bookingId"] as? String ?? "",
                message: row["message"] as? String ?? CanonicalBusinessEngine.timesheetReviewerUndoNotAllowedMessage
            )
        default:
            return nil
        }
    }
}

/// `timesheetReviewerUndoPlan` → the writes that undo the current session.
nonisolated struct RulebookTimesheetReviewerUndoPlan {
    var actions: [RulebookTimesheetReviewerUndoAction]
    /// Dotted `extraEntryReviews.{id}` values to put back.
    var reviewSet: [String: Any]
    /// Dotted `extraEntryReviews.{id}` paths to remove.
    var reviewRemove: [String]
    /// `reviewerBookingEdits.{key}` records to remove once their write succeeded.
    var removeRecordKeys: [String]
    var changeCount: Int
}

/// One record of `timesheetReviewerSessionRecords`.
nonisolated struct RulebookTimesheetReviewerSessionRecord {
    var key: String
    /// `booking` or `review`.
    var kind: String
    var value: [String: Any]
}

extension CanonicalBusinessEngine {
    private nonisolated static func undoText(_ name: String, fallback: String) -> String {
        constant(name, as: String.self) ?? fallback
    }

    /// `TIMESHEET_REVIEWER_CANCEL_CHANGES_LABEL` ("Cancel changes").
    nonisolated static var timesheetReviewerCancelChangesLabel: String {
        undoText("TIMESHEET_REVIEWER_CANCEL_CHANGES_LABEL", fallback: "Cancel changes")
    }

    /// `TIMESHEET_REVIEWER_CANCEL_CHANGES_DONE_MESSAGE`.
    nonisolated static var timesheetReviewerCancelChangesDoneMessage: String {
        undoText(
            "TIMESHEET_REVIEWER_CANCEL_CHANGES_DONE_MESSAGE",
            fallback: "Changes cancelled. The timesheet is as it was before you made changes."
        )
    }

    /// `TIMESHEET_REVIEWER_UNDO_NOT_ALLOWED_MESSAGE`.
    nonisolated static var timesheetReviewerUndoNotAllowedMessage: String {
        undoText(
            "TIMESHEET_REVIEWER_UNDO_NOT_ALLOWED_MESSAGE",
            fallback: "You can't book this job, so this removed booking can't be put back. Ask an admin or the job's manager to book it again."
        )
    }

    /// `timesheetReviewerBookingEditKey(collection, bookingId)`: the record's key on the sheet. Nil for an unusable id.
    nonisolated static func timesheetReviewerBookingEditKey(collection: String, bookingId: String) -> String? {
        guard let key = callJSON("timesheetReviewerBookingEditKey", arguments: [collection, bookingId]) as? String, !key.isEmpty else {
            return nil
        }
        return key
    }

    /// `timesheetReviewerEditBefore({ data, deleted })`: the before-values a reviewer edit stores (JSON shape; the writer
    /// turns `{ seconds, nanoseconds }` back into Timestamps). `data` is the stored booking read fresh, without the
    /// reader's `id` / `collection` keys. Nil when there is nothing.
    nonisolated static func timesheetReviewerEditBefore(data: [String: Any], deleted: Bool) -> [String: Any]? {
        var stored = data
        stored.removeValue(forKey: "id")
        stored.removeValue(forKey: "collection")
        return callJSON("timesheetReviewerEditBefore", arguments: [["data": stored, "deleted": deleted]]) as? [String: Any]
    }

    /// `timesheetReviewerReviewRecord({ sheet, entryId, before, editedBy, makingChanges, after })`. Nil when nothing is
    /// recorded (no session, exported, a late extra, or already recorded in the session).
    nonisolated static func timesheetReviewerReviewRecord(
        sheet: [String: Any],
        entryId: String,
        before: [String: Any]?,
        editedBy: String,
        makingChanges: Bool,
        after: [String: Any]?
    ) -> RulebookTimesheetReviewerBookingEdit? {
        let input: [String: Any] = [
            "sheet": sheet,
            "entryId": entryId,
            "before": before.map { $0 as Any } ?? NSNull(),
            "editedBy": editedBy,
            "makingChanges": makingChanges,
            "after": after.map { $0 as Any } ?? NSNull(),
        ]
        guard let row = callJSON("timesheetReviewerReviewRecord", arguments: [input]) as? [String: Any],
              let key = row["key"] as? String, !key.isEmpty, let value = row["value"] as? [String: Any] else { return nil }
        return RulebookTimesheetReviewerBookingEdit(key: key, value: value)
    }

    /// `timesheetReviewerSessionRecords(sheet)`: the records of the current making-changes session still to undo.
    nonisolated static func timesheetReviewerSessionRecords(_ sheet: [String: Any]) -> [RulebookTimesheetReviewerSessionRecord] {
        guard let rows = callJSON("timesheetReviewerSessionRecords", arguments: [sheet]) as? [[String: Any]] else { return [] }
        return rows.compactMap { row in
            guard let key = row["key"] as? String, !key.isEmpty else { return nil }
            return RulebookTimesheetReviewerSessionRecord(
                key: key,
                kind: row["kind"] as? String ?? "booking",
                value: row["value"] as? [String: Any] ?? [:]
            )
        }
    }

    /// `timesheetReviewerCancelChangesOffered({ sheet, viewerIsReviewer, viewerIsSubject })`. False when the script did
    /// not answer (nothing is offered that could not be planned).
    nonisolated static func timesheetReviewerCancelChangesOffered(sheet: [String: Any], viewerIsReviewer: Bool, viewerIsSubject: Bool) -> Bool {
        let input: [String: Any] = ["sheet": sheet, "viewerIsReviewer": viewerIsReviewer, "viewerIsSubject": viewerIsSubject]
        return callJSON("timesheetReviewerCancelChangesOffered", arguments: [input]) as? Bool ?? false
    }

    /// `timesheetReviewerCancelChangesConfirmMessage(n)`.
    nonisolated static func timesheetReviewerCancelChangesConfirmMessage(_ changeCount: Int) -> String {
        callJSON("timesheetReviewerCancelChangesConfirmMessage", arguments: [changeCount]) as? String
            ?? "Cancel the changes you made? Bookings go back to how they were and your decisions on price work and expenses are undone."
    }

    /// `timesheetReviewerUndoPlan({ sheet, bookings, timeZone })`. `bookings` rows: `collection`, `bookingId`, `data`
    /// (the stored booking as `firestoreJSON`, or NSNull when missing) and `tombstoned`. Nil when the script did not answer.
    nonisolated static func timesheetReviewerUndoPlan(sheet: [String: Any], bookings: [[String: Any]]) -> RulebookTimesheetReviewerUndoPlan? {
        let input: [String: Any] = [
            "sheet": sheet,
            "bookings": bookings,
            "timeZone": OrganizationRulebookContext.timeZoneIdentifier,
        ]
        guard let row = callJSON("timesheetReviewerUndoPlan", arguments: [input]) as? [String: Any] else { return nil }
        let reviews = row["reviews"] as? [String: Any] ?? [:]
        return RulebookTimesheetReviewerUndoPlan(
            actions: (row["actions"] as? [Any] ?? []).compactMap { RulebookTimesheetReviewerUndoAction(json: $0) },
            reviewSet: reviews["set"] as? [String: Any] ?? [:],
            reviewRemove: reviews["remove"] as? [String] ?? [],
            removeRecordKeys: row["removeRecordKeys"] as? [String] ?? [],
            changeCount: (row["changeCount"] as? NSNumber)?.intValue ?? 0
        )
    }

    /// `timesheetReviewerRestoredRecords(...)`: after a removed booking is re-created under `newBookingId`, the old record
    /// (marked `restoredAs`) and the new booking's record (`restoredFrom`). Nil when either cannot be built.
    nonisolated static func timesheetReviewerRestoredRecords(
        sheet: [String: Any],
        oldKey: String,
        oldRecord: [String: Any],
        collection: String,
        newBookingId: String,
        createdDoc: [String: Any],
        editedBy: String
    ) -> (old: RulebookTimesheetReviewerBookingEdit, created: RulebookTimesheetReviewerBookingEdit)? {
        let input: [String: Any] = [
            "sheet": sheet,
            "oldKey": oldKey,
            "oldRecord": oldRecord,
            "collection": collection,
            "newBookingId": newBookingId,
            "createdDoc": createdDoc,
            "editedBy": editedBy,
            "timeZone": OrganizationRulebookContext.timeZoneIdentifier,
        ]
        guard let row = callJSON("timesheetReviewerRestoredRecords", arguments: [input]) as? [String: Any],
              let old = row["old"] as? [String: Any], let created = row["created"] as? [String: Any],
              let oldKey = old["key"] as? String, let oldValue = old["value"] as? [String: Any],
              let newKey = created["key"] as? String, let newValue = created["value"] as? [String: Any] else { return nil }
        return (
            RulebookTimesheetReviewerBookingEdit(key: oldKey, value: oldValue),
            RulebookTimesheetReviewerBookingEdit(key: newKey, value: newValue)
        )
    }
}

/// The script's JSON values written back to Firestore: a `{ seconds, nanoseconds }` map (how `FirebaseBackend.firestoreJSON`
/// passes a Timestamp) becomes a Timestamp again, so a recorded or re-created booking keeps its stored date type (the
/// booking queries filter on a Timestamp `date`).
nonisolated enum TimesheetReviewerFirestoreValue {
    static func value(_ json: Any) -> Any {
        switch json {
        case let map as [String: Any]:
            if map.count == 2, let seconds = map["seconds"] as? NSNumber, let nanoseconds = map["nanoseconds"] as? NSNumber {
                return Timestamp(seconds: seconds.int64Value, nanoseconds: nanoseconds.int32Value)
            }
            return map.mapValues { value($0) }
        case let list as [Any]:
            return list.map { value($0) }
        default:
            return json
        }
    }

    static func map(_ json: [String: Any]) -> [String: Any] {
        json.mapValues { value($0) }
    }
}

/// The outcome of Cancel changes.
nonisolated struct TimesheetReviewerUndoResult {
    /// Changes undone.
    var undone: Int
    /// Bookings left as they are, with the reason to show.
    var refused: [(bookingId: String, message: String)]

    /// The message to show after Cancel changes.
    var message: String {
        if refused.isEmpty { return CanonicalBusinessEngine.timesheetReviewerCancelChangesDoneMessage }
        let reasons = refused.map { $0.message }
        var seen = Set<String>()
        let unique = reasons.filter { seen.insert($0).inserted }
        return unique.joined(separator: "\n")
    }
}

extension FirebaseBackend {
    /// RULEBOOK 1.90.0 §8: Cancel changes on the sheet `settings/{documentId}` (web `cancelTimesheetReviewerChanges`).
    /// Each recorded booking is undone in its own transaction that re-reads the sheet, the booking and its tombstone and
    /// plans again (`timesheetReviewerUndoPlan`), so a change made meanwhile is never overwritten and two Cancel runs at
    /// once never re-create a booking twice. Then the price work / expense decisions in one transaction.
    func cancelTimesheetReviewerChanges(organizationId: String, documentId: String) async throws -> TimesheetReviewerUndoResult {
        let org = db.collection("organizations").document(normalizedOrganizationId(organizationId))
        let writerId = Auth.auth().currentUser?.uid ?? ""
        return try await TimesheetReviewerUndoWriter.run(db: db, org: org, documentId: documentId, writerId: writerId)
    }
}

/// The writes of Cancel changes. Nonisolated: Firestore runs transaction blocks off the main thread.
nonisolated enum TimesheetReviewerUndoWriter {
    private static let checkFailedMessage = "This could not be checked against the timesheet rules. Try again; nothing was changed."

    static func run(db: Firestore, org: DocumentReference, documentId: String, writerId: String) async throws -> TimesheetReviewerUndoResult {
        let sheetRef = org.collection("settings").document(documentId)
        let firstRead = try await sheetRef.getDocument(source: .server)
        guard let firstData = firstRead.data() else { return TimesheetReviewerUndoResult(undone: 0, refused: []) }
        let records = CanonicalBusinessEngine.timesheetReviewerSessionRecords(FirebaseBackend.firestoreJSON(firstData) as? [String: Any] ?? [:])
        var undone = 0
        var refused: [(bookingId: String, message: String)] = []
        for entry in records where entry.kind == "booking" {
            let collection = (entry.value["collection"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "bookings"
            let bookingId = entry.value["bookingId"] as? String ?? ""
            guard !bookingId.isEmpty else { continue }
            do {
                let answer = try await undoBooking(
                    db: db, org: org, sheetRef: sheetRef, key: entry.key, collection: collection, bookingId: bookingId, writerId: writerId
                )
                if let message = answer {
                    refused.append((bookingId, message))
                } else {
                    undone += 1
                }
            } catch UndoSkip.skip {
                continue
            } catch {
                let nsError = error as NSError
                guard nsError.domain == "FIRFirestoreErrorDomain", nsError.code == 7 else { throw error }
                refused.append((
                    bookingId,
                    entry.value["deleted"] as? Bool == true
                        ? CanonicalBusinessEngine.timesheetReviewerUndoNotAllowedMessage
                        : "You are not allowed to change this booking — not undone."
                ))
            }
        }
        undone += try await undoReviews(db: db, sheetRef: sheetRef, writerId: writerId)
        return TimesheetReviewerUndoResult(undone: undone, refused: refused)
    }

    private enum UndoSkip: Error { case skip }

    /// One booking in one transaction. Nil when it was undone; a message when it is left as it is. Throws `.skip` when
    /// the record is no longer in the session.
    private static func undoBooking(
        db: Firestore,
        org: DocumentReference,
        sheetRef: DocumentReference,
        key entryKey: String,
        collection: String,
        bookingId: String,
        writerId: String
    ) async throws -> String? {
        let editsField = CanonicalBusinessEngine.timesheetReviewerBookingEditsField
        let metadata = WriteMetadata.fields(userId: writerId.isEmpty ? nil : writerId)
        let bookingRef = org.collection(collection).document(bookingId)
        let tombstoneRef = org.collection(CanonicalBusinessEngine.bookingTombstoneCollection).document(bookingId)
        let answer = try await db.runTransaction { transaction, errorPointer -> Any? in
            let sheetNow: DocumentSnapshot
            let booking: DocumentSnapshot
            let tombstone: DocumentSnapshot
            do {
                sheetNow = try transaction.getDocument(sheetRef)
                booking = try transaction.getDocument(bookingRef)
                tombstone = try transaction.getDocument(tombstoneRef)
            } catch {
                errorPointer?.pointee = error as NSError
                return nil
            }
            guard let rawSheet = sheetNow.data() else { return "skip" }
            let sheet = FirebaseBackend.firestoreJSON(rawSheet) as? [String: Any] ?? [:]
            let bookingJSON: Any = booking.data().map { FirebaseBackend.firestoreJSON($0) } ?? NSNull()
            guard let plan = CanonicalBusinessEngine.timesheetReviewerUndoPlan(
                sheet: sheet,
                bookings: [["collection": collection, "bookingId": bookingId, "data": bookingJSON, "tombstoned": tombstone.exists]]
            ) else { return ["refused": checkFailedMessage] }
            // Gone from the session (undone elsewhere, `restoredAs`, or signed again): nothing to do.
            guard let action = plan.actions.first(where: { $0.key == entryKey }) else { return "skip" }
            switch action {
            case .refuse(_, _, _, let message):
                return ["refused": message]
            case .restore(let key, _, _, let set, let remove):
                var update: [String: Any] = [:]
                for (field, value) in set { update[field] = TimesheetReviewerFirestoreValue.value(value) }
                for field in remove { update[field] = FieldValue.delete() }
                update["updatedAt"] = FieldValue.serverTimestamp()
                for (field, value) in metadata { update[field] = value }
                transaction.updateData(update, forDocument: bookingRef)
                var sheetUpdate: [AnyHashable: Any] = [FieldPath([editsField, key]): FieldValue.delete()]
                sheetUpdate["updatedAt"] = FieldValue.serverTimestamp()
                for (field, value) in metadata { sheetUpdate[field] = value }
                transaction.updateData(sheetUpdate, forDocument: sheetRef)
                return "done"
            case .recreate(let key, let actionCollection, _, let data):
                let newRef = org.collection(actionCollection).document()
                var createdJSON = data
                createdJSON["id"] = newRef.documentID
                let oldRecord = (sheet[editsField] as? [String: Any])?[key] as? [String: Any] ?? [:]
                guard let restored = CanonicalBusinessEngine.timesheetReviewerRestoredRecords(
                    sheet: sheet,
                    oldKey: key,
                    oldRecord: oldRecord,
                    collection: actionCollection,
                    newBookingId: newRef.documentID,
                    createdDoc: createdJSON,
                    editedBy: writerId
                ) else { return ["refused": CanonicalBusinessEngine.timesheetReviewerUndoNotAllowedMessage] }
                var created = TimesheetReviewerFirestoreValue.map(createdJSON)
                created["createdAt"] = FieldValue.serverTimestamp()
                created["updatedAt"] = FieldValue.serverTimestamp()
                for (field, value) in metadata { created[field] = value }
                transaction.setData(created, forDocument: newRef)
                var newRecord = TimesheetReviewerFirestoreValue.map(restored.created.value)
                newRecord["editedAt"] = FieldValue.serverTimestamp()
                var sheetUpdate: [AnyHashable: Any] = [
                    FieldPath([editsField, restored.old.key]): TimesheetReviewerFirestoreValue.map(restored.old.value),
                    FieldPath([editsField, restored.created.key]): newRecord,
                ]
                sheetUpdate["updatedAt"] = FieldValue.serverTimestamp()
                for (field, value) in metadata { sheetUpdate[field] = value }
                transaction.updateData(sheetUpdate, forDocument: sheetRef)
                return "done"
            }
        }
        if let text = answer as? String {
            if text == "done" { return nil }
            throw UndoSkip.skip
        }
        if let row = answer as? [String: Any], let message = row["refused"] as? String { return message }
        throw UndoSkip.skip
    }

    /// Price work / expense decisions and their records: one transaction, planned from the sheet read again.
    private static func undoReviews(db: Firestore, sheetRef: DocumentReference, writerId: String) async throws -> Int {
        let editsField = CanonicalBusinessEngine.timesheetReviewerBookingEditsField
        let metadata = WriteMetadata.fields(userId: writerId.isEmpty ? nil : writerId)
        let answer = try await db.runTransaction { transaction, errorPointer -> Any? in
            let sheetNow: DocumentSnapshot
            do {
                sheetNow = try transaction.getDocument(sheetRef)
            } catch {
                errorPointer?.pointee = error as NSError
                return nil
            }
            guard let rawSheet = sheetNow.data() else { return 0 }
            let sheet = FirebaseBackend.firestoreJSON(rawSheet) as? [String: Any] ?? [:]
            guard let plan = CanonicalBusinessEngine.timesheetReviewerUndoPlan(sheet: sheet, bookings: []) else { return 0 }
            let actionKeys = Set(plan.actions.map(\.key))
            var update: [AnyHashable: Any] = [:]
            for (dotted, value) in plan.reviewSet { update[fieldPath(dotted)] = TimesheetReviewerFirestoreValue.value(value) }
            for dotted in plan.reviewRemove { update[fieldPath(dotted)] = FieldValue.delete() }
            for key in plan.removeRecordKeys where !actionKeys.contains(key) { update[FieldPath([editsField, key])] = FieldValue.delete() }
            guard !update.isEmpty else { return 0 }
            update["updatedAt"] = FieldValue.serverTimestamp()
            for (field, value) in metadata { update[field] = value }
            transaction.updateData(update, forDocument: sheetRef)
            return plan.reviewRemove.count + plan.reviewSet.count
        }
        return (answer as? Int) ?? 0
    }

    /// `extraEntryReviews.{id}` → a two-part field path (an entry id may contain dots).
    private static func fieldPath(_ dotted: String) -> FieldPath {
        guard let dot = dotted.firstIndex(of: ".") else { return FieldPath([dotted]) }
        return FieldPath([String(dotted[..<dot]), String(dotted[dotted.index(after: dot)...])])
    }
}
