//
//  WarningResolutionStore.swift
//  Project Planner
//
//  Approvals and dismissals for warnings (clash approve → weekly report). Firestore is the record,
//  shared with web (RULEBOOK §5): `organizations/{orgId}/warningResolutions/{resolutionKey}` and
//  `organizations/{orgId}/acceptedBookingClashes/{clashPairKey}`, both read with live listeners. A clash
//  approval writes both in one batch (`clashApprovalWrites`); un-approving deletes both. Whether a row
//  still counts is `isWarningActive` over `resolvedWarningKeys`; a clash is approved when `isClashApproved`.
//  UserDefaults is only this phone's offline copy of the last snapshot: Firestore replaces it, so an
//  approval removed on web or another phone drops here too. Writes are staff only (`canViewStaffWarnings`).
//

import Foundation
import Combine
import FirebaseAuth
import FirebaseFirestore

@MainActor
final class WarningResolutionStore: ObservableObject {
    static let shared = WarningResolutionStore()

    /// `warningResolutions` keys with status approved (live snapshot, else this phone's copy of it).
    @Published private(set) var approvedResolutionKeys: Set<String> = []
    /// `warningResolutions` keys with status dismissed.
    @Published private(set) var dismissedResolutionKeys: Set<String> = []
    /// `acceptedBookingClashes` rows (`id`, `bookingAId`, `bookingBId`), from web or this phone.
    @Published private(set) var acceptedClashes: [[String: Any]] = []

