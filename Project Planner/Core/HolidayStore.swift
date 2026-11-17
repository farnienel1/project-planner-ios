//
//  HolidayStore.swift
//  Project Planner
//

import Foundation
import Combine
import FirebaseAuth
import FirebaseFirestore

@MainActor
class HolidayStore: ObservableObject {
    @Published var bookings: [HolidayBooking] = [] {
        didSet { revision &+= 1 }
    }
    /// Bumped on every change to `bookings`, so booking-flow conflict checks can be memoised per data version.
    private(set) var revision = 0
    @Published var isLoading = false
    @Published var errorMessage: String?
    /// The organisation whose annual leave last finished loading (read, listener snapshot, or failed).
    /// Warnings wait for it (`WarningInputsReadiness`): leave not read yet must not list people as unbooked.
    private(set) var finishedLoadOrganizationId: String?

    private var firebaseBackend: FirebaseBackend?
    private var smartCache: SmartCacheService?
    private var isLoadingInFlight = false
    private var pendingWritesObserver: AnyCancellable?
    private var lateRefusalObserver: NSObjectProtocol?
    /// 1.33.1: the last save was kept on this phone and the server has not confirmed it yet (Pending sync).
    @Published private(set) var lastSaveWasPendingSync = false

    init() {
        // 1.33.1: rows re-draw "Pending sync" when a leave write Firestore holds is confirmed or refused.
        pendingWritesObserver = SDKPendingWrites.shared.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
        // A leave write refused after its wait: Firestore rolled it back; the server's copy is read again.
        lateRefusalObserver = NotificationCenter.default.addObserver(
            forName: SDKPendingWrites.lateRefusalNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            let collection = note.userInfo?["collection"] as? String
            guard collection == LeaveWriteAck.collection else { return }
            Task { @MainActor [weak self] in
                await self?.loadData()
            }
        }
        // RULEBOOK 1.56.0: re-plan on the switch, user and own-id changes; clear leave on sign-out.
        observeReplans()
        NotificationCenter.default.addObserver(
            forName: .organizationDidLoad,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard self.firebaseBackend?.hasBootstrappedOrgDataLoad == true else { return }
                // Bootstrap owns holiday loads; avoid a post-bootstrap duplicate fetch.
            }
        }
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    private func resolveOrganizationId() async throws -> String {
        guard let fb = firebaseBackend, fb.isAuthenticated else {
            throw NSError(domain: "HolidayStore", code: 401, userInfo: [NSLocalizedDescriptionKey: "You must be signed in to manage annual leave."])
        }

        if let orgId = fb.currentOrganization?.firestoreDocumentId, !orgId.isEmpty {
            return orgId
        }

        if let userId = fb.currentUser?.uid {
            await fb.loadUserOrganizationWithRecovery(userId: userId)
        }

        if let orgId = fb.currentOrganization?.firestoreDocumentId, !orgId.isEmpty {
            return orgId
        }

        throw NSError(domain: "HolidayStore", code: 404, userInfo: [NSLocalizedDescriptionKey: "Organization not loaded yet. Please try again in a moment."])
    }

    func setFirebaseBackend(_ backend: FirebaseBackend) {
        firebaseBackend = backend
    }

    func setSmartCache(_ smartCache: SmartCacheService) {
        self.smartCache = smartCache
    }

    // MARK: Offline (RULEBOOK §2: annual leave requests are allowed offline)

    private var isOffline: Bool { smartCache?.isOnline == false }

    /// "Pending sync": this request has a change the server has not confirmed — queued in the outbox (offline), or
    /// (1.33.1) held by Firestore after the save's short wait (`LeaveWriteAck`).
    func isPendingSync(_ booking: HolidayBooking) -> Bool {
        LeaveWriteAck.isPending(documentId: booking.documentId)
    }

    /// One leave save's waits (`BookingWriteSession`): the organisation is checked once, every wait is short.
    private func writeSession(_ orgId: String) -> BookingWriteSession {
        BookingWriteSession(organizationId: orgId)
    }

    /// The signed-in person's own request: only those are queued offline. Deciding or booking leave for someone
    /// else is an approval (online only, `approvals.annual_leave`).
    private func isOwnRequest(_ booking: HolidayBooking) -> Bool {
        guard let uid = firebaseBackend?.currentUser?.uid, !uid.isEmpty else { return false }
        return booking.userId == uid
    }

