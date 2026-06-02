//
//  OfflineMaterialLocalStore.swift
//  Project Planner
//
//  Local overlay for materials created/edited while offline.
//

import Foundation

@MainActor
final class OfflineMaterialLocalStore {
    static let shared = OfflineMaterialLocalStore()

    private let storageKeyPrefix = "offline_materials_overlay_v1"
    private let deletedKeyPrefix = "offline_materials_deleted_v1"
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    private init() {}

    // MARK: - Write overlay

    func upsert(_ material: MaterialItem, organizationId: String) {
        var items = loadOverlay(organizationId: organizationId, projectId: material.projectId)
        if let index = items.firstIndex(where: { $0.id == material.id }) {
            items[index] = material
        } else {
            items.append(material)
        }
        saveOverlay(items, organizationId: organizationId, projectId: material.projectId)
    }

    func markPendingDelete(materialId: UUID, projectId: UUID, organizationId: String) {
        var overlay = loadOverlay(organizationId: organizationId, projectId: projectId)
        overlay.removeAll { $0.id == materialId }
        saveOverlay(overlay, organizationId: organizationId, projectId: projectId)

        var deleted = loadDeletedIds(organizationId: organizationId, projectId: projectId)
        deleted.insert(materialId)
        saveDeletedIds(deleted, organizationId: organizationId, projectId: projectId)
    }

    func markSynced(materialId: UUID, projectId: UUID) {
        guard let orgId = cachedOrganizationId() else { return }
        var overlay = loadOverlay(organizationId: orgId, projectId: projectId)
        overlay.removeAll { $0.id == materialId }
        saveOverlay(overlay, organizationId: orgId, projectId: projectId)
    }

    func markDeletedSynced(materialId: UUID) {
        guard let orgId = cachedOrganizationId() else { return }
        for projectKey in allProjectKeys(organizationId: orgId) {
            var deleted = loadDeletedIds(organizationId: orgId, projectId: projectKey)
            deleted.remove(materialId)
            saveDeletedIds(deleted, organizationId: orgId, projectId: projectKey)
        }
    }

    // MARK: - Read merge

    func mergedMaterials(
        organizationId: String,
        projectId: UUID,
        remote: [MaterialItem]
    ) -> [MaterialItem] {
        let overlay = loadOverlay(organizationId: organizationId, projectId: projectId)
        let pendingDeletes = loadDeletedIds(organizationId: organizationId, projectId: projectId)

        var byId: [UUID: MaterialItem] = [:]
        for item in remote where !pendingDeletes.contains(item.id) {
            byId[item.id] = item
        }
        for item in overlay where !pendingDeletes.contains(item.id) {
            byId[item.id] = item
        }
        return byId.values.sorted { lhs, rhs in
            if lhs.date != rhs.date { return lhs.date < rhs.date }
            return lhs.material.localizedCaseInsensitiveCompare(rhs.material) == .orderedAscending
        }
    }

    func hasPendingChanges(for projectId: UUID, organizationId: String) -> Bool {
        !loadOverlay(organizationId: organizationId, projectId: projectId).isEmpty
            || !loadDeletedIds(organizationId: organizationId, projectId: projectId).isEmpty
    }

    // MARK: - Storage keys

    private func overlayKey(organizationId: String, projectId: UUID) -> String {
        "\(storageKeyPrefix)_\(organizationId)_\(projectId.uuidString)"
    }

    private func deletedKey(organizationId: String, projectId: UUID) -> String {
        "\(deletedKeyPrefix)_\(organizationId)_\(projectId.uuidString)"
    }

    private func loadOverlay(organizationId: String, projectId: UUID) -> [MaterialItem] {
        guard let data = UserDefaults.standard.data(forKey: overlayKey(organizationId: organizationId, projectId: projectId)),
              let items = try? decoder.decode([MaterialItem].self, from: data) else {
            return []
        }
        return items
    }

    private func saveOverlay(_ items: [MaterialItem], organizationId: String, projectId: UUID) {
        guard let data = try? encoder.encode(items) else { return }
        UserDefaults.standard.set(data, forKey: overlayKey(organizationId: organizationId, projectId: projectId))
    }

    private func loadDeletedIds(organizationId: String, projectId: UUID) -> Set<UUID> {
        guard let data = UserDefaults.standard.data(forKey: deletedKey(organizationId: organizationId, projectId: projectId)),
              let ids = try? decoder.decode([UUID].self, from: data) else {
            return []
        }
        return Set(ids)
    }

    private func saveDeletedIds(_ ids: Set<UUID>, organizationId: String, projectId: UUID) {
        guard let data = try? encoder.encode(Array(ids)) else { return }
        UserDefaults.standard.set(data, forKey: deletedKey(organizationId: organizationId, projectId: projectId))
    }

    private func cachedOrganizationId() -> String? {
        UserDefaults.standard.string(forKey: "cached_organizationId")
    }

    private func allProjectKeys(organizationId: String) -> [UUID] {
        let prefix = "\(deletedKeyPrefix)_\(organizationId)_"
        return UserDefaults.standard.dictionaryRepresentation().keys.compactMap { key -> UUID? in
            guard key.hasPrefix(prefix) else { return nil }
            let suffix = key.dropFirst(prefix.count)
            return UUID(uuidString: String(suffix))
        }
    }
}
