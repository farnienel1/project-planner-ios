//
//  FirebaseBackend+OfflineDelete.swift
//  Project Planner
//
//  RULEBOOK 1.33.0 §2 (owner decision 4 Nov "Offline delete on iOS"): replaying a queued delete of a labour or manager
//  schedule booking. The live booking and its tombstone are read from the server, `offlineDeleteReplayDecision` says
//  what to do, and an `apply` is written — the delete and its tombstone (`bookingTombstoneWriteFields`) — in one
//  Firestore transaction that reads both again and asks the rule again, so a change made on another device in between
//  is never deleted. `offlineDeleteRefusalDecision` reads a server refusal. App plumbing only; the rulebook decides.
//  Also: the booked person's timesheets for `bookingDeleteSignedTimesheetWarning`.
//

import Foundation
import FirebaseAuth
@preconcurrency import FirebaseFirestore

extension FirebaseBackend {
    /// Replays one queued delete. Returns the decision that was carried out (`apply`, `alreadyGone`,
    /// `refuseChanged`, `refusePermission`). Throws when the server could not be reached (the item stays queued) or
    /// refused the write (read it with `offlineDeleteRefusalDecision`). `fingerprint` nil (an item queued by an older
    /// build) compares the live booking with itself, so only the permission and tombstone checks apply.
    func replayOfflineBookingDelete(
        collection: String,
        documentId: String,
        organizationId: String,
        fingerprint: String?
    ) async throws -> String {
        let orgId = normalizedOrganizationId(organizationId)
        guard !orgId.isEmpty, !documentId.isEmpty,
              let uid = currentUser?.uid,
              let tombstonePath = CanonicalBusinessEngine.bookingTombstonePath(organizationId: orgId, bookingId: documentId),
              var tombstone = CanonicalBusinessEngine.bookingTombstoneWriteFields(
                bookingId: documentId,
                collection: collection,
                deletedBy: uid,
                deletedFrom: "ios"
              ) else {
            throw NSError(
                domain: "FirebaseBackend",
                code: 400,
                userInfo: [NSLocalizedDescriptionKey: "Could not delete this booking: sign in again and retry."]
            )
        }
        tombstone["deletedAt"] = FieldValue.serverTimestamp()
        let ref = db.collection("organizations").document(orgId).collection(collection).document(documentId)
        let tombstoneRef = db.document(tombstonePath)

        // The server copy (offline this throws and the item stays queued).
        let liveSnapshot = try await ref.getDocument(source: .server)
        let tombstoned = (try? await tombstoneRef.getDocument(source: .server))?.exists ?? false
        let live = liveSnapshot.exists ? liveSnapshot.data() : nil
        // `canDeleteBooking` for the signed-in user on the live booking and its job. Nil (the security rules decide)
        // when this device cannot judge it: another organisation's queued item, no viewer yet, or the job not loaded.
        let openOrgId = normalizedOrganizationId(currentOrganization?.firestoreDocumentId ?? "")
        let mayDelete: Bool? = live.flatMap {
            Self.offlineDeleteAllowed(
                collection: collection,
                data: $0,
                sameOrganization: !openOrgId.isEmpty && openOrgId == orgId
            )
        }
        let timeZone = OrganizationRulebookContext.timeZoneIdentifier
        let first = Self.offlineDeleteDecision(
            documentId: documentId, collection: collection, fingerprint: fingerprint,
            live: live, tombstoned: tombstoned, mayDelete: mayDelete, timeZone: timeZone
        )
        guard first == "apply" else { return first }
        return try await Self.runOfflineDeleteTransaction(
            db: db,
            ref: ref,
            tombstoneRef: tombstoneRef,
            tombstone: RulebookJSONBox(object: tombstone),
            documentId: documentId,
            collection: collection,
            fingerprint: fingerprint,
            mayDelete: mayDelete,
            timeZone: timeZone
        )
    }

    /// After a permission-denied refusal (RULEBOOK 1.33.0 §2 `offlineDeleteRefusalDecision`): a fresh server read of
    /// the booking and its tombstone. False when the booking is gone or tombstoned (the delete already happened), true
    /// when it is still there, nil when it could not be read.
    func offlineDeletedBookingStillLive(collection: String, documentId: String, organizationId: String) async -> Bool? {
        let orgId = normalizedOrganizationId(organizationId)
        guard !orgId.isEmpty, !documentId.isEmpty else { return nil }
        let ref = db.collection("organizations").document(orgId).collection(collection).document(documentId)
        guard let live = try? await ref.getDocument(source: .server) else { return nil }
        guard live.exists else { return false }
        if let tombstonePath = CanonicalBusinessEngine.bookingTombstonePath(organizationId: orgId, bookingId: documentId),
           let tombstone = try? await db.document(tombstonePath).getDocument(source: .server),
           tombstone.exists {
            return false
        }
        return true
    }

