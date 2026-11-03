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
        guard !newBookings.isEmpty else { return }
        // RULEBOOK §1: organisation-zone midnight of each booking's day (`BookingDay`).
        let newBookings = newBookings.map { booking -> Booking in
            var booking = booking
            booking.date = BookingDay.organizationMidnight(for: booking.date)
            return booking
        }
        if let refusal = writeRefusal(newBookings) {
            errorMessage = refusal
            return
        }
        bookings.append(contentsOf: newBookings)
        await saveData(writes: newBookings.map { BookingWrite(booking: $0, changedFields: nil) })
    }
    
    /// Saves only the fields that changed against the copy on this device (RULEBOOK §1 partial writes).
    func updateBooking(_ booking: Booking) async {
        var booking = booking
        booking.date = BookingDay.organizationMidnight(for: booking.date)
        if let index = bookings.firstIndex(where: { $0.id == booking.id }) {
            // Both the job it was on and the job it moves to must be the viewer's.
            if let refusal = writeRefusal([bookings[index], booking]) {
                errorMessage = refusal
                return
            }
            let changed = BookingWritePatch.changedLabourFields(from: bookings[index], to: booking)
            bookings[index] = booking
            await saveData(writes: changed.isEmpty ? [] : [BookingWrite(booking: booking, changedFields: changed)])
        }
    }

    /// RULEBOOK §2 "Pending sync": this booking has a change in the outbox the server has not confirmed.
    func isPendingSync(_ booking: Booking) -> Bool {
        OfflineOutboxStore.shared.hasPendingSync(bookingId: booking.id)
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

    func deleteBooking(_ booking: Booking) async {
        // RULEBOOK §2 (`offlineAvailability("booking.delete")`): deleting a booking is online only; the
        // delete and its tombstone are never queued.
        guard OfflinePolicy.isEnabled(.deleteBooking, isOnline: smartCache?.isOnline ?? true) else {
            errorMessage = OfflinePolicy.onlineOnlyMessage
            return
        }
        if let refusal = writeRefusal([booking], isDelete: true) {
            errorMessage = refusal
            return
        }
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

        do {
            // Deletes and writes the `deletedBookings` tombstone in one batch (RULEBOOK §2).
            try await fb.deleteBooking(booking, organizationId: orgId)
        } catch {
            // Refused (for example: only an admin may delete a labour booking), or the connection dropped:
            // deletes are online only, so nothing is queued. It still exists on the server; put it back.
            if !bookings.contains(where: { $0.id == booking.id }) {
                bookings.append(booking)
                smartCache?.cacheBookings(bookings)
                try? await persistenceService.saveBookingData(bookings: bookings)
                ScheduleChangeNotifier.postBookingStoreDidChange()
            }
            errorMessage = OfflineWriteSupport.shouldQueue(error: error, isOnline: smartCache?.isOnline ?? true)
                ? OfflinePolicy.onlineOnlyMessage
                : error.localizedDescription
            print("🔥🔥🔥 DEBUG: Error deleting booking from Firebase: \(error)")
        }
    }
    
    func cancelBooking(_ booking: Booking) async {
        if let index = bookings.firstIndex(where: { $0.id == booking.id }) {
            if let refusal = writeRefusal([bookings[index]]) {
                errorMessage = refusal
                return
            }
            bookings[index].status = .cancelled
            await saveData(writes: [BookingWrite(booking: bookings[index], changedFields: ["status"])])
        }
    }
    
    func completeBooking(_ booking: Booking) async {
        if let index = bookings.firstIndex(where: { $0.id == booking.id }) {
            if let refusal = writeRefusal([bookings[index]]) {
                errorMessage = refusal
                return
            }
            bookings[index].status = .completed
            await saveData(writes: [BookingWrite(booking: bookings[index], changedFields: ["status"])])
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
    
    var cancelledBookings: [Booking] {
        bookings.filter { $0.status == .cancelled }
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
    }

    /// Saves the list on this device, then writes only `writes` to Firestore (RULEBOOK §1 partial writes).
    /// Offline, each write goes to the outbox with its changed fields and shows "Pending sync" (§2).
    private func saveData(writes: [BookingWrite] = []) async {
        do {
            // Save to local storage
            try await persistenceService.saveBookingData(bookings: bookings)
            smartCache?.cacheBookings(bookings)

            guard !writes.isEmpty else {
                ScheduleChangeNotifier.postBookingStoreDidChange()
                return
            }

            let organizationId = await DataPersistenceManager.shared.waitForOrganization(
                firebaseBackend: firebaseBackend,
                maxWaitSeconds: smartCache?.isOnline == false ? 1 : 10
            ) ?? firebaseBackend?.resolvedOrganizationIdForOfflineWrites()

            if smartCache?.isOnline == false {
                if let organizationId {
                    for write in writes {
                        OfflineOutboxStore.shared.enqueueSaveBooking(
                            write.booking,
                            changedFields: write.changedFields,
                            organizationId: organizationId
                        )
                    }
                    print("🔥🔥🔥 DEBUG: Queued \(writes.count) bookings for offline sync")
                } else {
                    errorMessage = "Saved locally. Organization not available to queue cloud sync yet."
                }
                ScheduleChangeNotifier.postBookingStoreDidChange()
                return
            }

            if let organizationId,
               let firebaseBackend = firebaseBackend {

                print("🔥🔥🔥 DEBUG: Saving bookings to Firebase for organization: \(organizationId)")

                var failedCount = 0
                var refusedIds = Set<UUID>()
                for write in writes {
                    do {
                        try await firebaseBackend.saveBooking(
                            write.booking,
                            organizationId: organizationId,
                            changedFields: write.changedFields
                        )
                    } catch {
                        failedCount += 1
                        if OfflineWriteSupport.shouldQueue(error: error, isOnline: smartCache?.isOnline ?? true),
                           let orgId = firebaseBackend.resolvedOrganizationIdForOfflineWrites() {
                            OfflineOutboxStore.shared.enqueueSaveBooking(
                                write.booking,
                                changedFields: write.changedFields,
                                organizationId: orgId
                            )
                        } else if BookingWritePatch.isRefusedFinal(error, isCreate: write.changedFields == nil) {
                            // Tombstoned (deleted elsewhere) or cancelled by someone who may reinstate it.
                            refusedIds.insert(write.booking.id)
                        }
                        print("🔥🔥🔥 DEBUG: Error saving booking \(write.booking.id.uuidString): \(error)")
                    }
                }

                if !refusedIds.isEmpty {
                    // A refused create is never on the server: drop it. A refused edit comes back from the
                    // listener with the server's values.
                    let refusedCreates = Set(writes.filter { $0.changedFields == nil && refusedIds.contains($0.booking.id) }.map(\.booking.id))
                    if !refusedCreates.isEmpty {
                        bookings.removeAll { refusedCreates.contains($0.id) }
                        smartCache?.cacheBookings(bookings)
                        try? await persistenceService.saveBookingData(bookings: bookings)
                    }
                    errorMessage = CanonicalBusinessEngine.bookingReplayRefusedMessage
                } else if failedCount > 0 {
                    if OfflineOutboxStore.shared.pendingCount > 0 {
                        errorMessage = "Some bookings saved locally and will sync when you're back online."
                    } else {
                        errorMessage = "Some bookings could not be synced to cloud (\(failedCount))."
                    }
                    print("🔥🔥🔥 DEBUG: Saved \(writes.count - failedCount)/\(writes.count) bookings to Firebase")
                } else {
                    errorMessage = nil
                    print("🔥🔥🔥 DEBUG: Successfully saved \(writes.count) bookings to Firebase")
                }
            } else {
                print("🔥🔥🔥 DEBUG: Saved \(bookings.count) bookings locally (Firebase not available or not authenticated)")
                if let organizationId = firebaseBackend?.resolvedOrganizationIdForOfflineWrites() {
                    for write in writes {
                        OfflineOutboxStore.shared.enqueueSaveBooking(
                            write.booking,
                            changedFields: write.changedFields,
                            organizationId: organizationId
                        )
                    }
                }
            }
        } catch {
            errorMessage = "Failed to save data: \(error.localizedDescription)"
        }
        ScheduleChangeNotifier.postBookingStoreDidChange()
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
            if BookingStore.sameBookings(remote, existing) {
                if bookings.count != existing.count { bookings = existing }
                return
            }
            if remote.count < existing.count {
                NSLog("BOOKINGS_SERVER_REPLACED kept=%d removed=%d", remote.count, existing.count - remote.count)
            }
            bookings = remote
            smartCache?.cacheBookings(remote)
            ScheduleChangeNotifier.postBookingStoreDidChange()
            return
        }
        if remote.isEmpty && !existing.isEmpty {
            bookings = existing
            print("🔥🔥🔥 DEBUG: BOOKINGS_KEPT \(existing.count) — refused an empty update fromCache=\(fromCache)")
            return
        }
        if remote.count < existing.count {
            var byId = Dictionary(existing.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            for booking in remote {
                byId[booking.id] = booking
            }
            let merged = Array(byId.values)
            print("🔥🔥🔥 DEBUG: BOOKINGS_KEPT merged \(merged.count) (update had \(remote.count), fromCache=\(fromCache))")
            bookings = merged
            smartCache?.cacheBookings(merged)
            ScheduleChangeNotifier.postBookingStoreDidChange()
            return
        }
        if BookingStore.sameBookings(remote, existing) {
            if bookings.count != existing.count {
                bookings = existing
            }
            return
        }
        bookings = remote
        smartCache?.cacheBookings(remote)
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
