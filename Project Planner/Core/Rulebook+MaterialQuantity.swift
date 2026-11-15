//
//  Rulebook+MaterialQuantity.swift
//  Project Planner
//
//  RULEBOOK 1.48.0 §28 (owner decisions 15 Nov 1–5): one quantity model for materials — the quantity, the order unit
//  (`MATERIAL_ORDER_UNITS`) and optionally what is in one (`contentAmount` + `contentMeasure`) — one wording
//  (`materialLineText`: "2no 50m drums", "100m", "4no") and one catalogue CSV rule (`parseMaterialCatalogueCsv`,
//  `materialCatalogueCsvExport`, the upload checks). Typed wrappers for web `lib/canonical/materialQuantity.ts` and
//  `materialCatalogueCsv.ts`. Swift formats and parses nothing itself (AGENTS.md Rule 0).
//

import Foundation

/// RULEBOOK 1.48.0 `MATERIAL_ORDER_UNIT_DETAILS[unit]`.
nonisolated struct MaterialOrderUnitDetail: Codable, Hashable, Sendable {
    let label: String
    let singular: String
    let plural: String
    let hint: String
    /// The measures "What's in one" offers (`m`, `mm`, `pcs`); empty for Metre.
    let measures: [String]
    /// Only Metre takes decimals (owner decision 3).
    let decimalQuantity: Bool
    let legacyUnit: String
}

/// RULEBOOK 1.48.0 `materialQuantityModel(data)`: the order unit and what is in one, read from the new fields or, for a
/// line stored before 1.48.0 (or one an older build edited), from the old ones.
nonisolated struct MaterialQuantityModel: Hashable, Sendable {
    var orderUnit: String
    var contentAmount: Double?
    var contentMeasure: String?
}

/// RULEBOOK 1.48.0 `parseMaterialCatalogueCsv` row.
nonisolated struct MaterialCatalogueCsvRow: Hashable, Sendable {
    let id: String
    let name: String
    let category: String
    let brand: String
    let productCode: String
    let orderUnit: String
    let contentAmount: Double?
    let contentMeasure: String?
    let size: String
    let rowNumber: Int
}

/// RULEBOOK 1.48.0 `parseMaterialCatalogueCsv(text)` → `{ rows, errors ("Row N: …"), duplicateRows }`.
nonisolated struct MaterialCatalogueCsvParse: Hashable, Sendable {
    let rows: [MaterialCatalogueCsvRow]
    let errors: [String]
    let duplicateRows: [Int]
}

extension CanonicalBusinessEngine {
    // MARK: Units

    /// `MATERIAL_ORDER_UNITS`: Each, Box, Pack, Drum, Reel, Coil, Pallet, Length, Metre.
    nonisolated static var materialOrderUnits: [String] { materialOrderUnitsConstant }
    private nonisolated static let materialOrderUnitsConstant: [String] =
        constant("MATERIAL_ORDER_UNITS", as: [String].self) ?? []

    /// `MATERIAL_ORDER_UNIT_DETAILS`: label, hint, measures and whether the quantity may have decimals, per unit. Read
    /// once (a constant of the packed script).
    nonisolated static var materialOrderUnitDetails: [String: MaterialOrderUnitDetail] { materialOrderUnitDetailsConstant }
    private nonisolated static let materialOrderUnitDetailsConstant: [String: MaterialOrderUnitDetail] =
        constant("MATERIAL_ORDER_UNIT_DETAILS", as: [String: MaterialOrderUnitDetail].self) ?? [:]

    /// `normalizeMaterialOrderUnit(raw)`: the order unit from any spelling, or nil.
    nonisolated static func normalizeMaterialOrderUnit(_ raw: String?) -> String? {
        callJSON("normalizeMaterialOrderUnit", arguments: [RulebookJSON.orNull(raw)]) as? String
    }

    private nonisolated static func number(_ value: Any?) -> Double? {
        (value as? NSNumber)?.doubleValue
    }

