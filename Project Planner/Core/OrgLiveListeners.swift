//
//  OrgLiveListeners.swift
//  Project Planner
//
//  RULEBOOK §1 "Live screens use real-time listeners": a screen showing shared data listens for changes so a
//  save on web appears here without a refresh. App plumbing only: every snapshot is read through the same
//  rulebook reader as the one-off load (`parseHolidayDocuments`, `parseWorkDocument` via `jobs(fromDocuments:)`,
//  `parseClientDocument`, `parseOperativeDocument`, `parseManagerDocument`, `parseSubcontractorDocument`,
//  `parseSubcontractorBookingDocument`, `parseTaskDocument`, `parseJobTypesDocument`,
//  `parseMaterialSendRecordDocument`, all through `CanonicalBusinessEngine`), and no business rule is computed here.
//
//  One listener per collection per organisation (never per row). All of them live in `OrgListenerRegistry`,
//  which `FirebaseBackend.stopScheduleLiveListeners()` empties on an organisation switch and on sign-out
//  (AGENTS rule 2: never keep another company's listener). Firestore serves the cached copy first and
//  offline, and the same listener resumes with server data when the connection returns.
//

import Foundation
@preconcurrency import FirebaseFirestore

extension Notification.Name {
    /// A live listener changed an input of the warnings scan (annual leave, operatives, managers, dismissed
    /// warnings). RULEBOOK §5: "Warnings refresh whenever bookings, leave, settings or users change".
    static let liveWarningInputsDidChange = Notification.Name("liveWarningInputsDidChange")
    /// The organisation's `annualLeaveDefaults` arrived or changed: users parsed with
    /// `annualLeaveDefaultsPending` are read again (`parseUserDocument`).
    static let organizationAnnualLeaveDefaultsDidChange = Notification.Name("organizationAnnualLeaveDefaultsDidChange")
}

/// Every organisation-scoped live listener this session holds, keyed by name ("holidayBookings",
/// "timesheet", "materialSendRecords", …). Attaching the same target again is a no-op; a different target
/// for the same key replaces the old listener.
nonisolated final class OrgListenerRegistry: @unchecked Sendable {
    private struct Entry {
        let target: String
        let token: UUID
        let remove: () -> Void
    }

    private var entries: [String: Entry] = [:]
    private let lock = NSLock()
    /// Explicit stops per key (`remove(key:)` without a token) and of everything (`removeAll`). A delayed retry
    /// compares the mark it took when it attached: a screen that stopped its listener meanwhile is not re-listened.
    private var stops: [String: Int] = [:]
    private var stopAllCount = 0

    /// Changes whenever `key`'s listener is stopped on purpose (a screen closed it, an organisation switch, sign-out);
    /// never when a failed listener drops itself (`remove(key:token:)`).
    nonisolated struct StopMark: Equatable, Sendable {
        let all: Int
        let key: Int
    }

    func stopMark(key: String) -> StopMark {
        lock.lock(); defer { lock.unlock() }
        return StopMark(all: stopAllCount, key: stops[key] ?? 0)
    }

    init() {}

    /// True when `key` has no listener for `target` (a new one should attach).
    func needsAttach(key: String, target: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        // Same rule as `LaunchStartupPolicy.shouldAttachListener` (kept here: this type is nonisolated).
        let requested = target.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !requested.isEmpty else { return false }
        return entries[key]?.target != requested
    }

    /// Stores the listener for `key`, removing any other one it replaces. Returns its token.
    @discardableResult
    func set(key: String, target: String, remove: @escaping () -> Void) -> UUID {
        let token = UUID()
        lock.lock()
        let previous = entries[key]
        entries[key] = Entry(target: target, token: token, remove: remove)
        lock.unlock()
        previous?.remove()
        return token
    }

    /// The listener with `token` stays attached, but the next `needsAttach` for `key` is true, so a re-plan replaces
    /// it (and `set` removes it). A newer listener for `key` is left alone.
    func markForReattach(key: String, token: UUID) {
        lock.lock(); defer { lock.unlock() }
        guard let entry = entries[key], entry.token == token else { return }
        entries[key] = Entry(target: "", token: entry.token, remove: entry.remove)
    }

    /// Removes `key`'s listener, or only the one with `token` when given (a failed listener drops itself so the
    /// next foreground can attach it again, without removing a newer replacement).
    func remove(key: String, token: UUID? = nil) {
        lock.lock()
        if token == nil { stops[key, default: 0] += 1 }
        let entry = entries[key]
        if let entry, token == nil || entry.token == token {
            entries[key] = nil
        } else {
            lock.unlock()
            return
        }
        lock.unlock()
        entry?.remove()
    }

    /// Organisation switch and sign-out.
    func removeAll() {
        lock.lock()
        stopAllCount += 1
        let all = Array(entries.values)
        entries.removeAll()
        lock.unlock()
        all.forEach { $0.remove() }
    }

    func isAttached(key: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return entries[key] != nil
    }

    var count: Int {
        lock.lock(); defer { lock.unlock() }
        return entries.count
    }
}