    private let defaults: UserDefaults
    private let legacyApprovedKey = "warning_resolution_approved_v1"
    private let legacyDismissedKey = "warning_resolution_dismissed_v1"
    private let legacyMigratedKey = "warning_resolution_legacy_migrated_v1"
    private var organizationId: String?
    private var resolutionListener: ListenerRegistration?
    private var acceptedClashListener: ListenerRegistration?
    /// The signed-in person's staff flags. Nil writes nothing.
    private var actorRole: CanonicalBusinessEngine.CanonicalStaffAccountRole?
    private var cachedDecisions: [String: Any]?
    private var cachedApprovalDecisions: [String: Any]?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let organizationId = WarningsDiskCacheStore.activeOrganizationId, !organizationId.isEmpty {
            self.organizationId = organizationId
            loadKeys(for: organizationId)
        }
    }

    /// Approvals and dismissals belong to one organisation. Switching must not hide the other org's warnings.
    func adoptOrganization(_ organizationId: String) {
        let trimmed = organizationId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, self.organizationId != trimmed else { return }
        self.organizationId = trimmed
        loadKeys(for: trimmed)
    }

    // MARK: - Who may write

    /// The person on this phone. Approve, dismiss and un-approve write only when `canViewStaffWarnings` is true
    /// for them, whichever screen asked (Warnings, Weekly Report).
    func setActor(_ user: AppUser?) {
        actorRole = user.map { UserStore.staffAccountRole(for: $0) }
        migrateLegacyResolutions()
    }

    /// `canViewStaffWarnings` for the person on this phone: admins and managers, never operative mode.
    var canWrite: Bool {
        guard let actorRole else { return false }
        return CanonicalBusinessEngine.canViewStaffWarnings(actorRole)
    }

    // MARK: - Local copy

    private func approvedStorageKey(_ organizationId: String) -> String {
        "warning_resolution_approved_v1_\(organizationId)"
    }

    private func dismissedStorageKey(_ organizationId: String) -> String {
        "warning_resolution_dismissed_v1_\(organizationId)"
    }

    private func loadKeys(for organizationId: String) {
        let approvedKey = approvedStorageKey(organizationId)
        let dismissedKey = dismissedStorageKey(organizationId)
        if defaults.object(forKey: approvedKey) == nil,
           defaults.object(forKey: dismissedKey) == nil,
           !defaults.bool(forKey: legacyMigratedKey) {
            if let legacyApproved = defaults.stringArray(forKey: legacyApprovedKey) {
                defaults.set(legacyApproved, forKey: approvedKey)
            }
            if let legacyDismissed = defaults.stringArray(forKey: legacyDismissedKey) {
                defaults.set(legacyDismissed, forKey: dismissedKey)
            }
            defaults.set(true, forKey: legacyMigratedKey)
        }
        approvedResolutionKeys = Set((defaults.stringArray(forKey: approvedKey) ?? []).map(Self.migratedResolutionKey))
        dismissedResolutionKeys = Set((defaults.stringArray(forKey: dismissedKey) ?? []).map(Self.migratedResolutionKey))
        acceptedClashes = []
        loadUnsyncedLegacyKeys(for: organizationId)
        legacyKeysByResolutionKey = [:]
        legacyWarnings = [:]
        migratedKeys = []
        invalidateDecisions()
        // Next turn, as before: the store can be created before Firebase is configured.
        Task { @MainActor [weak self] in
            guard let self, self.organizationId == organizationId else { return }
            self.attachListeners(organizationId: organizationId)
        }
    }

    /// RULEBOOK 1.8.0 §5: a stored key in its shared form (`sharedWarningResolutionKey`): older iOS manager-clash
    /// keys carried the day as epoch seconds (`mgr-clash-{user}-{1792623600.0}-{i}` → `mgr-clash-{user}-{2026-10-22}-{i}`)
    /// and material cut-off keys an epoch (`materials-{job}-{seconds}` → `materials-{job}-{YYYY-MM-DD}`). Any other key
    /// is returned as stored.
    nonisolated static func migratedResolutionKey(_ key: String) -> String {
        CanonicalBusinessEngine.sharedWarningResolutionKey(key) ?? key
    }

    // MARK: - Live listeners

    private func attachListeners(organizationId: String) {
        resolutionListener?.remove()
        acceptedClashListener?.remove()
        resolutionListener = nil
        acceptedClashListener = nil
        let org = Firestore.firestore().collection("organizations").document(organizationId)
        resolutionListener = org.collection("warningResolutions").addSnapshotListener { [weak self] snapshot, error in
            if let error {
                // A refused read keeps this phone's copy as it is.
                print("🔥🔥🔥 DEBUG: warningResolutions listener error: \(error.localizedDescription)")
                return
            }
            guard let snapshot else { return }
            // RULEBOOK 1.8.0 §5: `parseWarningResolutionDocument` (legacy keys read in their shared form; the stored
            // key is kept for `warningResolutionMigrationWrites`).
            let rows: [[String: String]] = snapshot.documents.compactMap { doc in
                guard let parsed = CanonicalBusinessEngine.parseWarningResolutionDocument(documentId: doc.documentID, data: doc.data()) else {
                    return nil
                }
                var row: [String: String] = [
                    "id": parsed.id,
                    "resolutionKey": parsed.text("resolutionKey"),
                    "storedKey": parsed.text("storedKey"),
                ]
                if let status = parsed.optionalText("status") { row["status"] = status }
                return row
            }
            let fromCache = snapshot.metadata.isFromCache
            Task { @MainActor in
                self?.applyResolutionRows(rows, fromCache: fromCache, organizationId: organizationId)
            }
        }
        acceptedClashListener = org.collection("acceptedBookingClashes").addSnapshotListener { [weak self] snapshot, error in
            if let error {
                print("🔥🔥🔥 DEBUG: acceptedBookingClashes listener error: \(error.localizedDescription)")
                return
            }
            guard let snapshot else { return }
            let rows: [[String: String]] = snapshot.documents.map { doc in
                let data = doc.data()
                return [
                    "id": doc.documentID,
                    "bookingAId": (data["bookingAId"] as? String) ?? "",
                    "bookingBId": (data["bookingBId"] as? String) ?? ""
                ]
            }
            Task { @MainActor in
                guard let self, self.organizationId == organizationId else { return }
                self.acceptedClashes = rows.map { row in row.reduce(into: [String: Any]()) { $0[$1.key] = $1.value } }
                self.invalidateDecisions()
                WarningsService.shared.reapplyResolutions()
            }
        }
    }

    /// Firestore replaces this phone's copy: a key removed elsewhere stops hiding its warning here.
    private func applyResolutionRows(_ rows: [[String: String]], fromCache: Bool, organizationId: String) {
        guard self.organizationId == organizationId else { return }
        storedResolutionRows = rows
        var approved = Set<String>()
        var dismissed = Set<String>()
        for row in rows {
            let key = Self.migratedResolutionKey(row["resolutionKey"] ?? row["id"] ?? "")
            guard !key.isEmpty else { continue }
            switch (row["status"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "approved": approved.insert(key)
            case "dismissed": dismissed.insert(key)
            default: continue
            }
        }
        let synced = hasServerSynced(organizationId)
        if fromCache && !synced {
            // First launch of this build while offline: the cache may be empty, so keep this phone's copy too.
            approved.formUnion(approvedResolutionKeys)
            dismissed.formUnion(dismissedResolutionKeys)
        } else if !fromCache && !synced {
            noteUnsyncedLegacyKeys(
                approved: approvedResolutionKeys.subtracting(approved),
                dismissed: dismissedResolutionKeys.subtracting(dismissed),
                organizationId: organizationId
            )
        }
        approvedResolutionKeys = approved
        dismissedResolutionKeys = dismissed
        persistApproved()
        persistDismissed()
        invalidateDecisions()
        WarningsService.shared.reapplyResolutions()
        migrateLegacyResolutions()
    }

    // MARK: - Decisions (the script decides)

    private func invalidateDecisions() {
        cachedDecisions = nil
        cachedApprovalDecisions = nil
    }

    private func records(approved: Set<String>, dismissed: Set<String>) -> [[String: Any]] {
        approved.sorted().map { ["resolutionKey": $0, "status": "approved"] }
            + dismissed.sorted().map { ["resolutionKey": $0, "status": "dismissed"] }
    }

    /// `WarningDecisions`: `resolvedWarningKeys` over every approved and dismissed record, and the accepted clashes.
    private func decisions() -> [String: Any] {
        if let cachedDecisions { return cachedDecisions }
        let keys = CanonicalBusinessEngine.resolvedWarningKeys(
            records(approved: approvedResolutionKeys, dismissed: dismissedResolutionKeys)
        ) ?? Array(approvedResolutionKeys.union(dismissedResolutionKeys)).sorted()
        let built = CanonicalBusinessEngine.warningDecisions(resolvedKeys: keys, acceptedClashes: acceptedClashes)
        cachedDecisions = built
        return built
    }

    /// The same, with `approvedKeys: approvedWarningKeys(...)`: a dismissed clash is hidden but is not an
    /// approved one on the weekly report (`isClashApproved` / `isClashGroupApproved` read `approvedKeys`).
    private func approvalDecisions() -> [String: Any] {
        if let cachedApprovalDecisions { return cachedApprovalDecisions }
        let all = records(approved: approvedResolutionKeys, dismissed: dismissedResolutionKeys)
        let resolved = CanonicalBusinessEngine.resolvedWarningKeys(all)
            ?? Array(approvedResolutionKeys.union(dismissedResolutionKeys)).sorted()
        let approved = CanonicalBusinessEngine.approvedWarningKeys(all) ?? Array(approvedResolutionKeys).sorted()
        let built = CanonicalBusinessEngine.warningDecisions(
            resolvedKeys: resolved,
            approvedKeys: approved,
            acceptedClashes: acceptedClashes
        )
        cachedApprovalDecisions = built
        return built
    }

    func isApproved(_ resolutionKey: String) -> Bool {
        approvedResolutionKeys.contains(resolutionKey)
    }

    func isDismissed(_ resolutionKey: String) -> Bool {
        dismissedResolutionKeys.contains(resolutionKey)
    }

    /// Key-only check, for rows that are not clashes and for when the script did not answer.
    func shouldShowActive(_ resolutionKey: String) -> Bool {
        !isApproved(resolutionKey) && !isDismissed(resolutionKey)
    }

    /// `isWarningActive` over `resolvedWarningKeys` and `acceptedBookingClashes`. Every list and count uses this.
    func shouldShowActive(_ warning: Warning) -> Bool {
        if legacyStatus(for: warning) != nil { return false }
        // Operative cluster: hidden once every overlapping pair is approved, dismissed or accepted
        // (`isClashGroupApproved` over `resolvedKeys`); a third booking reopens an approved pair.
        if let clash = warning.operativeClash,
           let approved = CanonicalBusinessEngine.isClashGroupApproved(
            pairs: clash.approvalPairs.map { (bookingAId: $0.bookingAId, bookingBId: $0.bookingBId) },
            decisions: decisions()
           ) {
            return !approved
        }
        let pair = Self.clashBookingIds(warning)
        if let active = CanonicalBusinessEngine.isWarningActive(
            resolutionKey: warning.resolutionKey,
            bookingAId: pair?.a,
            bookingBId: pair?.b,
            decisions: decisions()
        ) {
            return active
        }
        return shouldShowActive(warning.resolutionKey)
    }

    /// `isClashApproved`: approved on any device, by its `warningResolutions` key or its booking pair.
    func isClashApproved(_ warning: Warning) -> Bool {
        guard let pair = Self.clashBookingIds(warning) else { return false }
        if legacyStatus(for: warning) == "approved" { return true }
        // A cluster is approved only when every overlapping pair is (`isClashGroupApproved`).
        if let clash = warning.operativeClash {
            return CanonicalBusinessEngine.isClashGroupApproved(
                pairs: clash.approvalPairs.map { (bookingAId: $0.bookingAId, bookingBId: $0.bookingBId) },
                decisions: approvalDecisions()
            ) ?? isApproved(warning.resolutionKey)
        }
        return CanonicalBusinessEngine.isClashApproved(
            bookingAId: pair.a,
            bookingBId: pair.b,
            resolutionKey: warning.resolutionKey,
            decisions: approvalDecisions()
        ) ?? isApproved(warning.resolutionKey)
    }

    nonisolated static func clashBookingIds(_ warning: Warning) -> (a: String, b: String)? {
        if let clash = warning.managerClash {
            return (clash.bookingAId.uuidString, clash.bookingBId.uuidString)
        }
        if let clash = warning.operativeClash {
            return (clash.bookingAId.uuidString, clash.bookingBId.uuidString)
        }
        return nil
    }

    /// The pairs an approval writes and an un-approval deletes: every overlapping pair of an operative
    /// cluster (`operativeClashGroups`), else the clash row's own pair.
    nonisolated static func clashApprovalPairs(_ warning: Warning) -> [(a: String, b: String)] {
        if let clash = warning.operativeClash {
            return clash.approvalPairs.map { (a: $0.bookingAId, b: $0.bookingBId) }
        }
        if let pair = clashBookingIds(warning) { return [pair] }
        return []
    }

    // MARK: - Writes (staff only)

    /// A non-clash approval: `warningResolutions/{resolutionKey}` with status approved.
    @discardableResult
    func approve(_ resolutionKey: String) -> Bool {
        guard canWrite else { return false }
        approvedResolutionKeys.insert(resolutionKey)
        persistApproved()
        invalidateDecisions()
        writeResolution(resolutionKey, status: "approved")
        return true
    }

    /// A clash approval: `clashApprovalWrites`, both documents in one batch. Online only (the screen checks).
    @discardableResult
    func approve(_ warning: Warning) -> Bool {
        guard canWrite else { return false }
        guard Self.clashBookingIds(warning) != nil else { return approve(warning.resolutionKey) }
        guard let organizationId, let uid = Auth.auth().currentUser?.uid else { return false }
        return commitClashApproval(warning, organizationId: organizationId, uid: uid)
    }

    @discardableResult
    func dismiss(_ resolutionKey: String) -> Bool {
        guard canWrite else { return false }
        dismissedResolutionKeys.insert(resolutionKey)
        persistDismissed()
        invalidateDecisions()
        writeResolution(resolutionKey, status: "dismissed")
        return true
    }

    /// Un-approve a clash: deletes `warningResolutions/{clashResolutionKey}`, `acceptedBookingClashes/{clashPairKey}`
    /// (and any older key or pair row naming the same clash) in one batch. Online only (the screen checks).
    /// `completion` gets the commit error, if any; a refused delete puts the approval back through the listener.
    @discardableResult
    func unapprove(_ warning: Warning, completion: ((Error?) -> Void)? = nil) -> Bool {
        guard canWrite, let organizationId, let uid = Auth.auth().currentUser?.uid else { return false }
        let org = Firestore.firestore().collection("organizations").document(organizationId)
        let batch = Firestore.firestore().batch()
        var deletes = 0
        var keys = [warning.resolutionKey] + (legacyKeysByResolutionKey[warning.resolutionKey] ?? [])
        let pairs = Self.clashApprovalPairs(warning)
        if !pairs.isEmpty {
            var pairIds = Set<String>()
            for pair in pairs {
                if let pairKey = CanonicalBusinessEngine.clashPairKey(pair.a, pair.b) {
                    pairIds.insert(pairKey)
                }
                // Operative pairs have no own key: their `warningResolutions` id is `clashResolutionKey` of the pair.
                if warning.operativeClash != nil,
                   let key = CanonicalBusinessEngine.clashResolutionKey(bookingAId: pair.a, bookingBId: pair.b),
                   !keys.contains(key) {
                    keys.append(key)
                }
                for row in acceptedClashes {
                    guard let id = row["id"] as? String, !id.isEmpty,
                          CanonicalBusinessEngine.isClashAccepted(pair.a, pair.b, accepted: [row]) == true else { continue }
                    pairIds.insert(id)
                }
            }
            // Only rows that exist: deleting a missing document is refused for a manager.
            let existing = Set(acceptedClashes.compactMap { $0["id"] as? String })
            for id in pairIds where existing.contains(id) {
                batch.deleteDocument(org.collection("acceptedBookingClashes").document(id))
                deletes += 1
            }
            acceptedClashes.removeAll { row in
                guard let id = row["id"] as? String else { return false }
                return pairIds.contains(id)
            }
        }
        for key in keys {
            if approvedResolutionKeys.contains(key),
               let write = CanonicalBusinessEngine.warningResolutionWriteFields(
                resolutionKey: key,
                status: "approved",
                resolvedByUserId: uid
               ) {
                batch.deleteDocument(org.collection("warningResolutions").document(write.documentId))
                deletes += 1
            }
            approvedResolutionKeys.remove(key)
        }
        forgetLegacyKeys(keys, organizationId: organizationId)
        migratedKeys.remove(warning.resolutionKey)
        persistApproved()
        invalidateDecisions()
        guard deletes > 0 else {
            completion?(nil)
            return true
        }
        batch.commit { error in
            if let error {
                print("🔥🔥🔥 DEBUG: clash un-approve failed: \(error.localizedDescription)")
            }
            Task { @MainActor in completion?(error) }
        }
        return true
    }

    /// `clashApprovalWrites` for every pair of the clash (`clashApprovalPairs`), in one batch. An operative
    /// pair has no own key, so its `warningResolutions` id is the pair's `clashResolutionKey`.
    private func commitClashApproval(
        _ warning: Warning,
        organizationId: String,
        uid: String
    ) -> Bool {
        let pairs = Self.clashApprovalPairs(warning)
        let ownKey: String? = warning.operativeClash == nil ? warning.resolutionKey : nil
        let org = Firestore.firestore().collection("organizations").document(organizationId)
        let batch = Firestore.firestore().batch()
        var wrote = false
        for pair in pairs {
            guard let writes = CanonicalBusinessEngine.clashApprovalWrites(
                bookingAId: pair.a,
                bookingBId: pair.b,
                resolutionKey: ownKey,
                approvedByUserId: uid
            ) else { continue }
            if let accepted = writes.acceptedClash {
                var fields = WriteMetadata.stamped(accepted.fields, userId: uid)
                fields["acceptedAt"] = Timestamp(date: Date())
                batch.setData(fields, forDocument: org.collection("acceptedBookingClashes").document(accepted.documentId))
                if !acceptedClashes.contains(where: { ($0["id"] as? String) == accepted.documentId }) {
                    acceptedClashes.append(["id": accepted.documentId, "bookingAId": pair.a, "bookingBId": pair.b])
                }
                wrote = true
            }
            if let resolution = writes.resolution {
                var fields = WriteMetadata.stamped(resolution.fields, userId: uid)
                fields["resolvedAt"] = Timestamp(date: Date())
                batch.setData(fields, forDocument: org.collection("warningResolutions").document(resolution.documentId))
                approvedResolutionKeys.insert(resolution.documentId)
                wrote = true
            }
        }
        guard wrote else { return false }
        persistApproved()
        invalidateDecisions()
        batch.commit { error in
            if let error {
                print("🔥🔥🔥 DEBUG: clash approval write failed: \(error.localizedDescription)")
            }
        }
        return true
    }

    /// `warningResolutionWriteFields` → `warningResolutions/{resolutionKey}`.
    private func writeResolution(_ resolutionKey: String, status: String, onSuccess: (@MainActor @Sendable () -> Void)? = nil) {
        guard let organizationId,
              let uid = Auth.auth().currentUser?.uid,
              let write = CanonicalBusinessEngine.warningResolutionWriteFields(
                resolutionKey: resolutionKey,
                status: status,
                resolvedByUserId: uid
              ) else { return }
        var fields = WriteMetadata.stamped(write.fields, userId: uid)
        fields["resolvedAt"] = Timestamp(date: Date())
        Firestore.firestore().collection("organizations").document(organizationId)
            .collection("warningResolutions").document(write.documentId)
            .setData(fields) { error in
                if let error {
                    print("🔥🔥🔥 DEBUG: warningResolutions write failed: \(error.localizedDescription)")
                    return
                }
                Task { @MainActor in onSuccess?() }
            }
    }

    /// Previously pruned day-scoped unbooked dismissals outside the scan window, which made
    /// dismissed warnings reappear the next day. Dismissals are now permanent for that key.
    func pruneDismissedUnbookedKeys(from startDay: Date, through endDay: Date, calendar: Calendar = .current) {
        // Intentionally a no-op — dismissed warnings must not return on later refreshes.
        _ = (startDay, endDay, calendar)
    }

    private func persistApproved() {
        guard let organizationId else { return }
        defaults.set(Array(approvedResolutionKeys), forKey: approvedStorageKey(organizationId))
    }

    private func persistDismissed() {
        guard let organizationId else { return }
        defaults.set(Array(dismissedResolutionKeys), forKey: dismissedStorageKey(organizationId))
    }

    // MARK: - Legacy key migration (D3). Remove once every phone has run it.
    //
    // Older iOS builds saved operative clashes as `op-clash-{operativeUuid}-{epoch}-{i}` and material
    // cut-off rows as `materials-{projectUuid}-{epoch}`, in UserDefaults and (later) in `warningResolutions`.
    // The rows now use the shared keys (`clashResolutionKey`, `materials-{projectId}-{YYYY-MM-DD}`).
    // `WarningsComputation.generateWithLegacyKeys` hands over each row's old key forms. While an old key is
    // approved or dismissed and the shared one is not, the row is treated as resolved here, and a staff
    // member's phone writes the shared documents once (`clashApprovalWrites` / `warningResolutionWriteFields`).

    /// Shared key → the key forms older builds saved for the same row.
    private var legacyKeysByResolutionKey: [String: [String]] = [:]
    private var legacyWarnings: [String: Warning] = [:]
    /// Keys this phone saved that the server never had when this build first synced.
    private var unsyncedApprovedKeys: Set<String> = []
    private var unsyncedDismissedKeys: Set<String> = []
    /// Shared keys this session already wrote for a legacy key.
    private var migratedKeys: Set<String> = []
    /// The last `warningResolutions` snapshot (`id`, shared `resolutionKey`, `storedKey`, `status`).
    private var storedResolutionRows: [[String: String]] = []

    private func unsyncedApprovedStorageKey(_ organizationId: String) -> String {
        "warning_resolution_unsynced_approved_v2_\(organizationId)"
    }

    private func unsyncedDismissedStorageKey(_ organizationId: String) -> String {
        "warning_resolution_unsynced_dismissed_v2_\(organizationId)"
    }

    private func serverSyncedStorageKey(_ organizationId: String) -> String {
        "warning_resolution_server_synced_v2_\(organizationId)"
    }

    private func hasServerSynced(_ organizationId: String) -> Bool {
        defaults.bool(forKey: serverSyncedStorageKey(organizationId))
    }

    private func loadUnsyncedLegacyKeys(for organizationId: String) {
        unsyncedApprovedKeys = Set(defaults.stringArray(forKey: unsyncedApprovedStorageKey(organizationId)) ?? [])
        unsyncedDismissedKeys = Set(defaults.stringArray(forKey: unsyncedDismissedStorageKey(organizationId)) ?? [])
    }

    /// Runs once per organisation, on the first server snapshot this build sees. Those keys are only ever
    /// read through a row's legacy key forms, so a shared key removed on web is not brought back.
    private func noteUnsyncedLegacyKeys(approved: Set<String>, dismissed: Set<String>, organizationId: String) {
        unsyncedApprovedKeys.formUnion(approved)
        unsyncedDismissedKeys.formUnion(dismissed)
        defaults.set(Array(unsyncedApprovedKeys), forKey: unsyncedApprovedStorageKey(organizationId))
        defaults.set(Array(unsyncedDismissedKeys), forKey: unsyncedDismissedStorageKey(organizationId))
        defaults.set(true, forKey: serverSyncedStorageKey(organizationId))
    }

    private func forgetLegacyKeys(_ keys: [String], organizationId: String) {
        let drop = Set(keys)
        guard !unsyncedApprovedKeys.isDisjoint(with: drop) || !unsyncedDismissedKeys.isDisjoint(with: drop) else { return }
        unsyncedApprovedKeys.subtract(drop)
        unsyncedDismissedKeys.subtract(drop)
        defaults.set(Array(unsyncedApprovedKeys), forKey: unsyncedApprovedStorageKey(organizationId))
        defaults.set(Array(unsyncedDismissedKeys), forKey: unsyncedDismissedStorageKey(organizationId))
    }

    /// `approved` or `dismissed` when one of the row's old key forms is, else nil.
    private func legacyStatus(for warning: Warning) -> String? {
        guard let legacy = legacyKeysByResolutionKey[warning.resolutionKey], !legacy.isEmpty else { return nil }
        if legacy.contains(where: { approvedResolutionKeys.contains($0) || unsyncedApprovedKeys.contains($0) }) {
            return "approved"
        }
        if legacy.contains(where: { dismissedResolutionKeys.contains($0) || unsyncedDismissedKeys.contains($0) }) {
            return "dismissed"
        }
        return nil
    }

    /// The latest scan's rows and their old key forms. Writes the shared documents for any still pending.
    func updateLegacyKeys(_ legacyKeys: [String: [String]], warnings: [Warning]) {
        legacyKeysByResolutionKey = legacyKeys
        var rows: [String: Warning] = [:]
        for warning in warnings where legacyKeys[warning.resolutionKey] != nil {
            rows[warning.resolutionKey] = warning
        }
        legacyWarnings = rows
        migrateLegacyResolutions()
    }

    /// RULEBOOK 1.8.0 §5 (D3): the shared-key documents to write come from `warningResolutionMigrationWrites` over the
    /// stored documents (plus this phone's not-yet-synced legacy keys) and the rows' older key forms. Approved beats
    /// dismissed; a shared key already resolved is not written; old documents are left in place (readers map them).
    /// A clash approval also writes its booking pair (`commitClashApproval`). Staff only; idempotent.
    private func migrateLegacyResolutions() {
        guard canWrite, let organizationId, let uid = Auth.auth().currentUser?.uid else { return }
        // RULEBOOK 1.10.0 §1: runs from a warnings scan, allowed only as the named idempotent migration
        // (`IDEMPOTENT_MIGRATION_WRITES`).
        guard SyncWriteGate.allows(.listenerSnapshot, "warning-key migration", migration: "warningResolutionMigrationWrites") else { return }
        var documents: [(id: String, data: [String: Any])] = storedResolutionRows.map { row in
            let stored = row["storedKey"] ?? row["resolutionKey"] ?? row["id"] ?? ""
            var data: [String: Any] = ["resolutionKey": stored]
            if let status = row["status"] { data["status"] = status }
            return (id: row["id"] ?? stored, data: data)
        }
        for key in unsyncedApprovedKeys { documents.append((id: key, data: ["resolutionKey": key, "status": "approved"])) }
        for key in unsyncedDismissedKeys { documents.append((id: key, data: ["resolutionKey": key, "status": "dismissed"])) }
        var forms: [String: [String]] = [:]
        for key in legacyWarnings.keys where !migratedKeys.contains(key) {
            forms[key] = legacyKeysByResolutionKey[key] ?? []
        }
        guard let writes = CanonicalBusinessEngine.warningResolutionMigrationWrites(
            documents: documents,
            legacyKeyForms: forms,
            resolvedByUserId: uid
        ) else { return }
        let resolved = Set(decisions()["resolvedKeys"] as? [String] ?? [])
        for key in forms.keys where resolved.contains(key) {
            migratedKeys.insert(key)
            forgetLegacyKeys(forms[key] ?? [], organizationId: organizationId)
        }
        for write in writes {
            let key = (write.fields["resolutionKey"] as? String) ?? write.documentId
            let status = (write.fields["status"] as? String) ?? "dismissed"
            guard !migratedKeys.contains(key), !resolved.contains(key) else { continue }
            migratedKeys.insert(key)
            let legacy = legacyKeysByResolutionKey[key] ?? []
            if status == "approved", let warning = legacyWarnings[key], Self.clashBookingIds(warning) != nil {
                if commitClashApproval(warning, organizationId: organizationId, uid: uid) {
                    forgetLegacyKeys(legacy, organizationId: organizationId)
                }
                continue
            }
            writeResolution(key, status: status) { [weak self] in
                guard let self, self.organizationId == organizationId else { return }
                self.forgetLegacyKeys(legacy, organizationId: organizationId)
            }
            if status == "approved" {
                approvedResolutionKeys.insert(key)
                persistApproved()
            } else {
                dismissedResolutionKeys.insert(key)
                persistDismissed()
            }
            invalidateDecisions()
        }
    }
}
