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

    // In-memory cache for offline functionality
    private var cachedProjects: [Project] = []
    private var cachedClients: [Client] = []
    private var cachedOperatives: [Operative] = []
    private var cachedManagers: [Manager] = []
    private var cachedBookings: [Booking] = []
    private var cachedOrganizationSkills: [OrganizationSkill] = []
    private var cachedQualifications: [Qualification] = []

    init() {
        refreshOutboxCounts()
        outboxCancellable = OfflineOutboxStore.shared.$entries
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.refreshOutboxCounts()
            }
        startNetworkMonitoring()
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
        pendingSyncCount = OfflineOutboxStore.shared.pendingCount
        failedSyncCount = OfflineOutboxStore.shared.failedCount
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

    func cacheProjects(_ projects: [Project]) {
        cachedProjects = projects
    }

    func cacheClients(_ clients: [Client]) {
        cachedClients = clients
    }

    func cacheOperatives(_ operatives: [Operative]) {
        cachedOperatives = operatives
    }

    func cacheManagers(_ managers: [Manager]) {
        cachedManagers = managers
    }

    func cacheBookings(_ bookings: [Booking]) {
        cachedBookings = bookings
    }

    func cacheOrganizationSkills(_ skills: [OrganizationSkill]) {
        cachedOrganizationSkills = skills
    }

    func cacheQualifications(_ qualifications: [Qualification]) {
        cachedQualifications = qualifications
    }

    // MARK: - Cache Retrieval

    func getCachedProjects() -> [Project] {
        return cachedProjects
    }

    func getCachedClients() -> [Client] {
        return cachedClients
    }

    func getCachedOperatives() -> [Operative] {
        return cachedOperatives
    }

    func getCachedManagers() -> [Manager] {
        return cachedManagers
    }

    func getCachedBookings() -> [Booking] {
        return cachedBookings
    }

    func getCachedOrganizationSkills() -> [OrganizationSkill] {
        return cachedOrganizationSkills
    }

    func getCachedQualifications() -> [Qualification] {
        return cachedQualifications
    }

    // MARK: - Offline Queue Management (legacy API — delegates to outbox)

    func queueChange(_ change: PendingChange) {
        print("🔥🔥🔥 DEBUG: queueChange legacy call — \(change.type) for \(change.entityType)")
        refreshOutboxCounts()
    }

    // MARK: - Cache Clearing

    func clearAllCache() {
        cachedProjects.removeAll()
        cachedClients.removeAll()
        cachedOperatives.removeAll()
        cachedManagers.removeAll()
        cachedBookings.removeAll()
        cachedOrganizationSkills.removeAll()
        cachedQualifications.removeAll()
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
