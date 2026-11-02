//
//  Rulebook+HolidayDocuments.swift
//  Project Planner
//
//  Rulebook 1.5.0 (docs/RULEBOOK.md §1 "Document readers", §9): `organizations/{orgId}/holidayBookings/{id}`
//  documents are read only through the packed script's `parseHolidayDocuments` / `parseHolidayDocument`
//  (web `lib/canonical/holidayDocument.ts`). Keys, status and slot synonyms, ids (stored case, never dropped
//  for not being a UUID) and organisation-zone day keys all come from the script; nothing is decided here.
//

import Foundation

/// One `parseHolidayDocument` result. Ids keep their stored case; day keys are organisation-zone
/// `YYYY-MM-DD` with `startDayKey <= endDayKey`.
nonisolated struct CanonicalHolidayDocument: Equatable, Hashable, Sendable {
    /// The Firestore document id, stored case.
    let id: String
    let userId: String?
    /// Kept as stored, even when it is not a UUID.
    let operativeId: String?
    let startDayKey: String
    let endDayKey: String
    /// `FULL DAY`, `AM` or `PM` (`normalizeHolidayTimeSlot`).
    let timeSlot: String
    /// `pending`, `approved` or `rejected` (`normalizeHolidayStatus`).
    let status: String
    /// `status == approved`. A pending cancellation request is still approved leave.
    let approved: Bool
    let approvedByUserId: String?
    let cancellationRequested: Bool
    let cancellationRequestedByUserId: String?
    let decisionNote: String?
    /// Stored `organizationId`, when the document has one.
    let organizationId: String?

    /// A script row, or nil when it is not that shape.
    static func fromScript(_ value: Any?) -> CanonicalHolidayDocument? {
        guard let row = value as? [String: Any],
              let id = row["id"] as? String, !id.isEmpty,
              let startDayKey = row["startDayKey"] as? String, !startDayKey.isEmpty,
              let endDayKey = row["endDayKey"] as? String, !endDayKey.isEmpty else { return nil }
        func optionalText(_ key: String) -> String? {
            guard let text = row[key] as? String, !text.isEmpty else { return nil }
            return text
        }
        let status = optionalText("status") ?? "approved"
        return CanonicalHolidayDocument(
            id: id,
            userId: optionalText("userId"),
            operativeId: optionalText("operativeId"),
            startDayKey: startDayKey,
            endDayKey: endDayKey,
            timeSlot: optionalText("timeSlot") ?? "FULL DAY",
            status: status,
            approved: (row["approved"] as? Bool) ?? (status == "approved"),
            approvedByUserId: optionalText("approvedByUserId"),
            cancellationRequested: (row["cancellationRequested"] as? Bool) ?? false,
            cancellationRequestedByUserId: optionalText("cancellationRequestedByUserId"),
            decisionNote: optionalText("decisionNote"),
            organizationId: optionalText("organizationId")
        )
    }
}

extension CanonicalBusinessEngine {
    /// `parseHolidayDocument(docId, data, timeZone)`: one leave document, or nil when it has no readable
    /// start date (or the script did not answer). `data` is JSON (`FirebaseBackend.firestoreJSON`).
    nonisolated static func parseHolidayDocument(
        documentId: String,
        data: [String: Any],
        timeZone: String = OrganizationRulebookContext.timeZoneIdentifier
    ) -> CanonicalHolidayDocument? {
        CanonicalHolidayDocument.fromScript(
            callJSON("parseHolidayDocument", arguments: [documentId, data, timeZone])
        )
    }

    /// `parseHolidayDocuments(docs, timeZone)` over `{ id, data }` rows, dropping unreadable documents.
    /// Nil only when the script did not answer for the whole list.
    nonisolated static func parseHolidayDocuments(
        _ documents: [(id: String, data: [String: Any])],
        timeZone: String = OrganizationRulebookContext.timeZoneIdentifier
    ) -> [CanonicalHolidayDocument]? {
        let payload: [[String: Any]] = documents.map { ["id": $0.id, "data": $0.data] }
        guard let rows = callJSON("parseHolidayDocuments", arguments: [payload, timeZone]) as? [Any] else { return nil }
        return rows.compactMap { CanonicalHolidayDocument.fromScript($0) }
    }
}
