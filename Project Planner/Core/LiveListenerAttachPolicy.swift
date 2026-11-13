//
//  LiveListenerAttachPolicy.swift
//  Project Planner
//
//  RULEBOOK §1 "Live screens use real-time listeners": a cache may give the first paint; it is never the only read.
//  Owner report 13 Nov: the Scheduling grid and Daily Overview showed "Unknown person" for catalogue operatives
//  until the app was reloaded — the phone held a cached operatives list and no live listener was delivering
//  (a failed listener removed itself and was attached again only on the next return to the foreground; a failed
//  roster listener was never attached again in that session). App plumbing, not a business rule: these decide only
//  when this device reads again from the server.
//

import Foundation

nonisolated enum LiveListenerAttachPolicy {
    /// Seconds to wait before attaching a failed listener again, by how many times it has failed in a row. Nil: stop
    /// retrying until the next launch, foreground return or organisation switch. A permission refusal is retried once
    /// (fresh auth claims can arrive a moment later); anything else (network, unavailable) with a growing back-off.
    static func retryDelay(afterFailures failures: Int, permissionDenied: Bool) -> TimeInterval? {
        guard failures >= 1 else { return nil }
        if permissionDenied { return failures == 1 ? 30 : nil }
        let steps: [TimeInterval] = [5, 15, 45, 120, 300]
        return failures <= steps.count ? steps[failures - 1] : nil
    }

    /// True when the list on screen is standing on a cached copy alone and must be read from the server: the
    /// device is online and either no listener is attached, or one was attached `grace` seconds ago or more and no
    /// server snapshot has arrived since.
    static func needsServerRead(
        attachedAt: Date?,
        lastServerSnapshotAt: Date?,
        online: Bool,
        now: Date,
        grace: TimeInterval = 20
    ) -> Bool {
        guard online else { return false }
        guard let attachedAt else { return true }
        if let server = lastServerSnapshotAt, server >= attachedAt { return false }
        return now.timeIntervalSince(attachedAt) >= grace
    }

    /// A booked person id that names nobody on this device asks for one fresh server read of the people lists, once
    /// per organisation per session (never a loop: a second unknown id in the same organisation asks nothing).
    static func shouldRefreshForUnknownPerson(organizationId: String, alreadyRefreshed: Set<String>) -> Bool {
        let orgId = organizationId.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !orgId.isEmpty else { return false }
        return !alreadyRefreshed.contains(orgId)
    }

    /// Firestore's permission-denied code (`FirestoreErrorCode.permissionDenied`).
    static func isPermissionDenied(_ error: Error) -> Bool {
        let ns = error as NSError
        return ns.domain == "FIRFirestoreErrorDomain" && ns.code == 7
    }
}

/// When each keyed organisation listener was attached, when its last server snapshot arrived, and how many times in a
/// row it failed. Read by the stale-cache watchdog (`LiveListenerAttachPolicy.needsServerRead`).
nonisolated final class LiveListenerClock: @unchecked Sendable {
    static let shared = LiveListenerClock()

    private let lock = NSLock()
    private var attached: [String: Date] = [:]
    private var server: [String: Date] = [:]
    private var failures: [String: Int] = [:]

    init() {}

    private static func slot(_ key: String, _ organizationId: String) -> String {
        "\(key)|\(organizationId.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())"
    }

    func markAttached(key: String, organizationId: String, at date: Date = Date()) {
        lock.lock(); attached[Self.slot(key, organizationId)] = date; lock.unlock()
    }

    func markDetached(key: String, organizationId: String) {
        lock.lock(); attached[Self.slot(key, organizationId)] = nil; lock.unlock()
    }

    /// A server (not cache) snapshot arrived: the listener works, so its failure count resets.
    func markServerSnapshot(key: String, organizationId: String, at date: Date = Date()) {
        let slot = Self.slot(key, organizationId)
        lock.lock(); server[slot] = date; failures[slot] = 0; lock.unlock()
    }

    /// One more failure in a row; returns the new count.
    func markFailed(key: String, organizationId: String) -> Int {
        let slot = Self.slot(key, organizationId)
        lock.lock(); defer { lock.unlock() }
        attached[slot] = nil
        let next = (failures[slot] ?? 0) + 1
        failures[slot] = next
        return next
    }

    /// A launch, foreground return or organisation switch starts the retries afresh.
    func resetFailures(organizationId: String) {
        let suffix = "|\(organizationId.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())"
        lock.lock(); failures = failures.filter { !$0.key.hasSuffix(suffix) }; lock.unlock()
    }

    func attachedAt(key: String, organizationId: String) -> Date? {
        lock.lock(); defer { lock.unlock() }
        return attached[Self.slot(key, organizationId)]
    }

    func lastServerSnapshotAt(key: String, organizationId: String) -> Date? {
        lock.lock(); defer { lock.unlock() }
        return server[Self.slot(key, organizationId)]
    }

    func reset() {
        lock.lock(); attached.removeAll(); server.removeAll(); failures.removeAll(); lock.unlock()
    }
}

/// Safety net (owner report 13 Nov): a booked person id that names nobody on this device — no operatives row, no
/// account — asks for one fresh server read of the operatives list and the roster, once per organisation per session
/// (`LiveListenerAttachPolicy.shouldRefreshForUnknownPerson`). Display only: nothing is written. The screens redraw
/// from the stores when the read lands.
@MainActor
final class UnknownBookedPersonRefresh {
    static let shared = UnknownBookedPersonRefresh()

    private weak var firebaseBackend: FirebaseBackend?
    private weak var operativeStore: OperativeStore?
    private weak var userStore: UserStore?
    private(set) var refreshedOrganizationIds: Set<String> = []

    func connect(firebaseBackend: FirebaseBackend, operativeStore: OperativeStore, userStore: UserStore) {
        self.firebaseBackend = firebaseBackend
        self.operativeStore = operativeStore
        self.userStore = userStore
    }

    /// Called by the naming code when a booked id resolves to nobody. Safe to call from a view body.
    nonisolated static func report() {
        Task { @MainActor in shared.request() }
    }

    func request() {
        guard let firebaseBackend, firebaseBackend.isAuthenticated,
              let orgId = firebaseBackend.currentOrganization?.firestoreDocumentId else { return }
        guard LiveListenerAttachPolicy.shouldRefreshForUnknownPerson(
            organizationId: orgId,
            alreadyRefreshed: refreshedOrganizationIds
        ) else { return }
        refreshedOrganizationIds.insert(orgId.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
        NSLog("UNKNOWN_BOOKED_PERSON_SERVER_READ org=%@", orgId)
        operativeStore?.loadData()
        operativeStore?.startLiveUpdates(organizationId: orgId)
        Task { await self.userStore?.loadOrganizationUsers(forceRefresh: true) }
    }
}
