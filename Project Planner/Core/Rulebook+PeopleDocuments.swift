//
//  Rulebook+PeopleDocuments.swift
//  Project Planner
//
//  Rulebook 1.6.0 (docs/RULEBOOK.md §1 "Document readers" and "Partial writes only", §8, §11): the people
//  collections — `users/{uid}`, `operatives`, `managers`, `operativeDayRateHistory`, `clients`, `subcontractors`
//  and `skills` — are read only through the packed script's readers (web `lib/canonical/peopleDocuments.ts`)
//  and saved only with its partial-write helpers. Ids are the document id in stored case; a non-UUID id is
//  kept. Nothing is decided here: Swift converts Firestore values to JSON, calls the script and reads its answer.
//

import Foundation
import FirebaseFirestore

/// One reader result (`parseUserDocument`, `parseOperativeDocument`, …) with typed accessors. The keys are the
/// reader's own field names; instants come back as epoch milliseconds (`…Ms`).
nonisolated struct CanonicalDocumentRow {
    let raw: [String: Any]

    init?(_ value: Any?) {
        guard let row = value as? [String: Any] else { return nil }
        raw = row
    }

    /// The record id: the Firestore document id, stored case.
    var id: String { text("id") }

    /// Trimmed text, '' when missing.
    func text(_ key: String) -> String {
        (raw[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    /// Text, nil when missing or empty.
    func optionalText(_ key: String) -> String? {
        let value = text(key)
        return value.isEmpty ? nil : value
    }

    func number(_ key: String) -> Double? {
        // A JSON `true` is an NSNumber too; only a real number counts (an NSNumber 0 or 1 also casts to Bool).
        guard let number = raw[key] as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let value = number.doubleValue
        return value.isFinite ? value : nil
    }

    func bool(_ key: String, default fallback: Bool = false) -> Bool {
        (raw[key] as? Bool) ?? (raw[key] as? NSNumber)?.boolValue ?? fallback
    }

    /// An epoch-milliseconds field as a `Date`.
    func date(_ key: String) -> Date? {
        number(key).map { Date(timeIntervalSince1970: $0 / 1000) }
    }

    func strings(_ key: String) -> [String] {
        (raw[key] as? [Any])?.compactMap { $0 as? String } ?? []
    }

    func map(_ key: String) -> [String: Any] {
        raw[key] as? [String: Any] ?? [:]
    }

    func rows(_ key: String) -> [CanonicalDocumentRow] {
        (raw[key] as? [Any])?.compactMap { CanonicalDocumentRow($0) } ?? []
    }
}

/// `documentWriteFields` result (`{ set, remove }`) for one partial update. `set` values are the caller's own
/// values, so the app writes its native Firestore values (Timestamps stay Timestamps) for the keys the script
/// named, and `FieldValue.delete()` for each removed key.
nonisolated struct CanonicalDocumentWrite: Equatable {
    let setKeys: [String]
    let removeKeys: [String]

    var isEmpty: Bool { setKeys.isEmpty && removeKeys.isEmpty }

    init(setKeys: [String], removeKeys: [String]) {
        self.setKeys = setKeys
        self.removeKeys = removeKeys
    }

    init?(_ value: Any?) {
        guard let row = value as? [String: Any],
              let set = row["set"] as? [String: Any],
              let remove = row["remove"] as? [Any] else { return nil }
        setKeys = set.keys.sorted()
        removeKeys = remove.compactMap { $0 as? String }
    }

    /// The partial update to send: `next[key]` for every set key, `FieldValue.delete()` for every removed key.
    func firestoreFields(from next: [String: Any]) -> [String: Any] {
        var fields: [String: Any] = [:]
        for key in setKeys {
            if let value = next[key] { fields[key] = value }
        }
        for key in removeKeys {
            fields[key] = FieldValue.delete()
        }
        return fields
    }
}

/// Raised when the packed script did not answer a partial-write call. Nothing is written then: Swift has no
/// second copy of the rule.
nonisolated struct CanonicalWriteUnavailableError: LocalizedError {
    let function: String
    var errorDescription: String? { "This change could not be prepared (\(function)). Please try again." }
}

extension CanonicalBusinessEngine {
    /// Firestore values (or a native payload with `FieldValue.delete()` markers) as script JSON. A delete marker
    /// and any other value the script cannot take become null.
    nonisolated static func peopleDocumentJSON(_ data: [String: Any]) -> [String: Any] {
        (FirebaseBackend.firestoreJSON(data) as? [String: Any]) ?? [:]
    }

    // MARK: Readers

    /// `parseUserDocument(docId, data, { timeZone, annualLeaveDefaults })`. `data` is the stored document
    /// (Firestore values). `annualLeaveDefaults` is the organisation's map (§4.4); nil takes the rulebook default.
    nonisolated static func parseUserDocument(
        documentId: String,
        data: [String: Any],
        annualLeaveDefaults: OrganizationAnnualLeaveDefaults? = OrganizationRulebookContext.annualLeaveDefaults,
        timeZone: String = OrganizationRulebookContext.timeZoneIdentifier
    ) -> CanonicalDocumentRow? {
        var options: [String: Any] = ["timeZone": timeZone]
        if let annualLeaveDefaults {
            options["annualLeaveDefaults"] = [
                "daysPerYear": annualLeaveDefaults.daysPerYear,
                "startMonth": annualLeaveDefaults.startMonth,
                "endMonth": annualLeaveDefaults.endMonth,
                "carriesOver": annualLeaveDefaults.carriesOver,
            ] as [String: Any]
        }
        return CanonicalDocumentRow(callJSON("parseUserDocument", arguments: [documentId, peopleDocumentJSON(data), options]))
    }

    /// `parseOperativeDocument(docId, data, timeZone)`: nil without a name and an email.
    nonisolated static func parseOperativeDocument(
        documentId: String,
        data: [String: Any],
        timeZone: String = OrganizationRulebookContext.timeZoneIdentifier
    ) -> CanonicalDocumentRow? {
        CanonicalDocumentRow(callJSON("parseOperativeDocument", arguments: [documentId, peopleDocumentJSON(data), timeZone]))
    }

    /// `parseManagerDocument(docId, data)`: nil without a name and an email.
    nonisolated static func parseManagerDocument(documentId: String, data: [String: Any]) -> CanonicalDocumentRow? {
        CanonicalDocumentRow(callJSON("parseManagerDocument", arguments: [documentId, peopleDocumentJSON(data)]))
    }

    /// `parsePayRateHistoryDocuments(docs, timeZone)`: readable rows sorted by effectiveAt then createdAt.
    /// Nil when the script did not answer for the whole list.
    nonisolated static func parsePayRateHistoryDocuments(
        _ documents: [(id: String, data: [String: Any])],
        timeZone: String = OrganizationRulebookContext.timeZoneIdentifier
    ) -> [CanonicalDocumentRow]? {
        let payload: [[String: Any]] = documents.map { ["id": $0.id, "data": peopleDocumentJSON($0.data)] }
        guard let rows = callJSON("parsePayRateHistoryDocuments", arguments: [payload, timeZone]) as? [Any] else { return nil }
        return rows.compactMap { CanonicalDocumentRow($0) }
    }

    /// `parsePayRateHistoryDocument(docId, data, timeZone)`: one row, nil when unreadable.
    nonisolated static func parsePayRateHistoryDocument(
        documentId: String,
        data: [String: Any],
        timeZone: String = OrganizationRulebookContext.timeZoneIdentifier
    ) -> CanonicalDocumentRow? {
        CanonicalDocumentRow(callJSON("parsePayRateHistoryDocument", arguments: [documentId, peopleDocumentJSON(data), timeZone]))
    }

    /// `parseClientDocument(docId, data)`: nil without a name.
    nonisolated static func parseClientDocument(documentId: String, data: [String: Any]) -> CanonicalDocumentRow? {
        CanonicalDocumentRow(callJSON("parseClientDocument", arguments: [documentId, peopleDocumentJSON(data)]))
    }

    /// `parseSubcontractorDocument(docId, data)`: nil without a name or a type.
    nonisolated static func parseSubcontractorDocument(documentId: String, data: [String: Any]) -> CanonicalDocumentRow? {
        CanonicalDocumentRow(callJSON("parseSubcontractorDocument", arguments: [documentId, peopleDocumentJSON(data)]))
    }

    /// `parseSkillDocument(docId, data)`: nil without a name. A missing trade is ''.
    nonisolated static func parseSkillDocument(documentId: String, data: [String: Any]) -> CanonicalDocumentRow? {
        CanonicalDocumentRow(callJSON("parseSkillDocument", arguments: [documentId, peopleDocumentJSON(data)]))
    }

    /// `defaultTimesheetsEnabled({ operativeMode, employmentType })`: timesheets when the stored flag is missing.
    nonisolated static func defaultTimesheetsEnabled(operativeMode: Bool, employmentType: String?) -> Bool? {
        let input: [String: Any] = ["operativeMode": operativeMode, "employmentType": employmentType ?? NSNull()]
        return callJSON("defaultTimesheetsEnabled", arguments: [input]) as? Bool
    }

    // MARK: Partial writes

    /// One of `userProfileWriteFields`, `operativeRowWriteFields`, `managerRowWriteFields`, `clientWriteFields`,
    /// `subcontractorWriteFields` (or `documentWriteFields`). `before` is the stored document or the copy the
    /// editor loaded (nil for a new document); `next` the native fields the save would write, with
    /// `FieldValue.delete()` for "no value". Nil when the script did not answer.
    nonisolated static func peopleDocumentWrite(
        _ function: String,
        before: [String: Any]?,
        next: [String: Any]
    ) -> CanonicalDocumentWrite? {
        let beforeJSON: Any = before.map { peopleDocumentJSON($0) as Any } ?? NSNull()
        return CanonicalDocumentWrite(callJSON(function, arguments: [beforeJSON, peopleDocumentJSON(next)]))
    }

    /// `skillsCatalogueWrites({ stored, next, loaded })`: which skills to write (partial `{ name?, trade? }`) and
    /// which to delete. Nothing is deleted unless `loaded` and the list on screen is not empty.
    nonisolated static func skillsCatalogueWrites(
        stored: [(id: String, name: String, trade: String)],
        next: [(id: String, name: String, trade: String)],
        loaded: Bool
    ) -> (write: [(id: String, set: [String: Any])], remove: [String])? {
        let input: [String: Any] = [
            "stored": stored.map { ["id": $0.id, "name": $0.name, "trade": $0.trade] },
            "next": next.map { ["id": $0.id, "name": $0.name, "trade": $0.trade] },
            "loaded": loaded,
        ]
        guard let result = callJSON("skillsCatalogueWrites", arguments: [input]) as? [String: Any],
              let write = result["write"] as? [[String: Any]],
              let remove = result["remove"] as? [Any] else { return nil }
        let writes = write.compactMap { row -> (id: String, set: [String: Any])? in
            guard let id = row["id"] as? String, let set = row["set"] as? [String: Any] else { return nil }
            return (id: id, set: set)
        }
        return (write: writes, remove: remove.compactMap { $0 as? String })
    }
}

extension CanonicalBusinessEngine {
    // MARK: 1.9.0 leave defaults pending

    /// `USER_ANNUAL_LEAVE_FIGURE_FIELDS`: the four `users/{uid}` leave figure field names.
    nonisolated static var userAnnualLeaveFigureFields: [String] {
        (constant("USER_ANNUAL_LEAVE_FIGURE_FIELDS", as: [[String]].self) ?? []).compactMap(\.first)
    }

    /// `annualLeavePendingOmitFields(user, edited)`: the leave figure fields a `users/{uid}` save leaves out while
    /// `annualLeaveDefaultsPending` — each figure the document does not store (`storedKeys` are the
    /// `annualLeaveStored` keys it does) and the editor did not change. Nil when the script did not answer.
    nonisolated static func annualLeavePendingOmitFields(pending: Bool, storedKeys: [String], edited: [String]) -> [String]? {
        var stored: [String: Any] = [:]
        for key in storedKeys { stored[key] = true }
        let user: [String: Any] = ["annualLeaveDefaultsPending": pending, "annualLeaveStored": stored]
        return (callJSON("annualLeavePendingOmitFields", arguments: [user, edited]) as? [Any])?.compactMap { $0 as? String }
    }
}