/// How a listener snapshot replaces an in-memory list (the bookings rule, `BookingStore.applyRemoteBookings`):
/// a server snapshot is the whole collection and replaces the list, so a record deleted on web leaves this
/// device too. A cache snapshot never empties a list already on screen, and a shorter one only adds and updates.
///
/// `rowCount` is how many readable documents the snapshot or load held (`readableRowCount`). When it is above zero
/// but the reader produced no record at all, the reader failed (the script did not answer, or a value it cannot
/// take), not the collection: the list on screen is kept, the refusal is logged and recorded for the diagnostics
/// report (`ReaderDiagnostics`). A collection that is really empty has `rowCount` 0 and still empties the list.
enum LiveSnapshotMerge {
    /// The list to publish, or nil when the snapshot must not change what is on screen.
    static func apply<T: Identifiable>(
        existing: [T],
        incoming: [T],
        fromCache: Bool,
        rowCount: Int? = nil,
        collection: String = ""
    ) -> [T]? {
        if let rowCount, refusesUnreadSnapshot(
            collection: collection,
            rowCount: rowCount,
            parsedCount: incoming.count,
            existingCount: existing.count,
            fromCache: fromCache
        ) {
            return nil
        }
        guard fromCache else { return incoming }
        if incoming.isEmpty && !existing.isEmpty { return nil }
        guard incoming.count < existing.count else { return incoming }
        var byId = Dictionary(existing.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var order: [T.ID] = []
        var seen = Set<T.ID>()
        for item in existing where seen.insert(item.id).inserted { order.append(item.id) }
        for item in incoming {
            if seen.insert(item.id).inserted { order.append(item.id) }
            byId[item.id] = item
        }
        return order.compactMap { byId[$0] }
    }

    /// True when `rowCount` documents arrived, the reader made none of them into a record, and a list is already
    /// on screen: that list must stay. Logs and records the refusal. Used by every listener and loader whose list
    /// a failed reader could otherwise empty (projects, small works, clients, operatives, managers, users, leave).
    @discardableResult
    static func refusesUnreadSnapshot(
        collection: String,
        rowCount: Int,
        parsedCount: Int,
        existingCount: Int,
        fromCache: Bool
    ) -> Bool {
        guard rowCount > 0, parsedCount == 0 else { return false }
        // Recorded even with nothing on screen: the owner can then see the reader failed, not the data.
        ReaderDiagnostics.shared.record(
            collection: collection,
            rowCount: rowCount,
            parsedCount: parsedCount,
            keptCount: existingCount,
            source: fromCache ? "cache snapshot" : "server snapshot"
        )
        return existingCount > 0
    }

    /// Documents in a snapshot that a reader could make into a record: every document except the legacy
    /// placeholder, which `workDocuments` drops. When the script does not answer, every row counts (that is the
    /// failure this count guards against).
    static func readableRowCount(_ rows: LiveDocumentRows) -> Int {
        readableRowCount(ids: rows.map(\.id))
    }

    /// A one-off load (`loadProjects`, `loadOperatives`, …): true, logged and recorded, when it read readable
    /// documents and the reader made none of them into a record. The caller then keeps the list it has.
    static func loadYieldedNothing(collection: String, documentIds: [String], parsedCount: Int) -> Bool {
        guard parsedCount == 0 else { return false }
        let rowCount = readableRowCount(ids: documentIds)
        guard rowCount > 0 else { return false }
        ReaderDiagnostics.shared.record(
            collection: collection,
            rowCount: rowCount,
            parsedCount: 0,
            keptCount: 0,
            source: "one-off load (list on screen kept)"
        )
        return true
    }

    static func readableRowCount(ids: [String]) -> Int {
        guard !ids.isEmpty else { return 0 }
        let documents: [[String: Any]] = ids.map { ["id": $0] }
        return CanonicalBusinessEngine.workDocuments(projects: documents, smallWorks: [])?.count ?? ids.count
    }
}

/// Every time a reader turned a non-empty snapshot or load into no records (or a user document could not be read
/// by the rulebook), with counts. NSLog'd as `READER_YIELDED_NOTHING` and listed in Settings → diagnostic report
/// (`FirebaseBackend.diagnoseMissingData`), so a device that shows empty lists says why. App plumbing, not a rule.
nonisolated final class ReaderDiagnostics: @unchecked Sendable {
    static let shared = ReaderDiagnostics()

    nonisolated struct Event: Equatable, Sendable {
        let at: Date
        let collection: String
        let rowCount: Int
        let parsedCount: Int
        let keptCount: Int
        let source: String
    }

    private let lock = NSLock()
    private var stored: [Event] = []
    private let limit = 40

    init() {}

    func record(collection: String, rowCount: Int, parsedCount: Int, keptCount: Int, source: String) {
        let event = Event(
            at: Date(),
            collection: collection.isEmpty ? "?" : collection,
            rowCount: rowCount,
            parsedCount: parsedCount,
            keptCount: keptCount,
            source: source
        )
        NSLog(
            "READER_YIELDED_NOTHING collection=%@ source=%@ documents=%d records=%d keptOnScreen=%d scriptAnswers=%@",
            event.collection, source, rowCount, parsedCount, keptCount,
            Self.scriptAnswers() ? "yes" : "NO"
        )
        lock.lock()
        stored.append(event)
        if stored.count > limit { stored.removeFirst(stored.count - limit) }
        lock.unlock()
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .rulebookReaderYieldedNothing, object: nil)
        }
    }

    var events: [Event] {
        lock.lock(); defer { lock.unlock() }
        return stored
    }

    func reset() {
        lock.lock(); stored.removeAll(); lock.unlock()
    }

    /// Whether the packed script answers at all (a cheap call that always returns a value).
    static func scriptAnswers() -> Bool {
        CanonicalBusinessEngine.callJSON("organizationTimeZone", arguments: ["GB"]) is String
    }

    /// Text for the diagnostic report.
    func summary() -> String {
        var text = "   Rulebook script answers: \(Self.scriptAnswers() ? "yes" : "NO — every reader returns nothing")\n"
        let list = events
        if list.isEmpty {
            text += "   ✅ No reader refused a non-empty snapshot or load\n"
            return text
        }
        let formatter = ISO8601DateFormatter()
        for event in list.suffix(15) {
            text += "   ⚠️ \(formatter.string(from: event.at)) \(event.collection) (\(event.source)): "
            text += "\(event.rowCount) documents → \(event.parsedCount) records; kept \(event.keptCount) on screen\n"
        }
        return text
    }
}

