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
    /// Make the catalogue exactly the sheet. RULEBOOK 1.8.0 §1 (`materialCatalogueWrites`): never delete-all and
    /// rewrite — a row matching a current item keeps its Catalogue ID, items missing from the sheet are removed.
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
    /// Changes whenever `items` changes, so search can reuse the script's record list.
    @Published private(set) var searchGeneration = 0

    private weak var firebaseBackend: FirebaseBackend?
    private var searchRecords: [CanonicalBusinessEngine.CanonicalMaterialRecord] = []
    private var searchMemoKey: String?
    private var searchMemo: [MaterialCatalogItem] = []
    /// True when `items` came from a successful catalogue read (not the material-line fallback). A list save may
    /// delete stored items only then (`materialCatalogueWrites` `loaded`).
    private var catalogueLoaded = false

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
            catalogueLoaded = true
            if !normalized.isEmpty {
                replaceItems(normalized)
                return
            }
            // RULEBOOK 1.9.0 §1 "Never re-save what you didn't change": a load (and a listener snapshot) never writes.
            // An empty catalogue shows the items recovered from material lines, for display only; nothing is written
            // until the user saves (`syncWriteAllowed`).
            if SyncWriteGate.allows(.backgroundSync, "material catalogue backfill on load") {
                try? await firebaseBackend.backfillMaterialCatalogueFromExistingMaterials(organizationId: organizationId)
                let refreshed = try await firebaseBackend.loadMaterialCatalogue(organizationId: organizationId)
                replaceItems(refreshed.map(normalizeCategory))
                return
            }
            replaceItems((try? await fallbackItemsFromMaterialLines(firebaseBackend: firebaseBackend, organizationId: organizationId)) ?? [])
        } catch {
            catalogueLoaded = false
            // Fallback: if catalogue read fails or returns nothing, synthesize from existing materials so users can still see items.
            replaceItems((try? await fallbackItemsFromMaterialLines(firebaseBackend: firebaseBackend, organizationId: organizationId)) ?? [])
            if items.isEmpty {
                errorMessage = error.localizedDescription
            }
        }
    }

    /// `mode`: `.create` for a new catalogue item, `.update` for an edit (refused if the item was deleted elsewhere).
    func save(_ item: MaterialCatalogItem, mode: RecordSaveMode) async throws {
        guard let firebaseBackend,
              let organizationId = firebaseBackend.currentOrganization?.firestoreDocumentId else { return }
        try await firebaseBackend.saveMaterialCatalogueItem(item, organizationId: organizationId, mode: mode)
        if let index = items.firstIndex(where: { $0.id == item.id }) {
            items[index] = item
        } else {
            items.append(item)
            items.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        }
        noteCatalogueChanged()
    }

    func delete(_ itemId: UUID) async throws {
        guard let firebaseBackend,
              let organizationId = firebaseBackend.currentOrganization?.firestoreDocumentId else { return }
        try await firebaseBackend.deleteMaterialCatalogueItem(itemId, organizationId: organizationId)
        items.removeAll { $0.id == itemId }
        noteCatalogueChanged()
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

        // RULEBOOK 1.8.0 §1: the catalogue after the import, saved with `materialCatalogueWrites` (partial writes of
        // changed items; removals only after a successful load and never to an empty catalogue).
        var finalById = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })
        for id in plan.idsToDelete { finalById.removeValue(forKey: id) }
        for item in plan.itemsToSave { finalById[item.id] = item }
        let finalItems = Array(finalById.values)
        reportProgress(0, mode == .replaceAll ? "Uploading materials…" : "Saving materials…")
        try await firebaseBackend.writeMaterialCatalogue(
            finalItems,
            loaded: catalogueLoaded,
            organizationId: organizationId
        ) { done in
            reportProgress(min(done, writeTotal), "Saving materials…")
        }

        applyPlanLocally(plan)
        importProgress = MaterialCatalogueImportProgress(completed: writeTotal, total: writeTotal, phase: "Finished")
        return result
    }

    func search(query: String, limit: Int = 0) -> [MaterialCatalogItem] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let cap = limit > 0 ? limit : 0
        let memoKey = "\(searchGeneration)|\(cap)|\(trimmed)"
        if memoKey == searchMemoKey { return searchMemo }
        let hits = CanonicalBusinessEngine.rankMaterialRecords(
            query: trimmed,
            records: searchRecords,
            limit: cap > 0 ? cap : nil,
            cacheIdentity: searchGeneration
        ) ?? []
        let ranked = hits.compactMap { items.indices.contains($0.index) ? items[$0.index] : nil }
        searchMemoKey = memoKey
        searchMemo = ranked
        return ranked
    }

    private func replaceItems(_ next: [MaterialCatalogItem]) {
        items = next
        noteCatalogueChanged()
    }

    private func noteCatalogueChanged() {
        searchGeneration = CanonicalBusinessEngine.makeMaterialSearchCacheIdentity()
        searchRecords = items.map(\.canonicalSearchRecord)
        searchMemoKey = nil
        searchMemo = []
        CanonicalBusinessEngine.installMaterialSearchRecords(searchRecords, cacheIdentity: searchGeneration)
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
            var existingByIdentity: [String: MaterialCatalogItem] = [:]
            for item in existing {
                let key = duplicateKey(name: item.name, code: item.productCode)
                if existingByIdentity[key] == nil { existingByIdentity[key] = item }
            }
            let itemsToSave = uniqueRows.map { row -> MaterialCatalogItem in
                // A row naming a current item keeps its Catalogue ID (lines keep pointing at it); the rest are new.
                let match = existingByIdentity.removeValue(forKey: duplicateKey(name: row.name, code: row.productCode))
                return item(
                    from: row,
                    id: match?.id ?? UUID(),
                    createdAt: match?.createdAt ?? now,
                    createdByUserId: match?.createdByUserId ?? createdByUserId,
                    createdByName: match?.createdByName ?? createdByName
                )
            }
            let keptIds = Set(itemsToSave.map(\.id))
            return ImportPlan(
                itemsToSave: itemsToSave,
                idsToDelete: existing.map(\.id).filter { !keptIds.contains($0) },
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
        replaceItems(map.values.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending })
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
