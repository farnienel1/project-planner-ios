//
//  OfflineSyncCoordinator.swift
//  Project Planner
//
//  Processes the persistent outbox when connectivity returns.
//

import Foundation
import FirebaseAuth

@MainActor
enum OfflineSyncCoordinator {
    /// After this many failed replays an entry is no longer retried on its own: the queue sheet offers
    /// Retry (start again) or Discard (dropped like a refused replay, §2).
    static let maxAttempts = 5

    /// Whether `entry` has stopped retrying on its own and waits for Retry or Discard.
    static func reachedAttemptLimit(_ entry: OfflineOutboxEntry) -> Bool {
        entry.attemptCount >= maxAttempts
    }

    /// Retry: the entry starts its attempts again on the next sync.
    static func retry(entryId: UUID, outbox: OfflineOutboxStore? = nil) {
        (outbox ?? OfflineOutboxStore.shared).resetAttempts(id: entryId)
    }

    /// Discard: the entry leaves the queue for good and the stores drop its local pending copy, as for a
    /// refused replay (§2). No alert: the person chose it.
    static func discard(entryId: UUID, outbox: OfflineOutboxStore? = nil) {
        let outbox = outbox ?? OfflineOutboxStore.shared
        guard let entry = outbox.entries.first(where: { $0.id == entryId }) else { return }
        outbox.removeEntry(id: entry.id)
        postDropped(entry: entry)
    }

    /// RULEBOOK 1.33.0 (owner decision 4 Nov): Undo of a queued booking delete from the sync list. The item leaves the
    /// queue unsent and the booking is put back on this device.
    static func undoDelete(entryId: UUID, outbox: OfflineOutboxStore? = nil) {
        let outbox = outbox ?? OfflineOutboxStore.shared
        guard let queued = outbox.queuedDelete(entryId: entryId) else { return }
        outbox.removeEntry(id: entryId)
        postDeleteRestored(entry: queued.entry, payload: queued.payload)
    }

    /// The outcome of a queued delete that was not written (`offlineDeleteReplayDecision`): resolved with nothing to
    /// send (`alreadyGone`), or refused with a message (the booking is put back).
    private enum OfflineDeleteOutcome: Error {
        case resolved
        case refused(message: String)
    }

    /// Tests only: the signed-in account and the material email sender, so two real passes can be run over one
    /// queued email without Firebase. Nil in the app.
    struct ReplayTestSeam {
        var signedInUserId: String
        var sendMaterialRequest: @MainActor (MaterialOrderRequest, String) async throws -> Void
    }

    static var replayTestSeam: ReplayTestSeam?