/// Thrown by a one-off load whose documents the reader could not read at all, so the store keeps its list
/// (a failed load never empties a screen) instead of publishing nothing.
nonisolated struct RulebookReaderYieldedNothingError: LocalizedError {
    let collection: String
    let rowCount: Int
    var errorDescription: String? {
        "\(rowCount) \(collection) records could not be read on this device. The list already on screen was kept."
    }
}

extension Notification.Name {
    /// `ReaderDiagnostics` recorded a refusal (a screen can show a "could not read" notice).
    nonisolated static let rulebookReaderYieldedNothing = Notification.Name("rulebookReaderYieldedNothing")
}

/// The registry token of one listener, set after the listener is created (its error handler reads it).
nonisolated final class LiveListenerToken: @unchecked Sendable {
    var value: UUID?
    init() {}
}

typealias LiveDocumentRows = [(id: String, data: [String: Any])]

extension FirebaseBackend {
    /// Whether a listener snapshot for `organizationId` still belongs to the open organisation.
    func acceptsLiveSnapshot(organizationId: String) -> Bool {
        WarningsBookingScanScheduler.acceptsListener(
            listenerOrganizationId: organizationId,
            currentOrganizationId: currentOrganization?.firestoreDocumentId,
            sessionOrganizationId: sessionOrganizationId
        )
    }

