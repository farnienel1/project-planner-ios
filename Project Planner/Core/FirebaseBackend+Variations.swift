//
//  FirebaseBackend+Variations.swift
//  Project Planner
//

import Foundation
import UIKit
import FirebaseAuth
@preconcurrency import FirebaseFirestore
#if canImport(FirebaseStorage)
import FirebaseStorage
#endif

extension FirebaseBackend {
    /// The job a variation belongs to (`parseVariationDocument` → `parentId`, `parentType`), read from
    /// `variations/{id}`, else its `settings/variationItem_{id}` copy. For a notification deep link that names a
    /// variation only (`variationDetail`). Nil when neither copy can be read.
    static func variationParent(
        organizationId: String,
        variationId: String,
        db: Firestore = Firestore.firestore()
    ) async -> (parentId: String, parentType: VariationParentType)? {
        let org = db.collection("organizations").document(normalizedOrganizationId(organizationId))
        let refs = [
            org.collection("variations").document(variationId),
            org.collection("settings").document("variationItem_\(variationId)"),
        ]
        for ref in refs {
            guard let snapshot = try? await ref.getDocument(), let data = snapshot.data(),
                  let variation = VariationCodec.variation(from: data, documentId: variationId),
                  !variation.parentId.isEmpty else { continue }
            return (variation.parentId, variation.parentType)
        }
        return nil
    }

    private func variationsCollection(organizationId: String) -> CollectionReference {
        db.collection("organizations").document(normalizedOrganizationId(organizationId)).collection("variations")
    }

    private func variationTrackerDocument(organizationId: String, parentId: String) -> DocumentReference {
        db.collection("organizations")
            .document(normalizedOrganizationId(organizationId))
            .collection("variationTrackers")
            .document(parentId)
    }

    private func variationTradesDocument(organizationId: String) -> DocumentReference {
        db.collection("organizations")
            .document(normalizedOrganizationId(organizationId))
            .collection("settings")
            .document("variationTrades")
    }

    /// Writable even before `variations` collection rules are published (same pattern as H&S).
    private func variationsFallbackDocument(organizationId: String, parentId: String) -> DocumentReference {
        db.collection("organizations")
            .document(normalizedOrganizationId(organizationId))
            .collection("settings")
            .document("variations_\(parentId)")
    }

    /// One settings document per variation — same collection H&S already writes.
    private func variationItemDocument(organizationId: String, variationId: String) -> DocumentReference {
        db.collection("organizations")
            .document(normalizedOrganizationId(organizationId))
            .collection("settings")
            .document("variationItem_\(variationId)")
    }

    private func settingsCollection(organizationId: String) -> CollectionReference {
        db.collection("organizations")
            .document(normalizedOrganizationId(organizationId))
            .collection("settings")
    }

    func observeVariations(
        organizationId: String,
        parentId: String,
        onChange: @escaping @MainActor ([Variation]) -> Void
    ) -> ListenerRegistration {
        let orgId = normalizedOrganizationId(organizationId)
        let bag = VariationListenerBag()
        let parentIds = variationParentIdForms(parentId)

        bag.add(
            variationsCollection(organizationId: orgId)
                .whereField("parentId", in: parentIds)
                .addSnapshotListener { snapshot, error in
                    if let error {
                        print("❌ [Variations] listen error: \(error.localizedDescription)")
                        Task { @MainActor in
                            bag.receivedCollection = true
                            if bag.receivedFallback || bag.receivedItemDocs {
                                onChange(
                                    mergeVariationSources(
                                        collection: bag.collectionItems,
                                        fallback: bag.fallbackItems,
                                        itemDocs: bag.itemDocItems
                                    )
                                )
                            }
                        }
                        return
                    }
                    guard let snapshot else { return }
                    let parsed = snapshot.documents.compactMap { doc in
                        VariationCodec.variation(from: doc.data(), documentId: doc.documentID)
                    }
                    Task { @MainActor in
                        bag.collectionItems = parsed
                        bag.receivedCollection = true
                        if parsed.isEmpty && !bag.receivedFallback && !bag.receivedItemDocs {
                            return
                        }
                        onChange(
                            mergeVariationSources(
                                collection: bag.collectionItems,
                                fallback: bag.fallbackItems,
                                itemDocs: bag.itemDocItems
                            )
                        )
                    }
                }
        )

        bag.add(
            variationsFallbackDocument(organizationId: orgId, parentId: parentId)
                .addSnapshotListener { snapshot, error in
                    if let error {
                        print("❌ [Variations] fallback listen error: \(error.localizedDescription)")
                        Task { @MainActor in
                            bag.receivedFallback = true
                            onChange(
                                mergeVariationSources(
                                    collection: bag.collectionItems,
                                    fallback: bag.fallbackItems,
                                    itemDocs: bag.itemDocItems
                                )
                            )
                        }
                        return
                    }
                    let parsed = variationsFromFallbackDocument(snapshot?.data())
                    Task { @MainActor in
                        bag.fallbackItems = parsed
                        bag.receivedFallback = true
                        onChange(
                            mergeVariationSources(
                                collection: bag.collectionItems,
                                fallback: bag.fallbackItems,
                                itemDocs: bag.itemDocItems
                            )
                        )
                    }
                }
        )

        bag.add(
            settingsCollection(organizationId: orgId)
                .whereField("recordType", isEqualTo: "variationItem")
                .addSnapshotListener { snapshot, error in
                    if let error {
                        print("❌ [Variations] item-doc listen error: \(error.localizedDescription)")
                        Task { @MainActor in
                            bag.receivedItemDocs = true
                            onChange(
                                mergeVariationSources(
                                    collection: bag.collectionItems,
                                    fallback: bag.fallbackItems,
                                    itemDocs: bag.itemDocItems
                                )
                            )
                        }
                        return
                    }
                    let parsed = (snapshot?.documents ?? []).compactMap { doc -> Variation? in
                        let data = doc.data()
                        guard parentIds.contains((data["parentId"] as? String) ?? "") else { return nil }
                        let rawId = (data["id"] as? String)
                            ?? doc.documentID.replacingOccurrences(of: "variationItem_", with: "")
                        return VariationCodec.variation(from: data, documentId: rawId)
                    }
                    Task { @MainActor in
                        bag.itemDocItems = parsed
                        bag.receivedItemDocs = true
                        onChange(
                            mergeVariationSources(
                                collection: bag.collectionItems,
                                fallback: bag.fallbackItems,
                                itemDocs: bag.itemDocItems
                            )
                        )
                    }
                }
        )

        return bag
    }

    func observeVariationTracker(
        organizationId: String,
        parentId: String,
        parentType: VariationParentType,
        onChange: @escaping @MainActor (VariationTracker) -> Void
    ) -> ListenerRegistration {
        return variationTrackerDocument(organizationId: organizationId, parentId: parentId)
            .addSnapshotListener { snapshot, error in
                if let error {
                    print("❌ [Variations] tracker listen error: \(error.localizedDescription)")
                    return
                }
                let tracker: VariationTracker
                if let data = snapshot?.data() {
                    tracker = VariationCodec.tracker(from: data, parentId: parentId)
                } else {
                    // RULEBOOK 1.63.0: no tracker document reads as on (`parseVariationTrackerDocument`).
                    tracker = VariationCodec.tracker(from: [:], parentId: parentId, parentType: parentType)
                }
                Task { @MainActor in
                    onChange(tracker)
                }
            }
    }