    /// `offlineDeleteReplayDecision` for a live document read from Firestore.
    nonisolated static func offlineDeleteDecision(
        documentId: String,
        collection: String,
        fingerprint: String?,
        live: [String: Any]?,
        tombstoned: Bool,
        mayDelete: Bool?,
        timeZone: String
    ) -> String {
        let liveJSON = live.map { BookingWritePatch.storedJSON($0, collection: collection) }
        let queued = fingerprint ?? live.map { BookingWritePatch.stored($0, collection: collection) } ?? ""
        return CanonicalBusinessEngine.offlineDeleteReplayDecision(
            bookingId: documentId,
            collection: collection,
            fingerprint: queued,
            createdOffline: false,
            live: liveJSON,
            tombstoned: tombstoned,
            mayDelete: mayDelete,
            timeZone: timeZone
        )
    }

    /// `bookingRemoveAction` is `delete` for the live booking (labour: its job; manager schedule: person and place).
    /// Nil when this device cannot judge it — the queued item is for another organisation than the open one, the
    /// profile has not loaded, or the booking's job is not among the loaded jobs (e.g. a cold launch before jobs load)
    /// — so the replay goes ahead and the security rules decide (`offlineDeleteRefusalDecision` reads a refusal).
    static func offlineDeleteAllowed(collection: String, data: [String: Any], sameOrganization: Bool) -> Bool? {
        guard sameOrganization, JobAccessContext.readViewer != nil else { return nil }
        let isManagerSchedule = collection == "managerSiteBookings"
        let type = data["locationType"] as? String
        let jobLocation = type == "project" || type == "small_work"
        let rawJobId = isManagerSchedule ? (jobLocation ? data["locationId"] as? String : nil) : data["projectId"] as? String
        let jobKey = (rawJobId ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if !jobKey.isEmpty && JobAccessContext.jobFieldsById[jobKey] == nil { return nil }
        if isManagerSchedule {
            return JobAccessContext.bookingRemoveAction(
                collection: collection,
                userId: data["userId"] as? String,
                locationType: type,
                locationId: jobLocation ? data["locationId"] as? String : nil
            ) == "delete"
        }
        return JobAccessContext.bookingRemoveAction(collection: collection, projectId: data["projectId"] as? String) == "delete"
    }

    /// The delete and its tombstone in one transaction, after reading both again and asking the rule again.
    /// `nonisolated` so the transaction block never runs on the main actor.
    nonisolated private static func runOfflineDeleteTransaction(
        db: Firestore,
        ref: DocumentReference,
        tombstoneRef: DocumentReference,
        tombstone: RulebookJSONBox,
        documentId: String,
        collection: String,
        fingerprint: String?,
        mayDelete: Bool?,
        timeZone: String
    ) async throws -> String {
        let answer = try await db.runTransaction { transaction, errorPointer -> Any? in
            let liveNow: DocumentSnapshot
            let tombstoneNow: DocumentSnapshot
            do {
                liveNow = try transaction.getDocument(ref)
                tombstoneNow = try transaction.getDocument(tombstoneRef)
            } catch {
                errorPointer?.pointee = error as NSError
                return nil
            }
            let decision = FirebaseBackend.offlineDeleteDecision(
                documentId: documentId,
                collection: collection,
                fingerprint: fingerprint,
                live: liveNow.exists ? liveNow.data() : nil,
                tombstoned: tombstoneNow.exists,
                mayDelete: mayDelete,
                timeZone: timeZone
            )
            guard decision == "apply" else { return decision as NSString }
            transaction.deleteDocument(ref)
            transaction.setData(tombstone.object, forDocument: tombstoneRef)
            return "apply" as NSString
        }
        return (answer as? String) ?? "apply"
    }

    /// The person's timesheets as `{ startDayKey, endDayKey, ...stored fields }` for
    /// `bookingDeleteSignedTimesheetWarning` (`settings` documents `timesheet_*` where `userId ==`). Empty when they
    /// cannot be read (no warning is shown then; the delete never depends on it).
    func signedTimesheetCandidates(organizationId: String, userId: String) async -> [[String: Any]] {
        let orgId = normalizedOrganizationId(organizationId)
        let person = userId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !orgId.isEmpty, !person.isEmpty else { return [] }
        do {
            let snapshot = try await db.collection("organizations").document(orgId).collection("settings")
                .whereField("userId", isEqualTo: person)
                .getDocuments()
            return snapshot.documents
                .filter { $0.documentID.hasPrefix("timesheet_") }
                .compactMap { doc -> [String: Any]? in
                    let data = doc.data()
                    guard let start = data["weekStartKey"] as? String, let end = data["weekEndKey"] as? String else { return nil }
                    var row = (Self.firestoreJSON(data) as? [String: Any]) ?? [:]
                    row["startDayKey"] = start
                    row["endDayKey"] = end
                    return row
                }
        } catch {
            NSLog("SIGNED_TIMESHEET_READ_FAILED error=%@", error.localizedDescription)
            return []
        }
    }
}
