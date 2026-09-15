//
//  MaterialCatalogStore.swift
//  Project Planner
//

import Foundation
import Combine
import FirebaseAuth

enum MaterialCatalogueCSVImportMode: Equatable {
    /// Add new rows, update matching rows, and remove catalogue items missing from the sheet.
    case updateExisting
    /// Erase the current catalogue, then import every row as a new item (new Catalogue IDs).
    case replaceAll
}

struct MaterialCatalogueImportProgress: Equatable {
    var completed: Int
    var total: Int
    var phase: String

    var fraction: Double {
        guard total > 0 else { return 0 }
        return min(1, Double(completed) / Double(total))
    }
}

struct MaterialCatalogueCSVImportResult: Equatable {
    var added: Int
    var updated: Int
    var removed: Int
    var skippedDuplicates: Int

    var totalTouched: Int { added + updated + removed }
}

@MainActor
final class MaterialCatalogStore: ObservableObject {
    @Published private(set) var items: [MaterialCatalogItem] = []
    @Published private(set) var isLoading = false
    @Published var errorMessage: String?
    @Published private(set) var importProgress: MaterialCatalogueImportProgress?

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
            let catalog = try await firebaseBackend.loadMaterialCatalogue(organizationId: organizationId)
            let normalized = catalog.map(normalizeCategory)
            if !normalized.isEmpty {
                items = normalized
                return
            }
            // Bootstrap once for orgs with historical material lines but empty catalogue.
            try? await firebaseBackend.backfillMaterialCatalogueFromExistingMaterials(organizationId: organizationId)
            let refreshed = try await firebaseBackend.loadMaterialCatalogue(organizationId: organizationId)
            items = refreshed.map(normalizeCategory)
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

    func importCSV(
        _ rows: [MaterialCatalogCSVRow],
        mode: MaterialCatalogueCSVImportMode,
        createdByUserId: String,
        createdByName: String
    ) async throws -> MaterialCatalogueCSVImportResult {
        guard let firebaseBackend,
              let organizationId = firebaseBackend.currentOrganization?.firestoreDocumentId else {
            throw NSError(
                domain: "MaterialCatalogStore",
                code: 400,
                userInfo: [NSLocalizedDescriptionKey: "Organization ID is missing. Open Settings → Force Reload Data, then retry."]
            )
        }

        importProgress = MaterialCatalogueImportProgress(completed: 0, total: 1, phase: "Preparing catalogue…")
        defer { importProgress = nil }

        let plan = makeImportPlan(
            rows: rows,
            existing: items,
            mode: mode,
            createdByUserId: createdByUserId,
            createdByName: createdByName
        )
        let writeTotal = plan.itemsToSave.count + plan.idsToDelete.count
        let result = MaterialCatalogueCSVImportResult(
            added: plan.added,
            updated: plan.updated,
            removed: plan.idsToDelete.count,
            skippedDuplicates: plan.skippedDuplicates
        )

        if writeTotal == 0 {
            importProgress = MaterialCatalogueImportProgress(completed: 1, total: 1, phase: "Catalogue is already up to date")
            return result
        }

        let reportProgress: (Int, String) -> Void = { [weak self] completed, phase in
            self?.importProgress = MaterialCatalogueImportProgress(
                completed: completed,
                total: writeTotal,
                phase: phase
            )
        }

        switch mode {
        case .updateExisting:
            reportProgress(0, "Saving materials…")
            try await firebaseBackend.saveMaterialCatalogueItems(plan.itemsToSave, organizationId: organizationId) { saved in
                reportProgress(saved, "Saving materials…")
            }
            reportProgress(plan.itemsToSave.count, "Removing materials…")
            try await firebaseBackend.deleteMaterialCatalogueItems(plan.idsToDelete, organizationId: organizationId) { deleted in
                reportProgress(plan.itemsToSave.count + deleted, "Removing materials…")
            }
        case .replaceAll:
            reportProgress(0, "Removing current catalogue…")
            try await firebaseBackend.deleteMaterialCatalogueItems(plan.idsToDelete, organizationId: organizationId) { deleted in
                reportProgress(deleted, "Removing current catalogue…")
            }
            reportProgress(plan.idsToDelete.count, "Uploading materials…")
            try await firebaseBackend.saveMaterialCatalogueItems(plan.itemsToSave, organizationId: organizationId) { saved in
                reportProgress(plan.idsToDelete.count + saved, "Uploading materials…")
            }
        }

        applyPlanLocally(plan)
        importProgress = MaterialCatalogueImportProgress(completed: writeTotal, total: writeTotal, phase: "Finished")
        return result
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
        MaterialCatalogDuplicateDetection.identityKey(name: name, productCode: code)
    }

    var brandCount: Int {
        Set(items.map { MaterialCatalogDuplicateDetection.normalizeName($0.brand) }.filter { !$0.isEmpty }).count
    }

    var categoryCount: Int {
        Set(items.compactMap { $0.category?.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }).count
    }

    private struct ImportPlan {
        var itemsToSave: [MaterialCatalogItem]
        var idsToDelete: [UUID]
        var added: Int
        var updated: Int
        var skippedDuplicates: Int
    }

