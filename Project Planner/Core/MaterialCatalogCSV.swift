//
//  MaterialCatalogCSV.swift
//  Project Planner
//

import Foundation

struct MaterialCatalogCSVRow: Identifiable, Hashable {
    let id = UUID()
    var name: String
    var brand: String
    var productCode: String?
    var defaultUnit: MaterialUnit
    var size: String?
    var length: String?
    var lengthUnit: MaterialLengthUnit?
    var category: String?
}

enum MaterialCatalogCSV {
    static let templateFileName = "material_catalogue_upload_template.csv"

    static let templateContents = """
Name,Category,Manufacturer/Brand,Product Code,Default Type (Length Drum Box Pallet or Number),Size,Length,Length Unit (M or MM)

"""

    static func writeTemplateToTemporaryFile() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(templateFileName)
        try templateContents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    static func parse(data: Data) throws -> [MaterialCatalogCSVRow] {
        guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .utf16) else {
            throw NSError(domain: "MaterialCatalogCSV", code: 1, userInfo: [NSLocalizedDescriptionKey: "Could not read the CSV file."])
        }
        return try parse(text: text)
    }

    static func parse(text: String) throws -> [MaterialCatalogCSVRow] {
        let lines = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        guard let headerLine = lines.first else {
            throw NSError(domain: "MaterialCatalogCSV", code: 2, userInfo: [NSLocalizedDescriptionKey: "The CSV file is empty."])
        }

        let headers = splitCSVLine(headerLine).map { $0.lowercased() }
        func columnIndex(_ names: [String]) -> Int? {
            for name in names {
                if let idx = headers.firstIndex(of: name) { return idx }
            }
            return nil
        }

        guard let nameIdx = columnIndex(["name"]) else {
            throw NSError(domain: "MaterialCatalogCSV", code: 3, userInfo: [NSLocalizedDescriptionKey: "Missing required column: Name"])
        }
        let categoryIdx = columnIndex(["category"])
        let brandIdx = columnIndex(["manufacturer/brand", "manufacturer", "brand"])
        let codeIdx = columnIndex(["product code", "code"])
        let unitIdx = columnIndex([
            "default type (length drum box or number)",
            "default unit (length, box or number)",
            "default unit",
            "unit",
            "type"
        ])
        let sizeIdx = columnIndex(["size", "size/length", "pack size", "packsize"])
        let lengthIdx = columnIndex(["length"])
        let lengthUnitIdx = columnIndex(["length unit (m or mm)", "length unit"])
        guard let categoryIdx else {
            throw NSError(domain: "MaterialCatalogCSV", code: 6, userInfo: [NSLocalizedDescriptionKey: "Missing required column: Category"])
        }

        var rows: [MaterialCatalogCSVRow] = []
        for line in lines.dropFirst() {
            let cols = splitCSVLine(line)
            guard nameIdx < cols.count else { continue }
            let name = cols[nameIdx].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { continue }

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
            throw NSError(domain: "MaterialCatalogCSV", code: 4, userInfo: [NSLocalizedDescriptionKey: "No material rows found in the CSV."])
        }
        if rows.count > 5000 {
            throw NSError(domain: "MaterialCatalogCSV", code: 5, userInfo: [NSLocalizedDescriptionKey: "CSV exceeds the 5,000 item limit."])
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

    private static func splitCSVLine(_ line: String) -> [String] {
        var result: [String] = []
        var current = ""
        var inQuotes = false
        for char in line {
            if char == "\"" {
                inQuotes.toggle()
                continue
            }
            if char == "," && !inQuotes {
                result.append(current)
                current = ""
            } else {
                current.append(char)
            }
        }
        result.append(current)
        return result.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
    }
}
