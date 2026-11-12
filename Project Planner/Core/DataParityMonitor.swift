//
//  DataParityMonitor.swift
//  Project Planner
//
//  RULEBOOK 1.38.0 §27 "Data check" (owner decision 11 Nov; owner change 11 Nov: nothing is shown in the launch build).
//  Read-only, silent. For every list in `DATA_PARITY_CHECKS` this device listens to, the server's `count()` (server
//  source, never the cache) of exactly the listener's query is compared with the documents that listener received, by
//  stored document id with case kept (`DataParityListenerLedger`), before any reader or store filter — for projects and
//  small works the store's own list plus the placeholder document the readers drop (`readerDroppedCount`, from the
//  ledger) — through `CanonicalBusinessEngine.dataParityCheck`. A list with this device's unconfirmed writes (unless
//  `waitForPendingWrites` finishes within 5 s) or with no server snapshot yet is skipped that time. A difference is acted
//  on only when a second look `DATA_PARITY_CONFIRM_DELAY_MS` later finds it again (`dataParityConfirm`): then the
//  store's listener is removed and attached again (self-heal), the lists are compared again and the result is kept on
//  this device only (`UserDefaults`, the last 20, `dataParityLogAppend`). Nothing is written to Firestore. Runs on open,
//  on return to the foreground and every 10 minutes while the app is active, never offline (`dataParityCheckDue`); the
//  admin panel (Settings → Data health, `DataHealthView`) runs "Check now" only while `platformConfig/app.dataCheckPanel`
//  is on. Device-log lines are DEBUG builds only. App plumbing: every decision is the packed script's.
//

import Combine
import Foundation
import UIKit
@preconcurrency import FirebaseFirestore

@MainActor
final class DataParityMonitor: ObservableObject {
    static let shared = DataParityMonitor()

    /// This device's results for the open organisation, newest last (JSON rows of `dataParityLogEntry`).
    @Published private(set) var log: [[String: Any]] = []
    @Published private(set) var isRunning = false
    /// `dataCheckPanelEnabled(platformConfig/app, open organisation)`, kept fresh on the switch notification, an
    /// organisation switch and return to the foreground (the Settings row and panel read it).
    @Published private(set) var panelSwitchOn = false
    private var panelObserver: NSObjectProtocol?

    private weak var firebaseBackend: FirebaseBackend?
    private weak var projectStore: ProjectStore?
    private weak var operativeStore: OperativeStore?
    private weak var bookingStore: BookingStore?
    private weak var managerScheduleStore: ManagerScheduleStore?
    private weak var userStore: UserStore?
    private weak var taskStore: ProjectTaskStore?
    private weak var holidayStore: HolidayStore?
    private weak var smartCache: SmartCacheService?

    private var loadedOrganizationId: String?
    private var timerTask: Task<Void, Never>?
    private var openTask: Task<Void, Never>?

    /// Listeners usually deliver their first snapshot well within this after they attach.
    private let openDelayNanoseconds: UInt64 = 20_000_000_000
    /// Time for a re-attached listener to deliver its fresh snapshot before the re-check.
    private let healSettleNanoseconds: UInt64 = 3_000_000_000

    private init() {}

    func connect(
        firebaseBackend: FirebaseBackend,
        smartCache: SmartCacheService,
        projectStore: ProjectStore,
        operativeStore: OperativeStore,
        bookingStore: BookingStore,
        managerScheduleStore: ManagerScheduleStore,
        userStore: UserStore,
        taskStore: ProjectTaskStore,
        holidayStore: HolidayStore
    ) {
        self.firebaseBackend = firebaseBackend
        self.smartCache = smartCache
        self.projectStore = projectStore
        self.operativeStore = operativeStore
        self.bookingStore = bookingStore
        self.managerScheduleStore = managerScheduleStore
        self.userStore = userStore
        self.taskStore = taskStore
        self.holidayStore = holidayStore
        if panelObserver == nil {
            panelObserver = NotificationCenter.default.addObserver(
                forName: .dataCheckPanelSwitchDidChange,
                object: nil,
                queue: .main
            ) { _ in
                Task { @MainActor in DataParityMonitor.shared.refreshPanelSwitch() }
            }
        }
        refreshPanelSwitch()
        startTimerIfNeeded()
    }