    /// RULEBOOK 1.52.0 §22 (review of web #330): `opened` is the copy the editor opened (nil for a new variation). The
    /// save writes only the fields that differ from it (`variationWriteFields(opened, edited)`), never from the server
    /// copy, so a renumber, a status change or evidence linked meanwhile on another device is never written back. The
    /// settings copy and the log entry get the same changed fields only.
    func saveVariation(_ variation: Variation, opened: Variation? = nil, organizationId: String) async throws {
        guard currentUser != nil else {
            throw NSError(
                domain: "FirebaseBackend",
                code: 401,
                userInfo: [NSLocalizedDescriptionKey: "You must be signed in to save a variation."]
            )
        }
        let resolved = await resolveOrganizationIdForFirebaseWrites(preferredFallback: organizationId)
            ?? normalizedOrganizationId(organizationId)
        guard !resolved.isEmpty else {
            throw NSError(
                domain: "FirebaseBackend",
                code: 400,
                userInfo: [NSLocalizedDescriptionKey: "Organization ID is missing. Open Settings → Force Reload Data, then retry."]
            )
        }
        let orgId: String
        do {
            orgId = try await ensureReadableOrganization(resolved)
        } catch {
            print("⚠️ [Variations] Org root check skipped: \(error.localizedDescription)")
            orgId = resolved
        }
        do {
            try await ensureUserDocumentLinked(organizationId: orgId)
        } catch {
            print("⚠️ [Variations] ensureUserDocumentLinked: \(error.localizedDescription)")
        }
        await repairCurrentUserOrganizationAccess(organizationId: orgId)

        var payload = variation
        payload.orgId = orgId
        // Review of #235: the counters come from `variationTotals`; when the rule does not answer nothing is saved.
        guard payload.totals != nil else { throw CanonicalWriteUnavailableError(function: "variationTotals") }
        payload.recomputeCounts()
        let map = try VariationCodec.firestoreMap(from: payload)
        var openedMap: [String: Any]? = nil
        if var base = opened {
            base.orgId = orgId
            base.recomputeCounts()
            openedMap = try VariationCodec.firestoreMap(from: base)
        }
        // The fields this edit changed (all of them for a new variation).
        var changedKeys: Set<String>? = nil
        if let openedMap {
            guard let write = CanonicalBusinessEngine.peopleDocumentWrite("variationWriteFields", before: openedMap, next: map) else {
                throw CanonicalWriteUnavailableError(function: "variationWriteFields")
            }
            changedKeys = Set(write.setKeys).union(write.removeKeys)
            changedKeys?.remove("updatedAt")
            changedKeys?.remove("updatedByUid")
            if changedKeys?.isEmpty == true { return }
        }

        // Production still denies `variations/{id}` until those rules are published.
        // H&S / deadlines already persist on `settings/{docId}` — that is the success path.
        var lastError: Error?
        var wrote = false

        do {
            try await saveVariationToSettingsFallback(payload, map: map, changedKeys: changedKeys, organizationId: orgId)
            wrote = true
        } catch {
            lastError = error
            print("⚠️ [Variations] Settings log write failed: \(error.localizedDescription)")
        }

        do {
            try await saveVariationItemDocument(payload, map: map, openedMap: openedMap, organizationId: orgId)
            wrote = true
        } catch {
            lastError = lastError ?? error
            print("⚠️ [Variations] Settings item write failed: \(error.localizedDescription)")
        }

        do {
            // RULEBOOK 1.8.0 §1: `variationWriteFields` against the stored copy (line lists with their counters, the
            // status with its history and stamps, the number with its sequence written together; creator, origin and
            // parent never rewritten). A new variation is created whole.
            try await writeOperationsDocument(
                variationsCollection(organizationId: orgId).document(payload.id),
                writeFields: "variationWriteFields",
                base: openedMap
            ) { _ in map }
            wrote = true
        } catch {
            lastError = lastError ?? error
            print("⚠️ [Variations] Collection write skipped: \(error.localizedDescription)")
        }

        guard wrote else {
            throw lastError ?? NSError(
                domain: "FirebaseBackend",
                code: 7,
                userInfo: [NSLocalizedDescriptionKey: "Could not save this variation to Firebase."]
            )
        }
    }

    private func saveVariationToSettingsFallback(
        _ variation: Variation,
        map: [String: Any],
        changedKeys: Set<String>?,
        organizationId: String
    ) async throws {
        let ref = variationsFallbackDocument(organizationId: organizationId, parentId: variation.parentId)
        let existing = try await ref.getDocument()
        let stored = existing.exists ? existing.data() : nil
        // RULEBOOK 1.9.0 §1: `variationLogWriteFields` — the stored entries (each with its id from `variationLogItems`,
        // never random), this entry laid over the one with the same id or appended; never another entry removed and
        // never the log rewritten from a local copy. A new log also carries its parent fields.
        // RULEBOOK 1.52.0 §22: only the changed fields of an existing entry (the whole entry for a new variation).
        var map = map
        if let changedKeys {
            map = map.filter { changedKeys.contains($0.key) || $0.key == "updatedAt" || $0.key == "updatedByUid" }
        }
        map["id"] = variation.id
        guard let set = CanonicalBusinessEngine.variationLogWriteFields(
            stored: stored,
            entry: map,
            parentId: variation.parentId,
            parentType: variation.parentType.rawValue,
            organizationId: organizationId
        ) else {
            throw CanonicalWriteUnavailableError(function: "variationLogWriteFields")
        }
        var fields: [String: Any] = [:]
        for (key, value) in set { fields[key] = ScriptFirestoreValue.native(value) }
        fields["updatedAt"] = Timestamp(date: Date())
        if stored != nil {
            try await ref.updateData(fields)
        } else {
            try await ref.setData(fields, merge: true)
        }
    }

    private func saveVariationItemDocument(
        _ variation: Variation,
        map: [String: Any],
        openedMap: [String: Any]?,
        organizationId: String
    ) async throws {
        func itemCopy(_ fields: [String: Any]) -> [String: Any] {
            var data = fields
            data["recordType"] = "variationItem"
            data["parentId"] = variation.parentId
            data["parentType"] = variation.parentType.rawValue
            data["organizationId"] = organizationId
            return data
        }
        let data = itemCopy(map)
        // RULEBOOK 1.8.0 §1: the settings copy is saved with `variationWriteFields` too (1.52.0: against the opened copy).
        try await writeOperationsDocument(
            variationItemDocument(organizationId: organizationId, variationId: variation.id),
            writeFields: "variationWriteFields",
            base: openedMap.map(itemCopy)
        ) { _ in data }
    }