    /// `materialQuantityModel(data)` for any stored or in-app shape (line, catalogue item, send line, email line). Nil
    /// when the script did not answer.
    nonisolated static func materialQuantityModel(_ data: [String: Any]) -> MaterialQuantityModel? {
        guard let row = callJSON("materialQuantityModel", arguments: [data]) as? [String: Any],
              let orderUnit = row["orderUnit"] as? String else { return nil }
        return MaterialQuantityModel(
            orderUnit: orderUnit,
            contentAmount: number(row["contentAmount"]),
            contentMeasure: row["contentMeasure"] as? String
        )
    }

    // MARK: Wording

    /// `materialLineText(line)`: "2no 50m drums", "10no 3m lengths", "100m", "12.5m", "4no". The quantity alone when the
    /// script did not answer (display only).
    nonisolated static func materialLineText(_ line: [String: Any]) -> String {
        if let text = callJSON("materialLineText", arguments: [line]) as? String { return text }
        return (line["quantity"] as? NSNumber).map { "\($0)" } ?? ""
    }

    /// `materialLineText` for the quantity model.
    nonisolated static func materialLineText(
        quantity: Double,
        orderUnit: String?,
        contentAmount: Double?,
        contentMeasure: String?,
        legacy: [String: Any] = [:]
    ) -> String {
        var line = legacy
        line["quantity"] = quantity
        if let orderUnit, !orderUnit.isEmpty {
            line["orderUnit"] = orderUnit
            line["contentAmount"] = RulebookJSON.orNull(contentAmount)
            line["contentMeasure"] = RulebookJSON.orNull(contentMeasure)
        }
        return materialLineText(line)
    }

    /// `materialSendLineText(line)`: a past send line's stored `quantityText`, else its pre-1.48.0 wording. A past record
    /// is never re-rendered.
    nonisolated static func materialSendLineText(quantityText: String?, quantity: Double, unit: String, lengthDisplay: String?) -> String {
        let line: [String: Any] = [
            "quantityText": RulebookJSON.orNull(quantityText),
            "quantity": quantity,
            "unit": unit,
            "lengthDisplay": RulebookJSON.orNull(lengthDisplay),
        ]
        if let text = callJSON("materialSendLineText", arguments: [line]) as? String { return text }
        return quantityText ?? "\(quantity)"
    }

    /// `materialContentText({ contentAmount, contentMeasure })`: "50m", "150mm", "100pcs"; '' when nothing.
    nonisolated static func materialContentText(amount: Double?, measure: String?) -> String {
        let model: [String: Any] = ["contentAmount": RulebookJSON.orNull(amount), "contentMeasure": RulebookJSON.orNull(measure)]
        return callJSON("materialContentText", arguments: [model]) as? String ?? ""
    }

    /// `materialSizeText(size)`: '' for the "1" / "1.0" placeholder (display only).
    nonisolated static func materialSizeText(_ size: String?) -> String {
        callJSON("materialSizeText", arguments: [RulebookJSON.orNull(size)]) as? String ?? (size ?? "")
    }

    /// The catalogue row line "Drum · 50m in one" (`MATERIAL_ORDER_UNIT_DETAILS[...].label` + `materialContentText`).
    nonisolated static func materialCatalogueUnitSummary(orderUnit: String, contentAmount: Double?, contentMeasure: String?) -> String {
        let label = materialOrderUnitDetails[orderUnit]?.label ?? orderUnit
        let content = materialContentText(amount: contentAmount, measure: contentMeasure)
        return content.isEmpty ? label : "\(label) · \(content) in one"
    }

    // MARK: Checks (only when the quantity, the unit or what is in one changed)

    /// `materialQuantityError(quantity, orderUnit)`: why a typed quantity cannot be saved, or nil.
    nonisolated static func materialQuantityError(quantity: Any?, orderUnit: String) -> String? {
        let answer = callJSON("materialQuantityError", arguments: [RulebookJSON.orNull(quantity), orderUnit])
        if answer is NSNull { return nil }
        return answer as? String ?? "The materials rules did not load. Try again."
    }

