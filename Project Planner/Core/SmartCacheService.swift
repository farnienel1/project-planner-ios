//
//  SmartCacheService.swift
//  Project Planner
//
//  Created by Assistant on 29/09/2025.
//

import Foundation
import Combine
import FirebaseAuth
#if canImport(Network)
import Network
#endif
#if canImport(UIKit)
import UIKit
#endif

/// When queued changes are retried besides "network came back" (a path change), app foreground, Retry now and
/// pull-to-refresh: on a backing-off timer (1, 2, 5, then every 10 minutes) while anything can still retry on its
/// own. A phone on a weak site signal often never reports the path going offline, so a queued material order email
/// could otherwise wait until airplane mode was toggled.
///
/// "Can still retry" = outbox entries queued by the signed-in account and under the attempt limit
/// (`OfflineOutboxStore.autoRetryableCount`), plus queued site audits (`SiteAuditOfflineStore`). Entries stuck at the
/// limit wait for Retry or Discard and do not keep the timer alive. Timer passes do not count as tries.
enum OutboxRetryPolicy {
    nonisolated static let delays: [TimeInterval] = [60, 120, 300, 600]

    /// Wait before timer pass `pass` (0-based); the last delay repeats.
    nonisolated static func delay(beforePass pass: Int) -> TimeInterval {
        delays[min(max(pass, 0), delays.count - 1)]
    }

    /// A newly queued item restarts the backoff at the first delay.
    nonisolated static func restartsBackoff(previousRetryable: Int, retryable: Int) -> Bool {
        retryable > previousRetryable
    }

    nonisolated static func shouldKeepRetrying(retryableOutboxCount: Int, pendingSiteAudits: Int) -> Bool {
        retryableOutboxCount > 0 || pendingSiteAudits > 0
    }

    /// One timer pass: only online and when no sync is already running (the sync is single-flight anyway).
    nonisolated static func shouldRetryNow(retryableOutboxCount: Int, pendingSiteAudits: Int, isOnline: Bool, isSyncing: Bool) -> Bool {
        shouldKeepRetrying(retryableOutboxCount: retryableOutboxCount, pendingSiteAudits: pendingSiteAudits) && isOnline && !isSyncing
    }
}

/// Runs one async operation at a time. A caller that arrives while it runs is not dropped: it asks for one more
/// pass after the running one (callers that arrive together share that one trailing pass, which runs the latest
/// caller's operation) and waits until it has finished. Used for the offline sync, which every trigger reaches.
@MainActor
final class SingleFlight {
    typealias Operation = @MainActor () async -> Void

    /// The one offline sync of this device: the timer, foreground, Retry now, pull-to-refresh, reconnect and the
    /// sign-out "Sync now" all run through it, whichever `SmartCacheService` instance asked.
    static let offlineSync = SingleFlight()

    private var running: Task<Void, Never>?
    private var trailingOperation: Operation?

    var isRunning: Bool { running != nil }
    /// A trigger arrived during the running pass and will run right after it.
    var hasTrailingPass: Bool { trailingOperation != nil }

    func run(_ operation: @escaping Operation) async {
        if let running {
            trailingOperation = operation
            await running.value
            return
        }
        // The loop, the check for a trailing pass and clearing `running` all happen inside the task, on the main
        // actor with no await between the last check and the clear: a trigger that arrives as a pass ends either
        // becomes the trailing pass or (once `running` is nil) starts a new one. Never lost, never run late.
        let task = Task { @MainActor [weak self] in
            var next: Operation? = operation
            while let current = next {
                await current()
                next = self?.trailingOperation
                self?.trailingOperation = nil
            }
            self?.running = nil
        }
        running = task
        await task.value
    }