    /// RULEBOOK 1.27.0 §24 (owner decision 4) `CanonicalBusinessEngine.variationEvidenceRemovalWriteFields`: unlinks one
    /// evidence file and records `{ path, name, removedBy, removedAt }` on the variation's `removedEvidence`, as one
    /// partial update of `variations/{id}` read and written in a transaction (so a file added or removed elsewhere
    /// meanwhile is never lost), then of its `settings/variationItem_{id}` copy (best effort, also a transaction). The
    /// list is always built from the stored document, never from the screen's copy. Writes exactly `evidence`,
    /// `evidenceCount`, `removedEvidence` plus `updatedByUid` and write metadata. Returns whether either document
    /// changed (false when the file is not on the stored variation); throws when nothing was recorded and a write failed.
    @discardableResult
    func recordVariationEvidenceRemoval(variationId: String, evidenceId: String, organizationId: String) async throws -> Bool {
        let orgId = normalizedOrganizationId(organizationId)
        guard !orgId.isEmpty, !variationId.isEmpty, !evidenceId.isEmpty else { return false }
        let uid = currentUser?.uid ?? ""
        let removedAt = Timestamp(date: Date())
        let refs = [
            variationsCollection(organizationId: orgId).document(variationId),
            variationItemDocument(organizationId: orgId, variationId: variationId),
        ]
        var changed = false
        var firstError: Error?
        var failures = 0
        for ref in refs {
            do {
                if try await Self.runVariationEvidenceRemoval(
                    db: db,
                    ref: ref,
                    variationId: variationId,
                    evidenceId: evidenceId,
                    userId: uid,
                    removedAt: removedAt
                ) {
                    changed = true
                }
            } catch {
                failures += 1
                firstError = firstError ?? error
                print("⚠️ [Variations] evidence removal not recorded on \(ref.path): \(error.localizedDescription)")
            }
        }
        // Nothing recorded anywhere and a write failed: throw, so the caller keeps the file and never deletes it.
        if !changed, failures > 0, let firstError { throw firstError }
        return changed
    }

    /// One document of `recordVariationEvidenceRemoval`: read, `variationEvidenceRemovalWriteFields`, partial update, in
    /// one transaction. False when the document is missing or the file is not on it. `nonisolated` so the transaction
    /// block never runs on the main actor.
    nonisolated private static func runVariationEvidenceRemoval(
        db: Firestore,
        ref: DocumentReference,
        variationId: String,
        evidenceId: String,
        userId: String,
        removedAt: Timestamp
    ) async throws -> Bool {
        let answer = try await db.runTransaction { transaction, errorPointer -> Any? in
            let snapshot: DocumentSnapshot
            do {
                snapshot = try transaction.getDocument(ref)
            } catch {
                errorPointer?.pointee = error as NSError
                return nil
            }
            guard let stored = snapshot.data() else { return NSNumber(value: false) }
            guard let write = CanonicalBusinessEngine.variationEvidenceRemovalWriteFields(
                stored: stored,
                evidenceId: evidenceId,
                removedBy: userId,
                removedAt: removedAt,
                variationId: variationId
            ) else {
                errorPointer?.pointee = CanonicalWriteUnavailableError(function: "variationEvidenceRemovalWriteFields") as NSError
                return nil
            }
            guard var fields = write else { return NSNumber(value: false) }
            if !userId.isEmpty { fields["updatedByUid"] = userId }
            transaction.updateData(WriteMetadata.stamped(fields, userId: userId.isEmpty ? nil : userId), forDocument: ref)
            return NSNumber(value: true)
        }
        return (answer as? NSNumber)?.boolValue ?? false
    }

    // MARK: - VO tracker order (owner decision 23 Nov: drag on the iPhone, the same save as web)

    /// RULEBOOK 1.52.0 / 1.63.0 §22, web `applyVariationOrder` (`lib/variations/variationStorage.ts`): saves a new
    /// tracker order. The job's `variations` documents are read first and the save is refused
    /// (`VARIATION_RENUMBER_STALE_MESSAGE`) when one appeared since the screen loaded `baseRows`. An Open variation that
    /// still stores `voNumberLocked: true` (`variationStaleNumberLocks`) is unlocked first, each in its own small
    /// transaction (the rules read the stored lock). Then, in one transaction, the tracker and every base row with a
    /// `variations/{id}` document are read as stored; the save is refused when they changed
    /// (`variationRenumberConflict`), when the order is locked or a pinned row would move (`variationRenumberPlan`
    /// `refused`), or when a changed row has only its settings copies (`variationRenumberMissingRefusal`); otherwise
    /// each changed row is written with `variationRenumberWriteFields` and the tracker version goes up
    /// (`variationTrackerWriteFields` `renumbered`). Then the `settings/variationItem_{id}` copy and the settings log
    /// entry of each written row get the same numbers; a copy that fails is returned in `copiesFailed`, never swallowed.
    /// Online only (`UnlistedOfflineAction.renumberVariations`): the caller checks before calling.
    func applyVariationOrder(
        parentId: String,
        parentType: VariationParentType,
        order: [String],
        baseRows: [Variation],
        organizationId: String
    ) async throws -> VariationOrderSaveOutcome {
        let orgId = normalizedOrganizationId(organizationId)
        guard !orgId.isEmpty else { throw VariationOrderSaveError.refused("Organization ID is missing.") }
        let uid = currentUser?.uid ?? ""
        let collection = variationsCollection(organizationId: orgId)
        // A variation added since the screen loaded is not in `baseRows` (web: `readCollectionVariations`, a read
        // that fails reads as none).
        let currentDocs = (try? await collection.whereField("parentId", in: variationParentIdForms(parentId)).getDocuments())?.documents ?? []
        let current = currentDocs.compactMap { VariationCodec.variation(from: $0.data(), documentId: $0.documentID) }
        let baseIds = Set(baseRows.map { $0.id.lowercased() })
        if current.contains(where: { !baseIds.contains($0.id.lowercased()) }) {
            throw VariationOrderSaveError.changed(CanonicalBusinessEngine.variationRenumberStaleMessage)
        }
        guard let staleLocks = CanonicalBusinessEngine.variationStaleNumberLocks(rows: current.map(\.rulebookInput)) else {
            throw CanonicalWriteUnavailableError(function: "variationStaleNumberLocks")
        }
        for id in staleLocks {
            try await Self.runVariationStaleLockClear(db: db, ref: collection.document(id), variationId: id, userId: uid)
        }
        let collectionIds = Set(currentDocs.map { $0.documentID.lowercased() })
        let now = Timestamp(date: Date())
        let answer = try await Self.runVariationOrderTransaction(
            db: db,
            trackerRef: variationTrackerDocument(organizationId: orgId, parentId: parentId),
            collection: collection,
            parentId: parentId,
            order: order,
            baseRows: baseRows,
            collectionIds: collectionIds,
            userId: uid,
            now: now
        )

        var copiesFailed: [String] = []
        for write in answer.writes {
            let itemRef = variationItemDocument(organizationId: orgId, variationId: write.id)
            do {
                let item = try await itemRef.getDocument()
                if let data = item.data() {
                    let to = (write.set["voNumber"] as? String) ?? (data["voNumber"] as? String) ?? ""
                    let sequence = (write.set["sequence"] as? Int)
                        ?? (write.set["sequence"] as? NSNumber)?.intValue
                        ?? (data["sequence"] as? NSNumber)?.intValue ?? 0
                    guard let itemWrite = CanonicalBusinessEngine.variationRenumberWriteFields(stored: data, to: to, sequence: sequence, at: now, byUid: uid) else {
                        throw CanonicalWriteUnavailableError(function: "variationRenumberWriteFields")
                    }
                    if var fields = itemWrite {
                        fields["updatedByUid"] = uid
                        try await itemRef.updateData(WriteMetadata.stamped(fields, userId: uid.isEmpty ? nil : uid))
                    }
                }
            } catch {
                copiesFailed.append(write.id)
                print("⚠️ [Variations] a renumbered settings copy did not save: \(error.localizedDescription)")
            }
            do {
                var merged = answer.stored[write.id] ?? [:]
                for (key, value) in write.set { merged[key] = value }
                guard var next = VariationCodec.variation(from: merged, documentId: write.id) else {
                    throw CanonicalWriteUnavailableError(function: "parseVariationDocument")
                }
                if let base = baseRows.first(where: { $0.id == write.id }) {
                    if !base.parentId.isEmpty { next.parentId = base.parentId }
                    next.parentType = base.parentType
                }
                if next.parentId.isEmpty { next.parentId = parentId; next.parentType = parentType }
                let map = try VariationCodec.firestoreMap(from: next)
                try await saveVariationToSettingsFallback(next, map: map, changedKeys: nil, organizationId: orgId)
            } catch {
                if !copiesFailed.contains(write.id) { copiesFailed.append(write.id) }
                print("⚠️ [Variations] a renumbered settings log entry did not save: \(error.localizedDescription)")
            }
        }
        let changed = answer.planRows.filter(\.changed).map { (id: $0.id, from: $0.from, to: $0.to) }
        return VariationOrderSaveOutcome(changed: changed, copiesFailed: copiesFailed)
    }

