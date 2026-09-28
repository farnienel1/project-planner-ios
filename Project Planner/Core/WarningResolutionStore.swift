//
//  WarningResolutionStore.swift
//  Project Planner
//
//  Persists admin approvals/dismissals for warnings (clash approve → weekly report).
//

import Foundation
import Combine

@MainActor
final class WarningResolutionStore: ObservableObject {
    static let shared = WarningResolutionStore()

    @Published private(set) var approvedResolutionKeys: Set<String> = []
    @Published private(set) var dismissedResolutionKeys: Set<String> = []

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
        approvedResolutionKeys = Set(defaults.stringArray(forKey: approvedKey) ?? [])
        dismissedResolutionKeys = Set(defaults.stringArray(forKey: dismissedKey) ?? [])
    }

    func isApproved(_ resolutionKey: String) -> Bool {
        approvedResolutionKeys.contains(resolutionKey)
    }

    func isDismissed(_ resolutionKey: String) -> Bool {
        dismissedResolutionKeys.contains(resolutionKey)
    }

    func shouldShowActive(_ resolutionKey: String) -> Bool {
        !isApproved(resolutionKey) && !isDismissed(resolutionKey)
    }

    func approve(_ resolutionKey: String) {
        approvedResolutionKeys.insert(resolutionKey)
        persistApproved()
    }

    func dismiss(_ resolutionKey: String) {
        dismissedResolutionKeys.insert(resolutionKey)
        persistDismissed()
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
