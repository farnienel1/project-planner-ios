//
//  SmartCacheService.swift
//  Project Planner
//
//  Created by Assistant on 29/09/2025.
//

import Foundation
import Combine
#if canImport(Network)
import Network
#endif
#if canImport(UIKit)
import UIKit
#endif

// MARK: - Smart Cache Service for Offline Functionality

@MainActor
class SmartCacheService: ObservableObject {
    @Published var isOnline = true
    @Published var isSyncing = false
    @Published private(set) var pendingSyncCount = 0
    @Published private(set) var failedSyncCount = 0

    var showOfflineBanner: Bool {
        !isOnline || isSyncing || pendingSyncCount > 0 || failedSyncCount > 0
    }

    #if canImport(Network)
    private let networkMonitor = NWPathMonitor()
    #endif
    private let queue = DispatchQueue(label: "NetworkMonitor")

    private var firebaseBackend: FirebaseBackend?
    private var outboxCancellable: AnyCancellable?
    private var syncTask: Task<Void, Never>?

    // In-memory cache for offline functionality. Values are stored per organisation
    // so a switch cannot satisfy the next company from the previous company's arrays.
    private var cacheOrganizationId = ""
    private var projectsByOrganization: [String: [Project]] = [:]
    private var clientsByOrganization: [String: [Client]] = [:]
    private var operativesByOrganization: [String: [Operative]] = [:]
    private var managersByOrganization: [String: [Manager]] = [:]
    private var bookingsByOrganization: [String: [Booking]] = [:]
    private var skillsByOrganization: [String: [OrganizationSkill]] = [:]
    private var qualificationsByOrganization: [String: [Qualification]] = [:]