    /// One stale number lock (1.63.0): re-read the variation and clear `voNumberLocked` only while it is still Open with
    /// the lock set, so a variation submitted on another device meanwhile keeps its lock (review of web #388).
    nonisolated private static func runVariationStaleLockClear(db: Firestore, ref: DocumentReference, variationId: String, userId: String) async throws {
        _ = try await db.runTransaction { transaction, errorPointer -> Any? in
            let snapshot: DocumentSnapshot
            do {
                snapshot = try transaction.getDocument(ref)
            } catch {
                errorPointer?.pointee = error as NSError
                return nil
            }
            guard let data = snapshot.data(),
                  let fresh = VariationCodec.variation(from: data, documentId: variationId) else { return nil }
            guard let stale = CanonicalBusinessEngine.variationStaleNumberLocks(rows: [fresh.rulebookInput]) else {
                errorPointer?.pointee = CanonicalWriteUnavailableError(function: "variationStaleNumberLocks") as NSError
                return nil
            }
            guard !stale.isEmpty else { return nil }
            var fields: [String: Any] = ["voNumberLocked": false]
            if !userId.isEmpty { fields["updatedByUid"] = userId }
            transaction.updateData(WriteMetadata.stamped(fields, userId: userId.isEmpty ? nil : userId), forDocument: ref)
            return nil
        }
    }

    /// The save's transaction (see `applyVariationOrder`). `nonisolated` so the block never runs on the main actor.
    nonisolated private static func runVariationOrderTransaction(
        db: Firestore,
        trackerRef: DocumentReference,
        collection: CollectionReference,
        parentId: String,
        order: [String],
        baseRows: [Variation],
        collectionIds: Set<String>,
        userId: String,
        now: Timestamp
    ) async throws -> VariationOrderTransactionAnswer {
        let answer = try await db.runTransaction { transaction, errorPointer -> Any? in
            func fail(_ error: Error) -> Any? {
                errorPointer?.pointee = error as NSError
                return nil
            }
            let trackerSnap: DocumentSnapshot
            do {
                trackerSnap = try transaction.getDocument(trackerRef)
            } catch {
                return fail(error)
            }
            var stored: [String: [String: Any]] = [:]
            var live: [Variation] = []
            for row in baseRows {
                guard collectionIds.contains(row.id.lowercased()) else {
                    live.append(row)
                    continue
                }
                let snap: DocumentSnapshot
                do {
                    snap = try transaction.getDocument(collection.document(row.id))
                } catch {
                    return fail(error)
                }
                if let data = snap.data(), let parsed = VariationCodec.variation(from: data, documentId: row.id) {
                    stored[row.id] = data
                    live.append(parsed)
                } else {
                    live.append(row)
                }
            }
            guard let conflict = CanonicalBusinessEngine.variationRenumberConflict(
                base: baseRows.map(\.rulebookInput),
                live: live.map(\.rulebookInput)
            ) else {
                return fail(CanonicalWriteUnavailableError(function: "variationRenumberConflict"))
            }
            if conflict { return fail(VariationOrderSaveError.changed(CanonicalBusinessEngine.variationRenumberStaleMessage)) }
            let trackerData = trackerSnap.data()
            let tracker = VariationCodec.tracker(from: trackerData ?? [:], parentId: parentId)
            guard let plan = CanonicalBusinessEngine.variationRenumberPlanChanges(
                rows: live.map(\.rulebookInput),
                order: order,
                prefix: tracker.prefix,
                padding: tracker.padding,
                orderLocked: tracker.orderLocked
            ) else {
                return fail(CanonicalWriteUnavailableError(function: "variationRenumberPlan"))
            }
            // A pinned row never moves; a locked order never changes (`VARIATION_PINNED_MESSAGE` /
            // `VARIATION_ORDER_LOCKED_MESSAGE`).
            if let refused = plan.refused, !refused.isEmpty { return fail(VariationOrderSaveError.refused(refused)) }
            guard let missing = CanonicalBusinessEngine.variationRenumberMissingRefusal(changes: plan.changes, storedIds: Array(stored.keys)) else {
                return fail(CanonicalWriteUnavailableError(function: "variationRenumberMissingRefusal"))
            }
            if let missing { return fail(VariationOrderSaveError.refused(missing)) }
            var writes: [(id: String, set: [String: Any])] = []
            for change in plan.changes {
                guard let data = stored[change.id] else { continue }
                guard let write = CanonicalBusinessEngine.variationRenumberWriteFields(
                    stored: data, to: change.to, sequence: change.sequence, at: now, byUid: userId
                ) else {
                    return fail(CanonicalWriteUnavailableError(function: "variationRenumberWriteFields"))
                }
                guard let set = write else { continue }
                var fields = set
                if !userId.isEmpty { fields["updatedByUid"] = userId }
                transaction.updateData(WriteMetadata.stamped(fields, userId: userId.isEmpty ? nil : userId), forDocument: collection.document(change.id))
                writes.append((id: change.id, set: set))
            }
            if let trackerData {
                guard let renumbered = CanonicalBusinessEngine.variationTrackerRenumberedFields(stored: trackerData) else {
                    return fail(CanonicalWriteUnavailableError(function: "variationTrackerWriteFields"))
                }
                if let fields = renumbered { transaction.updateData(fields, forDocument: trackerRef) }
            }
            return VariationOrderTransactionAnswer(planRows: plan.rows, writes: writes, stored: stored)
        }
        guard let result = answer as? VariationOrderTransactionAnswer else {
            throw CanonicalWriteUnavailableError(function: "variationRenumberPlan")
        }
        return result
    }