    /// `materialContentError(amount, measure, orderUnit)`: why "What's in one" cannot be saved, or nil (blank is fine).
    nonisolated static func materialContentError(amount: String, measure: String?, orderUnit: String) -> String? {
        let answer = callJSON("materialContentError", arguments: [amount, RulebookJSON.orNull(measure), orderUnit])
        if answer is NSNull { return nil }
        return answer as? String ?? "The materials rules did not load. Try again."
    }

    // MARK: Catalogue CSV (upload safety, owner request)

    /// `MATERIAL_CATALOGUE_CSV_ENCODING_MESSAGE`: the file is not UTF-8.
    nonisolated static var materialCatalogueCsvEncodingMessage: String {
        constant("MATERIAL_CATALOGUE_CSV_ENCODING_MESSAGE", as: String.self)
            ?? "That file is not saved as UTF-8 text. In your spreadsheet choose \"CSV UTF-8\" when you save it."
    }

    /// `MATERIAL_CATALOGUE_CSV_BINARY_MESSAGE`: the file holds a NUL byte.
    nonisolated static var materialCatalogueCsvBinaryMessage: String {
        constant("MATERIAL_CATALOGUE_CSV_BINARY_MESSAGE", as: String.self)
            ?? "That file is not a plain-text CSV (it holds binary data). Open it in a spreadsheet and save it as CSV (UTF-8)."
    }

    /// `MATERIAL_CATALOGUE_CSV_HEADER`: the export and template header (new columns, then the old ones).
    nonisolated static var materialCatalogueCsvHeader: String {
        constant("MATERIAL_CATALOGUE_CSV_HEADER", as: String.self) ?? ""
    }

    /// `materialCatalogueCsvFileError({ fileName, byteLength })`: .csv only, 2 MB at most. Nil when fine; a refusal
    /// when the script did not answer (nothing is read then).
    nonisolated static func materialCatalogueCsvFileError(fileName: String, byteLength: Int) -> String? {
        let answer = callJSON("materialCatalogueCsvFileError", arguments: [["fileName": fileName, "byteLength": byteLength]])
        if answer is NSNull { return nil }
        return answer as? String ?? "The catalogue rules did not load. Try again."
    }

    /// `materialCatalogueCsvTextError(text)`: empty, too many rows, a missing header. Nil when fine.
    nonisolated static func materialCatalogueCsvTextError(_ text: String) -> String? {
        let answer = callJSON("materialCatalogueCsvTextError", arguments: [text])
        if answer is NSNull { return nil }
        return answer as? String ?? "The catalogue rules did not load. Try again."
    }

    /// `parseMaterialCatalogueCsv(text)`. Nil when the script did not answer.
    nonisolated static func parseMaterialCatalogueCsv(_ text: String) -> MaterialCatalogueCsvParse? {
        guard let result = callJSON("parseMaterialCatalogueCsv", arguments: [text]) as? [String: Any] else { return nil }
        let rows: [MaterialCatalogueCsvRow] = (result["rows"] as? [[String: Any]] ?? []).compactMap { row in
            guard let name = row["name"] as? String else { return nil }
            return MaterialCatalogueCsvRow(
                id: row["id"] as? String ?? "",
                name: name,
                category: row["category"] as? String ?? "",
                brand: row["brand"] as? String ?? "",
                productCode: row["productCode"] as? String ?? "",
                orderUnit: row["orderUnit"] as? String ?? "Each",
                contentAmount: number(row["contentAmount"]),
                contentMeasure: row["contentMeasure"] as? String,
                size: row["size"] as? String ?? "",
                rowNumber: (row["rowNumber"] as? NSNumber)?.intValue ?? 0
            )
        }
        return MaterialCatalogueCsvParse(
            rows: rows,
            errors: result["errors"] as? [String] ?? [],
            duplicateRows: (result["duplicateRows"] as? [NSNumber] ?? []).map(\.intValue)
        )
    }

