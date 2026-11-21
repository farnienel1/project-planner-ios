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

/// RULEBOOK 1.52.0 §22: a labour line is a crew — operatives × hours each (`variationLabourCrew`); `hours` is their
/// product. A line stored before 1.52 reads as one operative × its hours.
nonisolated struct VariationLabourLine: Identifiable, Hashable, Sendable {
    var id: String
    var trade: String
    var hours: Double
    var operatives: Int = 1
    var hoursEach: Double = 0
    /// True when the stored row had no crew fields and the line has not been edited: it is written back exactly as
    /// `{ id, trade, hours }` (never new fields on an untouched old line).
    var legacyShape: Bool = false
}

/// RULEBOOK 1.52.0 §22: a material quantity is a number with its unit (`variationMaterialQuantity`). `quantity` is the
/// stored text (shown as stored when it is not a number, e.g. "1-"); `quantityValue` nil then.
nonisolated struct VariationMaterialLine: Identifiable, Hashable, Sendable {
    var id: String
    var name: String
    var quantity: String
    var quantityValue: Double? = nil
    var unit: String = ""
    /// True when the stored row had no `quantityValue` and the line has not been edited: written back exactly as
    /// `{ id, name, quantity }`.
    var legacyShape: Bool = false
}

/// RULEBOOK 1.52.0 §22: a custom line — name, description, quantity × cost (organisation currency).
nonisolated struct VariationCustomLine: Identifiable, Hashable, Sendable {
    var id: String
    var name: String
    var description: String
    var quantity: Double
    var cost: Double
}

/// RULEBOOK 1.52.0 §22: a subcontractor line — the firm (`subcontractors/{id}` or typed), quote number, quantity × cost.
nonisolated struct VariationSubcontractorLine: Identifiable, Hashable, Sendable {
    var id: String
    var subcontractorId: String
    var name: String
    var quoteNumber: String
    var quantity: Double
    var cost: Double
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

/// RULEBOOK 1.27.0 §24: one evidence file unlinked from a variation (`parseVariationDocument` → `removedEvidence`),
/// written only by `variationEvidenceRemovalWriteFields`. Read-only on iOS; never part of `VariationCodec.firestoreMap`.
nonisolated struct VariationRemovedEvidence: Hashable, Sendable {
    /// The Storage path, else the stored download URL.
    var path: String
    var name: String
    /// The uid of whoever unlinked it.
    var removedBy: String
    var removedAt: Date?
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
    /// RULEBOOK 1.52.0 §22 (reader `customLines`).
    var customLines: [VariationCustomLine] = []
    /// RULEBOOK 1.52.0 §22 (reader `subcontractorLines`).
    var subcontractorLines: [VariationSubcontractorLine] = []
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
    /// RULEBOOK 1.27.0 §24: evidence unlinked from this variation, oldest first. Shown to admins only
    /// (`canViewRemovedEvidence`); never written by a variation save.
    var removedEvidence: [VariationRemovedEvidence] = []

    /// RULEBOOK 1.52.0 §22 `CanonicalBusinessEngine.variationTotals`: the stored counters come from the rule (an
    /// evidence entry counts with a storage path or a URL, the reader's rule). Pending uploads are left out. When the
    /// script does not answer the counters are left as they are.
    mutating func recomputeCounts() {
        guard let totals = totals else { return }
        totalLabourHours = totals.labourHours
        materialLineCount = totals.materialsCount
        evidenceCount = totals.evidenceCount
    }

    /// `variationTotals` of this variation (pending evidence left out). Nil when the script did not answer.
    var totals: RulebookVariationTotals? {
        CanonicalBusinessEngine.variationTotals(rulebookInput)
    }

    /// The variation as the rulebook's totals, export and renumber rules read it (script JSON).
    var rulebookInput: [String: Any] {
        var input: [String: Any] = [
            "id": id,
            "voNumber": voNumber,
            "heading": heading,
            "description": description,
            "status": status.rawValue,
            "createdByName": createdByName,
            "createdAtMs": createdAt.timeIntervalSince1970 * 1000,
            "sequence": sequence,
            "voNumberLocked": voNumberLocked,
            "isDeleted": isDeleted,
            "numberHistory": numberHistory.map { ["from": $0.from, "to": $0.to] },
            "labour": labour.map { line -> [String: Any] in
                line.hoursEach > 0
                    ? ["trade": line.trade, "hours": line.hours, "operatives": line.operatives, "hoursEach": line.hoursEach]
                    : ["trade": line.trade, "hours": line.hours]
            },
            "customLines": customLines.map {
                ["name": $0.name, "description": $0.description, "quantity": $0.quantity, "cost": $0.cost] as [String: Any]
            },
            "subcontractorLines": subcontractorLines.map {
                ["name": $0.name, "quoteNumber": $0.quoteNumber, "quantity": $0.quantity, "cost": $0.cost] as [String: Any]
            },
            "evidence": evidence.filter { !$0.isPending }.map { ["storagePath": $0.storagePath, "downloadURL": $0.downloadURL] },
        ]
        input["materials"] = materials.map { line -> [String: Any] in
            var row: [String: Any] = ["name": line.name, "quantity": line.quantity]
            if let value = line.quantityValue { row["quantityValue"] = value }
            if !line.unit.isEmpty { row["unit"] = line.unit }
            return row
        }
        return input
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
    /// RULEBOOK 1.52.0 §22: the tracker's order lock (`parseVariationTrackerDocument` `orderLocked`, set on web). iOS
    /// only shows it ("Locked", who and when); it never writes it, nor the old 5-minute lock fields.
    var orderLocked: Bool = false
    var orderLockedByName: String?
    var orderLockedAt: Date?

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
            version: 0
        )
    }
}