    init() {
        refreshOutboxCounts()
        outboxCancellable = OfflineOutboxStore.shared.$entries
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.refreshOutboxCounts()
            }
        startNetworkMonitoring()
        #if canImport(UIKit)
        NotificationCenter.default.addObserver(
            forName: UIApplication.willEnterForegroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                await self?.refreshConnectionAndSync()
            }
        }
        #endif
    }

    deinit {
        #if canImport(Network)
        networkMonitor.cancel()
        #endif
        syncTask?.cancel()
    }

    func setFirebaseBackend(_ backend: FirebaseBackend) {
        firebaseBackend = backend
    }

    func refreshOutboxCounts() {
        pendingSyncCount = OfflineOutboxStore.shared.pendingCount + SiteAuditOfflineStore.shared.pendingCount
        failedSyncCount = OfflineOutboxStore.shared.failedCount
        if isOnline && pendingSyncCount == 0 && failedSyncCount == 0 {
            isSyncing = false
        }
    }

    // MARK: - Network Monitoring

    private func startNetworkMonitoring() {
        #if canImport(Network)
        networkMonitor.pathUpdateHandler = { [weak self] path in
            DispatchQueue.main.async {
                let wasOffline = self?.isOnline == false
                self?.isOnline = path.status == .satisfied
                if wasOffline, self?.isOnline == true {
                    self?.syncPendingChanges()
                }
            }
        }
        networkMonitor.start(queue: queue)
        #else
        isOnline = true
        #endif
    }

    func syncPendingChanges() {
        guard isOnline, !isSyncing else { return }
        guard firebaseBackend != nil else {
            NotificationCenter.default.post(name: .syncOfflineChanges, object: nil)
            return
        }

        syncTask?.cancel()
        syncTask = Task { @MainActor in
            await performSync()
        }
    }

    func retryFailedSync() async {
        guard isOnline else { return }
        await performSync()
    }

    /// Re-check the current network path and push the outbox if we are back online.
    func refreshConnectionAndSync() async {
        #if canImport(Network)
        isOnline = networkMonitor.currentPath.status == .satisfied
        #endif
        if isOnline {
            await performSync()
        }
    }

    private func performSync() async {
        guard let firebaseBackend else {
            NotificationCenter.default.post(name: .syncOfflineChanges, object: nil)
            return
        }

        isSyncing = true
        defer {
            isSyncing = false
            refreshOutboxCounts()
        }

        refreshOutboxCounts()
        guard OfflineOutboxStore.shared.pendingCount > 0 || SiteAuditOfflineStore.shared.pendingCount > 0 else {
            await SiteAuditOfflineStore.shared.syncPending(firebaseBackend: firebaseBackend)
            NotificationCenter.default.post(name: .syncOfflineChanges, object: nil)
            return
        }

        print("🔥🔥🔥 DEBUG: 🔄 Syncing offline outbox (\(OfflineOutboxStore.shared.pendingCount) entries)")
        _ = await OfflineSyncCoordinator.processOutbox(firebaseBackend: firebaseBackend, outbox: OfflineOutboxStore.shared)
        refreshOutboxCounts()
        await SiteAuditOfflineStore.shared.syncPending(firebaseBackend: firebaseBackend)

        // Legacy fallback: stores still push in-memory state for any data not yet in the outbox.
        NotificationCenter.default.post(name: .syncOfflineChanges, object: nil)
        print("🔥🔥🔥 DEBUG: ✅ Offline sync pass finished — remaining: \(OfflineOutboxStore.shared.pendingCount)")
    }

    // MARK: - Cache Management

    func useOrganization(_ organizationId: String) {
        cacheOrganizationId = organizationId.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// Explicit switch wins. Otherwise the organisation id already stored for this device.
    private func resolvedOrganizationId() -> String {
        if !cacheOrganizationId.isEmpty { return cacheOrganizationId }
        let stored = (UserDefaults.standard.string(forKey: "cached_organizationId") ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return stored.isEmpty ? "__unscoped__" : stored
    }

    func cacheProjects(_ projects: [Project]) {
        projectsByOrganization[resolvedOrganizationId()] = projects
    }

    func cacheClients(_ clients: [Client]) {
        clientsByOrganization[resolvedOrganizationId()] = clients
    }

    func cacheOperatives(_ operatives: [Operative]) {
        operativesByOrganization[resolvedOrganizationId()] = operatives
    }

    func cacheManagers(_ managers: [Manager]) {
        managersByOrganization[resolvedOrganizationId()] = managers
    }

    func cacheBookings(_ bookings: [Booking]) {
        bookingsByOrganization[resolvedOrganizationId()] = bookings
    }

    func cacheOrganizationSkills(_ skills: [OrganizationSkill]) {
        skillsByOrganization[resolvedOrganizationId()] = skills
    }

    func cacheQualifications(_ qualifications: [Qualification]) {
        qualificationsByOrganization[resolvedOrganizationId()] = qualifications
    }

    // MARK: - Cache Retrieval

    func getCachedProjects() -> [Project] {
        return projectsByOrganization[resolvedOrganizationId()] ?? []
    }

    func getCachedClients() -> [Client] {
        return clientsByOrganization[resolvedOrganizationId()] ?? []
    }

    func getCachedOperatives() -> [Operative] {
        return operativesByOrganization[resolvedOrganizationId()] ?? []
    }

    func getCachedManagers() -> [Manager] {
        return managersByOrganization[resolvedOrganizationId()] ?? []
    }

    func getCachedBookings() -> [Booking] {
        return bookingsByOrganization[resolvedOrganizationId()] ?? []
    }

    func getCachedOrganizationSkills() -> [OrganizationSkill] {
        return skillsByOrganization[resolvedOrganizationId()] ?? []
    }

    func getCachedQualifications() -> [Qualification] {
        return qualificationsByOrganization[resolvedOrganizationId()] ?? []
    }

    // MARK: - Offline Queue Management (legacy API — delegates to outbox)

    func queueChange(_ change: PendingChange) {
        print("🔥🔥🔥 DEBUG: queueChange legacy call — \(change.type) for \(change.entityType)")
        refreshOutboxCounts()
    }

    // MARK: - Cache Clearing

    func clearAllCache() {
        cacheOrganizationId = ""
        projectsByOrganization.removeAll()
        clientsByOrganization.removeAll()
        operativesByOrganization.removeAll()
        managersByOrganization.removeAll()
        bookingsByOrganization.removeAll()
        skillsByOrganization.removeAll()
        qualificationsByOrganization.removeAll()
        OfflineOutboxStore.shared.clearAll()
        refreshOutboxCounts()
        print("🔥🔥🔥 DEBUG: All cache cleared")
    }
}

// MARK: - Pending Change Model (legacy)

struct PendingChange: Identifiable, Codable {
    var id = UUID()
    let type: ChangeType
    let entityType: EntityType
    let entityId: String
    let data: Data
    let timestamp: Date

    enum ChangeType: String, Codable {
        case create = "create"
        case update = "update"
        case delete = "delete"
    }

    enum EntityType: String, Codable {
        case project = "project"
        case client = "client"
        case operative = "operative"
        case manager = "manager"
        case booking = "booking"
        case skill = "skill"
        case qualification = "qualification"
    }
}