    /// Reads the panel switch for the open organisation again.
    func refreshPanelSwitch() {
        let next = SecuritySwitchContext.dataCheckPanel
        if next != panelSwitchOn { panelSwitchOn = next }
    }

    /// Whether the admin panel (and its Settings → Data health row) shows: `dataCheckPanelVisible`.
    func panelVisible(viewerIsAdmin: Bool) -> Bool {
        CanonicalBusinessEngine.dataCheckPanelVisible(viewerIsAdmin: viewerIsAdmin, dataCheckPanelEnabled: panelSwitchOn)
    }

    /// The live listeners were (re)attached: run the "open" check once they have had time to load.
    func listenersAttached() {
        // An organisation switch: show that organisation's log and switch.
        if let orgId = firebaseBackend?.currentOrganization?.firestoreDocumentId, !orgId.isEmpty {
            loadLog(organizationId: orgId)
        }
        refreshPanelSwitch()
        openTask?.cancel()
        openTask = Task { @MainActor [weak self] in
            guard let self else { return }
            try? await Task.sleep(nanoseconds: self.openDelayNanoseconds)
            guard !Task.isCancelled else { return }
            await self.run(trigger: "open")
        }
    }

    /// The app became active again.
    func appBecameActive() {
        refreshPanelSwitch()
        Task { @MainActor [weak self] in await self?.run(trigger: "foreground") }
    }

