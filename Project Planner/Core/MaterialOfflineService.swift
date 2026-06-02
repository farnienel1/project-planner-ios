//
//  MaterialOfflineService.swift
//  Project Planner
//
//  Offline-aware save/delete/send for materials.
//

import Foundation

enum MaterialOfflineSaveResult {
    case syncedImmediately
    case queuedForSync
}

@MainActor
enum MaterialOfflineService {

    static func resolvedOrganizationId(firebaseBackend: FirebaseBackend) -> String? {
        firebaseBackend.resolvedOrganizationIdForOfflineWrites()
    }

    static func mergedMaterials(
        organizationId: String,
        projectId: UUID,
        remote: [MaterialItem]
    ) -> [MaterialItem] {
        OfflineMaterialLocalStore.shared.mergedMaterials(
            organizationId: organizationId,
            projectId: projectId,
            remote: remote
        )
    }

    static func saveMaterial(
        _ material: MaterialItem,
        organizationId: String,
        firebaseBackend: FirebaseBackend,
        isOnline: Bool
    ) async throws -> MaterialOfflineSaveResult {
        OfflineMaterialLocalStore.shared.upsert(material, organizationId: organizationId)

        if !isOnline {
            OfflineOutboxStore.shared.enqueueSaveMaterialItem(material, organizationId: organizationId)
            return .queuedForSync
        }

        do {
            try await firebaseBackend.saveMaterialItem(material, organizationId: organizationId)
            OfflineMaterialLocalStore.shared.markSynced(materialId: material.id, projectId: material.projectId)
            return .syncedImmediately
        } catch where OfflineWriteSupport.shouldQueue(error: error, isOnline: isOnline) {
            OfflineOutboxStore.shared.enqueueSaveMaterialItem(material, organizationId: organizationId)
            return .queuedForSync
        }
    }

    static func deleteMaterial(
        _ materialId: UUID,
        projectId: UUID,
        organizationId: String,
        firebaseBackend: FirebaseBackend,
        isOnline: Bool
    ) async throws -> MaterialOfflineSaveResult {
        OfflineMaterialLocalStore.shared.markPendingDelete(
            materialId: materialId,
            projectId: projectId,
            organizationId: organizationId
        )

        if !isOnline {
            OfflineOutboxStore.shared.enqueueDeleteMaterialItem(materialId, organizationId: organizationId)
            return .queuedForSync
        }

        do {
            try await firebaseBackend.deleteMaterialItem(materialId, organizationId: organizationId)
            OfflineMaterialLocalStore.shared.markDeletedSynced(materialId: materialId)
            return .syncedImmediately
        } catch where OfflineWriteSupport.shouldQueue(error: error, isOnline: isOnline) {
            OfflineOutboxStore.shared.enqueueDeleteMaterialItem(materialId, organizationId: organizationId)
            return .queuedForSync
        }
    }

    static func sendMaterialRequest(
        _ request: MaterialOrderRequest,
        sendRecord: MaterialSendRecord?,
        organizationId: String,
        firebaseBackend: FirebaseBackend,
        isOnline: Bool
    ) async throws -> MaterialOfflineSaveResult {
        if !isOnline {
            OfflineOutboxStore.shared.enqueueSendMaterialRequest(
                request,
                sendRecord: sendRecord,
                organizationId: organizationId
            )
            return .queuedForSync
        }

        do {
            try await firebaseBackend.sendMaterialRequest(request, organizationId: organizationId)
            if let sendRecord {
                try? await firebaseBackend.saveMaterialSendRecord(sendRecord, organizationId: organizationId)
            }
            return .syncedImmediately
        } catch where OfflineWriteSupport.shouldQueue(error: error, isOnline: isOnline) {
            OfflineOutboxStore.shared.enqueueSendMaterialRequest(
                request,
                sendRecord: sendRecord,
                organizationId: organizationId
            )
            return .queuedForSync
        }
    }
}
