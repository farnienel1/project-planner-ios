//
//  MaterialCatalogStore.swift
//  Project Planner
//

import Foundation
import Combine
import FirebaseAuth

@MainActor
final class MaterialCatalogStore: ObservableObject {
    @Published private(set) var items: [MaterialCatalogItem] = []
    @Published private(set) var isLoading = false
    @Published var errorMessage: String?

    private weak var firebaseBackend: FirebaseBackend?

    func setFirebaseBackend(_ backend: FirebaseBackend) {
        firebaseBackend = backend
    }

    func load() async {
        guard let firebaseBackend,
              let organizationId = firebaseBackend.currentOrganization?.firestoreDocumentId else { return }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            try? await firebaseBackend.backfillMaterialCatalogueFromExistingMaterials(organizationId: organizationId)
        }
        do {
            let catalog = try await firebaseBackend.loadMaterialCatalogue(organizationId: organizationId)
            let normalized = catalog.map(normalizeCategory)
            if normalized.isEmpty {
                items = (try? await fallbackItemsFromMaterialLines(firebaseBackend: firebaseBackend, organizationId: organizationId)) ?? []
            } else {
                items = normalized
            }
        } catch {
            // Fallback: if catalogue read fails or returns nothing, synthesize from existing materials so users can still see items.
            items = (try? await fallbackItemsFromMaterialLines(firebaseBackend: firebaseBackend, organizationId: organizationId)) ?? []
            if items.isEmpty {
                errorMessage = error.localizedDescription
            }
        }
    }

    func save(_ item: MaterialCatalogItem) async throws {
        guard let firebaseBackend,
              let organizationId = firebaseBackend.currentOrganization?.firestoreDocumentId else { return }
        try await firebaseBackend.saveMaterialCatalogueItem(item, organizationId: organizationId)
        if let index = items.firstIndex(where: { $0.id == item.id }) {
            items[index] = item
        } else {
            items.append(item)
            items.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        }
    }

    func delete(_ itemId: UUID) async throws {
        guard let firebaseBackend,
              let organizationId = firebaseBackend.currentOrganization?.firestoreDocumentId else { return }
        try await firebaseBackend.deleteMaterialCatalogueItem(itemId, organizationId: organizationId)
        items.removeAll { $0.id == itemId }
    }

    func importRows(
        _ rows: [MaterialCatalogCSVRow],
        createdByUserId: String,
        createdByName: String,
        skipDuplicateKeys: Set<String>,
        forceImportKeys: Set<String> = []
    ) async throws -> Int {
        var imported = 0
        for row in rows {
            let key = duplicateKey(name: row.name, code: row.productCode)
            if skipDuplicateKeys.contains(key) { continue }
            if !forceImportKeys.contains(key),
               items.contains(where: {
                   MaterialCatalogDuplicateDetection.normalizeName($0.name)
                    == MaterialCatalogDuplicateDetection.normalizeName(row.name)
               }) {
                continue
            }
            let item = MaterialCatalogItem(
                name: row.name,
                brand: row.brand,
                productCode: row.productCode,
                defaultUnit: row.defaultUnit,
                sizeOrLength: row.sizeOrLength,
                category: normalizedCategory(row.category),
                createdByUserId: createdByUserId,
                createdByName: createdByName
            )
            try await save(item)
            imported += 1
        }
        return imported
    }

    func search(query: String, limit: Int = 12) -> [MaterialCatalogItem] {
        let q = MaterialCatalogDuplicateDetection.normalizeName(query)
        guard !q.isEmpty else { return [] }
        return items.filter { item in
            MaterialCatalogDuplicateDetection.normalizeName(item.name).contains(q)
                || MaterialCatalogDuplicateDetection.normalizeName(item.brand).contains(q)
                || MaterialCatalogDuplicateDetection.normalizeCode(item.productCode).contains(q)
                || MaterialCatalogDuplicateDetection.normalizeName(item.sizeOrLength ?? "").contains(q)
        }
        .prefix(limit)
        .map { $0 }
    }

    func duplicateKey(name: String, code: String?) -> String {
        "\(MaterialCatalogDuplicateDetection.normalizeName(name))|\(MaterialCatalogDuplicateDetection.normalizeCode(code))"
    }

    var brandCount: Int {
        Set(items.map { MaterialCatalogDuplicateDetection.normalizeName($0.brand) }.filter { !$0.isEmpty }).count
    }

    var categoryCount: Int {
        Set(items.compactMap { $0.category?.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }).count
    }

    private func normalizedCategory(_ value: String?) -> String {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? "Other" : trimmed
    }

    private func normalizeCategory(_ item: MaterialCatalogItem) -> MaterialCatalogItem {
        var normalized = item
        normalized.category = normalizedCategory(normalized.category)
        return normalized
    }

    private func fallbackItemsFromMaterialLines(firebaseBackend: FirebaseBackend, organizationId: String) async throws -> [MaterialCatalogItem] {
        let lines = try await firebaseBackend.loadAllMaterialItemsForOrganization(organizationId: organizationId)
        var byName: [String: MaterialCatalogItem] = [:]
        let creatorName = firebaseBackend.currentUser?.displayName ?? firebaseBackend.currentUser?.email ?? "Unknown"
        let creatorId = firebaseBackend.currentUser?.uid ?? "unknown"

        for line in lines {
            let name = line.material.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { continue }
            let key = MaterialCatalogDuplicateDetection.normalizeName(name)
            if byName[key] != nil { continue }
            let brand = line.brand?.trimmingCharacters(in: .whitespacesAndNewlines)
            let category = normalizedCategory(line.category)
            byName[key] = MaterialCatalogItem(
                name: name,
                brand: (brand?.isEmpty == false) ? brand! : "Custom",
                productCode: line.productCode,
                defaultUnit: line.unit,
                sizeOrLength: line.sizeOrLength,
                category: category,
                createdByUserId: creatorId,
                createdByName: creatorName
            )
        }
        return byName.values.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    func countAddedToday(calendar: Calendar = .current) -> Int {
        let today = calendar.startOfDay(for: Date())
        return items.filter { calendar.isDate($0.createdAt, inSameDayAs: today) }.count
    }
}
