//
//  BookingStore.swift
//  Project Planner
//
//  Created by Assistant on 29/09/2025.
//

import Foundation
import Combine

@MainActor
class BookingStore: ObservableObject {
    @Published var bookings: [Booking] = [] {
        // RULEBOOK 1.10.0 §17: an operative reads the jobs of their own bookings one by one (`jobQueryPlan`).
        didSet {
            JobAccessContext.updateOperativeJobIds(bookings: bookings, managerBookings: [])
            revision &+= 1
        }
    }
    /// Bumped on every change to `bookings`, so booking-flow conflict checks can be memoised per data version.
    private(set) var revision = 0
    @Published var isLoading: Bool = false
    @Published var errorMessage: String?
    @Published var isOffline: Bool = false
    /// The last server read failed. Coverage from this list is incomplete, so Warnings shows an error
    /// instead of treating missing bookings as unbooked.
    @Published private(set) var lastLoadFailed = false
    /// The live listener reported an error since the last good server snapshot.
    @Published private(set) var listenerFailed = false
    /// The organisation whose bookings load last finished (read or failed). Warnings wait for it
    /// (`WarningInputsReadiness`) so an empty list before the first read is never "nobody booked".
    private(set) var finishedLoadOrganizationId: String?
    
    private let persistenceService: PersistenceService
    private var firebaseBackend: FirebaseBackend?
    private var smartCache: SmartCacheService?
    private var cancellables = Set<AnyCancellable>()
    private var pendingReloadAfterCurrentLoad = false
    
    init(persistenceService: PersistenceService? = nil) {
        self.persistenceService = persistenceService ?? PersistenceService()
        
        // Listen for organization load events
        NotificationCenter.default.addObserver(
            forName: .organizationDidLoad,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                // Bootstrap / ContentView org-switch own the first loads. Reloading again here
                // after hasBootstrapped flips true can double-fetch every collection and jetsam.
                guard self.firebaseBackend?.hasBootstrappedOrgDataLoad == true else {
                    print("🔥🔥🔥 DEBUG: BookingStore skipping organizationDidLoad reload (pre-bootstrap)")
                    return
                }
                // Ignore routine org-did-load; only Settings force-reload clears the bootstrap flag
                // and ContentView re-runs bootstrap. Avoid a second full bookings fetch on launch.
                print("🔥🔥🔥 DEBUG: BookingStore ignoring organizationDidLoad reload (bootstrap owns loads)")
            }
        }
        
