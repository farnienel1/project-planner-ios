//
//  MaterialCatalogDuplicateDetection.swift
//  Project Planner
//

import Foundation

enum MaterialCatalogDuplicateKind {
    case exactCatalogueMatch(MaterialCatalogItem)
    case batchRowConflict(rowIndex: Int, existing: MaterialCatalogItem)
    case batchRowDuplicate(rowIndexA: Int, rowIndexB: Int)
}

struct MaterialCatalogDuplicateCandidate: Identifiable, Hashable {
    let id: String
    let incomingName: String
    let incomingCode: String
    let existingName: String
    let existingCode: String
    let existingItemId: UUID?
    let batchRowIndex: Int?
    var include: Bool

    init(
        id: String = UUID().uuidString,
        incomingName: String,
        incomingCode: String,
        existingName: String,
        existingCode: String,
        existingItemId: UUID? = nil,
        batchRowIndex: Int? = nil,
        include: Bool = false
    ) {
        self.id = id
        self.incomingName = incomingName
        self.incomingCode = incomingCode
        self.existingName = existingName
        self.existingCode = existingCode
        self.existingItemId = existingItemId
        self.batchRowIndex = batchRowIndex
        self.include = include
    }
}

enum MaterialCatalogDuplicateDetection {
    static func normalizeName(_ raw: String) -> String {
        raw.lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
    }

    static func normalizeCode(_ raw: String?) -> String {
        normalizeName(raw ?? "")
    }

    /// Duplicate when normalised material name and product code both match (manufacturer/brand is ignored).
    static func isDuplicate(
        name: String,
        productCode: String?,
        comparedTo existingName: String,
        existingProductCode: String?
    ) -> Bool {
        let n1 = normalizeName(name)
        let n2 = normalizeName(existingName)
        guard !n1.isEmpty, !n2.isEmpty, n1 == n2 else { return false }
        return normalizeCode(productCode) == normalizeCode(existingProductCode)
    }

    static func findCatalogueMatch(
        name: String,
        productCode: String?,
        in catalogue: [MaterialCatalogItem]
    ) -> MaterialCatalogItem? {
        catalogue.first { item in
            isDuplicate(
                name: name,
                productCode: productCode,
                comparedTo: item.name,
                existingProductCode: item.productCode
            )
        }
    }

    static func buildBatchDuplicateReview(
        incomingRows: [MaterialCatalogCSVRow],
        existingCatalogue: [MaterialCatalogItem]
    ) -> [MaterialCatalogDuplicateCandidate] {
        var results: [MaterialCatalogDuplicateCandidate] = []
        var seenIncoming: [(index: Int, row: MaterialCatalogCSVRow)] = []

        for (index, row) in incomingRows.enumerated() {
            let normalizedIncomingName = normalizeName(row.name)
            if let match = existingCatalogue.first(where: { normalizeName($0.name) == normalizedIncomingName }) {
                results.append(
                    MaterialCatalogDuplicateCandidate(
                        incomingName: row.name,
                        incomingCode: row.productCode ?? "",
                        existingName: match.name,
                        existingCode: match.productCode ?? "",
                        existingItemId: match.id,
                        batchRowIndex: index,
                        include: false
                    )
                )
                continue
            }

            if let prior = seenIncoming.first(where: { prior in
                normalizeName(prior.row.name) == normalizedIncomingName
            }) {
                results.append(
                    MaterialCatalogDuplicateCandidate(
                        incomingName: row.name,
                        incomingCode: row.productCode ?? "",
                        existingName: prior.row.name,
                        existingCode: prior.row.productCode ?? "",
                        batchRowIndex: index,
                        include: false
                    )
                )
            } else {
                seenIncoming.append((index, row))
            }
        }

        return results
    }
}

