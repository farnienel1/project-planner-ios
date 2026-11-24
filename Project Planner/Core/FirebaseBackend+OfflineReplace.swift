//
//  FirebaseBackend+OfflineReplace.swift
//  Project Planner
//
//  RULEBOOK 1.86.0 §2 / §5 (owner decision 24 Nov): replaying a Replace chosen offline. The new booking's document and
//  its tombstone and every replaced booking and its tombstone are read from the server, `offlineReplaceReplayDecision`
//  says what to do, and `apply` / `createOnly` are written in one Firestore transaction that reads everything again and
//  asks the rule again — the new booking as a plain create (never a merge) and each delete the rule lists with its
//  tombstone (`bookingReplaceWrites` for the paths and tombstones). App plumbing only; the rulebook decides.
//

import Foundation
import FirebaseAuth
@preconcurrency import FirebaseFirestore

extension FirebaseBackend {
    /// Replays one queued Replace and returns what was carried out. Throws when the server could not be reached (the
    /// item stays queued) or refused the write (read it with `offlineReplaceRefusalDecision`).
    func replayOfflineBookingReplace(
        _ payload: OfflineReplaceBookingPayload,
        organizationId: String
    ) async throws -> RulebookOfflineReplaceResult {
        let orgId = normalizedOrganizationId(organizationId)
        guard !orgId.isEmpty, let uid = currentUser?.uid, !uid.isEmpty,
              let newDocumentId = payload.newDocumentId, !newDocumentId.isEmpty,
              let newTombstonePath = CanonicalBusinessEngine.bookingTombstonePath(organizationId: orgId, bookingId: newDocumentId) else {
            throw NSError(
                domain: "FirebaseBackend",
                code: 400,
                userInfo: [NSLocalizedDescriptionKey: "Could not replace this booking: sign in again and retry."]
            )
        }
        let collection = payload.collection

        // The new booking's fields, exactly as the online Replace writes them (`createBookingReplacing`).
        var data: [String: Any]
        if let labour = payload.labourBooking {
            guard labour.writableOperativeId != nil else { throw UnresolvedBookingPersonError() }
            data = BookingWritePatch.labourValues(labour, deletesClearedFields: false)
            data["createdAt"] = Timestamp(date: labour.createdAt)
        } else if let manager = payload.managerBooking {
            data = BookingWritePatch.managerValues(manager, deletesClearedFields: false)
            data["organizationId"] = orgId
            data["createdAt"] = Timestamp(date: manager.createdAt)
        } else {
            return RulebookOfflineReplaceResult(decision: "dropLocal", deletes: [], message: nil)
        }
        data["id"] = newDocumentId

        // Every replaced booking the rule may delete, with its tombstone (`bookingReplaceWrites`). Rows the rule will
        // skip (created offline) are left out of the plan; the rule still sees them in `queuedReplaced`.
        let sendable = payload.replaced.filter { !$0.createdOffline }
        var plan: RulebookBookingReplacePlan?
        if !sendable.isEmpty {
            plan = CanonicalBusinessEngine.bookingReplaceWrites(
                organizationId: orgId,
                bookingCollection: collection,
                bookingId: newDocumentId,
                replaced: sendable.map { RulebookBookingReplaceRef(collection: $0.collection, bookingId: $0.documentId) },
                deletedBy: uid
            )
            guard plan != nil else {
                return RulebookOfflineReplaceResult(
                    decision: "refusePermission", deletes: [], message: CanonicalBusinessEngine.offlineReplaceRefusedMessage
                )
            }
        }
        let bookingPath = plan?.bookingPath ?? "organizations/\(orgId)/\(collection)/\(newDocumentId)"
        let rows: [OfflineReplaceRow] = (plan?.deletes ?? []).map { row in
            var tombstone = row.tombstone
            tombstone["deletedAt"] = FieldValue.serverTimestamp()
            return OfflineReplaceRow(
                collection: row.collection,
                bookingId: row.bookingId,
                ref: db.document(row.path),
                tombstoneRef: db.document(row.tombstonePath),
                tombstone: RulebookJSONBox(object: tombstone)
            )
        }

        // The zone the queued fingerprints were taken in (the queued item's own company, as for an offline delete).
        // When another company's document cannot be read the item waits (never compared in the wrong zone).
        let openOrgId = normalizedOrganizationId(currentOrganization?.firestoreDocumentId ?? "")
        let sameOrganization = !openOrgId.isEmpty && openOrgId == orgId
        var entryCountryCode: String?? = .none
        if !sameOrganization {
            let snapshot = try await db.collection("organizations").document(orgId).getDocument(source: .server)
            entryCountryCode = .some(snapshot.data()?["countryCode"] as? String)
        }
        guard let timeZone = Self.offlineDeleteTimeZone(
            sameOrganization: sameOrganization,
            openTimeZone: OrganizationRulebookContext.timeZoneIdentifier,
            entryCountryCode: entryCountryCode
        ) else {
            throw NSError(domain: "FirebaseBackend", code: 503, userInfo: [NSLocalizedDescriptionKey: "Waiting for the company's settings."])
        }

        // `canDeleteBooking` per replaced booking, judged on the live copy (nil: the rules decide). Read once before
        // the transaction (the job list lives on the main actor), then passed in.
        var mayDelete: [String: Bool] = [:]
        for row in rows {
            let live = try await row.ref.getDocument(source: .server)
            if let data = live.data(),
               let allowed = Self.offlineDeleteAllowed(collection: row.collection, data: data, sameOrganization: sameOrganization) {
                mayDelete[Self.replaceKey(row.collection, row.bookingId)] = allowed
            }
        }

        let create = RulebookJSONBox(object: WriteMetadata.stamped(data, userId: uid))
        let queued = payload.replaced.map {
            RulebookQueuedReplaceTarget(
                collection: $0.collection,
                bookingId: $0.documentId,
                fingerprint: $0.fingerprint,
                createdOffline: $0.createdOffline
            )
        }
        let result = try await Self.runOfflineReplaceTransaction(
            db: db,
            createRef: db.document(bookingPath),
            newTombstoneRef: db.document(newTombstonePath),
            create: create,
            rows: rows,
            queued: queued,
            mayDelete: mayDelete,
            collection: collection,
            newDocumentId: newDocumentId,
            timeZone: timeZone
        )
        NSLog("BOOKING_REPLACE_REPLAY id=%@ decision=%@", newDocumentId, result.decision)
        return result
    }

