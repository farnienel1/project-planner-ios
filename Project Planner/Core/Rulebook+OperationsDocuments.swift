//
//  Rulebook+OperationsDocuments.swift
//  Project Planner
//
//  Rulebook 1.8.0 (docs/RULEBOOK.md §1 "Document readers", "Partial writes only" and "Job keys", §5, §13): the
//  operations and record collections — `materials`, `materialCatalogue`, `materialSendRecords`, `wholesalers`,
//  `siteAudits`, `tasks`, `settings/jobTypes`, `settings/tradeTypeInventory`, `operativeProfiles`, health & safety
//  settings documents, variations, inbox `notifications` and `warningResolutions` — are read only through the packed
//  script's readers (web `lib/canonical/operationsDocuments.ts`, `recordsDocuments.ts`) and saved only with its
//  partial-write helpers. Ids keep their stored case; a row stored without an id gets the script's derived id.
//  Nothing is decided here: Swift converts Firestore values to JSON, calls the script and reads its answer
//  (`CanonicalDocumentRow`, `CanonicalDocumentWrite`, 1.6.0).
//

import Foundation
import FirebaseFirestore

/// `healthSafetySignatureWriteFields` result: one signer's entry written with a field path
/// (`['signatureRecords', key]`) plus an `arrayUnion` of the same row onto `signatures`, in one `update`.
nonisolated struct CanonicalHealthSafetySignatureWrite {
    let fieldPath: [String]
    let value: [String: Any]
    let arrayRow: [String: Any]

    init?(_ raw: Any?) {
        guard let row = raw as? [String: Any],
              let path = row["fieldPath"] as? [Any],
              let value = row["value"] as? [String: Any],
              let arrayRow = row["arrayRow"] as? [String: Any] else { return nil }
        fieldPath = path.compactMap { $0 as? String }
        self.value = value
        self.arrayRow = arrayRow
        guard fieldPath.count == 2 else { return nil }
    }
}

/// One `warningResolutionWriteFields` / `warningResolutionMigrationWrites` row: the document id and its fields.
nonisolated struct CanonicalWarningResolutionWrite {
    let documentId: String
    let fields: [String: Any]

    init?(_ raw: Any?) {
        guard let row = raw as? [String: Any],
              let documentId = row["documentId"] as? String, !documentId.isEmpty,
              let fields = row["fields"] as? [String: Any] else { return nil }
        self.documentId = documentId
        self.fields = fields
    }
}

/// Stored job keys (RULEBOOK 1.8.0 §1 "Job keys"): job-scoped records store the job's document id as stored.
nonisolated enum JobKeys {
    /// The job's stored document id for an in-app job UUID (`Project.documentId` when the job was read).
    static func storedJobId(for projectId: UUID) -> String {
        WorkDocumentKeys.storedId(for: projectId)
    }

    /// Values a `projectId` filter must match: the stored id, and the upper-case UUID older iOS builds wrote when it
    /// differs (so lines saved before 1.8.0 on a lower-case job are still found).
    static func queryValues(for projectId: UUID) -> [String] {
        let stored = storedJobId(for: projectId)
        return stored == projectId.uuidString ? [stored] : [stored, projectId.uuidString]
    }

    /// A stored id as an in-app UUID, remembering its stored spelling.
    static func inAppId(_ raw: String) -> UUID {
        WorkDocumentKeys.inAppId(for: raw)
    }
}

/// Script JSON back to Firestore values: a `{ seconds, nanoseconds }` map (what `FirebaseBackend.firestoreJSON` makes
/// of a Timestamp) becomes a `Timestamp` again; maps and lists are converted recursively; `NSNull` stays.
nonisolated enum ScriptFirestoreValue {
    static func native(_ value: Any) -> Any {
        if let map = value as? [String: Any] {
            if map.count == 2,
               let seconds = (map["seconds"] as? NSNumber)?.int64Value,
               let nanos = (map["nanoseconds"] as? NSNumber)?.int32Value {
                return Timestamp(seconds: seconds, nanoseconds: nanos)
            }
            return map.mapValues { native($0) }
        }
        if let list = value as? [Any] {
            return list.map { native($0) }
        }
        return value
    }

    /// Epoch milliseconds as a Timestamp (what a script `…Ms` / `date` instant field stores).
    static func timestamp(ms value: Any?) -> Timestamp? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let ms = number.doubleValue
        guard ms.isFinite else { return nil }
        return Timestamp(date: Date(timeIntervalSince1970: ms / 1000))
    }
}