    /// One snapshot listener on a query under `organizations/{orgId}`, registered as `key`. Calling it again for
    /// the same key and target does nothing (foreground re-attach is free). A failed listener removes itself and is
    /// attached again after `LiveListenerAttachPolicy.retryDelay` while the same organisation is open (before 13 Nov
    /// it waited for the next foreground return, so a cached list could stand alone for the whole session).
    /// `onChange` runs on the main actor with the documents as `(id, data)` rows for the rulebook reader.
    func listenOrganizationQuery(
        key: String,
        organizationId: String,
        targetSuffix: String = "",
        retryOnFailure: Bool = false,
        query makeQuery: @escaping (DocumentReference) -> Query,
        onChange: @escaping @MainActor (_ rows: LiveDocumentRows, _ fromCache: Bool) -> Void
    ) {
        let orgId = normalizedOrganizationId(organizationId)
        guard !orgId.isEmpty, isAuthenticated else { return }
        let target = "\(key):\(orgId)|\(targetSuffix)"
        let registry = liveListeners
        guard registry.needsAttach(key: key, target: target) else { return }
        let token = LiveListenerToken()
        // RULEBOOK 1.38.0 §27: what this listener received, by stored document id, for the data check.
        let ledger = DataParityListenerLedger.shared
        let generation = ledger.begin(key: key, organizationId: orgId, sourceCount: 1)
        let delivered = SnapshotDeliveredFlag()
        // Metadata changes are on only so the data check learns when the server answered (a cache-first listener
        // whose server confirmation changes no document raises nothing otherwise); such snapshots stop at the ledger.
        let registration = makeQuery(db.collection("organizations").document(orgId))
            .addSnapshotListener(includeMetadataChanges: true) { [weak self] snapshot, error in
                if let error {
                    NSLog("LIVE_LISTENER_FAILED key=%@ org=%@ error=%@", key, orgId, error.localizedDescription)
                    ledger.markFailed(key: key, generation: generation, source: 0)
                    let failures = LiveListenerClock.shared.markFailed(key: key, organizationId: orgId)
                    // Only organisation-wide listeners retry on their own; a screen's listener is attached again when
                    // the screen appears or the app returns to the foreground (it may have closed meanwhile).
                    let delay = retryOnFailure ? LiveListenerAttachPolicy.retryDelay(
                        afterFailures: failures,
                        permissionDenied: LiveListenerAttachPolicy.isPermissionDenied(error)
                    ) : nil
                    Task { @MainActor [weak self] in
                        if let value = token.value { registry.remove(key: key, token: value) }
                        guard let delay else { return }
                        try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                        guard let self, self.isAuthenticated,
                              organizationIdsMatch(self.currentOrganization?.firestoreDocumentId, orgId) else { return }
                        self.listenOrganizationQuery(
                            key: key,
                            organizationId: orgId,
                            targetSuffix: targetSuffix,
                            retryOnFailure: true,
                            query: makeQuery,
                            onChange: onChange
                        )
                    }
                    return
                }
                guard let snapshot else { return }
                let fromCache = snapshot.metadata.isFromCache
                if !fromCache { LiveListenerClock.shared.markServerSnapshot(key: key, organizationId: orgId) }
                let heldIdsChanged = ledger.record(
                    key: key,
                    generation: generation,
                    source: 0,
                    ids: snapshot.documents.map(\.documentID),
                    fromCache: fromCache,
                    hasPendingWrites: snapshot.metadata.hasPendingWrites
                )
                if DataParityListenerLedger.isMetadataOnly(
                    documentChangeCount: snapshot.documentChanges.count,
                    deliveredBefore: delivered.wasDelivered,
                    heldIdsChanged: heldIdsChanged
                ) { return }
                _ = delivered.markDelivered()
                let rows: LiveDocumentRows = snapshot.documents.map { (id: $0.documentID, data: $0.data()) }
                Task { @MainActor in
                    guard let self, self.acceptsLiveSnapshot(organizationId: orgId) else { return }
                    onChange(rows, fromCache)
                }
            }
        token.value = registry.set(key: key, target: target, remove: { registration.remove() })
        LiveListenerClock.shared.markAttached(key: key, organizationId: orgId)
    }