    private func offlineOrganizationId() throws -> String {
        if let orgId = firebaseBackend?.currentOrganization?.firestoreDocumentId, !orgId.isEmpty { return orgId }
        if let orgId = firebaseBackend?.resolvedOrganizationIdForOfflineWrites(), !orgId.isEmpty { return orgId }
        throw NSError(domain: "HolidayStore", code: 404, userInfo: [NSLocalizedDescriptionKey: "Organization not loaded yet. Please try again in a moment."])
    }

    /// Offline and not the person's own request: refused with the online-only message.
    private func requireOnlineUnlessOwn(_ booking: HolidayBooking) throws {
        guard isOffline, !isOwnRequest(booking) else { return }
        throw NSError(domain: "HolidayStore", code: 503, userInfo: [NSLocalizedDescriptionKey: OfflinePolicy.onlineOnlyMessage])
    }

    /// Queues the person's own new request (`holidayRequestWriteFields`) and keeps it on screen as Pending sync.
    private func queueCreate(_ draft: HolidayBooking) throws -> HolidayBooking {
        let orgId = try offlineOrganizationId()
        guard let uid = firebaseBackend?.currentUser?.uid else {
            throw NSError(domain: "HolidayStore", code: 401, userInfo: [NSLocalizedDescriptionKey: "You must be signed in to manage annual leave."])
        }
        let create = try FirebaseBackend.holidayRequestCreate(draft, organizationId: orgId)
        OfflineOutboxStore.shared.enqueueAnnualLeaveRequest(
            documentPath: "organizations/\(orgId)/holidayBookings/\(create.documentId)",
            fields: create.fields,
            isCreate: true,
            userId: uid,
            organizationId: orgId,
            entityId: create.documentId
        )
        bookings.removeAll { $0.id == create.stored.id }
        bookings.append(create.stored)
        return create.stored
    }

    /// Queues a partial update of the person's own request (edit of a pending request, or asking to cancel).
    private func queueUpdate(_ booking: HolidayBooking, fields: [String: Any]) throws {
        guard !fields.isEmpty else { return }
        let orgId = try offlineOrganizationId()
        guard let uid = firebaseBackend?.currentUser?.uid,
              let queued = OfflineFieldValue.fields(fields) else {
            throw NSError(domain: "HolidayStore", code: 503, userInfo: [NSLocalizedDescriptionKey: OfflinePolicy.onlineOnlyMessage])
        }
        OfflineOutboxStore.shared.enqueueAnnualLeaveRequest(
            documentPath: "organizations/\(orgId)/holidayBookings/\(booking.documentId)",
            fields: queued,
            isCreate: false,
            userId: uid,
            organizationId: orgId,
            entityId: booking.documentId
        )
    }

    // MARK: Live listener (RULEBOOK §1, §5, §9, §10; 1.56.0 `leaveQueryPlan`)

    /// The listener registry key (one leave listener per organisation).
    nonisolated static let listenerKey = "holidayBookings"
    /// RULEBOOK 1.56.0: re-plans after a refused own-leave listener are held back — the first after 30 s, the next after
    /// 120 s, then none until the plan (switch, user, own ids, email) changes. A screen, foreground or organisation
    /// switch asking again (`startLiveUpdates`) is never held back.
    nonisolated static let replanRefusalBackoff: [TimeInterval] = [30, 120]

    /// The organisation `startLiveUpdates` last asked for; only that organisation is re-planned, and only while open.
    private(set) var requestedOrganizationId: String?
    /// The plan (`LeaveReadDecision.signature`) and the signed-in uid the listener runs.
    private(set) var plannedSignature: String?
    private(set) var plannedUserId: String?
    /// Refused plans by `organisation|uid|signature`: how many times, and when a re-plan may try again.
    private var refusals: [String: (count: Int, nextAllowedAt: Date)] = [:]
    private var replanObservers: [NSObjectProtocol] = []
    /// The planned listener stopped retrying (review of #246): the next re-plan re-attaches it even when the plan is
    /// unchanged.
    private(set) var listenerGaveUp = false
    /// RULEBOOK 1.56.0 (review of #246): while the plan is `.unavailable` (the script did not answer for an operative),
    /// re-plans are scheduled after these waits, then none until something else asks again.
    nonisolated static let unavailableReplanDelays: [TimeInterval] = [5, 15, 45, 120]
    private var unavailableAttempts = 0
    private var unavailableReplanTask: Task<Void, Never>?
    /// A `loadData` asked for while one was running (review of #246): it runs once the running one finishes.
    private(set) var pendingLoadRequested = false
    /// Tests: the clock the refusal back-off reads.
    var now: () -> Date = { Date() }

    static func refusalKey(organizationId: String, userId: String?, signature: String) -> String {
        "\(normalizedOrganizationId(organizationId))|\(userId ?? "")|\(signature)"
    }

