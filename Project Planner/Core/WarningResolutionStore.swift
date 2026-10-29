//
//  WarningResolutionStore.swift
//  Project Planner
//
//  Approvals and dismissals for warnings (clash approve → weekly report). Firestore is the record,
//  shared with web: `organizations/{orgId}/warningResolutions/{resolutionKey}` through the rulebook's
//  `warningResolutionWriteFields`, and clash approvals in `acceptedBookingClashes` through
//  `acceptedClashWriteFields` / `isClashAccepted`. UserDefaults stays as the fallback while the
//  Firestore rule is not deployed or the phone is offline; a local key is never dropped because a
//  write failed.
//

import Foundation
import Combine
import FirebaseAuth
import FirebaseFirestore

@MainActor
final class WarningResolutionStore: ObservableObject {
    static let shared = WarningResolutionStore()

    @Published private(set) var approvedResolutionKeys: Set<String> = []
    @Published private(set) var dismissedResolutionKeys: Set<String> = []
    /// `acceptedBookingClashes` rows (`id`, `bookingAId`, `bookingBId`), from web or this phone.
    @Published private(set) var acceptedClashes: [[String: Any]] = []
    private var remoteLoadOrganizationId: String?

    private let defaults: UserDefaults
    private let legacyApprovedKey = "warning_resolution_approved_v1"
    private let legacyDismissedKey = "warning_resolution_dismissed_v1"
    private let legacyMigratedKey = "warning_resolution_legacy_migrated_v1"
    private var organizationId: String?

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
        Task { await loadRemote(organizationId: organizationId) }
    }

    /// Older manager-clash keys carried the day as seconds (`mgr-clash-{user}-{1792623600.0}-{i}`);
    /// `managerClashGroups` keys it by day (`mgr-clash-{user}-{2026-10-22}-{i}`).
    nonisolated static func migratedResolutionKey(_ key: String) -> String {
        guard key.hasPrefix("mgr-clash-"),
              let match = key.range(of: #"-(\d{9,}(?:\.\d+)?)-(\d+)$"#, options: .regularExpression) else {
            return key
        }
        let tail = key[match].dropFirst()
        let parts = tail.split(separator: "-")
        guard parts.count == 2, let seconds = Double(parts[0]),
              let dayKey = CanonicalBusinessEngine.dayKeyInOrganizationZone(Date(timeIntervalSince1970: seconds)) else {
            return key
        }
        return String(key[..<match.lowerBound]) + "-\(dayKey)-\(parts[1])"
    }

    /// Reads both collections for this organisation and merges them over the local keys.
    /// A refused read (rule not deployed yet) leaves the local keys as they are.
    func loadRemote(organizationId: String) async {
        remoteLoadOrganizationId = organizationId
        let org = Firestore.firestore().collection("organizations").document(organizationId)
        if let snapshot = try? await org.collection("warningResolutions").getDocuments(),
           self.organizationId == organizationId {
            let records: [[String: Any]] = snapshot.documents.map { doc in
                let data = doc.data()
                return [
                    "id": doc.documentID,
                    "resolutionKey": (data["resolutionKey"] as? String) ?? "",
                    "status": (data["status"] as? String) ?? ""
                ]
            }
            // The rulebook decides which keys are hidden. The approved ones are kept apart only so the
            // weekly report can list them as "Ticked"; every other resolved key is a dismissal.
            let approvedRecords = records.filter {
                ($0["status"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "approved"
            }
            if let resolved = CanonicalBusinessEngine.resolvedWarningKeys(records),
               let approved = CanonicalBusinessEngine.resolvedWarningKeys(approvedRecords) {
                approvedResolutionKeys.formUnion(approved)
                dismissedResolutionKeys.formUnion(Set(resolved).subtracting(approved))
                persistApproved()
                persistDismissed()
            } else {
                print("🔥🔥🔥 DEBUG: resolvedWarningKeys did not run; keeping this phone's warning keys")
            }
        }
        if let snapshot = try? await org.collection("acceptedBookingClashes").getDocuments(),
           self.organizationId == organizationId {
            acceptedClashes = snapshot.documents.map { doc in
                let data = doc.data()
                return [
                    "id": doc.documentID,
                    "bookingAId": (data["bookingAId"] as? String) ?? "",
                    "bookingBId": (data["bookingBId"] as? String) ?? ""
                ]
            }
        }
        if self.organizationId == organizationId {
            WarningsService.shared.reapplyResolutions()
        }
    }

    func isApproved(_ resolutionKey: String) -> Bool {
        approvedResolutionKeys.contains(resolutionKey)
    }

    func isDismissed(_ resolutionKey: String) -> Bool {
        dismissedResolutionKeys.contains(resolutionKey)
    }

    /// `isWarningActive` for a warning known only by its key (approved or dismissed on any device).
    func shouldShowActive(_ resolutionKey: String) -> Bool {
        isActive(resolutionKey: resolutionKey, pair: nil)
    }

    /// `isWarningActive`: also hides a clash whose two bookings were accepted on web or this phone.
    func shouldShowActive(_ warning: Warning) -> Bool {
        isActive(resolutionKey: warning.resolutionKey, pair: Self.clashBookingIds(warning))
    }

    /// Weekly report "Ticked": approved here or on web, or a clash pair accepted in `acceptedBookingClashes`
    /// that was not dismissed. Accepted pairs are the ones `isWarningActive` hides for their bookings.
    func isTicked(_ warning: Warning) -> Bool {
        if isApproved(warning.resolutionKey) { return true }
        guard !isDismissed(warning.resolutionKey), let pair = Self.clashBookingIds(warning) else { return false }
        return CanonicalBusinessEngine.isWarningActive(
            resolutionKey: warning.resolutionKey,
            bookingAId: pair.a,
            bookingBId: pair.b,
            resolvedKeys: [],
            acceptedClashes: acceptedClashes
        ) == false
    }

    /// Passes only this row's own key as `resolvedKeys` (the rule is a membership test), so the script is
    /// not handed every resolution for every warning. If the script did not run, a resolved key still hides.
    private func isActive(resolutionKey: String, pair: (a: String, b: String)?) -> Bool {
        let resolved = isApproved(resolutionKey) || isDismissed(resolutionKey)
        let active = CanonicalBusinessEngine.isWarningActive(
            resolutionKey: resolutionKey,
            bookingAId: pair?.a,
            bookingBId: pair?.b,
            resolvedKeys: resolved ? [resolutionKey] : [],
            acceptedClashes: pair == nil ? [] : acceptedClashes
        )
        return active ?? !resolved
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

    func approve(_ resolutionKey: String) {
        approvedResolutionKeys.insert(resolutionKey)
        persistApproved()
        writeResolution(resolutionKey, status: "approved")
    }

    /// A clash approval is also the `acceptedBookingClashes` row web reads.
    func approve(_ warning: Warning) {
        approve(warning.resolutionKey)
        guard let pair = Self.clashBookingIds(warning),
              let organizationId,
              let uid = Auth.auth().currentUser?.uid,
              let write = CanonicalBusinessEngine.acceptedClashWriteFields(
                bookingAId: pair.a,
                bookingBId: pair.b,
                acceptedByUserId: uid
              ) else { return }
        var fields = write.fields
        fields["acceptedAt"] = Timestamp(date: Date())
        acceptedClashes.append(["id": write.documentId, "bookingAId": pair.a, "bookingBId": pair.b])
        Firestore.firestore().collection("organizations").document(organizationId)
            .collection("acceptedBookingClashes").document(write.documentId)
            .setData(fields) { error in
                if let error {
                    print("🔥🔥🔥 DEBUG: acceptedBookingClashes write failed (kept on this phone): \(error.localizedDescription)")
                }
            }
    }

    func dismiss(_ resolutionKey: String) {
        dismissedResolutionKeys.insert(resolutionKey)
        persistDismissed()
        writeResolution(resolutionKey, status: "dismissed")
    }

    /// `warningResolutionWriteFields` → `warningResolutions/{resolutionKey}`. Until the rule is deployed the
    /// write is refused; the key stays on this phone and the next approval or dismissal tries again.
    private func writeResolution(_ resolutionKey: String, status: String) {
        guard let organizationId,
              let uid = Auth.auth().currentUser?.uid,
              let write = CanonicalBusinessEngine.warningResolutionWriteFields(
                resolutionKey: resolutionKey,
                status: status,
                resolvedByUserId: uid
              ) else { return }
        var fields = write.fields
        fields["resolvedAt"] = Timestamp(date: Date())
        Firestore.firestore().collection("organizations").document(organizationId)
            .collection("warningResolutions").document(write.documentId)
            .setData(fields) { error in
                if let error {
                    print("🔥🔥🔥 DEBUG: warningResolutions write failed (kept on this phone): \(error.localizedDescription)")
                }
            }
    }

    /// Previously pruned day-scoped unbooked dismissals outside the scan window, which made
    /// dismissed warnings reappear the next day. Dismissals are now permanent for that key.
    func pruneDismissedUnbookedKeys(from startDay: Date, through endDay: Date, calendar: Calendar = .current) {
        // Intentionally a no-op — dismissed warnings must not return on later refreshes.
        _ = (startDay, endDay, calendar)
    }

    func unapprove(_ resolutionKey: String) {
        approvedResolutionKeys.remove(resolutionKey)
        persistApproved()
        guard let organizationId,
              let write = CanonicalBusinessEngine.warningResolutionWriteFields(
                resolutionKey: resolutionKey,
                status: "approved",
                resolvedByUserId: Auth.auth().currentUser?.uid ?? ""
              ) else { return }
        Firestore.firestore().collection("organizations").document(organizationId)
            .collection("warningResolutions").document(write.documentId)
            .delete { error in
                if let error {
                    print("🔥🔥🔥 DEBUG: warningResolutions delete failed: \(error.localizedDescription)")
                }
            }
    }

    private func persistApproved() {
        guard let organizationId else { return }
        defaults.set(Array(approvedResolutionKeys), forKey: approvedStorageKey(organizationId))
    }

    private func persistDismissed() {
        guard let organizationId else { return }
        defaults.set(Array(dismissedResolutionKeys), forKey: dismissedStorageKey(organizationId))
    }
}
