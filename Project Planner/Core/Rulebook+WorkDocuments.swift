//
//  Rulebook+WorkDocuments.swift
//  Project Planner
//
//  Rulebook 1.7.0 (docs/RULEBOOK.md §1 "Document readers" and "Partial writes only", §2, §8): the work
//  collections — `projects`, `smallWorks`, `bookings` (edits), `subcontractorBookings`, timesheet price work and
//  expense entries, `settings/deadlines_*` and `settings/deadlineAssignments` — are read only through the packed
//  script's readers (web `lib/canonical/workDocumentReaders.ts`) and saved only with its partial-write helpers.
//  Ids are the document id or stored id in stored case; a non-UUID id is kept. Nothing is decided here: Swift
//  converts Firestore values to JSON, calls the script and reads its answer (`CanonicalDocumentRow`, 1.6.0).
//

import Foundation
import FirebaseFirestore

/// In-app UUIDs for stored work-document ids (job, client, firm, contact, entry, deadline ids). A stored id that
/// is a UUID is used as is; any other id gets `Manager.stableId(forFirestoreDocumentId:)` (1.6.0), and the stored
/// spelling is remembered in `OperativeKeyRegistry` so a save writes the id back exactly as stored.
nonisolated enum WorkDocumentKeys {
    /// The in-app UUID for a stored id. Remembers the stored spelling when `uuidString` would not spell it.
    static func inAppId(for raw: String) -> UUID {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let id = Manager.stableId(forFirestoreDocumentId: trimmed)
        if !trimmed.isEmpty, trimmed != id.uuidString {
            OperativeKeyRegistry.shared.remember(raw: trimmed, as: id)
        }
        return id
    }

    /// The stored id for an in-app UUID: `key` when it names `id`, else the remembered stored id, else `uuidString`.
    static func storedId(for id: UUID, key: String? = nil) -> String {
        if let key = key?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty,
           Manager.stableId(forFirestoreDocumentId: key) == id {
            return key
        }
        return OperativeKeyRegistry.shared.rawKey(for: id) ?? id.uuidString
    }
}

/// `deadlineAssignmentWriteFields` result: one job's assignees written with a field path (`['projects', KEY]`)
/// as a partial update, never a merge-set with a dotted key. `createFields` only when the document is missing.
nonisolated struct CanonicalDeadlineAssignmentWrite {
    let fieldPath: [String]
    let value: [String]
    let createFields: [String: Any]

    init?(_ raw: Any?) {
        guard let row = raw as? [String: Any],
              let path = row["fieldPath"] as? [Any],
              let value = row["value"] as? [Any],
              let create = row["createFields"] as? [String: Any] else { return nil }
        fieldPath = path.compactMap { $0 as? String }
        self.value = value.compactMap { $0 as? String }
        createFields = create
        guard fieldPath.count == 2 else { return nil }
    }
}

extension CanonicalBusinessEngine {
    // MARK: Jobs

    /// `parseJobDocument(docId, data, { kind, timeZone })` for `projects` (`smallWorks` false) or `smallWorks`.
    /// Nil for the legacy placeholder or a blank id. Start falls back to `createdAt`, end to the start.
    nonisolated static func parseJobDocument(
        documentId: String,
        data: [String: Any],
        smallWorks: Bool,
        timeZone: String = OrganizationRulebookContext.timeZoneIdentifier
    ) -> CanonicalDocumentRow? {
        let options: [String: Any] = ["kind": smallWorks ? "smallWorks" : "projects", "timeZone": timeZone]
        return CanonicalDocumentRow(callJSON("parseJobDocument", arguments: [documentId, peopleDocumentJSON(data), options]))
    }

    // MARK: Bookings (edit)

    /// `bookingUpdateWriteFields(before, next)`: the partial update of an existing booking. Empty when
    /// `before` is nil (an edit never creates a booking). Nil when the script did not answer.
    nonisolated static func bookingUpdateWrite(before: [String: Any]?, next: [String: Any]) -> CanonicalDocumentWrite? {
        peopleDocumentWrite("bookingUpdateWriteFields", before: before, next: next)
    }

