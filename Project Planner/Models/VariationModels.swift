//
//  VariationModels.swift
//  Project Planner
//
//  Shared contract with the web app. Identity is `id` (document id), never `voNumber`.
//

import Foundation
import FirebaseFirestore

nonisolated enum VariationParentType: String, Codable, Hashable, Sendable {
    case project
    case smallWork
}

nonisolated enum VariationOrigin: String, Codable, Hashable, Sendable {
    case app
    case tracker
}

nonisolated enum VariationStatus: String, Codable, Hashable, Sendable, CaseIterable {
    case open
    case submitted
    case closed

    var title: String {
        switch self {
        case .open: return "Open"
        case .submitted: return "Submitted"
        case .closed: return "Closed"
        }
    }

    /// User-facing copy from the shared contract. Shown when a single status is filtered.
    var definition: String {
        switch self {
        case .open:
            return "Any variations that have not been submitted, and are still required or have been carried out."
        case .submitted:
            return "Any variations that have been submitted by the QS to the client."
        case .closed:
            return "Any variations that are no longer required."
        }
    }

    var listOpacity: Double {
        switch self {
        case .open: return 1
        case .submitted: return 0.74
        case .closed: return 0.54
        }
    }
}

nonisolated enum VariationNumberingMode: String, Codable, Hashable, Sendable {
    case lockSubmitted
    case resequenceAll
}

nonisolated struct VariationLabourLine: Identifiable, Hashable, Sendable {
    var id: String
    var trade: String
    var hours: Double
}

nonisolated struct VariationMaterialLine: Identifiable, Hashable, Sendable {
    var id: String
    var name: String
    var quantity: String
}

nonisolated struct VariationEvidenceItem: Identifiable, Hashable, Sendable {
    var id: String
    var fileName: String
    var contentType: String
    var sizeBytes: Int
    var storagePath: String
    var downloadURL: String
    var uploadedByUid: String
    var uploadedAt: Date
    /// Local-only: file is queued or uploading and not yet on the document.
    var isPending: Bool
}

nonisolated struct VariationNumberHistoryEntry: Hashable, Sendable {
    var from: String
    var to: String
    var at: Date
    var byUid: String
}

nonisolated struct VariationStatusHistoryEntry: Hashable, Sendable {
    var status: String
    var byUid: String
    var byName: String
    var at: Date
}

nonisolated struct Variation: Identifiable, Hashable, Sendable {
    var id: String
    var orgId: String
    var parentType: VariationParentType
    var parentId: String
    var parentName: String
    var origin: VariationOrigin
    var voNumber: String
    var sequence: Int
    var voNumberLocked: Bool
    var numberHistory: [VariationNumberHistoryEntry]
    var heading: String
    var description: String
    var status: VariationStatus
    var labour: [VariationLabourLine]
    var materials: [VariationMaterialLine]
    var evidence: [VariationEvidenceItem]
    var totalLabourHours: Double
    var materialLineCount: Int
    var evidenceCount: Int
    var createdByUid: String
    var createdByName: String
    var createdAt: Date
    var updatedByUid: String
    var updatedAt: Date
    var statusHistory: [VariationStatusHistoryEntry]
    var submittedAt: Date?
    var closedAt: Date?
    var isDeleted: Bool

    mutating func recomputeCounts() {
        totalLabourHours = labour.reduce(0) { $0 + $1.hours }
        materialLineCount = materials.count
        evidenceCount = evidence.filter { !$0.isPending && !$0.downloadURL.isEmpty }.count
    }
}

nonisolated struct VariationTracker: Hashable, Sendable {
    var parentId: String
    var parentType: VariationParentType
    var enabled: Bool
    var enabledAt: Date?
    var enabledByUid: String?
    var numberingMode: VariationNumberingMode
    var prefix: String
    var padding: Int
    var version: Int
    var lockedByUid: String?
    var lockedByName: String?
    var lockedAt: Date?

    static func disabled(parentId: String, parentType: VariationParentType) -> VariationTracker {
        VariationTracker(
            parentId: parentId,
            parentType: parentType,
            enabled: false,
            enabledAt: nil,
            enabledByUid: nil,
            numberingMode: .lockSubmitted,
            prefix: VariationNumbering.defaultPrefix,
            padding: VariationNumbering.defaultPadding,
            version: 0,
            lockedByUid: nil,
            lockedByName: nil,
            lockedAt: nil
        )
    }
}