extension CanonicalBusinessEngine {
    private nonisolated static func opsRow(_ function: String, _ arguments: [Any]) -> CanonicalDocumentRow? {
        CanonicalDocumentRow(callJSON(function, arguments: arguments))
    }

    private nonisolated static func zoneOptions(_ timeZone: String) -> [String: Any] {
        ["timeZone": timeZone]
    }

    // MARK: Shared

    /// `organizationDayStartMs(dayKey, timeZone)` as a `Date`: organisation-zone midnight of a day key.
    nonisolated static func organizationDayStart(
        _ dayKey: String,
        timeZone: String = OrganizationRulebookContext.timeZoneIdentifier
    ) -> Date? {
        guard let ms = (callJSON("organizationDayStartMs", arguments: [dayKey, timeZone]) as? NSNumber)?.doubleValue else { return nil }
        return Date(timeIntervalSince1970: ms / 1000)
    }

    /// `storedJobIdForKey(key, jobIds)`: the stored job id a key names, compared without case.
    nonisolated static func storedJobIdForKey(_ key: String, jobIds: [String]) -> String? {
        callJSON("storedJobIdForKey", arguments: [key, jobIds]) as? String
    }

    /// `deadlineAssignedProjectIds(data, personIds, jobIds)`: keys mapped back to stored job ids (1.8.0).
    nonisolated static func deadlineAssignedProjectIds(_ data: [String: Any], personIds: [String], jobIds: [String]) -> [String]? {
        guard let rows = callJSON("deadlineAssignedProjectIds", arguments: [peopleDocumentJSON(data), personIds, jobIds]) as? [Any] else { return nil }
        return rows.compactMap { $0 as? String }
    }

    /// `mergeStoredRows(stored, next)`: each next row laid over its stored row by id, unknown keys kept.
    nonisolated static func mergeStoredRows(stored: Any?, next: [[String: Any]]) -> [[String: Any]]? {
        let storedJSON: Any = stored.map { FirebaseBackend.firestoreJSON($0) } ?? NSNull()
        let nextJSON = next.map { peopleDocumentJSON($0) }
        return callJSON("mergeStoredRows", arguments: [storedJSON, nextJSON]) as? [[String: Any]]
    }

    // MARK: Materials

    /// `parseMaterialLineDocument(docId, data, { timeZone })`. Nil without an id, a job id or a name.
    nonisolated static func parseMaterialLineDocument(
        documentId: String,
        data: [String: Any],
        timeZone: String = OrganizationRulebookContext.timeZoneIdentifier
    ) -> CanonicalDocumentRow? {
        opsRow("parseMaterialLineDocument", [documentId, peopleDocumentJSON(data), zoneOptions(timeZone)])
    }

    /// `materialLineFields(input, timeZone)`: the stored shape of a line (`date` as organisation-zone midnight ms).
    nonisolated static func materialLineFields(
        _ input: [String: Any],
        timeZone: String = OrganizationRulebookContext.timeZoneIdentifier
    ) -> [String: Any]? {
        callJSON("materialLineFields", arguments: [peopleDocumentJSON(input), timeZone]) as? [String: Any]
    }

    /// `materialSendStatusWriteFields(currentStatus, requestType)`: `{ status, lastSentRequestType }`.
    nonisolated static func materialSendStatusWriteFields(currentStatus: String, requestType: String) -> (status: String, lastSentRequestType: String)? {
        guard let row = callJSON("materialSendStatusWriteFields", arguments: [currentStatus, requestType]) as? [String: Any],
              let status = row["status"] as? String,
              let type = row["lastSentRequestType"] as? String else { return nil }
        return (status, type)
    }

