//
//  OfflineSyncCoordinator.swift
//  Project Planner
//
//  Processes the persistent outbox when connectivity returns.
//

import Foundation

@MainActor
enum OfflineSyncCoordinator {
    private static let maxAttempts = 5

    static func processOutbox(
        firebaseBackend: FirebaseBackend,
        outbox: OfflineOutboxStore = .shared
    ) async -> (synced: Int, failed: Int) {
        guard !outbox.entries.isEmpty else { return (0, 0) }

        var synced = 0
        var failed = 0
        let pending = outbox.entries

        print("🔥🔥🔥 DEBUG: [OfflineSync] Processing \(pending.count) outbox entries…")

        for entry in pending {
            if entry.attemptCount >= maxAttempts {
                failed += 1
                continue
            }

            do {
                try await execute(entry: entry, firebaseBackend: firebaseBackend)
                outbox.removeEntry(id: entry.id)
                synced += 1
            } catch {
                outbox.markFailed(id: entry.id, error: error.localizedDescription)
                failed += 1
                print("🔥🔥🔥 DEBUG: [OfflineSync] Failed \(entry.operation.rawValue): \(error.localizedDescription)")
            }
        }

        if synced > 0 {
            NotificationCenter.default.post(name: .offlineSyncDidComplete, object: nil)
        }

        print("🔥🔥🔥 DEBUG: [OfflineSync] Done — synced: \(synced), failed: \(failed), remaining: \(outbox.pendingCount)")
        return (synced, failed)
    }

    private static func execute(entry: OfflineOutboxEntry, firebaseBackend: FirebaseBackend) async throws {
        let decoder = JSONDecoder()
        switch entry.operation {
        case .saveBooking:
            let payload = try decoder.decode(OfflineSaveBookingPayload.self, from: entry.payload)
            try await firebaseBackend.saveBooking(payload.booking, organizationId: entry.organizationId)

        case .deleteBooking:
            let payload = try decoder.decode(OfflineDeleteBookingPayload.self, from: entry.payload)
            let deleteStub = Booking(
                id: payload.bookingId,
                operativeId: UUID(),
                projectId: UUID(),
                date: Date(),
                timeSlot: .fullDay,
                bookedBy: ""
            )
            try await firebaseBackend.deleteBooking(deleteStub, organizationId: entry.organizationId)

        case .saveManagerSiteBooking:
            let payload = try decoder.decode(OfflineSaveManagerSiteBookingPayload.self, from: entry.payload)
            try await firebaseBackend.saveManagerSiteBooking(payload.booking, organizationId: entry.organizationId)

        case .deleteManagerSiteBooking:
            let payload = try decoder.decode(OfflineDeleteManagerSiteBookingPayload.self, from: entry.payload)
            let deleteStub = ManagerSiteBooking(
                id: payload.bookingId,
                userId: "",
                date: Date(),
                timeSlot: .morning,
                locationType: .office
            )
            try await firebaseBackend.deleteManagerSiteBooking(deleteStub, organizationId: entry.organizationId)

        case .saveMaterialItem:
            let payload = try decoder.decode(OfflineSaveMaterialItemPayload.self, from: entry.payload)
            try await firebaseBackend.saveMaterialItem(payload.material, organizationId: entry.organizationId)
            OfflineMaterialLocalStore.shared.markSynced(materialId: payload.material.id, projectId: payload.material.projectId)

        case .deleteMaterialItem:
            let payload = try decoder.decode(OfflineDeleteMaterialItemPayload.self, from: entry.payload)
            try await firebaseBackend.deleteMaterialItem(payload.materialId, organizationId: entry.organizationId)
            OfflineMaterialLocalStore.shared.markDeletedSynced(materialId: payload.materialId)

        case .sendMaterialRequest:
            let payload = try decoder.decode(OfflineSendMaterialRequestPayload.self, from: entry.payload)
            try await firebaseBackend.sendMaterialRequest(payload.request, organizationId: entry.organizationId)
            if let record = payload.sendRecord {
                try? await firebaseBackend.saveMaterialSendRecord(record, organizationId: entry.organizationId)
            }
        }
    }
}

extension Notification.Name {
    static let offlineSyncDidComplete = Notification.Name("offlineSyncDidComplete")
}