    /// One snapshot listener on a single document under `organizations/{orgId}`. `data` is nil when the
    /// document does not exist. `hasPendingWrites` is true for this device's own unsent write. With `retryOnFailure`
    /// (organisation-wide documents only), a failed listener is attached again after
    /// `LiveListenerAttachPolicy.retryDelay` while the same organisation is open and someone is signed in; a screen's
    /// document listener is attached again when the screen appears (it may have closed meanwhile).
    /// Metadata changes are on only so `LiveListenerClock` learns when the server answered; `DocumentSnapshotDeduper`
    /// passes on only snapshots whose data changed, as before.
    func listenOrganizationDocument(
        key: String,
        organizationId: String,
        retryOnFailure: Bool = false,
        document makeRef: @escaping (DocumentReference) -> DocumentReference,
        onChange: @escaping @MainActor (_ data: [String: Any]?, _ fromCache: Bool, _ hasPendingWrites: Bool) -> Void
    ) {
        let orgId = normalizedOrganizationId(organizationId)
        guard !orgId.isEmpty, isAuthenticated else { return }
        let ref = makeRef(db.collection("organizations").document(orgId))
        let target = "\(key):\(ref.path)"
        let registry = liveListeners
        guard registry.needsAttach(key: key, target: target) else { return }
        let token = LiveListenerToken()
        let deduper = DocumentSnapshotDeduper()
        // Taken before attaching: a stop after this point (the screen closed, a switch) cancels a pending retry.
        let stopMark = registry.stopMark(key: key)
        let registration = ref.addSnapshotListener(includeMetadataChanges: true) { [weak self] snapshot, error in
            if let error {
                NSLog("LIVE_LISTENER_FAILED key=%@ path=%@ error=%@", key, ref.path, error.localizedDescription)
                let failures = LiveListenerClock.shared.markFailed(key: key, organizationId: orgId)
                let delay = retryOnFailure ? LiveListenerAttachPolicy.retryDelay(
                    afterFailures: failures,
                    permissionDenied: LiveListenerAttachPolicy.isPermissionDenied(error)
                ) : nil
                Task { @MainActor [weak self] in
                    if let value = token.value { registry.remove(key: key, token: value) }
                    guard let delay else { return }
                    try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                    // Never over a newer listener for the key (another document, attached by its screen meanwhile).
                    guard let self, registry.stopMark(key: key) == stopMark, !registry.isAttached(key: key),
                          LiveListenerAttachPolicy.mayRetryAttach(
                            listenerOrganizationId: orgId,
                            currentOrganizationId: self.currentOrganization?.firestoreDocumentId,
                            isAuthenticated: self.isAuthenticated
                          ) else { return }
                    // A no-op when the screen or a foreground return attached it again meanwhile (`needsAttach`).
                    self.listenOrganizationDocument(
                        key: key,
                        organizationId: orgId,
                        retryOnFailure: true,
                        document: makeRef,
                        onChange: onChange
                    )
                }
                return
            }
            guard let snapshot else { return }
            let fromCache = snapshot.metadata.isFromCache
            if !fromCache { LiveListenerClock.shared.markServerSnapshot(key: key, organizationId: orgId) }
            let pending = snapshot.metadata.hasPendingWrites
            let data = snapshot.exists ? snapshot.data() : nil
            guard deduper.shouldDeliver(data) else { return }
            Task { @MainActor in
                guard let self, self.acceptsLiveSnapshot(organizationId: orgId) else { return }
                onChange(data, fromCache, pending)
            }
        }
        token.value = registry.set(key: key, target: target, remove: { registration.remove() })
        LiveListenerClock.shared.markAttached(key: key, organizationId: orgId)
    }

