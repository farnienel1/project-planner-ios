//
//  Rulebook+OrgCompliance.swift
//  Project Planner
//
//  RULEBOOK 1.83.0 §31 (owner decisions 24 Nov: build now, lean; admins only; 30-day recovery): the organisation's
//  insurance & accreditations (web `lib/canonical/orgCompliance.ts`). Every answer comes from the packed script through
//  `CanonicalBusinessEngine.callJSON`; nothing is worked out here.
//

import Foundation
@preconcurrency import FirebaseFirestore

/// One stored document as `parseOrgComplianceDocuments` reads it.
nonisolated struct RulebookOrgComplianceEntry: Codable, Hashable, Sendable, Identifiable {
    let id: String
    let section: String
    let docType: String
    let title: String
    let issuer: String
    let reference: String
    let coverAmount: Double?
    /// `YYYY-MM-DD` (organisation zone, the last valid day) or nil.
    let expiresOn: String?
    let path: String
    let fileName: String
    let contentType: String
    let sizeBytes: Double?
    let uploadedAtMs: Double?
    let uploadedBy: String
    let updatedAtMs: Double?
    let updatedBy: String
}

/// `insurance` / `trade` / `quality` lists (`ORG_COMPLIANCE_SECTION_KEYS`).
nonisolated struct RulebookOrgComplianceDocuments: Codable, Hashable, Sendable {
    var insurance: [RulebookOrgComplianceEntry] = []
    var trade: [RulebookOrgComplianceEntry] = []
    var quality: [RulebookOrgComplianceEntry] = []

    func entries(_ section: String) -> [RulebookOrgComplianceEntry] {
        switch section {
        case "trade": return trade
        case "quality": return quality
        default: return insurance
        }
    }
}

nonisolated struct RulebookOrgComplianceDocumentType: Codable, Hashable, Sendable {
    let key: String
    let label: String
    let short: String
}

/// One `ORG_COMPLIANCE_SECTIONS` row.
nonisolated struct RulebookOrgComplianceSection: Codable, Hashable, Sendable, Identifiable {
    let key: String
    let title: String
    let helper: String
    let issuerLabel: String
    let referenceLabel: String
    let coverLabel: String?
    let emptyTitle: String
    let emptyBody: String
    let documentTypes: [RulebookOrgComplianceDocumentType]
    var id: String { key }
}

/// `orgComplianceExpiryStatus` → `{ status, tone, daysToExpiry, label }`.
nonisolated struct RulebookOrgComplianceStatus: Hashable, Sendable {
    /// `valid`, `expiring_soon`, `expired`, `no_expiry`.
    let status: String
    /// `green`, `amber`, `red`, `grey`.
    let tone: String
    let label: String
}

/// `orgComplianceCounts`.
nonisolated struct RulebookOrgComplianceCounts: Codable, Hashable, Sendable {
    var total: Int = 0
    var expiringSoon: Int = 0
    var expired: Int = 0
    var attention: Int = 0
}

/// `orgComplianceReminder(counts)`: the admins' Home reminder.
nonisolated struct RulebookOrgComplianceReminder: Hashable, Sendable {
    let count: Int
    let title: String
    let detail: String
}

/// `orgComplianceDocumentRefKey` form: `insurance:abc`.
nonisolated func orgComplianceRefKey(section: String, id: String) -> String { "\(section):\(id)" }

/// The documents the page lets an admin tick.
nonisolated struct OrgComplianceSelectedDocument: Hashable, Sendable {
    let section: String
    let entry: RulebookOrgComplianceEntry
    var key: String { orgComplianceRefKey(section: section, id: entry.id) }
}

/// The details a form edits (as typed; the rulebook checks and cleans them).
nonisolated struct OrgComplianceDetailsInput: Sendable {
    var docType: String
    var title: String
    var issuer: String
    var reference: String
    var coverAmount: String
    var expiresOn: String?

    var json: [String: Any] {
        [
            "docType": docType, "title": title, "issuer": issuer, "reference": reference,
            "coverAmount": coverAmount, "expiresOn": expiresOn ?? NSNull(),
        ]
    }
}

/// An uploaded file to link.
nonisolated struct OrgComplianceFileInput: Sendable {
    let path: String
    let fileName: String
    let contentType: String
    let sizeBytes: Int
    let uploadedAtMs: Int64
    let uploadedBy: String

    var json: [String: Any] {
        [
            "path": path, "fileName": fileName, "contentType": contentType, "sizeBytes": sizeBytes,
            "uploadedAtMs": uploadedAtMs, "uploadedBy": uploadedBy,
        ]
    }
}

