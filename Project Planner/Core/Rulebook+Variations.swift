//
//  Rulebook+Variations.swift
//  Project Planner
//
//  RULEBOOK 1.52.0 §22 (owner decisions 15 Nov; web `lib/canonical/variations.ts`): variation line shapes (labour crew,
//  numeric material quantity with its unit, custom and subcontractor lines), their checks, line totals and a
//  variation's totals, who sees costs, the list text (labour, quantity, dates, previous numbers), the workbook rows,
//  the tracker's renumber plan (pinned rows, the locked order) and the evidence link write. Every answer comes from the
//  packed script through `CanonicalBusinessEngine.callJSON`; Swift only renders it.
//

import Foundation

/// `variationTotals` / `variationListTotals` (`count` only on a list).
nonisolated struct RulebookVariationTotals: Hashable, Sendable {
    var labourHours: Double
    var materialsCount: Int
    var customCount: Int
    var subcontractorCount: Int
    var customTotal: Double
    var subcontractorTotal: Double
    var costTotal: Double
    var evidenceCount: Int
    var count: Int

    static let zero = RulebookVariationTotals(
        labourHours: 0, materialsCount: 0, customCount: 0, subcontractorCount: 0,
        customTotal: 0, subcontractorTotal: 0, costTotal: 0, evidenceCount: 0, count: 0
    )

    init(labourHours: Double, materialsCount: Int, customCount: Int, subcontractorCount: Int,
         customTotal: Double, subcontractorTotal: Double, costTotal: Double, evidenceCount: Int, count: Int) {
        self.labourHours = labourHours
        self.materialsCount = materialsCount
        self.customCount = customCount
        self.subcontractorCount = subcontractorCount
        self.customTotal = customTotal
        self.subcontractorTotal = subcontractorTotal
        self.costTotal = costTotal
        self.evidenceCount = evidenceCount
        self.count = count
    }

    init?(_ value: Any?) {
        guard let row = value as? [String: Any] else { return nil }
        func num(_ key: String) -> Double { (row[key] as? NSNumber)?.doubleValue ?? 0 }
        labourHours = num("labourHours")
        materialsCount = Int(num("materialsCount"))
        customCount = Int(num("customCount"))
        subcontractorCount = Int(num("subcontractorCount"))
        customTotal = num("customTotal")
        subcontractorTotal = num("subcontractorTotal")
        costTotal = num("costTotal")
        evidenceCount = Int(num("evidenceCount"))
        count = Int(num("count"))
    }
}

/// One cell of the variations workbook: a number, a text or empty.
nonisolated enum RulebookVariationExportCell: Hashable, Sendable {
    case number(Double)
    case text(String)
    case empty

    init(_ value: Any?) {
        if let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() {
            self = .number(number.doubleValue)
        } else if let text = value as? String {
            self = text.isEmpty ? .empty : .text(text)
        } else {
            self = .empty
        }
    }
}

/// `variationExportRows(...)`: the columns (key, label) and the rows of both sheets, keyed by column key.
nonisolated struct RulebookVariationExport: Sendable {
    let currency: String
    let includeCost: Bool
    let summaryColumns: [(key: String, label: String)]
    let lineColumns: [(key: String, label: String)]
    let summaryRows: [[String: RulebookVariationExportCell]]
    let summaryTotals: [String: RulebookVariationExportCell]
    let lineRows: [[String: RulebookVariationExportCell]]
    /// `VARIATION_EXPORT_COST_KEYS`: the money columns (drawn in the currency; left out when costs are hidden).
    let costKeys: Set<String>
}

/// One row of `variationRenumberPlan(...).rows`.
nonisolated struct RulebookVariationPlanRow: Hashable, Sendable {
    let id: String
    let from: String
    let to: String
    let changed: Bool
    let pinned: Bool
    let sequence: Int
}

/// `variationEvidenceAddWriteFields(stored, entries)`.
nonisolated struct RulebookVariationEvidenceAdd {
    /// `{ evidence, evidenceCount }` (script JSON) to write, or nil when nothing is added.
    let set: [String: Any]?
    let added: [String]
    let alreadyLinked: [String]
    let refused: [String]
}

