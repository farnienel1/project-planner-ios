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
        outbox: OfflineOutboxStore? = nil
    ) async -> (synced: Int, failed: Int) {
        let outbox = outbox ?? OfflineOutboxStore.shared
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
                if let writeError = error as? OfflinePartialUpdateWriter.WriteError {
                    // Another account is signed in, or the path is unusable: retrying cannot help.
                    outbox.removeRefused(id: entry.id, message: writeError.localizedDescription)
                    failed += 1
                    continue
                }
                let isBookingSave = entry.operation == .saveBooking || entry.operation == .saveManagerSiteBooking
                // An edit to a booking that is gone (deleted elsewhere before tombstones existed) must not
                // bring it back either. RULEBOOK-GAP(bookingReplayNotFound): not in `bookingReplayRefusedIsFinal`.
                if BookingWritePatch.isRefusedFinal(error) || (isBookingSave && BookingWritePatch.isNotFound(error)) {
                    // RULEBOOK §2: a refused replay is final (`bookingReplayRefusedIsFinal`). The booking
                    // was deleted (tombstone) or cancelled elsewhere, or the area is online only.
                    handleRefused(entry: entry, outbox: outbox)
                    failed += 1
                    print("🔥🔥🔥 DEBUG: [OfflineSync] Refused for good \(entry.operation.rawValue) \(entry.entityId)")
                    continue
                }
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
            // An edit replays only its changed fields; only a create writes the whole booking.
            try await firebaseBackend.saveBooking(
                payload.booking,
                organizationId: entry.organizationId,
                changedFields: payload.changedFields.map { Set($0) }
            )

        case .deleteBooking:
            let payload = try decoder.decode(OfflineDeleteBookingPayload.self, from: entry.payload)
            var deleteStub = Booking(
                id: payload.bookingId,
                operativeId: UUID(),
                projectId: UUID(),
                date: Date(),
                timeSlot: .fullDay,
                bookedBy: ""
            )
            deleteStub.documentId = payload.documentId
            try await firebaseBackend.deleteBooking(deleteStub, organizationId: entry.organizationId)

        case .saveManagerSiteBooking:
            let payload = try decoder.decode(OfflineSaveManagerSiteBookingPayload.self, from: entry.payload)
            try await firebaseBackend.saveManagerSiteBooking(
                payload.booking,
                organizationId: entry.organizationId,
                changedFields: payload.changedFields.map { Set($0) }
            )

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
                do {
                    try await firebaseBackend.saveMaterialSendRecord(record, organizationId: entry.organizationId)
                } catch {
                    print("🔥🔥🔥 DEBUG: [materials/send] email sent; send-record write failed: \(error.localizedDescription)")
                }
            }

        case .saveDeadlines:
            let payload = try decoder.decode(OfflineSaveDeadlinesPayload.self, from: entry.payload)
            let items = OfflineDeadlineCodec.items(from: payload.items)
            let written = try await firebaseBackend.saveDeadlines(
                items,
                projectId: payload.projectId,
                isSmallWorks: payload.isSmallWorks,
                organizationId: entry.organizationId,
                baseUpdatedAt: payload.baseUpdatedAt
            )
            OfflineDeadlineLocalStore.shared.save(
                items: written,
                projectId: payload.projectId,
                organizationId: entry.organizationId,
                updatedAt: Date()
            )

        case .saveAnnualLeaveRequest, .saveOwnProfileFields, .saveOwnNotificationToggles:
            let payload = try decoder.decode(OfflinePartialUpdatePayload.self, from: entry.payload)
            // Throws `OfflinePartialUpdateWriter.WriteError` (final) when another account is signed in.
            try await OfflinePartialUpdateWriter.replay(
                payload,
                db: firebaseBackend.db,
                signedInUserId: firebaseBackend.currentUser?.uid
            )
        }
    }

    /// Removes a refused item for good and tells the stores to drop the local copy.
    private static func handleRefused(entry: OfflineOutboxEntry, outbox: OfflineOutboxStore) {
        let message: String
        switch entry.operation {
        case .saveBooking, .saveManagerSiteBooking:
            // `BOOKING_REPLAY_REFUSED_MESSAGE`
            message = CanonicalBusinessEngine.bookingReplayRefusedMessage
        case .deleteBooking, .deleteManagerSiteBooking:
            message = "You do not have permission to delete this booking. It has been put back."
        default:
            message = "\(entry.displayTitle): this change was refused by the server and was not saved."
        }
        outbox.removeRefused(id: entry.id, message: message)
        switch entry.operation {
        case .saveBooking, .deleteBooking:
            NotificationCenter.default.post(
                name: .offlineBookingReplayRefused,
                object: nil,
                userInfo: ["bookingId": entry.entityId, "collection": "bookings", "operation": entry.operation.rawValue]
            )
        case .saveManagerSiteBooking, .deleteManagerSiteBooking:
            NotificationCenter.default.post(
                name: .offlineBookingReplayRefused,
                object: nil,
                userInfo: ["bookingId": entry.entityId, "collection": "managerSiteBookings", "operation": entry.operation.rawValue]
            )
        default:
            break
        }
    }
}

extension Notification.Name {
    static let offlineSyncDidComplete = Notification.Name("offlineSyncDidComplete")
    /// A queued booking write was refused for good. userInfo: `bookingId` (String), `collection`
    /// (`bookings` | `managerSiteBookings`), `operation` (outbox operation raw value).
    static let offlineBookingReplayRefused = Notification.Name("offlineBookingReplayRefused")
}