    /// The replay transaction: every read first (the new booking and its tombstone, each replaced booking and its
    /// tombstone), the rule asked again, then — only for `apply` / `createOnly` — the create and the deletes the rule
    /// lists, each with its tombstone. `nonisolated` so the block never runs on the main actor.
    nonisolated private static func runOfflineReplaceTransaction(
        db: Firestore,
        createRef: DocumentReference,
        newTombstoneRef: DocumentReference,
        create: RulebookJSONBox,
        rows: [OfflineReplaceRow],
        queued: [RulebookQueuedReplaceTarget],
        mayDelete: [String: Bool],
        collection: String,
        newDocumentId: String,
        timeZone: String
    ) async throws -> RulebookOfflineReplaceResult {
        let box = OfflineReplaceResultBox()
        _ = try await db.runTransaction { transaction, errorPointer -> Any? in
            var reads: [RulebookOfflineReplaceLive] = []
            let newSnapshot: DocumentSnapshot
            let newTombstone: DocumentSnapshot
            do {
                newSnapshot = try transaction.getDocument(createRef)
                newTombstone = try transaction.getDocument(newTombstoneRef)
                for row in rows {
                    let live = try transaction.getDocument(row.ref)
                    let tombstone = try transaction.getDocument(row.tombstoneRef)
                    reads.append(RulebookOfflineReplaceLive(
                        collection: row.collection,
                        bookingId: row.bookingId,
                        live: live.exists ? live.data() : nil,
                        tombstoned: tombstone.exists,
                        mayDelete: mayDelete[FirebaseBackend.replaceKey(row.collection, row.bookingId)]
                    ))
                }
            } catch {
                errorPointer?.pointee = error as NSError
                return nil
            }
            let result = CanonicalBusinessEngine.offlineReplaceReplayDecision(
                bookingCollection: collection,
                bookingId: newDocumentId,
                queuedReplaced: queued,
                newBookingDeleted: false,
                newBookingExists: newSnapshot.exists,
                newBookingTombstoned: newTombstone.exists,
                replaced: reads,
                timeZone: timeZone
            )
            box.value = result
            guard result.decision == "apply" || result.decision == "createOnly" else { return nil }
            let deleting = Set(result.deletes.map { FirebaseBackend.replaceKey($0.collection, $0.bookingId) })
            // A plain create (never a merge onto an existing document, RULEBOOK 1.20.2).
            transaction.setData(create.object, forDocument: createRef)
            for row in rows where deleting.contains(FirebaseBackend.replaceKey(row.collection, row.bookingId)) {
                transaction.deleteDocument(row.ref)
                transaction.setData(row.tombstone.object, forDocument: row.tombstoneRef)
            }
            return nil
        }
        return box.value ?? .unanswered
    }

    nonisolated static func replaceKey(_ collection: String, _ bookingId: String) -> String {
        "\(collection)/\(bookingId.lowercased())"
    }

    /// One replaced booking for the replay transaction.
    nonisolated struct OfflineReplaceRow: @unchecked Sendable {
        let collection: String
        let bookingId: String
        let ref: DocumentReference
        let tombstoneRef: DocumentReference
        let tombstone: RulebookJSONBox
    }

    nonisolated final class OfflineReplaceResultBox: @unchecked Sendable {
        var value: RulebookOfflineReplaceResult?
    }
}