extension CanonicalBusinessEngine {
    // MARK: - Line shapes

    /// `variationLabourLineFields({ id, trade, operatives, hoursEach })` → `{ id, trade, hours, operatives, hoursEach }`.
    nonisolated static func variationLabourLineFields(id: String, trade: String, operatives: Int, hoursEach: Double) -> [String: Any]? {
        callJSON("variationLabourLineFields", arguments: [["id": id, "trade": trade, "operatives": operatives, "hoursEach": hoursEach]]) as? [String: Any]
    }

    /// `variationMaterialLineFields({ id, name, quantity, unit })` → `{ id, name, quantity, quantityValue, unit }`.
    nonisolated static func variationMaterialLineFields(id: String, name: String, quantity: Double, unit: String) -> [String: Any]? {
        callJSON("variationMaterialLineFields", arguments: [["id": id, "name": name, "quantity": quantity, "unit": unit]]) as? [String: Any]
    }

    /// `variationCustomLineFields({ id, name, description, quantity, cost })`.
    nonisolated static func variationCustomLineFields(id: String, name: String, description: String, quantity: Double, cost: Double) -> [String: Any]? {
        callJSON("variationCustomLineFields", arguments: [[
            "id": id, "name": name, "description": description, "quantity": quantity, "cost": cost,
        ]]) as? [String: Any]
    }

    /// `variationSubcontractorLineFields({ id, subcontractorId, name, quoteNumber, quantity, cost })`.
    nonisolated static func variationSubcontractorLineFields(
        id: String, subcontractorId: String, name: String, quoteNumber: String, quantity: Double, cost: Double
    ) -> [String: Any]? {
        callJSON("variationSubcontractorLineFields", arguments: [[
            "id": id, "subcontractorId": subcontractorId, "name": name, "quoteNumber": quoteNumber,
            "quantity": quantity, "cost": cost,
        ]]) as? [String: Any]
    }

    // MARK: - Checks

    /// `variationMaterialQuantityError(value)`: `VARIATION_QUANTITY_MESSAGE`, or nil when the quantity is fine.
    /// The typed text is passed as typed (a "2,5" reads as 2.5 in the rule).
    nonisolated static func variationMaterialQuantityError(_ value: String) -> String? {
        callJSON("variationMaterialQuantityError", arguments: [value]) as? String
    }

    /// `variationCustomLineError({ name, quantity, cost })`.
    nonisolated static func variationCustomLineError(name: String, quantity: String, cost: String) -> String? {
        callJSON("variationCustomLineError", arguments: [["name": name, "quantity": quantity, "cost": cost]]) as? String
    }

    /// `variationSubcontractorLineError({ name, quantity, cost })`.
    nonisolated static func variationSubcontractorLineError(name: String, quantity: String, cost: String) -> String? {
        callJSON("variationSubcontractorLineError", arguments: [["name": name, "quantity": quantity, "cost": cost]]) as? String
    }

    /// `VARIATION_MATERIAL_UNITS` (`no`, `m`, `box`, `kg`).
    nonisolated static var variationMaterialUnits: [String] {
        constant("VARIATION_MATERIAL_UNITS", as: [String].self) ?? []
    }

    /// `VARIATION_ORDER_LOCKED_MESSAGE`.
    nonisolated static var variationOrderLockedMessage: String {
        constant("VARIATION_ORDER_LOCKED_MESSAGE", as: String.self) ?? ""
    }

    // MARK: - Figures and text

    /// `variationLineTotal({ quantity, cost })`: quantity (missing or 0 → 1) × cost, rounded to pennies.
    nonisolated static func variationLineTotal(quantity: String, cost: String) -> Double? {
        (callJSON("variationLineTotal", arguments: [["quantity": quantity, "cost": cost]]) as? NSNumber)?.doubleValue
    }