    /// Stops one keyed listener (a screen that listened while open has closed).
    func stopLiveListener(key: String) {
        liveListeners.remove(key: key)
        DataParityListenerLedger.shared.end(key: key)
    }

    /// Live `materialSendRecords` for one job while its order history is open (`parseMaterialSendRecordDocument`
    /// via `materialSendRecord(documentId:data:)`), newest first. The screen stops it when it closes.
    func listenMaterialSendRecords(
        organizationId: String,
        projectId: UUID,
        onChange: @escaping @MainActor ([MaterialSendRecord]) -> Void
    ) {
        let values = JobKeys.queryValues(for: projectId)
        listenOrganizationQuery(
            key: "materialSendRecords",
            organizationId: organizationId,
            targetSuffix: projectId.uuidString,
            query: { $0.collection("materialSendRecords").whereField("projectId", in: values) }
        ) { rows, fromCache in
            guard !fromCache else { return }
            let records = rows.compactMap { FirebaseBackend.materialSendRecord(documentId: $0.id, data: $0.data) }
                .sorted { $0.sentAt > $1.sentAt }
            onChange(records)
        }
    }

    /// `dismissedWarnings` (RULEBOOK §5): the warnings scan reads the keys fresh each time; this listener only
    /// asks for a rescan when another device dismisses or restores a warning.
    func startDismissedWarningsListener(organizationId: String) {
        listenOrganizationQuery(
            key: "dismissedWarnings",
            organizationId: organizationId,
            query: { $0.collection("dismissedWarnings") }
        ) { _, fromCache in
            guard !fromCache else { return }
            NotificationCenter.default.post(name: .liveWarningInputsDidChange, object: nil)
        }
    }
}