    /// `settings/variationTrades` through `parseVariationTrades` (1.9.0). Picker suggestions: read when the picker
    /// opens (`LIVE_COLLECTIONS` `listen: false`).
    func loadCustomVariationTrades(organizationId: String) async -> [String] {
        let snap = try? await variationTradesDocument(organizationId: organizationId).getDocument()
        return CanonicalBusinessEngine.parseVariationTrades(snap?.data()) ?? []
    }

    /// Adds one trade with `variationTradesWriteFields` against the stored list (only what the user added, so a
    /// stale list never drops another device's trade). A standard trade is not stored (app picker list).
    func addCustomVariationTrade(_ trade: String, organizationId: String) async {
        let trimmed = trade.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if VariationTrades.standard.contains(where: { $0.lowercased() == trimmed.lowercased() }) { return }
        let ref = variationTradesDocument(organizationId: organizationId)
        guard let snap = try? await ref.getDocument() else { return }
        let stored = snap.exists ? snap.data() : nil
        guard let answer = CanonicalBusinessEngine.variationTradesWriteFields(stored: stored, add: [trimmed]),
              let trades = answer else { return }
        if snap.exists {
            try? await ref.updateData(["customTrades": trades])
        } else {
            try? await ref.setData(["customTrades": trades], merge: true)
        }
    }

    func countOpenVariations(organizationId: String, parentId: String) async -> Int {
        let orgId = normalizedOrganizationId(organizationId)
        let parentIds = variationParentIdForms(parentId)
        async let collectionSnap = variationsCollection(organizationId: orgId)
            .whereField("parentId", in: parentIds)
            .getDocuments()
        async let fallbackSnap = variationsFallbackDocument(organizationId: orgId, parentId: parentId)
            .getDocument()
        async let itemSnap = settingsCollection(organizationId: orgId)
            .whereField("recordType", isEqualTo: "variationItem")
            .getDocuments()
        let collectionItems = ((try? await collectionSnap)?.documents ?? []).compactMap {
            VariationCodec.variation(from: $0.data(), documentId: $0.documentID)
        }
        let fallbackItems = variationsFromFallbackDocument((try? await fallbackSnap)?.data())
        let itemDocs = ((try? await itemSnap)?.documents ?? []).compactMap { doc -> Variation? in
            let data = doc.data()
            guard parentIds.contains((data["parentId"] as? String) ?? "") else { return nil }
            let rawId = (data["id"] as? String)
                ?? doc.documentID.replacingOccurrences(of: "variationItem_", with: "")
            return VariationCodec.variation(from: data, documentId: rawId)
        }
        // RULEBOOK 1.23.0 §22 `CanonicalBusinessEngine.openVariationCount`: not deleted, status `open` (any case).
        let merged = mergeVariationSources(collection: collectionItems, fallback: fallbackItems, itemDocs: itemDocs)
        return CanonicalBusinessEngine.openVariationCount(merged.map { ["isDeleted": $0.isDeleted, "status": $0.status.rawValue] }) ?? 0
    }

    #if canImport(FirebaseStorage)
    func uploadVariationEvidence(
        data: Data,
        fileName: String,
        contentType: String,
        organizationId: String,
        parentId: String,
        variationId: String,
        evidenceId: String
    ) async throws -> (storagePath: String, downloadURL: String) {
        guard let userId = currentUser?.uid else {
            throw NSError(domain: "FirebaseBackend", code: 401, userInfo: [NSLocalizedDescriptionKey: "User not authenticated"])
        }
        let orgId = normalizedOrganizationId(
            await resolveOrganizationIdForFirebaseWrites(preferredFallback: organizationId)
                ?? organizationId
        )
        guard !orgId.isEmpty else {
            throw NSError(
                domain: "FirebaseBackend",
                code: 400,
                userInfo: [NSLocalizedDescriptionKey: "Organization ID is missing. Open Settings → Force Reload Data, then retry."]
            )
        }
        do {
            try await ensureUserDocumentLinked(organizationId: orgId)
        } catch {
            print("⚠️ [Variations] upload ensureUserDocumentLinked: \(error.localizedDescription)")
        }
        let prepared = try StorageUploadPolicy.prepareFileData(
            data,
            originalFileName: fileName,
            declaredContentType: contentType,
            family: .variationEvidence,
            uid: userId,
            unixMilliseconds: StorageUploadPolicy.unixMillisecondsNow()
        )
        let folderId = parentId.isEmpty ? variationId : parentId
        // Health-and-safety evidence prefix first, then the variations object path.
        let paths = [
            "organizations/\(orgId)/healthSafety/\(folderId)/variationEvidence/\(prepared.objectName)",
            "organizations/\(orgId)/variations/\(variationId)/\(prepared.objectName)"
        ]
        var lastError: Error?
        // RULEBOOK 1.50.0 §24: one type per upload — the type `uploadAllowed` read from the bytes. The retry with
        // `application/octet-stream` is gone (the rules refuse it, and so does the rulebook). A refusal by the
        // rulebook is final: it is the same for both paths.
        for path in paths {
            let contentType = try StorageUploadPolicy.checkedUploadContentType(
                storagePath: path, data: prepared.data, declaredContentType: prepared.contentType
            )
            do {
                let result = try await putVariationEvidenceData(prepared.data, path: path, contentType: contentType)
                print("✅ [Variations] Evidence uploaded to \(path)")
                return result
            } catch {
                lastError = error
                print("⚠️ [Variations] Storage path failed \(path): \(error.localizedDescription)")
                // 17 Nov bug: a stall (no answer from File storage) is not a refusal — trying the second path would
                // only wait another minute. Stop and show why it stalled.
                if (error as NSError).domain == Self.variationUploadStallDomain { throw error }
            }
        }
        throw lastError ?? NSError(
            domain: "FirebaseBackend",
            code: 403,
            userInfo: [NSLocalizedDescriptionKey: "Could not upload evidence to Firebase Storage."]
        )
    }

