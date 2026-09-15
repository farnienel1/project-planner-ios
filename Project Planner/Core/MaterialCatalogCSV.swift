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
    var defaultUnit: MaterialUnit
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
        self.size = size
        self.length = length
        self.lengthUnit = lengthUnit
        self.category = category
    }
}

enum MaterialCatalogCSV {
    static let templateFileName = "material_catalogue_upload_template.csv"
    static let catalogueFileName = "material_catalogue.csv"
    static let maxFileBytes = 5 * 1024 * 1024

    static let headerLine =
        "Catalogue ID,Name,Category,Manufacturer/Brand,Product Code,Default Type (Length Drum Box Pallet or Number),Size,Length,Length Unit (M or MM)"

    static var templateContents: String { headerLine + "\n" }

    static func writeTemplateToTemporaryFile() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(templateFileName)
        try templateContents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    static func writeCatalogueToTemporaryFile(items: [MaterialCatalogItem]) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(catalogueFileName)
        try csvString(for: items).write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    static func csvString(for items: [MaterialCatalogItem]) -> String {
        let sorted = items.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
        var lines = [headerLine]
        for item in sorted {
            let category = item.category?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            lines.append(
                joinCSVFields([
                    item.id.uuidString,
                    item.name,
                    category.isEmpty ? "Other" : category,
                    item.brand,
                    item.productCode ?? "",
                    item.defaultUnit.rawValue,
                    item.size ?? "",
                    item.length ?? "",
                    item.lengthUnit?.rawValue ?? ""
                ])
            )
        }
        return lines.joined(separator: "\n") + "\n"
    }