    /// RULEBOOK 1.56.0 (review of web #356): never keep another user's leave, nor a whole company's once the plan
    /// narrows from the collection to the own queries.
    nonisolated static func mustClearRows(
        previousUserId: String?,
        userId: String?,
        previousSignature: String?,
        signature: String
    ) -> Bool {
        if let previousUserId, previousUserId != userId { return true }
        return previousSignature == LeaveReadDecision.all.signature && signature != LeaveReadDecision.all.signature
    }

    /// When a refused plan may be tried again by a re-plan: nil after the last allowed retry (never, until it changes).
    nonisolated static func nextAllowedReplan(afterRefusals count: Int, at time: Date) -> Date? {
        guard count >= 1, count <= replanRefusalBackoff.count else { return nil }
        return time.addingTimeInterval(replanRefusalBackoff[count - 1])
    }

    /// One refusal per plan attach (review of #246): a plan of several `or` queries is refused once per query, but
    /// counts once, so the waits are 30 s then 120 s.
    nonisolated final class RefusalOnce: @unchecked Sendable {
        private let lock = NSLock()
        private var counted = false
        /// True the first time only.
        func claim() -> Bool {
            lock.lock(); defer { lock.unlock() }
            if counted { return false }
            counted = true
            return true
        }
    }

    /// When the next re-plan of an `.unavailable` plan runs: nil after the last allowed attempt.
    nonisolated static func unavailableReplanDelay(afterAttempts attempts: Int) -> TimeInterval? {
        guard attempts >= 0, attempts < unavailableReplanDelays.count else { return nil }
        return unavailableReplanDelays[attempts]
    }

    /// Drops the leave rows on screen (a previous user's, or a whole company's after the plan narrowed). The person's
    /// own requests still queued offline stay (Pending sync).
    private func clearRows() {
        let pending = bookings.filter { isPendingSync($0) }
        if bookings != pending { bookings = pending }
        finishedLoadOrganizationId = nil
    }

    /// Sign-out: forget the plan, the refusals and every leave row.
    func resetForSignOut() {
        requestedOrganizationId = nil
        plannedSignature = nil
        plannedUserId = nil
        refusals.removeAll()
        listenerGaveUp = false
        unavailableAttempts = 0
        unavailableReplanTask?.cancel()
        unavailableReplanTask = nil
        pendingLoadRequested = false
        if !bookings.isEmpty { bookings = [] }
        finishedLoadOrganizationId = nil
        errorMessage = nil
    }