    /// RULEBOOK 1.52.0 §24: one upload with a timeout — cancelled after `variationUploadStallSeconds` without
    /// progress or `variationUploadTotalSeconds` in all — and the download URL read with a bounded retry. A `gs://`
    /// address is never stored: when no download URL can be read the object just uploaded is deleted again (its
    /// uploader, inside the undo window) and the upload fails with the real error.
    private func putVariationEvidenceData(
        _ data: Data,
        path: String,
        contentType: String
    ) async throws -> (storagePath: String, downloadURL: String) {
        let storageRef = storage.reference().child(path)
        let metadata = StorageMetadata()
        metadata.contentType = contentType
        let watch = VariationUploadWatch()
        do {
            _ = try await putWatched(storageRef: storageRef, data: data, metadata: metadata, watch: watch)
        } catch {
            guard watch.timedOut else { throw error }
            // Review of #261: past the 5-minute overall limit the upload was still moving, so it is not a stall.
            if watch.timedOutOverall {
                throw NSError(
                    domain: Self.variationUploadStallDomain,
                    code: 408,
                    userInfo: [NSLocalizedDescriptionKey: "The evidence upload took more than 5 minutes, so it was cancelled and nothing was saved. Check the connection, or add a smaller file."]
                )
            }
            // A refusal by the Storage rules comes back at once as an error; a stall means File storage never answered
            // (the SDK keeps retrying). Ask Storage one quick question about the same path to say which (17 Nov).
            throw NSError(
                domain: Self.variationUploadStallDomain,
                code: 408,
                userInfo: [NSLocalizedDescriptionKey: await Self.variationUploadStallReason(storageRef: storageRef, sentBytes: watch.sentBytes)]
            )
        }
        return try await variationEvidenceDownloadURL(storageRef: storageRef, path: path)
    }

    static let variationUploadStallDomain = "VariationUploadStall"

    /// Why an evidence upload stalled: refused (storage/unauthorized), no answer at all, or stopped mid-file.
    static func variationUploadStallReason(storageRef: StorageReference, sentBytes: Int64) async -> String {
        let probe = await variationStallProbe(storageRef: storageRef)
        if let probe = probe as NSError? {
            if probe.domain == StorageErrorDomain,
               let code = StorageErrorCode(rawValue: probe.code),
               code == .unauthorized || code == .unauthenticated {
                return "File storage refused this upload: your account may not add evidence to this job. Ask an admin to check your access."
            }
            let notFound = probe.domain == StorageErrorDomain && StorageErrorCode(rawValue: probe.code) == .objectNotFound
            if !notFound {
                return "File storage did not answer for a minute, so the upload was cancelled and nothing was saved. Check the internet connection and add the file again."
            }
        }
        return sentBytes > 0
            ? "The file stopped sending for a minute, so the upload was cancelled and nothing was saved. Check the connection and add the file again."
            : "File storage is reachable, but this upload got no answer for a minute, so it was cancelled and nothing was saved. Add the file again; if it happens again, tell support (upload never started)."
    }

    /// The first of: File storage's answer to one metadata read of the same path, or 10 seconds. Review of #261: a
    /// task group waited for the read itself, which the SDK keeps retrying (up to two minutes) and cannot be cancelled,
    /// so the message could take three minutes; this resumes once, on whichever comes first, and never waits again.
    nonisolated private static func variationStallProbe(storageRef: StorageReference) async -> Error? {
        await withCheckedContinuation { (continuation: CheckedContinuation<Error?, Never>) in
            let once = VariationResumeOnce()
            storageRef.getMetadata { _, error in
                if once.claim() { continuation.resume(returning: error) }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 10) {
                if once.claim() { continuation.resume(returning: NSError(domain: "VariationUploadStall", code: -1)) }
            }
        }
    }