    /// `variationTotals(variation)`.
    nonisolated static func variationTotals(_ variation: [String: Any]) -> RulebookVariationTotals? {
        RulebookVariationTotals(callJSON("variationTotals", arguments: [variation]))
    }

    /// `variationListTotals(variations)` (deleted ones left out).
    nonisolated static func variationListTotals(_ variations: [[String: Any]]) -> RulebookVariationTotals? {
        RulebookVariationTotals(callJSON("variationListTotals", arguments: [variations]))
    }

    /// `canSeeVariationCosts(role)`: admins, super admins and managers; never operative mode.
    nonisolated static func canSeeVariationCosts(_ role: CanonicalStaffAccountRole) -> Bool {
        let input: [String: Any] = [
            "isSuperAdmin": role.isSuperAdmin, "isAdmin": role.isAdmin,
            "isManager": role.isManager, "isOperativeMode": role.isOperativeMode,
        ]
        return (callJSON("canSeeVariationCosts", arguments: [input]) as? Bool) ?? false
    }

    /// `variationLabourText({ operatives, hoursEach, hours })` — "2 × 4h = 8h", or "8h".
    nonisolated static func variationLabourText(operatives: Int, hoursEach: Double, hours: Double) -> String? {
        callJSON("variationLabourText", arguments: [["operatives": operatives, "hoursEach": hoursEach, "hours": hours]]) as? String
    }

    /// `variationMaterialQuantityText(value, unit)` — "100m", "9".
    nonisolated static func variationMaterialQuantityText(_ value: Double, unit: String) -> String? {
        callJSON("variationMaterialQuantityText", arguments: [value, unit]) as? String
    }

    /// `variationDateText(ms, timeZone)` — "15 Nov 2026" in the organisation zone.
    nonisolated static func variationDateText(_ date: Date?, timeZone: String) -> String {
        guard let date else { return "" }
        return (callJSON("variationDateText", arguments: [date.timeIntervalSince1970 * 1000, timeZone]) as? String) ?? ""
    }

    /// `variationPreviousNumbers({ voNumber, numberHistory })` — the numbers it had before, oldest first.
    nonisolated static func variationPreviousNumbers(voNumber: String, history: [String]) -> [String] {
        let input: [String: Any] = ["voNumber": voNumber, "numberHistory": history.map { ["from": $0] }]
        return (callJSON("variationPreviousNumbers", arguments: [input]) as? [Any])?.compactMap { $0 as? String } ?? []
    }

    // MARK: - Workbook

    /// `variationExportRows(variations, { timeZone, currency, includeCost })`. Nil when the script did not answer.
    nonisolated static func variationExportRows(
        _ variations: [[String: Any]],
        timeZone: String,
        currency: String,
        includeCost: Bool
    ) -> RulebookVariationExport? {
        let options: [String: Any] = ["timeZone": timeZone, "currency": currency, "includeCost": includeCost]
        guard let result = callJSON("variationExportRows", arguments: [variations, options]) as? [String: Any] else { return nil }
        func columns(_ key: String) -> [(key: String, label: String)] {
            ((result[key] as? [Any]) ?? []).compactMap { entry in
                guard let row = entry as? [String: Any], let key = row["key"] as? String else { return nil }
                return (key: key, label: row["label"] as? String ?? key)
            }
        }
        func cells(_ value: Any?) -> [String: RulebookVariationExportCell] {
            var out: [String: RulebookVariationExportCell] = [:]
            for (key, cell) in (value as? [String: Any]) ?? [:] { out[key] = RulebookVariationExportCell(cell) }
            return out
        }
        let costKeys = constant("VARIATION_EXPORT_COST_KEYS", as: [String].self) ?? []
        return RulebookVariationExport(
            currency: result["currency"] as? String ?? currency,
            includeCost: (result["includeCost"] as? Bool) ?? includeCost,
            summaryColumns: columns("summaryColumns"),
            lineColumns: columns("lineColumns"),
            summaryRows: ((result["summaryRows"] as? [Any]) ?? []).map(cells),
            summaryTotals: cells(result["summaryTotals"]),
            lineRows: ((result["lineRows"] as? [Any]) ?? []).map(cells),
            costKeys: Set(costKeys)
        )
    }