        NotificationCenter.default.addObserver(
            forName: .bookingsListenerFailed,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.listenerFailed = true
            }
        }

        // Listen for offline sync trigger (when app comes back online)
        NotificationCenter.default.addObserver(
            forName: .syncOfflineChanges,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard self.firebaseBackend?.hasBootstrappedOrgDataLoad == true else {
                    print("🔥🔥🔥 DEBUG: BookingStore offline sync skipped until org bootstrap finishes")
                    return
                }
                // RULEBOOK §1/§2: queued changes replay from the outbox as partial updates. Re-saving
                // every in-memory booking here rewrote whole documents from a possibly stale copy and
                // could bring back bookings deleted on another device, so it no longer writes.
                print("🔥🔥🔥 DEBUG: BookingStore received syncOfflineChanges — outbox replays queued changes")
            }
        }

        // RULEBOOK §2: a refused replay is final. Drop the local row the server will never accept.
        NotificationCenter.default.addObserver(
            forName: .offlineBookingReplayRefused,
            object: nil,
            queue: .main
        ) { [weak self] note in
            let collection = note.userInfo?["collection"] as? String
            let bookingId = note.userInfo?["bookingId"] as? String
            let operation = note.userInfo?["operation"] as? String
            Task { @MainActor [weak self] in
                guard let self, collection == "bookings", let bookingId else { return }
                self.dropRefusedBooking(bookingId: bookingId, operation: operation)
            }
        }

        // 1.33.1 review item 4: a write Firestore held after its wait timed out was refused by the server. Drop the
        // local optimistic copy, so the live listener's next snapshot (the server's booking, or none) is what shows.
        NotificationCenter.default.addObserver(
            forName: SDKPendingWrites.lateRefusalNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard note.userInfo?["collection"] as? String == "bookings",
                  let documentId = note.userInfo?["documentId"] as? String else { return }
            let noteOrganizationId = note.userInfo?["organizationId"] as? String ?? ""
            Task { @MainActor [weak self] in
                guard let self else { return }
                let open = self.firebaseBackend?.resolvedOrganizationIdForOfflineWrites() ?? ""
                guard BookingPendingSync.sameOrganization(noteOrganizationId, open) else { return }
                self.dropLocalCopyAfterLateRefusal(documentId: documentId)
            }
        }

        // RULEBOOK 1.33.0: a queued delete was undone from the sync list or refused on replay — the booking comes back.
        NotificationCenter.default.addObserver(
            forName: .offlineBookingDeleteRestored,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard note.userInfo?["collection"] as? String == "bookings",
                  let booking = note.userInfo?["labourBooking"] as? Booking else { return }
            let noteOrganizationId = normalizedOrganizationId(note.userInfo?["organizationId"] as? String ?? "")
            Task { @MainActor [weak self] in
                guard let self else { return }
                // Only into the open organisation: a queued delete of another company's booking never shows here.
                let openOrganizationId = normalizedOrganizationId(self.firebaseBackend?.resolvedOrganizationIdForOfflineWrites() ?? "")
                guard noteOrganizationId.isEmpty || noteOrganizationId == openOrganizationId else { return }
                self.restoreDeletedBooking(booking)
            }
        }
    }

    /// 1.33.1 review item 4: the server refused a write Firestore held for this booking. The copy on this phone is
    /// dropped (ids without case). Review fix 2: the listener may already have published the server's copy before this
    /// runs, and then no further snapshot comes, so the booking is read again (bounded) and put back when it exists.
    /// Returns whether a copy was dropped (then the re-read runs).
    @discardableResult
    func dropLocalCopyAfterLateRefusal(documentId: String) -> Bool {
        let key = documentId.lowercased()
        let before = bookings.count
        bookings.removeAll { $0.documentKey.lowercased() == key || $0.id.uuidString.lowercased() == key }
        guard bookings.count != before else { return false }
        smartCache?.cacheBookings(bookings)
        let snapshot = bookings
        Task { try? await persistenceService.saveBookingData(bookings: snapshot) }
        ScheduleChangeNotifier.postBookingStoreDidChange()
        rereadAfterLateRefusal(documentId: documentId)
        return true
    }

    /// Review fix 2: reads the refused booking again and applies what was found (`applyLateRefusalReread`).
    private func rereadAfterLateRefusal(documentId: String) {
        guard let fb = firebaseBackend, let organizationId = fb.currentOrganization?.firestoreDocumentId else { return }
        Task { @MainActor [weak self] in
            let result = await fb.rereadBookingAfterLateRefusal(organizationId: organizationId, documentId: documentId)
            guard let self else { return }
            // Another organisation opened meanwhile: nothing from this one goes on screen.
            guard BookingPendingSync.sameOrganization(organizationId, self.firebaseBackend?.currentOrganization?.firestoreDocumentId ?? "") else {
                return
            }
            self.applyLateRefusalReread(result, organizationId: organizationId)
        }
    }

    /// Review fix 2: the server's copy goes back on screen (with any change of it still queued in the outbox on top,
    /// and never while a delete of it is queued); gone on the server, nothing; unknown (no answer, or the reader did
    /// not answer), a full reload, so the booking reappears if it exists.
    func applyLateRefusalReread(_ result: BookingLateRefusalReread, organizationId: String) {
        switch result {
        case .found(let server):
            let pending = OfflineOutboxStore.shared.pendingLabourBookings(organizationId: organizationId)
            guard let shown = Self.overlayingPendingOutbox(
                [server],
                pendingSaves: pending.saves.filter { $0.id == server.id },
                pendingDeletes: pending.deletedIds
            ).first else { return }
            if let index = bookings.firstIndex(where: { $0.id == shown.id }) {
                bookings[index] = shown
            } else {
                bookings.append(shown)
            }
            smartCache?.cacheBookings(bookings)
            let snapshot = bookings
            Task { try? await persistenceService.saveBookingData(bookings: snapshot) }
            ScheduleChangeNotifier.postBookingStoreDidChange()
        case .missing:
            break
        case .unknown:
            loadData()
        }
    }

    /// Puts back a booking whose queued delete was undone or refused (it is still on the server).
    private func restoreDeletedBooking(_ booking: Booking) {
        guard !bookings.contains(where: { $0.id == booking.id }) else { return }
        bookings.append(booking)
        smartCache?.cacheBookings(bookings)
        let snapshot = bookings
        Task { try? await persistenceService.saveBookingData(bookings: snapshot) }
        ScheduleChangeNotifier.postBookingStoreDidChange()
    }
    
    deinit {
        NotificationCenter.default.removeObserver(self)
    }
    
    func setCurrentUser(_ userId: String?) {
        persistenceService.setCurrentUser(userId)
        loadData()
    }
    
    func setFirebaseBackend(_ firebaseBackend: FirebaseBackend) {
        guard LaunchStartupPolicy.shouldRewireStore(isSameInstance: self.firebaseBackend === firebaseBackend) else { return }
        print("🔥🔥🔥 DEBUG: BookingStore.setFirebaseBackend called - Firebase backend connected!")
        self.firebaseBackend = firebaseBackend
    }
    
    func setSmartCache(_ smartCache: SmartCacheService) {
        self.smartCache = smartCache
        self.isOffline = !smartCache.isOnline
        smartCache.$isOnline
            .receive(on: DispatchQueue.main)
            .sink { [weak self] online in
                self?.isOffline = !online
            }
            .store(in: &cancellables)
    }
    
    // MARK: - Data Loading
    
    func loadData() {
        if isLoading {
            if firebaseBackend?.isBootstrappingOrgDataLoad == true {
                print("🔥🔥🔥 DEBUG: BookingStore loadData ignored (already loading during bootstrap); not queueing follow-up")
                return
            }
            pendingReloadAfterCurrentLoad = true
            print("🔥🔥🔥 DEBUG: BookingStore loadData ignored (already loading); queued one follow-up reload")
            return
        }
        isLoading = true
        errorMessage = nil
        let loadingOrganizationId = firebaseBackend?.currentOrganization?.firestoreDocumentId
        
        Task { @MainActor in
            defer {
                self.isLoading = false
                self.finishedLoadOrganizationId = loadingOrganizationId
                if self.pendingReloadAfterCurrentLoad {
                    self.pendingReloadAfterCurrentLoad = false
                    if self.firebaseBackend?.hasBootstrappedOrgDataLoad == true,
                       self.firebaseBackend?.isBootstrappingOrgDataLoad != true {
                        self.loadData()
                    }
                }
            }
            do {
                firebaseBackend?.prepareLaunchScheduleQueryIfNeeded()
                if bookings.isEmpty, firebaseBackend?.isAuthenticated != true {
                    let visible = bookingsInsideLaunchWindow(try? await persistenceService.loadBookingData())
                    if !visible.isEmpty {
                        bookings = visible
                        print("🔥🔥🔥 DEBUG: BOOKINGS_RESTORED \(visible.count) from disk before fetch")
                    }
                }
                // Try to load from Firebase first if authenticated
                if let firebaseBackend = firebaseBackend, 
                   firebaseBackend.isAuthenticated,
                   let organizationId = firebaseBackend.currentOrganization?.firestoreDocumentId {
                    
                    print("🔥🔥🔥 DEBUG: Loading bookings from Firebase for organization: \(organizationId)")
                    firebaseBackend.prepareLaunchScheduleQueryIfNeeded()
                    let queryStart = firebaseBackend.scheduleBookingQueryStart()
                    
                    // Launch reads from the warning window / current week forward, not the whole archive.
                    let firebaseBookings = try await firebaseBackend.loadBookings(
                        organizationId: organizationId,
                        startingOn: queryStart
                    )
                    if firebaseBackend.suppressStaleOrganizationCache {
                        self.bookings = firebaseBookings
                        self.smartCache?.cacheBookings(firebaseBookings)
                    } else if firebaseBookings.isEmpty && !self.bookings.isEmpty {
                        print("🔥🔥🔥 DEBUG: Remote returned 0 bookings, preserving \(self.bookings.count) in-memory bookings")
                    } else if firebaseBookings.isEmpty {
                        let cached = self.bookingsInsideLaunchWindow(try? await persistenceService.loadBookingData())
                        if !cached.isEmpty {
                            self.bookings = cached
                            print("🔥🔥🔥 DEBUG: Remote returned 0 bookings, restored \(cached.count) from disk")
                        } else {
                            self.bookings = firebaseBookings
                        }
                    } else {
                        self.bookings = firebaseBookings
                        self.smartCache?.cacheBookings(firebaseBookings)
                        // A windowed launch must not replace the on-disk archive with only recent rows.
                        if queryStart == nil {
                            Task { try? await persistenceService.saveBookingData(bookings: firebaseBookings) }
                        }
                    }
                    self.lastLoadFailed = false
                    self.startLiveUpdates(organizationId: organizationId, startingOn: queryStart)
                    
                    print("🔥🔥🔥 DEBUG: Loaded \(firebaseBookings.count) bookings from Firebase")
                    
                } else {
                    // Fallback to local storage
                    print("🔥🔥🔥 DEBUG: Loading bookings from local storage (Firebase not available or not authenticated)")
                    print("🔥🔥🔥 DEBUG: Firebase backend: \(firebaseBackend != nil)")
                    print("🔥🔥🔥 DEBUG: Authenticated: \(firebaseBackend?.isAuthenticated ?? false)")
                    print("🔥🔥🔥 DEBUG: Organization: \(firebaseBackend?.currentOrganization?.name ?? "nil")")
                    let bookings = self.bookingsInsideLaunchWindow(try? await persistenceService.loadBookingData())
                    if !bookings.isEmpty || self.bookings.isEmpty {
                        self.bookings = bookings
                    }
                    print("🔥🔥🔥 DEBUG: Loaded \(self.bookings.count) bookings from local storage")
                }
                
            } catch {
                self.errorMessage = error.localizedDescription
                self.lastLoadFailed = true
                NSLog("BOOKINGS_LOAD_FAILED error=%@", error.localizedDescription)
                if firebaseBackend?.suppressStaleOrganizationCache == true {
                    self.bookings = []
                } else {
                // Fallback to local cache when Firebase denies/ fails so operative visibility does not fully disappear.
                let cached = self.bookingsInsideLaunchWindow(try? await self.persistenceService.loadBookingData())
                if !cached.isEmpty {
                    self.bookings = cached
                    print("🔥🔥🔥 DEBUG: Loaded \(cached.count) cached bookings after Firebase error")
                }
                }
            }
        }
    }
    
    private func loadSampleData() {
        // Sample bookings will be created when we have sample operatives and projects
        self.bookings = []
    }
    
    private func loadDemoBookings() -> [Booking]? {
        let userDefaults = UserDefaults.standard
        guard let data = userDefaults.data(forKey: "demo@projectplanner.com_bookings"),
              let demoBookings = try? JSONDecoder().decode([Booking].self, from: data) else {
            return nil
        }
        return demoBookings
    }
    
    // MARK: - Booking Operations
    
    /// RULEBOOK 1.10.0 §2, §16: `canWriteBooking` / `canDeleteBooking` — admins every booking, managers only on jobs
    /// they manage, operatives never. Refused before anything is written or queued (the security rules refuse it too).
    private func writeRefusal(_ rows: [Booking], isDelete: Bool = false) -> String? {
        for booking in rows {
            if let message = JobAccessContext.bookingWriteRefusal(collection: "bookings", projectId: booking.storedProjectId, isDelete: isDelete) {
                return message
            }
        }
        return nil
    }

    func addBooking(_ booking: Booking) async {
        // RULEBOOK §1: stored at organisation-zone midnight of its day (`BookingDay`), whatever picker made it.
        var booking = booking
        booking.date = BookingDay.organizationMidnight(for: booking.date)
        if let refusal = writeRefusal([booking]) {
            errorMessage = refusal
            return
        }
        bookings.append(booking)
        await saveData(writes: [BookingWrite(booking: booking, changedFields: nil)])
    }

    /// Append multiple bookings then sync only the new rows (much faster than repeated full saves).
    func addBookings(_ newBookings: [Booking]) async {
        await addBookingsReturningResults(newBookings)
    }

    /// `addBookings`, returning each booking's outcome by id (1.33.1). A booking refused before anything is written
    /// (`writeRefusal`) is `.refused` with that message.
    @discardableResult
    private func addBookingsReturningResults(
        _ newBookings: [Booking],
        organizationId capturedOrganizationId: String? = nil,
        session: BookingWriteSession? = nil
    ) async -> [UUID: BookingSaveResult] {
        guard !newBookings.isEmpty else { return [:] }
        if let refusal = organizationChangedRefusal(capturedOrganizationId) {
            errorMessage = refusal
            return Dictionary(newBookings.map { ($0.id, BookingSaveResult.refused(refusal)) }, uniquingKeysWith: { first, _ in first })
        }
        // RULEBOOK §1: organisation-zone midnight of each booking's day (`BookingDay`).
        let newBookings = newBookings.map { booking -> Booking in
            var booking = booking
            booking.date = BookingDay.organizationMidnight(for: booking.date)
            return booking
        }
        if let refusal = writeRefusal(newBookings) {
            errorMessage = refusal
            return Dictionary(newBookings.map { ($0.id, BookingSaveResult.refused(refusal)) }, uniquingKeysWith: { first, _ in first })
        }
        bookings.append(contentsOf: newBookings)
        return await saveData(
            writes: newBookings.map { BookingWrite(booking: $0, changedFields: nil) },
            organizationId: capturedOrganizationId,
            session: session
        )
    }
    
    /// Saves only the fields that changed against the copy on this device (RULEBOOK §1 partial writes).
    func updateBooking(_ booking: Booking) async {
        await updateBookingReturningResult(booking)
    }

    /// `updateBooking`, returning what happened to this edit (1.33.1). An edit that changes nothing is `.saved`.
    @discardableResult
    private func updateBookingReturningResult(
        _ booking: Booking,
        organizationId capturedOrganizationId: String? = nil,
        session: BookingWriteSession? = nil
    ) async -> BookingSaveResult {
        if let refusal = organizationChangedRefusal(capturedOrganizationId) {
            errorMessage = refusal
            return .refused(refusal)
        }
        var booking = booking
        booking.date = BookingDay.organizationMidnight(for: booking.date)
        if let index = bookings.firstIndex(where: { $0.id == booking.id }) {
            // Both the job it was on and the job it moves to must be the viewer's.
            if let refusal = writeRefusal([bookings[index], booking]) {
                errorMessage = refusal
                return .refused(refusal)
            }
            let changed = BookingWritePatch.changedLabourFields(from: bookings[index], to: booking)
            // RULEBOOK 1.33.0: the copy before this edit, kept with a queued edit so a later offline delete stores the
            // fingerprint of what the server has (`bookingDeleteFingerprint`).
            let before = bookings[index]
            let baseline = changed.isEmpty ? nil : BookingWritePatch.deleteFingerprint(before)
            bookings[index] = booking
            // The company this save actually wrote to, as `saveData` resolved it (#209 re-review).
            var writtenOrganizationId: String?
            let results = await saveData(
                writes: changed.isEmpty ? [] : [
                    BookingWrite(booking: booking, changedFields: changed, baselineFingerprint: baseline, previous: before)
                ],
                organizationId: capturedOrganizationId,
                session: session,
                writtenTo: { writtenOrganizationId = $0 }
            )
            let result = results[booking.id] ?? .saved
            // RULEBOOK 1.33.0 §25 reopen: the PAYE overtime line this booking carried (best effort, after the write).
            // Only once the server has the edit: a refused edit changed nothing; one queued in the app outbox is told on
            // replay (`OfflineSyncCoordinator`, from the copy queued with it); one Firestore holds after its wait timed
            // out is told when the server confirms it (`holdReopenNoticesUntilConfirmed`).
            if !changed.isEmpty, result == .saved {
                // One notice per change: an older queued edit of this booking replays later, silently.
                OfflineOutboxStore.shared.clearReopenBaseline(bookingId: booking.id)
                // The company this edit was written to (#209 review item 4), never nil when it is known.
                OvertimeReopenNotice.labour(before: before, after: booking, organizationId: writtenOrganizationId)
            }
            return result
        }
        let message = "This booking is no longer on this phone. Close the screen and open it again."
        errorMessage = message
        return .refused(message)
    }

    /// `updateBooking`, then this edit's own outcome: saved, queued as Pending sync, or refused (1.33.1). Read from
    /// the write itself, never from the store's `errorMessage`, which an earlier load or save may have left (Scheduling
    /// read a stale one as a failed edit, and a timed-out edit that was queued as "not saved").
    /// `organizationId`: the organisation the screen captured when Save was pressed. Every write of this save goes
    /// there, and nothing is written once another organisation is open (`organizationChanged`).
    /// `session` (review item 1): the save this edit belongs to — one organisation check and one "a wait timed out"
    /// state for every booking of a Confirm. Without one, the edit is its own save.
    func updateBookingReportingProblem(
        _ booking: Booking,
        organizationId: String? = nil,
        session: BookingWriteSession? = nil
    ) async -> BookingSaveResult {
        errorMessage = nil
        return await updateBookingReturningResult(
            booking,
            organizationId: organizationId,
            session: session ?? BookingWriteSession(organizationId: organizationId)
        )
    }

    /// `addBookings`, then each new booking's own outcome by id (1.33.1): a booking is counted as saved only once its
    /// write is known, never before.
    func addBookingsReportingProblem(
        _ newBookings: [Booking],
        organizationId: String? = nil,
        session: BookingWriteSession? = nil
    ) async -> [UUID: BookingSaveResult] {
        errorMessage = nil
        return await addBookingsReturningResults(
            newBookings,
            organizationId: organizationId,
            session: session ?? BookingWriteSession(organizationId: organizationId)
        )
    }

    /// Shown when the organisation changed between Save and the write (1.33.1): nothing is written.
    static let organizationChangedMessage = "You switched company while saving. Nothing was saved — open the booking again."

    /// True when a save captured one organisation and another is open now (ids compare as stored, normalised).
    static func organizationChanged(captured: String?, open: String?) -> Bool {
        guard let captured, let open else { return false }
        let a = normalizedOrganizationId(captured)
        let b = normalizedOrganizationId(open)
        return !a.isEmpty && !b.isEmpty && a != b
    }

    private func organizationChangedRefusal(_ captured: String?) -> String? {
        Self.organizationChanged(captured: captured, open: firebaseBackend?.resolvedOrganizationIdForOfflineWrites())
            ? Self.organizationChangedMessage
            : nil
    }

    /// RULEBOOK §2 "Pending sync": this booking has a change the server has not confirmed — in the app outbox, or
    /// (1.33.1) in Firestore's own queue after its confirmation wait timed out (`SDKPendingWrites`).
    func isPendingSync(_ booking: Booking) -> Bool {
        BookingPendingSync.isPending(bookingId: booking.id, collection: "bookings", documentKey: booking.documentKey)
    }

    /// How a delete is written (1.33.1).
    enum DeleteRoute: Equatable {
        /// Through Firestore now: the delete and its tombstone in one batch. Firestore writes it after any earlier write
        /// to the booking it still holds (a create whose confirmation timed out), so it is never decided before that
        /// create lands and never dropped locally.
        case firestore
        /// Queued in the app outbox (RULEBOOK 1.33.0 §2 offline delete; `dropLocal` for a create queued offline).
        case outbox
    }

    static func deleteRoute(queuesWhileOffline: Bool, pendingInFirestore: Bool) -> DeleteRoute {
        if pendingInFirestore { return .firestore }
        return queuesWhileOffline ? .outbox : .firestore
    }

    /// A queued save the server refused for good (tombstone / cancelled elsewhere): the row goes.
    /// A refused delete leaves the row to come back from the server listener.
    private func dropRefusedBooking(bookingId: String, operation: String?) {
        guard operation == OfflineOutboxEntry.Operation.saveBooking.rawValue else { return }
        let key = bookingId.uppercased()
        let before = bookings.count
        bookings.removeAll { $0.id.uuidString.uppercased() == key || $0.documentKey.uppercased() == key }
        guard bookings.count != before else { return }
        smartCache?.cacheBookings(bookings)
        let snapshot = bookings
        Task { try? await persistenceService.saveBookingData(bookings: snapshot) }
        ScheduleChangeNotifier.postBookingStoreDidChange()
    }
    
    /// A deleted person's bookings to remove, from the rulebook's `bookingsToRemoveOnOperativeDelete` (web calls it too):
    /// bookings under any of `personIds` dated today or later. Past bookings stay for timesheets and weekly reports.
    /// Nothing is removed when the script does not answer.
    func bookingsToRemoveOnPersonDelete(personIds: Set<UUID>, now: Date = Date()) -> [Booking] {
        guard !personIds.isEmpty,
              let ids = CanonicalBusinessEngine.bookingsToRemoveOnOperativeDelete(
                bookings.map {
                    CanonicalBusinessEngine.CanonicalRemovableBooking(
                        id: $0.documentKey,
                        operativeId: $0.storedOperativeId,
                        dateMs: $0.date.timeIntervalSince1970 * 1000
                    )
                },
                operativeIds: personIds.map { Booking.storedOperativeId(for: $0) },
                now: now
              ) else { return [] }
        let remove = Set(ids.map { $0.uppercased() })
        return bookings.filter { remove.contains($0.documentKey.uppercased()) }
    }

    /// RULEBOOK 1.10.0 §2, §16 `canDeleteBooking` for this labour booking, the same check `deleteBooking` makes: an
    /// admin deletes any labour booking, a manager deletes bookings on jobs they manage (as `canWriteBooking`), an
    /// operative never. True before the profile loads; the security rules still decide. Screens offer Delete only when
    /// this is true.
    func canDeleteBooking(_ booking: Booking) -> Bool {
        // RULEBOOK 1.33.0 §2 `bookingRemoveAction`: the one remove control is Delete; there is no cancel.
        JobAccessContext.bookingRemoveAction(collection: "bookings", projectId: booking.storedProjectId) == "delete"
    }

    /// `deleteBooking`, then the message to show when the booking is still there afterwards (refused by the rulebook
    /// or the server), else nil. Offline the delete is queued (1.33.0), so the booking is gone here. Lets Edit booking report a refused delete
    /// instead of closing as if it had worked.
    func deleteBookingReportingRefusal(_ booking: Booking) async -> String? {
        errorMessage = nil
        await deleteBooking(booking)
        guard bookings.contains(where: { $0.id == booking.id }) else { return nil }
        return errorMessage ?? "This booking could not be deleted."
    }

    /// RULEBOOK 1.33.0 §2 (owner decision 4 Nov "Offline delete on iOS"): deletes a labour booking with its tombstone.
    /// Offline (or when the connection drops) the delete is queued with `bookingDeleteFingerprint` of this device's
    /// copy and shows "Pending sync"; a booking created offline and deleted before it synced sends nothing. A day on a
    /// signed timesheet warns but the delete goes ahead (`bookingDeleteSignedTimesheetWarning`).
    func deleteBooking(_ booking: Booking) async {
        let action = OfflinePolicy.deleteAction(collection: "bookings")
        guard OfflinePolicy.isEnabled(action, isOnline: smartCache?.isOnline ?? true) else {
            errorMessage = OfflinePolicy.onlineOnlyMessage
            return
        }
        if let refusal = writeRefusal([booking], isDelete: true) {
            errorMessage = refusal
            return
        }
        // The fingerprint of this device's copy before it goes (a queued edit keeps the synced copy's own).
        let fingerprint = BookingWritePatch.deleteFingerprint(booking)
        bookings.removeAll { $0.id == booking.id }
        try? await persistenceService.saveBookingData(bookings: bookings)
        smartCache?.cacheBookings(bookings)
        ScheduleChangeNotifier.postBookingStoreDidChange()

        guard let fb = firebaseBackend else { return }
        let orgId = await DataPersistenceManager.shared.waitForOrganization(
            firebaseBackend: fb,
            maxWaitSeconds: smartCache?.isOnline == false ? 1 : 10
        ) ?? fb.resolvedOrganizationIdForOfflineWrites()
        guard let orgId else { return }

        warnIfOnSignedTimesheet(booking, organizationId: orgId)
        let outbox = OfflineOutboxStore.shared
        // 1.33.1 review fix 3: a queued write of this booking that the outbox is replaying right now is already out of
        // the app's hands (a replayed create would land after "nothing to send" and bring the booking back). It counts
        // as held by Firestore: the delete goes through Firestore, after it.
        let replayInFlight = outbox.isInFlight(bookingId: booking.id)
        let pendingInFirestore = replayInFlight
            || SDKPendingWrites.shared.contains(collection: "bookings", documentId: booking.documentKey)
        if Self.deleteRoute(
            queuesWhileOffline: OfflinePolicy.queuesWhileOffline(action, isOnline: smartCache?.isOnline ?? true),
            pendingInFirestore: pendingInFirestore
        ) == .outbox {
            outbox.enqueueDeleteBooking(booking, fingerprint: fingerprint, organizationId: orgId)
            return
        }
        if replayInFlight {
            // Bounded: the replayed write is handed to Firestore first, so the delete and its tombstone follow it.
            await outbox.waitUntilNotInFlight(bookingId: booking.id, timeoutSeconds: FirestoreWriteAck.defaultTimeoutSeconds)
        }

        // 1.33.1 review item 5: the delete goes through Firestore, so a change of this booking still queued in the
        // outbox would replay after it and be refused against the tombstone. As `enqueueDeleteBooking` does with a
        // queued edit (RULEBOOK §2), it is taken out; a create still queued offline was never sent: nothing is sent
        // (§2 `dropLocal`). Review fix 1: taken out, not thrown away — a delete that is refused or fails puts the
        // entries back (`requeueBookingSaves`), so the edit the booking is restored with still syncs.
        let taken = outbox.takeQueuedBookingSaves(bookingId: booking.id)
        var queuedFingerprint = fingerprint
        switch taken.kind {
        case .create where !pendingInFirestore:
            return
        case .edit(let baseline):
            queuedFingerprint = baseline ?? fingerprint
        case .nothing, .create:
            break
        }

        do {
            // Deletes and writes the `deletedBookings` tombstone in one batch (RULEBOOK §2).
            if pendingInFirestore {
                // 1.33.1: its create is still on its way in Firestore's queue; the delete goes after it. Bounded, so
                // the screen never waits for ever: a delete not confirmed in time is still with Firestore. Refused
                // after its wait timed out: the queued changes go back (review fix 1), and the store re-reads the
                // booking (`dropLocalCopyAfterLateRefusal`).
                let takenEntries = taken.entries
                do {
                    try await FirestoreWriteAck.run(
                        pendingKey: SDKPendingWrites.key(organizationId: orgId, collection: "bookings", documentId: booking.documentKey),
                        onSettledAfterTimeout: { error in
                            if error != nil {
                                OfflineOutboxStore.shared.requeueBookingSaves(takenEntries)
                            } else {
                                // #209 review item 2: a delete Firestore held is announced only once the server has it.
                                OvertimeReopenNotice.labour(before: booking, after: nil, organizationId: orgId)
                            }
                        }
                    ) {
                        try await fb.deleteBooking(booking, organizationId: orgId)
                    }
                } catch is FirestoreWriteAck.TimedOut {
                    print("🔥🔥🔥 DEBUG: Delete of \(booking.documentKey) is with Firestore, pending sync")
                    return
                }
            } else {
                try await fb.deleteBooking(booking, organizationId: orgId)
            }
            // RULEBOOK 1.33.0 §25 reopen: the PAYE overtime line this booking carried (best effort, after the delete).
            OvertimeReopenNotice.labour(before: booking, after: nil, organizationId: orgId)
        } catch {
            if OfflineWriteSupport.shouldQueue(error: error, isOnline: smartCache?.isOnline ?? true),
               OfflinePolicy.availability(action) == .allowedOffline {
                // The connection dropped: the delete waits in the outbox with its tombstone (§2); it replaces the
                // queued edit, as an offline delete always does.
                outbox.enqueueDeleteBooking(booking, fingerprint: queuedFingerprint, organizationId: orgId)
                return
            }
            // Refused (only an admin or the job's manager may delete it): it is still on the server; put it back, with
            // its queued edit (review fix 1).
            outbox.requeueBookingSaves(taken.entries)
            restoreDeletedBooking(booking)
            errorMessage = error.localizedDescription
            print("🔥🔥🔥 DEBUG: Error deleting booking from Firebase: \(error)")
        }
    }

    /// `bookingDeleteSignedTimesheetWarning` for the booked person's timesheets: shown once, the delete still goes ahead.
    private func warnIfOnSignedTimesheet(_ booking: Booking, organizationId: String) {
        guard let fb = firebaseBackend,
              let account = accountForLabourBooking(operativeId: booking.operativeId, users: RulebookRosterSnapshot.users) else { return }
        let dayKey = OrganizationRulebookContext.dayKey(booking.date)
        Task { @MainActor in
            let sheets = await fb.signedTimesheetCandidates(organizationId: organizationId, userId: account.id)
            if let warning = CanonicalBusinessEngine.bookingDeleteSignedTimesheetWarning(dayKey: dayKey, sheets: sheets) {
                OfflineOutboxStore.shared.lastNoticeMessage = warning
            }
        }
    }
    
    // MARK: - Booking Creation
    
    func bookOperative(
        _ operative: Operative,
        on date: Date,
        timeSlot: TimeSlot,
        for project: Project,
        bookedBy: String,
        notes: String? = nil,
        workStartTime: String? = nil,
        workEndTime: String? = nil,
        isBreakRemoved: Bool = false,
        otMultiplierOverride: Double? = nil,
        bookingGroupId: String? = nil
    ) async {
        // Update updatedAt when creating
        var updatedBooking = Booking(
            operativeId: operative.id,
            projectId: project.id,
            date: date,
            timeSlot: timeSlot,
            bookedBy: bookedBy,
            notes: notes,
            workStartTime: workStartTime,
            workEndTime: workEndTime,
            isBreakRemoved: isBreakRemoved,
            otMultiplierOverride: otMultiplierOverride,
            bookingGroupId: bookingGroupId
        )
        updatedBooking.updatedAt = Date()
        
        await addBooking(updatedBooking)
    }
    
    func bookOperatives(
        _ operatives: [Operative],
        on dates: [Date],
        timeSlots: [Date: TimeSlot],
        for project: Project,
        bookedBy: String,
        notes: String? = nil
    ) async {
        // Create multiple bookings for multiple operatives on multiple dates
        for operative in operatives {
            for date in dates {
                if let timeSlot = timeSlots[date] {
                    var booking = Booking(
                        operativeId: operative.id,
                        projectId: project.id,
                        date: date,
                        timeSlot: timeSlot,
                        bookedBy: bookedBy,
                        notes: notes
                    )
                    booking.updatedAt = Date()
                    await addBooking(booking)
                }
            }
        }
    }
    
    // MARK: - Computed Properties
    
    var bookingsByDate: [Date: [Booking]] {
        // Business day in the organisation zone (RULEBOOK §1), not the phone's.
        Dictionary(grouping: bookings) { OrganizationRulebookContext.calendar.startOfDay(for: $0.date) }
    }
    
    var bookingsByOperative: [UUID: [Booking]] {
        Dictionary(grouping: bookings) { $0.operativeId }
    }
    
    var bookingsByProject: [UUID: [Booking]] {
        Dictionary(grouping: bookings) { $0.projectId }
    }
    
    var upcomingBookings: [Booking] {
        bookings.filter { 
            $0.date >= Date() && 
            ($0.status.occupiesDay)
        }.sorted { $0.date < $1.date }
    }
    
    var todaysBookings: [Booking] {
        let calendar = OrganizationRulebookContext.calendar
        let today = calendar.startOfDay(for: Date())
        return bookings.filter { 
            calendar.isDate($0.date, inSameDayAs: today) &&
            ($0.status.occupiesDay)
        }.sorted { $0.timeSlot.rawValue < $1.timeSlot.rawValue }
    }
    
    var confirmedBookings: [Booking] {
        bookings.filter { $0.status == .confirmed }
    }
    
    var tentativeBookings: [Booking] {
        bookings.filter { $0.status == .tentative }
    }
    
    var completedBookings: [Booking] {
        bookings.filter { $0.status == .completed }
    }
    
    // MARK: - Booking Queries
    
    func bookings(for operative: Operative, on date: Date) -> [Booking] {
        let calendar = OrganizationRulebookContext.calendar
        let dayStart = calendar.startOfDay(for: date)
        return bookings.filter { 
            $0.operativeId == operative.id && 
            calendar.isDate($0.date, inSameDayAs: dayStart) &&
            ($0.status.occupiesDay)
        }
    }
    
    func bookings(for project: Project, on date: Date) -> [Booking] {
        let calendar = OrganizationRulebookContext.calendar
        let dayStart = calendar.startOfDay(for: date)
        return bookings.filter { 
            $0.projectId == project.id && 
            calendar.isDate($0.date, inSameDayAs: dayStart) &&
            ($0.status.occupiesDay)
        }
    }
    
    func bookings(for operative: Operative, from startDate: Date, to endDate: Date) -> [Booking] {
        bookings.filter { 
            $0.operativeId == operative.id && 
            $0.date >= startDate && 
            $0.date <= endDate &&
            ($0.status.occupiesDay)
        }.sorted { $0.date < $1.date }
    }
    
    func bookings(for project: Project, from startDate: Date, to endDate: Date) -> [Booking] {
        bookings.filter { 
            $0.projectId == project.id && 
            $0.date >= startDate && 
            $0.date <= endDate &&
            ($0.status.occupiesDay)
        }.sorted { $0.date < $1.date }
    }
    
    // MARK: - Conflict Detection
    
    func detectConflicts(for operative: Operative, on date: Date) -> [BookingConflict] {
        let dayBookings = bookings(for: operative, on: date)
        
        if dayBookings.count <= 1 {
            return []
        }
        
        var conflicts: [BookingConflict] = []
        let groupedByTime = Dictionary(grouping: dayBookings) { $0.timeSlot }
        
        // Check for overlapping time slots
        for (_, bookings) in groupedByTime {
            if bookings.count > 1 {
                conflicts.append(BookingConflict(
                    date: date,
                    operative: operative,
                    conflictingBookings: bookings
                ))
            }
        }
        
        // Check for full day conflicts with other slots
        if let fullDayBookings = groupedByTime[.fullDay], !fullDayBookings.isEmpty {
            let otherBookings = dayBookings.filter { $0.timeSlot != .fullDay }
            if !otherBookings.isEmpty {
                conflicts.append(BookingConflict(
                    date: date,
                    operative: operative,
                    conflictingBookings: fullDayBookings + otherBookings
                ))
            }
        }
        
        return conflicts
    }
    
    func allConflicts() -> [BookingConflict] {
        // TODO: Implement conflict detection across all operatives
        // This requires access to the operative store to resolve operative IDs
        return []
    }
    
    // MARK: - Persistence
    
    /// One booking to write: `changedFields` nil is a create (whole booking); otherwise only those fields.
    struct BookingWrite {
        let booking: Booking
        let changedFields: Set<String>?
        /// RULEBOOK 1.33.0: `bookingDeleteFingerprint` of the copy before this edit (kept with a queued edit).
        var baselineFingerprint: String? = nil
        /// RULEBOOK 1.33.0 §25: the copy before this edit, queued with it so the replay can send the reopen notice.
        var previous: Booking? = nil
    }

    /// "Pending sync" wording for a write kept on this phone that the server has not confirmed yet (1.33.1).
    static let pendingSyncMessage = "Saved on this phone. Pending sync — it will sync when the connection recovers."

    /// What `performWrites` did with one save's writes.
    struct WriteRun {
        var results: [UUID: BookingSaveResult] = [:]
        var refusedIds = Set<UUID>()
        var refusalMessage: String?
        /// Kept on this phone, not yet confirmed (Firestore's queue, or the app outbox).
        var pendingCount = 0
        /// Held by Firestore after its wait timed out (not the app outbox): the server's answer comes later. The value
        /// is that write's `SDKPendingWrites` ticket (nil when it was not marked).
        var sdkPending: [UUID: UInt64?] = [:]
    }

    /// 1.33.1: writes each booking in order through `write` and reports each one's outcome.
    /// - Confirmed: `.saved`.
    /// - The server did not confirm in time (`FirestoreWriteAck.TimedOut`): Firestore already holds the write and
    ///   delivers it (later writes to the same booking go after it), so it is `.queued` as Pending sync and **not** put
    ///   in the app outbox — a second copy there was sent twice.
    /// - A network failure before anything was handed to Firestore: queued in the app outbox as before (§2).
    /// - Refused: `.refused` with the rulebook's message for a final refusal (`bookingReplayRefusedIsFinal`).
    /// Every outbox entry uses `organizationId`, the organisation this save captured, never the one open now.
    /// `write` gets the confirmation wait for that write: the full `FirestoreWriteAck.defaultTimeoutSeconds` until one
    /// write of this save times out, then `afterTimeoutAckSeconds`, so a group save on a weak signal never waits 15 s
    /// per booking (the later writes are still handed to Firestore in order and reported Pending sync).
    /// Review item 1: the timeout state is the save's `BookingWriteSession`, so it carries across every edit and new
    /// booking of one Confirm, and a timed-out read before an edit counts too.
    static let afterTimeoutAckSeconds: Double = BookingWriteSession.afterTimeoutWaitSeconds

    static func performWrites(
        _ writes: [BookingWrite],
        organizationId: String,
        isOnline: Bool,
        session: BookingWriteSession? = nil,
        write: (BookingWrite, _ ackTimeoutSeconds: Double) async throws -> Void
    ) async -> WriteRun {
        var run = WriteRun()
        let session = session ?? BookingWriteSession(organizationId: organizationId)
        for item in writes {
            do {
                try await write(item, session.ackSeconds)
                run.results[item.booking.id] = .saved
            } catch {
                session.note(error)
                if FirestoreWriteAck.isPendingInSDK(error) {
                    run.pendingCount += 1
                    run.sdkPending[item.booking.id] = FirestoreWriteAck.pendingTicket(error)
                    run.results[item.booking.id] = .queued(pendingSyncMessage)
                } else if OfflineWriteSupport.shouldQueue(error: error, isOnline: isOnline) {
                    OfflineOutboxStore.shared.enqueueSaveBooking(
                        item.booking,
                        changedFields: item.changedFields,
                        organizationId: organizationId,
                        baselineFingerprint: item.baselineFingerprint,
                        previous: item.previous
                    )
                    run.pendingCount += 1
                    run.results[item.booking.id] = .queued(pendingSyncMessage)
                } else if BookingWritePatch.isRefusedFinal(error, isCreate: item.changedFields == nil) {
                    // Tombstoned (deleted elsewhere) or cancelled by someone who may reinstate it.
                    run.refusedIds.insert(item.booking.id)
                    run.results[item.booking.id] = .refused(CanonicalBusinessEngine.bookingReplayRefusedMessage)
                } else {
                    let message = error.localizedDescription
                    run.refusalMessage = run.refusalMessage ?? message
                    run.refusedIds.insert(item.booking.id)
                    run.results[item.booking.id] = .refused(message)
                }
                print("🔥🔥🔥 DEBUG: Booking write \(item.booking.id.uuidString) not confirmed: \(error)")
            }
        }
        return run
    }

    /// RULEBOOK 1.33.0 §25 reopen for an edit reported Pending sync because the server did not confirm it in time
    /// (Firestore holds it): the notice is sent when the server confirms it, also late, and never when the server
    /// refuses it (`SDKPendingWrites.whenConfirmed`; the leave pattern). An edit queued in the app outbox is told on
    /// replay instead (`OfflineSyncCoordinator`), and a confirmed one at once (`updateBookingReturningResult`).
    static func holdReopenNoticesUntilConfirmed(_ writes: [BookingWrite], run: WriteRun, organizationId: String) {
        for write in writes {
            guard let ticket = run.sdkPending[write.booking.id],
                  write.changedFields != nil, let before = write.previous else { continue }
            let after = write.booking
            SDKPendingWrites.shared.whenConfirmed(ticket: ticket) {
                // One notice per change: an older queued edit of this booking replays later, silently.
                OfflineOutboxStore.shared.clearReopenBaseline(bookingId: after.id)
                OvertimeReopenNotice.labour(before: before, after: after, organizationId: organizationId)
            }
        }
    }

    /// Saves the list on this device, then writes only `writes` to Firestore (RULEBOOK §1 partial writes).
    /// Offline, each write goes to the outbox with its changed fields and shows "Pending sync" (§2).
    /// 1.33.1: returns what happened to each write (saved, Pending sync, or refused), so a screen reports this save's
    /// own outcome (`performWrites`). The organisation is read once, at the start, and used for every write.
    @discardableResult
    private func saveData(
        writes: [BookingWrite] = [],
        organizationId capturedOrganizationId: String? = nil,
        session: BookingWriteSession? = nil,
        writtenTo: ((String) -> Void)? = nil
    ) async -> [UUID: BookingSaveResult] {
        var results: [UUID: BookingSaveResult] = [:]
        do {
            // Save to local storage
            try await persistenceService.saveBookingData(bookings: bookings)
            smartCache?.cacheBookings(bookings)

            guard !writes.isEmpty else {
                ScheduleChangeNotifier.postBookingStoreDidChange()
                return results
            }

            let resolvedOrganizationId: String?
            if let capturedOrganizationId {
                resolvedOrganizationId = capturedOrganizationId
            } else {
                resolvedOrganizationId = await DataPersistenceManager.shared.waitForOrganization(
                    firebaseBackend: firebaseBackend,
                    maxWaitSeconds: smartCache?.isOnline == false ? 1 : 10
                ) ?? firebaseBackend?.resolvedOrganizationIdForOfflineWrites()
            }
            let organizationId = resolvedOrganizationId
            // The organisation every write of this save goes to: the caller's notices name it, never the one open
            // when they are sent.
            if let organizationId { writtenTo?(organizationId) }

            if smartCache?.isOnline == false {
                if let organizationId {
                    for write in writes {
                        OfflineOutboxStore.shared.enqueueSaveBooking(
                            write.booking,
                            changedFields: write.changedFields,
                            organizationId: organizationId,
                            baselineFingerprint: write.baselineFingerprint,
                            previous: write.previous
                        )
                        results[write.booking.id] = .queued(Self.pendingSyncMessage)
                    }
                    print("🔥🔥🔥 DEBUG: Queued \(writes.count) bookings for offline sync")
                } else {
                    errorMessage = "Saved locally. Organization not available to queue cloud sync yet."
                    for write in writes { results[write.booking.id] = .queued(errorMessage ?? Self.pendingSyncMessage) }
                }
                ScheduleChangeNotifier.postBookingStoreDidChange()
                return results
            }

            if let organizationId,
               let firebaseBackend = firebaseBackend {

                print("🔥🔥🔥 DEBUG: Saving bookings to Firebase for organization: \(organizationId)")

                let session = session ?? BookingWriteSession(organizationId: organizationId)
                let run = await Self.performWrites(
                    writes,
                    organizationId: organizationId,
                    isOnline: smartCache?.isOnline ?? true,
                    session: session
                ) { write, ackTimeout in
                    try await firebaseBackend.saveBooking(
                        write.booking,
                        organizationId: organizationId,
                        changedFields: write.changedFields,
                        ackTimeoutSeconds: ackTimeout,
                        session: session
                    )
                }
                results = run.results
                Self.holdReopenNoticesUntilConfirmed(writes, run: run, organizationId: organizationId)

                if !run.refusedIds.isEmpty {
                    // A refused create is never on the server: drop it. A refused edit comes back from the
                    // listener with the server's values.
                    let refusedCreates = Set(writes.filter { $0.changedFields == nil && run.refusedIds.contains($0.booking.id) }.map(\.booking.id))
                    if !refusedCreates.isEmpty {
                        bookings.removeAll { refusedCreates.contains($0.id) }
                        smartCache?.cacheBookings(bookings)
                        try? await persistenceService.saveBookingData(bookings: bookings)
                    }
                    errorMessage = run.refusalMessage ?? CanonicalBusinessEngine.bookingReplayRefusedMessage
                } else if run.pendingCount > 0 {
                    errorMessage = "Some bookings saved on this phone and will sync when the connection recovers."
                    print("🔥🔥🔥 DEBUG: Saved \(writes.count - run.pendingCount)/\(writes.count) bookings to Firebase; the rest are pending sync")
                } else {
                    errorMessage = nil
                    print("🔥🔥🔥 DEBUG: Successfully saved \(writes.count) bookings to Firebase")
                    ScheduleChangeNotifier.postBookingStoreDidChange()
                    return results
                }
            } else {
                print("🔥🔥🔥 DEBUG: Saved \(bookings.count) bookings locally (Firebase not available or not authenticated)")
                if let organizationId {
                    for write in writes {
                        OfflineOutboxStore.shared.enqueueSaveBooking(
                            write.booking,
                            changedFields: write.changedFields,
                            organizationId: organizationId,
                            baselineFingerprint: write.baselineFingerprint,
                            previous: write.previous
                        )
                    }
                }
                for write in writes { results[write.booking.id] = .queued(Self.pendingSyncMessage) }
            }
        } catch {
            errorMessage = "Failed to save data: \(error.localizedDescription)"
            for write in writes where results[write.booking.id] == nil {
                results[write.booking.id] = .refused(errorMessage ?? error.localizedDescription)
            }
        }
        ScheduleChangeNotifier.postBookingStoreDidChange()
        return results
    }

    func discardInMemoryForOrganizationSwitch() {
        bookings = []
        finishedLoadOrganizationId = nil
        lastLoadFailed = false
        listenerFailed = false
        isLoading = false
        pendingReloadAfterCurrentLoad = false
        errorMessage = nil
    }

    private func bookingsInsideLaunchWindow(_ bookings: [Booking]?) -> [Booking] {
        let lowerBound = firebaseBackend?.scheduleBookingQueryStart()
        return (bookings ?? []).filter {
            LaunchStartupPolicy.launchBookingIncludes(date: $0.date, lowerBound: lowerBound)
        }
    }

    func startLiveUpdates(organizationId: String, startingOn start: Date? = nil) {
        firebaseBackend?.listenBookings(organizationId: organizationId, startingOn: start) { [weak self] remote, fromCache in
            guard let self else { return }
            guard WarningsBookingScanScheduler.acceptsListener(
                listenerOrganizationId: organizationId,
                currentOrganizationId: self.firebaseBackend?.currentOrganization?.firestoreDocumentId,
                sessionOrganizationId: self.firebaseBackend?.sessionOrganizationId
            ) else {
                return
            }
            self.applyRemoteBookings(remote, fromCache: fromCache)
        }
    }

    /// How one listener snapshot replaces the bookings held (`existing`: the bookings inside the launch window).
    /// A server snapshot is the whole query result and replaces the list (unless it is the same bookings); a cache
    /// snapshot never empties the list and, when shorter, only adds and updates. The pure part of
    /// `applyRemoteBookings`, so the data-parity fixture (RULEBOOK 1.38.0 §27, `DataParityFixtureTests`) runs this
    /// exact code. `changed` false: keep `existing`.
    static func liveBookingsMerge(existing: [Booking], remote: [Booking], fromCache: Bool) -> (list: [Booking], changed: Bool) {
        if !fromCache {
            if BookingStore.sameBookings(remote, existing) { return (existing, false) }
            return (remote, true)
        }
        if remote.isEmpty && !existing.isEmpty { return (existing, false) }
        if remote.count < existing.count {
            var byId = Dictionary(existing.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            for booking in remote {
                byId[booking.id] = booking
            }
            return (Array(byId.values), true)
        }
        if BookingStore.sameBookings(remote, existing) { return (existing, false) }
        return (remote, true)
    }

    /// A cache snapshot must not delete bookings that are already on screen. A server snapshot is the
    /// whole query result, so it replaces the list: a booking deleted or moved on the web leaves this
    /// device too instead of being merged back in. Rows older than the launch window are not kept.
    private func applyRemoteBookings(_ serverRows: [Booking], fromCache: Bool) {
        // RULEBOOK §2: a booking created or edited offline stays on screen ("Pending sync") until the outbox
        // replays it; a queued delete stays gone. The server copy is used for everything else.
        var remote = serverRows
        if let organizationId = firebaseBackend?.currentOrganization?.firestoreDocumentId {
            let pending = OfflineOutboxStore.shared.pendingLabourBookings(organizationId: organizationId)
            remote = BookingStore.overlayingPendingOutbox(serverRows, pendingSaves: pending.saves, pendingDeletes: pending.deletedIds)
        }
        let lowerBound = firebaseBackend?.scheduleBookingQueryStart()
        let existing = bookings.filter {
            LaunchStartupPolicy.launchBookingIncludes(date: $0.date, lowerBound: lowerBound)
        }
        if !fromCache {
            listenerFailed = false
            // RULEBOOK §2 read-only offline screens show "Last updated" from this.
            smartCache?.markSynced()
            if remote.count < existing.count, !BookingStore.sameBookings(remote, existing) {
                NSLog("BOOKINGS_SERVER_REPLACED kept=%d removed=%d", remote.count, existing.count - remote.count)
            }
        }
        let merged = BookingStore.liveBookingsMerge(existing: existing, remote: remote, fromCache: fromCache)
        guard merged.changed else {
            if bookings.count != existing.count { bookings = existing }
            if fromCache && remote.isEmpty && !existing.isEmpty {
                print("🔥🔥🔥 DEBUG: BOOKINGS_KEPT \(existing.count) — refused an empty update fromCache=\(fromCache)")
            }
            return
        }
        if fromCache && remote.count < existing.count {
            print("🔥🔥🔥 DEBUG: BOOKINGS_KEPT merged \(merged.list.count) (update had \(remote.count), fromCache=\(fromCache))")
        }
        bookings = merged.list
        smartCache?.cacheBookings(merged.list)
        ScheduleChangeNotifier.postBookingStoreDidChange()
    }
    
    /// The server rows with this device's queued creates and edits in place of (or added to) the stored copy, and
    /// its queued deletes left out. Pure, for tests.
    static func overlayingPendingOutbox(
        _ server: [Booking],
        pendingSaves: [Booking],
        pendingDeletes: Set<UUID>
    ) -> [Booking] {
        guard !pendingSaves.isEmpty || !pendingDeletes.isEmpty else { return server }
        let pendingIds = Set(pendingSaves.map(\.id))
        var out = server.filter { !pendingIds.contains($0.id) && !pendingDeletes.contains($0.id) }
        out += pendingSaves.filter { !pendingDeletes.contains($0.id) }
        return out
    }

    /// Same ids and the same stored fields, in any order.
    static func sameBookings(_ lhs: [Booking], _ rhs: [Booking]) -> Bool {
        guard lhs.count == rhs.count else { return false }
        let incoming = lhs.sorted { $0.id.uuidString < $1.id.uuidString }
        let current = rhs.sorted { $0.id.uuidString < $1.id.uuidString }
        return zip(incoming, current).allSatisfy { lhs, rhs in
            lhs.id == rhs.id && lhs.updatedAt == rhs.updatedAt && lhs.status == rhs.status
                && lhs.timeSlot == rhs.timeSlot && lhs.workStartTime == rhs.workStartTime
                && lhs.workEndTime == rhs.workEndTime && lhs.projectId == rhs.projectId
                && lhs.operativeId == rhs.operativeId && lhs.date == rhs.date
        }
    }

    func clearAllData() async {
        bookings.removeAll()
        await saveData()
    }
}

