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

    /// Both people lists have finished a load for the open organisation (ids without case).
    static func peopleListsLoaded(organizationId: String, operativesLoadedFor: String?, rosterLoadedFor: String?) -> Bool {
        func key(_ id: String?) -> String { (id ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
        let org = key(organizationId)
        return !org.isEmpty && key(operativesLoadedFor) == org && key(rosterLoadedFor) == org
    }

    /// Firestore's permission-denied code (`FirestoreErrorCode.permissionDenied`).
    static func isPermissionDenied(_ error: Error) -> Bool {
        let ns = error as NSError
        return ns.domain == "FIRFirestoreErrorDomain" && ns.code == 7
    }

    /// A delayed retry of a failed listener attaches again only while someone is signed in and the organisation the
    /// listener was for is still the open one (ids without case). Never another company's listener after a switch.
    static func mayRetryAttach(listenerOrganizationId: String, currentOrganizationId: String?, isAuthenticated: Bool) -> Bool {
        func key(_ id: String?) -> String { (id ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
        let listener = key(listenerOrganizationId)
        return isAuthenticated && !listener.isEmpty && listener == key(currentOrganizationId)
    }

    /// What `organizations/{orgId}` (the settings document) needs when its listener is asked for.
    nonisolated enum OrganizationDocumentAttach: Equatable, Sendable {
        /// The listener for this organisation is attached: nothing to do.
        case keep
        /// This organisation's listener failed (or was dropped by the watchdog): attach it again on its own, leaving
        /// every other listener of the same organisation as it is.
        case reattachSameOrganization
        /// No listener, or another organisation's: the full organisation switch (every listener stops first).
        case replace
    }

    /// `activeTarget` is the target remembered for the settings listener (kept after a failure, so an organisation
    /// switch is still recognised as one); `hasRegistration` whether a Firestore listener is actually attached.
    static func organizationDocumentAttach(activeTarget: String?, requestedTarget: String, hasRegistration: Bool) -> OrganizationDocumentAttach {
        let requested = requestedTarget.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !requested.isEmpty else { return .keep }
        let active = (activeTarget ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !active.isEmpty, active == requested else { return .replace }
        return hasRegistration ? .keep : .reattachSameOrganization
    }

    /// Planned listeners (`listenPlannedSources`: projects, small works, bookings, manager site bookings, subcontractor
    /// bookings) retry their own failed parts, so the watchdog only steps in when the list stands on the cache alone:
    /// online, and either no listener is recorded for the key, or one was attached `grace` seconds ago or more and not
    /// every part has answered from the server yet (`DataParityListenerLedger.Snapshot.serverSnapshot`).
    static func plannedListenerNeedsReattach(
        listenerRecorded: Bool,
        serverAnswered: Bool,
        attachedAt: Date?,
        online: Bool,
        now: Date,
        grace: TimeInterval = 20
    ) -> Bool {
        guard online else { return false }
        guard listenerRecorded else { return true }
        guard !serverAnswered else { return false }
        guard let attachedAt else { return true }
        return now.timeIntervalSince(attachedAt) >= grace
    }

    /// The planned keys the stale-cache watchdog checks (each re-attached by its own owner).
    static let plannedWatchdogKeys = ["projects", "smallWorks", "subcontractorBookings", "bookings", "managerSiteBookings"]
}

/// Single-document listeners ask Firestore for metadata changes so they learn when the server answered (a server copy
/// equal to the cached one raises nothing otherwise). This passes on only snapshots whose data changed (or the first
/// one), so the screen sees exactly the snapshots it saw before metadata changes were switched on.
nonisolated final class DocumentSnapshotDeduper: @unchecked Sendable {
    private let lock = NSLock()
    private var delivered = false
    private var last: NSDictionary?

    init() {}

    /// True when `data` (nil: the document does not exist) differs from the last delivered data, or nothing was
    /// delivered yet. Marks it delivered.
    func shouldDeliver(_ data: [String: Any]?) -> Bool {
        let next = data.map { $0 as NSDictionary }
        lock.lock(); defer { lock.unlock() }
        if delivered {
            switch (last, next) {
            case (nil, nil): return false
            case let (previous?, incoming?) where previous.isEqual(incoming): return false
            default: break
            }
        }
        delivered = true
        last = next
        return true
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

    /// Sign-out: the next session may refresh again.
    func reset() {
        refreshedOrganizationIds = []
    }

    func request() {
        guard let firebaseBackend, firebaseBackend.isAuthenticated,
              let orgId = firebaseBackend.currentOrganization?.firestoreDocumentId else { return }
        // Not while the people lists are still loading for this organisation (a cold-start cache would spend the one
        // refresh before the first server read has even landed).
        guard LiveListenerAttachPolicy.peopleListsLoaded(
            organizationId: orgId,
            operativesLoadedFor: operativeStore?.finishedLoadOrganizationId,
            rosterLoadedFor: userStore?.organizationUsersFinishedLoadOrganizationId
        ) else { return }
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