    private func putWatched(
        storageRef: StorageReference,
        data: Data,
        metadata: StorageMetadata,
        watch: VariationUploadWatch
    ) async throws -> StorageMetadata {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<StorageMetadata, Error>) in
            let task = storageRef.putData(data, metadata: metadata) { metadata, error in
                guard watch.finish() else { return }
                // Review of #261 (as web #388): a finished upload always wins. When the watchdog gave up but the file
                // still finished (its cancel came too late), it is returned and linked — never reported as a timeout
                // with the file left in Storage unlinked.
                if error == nil, let metadata {
                    continuation.resume(returning: metadata)
                } else if watch.timedOut {
                    continuation.resume(throwing: NSError(
                        domain: "FirebaseBackend",
                        code: 408,
                        userInfo: [NSLocalizedDescriptionKey: "The upload timed out. Check the connection and try again."]
                    ))
                } else if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(throwing: NSError(domain: "StorageReference", code: -1, userInfo: [NSLocalizedDescriptionKey: "Unknown error"]))
                }
            }
            task.observe(.progress) { snapshot in
                watch.touch(sentBytes: snapshot.progress?.completedUnitCount ?? 0)
            }
            Task {
                while !watch.isFinished {
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                    if watch.shouldGiveUp(stallSeconds: Self.variationUploadStallSeconds, totalSeconds: Self.variationUploadTotalSeconds) {
                        task.cancel()
                        break
                    }
                }
            }
        }
    }

    private func variationEvidenceDownloadURL(storageRef: StorageReference, path: String) async throws -> (storagePath: String, downloadURL: String) {
        var lastError: Error?
        for attempt in 0..<3 {
            do {
                let url = try await storageRef.downloadURL().absoluteString
                return (path, url)
            } catch {
                lastError = error
                try? await Task.sleep(nanoseconds: UInt64(attempt + 1) * 1_000_000_000)
            }
        }
        // No download URL: never store `gs://`. Remove the object just uploaded and fail the upload.
        try? await storageRef.delete()
        throw lastError ?? NSError(
            domain: "FirebaseBackend",
            code: 500,
            userInfo: [NSLocalizedDescriptionKey: "The file uploaded but its link could not be read. Please try again."]
        )
    }

    static let variationUploadStallSeconds: TimeInterval = 60
    static let variationUploadTotalSeconds: TimeInterval = 300

    /// RULEBOOK 1.52.0 §24 `CanonicalBusinessEngine.variationEvidenceAddWriteFields`: links uploaded files to the
    /// variation in a transaction on `variations/{id}` (the stored list plus each new entry, up to 10 files; a file
    /// someone else linked meanwhile is kept), then on its `settings/variationItem_{id}` copy (also a transaction, best
    /// effort). Returns the keys (storage path, else id) the variation now holds of `entries` — added or already
    /// linked — and the refused ones (the 10-file limit). Throws when the link on `variations/{id}` failed.
    func linkVariationEvidence(
        variationId: String,
        entries: [VariationEvidenceItem],
        organizationId: String
    ) async throws -> (linked: Set<String>, refused: Set<String>) {
        let orgId = normalizedOrganizationId(organizationId)
        let uid = currentUser?.uid ?? ""
        let rows: [[String: Any]] = entries.map { item in
            let stamp = Timestamp(date: item.uploadedAt)
            return [
                "id": item.id,
                "fileName": item.fileName,
                "contentType": item.contentType,
                "sizeBytes": item.sizeBytes,
                "storagePath": item.storagePath,
                "downloadURL": item.downloadURL,
                "uploadedByUid": item.uploadedByUid,
                "uploadedAt": ["seconds": stamp.seconds, "nanoseconds": stamp.nanoseconds],
            ]
        }
        let main = variationsCollection(organizationId: orgId).document(variationId)
        let mainOutcome = try await Self.runVariationEvidenceLink(db: db, ref: main, entries: rows, userId: uid)
        // The settings copy: best effort when `variations/{id}` exists; the answer when only the copy exists (review of
        // #235: a variation saved only as its settings copy reports what was linked there, not "did not upload").
        var copyOutcome: (added: [String], alreadyLinked: [String], refused: [String])?
        do {
            copyOutcome = try await Self.runVariationEvidenceLink(
                db: db,
                ref: variationItemDocument(organizationId: orgId, variationId: variationId),
                entries: rows,
                userId: uid
            )
        } catch {
            if mainOutcome == nil { throw error }
            print("⚠️ [Variations] evidence link on the settings copy skipped: \(error.localizedDescription)")
        }
        guard let outcome = mainOutcome ?? copyOutcome else {
            throw NSError(
                domain: "FirebaseBackend",
                code: 404,
                userInfo: [NSLocalizedDescriptionKey: "This variation was not found, so the files could not be added. Save it and try again."]
            )
        }
        return (Set(outcome.added + outcome.alreadyLinked), Set(outcome.refused))
    }

    /// One document of `linkVariationEvidence`: read, `variationEvidenceAddWriteFields`, partial update, in one
    /// transaction. Nil when the document is missing.
    nonisolated private static func runVariationEvidenceLink(
        db: Firestore,
        ref: DocumentReference,
        entries: [[String: Any]],
        userId: String
    ) async throws -> (added: [String], alreadyLinked: [String], refused: [String])? {
        let answer = try await db.runTransaction { transaction, errorPointer -> Any? in
            let snapshot: DocumentSnapshot
            do {
                snapshot = try transaction.getDocument(ref)
            } catch {
                errorPointer?.pointee = error as NSError
                return nil
            }
            guard let stored = snapshot.data() else { return ["missing": true] as [String: Any] }
            guard let result = CanonicalBusinessEngine.variationEvidenceAddWriteFields(stored: stored, entries: entries) else {
                errorPointer?.pointee = CanonicalWriteUnavailableError(function: "variationEvidenceAddWriteFields") as NSError
                return nil
            }
            if let set = result.set {
                var fields: [String: Any] = [:]
                for (key, value) in set { fields[key] = ScriptFirestoreValue.native(value) }
                if !userId.isEmpty { fields["updatedByUid"] = userId }
                transaction.updateData(WriteMetadata.stamped(fields, userId: userId.isEmpty ? nil : userId), forDocument: ref)
            }
            return ["added": result.added, "alreadyLinked": result.alreadyLinked, "refused": result.refused] as [String: Any]
        }
        let map = answer as? [String: Any] ?? [:]
        if map["missing"] as? Bool == true { return nil }
        func strings(_ key: String) -> [String] { (map[key] as? [String]) ?? [] }
        return (strings("added"), strings("alreadyLinked"), strings("refused"))
    }

    /// RULEBOOK 1.52.0 §24: the evidence keys (storage path, else id) on the stored variation, read from the server
    /// (never the cache). Nil when the read failed — then no uploaded file may be deleted.
    func storedVariationEvidenceKeys(variationId: String, organizationId: String) async -> Set<String>? {
        let orgId = normalizedOrganizationId(organizationId)
        do {
            var snapshot = try await variationsCollection(organizationId: orgId).document(variationId).getDocument(source: .server)
            if !snapshot.exists {
                // A variation saved only as its settings copy: its evidence is there.
                snapshot = try await variationItemDocument(organizationId: orgId, variationId: variationId).getDocument(source: .server)
            }
            // Neither document: no answer, so no file is deleted.
            guard snapshot.exists,
                  let keys = CanonicalBusinessEngine.variationEvidenceKeys(stored: snapshot.data()) else { return nil }
            return Set(keys)
        } catch {
            return nil
        }
    }

    /// Deletes an evidence object this device just uploaded and could not link (its uploader, inside the undo window).
    func deleteUnlinkedVariationEvidence(storagePath: String) async {
        guard !storagePath.isEmpty else { return }
        try? await storage.reference().child(storagePath).delete()
    }

    /// RULEBOOK 1.25.0 §24 `CanonicalBusinessEngine.fileDeletePermission`: deletes the evidence object only for an admin of
    /// this organisation or its uploader within the undo window; otherwise nothing is deleted and the caller unlinks it
    /// and keeps the file. A refused or failed delete is reported, never swallowed.
    func deleteVariationEvidenceFile(
        storagePath: String,
        viewerRole: CanonicalBusinessEngine.CanonicalStaffAccountRole,
        uploadedAt: Date?
    ) async -> StoredFileRemoval {
        guard !storagePath.isEmpty else { return .kept }
        let permission = CanonicalBusinessEngine.fileDeletePermission(
            storagePath: storagePath,
            organizationId: currentOrganization?.firestoreDocumentId ?? "",
            viewerUserId: currentUser?.uid ?? "",
            viewerRole: viewerRole,
            uploadedAt: uploadedAt
        )
        guard permission.allowed else { return .kept }
        do {
            try await storage.reference().child(storagePath).delete()
            return .deleted
        } catch {
            print("⚠️ [Variations] evidence delete refused or failed for \(storagePath): \(error.localizedDescription)")
            return .failed(error.localizedDescription)
        }
    }
    #else
    func uploadVariationEvidence(
        data: Data,
        fileName: String,
        contentType: String,
        organizationId: String,
        parentId: String,
        variationId: String,
        evidenceId: String
    ) async throws -> (storagePath: String, downloadURL: String) {
        throw NSError(
            domain: "FirebaseBackend",
            code: 501,
            userInfo: [NSLocalizedDescriptionKey: "Firebase Storage is not available in this build."]
        )
    }

    func deleteVariationEvidenceFile(
        storagePath: String,
        viewerRole: CanonicalBusinessEngine.CanonicalStaffAccountRole,
        uploadedAt: Date?
    ) async -> StoredFileRemoval { .kept }

    func linkVariationEvidence(
        variationId: String,
        entries: [VariationEvidenceItem],
        organizationId: String
    ) async throws -> (linked: Set<String>, refused: Set<String>) {
        throw NSError(domain: "FirebaseBackend", code: 501, userInfo: [NSLocalizedDescriptionKey: "Firebase Storage is not available in this build."])
    }

    func storedVariationEvidenceKeys(variationId: String, organizationId: String) async -> Set<String>? { nil }

    func deleteUnlinkedVariationEvidence(storagePath: String) async {}
    #endif
}