nonisolated enum VariationNumbering {
    static let defaultPrefix = "VO-"
    static let defaultPadding = 3

    /// RULEBOOK 1.22.0 §22 `CanonicalBusinessEngine.variationNumberValue`: the trailing digits only ("V2-003" → 3).
    static func numericValue(from voNumber: String) -> Int {
        CanonicalBusinessEngine.variationNumberValue(voNumber) ?? 0
    }

    /// RULEBOOK 1.22.0 §22 `CanonicalBusinessEngine.formatVariationNumber`.
    static func format(prefix: String, padding: Int, value: Int) -> String {
        CanonicalBusinessEngine.formatVariationNumber(value, prefix: prefix, padding: padding) ?? "\(prefix)\(value)"
    }

    /// RULEBOOK 1.22.0 §22 `CanonicalBusinessEngine.nextVariationNumber`: highest trailing number + 1 over every
    /// variation, deleted and closed ones included, so a number is never reused ("V2-003" → "V2-004"). Nil when the
    /// script did not answer — nothing is numbered from a Swift guess.
    static func nextFree(existing: [Variation], prefix: String = defaultPrefix, padding: Int = defaultPadding) -> String? {
        CanonicalBusinessEngine.nextVariationNumber(existingNumbers: existing.map(\.voNumber), prefix: prefix, padding: padding)
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
        // Lines stored with the 1.52 shape (an id and the crew / number fields); every other line is written back as
        // stored until it is edited.
        func storedIds(_ key: String, having field: String) -> Set<String> {
            Set(((data[key] as? [Any]) ?? []).compactMap { entry -> String? in
                guard let line = entry as? [String: Any], line[field] != nil,
                      let id = (line["id"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !id.isEmpty else { return nil }
                return id.lowercased()
            })
        }
        let crewIds = storedIds("labour", having: "operatives")
        let numberIds = storedIds("materials", having: "quantityValue")
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
                let hours = line.number("hours") ?? 0
                return VariationLabourLine(
                    id: line.id,
                    trade: line.text("trade"),
                    hours: hours,
                    operatives: max(1, Int(line.number("operatives") ?? 1)),
                    hoursEach: line.number("hoursEach") ?? hours,
                    legacyShape: !crewIds.contains(line.id.lowercased())
                )
            },
            materials: row.rows("materials").map { line in
                VariationMaterialLine(
                    id: line.id,
                    name: line.text("name"),
                    quantity: line.text("quantity"),
                    quantityValue: line.number("quantityValue"),
                    unit: line.text("unit"),
                    legacyShape: !numberIds.contains(line.id.lowercased())
                )
            },
            customLines: row.rows("customLines").map { line in
                VariationCustomLine(
                    id: line.id,
                    name: line.text("name"),
                    description: line.raw["description"] as? String ?? "",
                    quantity: line.number("quantity") ?? 1,
                    cost: line.number("cost") ?? 0
                )
            },
            subcontractorLines: row.rows("subcontractorLines").map { line in
                VariationSubcontractorLine(
                    id: line.id,
                    subcontractorId: line.text("subcontractorId"),
                    name: line.text("name"),
                    quoteNumber: line.text("quoteNumber"),
                    quantity: line.number("quantity") ?? 1,
                    cost: line.number("cost") ?? 0
                )
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
            isDeleted: row.bool("isDeleted"),
            removedEvidence: row.rows("removedEvidence").map { entry in
                VariationRemovedEvidence(
                    path: entry.text("path"),
                    name: entry.text("name"),
                    removedBy: entry.text("removedBy"),
                    removedAt: entry.date("removedAtMs")
                )
            }
        )
    }

    /// RULEBOOK 1.52.0 §22, review of #235: every new or changed line is shaped by the rulebook; when the script does
    /// not answer for a line the save is refused (`CanonicalWriteUnavailableError`), never a line dropped or written
    /// in another shape.
    static func firestoreMap(from variation: Variation) throws -> [String: Any] {
        var labourRows: [[String: Any]] = []
        for line in variation.labour {
            // An untouched old line, or one built without a crew (`hoursEach` 0), keeps its stored shape and hours.
            if line.legacyShape || line.hoursEach <= 0 {
                labourRows.append(["id": line.id, "trade": line.trade, "hours": line.hours])
                continue
            }
            guard let fields = CanonicalBusinessEngine.variationLabourLineFields(
                id: line.id, trade: line.trade, operatives: line.operatives, hoursEach: line.hoursEach
            ) else { throw CanonicalWriteUnavailableError(function: "variationLabourLineFields") }
            labourRows.append(fields)
        }
        var materialRows: [[String: Any]] = []
        for line in variation.materials {
            guard !line.legacyShape, let value = line.quantityValue else {
                materialRows.append(["id": line.id, "name": line.name, "quantity": line.quantity])
                continue
            }
            guard let fields = CanonicalBusinessEngine.variationMaterialLineFields(
                id: line.id, name: line.name, quantity: value, unit: line.unit.isEmpty ? "no" : line.unit
            ) else { throw CanonicalWriteUnavailableError(function: "variationMaterialLineFields") }
            materialRows.append(fields)
        }
        var customRows: [[String: Any]] = []
        for line in variation.customLines {
            guard let fields = CanonicalBusinessEngine.variationCustomLineFields(
                id: line.id, name: line.name, description: line.description, quantity: line.quantity, cost: line.cost
            ) else { throw CanonicalWriteUnavailableError(function: "variationCustomLineFields") }
            customRows.append(fields)
        }
        var subcontractorRows: [[String: Any]] = []
        for line in variation.subcontractorLines {
            guard let fields = CanonicalBusinessEngine.variationSubcontractorLineFields(
                id: line.id, subcontractorId: line.subcontractorId, name: line.name,
                quoteNumber: line.quoteNumber, quantity: line.quantity, cost: line.cost
            ) else { throw CanonicalWriteUnavailableError(function: "variationSubcontractorLineFields") }
            subcontractorRows.append(fields)
        }
        return firestoreMap(from: variation, labour: labourRows, materials: materialRows, customLines: customRows, subcontractorLines: subcontractorRows)
    }

    private static func firestoreMap(
        from variation: Variation,
        labour labourRows: [[String: Any]],
        materials materialRows: [[String: Any]],
        customLines customRows: [[String: Any]],
        subcontractorLines subcontractorRows: [[String: Any]]
    ) -> [String: Any] {
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
            // RULEBOOK 1.52.0 §22: lines shaped above (an untouched old line exactly as stored).
            "labour": labourRows,
            "materials": materialRows,
            "customLines": customRows,
            "subcontractorLines": subcontractorRows,
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
    /// RULEBOOK 1.63.0: a job with no tracker document (`data` empty) reads as on — the rulebook reader decides; the
    /// job's own parent type is kept for it.
    static func tracker(from data: [String: Any], parentId: String, parentType: VariationParentType = .project) -> VariationTracker {
        guard let row = CanonicalBusinessEngine.parseVariationTrackerDocument(parentId: parentId, data: data) else {
            return .disabled(parentId: parentId, parentType: parentType)
        }
        return VariationTracker(
            parentId: row.text("parentId").isEmpty ? parentId : row.text("parentId"),
            parentType: data["parentType"] == nil ? parentType : (VariationParentType(rawValue: row.text("parentType")) ?? .project),
            enabled: row.bool("enabled"),
            enabledAt: row.date("enabledAtMs"),
            enabledByUid: row.optionalText("enabledByUid"),
            numberingMode: VariationNumberingMode(rawValue: row.text("numberingMode")) ?? .lockSubmitted,
            prefix: row.optionalText("prefix") ?? VariationNumbering.defaultPrefix,
            padding: Int(row.number("padding") ?? Double(VariationNumbering.defaultPadding)),
            version: Int(row.number("version") ?? 0),
            orderLocked: row.bool("orderLocked"),
            orderLockedByName: row.optionalText("orderLockedByName"),
            orderLockedAt: row.date("orderLockedAtMs")
        )
    }
}