/// What one booking write did (1.33.1 review item 4).
nonisolated enum BookingSaveResult: Equatable {
    /// Confirmed by the server.
    case saved
    /// Kept on this phone and queued as Pending sync (offline, or the server did not confirm in time).
    case queued(String)
    /// Refused or failed: not saved. The message says why.
    case refused(String)
    /// 1.33.1 review NIT 5: the same booking is already being saved (a double tap). Nothing was written by this call;
    /// the save already running reports the outcome, so screens show nothing for this one (never "saved").
    case alreadySaving

    /// Saved or queued: the booking exists (or will) and its notices may go out.
    var keepsBooking: Bool {
        if case .refused = self { return false }
        return true
    }
}

/// 1.33.1 review fix 2: what reading a booking again after a late refusal found.
enum BookingLateRefusalReread: Equatable {
    /// The server (or this device's cache) has it: it goes back on screen.
    case found(Booking)
    /// The server answered that it does not exist.
    case missing
    /// No reliable answer: the store reloads.
    case unknown
}

/// RULEBOOK §2 "Pending sync" for a labour or manager schedule booking (1.33.1 review item 3): a change in the app
/// outbox, or a write Firestore holds whose confirmation wait timed out (`SDKPendingWrites`). One test for the stores
/// and the rows (`PendingSyncIndicator`).
enum BookingPendingSync {
    @MainActor
    static func isPending(bookingId: UUID, collection: String, documentKey: String) -> Bool {
        isPending(entityId: bookingId.uuidString, collection: collection, documentKey: documentKey)
    }

    @MainActor
    static func isPending(entityId: String, collection: String?, documentKey: String?) -> Bool {
        if OfflineOutboxStore.shared.hasPendingSync(entityId: entityId) { return true }
        guard let collection, let documentKey else { return false }
        return SDKPendingWrites.shared.contains(collection: collection, documentId: documentKey)
    }

    /// Ids compare as stored, normalised and without case; an empty id on either side matches (as the restore notes).
    nonisolated static func sameOrganization(_ a: String, _ b: String) -> Bool {
        let left = a.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let right = b.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return left.isEmpty || right.isEmpty || left == right
    }
}