/// RULEBOOK 1.52.0 §24: progress and finish of one evidence upload, for its timeout.
nonisolated final class VariationUploadWatch: @unchecked Sendable {
    private let lock = NSLock()
    private let started = Date()
    private var lastProgress = Date()
    private var finished = false
    private var didTimeOut = false
    private var overall = false

    /// Read under the lock (review of #235).
    var timedOut: Bool {
        lock.lock(); defer { lock.unlock() }
        return didTimeOut
    }

    /// True when it gave up on the overall limit (`variationUploadTotalSeconds`) rather than on a stall.
    var timedOutOverall: Bool {
        lock.lock(); defer { lock.unlock() }
        return overall
    }

    private var sent: Int64 = 0

    /// Bytes the SDK reported as sent (for the stall reason).
    var sentBytes: Int64 {
        lock.lock(); defer { lock.unlock() }
        return sent
    }

    func touch(sentBytes: Int64 = 0) {
        lock.lock(); lastProgress = Date(); sent = max(sent, sentBytes); lock.unlock()
    }

    /// True the first time only (the upload's completion runs once).
    func finish() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if finished { return false }
        finished = true
        return true
    }

    var isFinished: Bool {
        lock.lock(); defer { lock.unlock() }
        return finished
    }

    func shouldGiveUp(stallSeconds: TimeInterval, totalSeconds: TimeInterval) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !finished else { return false }
        let now = Date()
        let stalled = now.timeIntervalSince(lastProgress) > stallSeconds
        let tooLong = now.timeIntervalSince(started) > totalSeconds
        if stalled || tooLong {
            didTimeOut = true
            overall = tooLong && !stalled
            return true
        }
        return false
    }
}

/// Resumes a continuation once, whichever callback comes first.
nonisolated final class VariationResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false

    func claim() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if claimed { return false }
        claimed = true
        return true
    }
}

/// RULEBOOK 1.8.0 §1 "Job keys": variations name the job by its stored document id. iOS builds before 1.8.0 wrote
/// the in-app UUID text, which differs for a lower-case or non-UUID job id, so both forms are matched on read.
nonisolated private func variationParentIdForms(_ parentId: String) -> [String] {
    let stored = parentId.trimmingCharacters(in: .whitespacesAndNewlines)
    let legacy = Manager.stableId(forFirestoreDocumentId: stored).uuidString
    return stored == legacy || stored.isEmpty ? [stored] : [stored, legacy]
}

nonisolated private func fallbackItemMaps(from data: [String: Any]) -> [[String: Any]] {
    if let items = data["items"] as? [[String: Any]] {
        return items
    }
    if let items = data["items"] as? [String: Any] {
        return items.compactMap { id, value in
            guard var row = value as? [String: Any] else { return nil }
            if ((row["id"] as? String) ?? "").isEmpty {
                row["id"] = id
            }
            return row
        }
    }
    return []
}

nonisolated private func variationsFromFallbackDocument(_ data: [String: Any]?) -> [Variation] {
    guard let data else { return [] }
    // RULEBOOK 1.9.0: each entry's id from `variationLogItems` (stored `id`, map key, or the derived
    // `variationLogItemId` — never random), read with `parseVariationDocument`.
    let parentId = (data["parentId"] as? String) ?? ""
    if let items = CanonicalBusinessEngine.variationLogItems(parentId: parentId, data: data) {
        return items.compactMap { item in
            var row = (ScriptFirestoreValue.native(item.row) as? [String: Any]) ?? item.row
            row["id"] = item.id
            return VariationCodec.variation(from: row, documentId: item.id)
        }
    }
    return fallbackItemMaps(from: data).compactMap { row in
        VariationCodec.variation(from: row, documentId: (row["id"] as? String) ?? "")
    }
}

/// RULEBOOK 1.23.0 §22 `CanonicalBusinessEngine.mergeVariationSources`: one list from the collection and the older
/// fallbacks, ids without case, the newer `updatedAtMs` winning (the collection on a tie), in first-appearance order.
/// Rows go in tagged (`_i`) so the answer maps back to these values. With no script answer the collection rows only.
nonisolated private func mergeVariationSources(
    collection: [Variation],
    fallback: [Variation],
    itemDocs: [Variation] = []
) -> [Variation] {
    func rows(_ items: [Variation], _ source: String) -> [[String: Any]] {
        items.enumerated().map { index, item in
            ["id": item.id, "updatedAtMs": (item.updatedAt.timeIntervalSince1970 * 1000).rounded(), "_i": "\(source):\(index)"]
        }
    }
    guard let kept = CanonicalBusinessEngine.mergeVariationSources(
        collection: rows(collection, "c"), fallback: rows(fallback, "f"), itemDocs: rows(itemDocs, "d")
    ) else { return collection }
    let sources: [String: [Variation]] = ["c": collection, "f": fallback, "d": itemDocs]
    return kept.compactMap { tag in
        let parts = tag.split(separator: ":")
        guard parts.count == 2, let list = sources[String(parts[0])], let index = Int(parts[1]), list.indices.contains(index) else { return nil }
        return list[index]
    }
}

nonisolated private final class VariationListenerBag: NSObject, ListenerRegistration, @unchecked Sendable {
    private var listeners: [ListenerRegistration] = []
    var collectionItems: [Variation] = []
    var fallbackItems: [Variation] = []
    var itemDocItems: [Variation] = []
    var receivedCollection = false
    var receivedFallback = false
    var receivedItemDocs = false

    func add(_ listener: ListenerRegistration) {
        listeners.append(listener)
    }

    func remove() {
        listeners.forEach { $0.remove() }
        listeners.removeAll()
    }
}

enum VariationEvidenceProcessor {
    static var maxBytes: Int { StorageUploadPolicy.variationMaxBytes }

    static func isAllowed(fileName: String, contentType: String, byteCount: Int) -> Bool {
        StorageUploadPolicy.refusal(
            family: .variationEvidence,
            fileExtension: (fileName as NSString).pathExtension,
            contentType: contentType,
            byteCount: byteCount
        ) == nil
    }

    static func preparedImageData(_ image: UIImage) -> Data? {
        try? StorageUploadPolicy.jpegDataFittingUploadLimit(
            image,
            maxBytes: maxBytes,
            initialQuality: 0.7,
            encodeFailedMessage: "Failed to process image",
            oversizedMessage: CanonicalBusinessEngine.uploadRefusalMessage(kind: "variation_evidence", reason: "too_large")
        )
    }
}

/// `applyVariationOrder`'s answer: the plan rows that changed number (`from` → `to`) and the variations whose settings
/// copy or log entry did not take the new number.
nonisolated struct VariationOrderSaveOutcome: Sendable {
    let changed: [(id: String, from: String, to: String)]
    let copiesFailed: [String]
}

/// Why `applyVariationOrder` saved nothing: the variations changed since the screen loaded them
/// (`VARIATION_RENUMBER_STALE_MESSAGE`), or the rulebook refused the order (a pinned row, the locked order, a row with
/// only its settings copies).
nonisolated enum VariationOrderSaveError: LocalizedError, Sendable {
    case changed(String)
    case refused(String)

    var message: String {
        switch self {
        case .changed(let text), .refused(let text): return text
        }
    }

    var errorDescription: String? { message }
}

/// What the save's transaction worked out (the plan, the rows written and their stored copies).
nonisolated struct VariationOrderTransactionAnswer: @unchecked Sendable {
    let planRows: [RulebookVariationPlanRow]
    let writes: [(id: String, set: [String: Any])]
    let stored: [String: [String: Any]]
}