    /// `bookingsToRemoveOnProjectDelete({ bookings, projectId, nowIso, timeZone })`: the job's bookings dated
    /// today or later in the organisation zone. Past bookings stay. Nil when the script did not answer.
    nonisolated static func bookingsToRemoveOnProjectDelete(
        _ bookings: [(id: String, projectId: String, date: Date)],
        projectId: String,
        now: Date,
        timeZone: String = OrganizationRulebookContext.timeZoneIdentifier
    ) -> [String]? {
        let input: [String: Any] = [
            "bookings": bookings.map { ["id": $0.id, "projectId": $0.projectId, "dateMs": $0.date.timeIntervalSince1970 * 1000] as [String: Any] },
            "projectId": projectId,
            "nowIso": ISO8601DateFormatter().string(from: now),
            "timeZone": timeZone,
        ]
        guard let rows = callJSON("bookingsToRemoveOnProjectDelete", arguments: [input]) as? [Any] else { return nil }
        return rows.compactMap { $0 as? String }
    }

    // MARK: Subcontractor bookings

    /// `parseSubcontractorBookingDocument(docId, data, { timeZone })`: nil without a firm, job or date, or with an
    /// unreadable status or slot. Missing status is Confirmed; missing slot FULL DAY.
    nonisolated static func parseSubcontractorBookingDocument(
        documentId: String,
        data: [String: Any],
        timeZone: String = OrganizationRulebookContext.timeZoneIdentifier
    ) -> CanonicalDocumentRow? {
        CanonicalDocumentRow(callJSON(
            "parseSubcontractorBookingDocument",
            arguments: [documentId, peopleDocumentJSON(data), ["timeZone": timeZone] as [String: Any]]
        ))
    }

    /// `subcontractorBookingCreateFields(input)`: the stored shape of a new subcontractor booking (milliseconds for
    /// `date`, `createdAt`, `updatedAt`). Nil when the input is refused or the script did not answer.
    nonisolated static func subcontractorBookingCreateFields(
        id: String,
        subcontractorId: String,
        projectId: String,
        date: Date,
        timeSlot: String,
        workStartTime: String?,
        workEndTime: String?,
        isBreakRemoved: Bool,
        bookedBy: String,
        status: String,
        bookedContactIds: [String],
        bookedOperativeNames: [String],
        createdAt: Date
    ) -> [String: Any]? {
        let input: [String: Any] = [
            "id": id,
            "subcontractorId": subcontractorId,
            "projectId": projectId,
            "dateMs": date.timeIntervalSince1970 * 1000,
            "timeSlot": timeSlot,
            "workStartTime": workStartTime ?? NSNull(),
            "workEndTime": workEndTime ?? NSNull(),
            "isBreakRemoved": isBreakRemoved,
            "bookedBy": bookedBy,
            "status": status,
            "bookedContactIds": bookedContactIds,
            "bookedOperativeNames": bookedOperativeNames,
            "createdAtMs": createdAt.timeIntervalSince1970 * 1000,
        ]
        guard let result = callJSON("subcontractorBookingCreateFields", arguments: [input]) as? [String: Any],
              (result["ok"] as? Bool) == true,
              let fields = result["fields"] as? [String: Any] else { return nil }
        return fields
    }

    /// `subcontractorBookingWriteFields(before, next)`: the partial update of an existing subcontractor booking.
    /// Empty when `before` is nil (an edit never re-creates a deleted booking).
    nonisolated static func subcontractorBookingWrite(before: [String: Any]?, next: [String: Any]) -> CanonicalDocumentWrite? {
        peopleDocumentWrite("subcontractorBookingWriteFields", before: before, next: next)
    }

    // MARK: Timesheet entries