    /// `countsAsAttempt` false for a background timer pass (`OutboxRetryPolicy`): a failure is recorded without
    /// using up one of the `maxAttempts` tries.
    static func processOutbox(
        firebaseBackend: FirebaseBackend,
        outbox: OfflineOutboxStore? = nil,
        countsAsAttempt: Bool = true
    ) async -> (synced: Int, failed: Int) {
        let outbox = outbox ?? OfflineOutboxStore.shared
        guard !outbox.entries.isEmpty else { return (0, 0) }

        var synced = 0
        var failed = 0
        let pending = outbox.entries

        print("🔥🔥🔥 DEBUG: [OfflineSync] Processing \(pending.count) outbox entries…")

        let signedInUserId = replayTestSeam?.signedInUserId ?? firebaseBackend.currentUser?.uid

        for entry in pending {
            if (signedInUserId ?? "").isEmpty {
                // Nobody signed in: nothing replays (and nothing is counted as a failure).
                break
            }
            if !entry.mayReplay(signedInUserId: signedInUserId) {
                // Queued by another account on this device: never written as this one (§2, §16).
                outbox.removeEntry(id: entry.id)
                postDropped(entry: entry)
                failed += 1
                print("🔥🔥🔥 DEBUG: [OfflineSync] Dropped \(entry.operation.rawValue) queued by another account")
                continue
            }
            if reachedAttemptLimit(entry) {
                // Waits for Retry or Discard in the queue sheet.
                failed += 1
                continue
            }

            // 1.33.1 review fix 3: an entry taken out of the queue since this pass began (a delete through Firestore
            // took that booking's queued save) is never replayed from the stale list.
            guard outbox.entries.contains(where: { $0.id == entry.id }) else { continue }
            // Another pass running at the same time already holds this entry: never replayed twice (a queued
            // material email would be sent twice; `sendMaterialRequest` has no server-side dedupe).
            guard outbox.claimEntryForReplay(id: entry.id) else { continue }
            defer { outbox.releaseEntryClaim(id: entry.id) }

            do {
                // 1.33.1 review fix 3: while this entry replays, a delete of its booking goes through Firestore after
                // it (`OfflineOutboxStore.isInFlight`), never "nothing to send". Cleared when this block ends, before
                // any catch below runs.
                outbox.markInFlight(entityId: entry.entityId)
                defer { outbox.clearInFlight(entityId: entry.entityId) }
                try await execute(entry: entry, firebaseBackend: firebaseBackend)
                outbox.removeEntry(id: entry.id)
                synced += 1
                // The server confirmed this change: follow-ups that wait for it (leave approver notices) run now.
                NotificationCenter.default.post(name: .offlineOutboxEntrySynced, object: nil, userInfo: entryInfo(entry))
            } catch let outcome as OfflineDeleteOutcome {
                // RULEBOOK 1.33.0: a queued delete that was not written leaves the queue: gone already (nothing to do),
                // or refused — the booking comes back with the rulebook's message.
                switch outcome {
                case .resolved:
                    outbox.removeEntry(id: entry.id)
                    synced += 1
                case .refused(let message):
                    outbox.removeRefused(id: entry.id, message: message)
                    restoreRefusedDelete(entry: entry)
                    failed += 1
                }
            } catch {
                if FirestoreWriteAck.isPendingInSDK(error) {
                    // 1.33.1: the replayed booking write was handed to Firestore but the server did not confirm it in
                    // time. Firestore keeps it and delivers it in order, so it leaves the outbox (never sent twice).
                    outbox.removeEntry(id: entry.id)
                    synced += 1
                    print("🔥🔥🔥 DEBUG: [OfflineSync] \(entry.operation.rawValue) \(entry.entityId) is with Firestore, pending sync")
                    continue
                }
                if let writeError = error as? OfflinePartialUpdateWriter.WriteError {
                    // Another account is signed in, or the path is unusable: retrying cannot help.
                    outbox.removeRefused(id: entry.id, message: writeError.localizedDescription)
                    NotificationCenter.default.post(name: .offlineOutboxEntryRefused, object: nil, userInfo: entryInfo(entry))
                    failed += 1
                    continue
                }
                // `bookingReplayRefusedIsFinal({ code, isCreate })`: also final is not-found on an edit replay
                // (the booking was deleted elsewhere; an edit never turns into a create).
                // Any other queued edit: `replayRefusedIsFinal({ code, isCreate })` (RULEBOOK 1.9.0 §1).
                if replayIsFinal(error, entry: entry) {
                    // RULEBOOK §2: a refused replay is final (`bookingReplayRefusedIsFinal`). The booking
                    // was deleted (tombstone) or cancelled elsewhere, or the area is online only.
                    handleRefused(entry: entry, outbox: outbox)
                    failed += 1
                    print("🔥🔥🔥 DEBUG: [OfflineSync] Refused for good \(entry.operation.rawValue) \(entry.entityId)")
                    continue
                }
                outbox.markFailed(id: entry.id, error: error.localizedDescription, countsAsAttempt: countsAsAttempt)
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

    /// userInfo for `.offlineOutboxEntrySynced` / `.offlineOutboxEntryRefused`.
    private static func entryInfo(_ entry: OfflineOutboxEntry) -> [String: String] {
        [
            "operation": entry.operation.rawValue,
            "entityId": entry.entityId,
            "organizationId": entry.organizationId,
        ]
    }

    /// Bookings: `bookingReplayRefusedIsFinal`; every other queued item: `replayRefusedIsFinal`. The Firestore code is
    /// read through an app error that wraps it (1.33.0: before, a refusal the backend re-wrapped was never seen as
    /// final and retried until the attempt limit). Queued deletes are decided in `replayDelete`.
    private static func replayIsFinal(_ error: Error, entry: OfflineOutboxEntry) -> Bool {
        switch entry.operation {
        case .saveBooking, .saveManagerSiteBooking:
            return BookingWritePatch.isRefusedFinal(error, isCreate: bookingSaveIsCreate(entry))
        case .deleteBooking, .deleteManagerSiteBooking:
            return false
        default:
            guard let code = BookingWritePatch.firestoreErrorCode(error) else { return false }
            return CanonicalBusinessEngine.replayRefusedIsFinal(errorCode: code, isCreate: queuedItemIsCreate(entry))
        }
    }

    /// A queued partial update knows whether it creates (`isCreate`); other items are unknown (nil), so only
    /// permission-denied is final for them.
    private static func queuedItemIsCreate(_ entry: OfflineOutboxEntry) -> Bool? {
        switch entry.operation {
        case .saveAnnualLeaveRequest, .saveOwnProfileFields, .saveOwnNotificationToggles:
            return (try? JSONDecoder().decode(OfflinePartialUpdatePayload.self, from: entry.payload))?.isCreate
        default:
            return nil
        }
    }

    /// For a queued booking save: true for a create (no `changedFields`), false for an edit. Nil otherwise.
    private static func bookingSaveIsCreate(_ entry: OfflineOutboxEntry) -> Bool? {
        let decoder = JSONDecoder()
        switch entry.operation {
        case .saveBooking:
            guard let payload = try? decoder.decode(OfflineSaveBookingPayload.self, from: entry.payload) else { return nil }
            return payload.changedFields == nil
        case .saveManagerSiteBooking:
            guard let payload = try? decoder.decode(OfflineSaveManagerSiteBookingPayload.self, from: entry.payload) else { return nil }
            return payload.changedFields == nil
        default:
            return nil
        }
    }

    private static func execute(entry: OfflineOutboxEntry, firebaseBackend: FirebaseBackend) async throws {
        let decoder = JSONDecoder()
        switch entry.operation {
        case .saveBooking:
            let payload = try decoder.decode(OfflineSaveBookingPayload.self, from: entry.payload)
            // An edit replays only its changed fields; only a create writes the whole booking.
            do {
                try await firebaseBackend.saveBooking(
                    payload.booking,
                    organizationId: entry.organizationId,
                    changedFields: payload.changedFields.map { Set($0) }
                )
            } catch {
                // #209 review item 1: a replay Firestore holds after its wait timed out tells the person once the
                // server confirms it (never if it refuses); the entry then leaves the outbox (`replayPending`).
                if FirestoreWriteAck.isPendingInSDK(error), payload.changedFields != nil, let previous = payload.previousBooking {
                    let after = payload.booking
                    let organizationId = entry.organizationId
                    SDKPendingWrites.shared.whenConfirmed(ticket: FirestoreWriteAck.pendingTicket(error)) {
                        OvertimeReopenNotice.labour(before: previous, after: after, organizationId: organizationId)
                    }
                }
                throw error
            }
            // RULEBOOK 1.33.0 §25 reopen: the edit reached the server now, so the PAYE overtime line may reopen
            // (web notifies after its online write; best effort).
            // Only judged in the company it was written to (skipped when another company is open now).
            if payload.changedFields != nil, let previous = payload.previousBooking {
                OvertimeReopenNotice.labour(before: previous, after: payload.booking, organizationId: entry.organizationId)
            }

        case .deleteBooking, .deleteManagerSiteBooking:
            try await replayDelete(entry: entry, firebaseBackend: firebaseBackend)

        case .saveManagerSiteBooking:
            let payload = try decoder.decode(OfflineSaveManagerSiteBookingPayload.self, from: entry.payload)
            do {
                try await firebaseBackend.saveManagerSiteBooking(
                    payload.booking,
                    organizationId: entry.organizationId,
                    changedFields: payload.changedFields.map { Set($0) }
                )
            } catch {
                // #209 review item 1: as for a labour booking replay.
                if FirestoreWriteAck.isPendingInSDK(error), payload.changedFields != nil, let previous = payload.previousBooking {
                    let after = payload.booking
                    let organizationId = entry.organizationId
                    SDKPendingWrites.shared.whenConfirmed(ticket: FirestoreWriteAck.pendingTicket(error)) {
                        OvertimeReopenNotice.managerSite(before: previous, after: after, organizationId: organizationId)
                    }
                }
                throw error
            }
            if payload.changedFields != nil, let previous = payload.previousBooking {
                OvertimeReopenNotice.managerSite(before: previous, after: payload.booking, organizationId: entry.organizationId)
            }

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
            if let seam = replayTestSeam {
                try await seam.sendMaterialRequest(payload.request, entry.organizationId)
            } else {
                try await firebaseBackend.sendMaterialRequest(payload.request, organizationId: entry.organizationId)
            }
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

    /// RULEBOOK 1.33.0 §2: replays a queued delete (`offlineDeleteReplayDecision` in a transaction with its
    /// tombstone). The document id is the stored one (a lower-case manager schedule id stays lower case). A server
    /// refusal is read with `offlineDeleteRefusalDecision`: not-found is gone already, permission-denied is refused
    /// (the booking comes back), anything else retries.
    private static func replayDelete(entry: OfflineOutboxEntry, firebaseBackend: FirebaseBackend) async throws {
        let payload = try JSONDecoder().decode(OfflineDeleteBookingPayload.self, from: entry.payload)
        let collection = payload.collection ?? (entry.operation == .deleteManagerSiteBooking ? "managerSiteBookings" : "bookings")
        let documentId = payload.documentId ?? payload.bookingId.uuidString
        let decision: String
        do {
            decision = try await firebaseBackend.replayOfflineBookingDelete(
                collection: collection,
                documentId: documentId,
                organizationId: entry.organizationId,
                fingerprint: payload.fingerprint
            )
        } catch {
            guard let code = BookingWritePatch.firestoreErrorCode(error) else { throw error }
            switch CanonicalBusinessEngine.offlineDeleteRefusalDecision(code: code) {
            case "alreadyGone": throw OfflineDeleteOutcome.resolved
            case "refusePermission":
                // RULEBOOK 1.33.0 §2: refused only after a fresh read shows the booking still there; gone or
                // tombstoned means the delete already happened.
                let stillLive = await firebaseBackend.offlineDeletedBookingStillLive(
                    collection: collection,
                    documentId: documentId,
                    organizationId: entry.organizationId
                )
                if stillLive == false { throw OfflineDeleteOutcome.resolved }
                throw OfflineDeleteOutcome.refused(message: CanonicalBusinessEngine.offlineDeleteRefusedMessage)
            default: throw error
            }
        }
        switch decision {
        case "apply":
            // RULEBOOK 1.33.0 §25 reopen: the queued delete was written now (best effort, after the write).
            if let booking = payload.labourBooking {
                OvertimeReopenNotice.labour(before: booking, after: nil, organizationId: entry.organizationId)
            } else if let booking = payload.managerBooking {
                OvertimeReopenNotice.managerSite(before: booking, after: nil, organizationId: entry.organizationId)
            }
            return
        case "alreadyGone", "dropLocal":
            throw OfflineDeleteOutcome.resolved
        case "refuseChanged":
            throw OfflineDeleteOutcome.refused(message: CanonicalBusinessEngine.offlineDeleteChangedMessage)
        default:
            throw OfflineDeleteOutcome.refused(message: CanonicalBusinessEngine.offlineDeleteRefusedMessage)
        }
    }

    /// A refused delete: the booking reappears on this device (the server still has it; its listener confirms).
    private static func restoreRefusedDelete(entry: OfflineOutboxEntry) {
        guard let payload = try? JSONDecoder().decode(OfflineDeleteBookingPayload.self, from: entry.payload) else { return }
        NotificationCenter.default.post(name: .offlineOutboxEntryRefused, object: nil, userInfo: entryInfo(entry))
        postDeleteRestored(entry: entry, payload: payload)
    }

    /// Tells the stores to put a booking whose queued delete was undone or refused back (`.offlineBookingDeleteRestored`).
    private static func postDeleteRestored(entry: OfflineOutboxEntry, payload: OfflineDeleteBookingPayload) {
        var info: [String: Any] = [
            "bookingId": payload.bookingId.uuidString,
            "collection": payload.collection ?? (entry.operation == .deleteManagerSiteBooking ? "managerSiteBookings" : "bookings"),
            "organizationId": entry.organizationId,
        ]
        if let booking = payload.labourBooking { info["labourBooking"] = booking }
        if let booking = payload.managerBooking { info["managerBooking"] = booking }
        NotificationCenter.default.post(name: .offlineBookingDeleteRestored, object: nil, userInfo: info)
    }

    /// Removes a refused item for good and tells the stores to drop the local copy.
    private static func handleRefused(entry: OfflineOutboxEntry, outbox: OfflineOutboxStore) {
        let message: String
        switch entry.operation {
        case .saveBooking, .saveManagerSiteBooking:
            // `BOOKING_REPLAY_REFUSED_MESSAGE`
            message = CanonicalBusinessEngine.bookingReplayRefusedMessage
        case .deleteBooking, .deleteManagerSiteBooking:
            message = CanonicalBusinessEngine.offlineDeleteRefusedMessage
        default:
            message = "\(entry.displayTitle): this change was refused by the server and was not saved."
        }
        outbox.removeRefused(id: entry.id, message: message)
        postDropped(entry: entry)
    }

    /// Tells the stores an entry left the queue unsynced, so they drop its local pending copy.
    private static func postDropped(entry: OfflineOutboxEntry) {
        NotificationCenter.default.post(name: .offlineOutboxEntryRefused, object: nil, userInfo: entryInfo(entry))
        // A discarded or dropped delete was never sent: the booking is still on the server, so it comes back here.
        if entry.operation == .deleteBooking || entry.operation == .deleteManagerSiteBooking,
           let payload = try? JSONDecoder().decode(OfflineDeleteBookingPayload.self, from: entry.payload) {
            postDeleteRestored(entry: entry, payload: payload)
        }
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
    /// RULEBOOK 1.33.0: a queued booking delete was undone or refused; the booking goes back on this device.
    /// userInfo: `bookingId`, `collection`, `organizationId` (Strings) and `labourBooking` (`Booking`) or
    /// `managerBooking` (`ManagerSiteBooking`) when the item carried the copy.
    static let offlineBookingDeleteRestored = Notification.Name("offlineBookingDeleteRestored")
    /// One outbox entry was written and confirmed by the server. userInfo: `operation`, `entityId`,
    /// `organizationId` (Strings).
    static let offlineOutboxEntrySynced = Notification.Name("offlineOutboxEntrySynced")
    /// One outbox entry was refused for good and removed. userInfo as `offlineOutboxEntrySynced`.
    static let offlineOutboxEntryRefused = Notification.Name("offlineOutboxEntryRefused")
    /// The signed-in account signed out; device caches for it are cleared.
    static let appDidSignOut = Notification.Name("appDidSignOut")
}