    static func parse(data: Data) throws -> [MaterialCatalogCSVRow] {
        if data.count > maxFileBytes {
            throw csvError(code: 7, "CSV exceeds the 5MB size limit.")
        }
        guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .utf16) else {
            throw csvError(code: 1, "Could not read the CSV file.")
        }
        return try parse(text: text)
    }

    static func parse(text: String) throws -> [MaterialCatalogCSVRow] {
        var working = text
        if working.hasPrefix("\u{FEFF}") {
            working.removeFirst()
        }
        let lines = working
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        guard let headerLine = lines.first else {
            throw csvError(code: 2, "The CSV file is empty.")
        }

        let headers = splitCSVLine(headerLine).map(normalizeHeader)
        func columnIndex(_ names: [String]) -> Int? {
            for name in names {
                if let idx = headers.firstIndex(of: name) { return idx }
            }
            return nil
        }

        guard let nameIdx = columnIndex(["name"]) else {
            throw csvError(code: 3, "Missing required column: Name")
        }
        guard let categoryIdx = columnIndex(["category"]) else {
            throw csvError(code: 6, "Missing required column: Category")
        }
        let catalogueIdIdx = columnIndex(["catalogue id", "catalog id", "catalogueid", "id"])
        let brandIdx = columnIndex(["manufacturer/brand", "manufacturer", "brand"])
        let codeIdx = columnIndex(["product code", "code"])
        let unitIdx = columnIndex([
            "default type (length drum box pallet or number)",
            "default type (length drum box or number)",
            "default unit (length, box or number)",
            "default unit",
            "unit",
            "type"
        ])
        let sizeIdx = columnIndex(["size", "size/length", "pack size", "packsize"])
        let lengthIdx = columnIndex(["length"])
        let lengthUnitIdx = columnIndex(["length unit (m or mm)", "length unit"])

        var rows: [MaterialCatalogCSVRow] = []
        for line in lines.dropFirst() {
            let cols = splitCSVLine(line)
            guard nameIdx < cols.count else { continue }
            let name = cols[nameIdx].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { continue }

            let catalogueId: UUID? = {
                guard let catalogueIdIdx, catalogueIdIdx < cols.count else { return nil }
                let raw = cols[catalogueIdIdx].trimmingCharacters(in: .whitespacesAndNewlines)
                guard !raw.isEmpty else { return nil }
                return UUID(uuidString: raw)
            }()

            let brand: String
            if let brandIdx, brandIdx < cols.count {
                brand = cols[brandIdx].trimmingCharacters(in: .whitespacesAndNewlines)
            } else {
                brand = ""
            }

            let code: String?
            if let codeIdx, codeIdx < cols.count {
                let c = cols[codeIdx].trimmingCharacters(in: .whitespacesAndNewlines)
                code = c.isEmpty ? nil : c
            } else {
                code = nil
            }

            let unitRaw = (unitIdx.flatMap { $0 < cols.count ? cols[$0] : nil }) ?? "Number"
            let unit = parseUnit(unitRaw)

            let size: String? = {
                let value = sizeIdx.flatMap { $0 < cols.count ? cols[$0] : nil }?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                return value.isEmpty ? nil : value
            }()

            let length: String? = {
                let primary = lengthIdx.flatMap { $0 < cols.count ? cols[$0] : nil }?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if !primary.isEmpty { return primary }
                let fallbackLegacy = sizeIdx.flatMap { $0 < cols.count ? cols[$0] : nil }?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                return fallbackLegacy.isEmpty ? nil : fallbackLegacy
            }()

            let lengthUnit: MaterialLengthUnit? = {
                let raw = lengthUnitIdx.flatMap { $0 < cols.count ? cols[$0] : nil }?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                return MaterialLengthSpecification.parseUnit(from: raw)
            }()

            let category: String
            if categoryIdx < cols.count {
                let c = cols[categoryIdx].trimmingCharacters(in: .whitespacesAndNewlines)
                category = c.isEmpty ? "Other" : c
            } else {
                category = "Other"
            }

            rows.append(
                MaterialCatalogCSVRow(
                    catalogueId: catalogueId,
                    name: name,
                    brand: brand.isEmpty ? "Unknown" : brand,
                    productCode: code,
                    defaultUnit: unit,
                    size: size,
                    length: length,
                    lengthUnit: lengthUnit,
                    category: category
                )
            )
        }

        guard !rows.isEmpty else {
            throw csvError(code: 4, "No material rows found in the CSV.")
        }
        if rows.count > 5000 {
            throw csvError(code: 5, "CSV exceeds the 5,000 item limit.")
        }
        return rows
    }

    private static func parseUnit(_ raw: String) -> MaterialUnit {
        switch raw.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) {
        case "box": return .box
        case "length": return .length
        case "drum", "drums": return .drum
        case "pallet", "pallets": return .pallet
        default: return .number
        }
    }

    private static func normalizeHeader(_ raw: String) -> String {
        raw.lowercased()
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func csvError(code: Int, _ message: String) -> NSError {
        NSError(domain: "MaterialCatalogCSV", code: code, userInfo: [NSLocalizedDescriptionKey: message])
    }

    static func joinCSVFields(_ fields: [String]) -> String {
        fields.map(escapeCSVField).joined(separator: ",")
    }

    static func escapeCSVField(_ field: String) -> String {
        let needsQuotes = field.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r" })
            || UUID(uuidString: field) != nil
        if needsQuotes {
            return "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        return field
    }

    static func splitCSVLine(_ line: String) -> [String] {
        var result: [String] = []
        var current = ""
        var inQuotes = false
        var index = line.startIndex
        while index < line.endIndex {
            let char = line[index]
            if inQuotes {
                if char == "\"" {
                    let next = line.index(after: index)
                    if next < line.endIndex, line[next] == "\"" {
                        current.append("\"")
                        index = next
                    } else {
                        inQuotes = false
                    }
                } else {
                    current.append(char)
                }
            } else if char == "\"" {
                inQuotes = true
            } else if char == "," {
                result.append(current)
                current = ""
            } else {
                current.append(char)
            }
            index = line.index(after: index)
        }
        result.append(current)
        return result.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
    }
}