/// RULEBOOK 1.9.0 §1: where iOS holds the listener for every `LIVE_COLLECTIONS` row with `listen: true`
/// (`screenMustListen`). `OrgLiveListenersTests` compares this list with the packed script's `LIVE_COLLECTIONS`, so a
/// collection web adds to the list fails the tests until iOS listens to it. Values say where; a row iOS never shows
/// says so (it then needs no listener). App plumbing, not a rule.
nonisolated enum IOSLiveListenerCoverage {
    /// Marks a collection no iOS screen shows (no listener is needed until one does).
    static let notShownOnIOS = "not shown on iOS"

    static let listeners: [String: String] = [
        "organization": "FirebaseBackend organizationDocumentListener (organizations/{orgId})",
        "users": "FirebaseBackend users where organizationId (live roster) + observeCurrentUserDocument",
        "bookings": "FirebaseBackend booking listener (bookingLoadStart)",
        "managerSiteBookings": "FirebaseBackend managerSiteBookings listener (bookingLoadStart)",
        "subcontractorBookings": "SubcontractorStore.startLiveUpdates (key subcontractorBookings)",
        "projects": "ProjectStore.startLiveUpdates (key projects)",
        "smallWorks": "ProjectStore.startLiveUpdates (key smallWorks)",
        "holidayBookings": "HolidayStore live listener (key holidayBookings)",
        "timesheets": "InvoicingView open sheet (listenOrganizationDocument settings/timesheet_*)",
        "operatives": "OperativeStore.startLiveUpdates (key operatives)",
        "managers": "OperativeStore.startLiveUpdates (key managers)",
        "clients": "ProjectStore.startLiveUpdates (key clients)",
        "subcontractors": "SubcontractorStore.startLiveUpdates (key subcontractors)",
        "operativeDayRateHistory": "InvoicingView timesheet screens and ManageUsersView Edit User (listensWhileOpen)",
        "warningResolutions": "WarningResolutionStore resolutionListener",
        "acceptedBookingClashes": "WarningResolutionStore acceptedClashListener",
        "dismissedWarnings": "FirebaseBackend.startDismissedWarningsListener",
        "materials": "FirebaseBackend materials listener (per job)",
        "materialSendRecords": "FirebaseBackend.listenMaterialSendRecords (order history open)",
        "materialCatalogue": "MaterialsCatalogueFlow (listensWhileOpen)",
        "wholesalers": "WholesalersView (listensWhileOpen)",
        "siteAudits": "SiteAuditView job audits (listensWhileOpen)",
        "tasks": "ProjectTaskStore.startLiveUpdates (key tasks)",
        "healthSafety": "ProjectHealthSafetyView (listensWhileOpen on healthSafetyDocumentIds)",
        "variations": "VariationStore.observeVariations",
        "variationTrackers": "VariationStore.observeVariationTracker",
        "deadlines": "ProjectDeadlinesView (listensWhileOpen on deadlines_{KEY} + deadlineAssignments)",
        "notifications": "NotificationService notificationsListener (userId == signed-in user, newest 150)",
        "jobTypes": "ProjectStore.startLiveUpdates (key jobTypes)",
        "skills": notShownOnIOS + " (the skills catalogue is retired on iOS)",
        "qualifications": "OperativeStore.startLiveUpdates (key qualifications)",
        // RULEBOOK 1.29.0 §25: while the Overtime screens are open (CanonicalBusinessEngine.liveCollections).
        "overtimeRequests": "OvertimeRangesView / OvertimeLinesView (FirebaseBackend.listenOvertimeRequests, userId ==)",
        "overtimeReviews": "OvertimeLinesView (FirebaseBackend.listenOvertimeReviews, userId ==)",
        // RULEBOOK 1.30.0 §26.
        "priceWorkItems": "PayeClaimsRangeView (FirebaseBackend.listenPayeClaims, userId ==)",
        "expenseItems": "PayeClaimsRangeView (FirebaseBackend.listenPayeClaims, userId ==)",
        "personalSiteAudits": "PersonalSiteAuditsView / PersonalSiteAuditPickerSheet (FirebaseBackend.listenPersonalSiteAudits, ownerUserId ==)",
    ]

    /// `LIVE_COLLECTIONS` ids with `listen: true` that have no entry above. Empty when iOS covers them all.
    static func uncoveredListenIds(_ rows: [CanonicalLiveCollection] = CanonicalBusinessEngine.liveCollections) -> [String] {
        rows.filter { $0.listen && listeners[$0.id] == nil }.map(\.id)
    }
}
