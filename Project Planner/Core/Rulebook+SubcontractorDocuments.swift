//
//  Rulebook+SubcontractorDocuments.swift
//  Project Planner
//
//  RULEBOOK 1.80.0 §30 (owner decision 24 Nov, option (a)): a subcontractor's insurance and RAMS documents, uploaded
//  by staff on the firm's page (web `lib/canonical/subcontractorDocuments.ts`). Every answer comes from the packed
//  script through `CanonicalBusinessEngine.callJSON`; nothing is worked out here.
//

import Foundation
@preconcurrency import FirebaseFirestore

/// One stored document as `parseSubcontractorDocuments` reads it.
nonisolated struct RulebookSubcontractorDocument: Codable, Hashable, Sendable, Identifiable {
    let id: String
    let path: String
    let name: String
    let contentType: String
    let sizeBytes: Double?
    let uploadedAtMs: Double?
    let uploadedBy: String
    /// `YYYY-MM-DD` (organisation zone) or nil.
    let expiresOn: String?

    var uploadedAt: Date? { uploadedAtMs.map { Date(timeIntervalSince1970: $0 / 1000) } }
}

/// `insurance` / `rams` lists (`SUBCONTRACTOR_DOCUMENT_KINDS`).
nonisolated struct RulebookSubcontractorDocuments: Codable, Hashable, Sendable {
    var insurance: [RulebookSubcontractorDocument] = []
    var rams: [RulebookSubcontractorDocument] = []

    func entries(_ kind: String) -> [RulebookSubcontractorDocument] { kind == "rams" ? rams : insurance }
}

/// `subcontractorDocumentExpiryState` → `{ state, daysLeft, label }`.
nonisolated struct RulebookSubcontractorDocumentExpiry: Hashable, Sendable {
    /// `none`, `expired`, `expiresToday`, `expiringSoon`, `valid`.
    let state: String
    let label: String
}

/// A list write: one field path (`documents.insurance` / `documents.rams`) and its full new value (native types).
nonisolated struct RulebookSubcontractorDocumentWrite: @unchecked Sendable {
    let fieldPath: String
    let value: [Any]
}

extension CanonicalBusinessEngine {
    /// `SUBCONTRACTOR_DOCUMENT_KINDS` ("insurance", "rams").
    nonisolated static var subcontractorDocumentKinds: [String] {
        constant("SUBCONTRACTOR_DOCUMENT_KINDS", as: [String].self) ?? ["insurance", "rams"]
    }

    /// `SUBCONTRACTOR_DOCUMENT_LABELS[kind]` ("Insurance" / "RAMS").
    nonisolated static func subcontractorDocumentLabel(_ kind: String) -> String {
        constant("SUBCONTRACTOR_DOCUMENT_LABELS", as: [String: String].self)?[kind] ?? kind
    }

    nonisolated static var subcontractorDocumentsEmptyText: String {
        constant("SUBCONTRACTOR_DOCUMENTS_EMPTY_TEXT", as: String.self) ?? "No documents uploaded yet."
    }

    nonisolated static var subcontractorDocumentExpiryLabel: String {
        constant("SUBCONTRACTOR_DOCUMENT_EXPIRY_LABEL", as: String.self) ?? "Expiry date (optional)"
    }

    nonisolated static var subcontractorDocumentsFullMessage: String {
        constant("SUBCONTRACTOR_DOCUMENTS_FULL_MESSAGE", as: String.self) ?? "This subcontractor already holds the most documents of this kind."
    }

    /// `canManageSubcontractors(user)`: admins and super admins; managers with the manager flag and the Sub
    /// Contractors permission in effect; operatives never. False when the script did not answer.
    nonisolated static func canManageSubcontractors(_ subject: [String: Any]) -> Bool {
        callJSON("canManageSubcontractors", arguments: [subject]) as? Bool ?? false
    }

    /// `subcontractorDocumentStoragePath({ organizationId, subcontractorId, uid, unixMs, extension })`.
    nonisolated static func subcontractorDocumentStoragePath(
        organizationId: String,
        subcontractorId: String,
        uid: String,
        unixMs: Int64,
        fileExtension: String
    ) -> String? {
        let input: [String: Any] = [
            "organizationId": organizationId,
            "subcontractorId": subcontractorId,
            "uid": uid,
            "unixMs": unixMs,
            "extension": fileExtension,
        ]
        return callJSON("subcontractorDocumentStoragePath", arguments: [input]) as? String
    }