    /// `parseMaterialCatalogueDocument(docId, data)`. Nil without an id or a name. Missing brand → "Custom".
    nonisolated static func parseMaterialCatalogueDocument(documentId: String, data: [String: Any]) -> CanonicalDocumentRow? {
        opsRow("parseMaterialCatalogueDocument", [documentId, peopleDocumentJSON(data)])
    }

    /// `materialCatalogueItemFields(item)`: the stored shape of one catalogue item (blank optionals null, missing
    /// brand "Custom", missing category "Other", `length` mirrored to `sizeOrLength`). JSON values.
    nonisolated static func materialCatalogueItemFields(_ item: [String: Any]) -> [String: Any]? {
        callJSON("materialCatalogueItemFields", arguments: [peopleDocumentJSON(item)]) as? [String: Any]
    }

    /// `materialCatalogueWrites({ stored, next, loaded })`: items to write (`{ id, create, set, remove }`) and ids to
    /// delete. Nothing is deleted unless `loaded` and `next` is not empty. `next` rows are
    /// `MaterialCatalogueItemInput` maps (native values; `createdAt` passes through).
    nonisolated static func materialCatalogueWrites(
        stored: [(id: String, data: [String: Any])],
        next: [[String: Any]],
        loaded: Bool
    ) -> (write: [(id: String, create: Bool, set: [String: Any], remove: [String])], remove: [String])? {
        let input: [String: Any] = [
            "stored": stored.map { ["id": $0.id, "data": peopleDocumentJSON($0.data)] as [String: Any] },
            "next": next.map { peopleDocumentJSON($0) },
            "loaded": loaded,
        ]
        guard let result = callJSON("materialCatalogueWrites", arguments: [input]) as? [String: Any],
              let write = result["write"] as? [[String: Any]],
              let remove = result["remove"] as? [Any] else { return nil }
        let writes = write.compactMap { row -> (id: String, create: Bool, set: [String: Any], remove: [String])? in
            guard let id = row["id"] as? String, let set = row["set"] as? [String: Any] else { return nil }
            let removed = (row["remove"] as? [Any])?.compactMap { $0 as? String } ?? []
            return (id, (row["create"] as? Bool) ?? false, set, removed)
        }
        return (writes, remove.compactMap { $0 as? String })
    }

    /// `parseMaterialSendRecordDocument(docId, data, { timeZone })`. Nil without an id, a job id or `sentAt`.
    nonisolated static func parseMaterialSendRecordDocument(
        documentId: String,
        data: [String: Any],
        timeZone: String = OrganizationRulebookContext.timeZoneIdentifier
    ) -> CanonicalDocumentRow? {
        opsRow("parseMaterialSendRecordDocument", [documentId, peopleDocumentJSON(data), zoneOptions(timeZone)])
    }

    /// `materialSendRecordCreateFields(input)`: the stored shape of a new send record. Instants are passed as
    /// epoch ms and come back as given (the caller swaps in Timestamps).
    nonisolated static func materialSendRecordCreateFields(_ input: [String: Any]) -> [String: Any]? {
        callJSON("materialSendRecordCreateFields", arguments: [peopleDocumentJSON(input)]) as? [String: Any]
    }

    // MARK: Wholesalers, site audits, tasks

    /// `parseWholesalerDocument(docId, data)`. Nil without an id or a name. Contacts without an id get
    /// `wholesalerContactId`; exactly one contact is primary.
    nonisolated static func parseWholesalerDocument(documentId: String, data: [String: Any]) -> CanonicalDocumentRow? {
        opsRow("parseWholesalerDocument", [documentId, peopleDocumentJSON(data)])
    }

    /// `parseSiteAuditDocument(docId, data, { timeZone })`. Nil without an id, a job id or a type.
    nonisolated static func parseSiteAuditDocument(
        documentId: String,
        data: [String: Any],
        timeZone: String = OrganizationRulebookContext.timeZoneIdentifier
    ) -> CanonicalDocumentRow? {
        opsRow("parseSiteAuditDocument", [documentId, peopleDocumentJSON(data), zoneOptions(timeZone)])
    }