    private func observeReplans() {
        guard replanObservers.isEmpty else { return }
        for name in [Notification.Name.jobReadPlanDidChange, .leaveReadPlanDidChange] {
            replanObservers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in self?.replanLiveUpdates() }
            })
        }
        replanObservers.append(NotificationCenter.default.addObserver(forName: .userDidSignOut, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.resetForSignOut() }
        })
    }

    /// RULEBOOK 1.56.0: the switch, the signed-in user, their level or email, or their own ids (the `operatives` rows)
    /// changed — re-plan the organisation last asked for, only while it is still the open one.
    func replanLiveUpdates() {
        guard let fb = firebaseBackend, fb.isAuthenticated,
              let orgId = requestedOrganizationId,
              organizationIdsMatch(fb.currentOrganization?.firestoreDocumentId, orgId) else { return }
        startLiveUpdates(organizationId: orgId, isReplan: true)
    }

    /// RULEBOOK §1, §5, §9, §10: one live listener on the organisation's annual leave, read through
    /// `parseHolidayDocuments` (`FirebaseBackend.holidayBookings(fromDocuments:)`). A decision or a request made
    /// on web shows on Annual leave, Daily Overview, My Schedule and timesheet leave lines, and the warnings
    /// scan runs again (`.liveWarningInputsDidChange`). Cached copy first; offline keeps the last copy.
    /// RULEBOOK 1.56.0 (`leaveQueryPlan`, owner decisions 17 Nov): while `operativeOwnLeave` is off or unread, and for
    /// everyone not at the operative level, the whole `holidayBookings` collection as before; an operative with the
    /// switch on listens only to their own `or` queries, merged by document id — never the whole collection.
    func startLiveUpdates(organizationId: String, isReplan: Bool = false) {
        guard let fb = firebaseBackend else { return }
        let orgId = normalizedOrganizationId(organizationId)
        guard !orgId.isEmpty else { return }
        observeReplans()
        if !organizationIdsMatch(requestedOrganizationId, orgId) {
            // Another company: its plan, refusals and rows never carry over.
            plannedSignature = nil
            plannedUserId = nil
            refusals.removeAll()
            listenerGaveUp = false
            unavailableAttempts = 0
            unavailableReplanTask?.cancel()
            unavailableReplanTask = nil
            let kept = bookings.filter { organizationIdsMatch($0.organizationId, orgId) }
            if kept.count != bookings.count { bookings = kept }
        }
        requestedOrganizationId = orgId
        let decision = fb.leaveReadDecision(organizationId: orgId)
        let signature = decision.signature
        let userId = fb.currentUser?.uid
        let refusalKey = Self.refusalKey(organizationId: orgId, userId: userId, signature: signature)
        if isReplan {
            if let refusal = refusals[refusalKey], now() < refusal.nextAllowedAt { return }
            // The same plan for the same user: nothing to do — no re-entry. A listener that failed retries on its own
            // capped back-off (or on the next foreground); only a refused own plan is re-planned here, after its wait.
            if refusals[refusalKey] == nil, !listenerGaveUp, decision != .unavailable,
               signature == plannedSignature, userId == plannedUserId {
                return
            }
        }
        if Self.mustClearRows(previousUserId: plannedUserId, userId: userId, previousSignature: plannedSignature, signature: signature) {
            clearRows()
        }
        plannedSignature = signature
        plannedUserId = userId
        listenerGaveUp = false
        if decision != .unavailable {
            unavailableAttempts = 0
            unavailableReplanTask?.cancel()
            unavailableReplanTask = nil
            if errorMessage == LeaveReadDecision.unavailableMessage { errorMessage = nil }
        }
        let once = RefusalOnce()
        let onRefused: @MainActor () -> Void = { [weak self] in
            guard let self, once.claim() else { return }
            let count = (self.refusals[refusalKey]?.count ?? 0) + 1
            self.refusals[refusalKey] = (count, Self.nextAllowedReplan(afterRefusals: count, at: self.now()) ?? .distantFuture)
        }
        switch decision {
        case .all:
            fb.listenOrganizationQuery(
                key: Self.listenerKey,
                organizationId: orgId,
                retryOnFailure: true,
                stillWanted: { [weak self] in self?.plannedSignature == signature && self?.plannedUserId == userId },
                query: { $0.collection("holidayBookings") }
            ) { [weak self] rows, fromCache in
                self?.applyLiveRows(rows, fromCache: fromCache, organizationId: orgId, signature: signature, userId: userId)
            }
        case .own:
            let sources = fb.leaveReadSources(organizationId: orgId, decision: decision)
            fb.listenOrganizationPlan(
                key: Self.listenerKey,
                organizationId: orgId,
                plan: (sources, "leave:\(signature)"),
                cappedRetries: true,
                onRefused: onRefused,
                onGaveUp: { [weak self] in
                    guard let self, self.plannedSignature == signature, self.plannedUserId == userId else { return }
                    self.listenerGaveUp = true
                }
            ) { [weak self] rows, fromCache in
                self?.applyLiveRows(rows, fromCache: fromCache, organizationId: orgId, signature: signature, userId: userId)
            }
        case .nothing:
            // The viewer is not known yet: no leave read at all.
            fb.stopLiveListener(key: Self.listenerKey)
        case .unavailable:
            // The script did not answer for an operative: no read (never the whole collection), say so and try again.
            fb.stopLiveListener(key: Self.listenerKey)
            errorMessage = LeaveReadDecision.unavailableMessage
            scheduleUnavailableReplan()
        }
    }

    /// Re-plans the open organisation after the next `unavailableReplanDelays` wait, while the plan is still unavailable.
    private func scheduleUnavailableReplan() {
        guard unavailableReplanTask == nil,
              let delay = Self.unavailableReplanDelay(afterAttempts: unavailableAttempts) else { return }
        unavailableAttempts += 1
        unavailableReplanTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled, let self else { return }
            self.unavailableReplanTask = nil
            guard self.plannedSignature == LeaveReadDecision.unavailable.signature else { return }
            self.replanLiveUpdates()
        }
    }

    /// One listener snapshot of `signature`'s plan. A snapshot of a plan replaced meanwhile (another user, the plan
    /// narrowed) is dropped.
    private func applyLiveRows(
        _ rows: LiveDocumentRows,
        fromCache: Bool,
        organizationId: String,
        signature: String,
        userId: String?
    ) {
        guard plannedSignature == signature, plannedUserId == userId,
              organizationIdsMatch(requestedOrganizationId, organizationId) else { return }
        if !fromCache {
            // A plan that works clears the refusals of that company and user (review of web #356).
            let prefix = Self.refusalKey(organizationId: organizationId, userId: userId, signature: "")
            refusals = refusals.filter { !$0.key.hasPrefix(prefix) }
        }
        let parsed = FirebaseBackend.holidayBookings(fromDocuments: rows, organizationId: normalizedOrganizationId(organizationId))
        // Leave documents arrived but none could be read: keep the leave on screen (queued requests would
        // otherwise be all that is left).
        if LiveSnapshotMerge.refusesUnreadSnapshot(
            collection: "holidayBookings",
            rowCount: LiveSnapshotMerge.readableRowCount(rows),
            parsedCount: parsed.count,
            existingCount: bookings.count,
            fromCache: fromCache
        ) {
            return
        }
        // §2: a request queued offline stays on screen (Pending sync) until the outbox replays it.
        let pending = bookings.filter { isPendingSync($0) }
        let pendingIds = Set(pending.map(\.id))
        let incoming = parsed.filter { !pendingIds.contains($0.id) } + pending
        let firstDelivery = !organizationIdsMatch(finishedLoadOrganizationId, organizationId)
        finishedLoadOrganizationId = normalizedOrganizationId(organizationId)
        guard let next = LiveSnapshotMerge.apply(existing: bookings, incoming: incoming, fromCache: fromCache),
              Set(next) != Set(bookings) else {
            if firstDelivery {
                NotificationCenter.default.post(name: .liveWarningInputsDidChange, object: nil)
            }
            return
        }
        bookings = next
        NotificationCenter.default.post(name: .liveWarningInputsDidChange, object: nil)
    }

    /// Loads annual leave once. A request made while a load is running is not dropped (review of #246): it runs
    /// again once that load finishes, so the newest plan, user and company are always read last.
    /// At most this many reads per `loadData` call (the first and the newer requests made meanwhile): never a loop.
    nonisolated static let maxLoadRunsPerRequest = 3

    func loadData() async {
        if isLoadingInFlight {
            pendingLoadRequested = true
            return
        }
        var runs = 0
        repeat {
            pendingLoadRequested = false
            runs += 1
            await loadDataOnce()
        } while pendingLoadRequested && runs < Self.maxLoadRunsPerRequest && firebaseBackend?.isAuthenticated == true
        pendingLoadRequested = false
    }

    private func loadDataOnce() async {
        guard let fb = firebaseBackend else {
            errorMessage = "Annual leave service unavailable. Please reopen the app."
            isLoading = false
            return
        }
        guard fb.isAuthenticated else {
            errorMessage = "Please sign in again to load annual leave."
            isLoading = false
            return
        }
        guard !isLoadingInFlight else { return }
        isLoadingInFlight = true
        isLoading = true
        var attemptedOrganizationId = fb.currentOrganization?.firestoreDocumentId
        defer {
            isLoading = false
            isLoadingInFlight = false
            if let attemptedOrganizationId, !attemptedOrganizationId.isEmpty {
                finishedLoadOrganizationId = attemptedOrganizationId
            }
        }
        errorMessage = nil
        // What this load read: its plan, user and company (set once the plan is known), so a stale result or error
        // is never shown (review of #246).
        var started: (signature: String, userId: String?, organizationId: String)?
        func stillCurrent() -> Bool {
            guard let started else { return true }
            return Self.loadResultStillCurrent(
                decisionSignature: started.signature,
                currentSignature: fb.leaveReadDecision(organizationId: started.organizationId).signature,
                userId: started.userId,
                currentUserId: fb.currentUser?.uid,
                organizationId: started.organizationId,
                currentOrganizationId: fb.currentOrganization?.firestoreDocumentId
            )
        }
        do {
            print("🔥🔥🔥 DEBUG: HolidayStore loadData starting…")
            let orgId = try await resolveOrganizationId()
            attemptedOrganizationId = orgId
            // RULEBOOK 1.56.0: the same plan as the listener (`leaveQueryPlan`); an operative with the switch on never
            // reads the whole collection, and nothing is read before the viewer is known.
            let decision = fb.leaveReadDecision(organizationId: orgId)
            if decision == .nothing {
                attemptedOrganizationId = nil
                return
            }
            started = (decision.signature, fb.currentUser?.uid, orgId)
            print("🔥🔥🔥 DEBUG: HolidayStore resolved org \(orgId); fetching holidayBookings…")
            let loaded = try await fb.loadHolidayBookings(organizationId: orgId, decision: decision)
            // The plan, user or open company changed while reading (the plan narrowed, a sign-out): the result is
            // not this screen's any more.
            guard stillCurrent() else {
                attemptedOrganizationId = nil
                pendingLoadRequested = true
                return
            }
            bookings = loaded
            print("🔥🔥🔥 DEBUG: HolidayStore loaded \(bookings.count) holiday bookings")
        } catch {
            // A stale load's failure is not this screen's error (review of #246).
            guard stillCurrent() else {
                attemptedOrganizationId = nil
                pendingLoadRequested = true
                return
            }
            let nsError = error as NSError
            print("🔥🔥🔥 DEBUG: HolidayStore loadData failed: \(error.localizedDescription)")
            if nsError.domain == "FIRFirestoreErrorDomain" && nsError.code == 7 {
                errorMessage = "Annual leave sync is currently blocked by Firebase permissions. Existing cached data may still be shown."
            } else {
                errorMessage = error.localizedDescription
            }
            // Keep currently loaded bookings on transient permission/network errors.
        }
    }

    /// RULEBOOK 1.56.0: a one-off load's result is used only when the plan it read, the signed-in user and the open
    /// organisation are still the ones it started with.
    static func loadResultStillCurrent(
        decisionSignature: String,
        currentSignature: String,
        userId: String?,
        currentUserId: String?,
        organizationId: String,
        currentOrganizationId: String?
    ) -> Bool {
        decisionSignature == currentSignature && userId == currentUserId
            && organizationIdsMatch(currentOrganizationId, organizationId)
    }

    /// A new booking creates one document (`holidayRequestWriteFields`). A booking already in the store
    /// writes only the fields that changed (partial update + `WriteMetadata`), never a full merge-set.
    func saveBooking(_ booking: HolidayBooking) async throws {
        guard let fb = firebaseBackend else { return }
        try requireOnlineUnlessOwn(booking)
        if isOffline {
            // RULEBOOK §2: the person's own request is queued and shows Pending sync.
            if let previous = bookings.first(where: { $0.id == booking.id }) {
                try queueUpdate(booking, fields: Self.changedFields(from: previous, to: booking))
                if let index = bookings.firstIndex(where: { $0.id == booking.id }) {
                    bookings[index] = booking
                }
            } else {
                _ = try queueCreate(booking)
            }
            return
        }
        let orgId = try await resolveOrganizationId()
        let session = writeSession(orgId)
        if let previous = bookings.first(where: { $0.id == booking.id }) {
            let fields = Self.changedFields(from: previous, to: booking)
            lastSaveWasPendingSync = try await fb.updateHolidayBookingFields(
                documentId: booking.documentId,
                fields: fields,
                organizationId: orgId,
                session: session
            )
            if let index = bookings.firstIndex(where: { $0.id == booking.id }) {
                bookings[index] = booking
            }
            return
        }
        let result = try await fb.saveHolidayBooking(booking, organizationId: orgId, session: session)
        lastSaveWasPendingSync = result.pendingSync
        bookings.removeAll { $0.id == result.stored.id }
        bookings.append(result.stored)
    }

    /// One document per request range (`holidayRequestRanges` → `holidayRequestWriteFields`, §9).
    /// `picks` are the chosen days (any time of day; the organisation-zone day key is used) with their slot.
    /// Returns the saved bookings in date order.
    @discardableResult
    func createRequests(
        picks: [(day: Date, timeSlot: HolidayTimeSlot)],
        userId: String?,
        operativeId: UUID?,
        status: HolidayStatus,
        approvedByUserId: String?
    ) async throws -> [HolidayBooking] {
        guard let fb = firebaseBackend else { return [] }
        let signedIn = fb.currentUser?.uid
        let ownRequest = signedIn != nil && userId == signedIn
        if isOffline && !ownRequest {
            throw NSError(domain: "HolidayStore", code: 503, userInfo: [NSLocalizedDescriptionKey: OfflinePolicy.onlineOnlyMessage])
        }
        let orgId: String
        if isOffline {
            orgId = try offlineOrganizationId()
        } else {
            orgId = try await resolveOrganizationId()
        }
        let keyed = picks.map { (dayKey: OrganizationRulebookContext.dayKey($0.day), timeSlot: $0.timeSlot.rawValue) }
        guard let ranges = CanonicalBusinessEngine.holidayRequestRanges(picks: keyed) else {
            throw NSError(domain: "HolidayStore", code: 500, userInfo: [NSLocalizedDescriptionKey: "Annual leave could not be prepared. Please try again."])
        }
        var saved: [HolidayBooking] = []
        var anyPending = false
        let session = writeSession(orgId)
        for range in ranges {
            guard let start = OrganizationRulebookContext.date(fromDayKey: range.startDayKey),
                  let end = OrganizationRulebookContext.date(fromDayKey: range.endDayKey) else { continue }
            let draft = HolidayBooking(
                organizationId: orgId,
                userId: userId,
                operativeId: operativeId,
                startDate: start,
                endDate: end,
                status: status,
                timeSlot: HolidayTimeSlot(rawValue: range.timeSlot) ?? .fullDay,
                approvedByUserId: status == .approved ? approvedByUserId : nil
            )
            if isOffline {
                // RULEBOOK §2: queued; approver notices wait for the server (`isPendingSync`).
                saved.append(try queueCreate(draft))
                continue
            }
            let result = try await fb.saveHolidayBooking(draft, organizationId: orgId, session: session)
            anyPending = anyPending || result.pendingSync
            bookings.removeAll { $0.id == result.stored.id }
            bookings.append(result.stored)
            saved.append(result.stored)
        }
        lastSaveWasPendingSync = anyPending
        return saved.sorted { $0.startDate < $1.startDate }
    }

    /// Firestore values for the keys that differ between two versions of one booking.
    private static func changedFields(from old: HolidayBooking, to new: HolidayBooking) -> [String: Any] {
        func timestamp(_ date: Date?) -> Any { date.map { Timestamp(date: $0) as Any } ?? NSNull() }
        func text(_ value: String?) -> Any {
            let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return trimmed.isEmpty ? (NSNull() as Any) : (trimmed as Any)
        }
        var fields: [String: Any] = [:]
        if old.startDate != new.startDate { fields["startDate"] = timestamp(new.startDate) }
        if old.endDate != new.endDate { fields["endDate"] = timestamp(new.endDate) }
        if old.timeSlot != new.timeSlot { fields["timeSlot"] = new.timeSlot.rawValue }
        if old.status != new.status { fields["status"] = new.status.rawValue }
        if old.approvedByUserId != new.approvedByUserId { fields["approvedByUserId"] = text(new.approvedByUserId) }
        if old.approvedAt != new.approvedAt { fields["approvedAt"] = timestamp(new.approvedAt) }
        if old.cancellationRequestedAt != new.cancellationRequestedAt {
            fields["cancellationRequestedAt"] = timestamp(new.cancellationRequestedAt)
        }
        if old.cancellationRequestedByUserId != new.cancellationRequestedByUserId {
            fields["cancellationRequestedByUserId"] = text(new.cancellationRequestedByUserId)
        }
        if old.decisionNote != new.decisionNote {
            fields["decisionNote"] = CanonicalBusinessEngine.parseHolidayDecisionNote(new.decisionNote).map { $0 as Any } ?? NSNull()
        }
        return fields
    }

    /// Returns what happened (saved, Pending sync, or refused) for the feedback sound (guide §4); what is written is
    /// unchanged. Without a backend nothing is written: refused.
    @discardableResult
    func deleteBooking(_ booking: HolidayBooking) async -> BookingSaveResult {
        guard let fb = firebaseBackend else { return .refused(Self.notSavedMessage) }
        do {
            let orgId = try await resolveOrganizationId()
            lastSaveWasPendingSync = try await fb.deleteHolidayBooking(booking, organizationId: orgId, session: writeSession(orgId))
            bookings.removeAll { $0.id == booking.id }
            return lastSaveWasPendingSync ? .queued(BookingStore.pendingSyncMessage) : .saved
        } catch {
            errorMessage = error.localizedDescription
            return .refused(error.localizedDescription)
        }
    }

    /// Feedback only: the refusal when no backend is set (nothing is written or shown, as before).
    static let notSavedMessage = "This annual leave change could not be saved."

    // Owner decision 4 Nov ("Never delete leave"): changing Annual Leave Management, the line manager or the account
    // type never deletes a person's approved or pending leave. The toggle only decides whether *future* leave saves
    // approved or is requested (`canSelfBookAnnualLeave`). The two helpers that deleted it are gone.

    /// Approve in one partial update (`holidayDecisionWriteFields`). Returns the outcome for the feedback sound.
    @discardableResult
    func approveBooking(_ booking: HolidayBooking, approvedByUserId: String) async -> BookingSaveResult {
        await decide(booking, status: .approved, approverUid: approvedByUserId, note: nil)
    }

    /// Decline in one partial update (`holidayDecisionWriteFields`). A blank reason clears the note. Returns the
    /// outcome for the feedback sound.
    @discardableResult
    func rejectBooking(_ booking: HolidayBooking, rejectedByUserId: String, reason: String = "") async -> BookingSaveResult {
        await decide(booking, status: .rejected, approverUid: rejectedByUserId, note: reason)
    }

    /// Writes exactly as before; the result (saved, Pending sync after the short wait, or refused) is for the feedback
    /// sound only (guide §4).
    @discardableResult
    private func decide(_ booking: HolidayBooking, status: HolidayStatus, approverUid: String, note: String?) async -> BookingSaveResult {
        guard let fb = firebaseBackend else { return .refused(Self.notSavedMessage) }
        do {
            let orgId = try await resolveOrganizationId()
            let result = try await fb.decideHolidayBooking(
                booking,
                status: status,
                approverUid: approverUid,
                decisionNote: note,
                organizationId: orgId,
                session: writeSession(orgId)
            )
            lastSaveWasPendingSync = result.pendingSync
            let decision = result.decision
            var updated = booking
            updated.status = HolidayStatus(rawValue: decision.status) ?? status
            updated.approvedByUserId = decision.approvedByUserId
            updated.approvedAt = Date()
            updated.decisionNote = decision.decisionNote
            updated.updatedAt = Date()
            if let index = bookings.firstIndex(where: { $0.id == booking.id }) {
                bookings[index] = updated
            } else {
                bookings.append(updated)
            }
            return result.pendingSync ? .queued(BookingStore.pendingSyncMessage) : .saved
        } catch {
            errorMessage = error.localizedDescription
            return .refused(error.localizedDescription)
        }
    }

    var pendingRequests: [HolidayBooking] {
        bookings.filter {
            ($0.status == .pending || $0.cancellationRequestedAt != nil) &&
            ($0.operativeId != nil || $0.userId != nil)
        }
    }

    func requestCancellation(_ booking: HolidayBooking, by userId: String) async {
        var updated = booking
        updated.cancellationRequestedAt = Date()
        updated.cancellationRequestedByUserId = userId
        updated.updatedAt = Date()
        do {
            try await saveBooking(updated)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// An approver refuses a cancellation request (RULEBOOK §9): the leave stays approved and the request fields are
    /// cleared in one partial update. Returns false when the write failed (`errorMessage` is set).
    @discardableResult
    func refuseCancellation(_ booking: HolidayBooking) async -> Bool {
        guard booking.cancellationRequestedAt != nil else { return false }
        var updated = booking
        updated.cancellationRequestedAt = nil
        updated.cancellationRequestedByUserId = nil
        updated.updatedAt = Date()
        do {
            try await saveBooking(updated)
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    /// Approved records whose leave days (`leaveRecordDayKeys` over the reader's `startDayKey` / `endDayKey`)
    /// include the organisation day of `date`.
    func approvedBookings(covering date: Date) -> [HolidayBooking] {
        let dayKey = OrganizationRulebookContext.dayKey(date)
        return bookings.filter { b in
            b.isApproved && LeaveRecordDays.covers(b, dayKey: dayKey)
        }
    }

    /// RULEBOOK 1.9.0 §9, §10: this account's leave — `leaveRecordsForAccount` (a record whose `userId` or
    /// `operativeId` is any of the account's ids: uid, former and same-email ids, catalogue rows on its email; without
    /// case, never by name). With no profile loaded but a stored `userId`, that id alone is the account. With neither,
    /// the records on `operativeId` (a catalogue-only person). Empty when the script did not answer: no Swift copy of
    /// the matching rule (AGENTS.md Rule 0).
    func myBookings(account: AppUser?, operatives: [Operative], operativeId: UUID? = nil, userId: String? = nil) -> [HolidayBooking] {
        let accountRow: CanonicalBusinessEngine.CanonicalBookingPersonAccount
        if let account {
            accountRow = CanonicalBusinessEngine.CanonicalBookingPersonAccount(
                id: account.id,
                email: account.email,
                formerIds: account.formerUserIds,
                aliasIds: account.sameEmailUserIds
            )
        } else if let uid = userId?.trimmingCharacters(in: .whitespacesAndNewlines), !uid.isEmpty {
            accountRow = CanonicalBusinessEngine.CanonicalBookingPersonAccount(id: uid, email: nil, formerIds: nil, aliasIds: nil)
        } else {
            guard let operativeId else { return [] }
            return bookings.filter { $0.operativeId == operativeId }
        }
        guard let indexes = CanonicalBusinessEngine.leaveRecordsForAccount(
            records: bookings.map { (userId: $0.userId, operativeId: $0.operativeIdRaw) },
            account: accountRow,
            operatives: operatives.map { CanonicalBusinessEngine.CanonicalBookingPersonOperative(id: $0.documentId, email: $0.email) }
        ) else {
            return []
        }
        let all = bookings
        return indexes.filter { $0 >= 0 && $0 < all.count }.map { all[$0] }
    }
}