/// A section write: the merge-set payload (`orgComplianceMergePayload`, native types) or nil when nothing changes.
nonisolated struct RulebookOrgComplianceWritePlan: @unchecked Sendable {
    let payload: [String: Any]?
    /// `added`, `alreadyLinked`, `refused`, `invalid`, `changed`, `unchanged`, `missing`, `replaced`, `removed`;
    /// `no_answer` when the script did not run.
    let outcome: String
    let error: String?
    /// The file a replace or remove leaves behind (deleted by the admin; kept 30 days by the bucket, §24).
    let oldPath: String?
}

extension CanonicalBusinessEngine {
    nonisolated static var orgComplianceSections: [RulebookOrgComplianceSection] {
        constant("ORG_COMPLIANCE_SECTIONS", as: [RulebookOrgComplianceSection].self) ?? []
    }

    /// `ORG_COMPLIANCE_LABELS[key]` (form and action wording), else `fallback`.
    nonisolated static func orgComplianceLabel(_ key: String, fallback: String) -> String {
        constant("ORG_COMPLIANCE_LABELS", as: [String: String].self)?[key] ?? fallback
    }

    nonisolated static var orgCompliancePageTitle: String {
        constant("ORG_COMPLIANCE_PAGE_TITLE", as: String.self) ?? "Insurance & accreditations"
    }

    nonisolated static var orgCompliancePageSubtitle: String {
        constant("ORG_COMPLIANCE_PAGE_SUBTITLE", as: String.self) ?? ""
    }

    nonisolated static var orgComplianceHubGroup: String {
        constant("ORG_COMPLIANCE_HUB_GROUP", as: String.self) ?? "Compliance"
    }

    /// `canManageOrganizationCompliance(user)`: admins and super admins only. False when the script did not answer.
    nonisolated static func canManageOrganizationCompliance(_ subject: [String: Any]) -> Bool {
        callJSON("canManageOrganizationCompliance", arguments: [subject]) as? Bool ?? false
    }

    /// `orgComplianceStoragePath({ organizationId, uid, unixMs, extension })`.
    nonisolated static func orgComplianceStoragePath(organizationId: String, uid: String, unixMs: Int64, fileExtension: String) -> String? {
        let input: [String: Any] = ["organizationId": organizationId, "uid": uid, "unixMs": unixMs, "extension": fileExtension]
        return callJSON("orgComplianceStoragePath", arguments: [input]) as? String
    }

    /// `parseOrgComplianceDocuments(data, { organizationId })`. Nil when the script did not answer.
    nonisolated static func parseOrgComplianceDocuments(data: [String: Any]?, organizationId: String) -> RulebookOrgComplianceDocuments? {
        let stored: Any = data.map { peopleDocumentJSON($0) } ?? NSNull()
        guard let row = callJSON("parseOrgComplianceDocuments", arguments: [stored, ["organizationId": organizationId]]),
              JSONSerialization.isValidJSONObject(row),
              let json = try? JSONSerialization.data(withJSONObject: row) else { return nil }
        return try? JSONDecoder().decode(RulebookOrgComplianceDocuments.self, from: json)
    }

    /// `orgComplianceTodayKey(nowMs, timeZone)`.
    nonisolated static func orgComplianceTodayKey(now: Date = Date(), timeZone: String = OrganizationRulebookContext.timeZoneIdentifier) -> String {
        callJSON("orgComplianceTodayKey", arguments: [(now.timeIntervalSince1970 * 1000).rounded(), timeZone]) as? String
            ?? OrganizationRulebookContext.dayKey(now)
    }

    /// `orgComplianceDetailsError(section, details, todayKey)`; a message when the script did not answer.
    nonisolated static func orgComplianceDetailsError(section: String, details: OrgComplianceDetailsInput, todayKey: String) -> String? {
        guard let answer = callJSON("orgComplianceDetailsError", arguments: [section, details.json, todayKey]) else {
            return CanonicalWriteUnavailableError(function: "orgComplianceDetailsError").errorDescription
        }
        return answer as? String
    }

    /// `orgComplianceExpiryStatus(expiresOn, todayKey)`.
    nonisolated static func orgComplianceExpiryStatus(expiresOn: String?, todayKey: String) -> RulebookOrgComplianceStatus {
        guard let row = callJSON("orgComplianceExpiryStatus", arguments: [expiresOn ?? NSNull(), todayKey]) as? [String: Any] else {
            return RulebookOrgComplianceStatus(status: "no_expiry", tone: "grey", label: expiresOn ?? "")
        }
        return RulebookOrgComplianceStatus(
            status: row["status"] as? String ?? "no_expiry",
            tone: row["tone"] as? String ?? "grey",
            label: row["label"] as? String ?? ""
        )
    }

    private nonisolated static func orgComplianceEntriesJSON(_ entries: [RulebookOrgComplianceEntry]) -> Any {
        guard let data = try? JSONEncoder().encode(entries),
              let json = try? JSONSerialization.jsonObject(with: data) else { return [Any]() }
        return json
    }