    /// Runs `operation` through this guard but returns after at most `timeoutSeconds`; the pass keeps going in the
    /// background if it is slower. True when it finished in time.
    @discardableResult
    func run(timeoutSeconds: Double, _ operation: @escaping Operation) async -> Bool {
        let finished = FinishedFlag()
        Task { @MainActor in
            await self.run(operation)
            finished.done = true
        }
        let deadline = Date().addingTimeInterval(max(0, timeoutSeconds))
        while !finished.done, Date() < deadline {
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        return finished.done
    }

    @MainActor
    private final class FinishedFlag {
        var done = false
    }

    /// Returns once no pass is running, or after `timeoutSeconds` (a Storage upload can stall for minutes; a
    /// sign-out must not wait for it). True when the sync finished in time.
    @discardableResult
    func waitUntilIdle(timeoutSeconds: Double) async -> Bool {
        let deadline = Date().addingTimeInterval(max(0, timeoutSeconds))
        while running != nil, Date() < deadline {
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        return running == nil
    }
}

// MARK: - Smart Cache Service for Offline Functionality

@MainActor
class SmartCacheService: ObservableObject {
    @Published var isOnline = true
    @Published var isSyncing = false
    @Published private(set) var pendingSyncCount = 0
    @Published private(set) var failedSyncCount = 0
    /// RULEBOOK §2: when this device last had server data for the current organisation. Daily Overview,
    /// warnings, weekly report and My Schedule show "Last updated [date/time]" from it while offline
    /// (`OfflinePolicy.lastUpdatedMessage`, `LastUpdatedOfflineLabel`). A per-device cache marker only.
    @Published private(set) var lastSyncedAt: Date?

    /// "Last updated [date/time]" while offline, else nil.
    var lastUpdatedOfflineMessage: String? {
        isOnline ? nil : OfflinePolicy.lastUpdatedMessage(lastSyncedAt)
    }

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
    /// Runs while the outbox has pending entries (`OutboxRetryPolicy`); stops itself when it is empty.
    private var outboxRetryTask: Task<Void, Never>?
    /// Every sync trigger goes through this, so two passes never run at once.
    private let syncFlight = SingleFlight.offlineSync
    private var siteAuditCancellable: AnyCancellable?
    /// Retryable work seen at the last timer check; more than before = something new was queued.
    private var lastRetryableTotal = 0

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
        lastSyncedAt = Self.storedLastSync(organizationId: resolvedOrganizationId())
        refreshOutboxCounts()
        outboxCancellable = OfflineOutboxStore.shared.$entries
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.refreshOutboxCounts()
            }
        // A site audit saved offline also counts and starts the retry timer.
        siteAuditCancellable = SiteAuditOfflineStore.shared.$pending
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.refreshOutboxCounts()
            }
        startNetworkMonitoring()
        // Sign-out clears this account's cache and outbox (`FirebaseBackend.clearDeviceQueuesOnSignOut`).
        NotificationCenter.default.addObserver(
            forName: .appDidSignOut,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.clearAllCache() }
        }
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
        outboxRetryTask?.cancel()
    }

    func setFirebaseBackend(_ backend: FirebaseBackend) {
        firebaseBackend = backend
        updateOutboxRetryTimer()
    }

    func refreshOutboxCounts() {
        pendingSyncCount = OfflineOutboxStore.shared.pendingCount + SiteAuditOfflineStore.shared.pendingCount
        failedSyncCount = OfflineOutboxStore.shared.failedCount
        if isOnline && pendingSyncCount == 0 && failedSyncCount == 0 {
            isSyncing = false
        }
        updateOutboxRetryTimer()
    }

    private var retryableWorkCounts: (outbox: Int, siteAudits: Int) {
        (
            OfflineOutboxStore.shared.autoRetryableCount(signedInUserId: firebaseBackend?.currentUser?.uid),
            SiteAuditOfflineStore.shared.retryableCount
        )
    }

    private func updateOutboxRetryTimer() {
        let counts = retryableWorkCounts
        let total = counts.outbox + counts.siteAudits
        defer { lastRetryableTotal = total }
        guard OutboxRetryPolicy.shouldKeepRetrying(retryableOutboxCount: counts.outbox, pendingSiteAudits: counts.siteAudits) else {
            outboxRetryTask?.cancel()
            outboxRetryTask = nil
            return
        }
        if outboxRetryTask != nil {
            // Something new was queued: start the backoff again from 1 minute.
            guard OutboxRetryPolicy.restartsBackoff(previousRetryable: lastRetryableTotal, retryable: total) else { return }
            outboxRetryTask?.cancel()
            outboxRetryTask = nil
        }
        outboxRetryTask = Task { @MainActor [weak self] in
            var pass = 0
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(OutboxRetryPolicy.delay(beforePass: pass) * 1_000_000_000))
                pass += 1
                guard !Task.isCancelled, let self else { return }
                let counts = self.retryableWorkCounts
                guard OutboxRetryPolicy.shouldKeepRetrying(retryableOutboxCount: counts.outbox, pendingSiteAudits: counts.siteAudits) else {
                    self.outboxRetryTask = nil
                    return
                }
                #if canImport(Network)
                self.isOnline = self.networkMonitor.currentPath.status == .satisfied
                #endif
                if OutboxRetryPolicy.shouldRetryNow(
                    retryableOutboxCount: counts.outbox,
                    pendingSiteAudits: counts.siteAudits,
                    isOnline: self.isOnline,
                    isSyncing: self.isSyncing
                ) {
                    await self.performSync(countsAsAttempt: false)
                }
            }
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

        // No cancel of a running pass: it may be mid-send. `performSync` is single-flight.
        syncTask = Task { @MainActor in
            await performSync()
        }
    }

    func retryFailedSync() async {
        guard isOnline else { return }
        await performSync()
    }

    /// Re-check the current network path and push the outbox if we are back online. `userRetry` (the queue sheet's
    /// Retry now): queued site audits start their tries again.
    func refreshConnectionAndSync(userRetry: Bool = false) async {
        if userRetry { SiteAuditOfflineStore.shared.resetAttempts() }
        #if canImport(Network)
        isOnline = networkMonitor.currentPath.status == .satisfied
        #endif
        if isOnline {
            await performSync()
        }
    }

    /// Single-flight: a call while a pass runs waits for that pass (it never starts a second one).
    private func performSync(countsAsAttempt: Bool = true) async {
        await syncFlight.run { [weak self] in
            await self?.performSyncPass(countsAsAttempt: countsAsAttempt)
        }
    }

    private func performSyncPass(countsAsAttempt: Bool) async {
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
            await SiteAuditOfflineStore.shared.syncPending(firebaseBackend: firebaseBackend, countsAsAttempt: countsAsAttempt)
            // Nothing was queued, so nothing replayed: no `.syncOfflineChanges`. Foregrounding used to post it
            // here every time and stores re-saved stale in-memory copies over other devices' edits. Live
            // listeners (re-attached on foreground) bring the server copy instead.
            return
        }

        print("🔥🔥🔥 DEBUG: 🔄 Syncing offline outbox (\(OfflineOutboxStore.shared.pendingCount) entries)")
        let result = await OfflineSyncCoordinator.processOutbox(
            firebaseBackend: firebaseBackend,
            outbox: OfflineOutboxStore.shared,
            countsAsAttempt: countsAsAttempt
        )
        if result.synced > 0 { markSynced() }
        refreshOutboxCounts()
        await SiteAuditOfflineStore.shared.syncPending(firebaseBackend: firebaseBackend, countsAsAttempt: countsAsAttempt)

        // Stores reload after a sync. Booking stores no longer push in-memory state here (RULEBOOK §1
        // partial writes); queued changes replay only from the outbox.
        NotificationCenter.default.post(name: .syncOfflineChanges, object: nil)
        print("🔥🔥🔥 DEBUG: ✅ Offline sync pass finished — remaining: \(OfflineOutboxStore.shared.pendingCount)")
    }

    // MARK: - Cache Management

    func useOrganization(_ organizationId: String) {
        cacheOrganizationId = organizationId.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        lastSyncedAt = Self.storedLastSync(organizationId: resolvedOrganizationId())
    }

    // MARK: - Last synced (RULEBOOK §2 read-only offline)

    private static let lastSyncStoragePrefix = "offline_last_synced_at_"

    /// Call when a server (not cache) snapshot or a server read for the current organisation arrives.
    func markSynced(at date: Date = Date()) {
        lastSyncedAt = date
        let key = Self.lastSyncStoragePrefix + resolvedOrganizationId()
        UserDefaults.standard.set(date.timeIntervalSince1970, forKey: key)
    }

    private static func storedLastSync(organizationId: String) -> Date? {
        let seconds = UserDefaults.standard.double(forKey: lastSyncStoragePrefix + organizationId)
        return seconds > 0 ? Date(timeIntervalSince1970: seconds) : nil
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
        lastSyncedAt = nil
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