    /// `parseTimesheetEntries(sheetDocId, sheet, { timeZone })`: `expenseEntries` and `priceWorkEntries` rows. Each
    /// keeps its stored id (any case, UUID or not); an entry with none gets `timesheetEntryId`. The decision in
    /// effect is `timesheetEntryDecision` for that id. Nil when the script did not answer.
    nonisolated static func parseTimesheetEntries(
        sheetDocumentId: String,
        sheet: [String: Any],
        timeZone: String = OrganizationRulebookContext.timeZoneIdentifier
    ) -> CanonicalDocumentRow? {
        CanonicalDocumentRow(callJSON(
            "parseTimesheetEntries",
            arguments: [sheetDocumentId, peopleDocumentJSON(sheet), ["timeZone": timeZone] as [String: Any]]
        ))
    }

    // MARK: Deadlines

    /// `deadlineProjectKey(projectId)`: the job key in deadline documents (trimmed, upper case).
    nonisolated static func deadlineProjectKey(_ projectId: String) -> String? {
        guard let key = callJSON("deadlineProjectKey", arguments: [projectId]) as? String, !key.isEmpty else { return nil }
        return key
    }

    /// `deadlinesDocumentId(projectId, isSmallWorks)`: `deadlines_{projects|smallWorks}_{KEY}`.
    nonisolated static func deadlinesDocumentId(projectId: String, isSmallWorks: Bool) -> String? {
        callJSON("deadlinesDocumentId", arguments: [projectId, isSmallWorks]) as? String
    }

    /// `parseDeadlineDocument(docId, data, { projectId, timeZone })`: `items` with stored ids, ordered by due day.
    nonisolated static func parseDeadlineDocument(
        documentId: String,
        data: [String: Any],
        projectId: String?,
        timeZone: String = OrganizationRulebookContext.timeZoneIdentifier
    ) -> CanonicalDocumentRow? {
        let options: [String: Any] = ["projectId": projectId ?? NSNull(), "timeZone": timeZone]
        return CanonicalDocumentRow(callJSON("parseDeadlineDocument", arguments: [documentId, peopleDocumentJSON(data), options]))
    }

    /// `parseDeadlineItem(raw, { projectId, timeZone })`: one deadline item; nil without an id.
    nonisolated static func parseDeadlineItem(
        _ item: [String: Any],
        projectId: String?,
        timeZone: String = OrganizationRulebookContext.timeZoneIdentifier
    ) -> CanonicalDocumentRow? {
        let options: [String: Any] = ["projectId": projectId ?? NSNull(), "timeZone": timeZone]
        return CanonicalDocumentRow(callJSON("parseDeadlineItem", arguments: [peopleDocumentJSON(item), options]))
    }

    /// `parseDeadlineAssignments(data)`: job key → assignee ids (the nested `projects` map and older literal
    /// `projects.{KEY}` fields).
    nonisolated static func parseDeadlineAssignments(_ data: [String: Any]) -> [String: [String]]? {
        guard let map = callJSON("parseDeadlineAssignments", arguments: [peopleDocumentJSON(data)]) as? [String: Any] else { return nil }
        return map.mapValues { ($0 as? [Any])?.compactMap { $0 as? String } ?? [] }
    }

    /// `deadlineAssignedProjectIds(data, personIds)`: job keys (as stored) whose assignees include the person.
    nonisolated static func deadlineAssignedProjectIds(_ data: [String: Any], personIds: [String]) -> [String]? {
        guard let rows = callJSON("deadlineAssignedProjectIds", arguments: [peopleDocumentJSON(data), personIds]) as? [Any] else { return nil }
        return rows.compactMap { $0 as? String }
    }

    /// `deadlineAssignmentWriteFields({ projectId, assigneeUserIds })`. Nil without a job id.
    nonisolated static func deadlineAssignmentWriteFields(projectId: String, assigneeUserIds: [String]) -> CanonicalDeadlineAssignmentWrite? {
        let input: [String: Any] = ["projectId": projectId, "assigneeUserIds": assigneeUserIds]
        return CanonicalDeadlineAssignmentWrite(callJSON("deadlineAssignmentWriteFields", arguments: [input]))
    }
}