    /// `orgComplianceSortedEntries(entries, todayKey)`: expired, expiring soon, valid, no expiry; then date; then name.
    nonisolated static func orgComplianceSortedEntries(_ entries: [RulebookOrgComplianceEntry], todayKey: String) -> [RulebookOrgComplianceEntry] {
        guard let row = callJSON("orgComplianceSortedEntries", arguments: [orgComplianceEntriesJSON(entries), todayKey]),
              JSONSerialization.isValidJSONObject(row),
              let json = try? JSONSerialization.data(withJSONObject: row),
              let sorted = try? JSONDecoder().decode([RulebookOrgComplianceEntry].self, from: json) else { return entries }
        return sorted
    }

    /// `orgComplianceCounts(documents, todayKey)`.
    nonisolated static func orgComplianceCounts(_ documents: RulebookOrgComplianceDocuments?, todayKey: String) -> RulebookOrgComplianceCounts {
        guard let documents,
              let data = try? JSONEncoder().encode(documents),
              let docs = try? JSONSerialization.jsonObject(with: data),
              let row = callJSON("orgComplianceCounts", arguments: [docs, todayKey]),
              JSONSerialization.isValidJSONObject(row),
              let json = try? JSONSerialization.data(withJSONObject: row),
              let counts = try? JSONDecoder().decode(RulebookOrgComplianceCounts.self, from: json) else { return RulebookOrgComplianceCounts() }
        return counts
    }

    /// `orgComplianceHubSubtitle(counts)`.
    nonisolated static func orgComplianceHubSubtitle(_ counts: RulebookOrgComplianceCounts?) -> String {
        let arg: Any = counts.flatMap { try? JSONSerialization.jsonObject(with: JSONEncoder().encode($0)) } ?? NSNull()
        return callJSON("orgComplianceHubSubtitle", arguments: [arg]) as? String ?? "PI, PL, trade and ISO certificates"
    }

    /// `orgComplianceCoverText(amount, currency)` ("£10,000,000").
    nonisolated static func orgComplianceCoverText(_ amount: Double?, currency: String = OrganizationRulebookContext.currencyCode) -> String {
        guard let amount else { return "" }
        return callJSON("orgComplianceCoverText", arguments: [amount, currency]) as? String ?? ""
    }

    private nonisolated static func orgCompliancePlan(_ row: [String: Any]?, oldPathKey: String? = nil) -> RulebookOrgComplianceWritePlan {
        guard let row else { return RulebookOrgComplianceWritePlan(payload: nil, outcome: "no_answer", error: nil, oldPath: nil) }
        var payload: [String: Any]?
        if let set = row["set"] as? [String: Any],
           let merged = callJSON("orgComplianceMergePayload", arguments: [set]) as? [String: Any] {
            payload = ScriptFirestoreValue.native(merged) as? [String: Any]
        }
        let outcome = row["outcome"] as? String ?? (row["set"] is [String: Any] ? "removed" : "missing")
        return RulebookOrgComplianceWritePlan(
            payload: payload,
            outcome: outcome,
            error: row["error"] as? String,
            oldPath: oldPathKey.flatMap { row[$0] as? String }
        )
    }

    nonisolated static func orgComplianceAddWriteFields(
        stored: [String: Any], section: String, organizationId: String, todayKey: String,
        details: OrgComplianceDetailsInput, file: OrgComplianceFileInput
    ) -> RulebookOrgComplianceWritePlan {
        let input: [String: Any] = [
            "section": section, "organizationId": organizationId, "todayKey": todayKey,
            "details": details.json, "file": file.json,
        ]
        return orgCompliancePlan(callJSON("orgComplianceAddWriteFields", arguments: [peopleDocumentJSON(stored), input]) as? [String: Any])
    }

    nonisolated static func orgComplianceUpdateWriteFields(
        stored: [String: Any], section: String, organizationId: String, entryId: String, todayKey: String,
        details: OrgComplianceDetailsInput, updatedAtMs: Int64, updatedBy: String
    ) -> RulebookOrgComplianceWritePlan {
        let input: [String: Any] = [
            "section": section, "organizationId": organizationId, "entryId": entryId, "todayKey": todayKey,
            "details": details.json, "updatedAtMs": updatedAtMs, "updatedBy": updatedBy,
        ]
        return orgCompliancePlan(callJSON("orgComplianceUpdateWriteFields", arguments: [peopleDocumentJSON(stored), input]) as? [String: Any])
    }