    private func makeImportPlan(
        rows: [MaterialCatalogCSVRow],
        existing: [MaterialCatalogItem],
        mode: MaterialCatalogueCSVImportMode,
        createdByUserId: String,
        createdByName: String
    ) -> ImportPlan {
        var seenFileIds = Set<UUID>()
        var seenFileIdentities = Set<String>()
        var uniqueRows: [MaterialCatalogCSVRow] = []
        var skippedDuplicates = 0

        for row in rows {
            if mode == .updateExisting, let catalogueId = row.catalogueId {
                if seenFileIds.contains(catalogueId) {
                    skippedDuplicates += 1
                    continue
                }
                seenFileIds.insert(catalogueId)
            }
            let identity = duplicateKey(name: row.name, code: row.productCode)
            if seenFileIdentities.contains(identity) {
                skippedDuplicates += 1
                continue
            }
            seenFileIdentities.insert(identity)
            uniqueRows.append(row)
        }

        switch mode {
        case .replaceAll:
            let now = Date()
            let itemsToSave = uniqueRows.map { row in
                item(
                    from: row,
                    id: UUID(),
                    createdAt: now,
                    createdByUserId: createdByUserId,
                    createdByName: createdByName
                )
            }
            return ImportPlan(
                itemsToSave: itemsToSave,
                idsToDelete: existing.map(\.id),
                added: itemsToSave.count,
                updated: 0,
                skippedDuplicates: skippedDuplicates
            )

        case .updateExisting:
            var existingById = Dictionary(uniqueKeysWithValues: existing.map { ($0.id, $0) })
            var existingByIdentity: [String: MaterialCatalogItem] = [:]
            for item in existing {
                let key = duplicateKey(name: item.name, code: item.productCode)
                if existingByIdentity[key] == nil {
                    existingByIdentity[key] = item
                }
            }

            var itemsToSave: [MaterialCatalogItem] = []
            var added = 0
            var updated = 0
            var keptIds = Set<UUID>()

            for row in uniqueRows {
                let identity = duplicateKey(name: row.name, code: row.productCode)
                let match: MaterialCatalogItem?
                if let catalogueId = row.catalogueId, let existingItem = existingById[catalogueId] {
                    match = existingItem
                } else if let existingItem = existingByIdentity[identity] {
                    match = existingItem
                } else {
                    match = nil
                }

                if let match {
                    existingById.removeValue(forKey: match.id)
                    existingByIdentity.removeValue(forKey: duplicateKey(name: match.name, code: match.productCode))
                    let updatedItem = item(
                        from: row,
                        id: match.id,
                        createdAt: match.createdAt,
                        createdByUserId: match.createdByUserId,
                        createdByName: match.createdByName
                    )
                    keptIds.insert(match.id)
                    if hasCatalogueFieldChanges(updatedItem, match) {
                        itemsToSave.append(updatedItem)
                        updated += 1
                    }
                } else {
                    let newId = row.catalogueId ?? UUID()
                    let newItem = item(
                        from: row,
                        id: newId,
                        createdAt: Date(),
                        createdByUserId: createdByUserId,
                        createdByName: createdByName
                    )
                    itemsToSave.append(newItem)
                    keptIds.insert(newItem.id)
                    added += 1
                }
            }

            let idsToDelete = existing.map(\.id).filter { !keptIds.contains($0) }
            return ImportPlan(
                itemsToSave: itemsToSave,
                idsToDelete: idsToDelete,
                added: added,
                updated: updated,
                skippedDuplicates: skippedDuplicates
            )
        }
    }

    private func applyPlanLocally(_ plan: ImportPlan) {
        var map = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })
        for id in plan.idsToDelete {
            map.removeValue(forKey: id)
        }
        for item in plan.itemsToSave {
            map[item.id] = normalizeCategory(item)
        }
        items = map.values.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private func item(
        from row: MaterialCatalogCSVRow,
        id: UUID,
        createdAt: Date,
        createdByUserId: String,
        createdByName: String
    ) -> MaterialCatalogItem {
        MaterialCatalogItem(
            id: id,
            name: row.name,
            brand: row.brand,
            productCode: row.productCode,
            defaultUnit: row.defaultUnit,
            size: row.size,
            length: row.length,
            lengthUnit: row.lengthUnit,
            category: normalizedCategory(row.category),
            createdAt: createdAt,
            createdByUserId: createdByUserId,
            createdByName: createdByName
        )
    }

    private func hasCatalogueFieldChanges(_ lhs: MaterialCatalogItem, _ rhs: MaterialCatalogItem) -> Bool {
        lhs.name != rhs.name
            || lhs.brand != rhs.brand
            || normalizedOptional(lhs.productCode) != normalizedOptional(rhs.productCode)
            || lhs.defaultUnit != rhs.defaultUnit
            || normalizedOptional(lhs.size) != normalizedOptional(rhs.size)
            || normalizedOptional(lhs.length) != normalizedOptional(rhs.length)
            || lhs.lengthUnit != rhs.lengthUnit
            || normalizedCategory(lhs.category) != normalizedCategory(rhs.category)
    }

    private func normalizedOptional(_ value: String?) -> String {
        value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
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
                size: line.size,
                length: line.length ?? line.sizeOrLength,
                lengthUnit: line.lengthUnit,
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