    /// `materialCatalogueCsvExport(items)`: the whole file (header, cells with the formula guard, old + new columns).
    /// Nil when the script did not answer.
    nonisolated static func materialCatalogueCsvExport(_ items: [[String: Any]]) -> String? {
        callJSON("materialCatalogueCsvExport", arguments: [items]) as? String
    }
}

// MARK: - Model helpers (mapping only)

extension MaterialItem {
    /// The order unit as the rulebook reads this line: the stored one, else worked out from the old fields.
    var effectiveQuantityModel: MaterialQuantityModel {
        if let orderUnit, !orderUnit.isEmpty {
            return MaterialQuantityModel(orderUnit: orderUnit, contentAmount: contentAmount, contentMeasure: contentMeasure)
        }
        return CanonicalBusinessEngine.materialQuantityModel(legacyQuantityFields)
            ?? MaterialQuantityModel(orderUnit: "Each", contentAmount: nil, contentMeasure: nil)
    }

    /// The pre-1.48.0 fields, as stored.
    var legacyQuantityFields: [String: Any] {
        [
            "unit": unit.rawValue,
            "length": RulebookJSON.orNull(length),
            "lengthUnit": RulebookJSON.orNull(lengthUnit?.rawValue),
        ]
    }

    /// RULEBOOK 1.48.0 `materialLineText`: "2no 50m drums", "100m", "4no".
    var quantityText: String {
        let model = effectiveQuantityModel
        return CanonicalBusinessEngine.materialLineText(
            quantity: quantity,
            orderUnit: model.orderUnit,
            contentAmount: model.contentAmount,
            contentMeasure: model.contentMeasure
        )
    }
}

extension MaterialCatalogItem {
    var effectiveQuantityModel: MaterialQuantityModel {
        if let orderUnit, !orderUnit.isEmpty {
            return MaterialQuantityModel(orderUnit: orderUnit, contentAmount: contentAmount, contentMeasure: contentMeasure)
        }
        let legacy: [String: Any] = [
            "defaultUnit": defaultUnit.rawValue,
            "length": RulebookJSON.orNull(length),
            "lengthUnit": RulebookJSON.orNull(lengthUnit?.rawValue),
        ]
        return CanonicalBusinessEngine.materialQuantityModel(legacy)
            ?? MaterialQuantityModel(orderUnit: "Each", contentAmount: nil, contentMeasure: nil)
    }

    /// "Drum · 50m in one".
    var orderUnitSummary: String {
        let model = effectiveQuantityModel
        return CanonicalBusinessEngine.materialCatalogueUnitSummary(
            orderUnit: model.orderUnit, contentAmount: model.contentAmount, contentMeasure: model.contentMeasure
        )
    }

    /// The Size as shown (`materialSizeText`: the "1.0" placeholder hidden).
    var sizeDisplay: String {
        CanonicalBusinessEngine.materialSizeText(size)
    }
}

extension MaterialSendLineSnapshot {
    /// RULEBOOK 1.48.0 `materialSendLineText`: the text the line was sent with, never re-rendered.
    var historyText: String {
        CanonicalBusinessEngine.materialSendLineText(
            quantityText: quantityText, quantity: quantity, unit: unit.rawValue, lengthDisplay: lengthDisplay
        )
    }
}

extension CanonicalBusinessEngine {
    /// `formatMaterialAmount(value)`: "2.4", "50", "12.5" (no trailing zeros, no float noise).
    nonisolated static func formatMaterialAmount(_ value: Double) -> String {
        callJSON("formatMaterialAmount", arguments: [value]) as? String ?? "\(value)"
    }
}