    nonisolated static func orgComplianceReplaceWriteFields(
        stored: [String: Any], section: String, organizationId: String, entryId: String, todayKey: String,
        details: OrgComplianceDetailsInput, file: OrgComplianceFileInput
    ) -> RulebookOrgComplianceWritePlan {
        let input: [String: Any] = [
            "section": section, "organizationId": organizationId, "entryId": entryId, "todayKey": todayKey,
            "details": details.json, "file": file.json,
        ]
        return orgCompliancePlan(
            callJSON("orgComplianceReplaceWriteFields", arguments: [peopleDocumentJSON(stored), input]) as? [String: Any],
            oldPathKey: "replacedPath"
        )
    }

    nonisolated static func orgComplianceRemoveWriteFields(
        stored: [String: Any], section: String, organizationId: String, entryId: String
    ) -> RulebookOrgComplianceWritePlan {
        let input: [String: Any] = ["section": section, "organizationId": organizationId, "entryId": entryId]
        return orgCompliancePlan(
            callJSON("orgComplianceRemoveWriteFields", arguments: [peopleDocumentJSON(stored), input]) as? [String: Any],
            oldPathKey: "removedPath"
        )
    }

    // ── 1.83.0 phase 2 (owner decision 24 Nov): file name, linked check, reminder, zip, share links ──

    /// `orgComplianceFileName(pickedName, storedPath)`: the same stored name as web.
    nonisolated static func orgComplianceFileName(pickedName: String, storedPath: String) -> String? {
        callJSON("orgComplianceFileName", arguments: [pickedName, storedPath]) as? String
    }

    /// `orgCompliancePathLinked(stored, path)`: does any stored entry name this file? Nil when the script did not answer
    /// (the caller then keeps the file).
    nonisolated static func orgCompliancePathLinked(stored: [String: Any]?, path: String) -> Bool? {
        let doc: Any = stored.map { peopleDocumentJSON($0) } ?? NSNull()
        return callJSON("orgCompliancePathLinked", arguments: [doc, path]) as? Bool
    }

    /// `orgComplianceReminder(counts)`: nil when nothing needs attention.
    nonisolated static func orgComplianceReminder(_ counts: RulebookOrgComplianceCounts) -> RulebookOrgComplianceReminder? {
        guard let arg = try? JSONSerialization.jsonObject(with: JSONEncoder().encode(counts)),
              let row = callJSON("orgComplianceReminder", arguments: [arg]) as? [String: Any],
              let title = row["title"] as? String else { return nil }
        return RulebookOrgComplianceReminder(
            count: (row["count"] as? NSNumber)?.intValue ?? 0,
            title: title,
            detail: row["detail"] as? String ?? ""
        )
    }

    nonisolated static var orgComplianceZipMaxDocuments: Int {
        constant("ORG_COMPLIANCE_ZIP_MAX_DOCUMENTS", as: Int.self) ?? 50
    }

    nonisolated static var orgComplianceShareMaxDocuments: Int {
        constant("ORG_COMPLIANCE_SHARE_MAX_DOCUMENTS", as: Int.self) ?? 20
    }

    /// `ORG_COMPLIANCE_SHARE_MESSAGES[key]`.
    nonisolated static func orgComplianceShareMessage(_ key: String, fallback: String) -> String {
        constant("ORG_COMPLIANCE_SHARE_MESSAGES", as: [String: String].self)?[key] ?? fallback
    }

    /// `orgComplianceZipEntryNames(entries)`: safe, unique names in the order given. Nil when the script did not answer.
    nonisolated static func orgComplianceZipEntryNames(_ entries: [RulebookOrgComplianceEntry]) -> [String]? {
        let rows: [[String: Any]] = entries.map { ["fileName": $0.fileName, "title": $0.title] }
        guard let names = callJSON("orgComplianceZipEntryNames", arguments: [rows]) as? [String], names.count == entries.count else { return nil }
        return names
    }

    /// `orgComplianceZipFileName(todayKey)`.
    nonisolated static func orgComplianceZipFileName(todayKey: String) -> String {
        callJSON("orgComplianceZipFileName", arguments: [todayKey]) as? String ?? "Insurance-and-accreditations.zip"
    }

    /// `orgComplianceShareSelection(documents, refs)` → the refs a link may share (as `section:id`) or the message.
    nonisolated static func orgComplianceShareSelection(_ documents: RulebookOrgComplianceDocuments, refs: [String]) -> (refs: [String], error: String?) {
        guard let data = try? JSONEncoder().encode(documents),
              let docs = try? JSONSerialization.jsonObject(with: data),
              let row = callJSON("orgComplianceShareSelection", arguments: [docs, refs]) as? [String: Any] else {
            return ([], CanonicalWriteUnavailableError(function: "orgComplianceShareSelection").errorDescription)
        }
        let picked = (row["refs"] as? [[String: Any]] ?? []).compactMap { ref -> String? in
            guard let section = ref["section"] as? String, let id = ref["id"] as? String else { return nil }
            return orgComplianceRefKey(section: section, id: id)
        }
        return (picked, row["error"] as? String)
    }
}