    /// `parseSubcontractorDocuments(subcontractorId, data, { organizationId })`. Nil when the script did not answer.
    nonisolated static func parseSubcontractorDocuments(
        subcontractorId: String,
        data: [String: Any],
        organizationId: String? = nil
    ) -> RulebookSubcontractorDocuments? {
        let options: [String: Any] = ["organizationId": organizationId ?? NSNull()]
        guard let row = callJSON("parseSubcontractorDocuments", arguments: [subcontractorId, peopleDocumentJSON(data), options]),
              JSONSerialization.isValidJSONObject(row),
              let json = try? JSONSerialization.data(withJSONObject: row) else { return nil }
        return try? JSONDecoder().decode(RulebookSubcontractorDocuments.self, from: json)
    }

    private nonisolated static func subcontractorDocumentWrite(_ row: [String: Any]?) -> RulebookSubcontractorDocumentWrite? {
        guard let set = row?["set"] as? [String: Any],
              let fieldPath = set["fieldPath"] as? String,
              let value = set["value"] as? [Any] else { return nil }
        return RulebookSubcontractorDocumentWrite(fieldPath: fieldPath, value: value.map { ScriptFirestoreValue.native($0) })
    }

    /// `subcontractorDocumentAddWriteFields(stored, input)` → the write (nil when nothing changes) and the outcome
    /// (`added`, `alreadyLinked`, `refused`, `invalid`; `no_answer` when the script did not run).
    nonisolated static func subcontractorDocumentAddWriteFields(
        stored: [String: Any],
        kind: String,
        subcontractorId: String,
        organizationId: String,
        path: String,
        name: String,
        contentType: String,
        sizeBytes: Int,
        uploadedAtMs: Int64,
        uploadedBy: String,
        expiresOn: String?
    ) -> (write: RulebookSubcontractorDocumentWrite?, outcome: String) {
        let input: [String: Any] = [
            "kind": kind,
            "subcontractorId": subcontractorId,
            "organizationId": organizationId,
            "entry": [
                "path": path,
                "name": name,
                "contentType": contentType,
                "sizeBytes": sizeBytes,
                "uploadedAtMs": uploadedAtMs,
                "uploadedBy": uploadedBy,
                "expiresOn": expiresOn ?? NSNull(),
            ] as [String: Any],
        ]
        guard let row = callJSON("subcontractorDocumentAddWriteFields", arguments: [peopleDocumentJSON(stored), input]) as? [String: Any] else {
            return (nil, "no_answer")
        }
        return (subcontractorDocumentWrite(row), row["outcome"] as? String ?? "invalid")
    }

    /// `subcontractorDocumentRemoveWriteFields(stored, { kind, subcontractorId, entryId })` → the write and the removed path.
    nonisolated static func subcontractorDocumentRemoveWriteFields(
        stored: [String: Any],
        kind: String,
        subcontractorId: String,
        entryId: String
    ) -> (write: RulebookSubcontractorDocumentWrite?, removedPath: String?, answered: Bool) {
        let input: [String: Any] = ["kind": kind, "subcontractorId": subcontractorId, "entryId": entryId]
        guard let row = callJSON("subcontractorDocumentRemoveWriteFields", arguments: [peopleDocumentJSON(stored), input]) as? [String: Any] else {
            return (nil, nil, false)
        }
        return (subcontractorDocumentWrite(row), row["removedPath"] as? String, true)
    }

    /// `subcontractorDocumentExpiryWriteFields(stored, { kind, subcontractorId, entryId, expiresOn })`.
    nonisolated static func subcontractorDocumentExpiryWriteFields(
        stored: [String: Any],
        kind: String,
        subcontractorId: String,
        entryId: String,
        expiresOn: String?
    ) -> (write: RulebookSubcontractorDocumentWrite?, outcome: String) {
        let input: [String: Any] = [
            "kind": kind, "subcontractorId": subcontractorId, "entryId": entryId, "expiresOn": expiresOn ?? NSNull(),
        ]
        guard let row = callJSON("subcontractorDocumentExpiryWriteFields", arguments: [peopleDocumentJSON(stored), input]) as? [String: Any] else {
            return (nil, "no_answer")
        }
        return (subcontractorDocumentWrite(row), row["outcome"] as? String ?? "invalid")
    }

    /// `subcontractorDocumentExpiryState(expiresOn, nowMs, timeZone)` on the organisation day.
    nonisolated static func subcontractorDocumentExpiryState(
        expiresOn: String?,
        now: Date = Date(),
        timeZone: String
    ) -> RulebookSubcontractorDocumentExpiry {
        let args: [Any] = [expiresOn ?? NSNull(), (now.timeIntervalSince1970 * 1000).rounded(), timeZone]
        guard let row = callJSON("subcontractorDocumentExpiryState", arguments: args) as? [String: Any] else {
            return RulebookSubcontractorDocumentExpiry(state: "none", label: expiresOn ?? "")
        }
        return RulebookSubcontractorDocumentExpiry(state: row["state"] as? String ?? "none", label: row["label"] as? String ?? "")
    }
}
