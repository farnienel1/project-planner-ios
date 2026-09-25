//
//  VariationModels.swift
//  Project Planner
//
//  Shared contract with the web app. Identity is `id` (document id), never `voNumber`.
//

import Foundation
@preconcurrency import FirebaseFirestore

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
    nonisolated static func variation(from data: [String: Any], documentId: String) -> Variation? {
        let parentType = VariationParentType(rawValue: data["parentType"] as? String ?? "") ?? .project
        let origin = VariationOrigin(rawValue: data["origin"] as? String ?? "") ?? .app
        let status = VariationStatus(rawValue: data["status"] as? String ?? "") ?? .open
        return Variation(
            id: documentId,
            orgId: data["orgId"] as? String ?? data["organizationId"] as? String ?? "",
            parentType: parentType,
            parentId: data["parentId"] as? String ?? "",
            parentName: data["parentName"] as? String ?? "",
            origin: origin,
            voNumber: data["voNumber"] as? String ?? "",
            sequence: firestoreInt(data["sequence"]),
            voNumberLocked: data["voNumberLocked"] as? Bool ?? false,
            numberHistory: numberHistory(from: data["numberHistory"]),
            heading: data["heading"] as? String ?? "",
            description: data["description"] as? String ?? "",
            status: status,
            labour: labour(from: data["labour"]),
            materials: materials(from: data["materials"]),
            evidence: evidence(from: data["evidence"]),
            totalLabourHours: firestoreDouble(data["totalLabourHours"]),
            materialLineCount: firestoreInt(data["materialLineCount"]),
            evidenceCount: firestoreInt(data["evidenceCount"]),
            createdByUid: data["createdByUid"] as? String ?? "",
            createdByName: data["createdByName"] as? String ?? "",
            createdAt: date(from: data["createdAt"]) ?? Date(),
            updatedByUid: data["updatedByUid"] as? String ?? "",
            updatedAt: date(from: data["updatedAt"]) ?? Date(),
            statusHistory: statusHistory(from: data["statusHistory"]),
            submittedAt: date(from: data["submittedAt"]),
            closedAt: date(from: data["closedAt"]),
            isDeleted: data["isDeleted"] as? Bool ?? false
        )
    }

    nonisolated static func firestoreMap(from variation: Variation) -> [String: Any] {
        var map: [String: Any] = [
            "id": variation.id,
            "orgId": variation.orgId,
            "organizationId": variation.orgId,
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

    nonisolated static func tracker(from data: [String: Any], parentId: String) -> VariationTracker {
        VariationTracker(
            parentId: parentId,
            parentType: VariationParentType(rawValue: data["parentType"] as? String ?? "") ?? .project,
            enabled: data["enabled"] as? Bool ?? false,
            enabledAt: date(from: data["enabledAt"]),
            enabledByUid: data["enabledByUid"] as? String,
            numberingMode: VariationNumberingMode(rawValue: data["numberingMode"] as? String ?? "") ?? .lockSubmitted,
            prefix: {
                let raw = (data["prefix"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                return raw.isEmpty ? VariationNumbering.defaultPrefix : raw
            }(),
            padding: {
                let parsed = firestoreInt(data["padding"])
                return parsed > 0 ? parsed : VariationNumbering.defaultPadding
            }(),
            version: firestoreInt(data["version"]),
            lockedByUid: data["lockedByUid"] as? String,
            lockedByName: data["lockedByName"] as? String,
            lockedAt: date(from: data["lockedAt"])
        )
    }

    nonisolated static func firestoreMap(from tracker: VariationTracker) -> [String: Any] {
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

    nonisolated private static func firestoreInt(_ value: Any?) -> Int {
        if let i = value as? Int { return i }
        if let n = value as? Int64 { return Int(n) }
        if let n = value as? NSNumber { return n.intValue }
        if let d = value as? Double { return Int(d) }
        if let s = value as? String { return Int(s) ?? 0 }
        return 0
    }

    nonisolated private static func firestoreDouble(_ value: Any?) -> Double {
        if let d = value as? Double { return d }
        if let i = value as? Int { return Double(i) }
        if let n = value as? NSNumber { return n.doubleValue }
        if let s = value as? String { return Double(s) ?? 0 }
        return 0
    }

    nonisolated private static func date(from value: Any?) -> Date? {
        if let ts = value as? Timestamp { return ts.dateValue() }
        if let date = value as? Date { return date }
        return nil
    }

    nonisolated private static func labour(from value: Any?) -> [VariationLabourLine] {
        ((value as? [[String: Any]]) ?? []).compactMap { row in
            let id = row["id"] as? String ?? UUID().uuidString
            return VariationLabourLine(
                id: id,
                trade: row["trade"] as? String ?? "",
                hours: firestoreDouble(row["hours"])
            )
        }
    }

    nonisolated private static func materials(from value: Any?) -> [VariationMaterialLine] {
        ((value as? [[String: Any]]) ?? []).compactMap { row in
            let id = row["id"] as? String ?? UUID().uuidString
            return VariationMaterialLine(
                id: id,
                name: row["name"] as? String ?? "",
                quantity: row["quantity"] as? String ?? ""
            )
        }
    }

    nonisolated private static func evidence(from value: Any?) -> [VariationEvidenceItem] {
        ((value as? [[String: Any]]) ?? []).compactMap { row in
            let id = row["id"] as? String ?? UUID().uuidString
            return VariationEvidenceItem(
                id: id,
                fileName: row["fileName"] as? String ?? "",
                contentType: row["contentType"] as? String ?? "",
                sizeBytes: firestoreInt(row["sizeBytes"]),
                storagePath: row["storagePath"] as? String ?? "",
                downloadURL: row["downloadURL"] as? String ?? "",
                uploadedByUid: row["uploadedByUid"] as? String ?? "",
                uploadedAt: date(from: row["uploadedAt"]) ?? Date(),
                isPending: false
            )
        }
    }

    nonisolated private static func numberHistory(from value: Any?) -> [VariationNumberHistoryEntry] {
        ((value as? [[String: Any]]) ?? []).compactMap { row in
            VariationNumberHistoryEntry(
                from: row["from"] as? String ?? "",
                to: row["to"] as? String ?? "",
                at: date(from: row["at"]) ?? Date(),
                byUid: row["byUid"] as? String ?? ""
            )
        }
    }

    nonisolated private static func statusHistory(from value: Any?) -> [VariationStatusHistoryEntry] {
        ((value as? [[String: Any]]) ?? []).compactMap { row in
            VariationStatusHistoryEntry(
                status: row["status"] as? String ?? "",
                byUid: row["byUid"] as? String ?? "",
                byName: row["byName"] as? String ?? "",
                at: date(from: row["at"]) ?? Date()
            )
        }
    }
}
