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
    private let approvedKey = "warning_resolution_approved_v1"
    private let dismissedKey = "warning_resolution_dismissed_v1"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
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

    func unapprove(_ resolutionKey: String) {
        approvedResolutionKeys.remove(resolutionKey)
        persistApproved()
    }

    private func persistApproved() {
        defaults.set(Array(approvedResolutionKeys), forKey: approvedKey)
    }

    private func persistDismissed() {
        defaults.set(Array(dismissedResolutionKeys), forKey: dismissedKey)
    }
}