    /// `parseTaskDocument(docId, data, { timeZone })`. Nil without an id or a title; a task with no job id is kept.
    nonisolated static func parseTaskDocument(
        documentId: String,
        data: [String: Any],
        timeZone: String = OrganizationRulebookContext.timeZoneIdentifier
    ) -> CanonicalDocumentRow? {
        opsRow("parseTaskDocument", [documentId, peopleDocumentJSON(data), zoneOptions(timeZone)])
    }

    /// `taskFields(input)`: the stored shape of a task (blank optionals and empty lists null).
    nonisolated static func taskFields(_ input: [String: Any]) -> [String: Any]? {
        callJSON("taskFields", arguments: [peopleDocumentJSON(input)]) as? [String: Any]
    }

    // MARK: settings/jobTypes, settings/tradeTypeInventory, operativeProfiles

    /// `parseJobTypesDocument(data, organization)`: canonical names, de-duplicated, sorted.
    nonisolated static func parseJobTypesDocument(_ data: [String: Any]?, organization: [String: Any]? = nil) -> [String]? {
        let args: [Any] = [data.map { peopleDocumentJSON($0) as Any } ?? NSNull(), organization.map { peopleDocumentJSON($0) as Any } ?? NSNull()]
        return ((callJSON("parseJobTypesDocument", arguments: args) as? [String: Any])?["jobTypes"] as? [Any])?.compactMap { $0 as? String }
    }

    /// `mergeJobTypeCatalogues(stored, recovered)`: the stored list with recovered names and the restored defaults.
    nonisolated static func mergeJobTypeCatalogues(stored: [String], recovered: [String]) -> [String]? {
        (callJSON("mergeJobTypeCatalogues", arguments: [stored, recovered]) as? [Any])?.compactMap { $0 as? String }
    }

    /// `jobTypesWriteFields(stored, next)`: the names to write, or nil when the list is empty or unchanged (no write).
    /// The outer optional is nil when the script did not answer.
    nonisolated static func jobTypesWriteFields(stored: [String]?, next: [String]) -> [String]?? {
        guard let value = callJSON("jobTypesWriteFields", arguments: [stored.map { $0 as Any } ?? NSNull(), next]) else { return nil }
        if value is NSNull { return .some(nil) }
        guard let names = ((value as? [String: Any])?["set"] as? [String: Any])?["jobTypes"] as? [Any] else { return nil }
        return .some(names.compactMap { $0 as? String })
    }

    /// `parseTradeTypeInventory(data)`: trimmed, de-duplicated without case, stored order.
    nonisolated static func parseTradeTypeInventory(_ data: [String: Any]?) -> [String]? {
        let arg: Any = data.map { peopleDocumentJSON($0) as Any } ?? NSNull()
        return ((callJSON("parseTradeTypeInventory", arguments: [arg]) as? [String: Any])?["trades"] as? [Any])?.compactMap { $0 as? String }
    }

    /// `tradeTypeInventoryWriteFields(stored, incoming)`: the trades to write, `.some(nil)` when nothing is new.
    nonisolated static func tradeTypeInventoryWriteFields(stored: [String: Any]?, incoming: [String]) -> [String]?? {
        let arg: Any = stored.map { peopleDocumentJSON($0) as Any } ?? NSNull()
        guard let value = callJSON("tradeTypeInventoryWriteFields", arguments: [arg, incoming]) else { return nil }
        if value is NSNull { return .some(nil) }
        guard let trades = ((value as? [String: Any])?["set"] as? [String: Any])?["trades"] as? [Any] else { return nil }
        return .some(trades.compactMap { $0 as? String })
    }

    /// `parseOperativeProfileDocument(docId, data)`: the pay mirror (an hourly mirror stays hourly).
    nonisolated static func parseOperativeProfileDocument(documentId: String, data: [String: Any]) -> CanonicalDocumentRow? {
        opsRow("parseOperativeProfileDocument", [documentId, peopleDocumentJSON(data)])
    }

    // MARK: Health & safety