    private func startTimerIfNeeded() {
        guard timerTask == nil else { return }
        timerTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                let interval = CanonicalBusinessEngine.dataParityMinIntervalMs
                try? await Task.sleep(nanoseconds: UInt64(max(60_000, interval) * 1_000_000))
                guard let self, !Task.isCancelled else { return }
                if UIApplication.shared.applicationState == .active {
                    await self.run(trigger: "timer")
                }
            }
        }
    }

    // MARK: Log (this device only)

    private func logKey(_ organizationId: String) -> String { "pp.dataParity.v1.\(organizationId)" }

    func loadLog(organizationId: String) {
        let orgId = normalizedOrganizationId(organizationId)
        guard !orgId.isEmpty, loadedOrganizationId != orgId else { return }
        loadedOrganizationId = orgId
        if let data = UserDefaults.standard.data(forKey: logKey(orgId)),
           let rows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
            log = rows
        } else {
            log = []
        }
    }

    private func saveLog(_ rows: [[String: Any]], organizationId: String) {
        guard JSONSerialization.isValidJSONObject(rows), let data = try? JSONSerialization.data(withJSONObject: rows) else { return }
        UserDefaults.standard.set(data, forKey: logKey(organizationId))
    }

    var latestEntry: [String: Any]? { log.last }

    private var lastCheckedMs: Double? { (log.last?["atMs"] as? NSNumber)?.doubleValue }

    // MARK: Run

    /// One check. `trigger` is `open`, `foreground`, `timer` or `manual` (Check now). Never blocks a screen.
    func run(trigger: String) async {
        guard !isRunning,
              let firebaseBackend,
              firebaseBackend.isAuthenticated,
              let orgId = firebaseBackend.currentOrganization?.firestoreDocumentId,
              !orgId.isEmpty else { return }
        loadLog(organizationId: orgId)
        let online = smartCache?.isOnline ?? true
        let nowMs = Date().timeIntervalSince1970 * 1000
        guard CanonicalBusinessEngine.dataParityCheckDue(trigger: trigger, lastCheckedMs: lastCheckedMs, nowMs: nowMs, online: online) else {
            return
        }
        isRunning = true
        defer { isRunning = false }
        let keys = CanonicalBusinessEngine.dataParityChecks.map(\.key)
        guard !keys.isEmpty, let first = await compare(keys: keys, organizationId: orgId) else { return }
        // The two-look rule: act only on a list a second look still finds different (a save in flight or a snapshot on
        // its way is not a lost record).
        var confirmed = first
        if !first.reloadKeys.isEmpty {
            let delay = UInt64(max(0, CanonicalBusinessEngine.dataParityConfirmDelayMs) * 1_000_000)
            try? await Task.sleep(nanoseconds: delay)
            let second = await compare(keys: first.reloadKeys, organizationId: orgId)
            guard let result = CanonicalBusinessEngine.dataParityConfirm(first: first, confirm: second) else { return }
            confirmed = result
        }
        var recheck: RulebookDataParityResult?
        if !confirmed.reloadKeys.isEmpty {
            for key in confirmed.reloadKeys { await heal(key: key, organizationId: orgId) }
            try? await Task.sleep(nanoseconds: healSettleNanoseconds)
            recheck = await compare(keys: confirmed.reloadKeys, organizationId: orgId)
        }
        guard organizationIdsMatch(firebaseBackend.currentOrganization?.firestoreDocumentId, orgId),
              let entry = CanonicalBusinessEngine.dataParityLogEntry(
                atMs: Date().timeIntervalSince1970 * 1000,
                trigger: trigger,
                first: confirmed,
                recheck: recheck
              ) else { return }
        let next = CanonicalBusinessEngine.dataParityLogAppend(log, entry: entry)
        log = next
        saveLog(next, organizationId: orgId)
        #if DEBUG
        if !confirmed.reloadKeys.isEmpty {
            NSLog("DATA_PARITY_MISMATCH org=%@ lists=%@ healedAll=%@", orgId, confirmed.reloadKeys.joined(separator: ","), (entry["ok"] as? Bool ?? false) ? "yes" : "no")
        }
        #endif
    }

    private func compare(keys: [String], organizationId: String) async -> RulebookDataParityResult? {
        let writesSettled = await Self.pendingWritesSettled(timeoutSeconds: 5)
        var lists: [RulebookDataParityListInput] = []
        for key in keys {
            lists.append(await probe(key: key, organizationId: organizationId, writesSettled: writesSettled))
        }
        return CanonicalBusinessEngine.dataParityCheck(lists: lists)
    }

    // MARK: Probes (server count and held records per list)

    /// What the listener for `key` received (`DataParityListenerLedger`), or a skip: no listener, this device's
    /// unconfirmed writes (unless every write was just confirmed), or no server snapshot for its query yet.
    private func listenerDocuments(
        key: String,
        organizationId: String,
        writesSettled: Bool
    ) -> (snapshot: DataParityListenerLedger.Snapshot?, skip: String?) {
        guard let snapshot = DataParityListenerLedger.shared.snapshot(key: key, organizationId: organizationId) else {
            return (nil, "notListening")
        }
        if snapshot.pendingWrites && !writesSettled { return (snapshot, "pendingWrites") }
        if !snapshot.serverSnapshot { return (snapshot, "awaitingServerSnapshot") }
        return (snapshot, nil)
    }

    private func probe(key: String, organizationId orgId: String, writesSettled: Bool) async -> RulebookDataParityListInput {
        guard let firebaseBackend else { return RulebookDataParityListInput(key: key, skipped: "notListening") }
        let db = Firestore.firestore()
        let org = db.collection("organizations").document(orgId)
        switch key {
        case "projects", "smallWorks":
            guard let projectStore, organizationIdsMatch(projectStore.finishedLoadOrganizationId, orgId) else {
                return RulebookDataParityListInput(key: key, skipped: "notListening")
            }
            let plan = firebaseBackend.jobReadSources(organizationId: orgId, collection: key)
            if Self.planHasDocumentReads(plan.sources) { return RulebookDataParityListInput(key: key, skipped: "documentReads") }
            let listener = listenerDocuments(key: key, organizationId: orgId, writesSettled: writesSettled)
            if let skip = listener.skip { return RulebookDataParityListInput(key: key, skipped: skip) }
            guard let serverCount = await Self.countPlan(plan.sources) else {
                return RulebookDataParityListInput(key: key, skipped: nil)
            }
            let held = key == "projects"
                ? projectStore.projects.filter { !$0.isSmallWorksDocument }
                : ProjectWorksMerge.smallWorksList(store: projectStore.projects, smallWorksDocuments: projectStore.smallWorksDocuments)
            // The legacy placeholder document: counted by the server, left out by the reader (`workDocuments`); counted
            // from what the listener received, so no extra server read.
            return RulebookDataParityListInput(
                key: key,
                serverCount: serverCount,
                localIds: held.map(\.documentId),
                readerDroppedCount: listener.snapshot?.placeholderCount ?? 0
            )
        case "users":
            guard let ids = userStore?.dataParityHeldUserIds(organizationId: orgId) else {
                return RulebookDataParityListInput(key: key, skipped: "notListening")
            }
            let count = await Self.serverCount(db.collection("users").whereField("organizationId", isEqualTo: orgId))
            return RulebookDataParityListInput(key: key, serverCount: count, localIds: ids)
        case "bookings", "managerSiteBookings":
            let start = key == "bookings" ? firebaseBackend.dataParityBookingsListenStart : firebaseBackend.dataParityManagerScheduleListenStart
            guard let start else { return RulebookDataParityListInput(key: key, skipped: "notListening") }
            let plan = firebaseBackend.bookingReadSources(organizationId: orgId, collection: key, startingOn: start)
            if Self.planHasDocumentReads(plan.sources) { return RulebookDataParityListInput(key: key, skipped: "documentReads") }
            let listener = listenerDocuments(key: key, organizationId: orgId, writesSettled: writesSettled)
            if let skip = listener.skip { return RulebookDataParityListInput(key: key, skipped: skip) }
            let serverCount = await Self.countPlan(plan.sources)
            return RulebookDataParityListInput(key: key, serverCount: serverCount, localIds: listener.snapshot?.ids ?? [])
        default:
            guard firebaseBackend.liveListeners.isAttached(key: key) else {
                return RulebookDataParityListInput(key: key, skipped: "notListening")
            }
            let listener = listenerDocuments(key: key, organizationId: orgId, writesSettled: writesSettled)
            if let skip = listener.skip { return RulebookDataParityListInput(key: key, skipped: skip) }
            let count = await Self.serverCount(org.collection(key))
            return RulebookDataParityListInput(key: key, serverCount: count, localIds: listener.snapshot?.ids ?? [])
        }
    }

    /// True when every write this device has queued was confirmed by the server within `timeoutSeconds` (then no
    /// list has unconfirmed writes, whatever its last snapshot said); false offline or while a write is on its way.
    private static func pendingWritesSettled(timeoutSeconds: Double) async -> Bool {
        await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            let once = DataParityResumeOnce(continuation)
            Firestore.firestore().waitForPendingWrites { error in once.resume(error == nil) }
            DispatchQueue.main.asyncAfter(deadline: .now() + timeoutSeconds) { once.resume(false) }
        }
    }

    // MARK: Self-heal

    private func heal(key: String, organizationId orgId: String) async {
        guard let firebaseBackend else { return }
        switch key {
        case "projects", "smallWorks", "clients":
            firebaseBackend.stopLiveListener(key: key)
            projectStore?.startLiveUpdates(organizationId: orgId)
        case "operatives", "managers":
            firebaseBackend.stopLiveListener(key: key)
            operativeStore?.startLiveUpdates(organizationId: orgId)
        case "holidayBookings":
            firebaseBackend.stopLiveListener(key: key)
            holidayStore?.startLiveUpdates(organizationId: orgId)
        case "tasks":
            firebaseBackend.stopLiveListener(key: key)
            taskStore?.startLiveUpdates(organizationId: orgId)
        case "bookings", "managerSiteBookings":
            firebaseBackend.reattachScheduleListenerForDataCheck(collection: key)
        case "users":
            await userStore?.reattachOrganizationUsersForDataCheck(organizationId: orgId)
        default:
            break
        }
    }

    // MARK: Server counts

    nonisolated private static func planHasDocumentReads(_ sources: [PlannedReadSource]) -> Bool {
        sources.contains { if case .document = $0.kind { return true } else { return false } }
    }

    /// The sum of the plan's query counts (`dataParitySumCounts`); nil for a plan with a document read or any count
    /// that could not be read.
    private static func countPlan(_ sources: [PlannedReadSource]) async -> Int? {
        guard !sources.isEmpty, !planHasDocumentReads(sources) else { return nil }
        var counts: [Int?] = []
        for source in sources {
            if case let .query(query, _) = source.kind {
                counts.append(await serverCount(query))
            }
        }
        return CanonicalBusinessEngine.dataParitySumCounts(counts)
    }

    private static func serverCount(_ query: Query) async -> Int? {
        do {
            let snapshot = try await query.count.getAggregation(source: .server)
            return snapshot.count.intValue
        } catch {
            return nil
        }
    }
}

/// Resumes a continuation once (whichever of the pending-writes answer and the timeout comes first).
nonisolated final class DataParityResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Bool, Never>?

    init(_ continuation: CheckedContinuation<Bool, Never>) {
        self.continuation = continuation
    }

    func resume(_ value: Bool) {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume(returning: value)
    }
}