/// RULEBOOK 1.48.0: what the quantity inputs hold while a person edits a line or a catalogue item (text, so a half-typed
/// "12." is kept). The checks and the wording are the rulebook's.
struct MaterialQuantityDraft: Equatable {
    var quantityText: String
    var orderUnit: String
    var contentAmountText: String
    var contentMeasure: String?

    init(quantity: Double, model: MaterialQuantityModel) {
        quantityText = CanonicalBusinessEngine.formatMaterialAmount(quantity)
        orderUnit = model.orderUnit
        contentAmountText = model.contentAmount.map { CanonicalBusinessEngine.formatMaterialAmount($0) } ?? ""
        contentMeasure = model.contentMeasure
    }

    /// A new line: 1 Each, nothing in one.
    static var newLine: MaterialQuantityDraft {
        MaterialQuantityDraft(quantity: 1, model: MaterialQuantityModel(orderUnit: "Each", contentAmount: nil, contentMeasure: nil))
    }

    private static func parse(_ text: String) -> Double? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: ",", with: ".")
        guard !trimmed.isEmpty else { return nil }
        return Double(trimmed)
    }

    /// The typed quantity, or nil when it is not a number.
    var quantity: Double? { Self.parse(quantityText) }

    /// The measures the order unit offers (`MATERIAL_ORDER_UNIT_DETAILS[unit].measures`).
    var measures: [String] { CanonicalBusinessEngine.materialOrderUnitDetails[orderUnit]?.measures ?? [] }

    /// The quantity model to save: what is in one only when the unit offers a measure and a number above 0 is typed.
    var model: MaterialQuantityModel {
        let amount = Self.parse(contentAmountText)
        let measure = contentMeasure ?? measures.first
        guard let amount, amount > 0, let measure, measures.contains(measure) else {
            return MaterialQuantityModel(orderUnit: orderUnit, contentAmount: nil, contentMeasure: nil)
        }
        return MaterialQuantityModel(orderUnit: orderUnit, contentAmount: amount, contentMeasure: measure)
    }

    /// After the order unit changes: keep the measure only when the new unit offers it; Metre has nothing in one.
    mutating func fitMeasureToUnit() {
        let offered = measures
        if offered.isEmpty {
            contentAmountText = ""
            contentMeasure = nil
        } else if let measure = contentMeasure, !offered.contains(measure) {
            contentMeasure = offered.first
        } else if contentMeasure == nil {
            contentMeasure = offered.first
        }
    }

    private func sameQuantity(as other: MaterialQuantityDraft) -> Bool {
        quantity == other.quantity && model == other.model
    }

    /// Why the inputs cannot be saved (`materialQuantityError`, then `materialContentError`), or nil. Checked only when
    /// the quantity, the unit or what is in one changed from `original`, so an older line (2.5 boxes) still saves a
    /// notes change.
    func validationError(comparedWith original: MaterialQuantityDraft?) -> String? {
        if let original, sameQuantity(as: original) { return nil }
        let typed: Any = quantity.map { $0 as Any } ?? quantityText
        if let error = CanonicalBusinessEngine.materialQuantityError(quantity: typed, orderUnit: orderUnit) {
            return error
        }
        return CanonicalBusinessEngine.materialContentError(
            amount: contentAmountText.trimmingCharacters(in: .whitespacesAndNewlines),
            measure: contentMeasure ?? measures.first,
            orderUnit: orderUnit
        )
    }

    /// Writes the quantity and the model onto a line (the old fields are written by the rulebook writer).
    func apply(to item: inout MaterialItem) {
        if let quantity { item.quantity = quantity }
        let model = self.model
        item.orderUnit = model.orderUnit
        item.contentAmount = model.contentAmount
        item.contentMeasure = model.contentMeasure
    }

    /// Writes the default model onto a catalogue item.
    func apply(to item: inout MaterialCatalogItem) {
        let model = self.model
        item.orderUnit = model.orderUnit
        item.contentAmount = model.contentAmount
        item.contentMeasure = model.contentMeasure
    }
}