    /// `healthSafetyDocumentId(jobId, isSmallWorks)`: `healthSafety_{projects|smallWorks}_{KEY}`.
    nonisolated static func healthSafetyDocumentId(jobId: String, isSmallWorks: Bool) -> String? {
        callJSON("healthSafetyDocumentId", arguments: [jobId, isSmallWorks]) as? String
    }

    /// `healthSafetyDocumentIds(jobId, isSmallWorks)`: the shared id first, then an older stored-case id.
    nonisolated static func healthSafetyDocumentIds(jobId: String, isSmallWorks: Bool) -> [String]? {
        (callJSON("healthSafetyDocumentIds", arguments: [jobId, isSmallWorks]) as? [Any])?.compactMap { $0 as? String }
    }

    /// `healthSafetySignatureKey(issueId, userId)`: `{issue}__{user}`, lower case.
    nonisolated static func healthSafetySignatureKey(issueId: String, userId: String) -> String? {
        callJSON("healthSafetySignatureKey", arguments: [issueId, userId]) as? String
    }

    /// `parseHealthSafetyDocument(data, { projectId, timeZone })`: talks, issues, folded signatures, RAMS and other docs.
    nonisolated static func parseHealthSafetyDocument(
        _ data: [String: Any],
        projectId: String,
        timeZone: String = OrganizationRulebookContext.timeZoneIdentifier
    ) -> CanonicalDocumentRow? {
        opsRow("parseHealthSafetyDocument", [peopleDocumentJSON(data), ["projectId": projectId, "timeZone": timeZone] as [String: Any]])
    }

    /// `healthSafetyDocumentWriteFields(stored, next)`: `{ set, remove }` for the five arrays only. `next` rows are
    /// native maps; the merged rows come back as JSON (instants as `{ seconds, nanoseconds }` or ms), so the caller
    /// converts them with `ScriptFirestoreValue.native(_:)`.
    nonisolated static func healthSafetyDocumentWriteFields(stored: [String: Any]?, next: [String: [[String: Any]]]) -> (set: [String: Any], remove: [String])? {
        let storedJSON: Any = stored.map { peopleDocumentJSON($0) as Any } ?? NSNull()
        let nextJSON = next.mapValues { $0.map { peopleDocumentJSON($0) } }
        guard let row = callJSON("healthSafetyDocumentWriteFields", arguments: [storedJSON, nextJSON]) as? [String: Any],
              let set = row["set"] as? [String: Any],
              let remove = row["remove"] as? [Any] else { return nil }
        return (set, remove.compactMap { $0 as? String })
    }

    /// `healthSafetySignatureWriteFields(input)`. Instants are passed as epoch ms.
    nonisolated static func healthSafetySignatureWriteFields(
        issueId: String,
        userId: String,
        signatureId: String?,
        status: String,
        readConfirmed: Bool,
        signatureImageBase64: String?,
        signedAt: Date?,
        reminderSentAt: Date?
    ) -> CanonicalHealthSafetySignatureWrite? {
        var input: [String: Any] = [
            "issueId": issueId,
            "userId": userId,
            "status": status,
            "readConfirmed": readConfirmed,
        ]
        if let signatureId { input["signatureId"] = signatureId }
        if let signatureImageBase64 { input["signatureImageBase64"] = signatureImageBase64 }
        if let signedAt { input["signedAt"] = signedAt.timeIntervalSince1970 * 1000 }
        if let reminderSentAt { input["reminderSentAt"] = reminderSentAt.timeIntervalSince1970 * 1000 }
        return CanonicalHealthSafetySignatureWrite(callJSON("healthSafetySignatureWriteFields", arguments: [input]))
    }

    /// `healthSafetyIssueStatus(issue, signatures)`: `complete` when every recipient signed, else `scheduled` /
    /// `awaiting`.
    nonisolated static func healthSafetyIssueStatus(
        issueId: String,
        status: String,
        recipientUserIds: [String],
        signatures: [(issueId: String, userId: String, status: String)]
    ) -> String? {
        let issue: [String: Any] = ["id": issueId, "status": status, "recipientUserIds": recipientUserIds]
        let rows = signatures.map { ["issueId": $0.issueId, "userId": $0.userId, "status": $0.status] }
        return callJSON("healthSafetyIssueStatus", arguments: [issue, rows]) as? String
    }