nonisolated enum VariationNumbering {
    static let defaultPrefix = "VO-"
    static let defaultPadding = 3

    static func numericValue(from voNumber: String) -> Int {
        let digits = voNumber.filter(\.isNumber)
        return Int(digits) ?? 0
    }

    static func format(prefix: String, padding: Int, value: Int) -> String {
        let pad = max(1, padding)
        let body = String(format: "%0\(pad)d", value)
        return "\(prefix)\(body)"
    }

    /// Next number is always max+1. Closed/deleted numbers are never reused.
    static func nextFree(existing: [Variation], prefix: String = defaultPrefix, padding: Int = defaultPadding) -> String {
        let maxVal = existing.map { numericValue(from: $0.voNumber) }.max() ?? 0
        return format(prefix: prefix, padding: padding, value: maxVal + 1)
    }

    static func parentName(jobNumber: String, siteName: String) -> String {
        let job = jobNumber.trimmingCharacters(in: .whitespacesAndNewlines)
        let site = siteName.trimmingCharacters(in: .whitespacesAndNewlines)
        if job.isEmpty { return site }
        if site.isEmpty { return job }
        return "\(job) · \(site)"
    }
}

nonisolated enum VariationCodec {
    /// RULEBOOK 1.8.0 §1: one variation through `parseVariationDocument` (`variations/{id}`, a
    /// `settings/variationItem_{id}` document or a settings-log entry). Lines with any content are kept; a line stored
    /// without an id gets `variationLineId` (the same on web and every read, never random). Counters come from the
    /// lines. Nil without an id.
    nonisolated static func variation(from data: [String: Any], documentId: String) -> Variation? {
        guard let row = CanonicalBusinessEngine.parseVariationDocument(documentId: documentId, data: data) else { return nil }
        func at(_ value: Date?) -> Date { value ?? Date(timeIntervalSince1970: 0) }
        return Variation(
            id: row.id,
            orgId: row.text("orgId"),
            parentType: VariationParentType(rawValue: row.text("parentType")) ?? .project,
            parentId: row.text("parentId"),
            parentName: row.text("parentName"),
            origin: VariationOrigin(rawValue: row.text("origin")) ?? .app,
            voNumber: row.text("voNumber"),
            sequence: Int(row.number("sequence") ?? 0),
            voNumberLocked: row.bool("voNumberLocked"),
            numberHistory: row.rows("numberHistory").map { entry in
                VariationNumberHistoryEntry(from: entry.text("from"), to: entry.text("to"), at: at(entry.date("atMs")), byUid: entry.text("byUid"))
            },
            heading: row.text("heading"),
            // Description keeps its stored spacing (the reader returns it untrimmed).
            description: row.raw["description"] as? String ?? "",
            status: VariationStatus(rawValue: row.text("status")) ?? .open,
            labour: row.rows("labour").map { line in
                VariationLabourLine(id: line.id, trade: line.text("trade"), hours: line.number("hours") ?? 0)
            },
            materials: row.rows("materials").map { line in
                VariationMaterialLine(id: line.id, name: line.text("name"), quantity: line.text("quantity"))
            },
            evidence: row.rows("evidence").map { item in
                VariationEvidenceItem(
                    id: item.id,
                    fileName: item.text("fileName"),
                    contentType: item.text("contentType"),
                    sizeBytes: Int(item.number("sizeBytes") ?? 0),
                    storagePath: item.text("storagePath"),
                    downloadURL: item.text("downloadURL"),
                    uploadedByUid: item.text("uploadedByUid"),
                    uploadedAt: at(item.date("uploadedAtMs")),
                    isPending: false
                )
            },
            totalLabourHours: row.number("totalLabourHours") ?? 0,
            materialLineCount: Int(row.number("materialLineCount") ?? 0),
            evidenceCount: Int(row.number("evidenceCount") ?? 0),
            createdByUid: row.text("createdByUid"),
            createdByName: row.text("createdByName"),
            createdAt: at(row.date("createdAtMs")),
            updatedByUid: row.text("updatedByUid"),
            updatedAt: at(row.date("updatedAtMs")),
            statusHistory: row.rows("statusHistory").map { entry in
                VariationStatusHistoryEntry(status: entry.text("status"), byUid: entry.text("byUid"), byName: entry.text("byName"), at: at(entry.date("atMs")))
            },
            submittedAt: row.date("submittedAtMs"),
            closedAt: row.date("closedAtMs"),
            isDeleted: row.bool("isDeleted")
        )
    }

    static func firestoreMap(from variation: Variation) -> [String: Any] {
        var map: [String: Any] = [
            "id": variation.id,
            "orgId": variation.orgId,
            "parentType": variation.parentType.rawValue,
            "parentId": variation.parentId,
            "parentName": variation.parentName,
            "origin": variation.origin.rawValue,
            "voNumber": variation.voNumber,
            "sequence": variation.sequence,
            "voNumberLocked": variation.voNumberLocked,
            "numberHistory": variation.numberHistory.map { entry in
                [
                    "from": entry.from,
                    "to": entry.to,
                    "at": Timestamp(date: entry.at),
                    "byUid": entry.byUid
                ] as [String: Any]
            },
            "heading": variation.heading,
            "description": variation.description,
            "status": variation.status.rawValue,
            "labour": variation.labour.map { line in
                [
                    "id": line.id,
                    "trade": line.trade,
                    "hours": line.hours
                ] as [String: Any]
            },
            "materials": variation.materials.map { line in
                [
                    "id": line.id,
                    "name": line.name,
                    "quantity": line.quantity
                ] as [String: Any]
            },
            "evidence": variation.evidence.filter { !$0.isPending }.map { item in
                [
                    "id": item.id,
                    "fileName": item.fileName,
                    "contentType": item.contentType,
                    "sizeBytes": item.sizeBytes,
                    "storagePath": item.storagePath,
                    "downloadURL": item.downloadURL,
                    "uploadedByUid": item.uploadedByUid,
                    "uploadedAt": Timestamp(date: item.uploadedAt)
                ] as [String: Any]
            },
            "totalLabourHours": variation.totalLabourHours,
            "materialLineCount": variation.materialLineCount,
            "evidenceCount": variation.evidenceCount,
            "createdByUid": variation.createdByUid,
            "createdByName": variation.createdByName,
            "createdAt": Timestamp(date: variation.createdAt),
            "updatedByUid": variation.updatedByUid,
            "updatedAt": Timestamp(date: variation.updatedAt),
            "statusHistory": variation.statusHistory.map { entry in
                [
                    "status": entry.status,
                    "byUid": entry.byUid,
                    "byName": entry.byName,
                    "at": Timestamp(date: entry.at)
                ] as [String: Any]
            },
            "isDeleted": variation.isDeleted
        ]
        if let submittedAt = variation.submittedAt {
            map["submittedAt"] = Timestamp(date: submittedAt)
        }
        if let closedAt = variation.closedAt {
            map["closedAt"] = Timestamp(date: closedAt)
        }
        return map
    }

    /// RULEBOOK 1.8.0: `variationTrackers/{parentId}` through `parseVariationTrackerDocument`.
    static func tracker(from data: [String: Any], parentId: String) -> VariationTracker {
        guard let row = CanonicalBusinessEngine.parseVariationTrackerDocument(parentId: parentId, data: data) else {
            return .disabled(parentId: parentId, parentType: .project)
        }
        return VariationTracker(
            parentId: row.text("parentId").isEmpty ? parentId : row.text("parentId"),
            parentType: VariationParentType(rawValue: row.text("parentType")) ?? .project,
            enabled: row.bool("enabled"),
            enabledAt: row.date("enabledAtMs"),
            enabledByUid: row.optionalText("enabledByUid"),
            numberingMode: VariationNumberingMode(rawValue: row.text("numberingMode")) ?? .lockSubmitted,
            prefix: row.optionalText("prefix") ?? VariationNumbering.defaultPrefix,
            padding: Int(row.number("padding") ?? Double(VariationNumbering.defaultPadding)),
            version: Int(row.number("version") ?? 0),
            lockedByUid: row.optionalText("lockedByUid"),
            lockedByName: row.optionalText("lockedByName"),
            lockedAt: row.date("lockedAtMs")
        )
    }

    static func firestoreMap(from tracker: VariationTracker) -> [String: Any] {
        var map: [String: Any] = [
            "parentId": tracker.parentId,
            "parentType": tracker.parentType.rawValue,
            "enabled": tracker.enabled,
            "numberingMode": tracker.numberingMode.rawValue,
            "prefix": tracker.prefix,
            "padding": tracker.padding,
            "version": tracker.version
        ]
        if let enabledAt = tracker.enabledAt { map["enabledAt"] = Timestamp(date: enabledAt) }
        if let enabledByUid = tracker.enabledByUid { map["enabledByUid"] = enabledByUid }
        if let lockedByUid = tracker.lockedByUid { map["lockedByUid"] = lockedByUid }
        if let lockedByName = tracker.lockedByName { map["lockedByName"] = lockedByName }
        if let lockedAt = tracker.lockedAt { map["lockedAt"] = Timestamp(date: lockedAt) }
        return map
    }
}
