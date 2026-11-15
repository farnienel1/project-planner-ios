//
//  MaterialCatalogCSV.swift
//  Project Planner
//

import Foundation

struct MaterialCatalogCSVRow: Identifiable, Hashable {
    let id: UUID
    /// Stable catalogue identity from the sheet. Nil when the row is new or the ID is blank/invalid.
    var catalogueId: UUID?
    var name: String
    var brand: String
    var productCode: String?
    /// The pre-1.48.0 default unit (`MATERIAL_ORDER_UNIT_DETAILS[orderUnit].legacyUnit`).
    var defaultUnit: MaterialUnit
    /// RULEBOOK 1.48.0: the order unit and what is in one (`parseMaterialCatalogueCsv`; a filled Order unit wins over
    /// the old columns).
    var orderUnit: String?
    var contentAmount: Double?
    var contentMeasure: String?
    var size: String?
    var length: String?
    var lengthUnit: MaterialLengthUnit?
    var category: String?

    init(
        id: UUID = UUID(),
        catalogueId: UUID? = nil,
        name: String,
        brand: String,
        productCode: String? = nil,
        defaultUnit: MaterialUnit,
        orderUnit: String? = nil,
        contentAmount: Double? = nil,
        contentMeasure: String? = nil,
        size: String? = nil,
        length: String? = nil,
        lengthUnit: MaterialLengthUnit? = nil,
        category: String? = nil
    ) {
        self.id = id
        self.catalogueId = catalogueId
        self.name = name
        self.brand = brand
        self.productCode = productCode
        self.defaultUnit = defaultUnit
        self.orderUnit = orderUnit
        self.contentAmount = contentAmount
        self.contentMeasure = contentMeasure
        self.size = size
        self.length = length
        self.lengthUnit = lengthUnit
        self.category = category
    }
}

enum MaterialCatalogCSV {
    static let templateFileName = "material_catalogue_upload_template.csv"
    static let catalogueFileName = "material_catalogue.csv"

    /// RULEBOOK 1.48.0 `MATERIAL_CATALOGUE_CSV_HEADER`: Catalogue ID, Name, Category, Manufacturer/Brand, Product Code,
    /// Order unit, Contents amount, Contents measure, Size, then the old Default Type, Length, Length Unit.
    static var headerLine: String { CanonicalBusinessEngine.materialCatalogueCsvHeader }

    static var templateContents: String { headerLine + "\n" }

    static func writeTemplateToTemporaryFile() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(templateFileName)
        try templateContents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    static func writeCatalogueToTemporaryFile(items: [MaterialCatalogItem]) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(catalogueFileName)
        guard let text = csvString(for: items) else { throw csvError(code: 8, "The catalogue rules did not load. Try again.") }
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// RULEBOOK 1.48.0 `materialCatalogueCsvExport(items)`: every cell from the rulebook (the formula apostrophe
    /// included), new and old columns. Sorted by name as before. Nil when the script did not answer.
    static func csvString(for items: [MaterialCatalogItem]) -> String? {
        let sorted = items.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
        let rows: [[String: Any]] = sorted.map { item in
            // The model with the old columns that go with it (`materialQuantityWriteFields`), never a stale old field.
            var row = item.quantityFieldsForScript
            row["id"] = WorkDocumentKeys.storedId(for: item.id)
            row["name"] = item.name
            row["category"] = RulebookJSON.orNull(item.category)
            row["brand"] = item.brand
            row["productCode"] = RulebookJSON.orNull(item.productCode)
            row["size"] = RulebookJSON.orNull(item.size)
            return row
        }
        return CanonicalBusinessEngine.materialCatalogueCsvExport(rows)
    }

    /// The rows a file holds and the rows the rulebook refused ("Row N: …"), shown before the rest are imported.
    struct ParseResult {
        var rows: [MaterialCatalogCSVRow]
        var errors: [String]
    }

    /// RULEBOOK 1.48.0 upload safety (owner request), in this order: `.csv` only and 2 MB at most
    /// (`materialCatalogueCsvFileError`); UTF-8 only (no UTF-16 fallback, `MATERIAL_CATALOGUE_CSV_ENCODING_MESSAGE`);
    /// no NUL byte (`MATERIAL_CATALOGUE_CSV_BINARY_MESSAGE`); then `materialCatalogueCsvTextError` and
    /// `parseMaterialCatalogueCsv`. Read on the device only; the file is never uploaded.
    static func parse(data: Data, fileName: String) throws -> ParseResult {
        if let message = CanonicalBusinessEngine.materialCatalogueCsvFileError(fileName: fileName, byteLength: data.count) {
            throw csvError(code: 7, message)
        }
        if data.contains(0) {
            throw csvError(code: 9, CanonicalBusinessEngine.materialCatalogueCsvBinaryMessage)
        }
        guard let text = String(data: data, encoding: .utf8) else {
            throw csvError(code: 1, CanonicalBusinessEngine.materialCatalogueCsvEncodingMessage)
        }
        return try parse(text: text)
    }

    static func parse(text: String) throws -> ParseResult {
        if let message = CanonicalBusinessEngine.materialCatalogueCsvTextError(text) {
            throw csvError(code: 2, message)
        }
        guard let parsed = CanonicalBusinessEngine.parseMaterialCatalogueCsv(text) else {
            throw csvError(code: 8, "The catalogue rules did not load. Try again.")
        }
        let details = CanonicalBusinessEngine.materialOrderUnitDetails
        let rows = parsed.rows.map { row -> MaterialCatalogCSVRow in
            let id = row.id.trimmingCharacters(in: .whitespacesAndNewlines)
            let legacyUnit = details[row.orderUnit].flatMap { MaterialUnit(rawValue: $0.legacyUnit) } ?? .number
            return MaterialCatalogCSVRow(
                catalogueId: id.isEmpty ? nil : UUID(uuidString: id),
                name: row.name,
                brand: row.brand.isEmpty ? "Custom" : row.brand,
                productCode: row.productCode.isEmpty ? nil : row.productCode,
                defaultUnit: legacyUnit,
                orderUnit: row.orderUnit,
                contentAmount: row.contentAmount,
                contentMeasure: row.contentMeasure,
                size: row.size.isEmpty ? nil : row.size,
                category: row.category.isEmpty ? "Other" : row.category
            )
        }
        if rows.isEmpty && parsed.errors.isEmpty {
            throw csvError(code: 4, "No material rows found in the CSV.")
        }
        return ParseResult(rows: rows, errors: parsed.errors)
    }

    nonisolated private static func csvError(code: Int, _ message: String) -> NSError {
        NSError(domain: "MaterialCatalogCSV", code: code, userInfo: [NSLocalizedDescriptionKey: message])
    }

}