    /// `HS_ISSUE_STATUS_STORED[normalizeHSIssueStatus(status)]`: the word written for an issue status.
    nonisolated static func healthSafetyStoredIssueStatus(_ status: String) -> String? {
        guard let token = callJSON("normalizeHSIssueStatus", arguments: [status]) as? String,
              let map = constant("HS_ISSUE_STATUS_STORED", as: [String: String].self) else { return nil }
        return map[token]
    }

    // MARK: Variations

    /// `parseVariationDocument(docId, data)`. Nil without an id. Lines with any content are kept; a line without an
    /// id gets `variationLineId`.
    nonisolated static func parseVariationDocument(documentId: String, data: [String: Any]) -> CanonicalDocumentRow? {
        opsRow("parseVariationDocument", [documentId, peopleDocumentJSON(data)])
    }

    /// `parseVariationTrackerDocument(parentId, data)`: a missing document is a disabled tracker.
    nonisolated static func parseVariationTrackerDocument(parentId: String, data: [String: Any]?) -> CanonicalDocumentRow? {
        let arg: Any = data.map { peopleDocumentJSON($0) as Any } ?? NSNull()
        return opsRow("parseVariationTrackerDocument", [parentId, arg])
    }

    // MARK: Notifications

    /// `parseNotificationDocument(docId, data, { timeZone, organizationId })`. Nil only without an id or a type.
    nonisolated static func parseNotificationDocument(
        documentId: String,
        data: [String: Any],
        organizationId: String?,
        timeZone: String = OrganizationRulebookContext.timeZoneIdentifier
    ) -> CanonicalDocumentRow? {
        let options: [String: Any] = ["timeZone": timeZone, "organizationId": organizationId ?? NSNull()]
        return opsRow("parseNotificationDocument", [documentId, peopleDocumentJSON(data), options])
    }

    /// `KNOWN_NOTIFICATION_TYPES`.
    nonisolated static var knownNotificationTypes: [String] {
        constant("KNOWN_NOTIFICATION_TYPES", as: [String].self) ?? []
    }

    // MARK: Warning resolutions

    /// `sharedWarningResolutionKey(key, timeZone)`: a legacy iOS key in its shared form; any other key as stored.
    nonisolated static func sharedWarningResolutionKey(
        _ key: String,
        timeZone: String = OrganizationRulebookContext.timeZoneIdentifier
    ) -> String? {
        callJSON("sharedWarningResolutionKey", arguments: [key, timeZone]) as? String
    }

    /// `parseWarningResolutionDocument(docId, data, { timeZone })`.
    nonisolated static func parseWarningResolutionDocument(
        documentId: String,
        data: [String: Any],
        timeZone: String = OrganizationRulebookContext.timeZoneIdentifier
    ) -> CanonicalDocumentRow? {
        opsRow("parseWarningResolutionDocument", [documentId, peopleDocumentJSON(data), zoneOptions(timeZone)])
    }

    /// `warningResolutionMigrationWrites({ docs, legacyKeyForms, resolvedByUserId, timeZone })`: shared-key documents
    /// to write for legacy keys (never deletes). Nil when the script did not answer.
    nonisolated static func warningResolutionMigrationWrites(
        documents: [(id: String, data: [String: Any])],
        legacyKeyForms: [String: [String]],
        resolvedByUserId: String,
        timeZone: String = OrganizationRulebookContext.timeZoneIdentifier
    ) -> [CanonicalWarningResolutionWrite]? {
        let input: [String: Any] = [
            "docs": documents.map { ["id": $0.id, "data": peopleDocumentJSON($0.data)] as [String: Any] },
            "legacyKeyForms": legacyKeyForms,
            "resolvedByUserId": resolvedByUserId,
            "timeZone": timeZone,
        ]
        guard let rows = callJSON("warningResolutionMigrationWrites", arguments: [input]) as? [Any] else { return nil }
        return rows.compactMap { CanonicalWarningResolutionWrite($0) }
    }
}