    /// `variationExportFileName(jobNumber)` — "{job number}-variations.xlsx".
    nonisolated static func variationExportFileName(jobNumber: String) -> String {
        (callJSON("variationExportFileName", arguments: [jobNumber]) as? String) ?? "variations.xlsx"
    }

    // MARK: - Tracker

    /// `variationRenumberPlan({ rows, order, prefix, padding, orderLocked })`: the tracker's order and numbers, pinned
    /// rows in their places. `refused` is `VARIATION_ORDER_LOCKED_MESSAGE` when the order is locked.
    nonisolated static func variationRenumberPlan(
        rows: [[String: Any]],
        order: [String] = [],
        prefix: String,
        padding: Int,
        orderLocked: Bool
    ) -> (rows: [RulebookVariationPlanRow], refused: String?)? {
        let input: [String: Any] = ["rows": rows, "order": order, "prefix": prefix, "padding": padding, "orderLocked": orderLocked]
        guard let result = callJSON("variationRenumberPlan", arguments: [input]) as? [String: Any] else { return nil }
        let planRows: [RulebookVariationPlanRow] = ((result["rows"] as? [Any]) ?? []).compactMap { entry in
            guard let row = CanonicalDocumentRow(entry) else { return nil }
            return RulebookVariationPlanRow(
                id: row.id,
                from: row.text("from"),
                to: row.text("to"),
                changed: row.bool("changed"),
                pinned: row.bool("pinned"),
                sequence: Int(row.number("sequence") ?? 0)
            )
        }
        return (planRows, result["refused"] as? String)
    }

    /// RULEBOOK 1.63.0 §22 `variationStatusWriteFields(stored, status)`: the number lock written with a status change —
    /// Submitted and Closed lock it, Open unlocks it in the same write (a reopened variation is unpinned). Falls back to
    /// the same rule when the script does not answer.
    nonisolated static func variationStatusLocksNumber(status: String, storedLocked: Bool) -> Bool {
        let result = callJSON("variationStatusWriteFields", arguments: [["voNumberLocked": storedLocked], status]) as? [String: Any]
        if let locked = result?["voNumberLocked"] as? Bool { return locked }
        return status == "submitted" || status == "closed"
    }

    /// `variationIsPinned(row)`: Submitted and Closed keep their place and number (1.63.0: the status decides; a lock
    /// left on a reopened Open variation no longer pins it).
    nonisolated static func variationIsPinned(status: String, voNumberLocked: Bool) -> Bool {
        (callJSON("variationIsPinned", arguments: [["status": status, "voNumberLocked": voNumberLocked]]) as? Bool) ?? false
    }

    // MARK: - Evidence

    /// `variationEvidenceKeys(stored)`: the storage paths (else ids) of the evidence on a stored variation.
    nonisolated static func variationEvidenceKeys(stored: [String: Any]?) -> [String]? {
        (callJSON("variationEvidenceKeys", arguments: [peopleDocumentJSON(stored ?? [:])]) as? [Any])?.compactMap { $0 as? String }
    }

    /// `variationEvidenceAddWriteFields(stored, entries)`. Entries are script JSON (no Timestamps: `uploadedAt` in ms is
    /// replaced by the caller's native value before writing).
    nonisolated static func variationEvidenceAddWriteFields(stored: [String: Any]?, entries: [[String: Any]]) -> RulebookVariationEvidenceAdd? {
        guard let result = callJSON("variationEvidenceAddWriteFields", arguments: [peopleDocumentJSON(stored ?? [:]), entries]) as? [String: Any] else {
            return nil
        }
        func strings(_ key: String) -> [String] { ((result[key] as? [Any]) ?? []).compactMap { $0 as? String } }
        return RulebookVariationEvidenceAdd(
            set: result["set"] as? [String: Any],
            added: strings("added"),
            alreadyLinked: strings("alreadyLinked"),
            refused: strings("refused")
        )
    }
}
