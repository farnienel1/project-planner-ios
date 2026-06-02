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
    @Published var bookings: [Booking] = []
    @Published var isLoading: Bool = false
    @Published var errorMessage: String?
    @Published var isOffline: Bool = false
    
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
                print("🔥🔥🔥 DEBUG: BookingStore received organizationDidLoad notification - reloading data")
                self?.loadData()
                // Avoid auto-syncing every booking on org load; this creates large startup write storms.
                // Booking saves still happen on user actions and offline sync notifications.
            }
        }
        
        // Listen for offline sync trigger (when app comes back online)
        NotificationCenter.default.addObserver(
            forName: .syncOfflineChanges,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                print("🔥🔥🔥 DEBUG: BookingStore received syncOfflineChanges notification - syncing all data to Firebase")
                if let self = self, !self.bookings.isEmpty {
                    await self.saveData()
                }
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
            pendingReloadAfterCurrentLoad = true
            print("🔥🔥🔥 DEBUG: BookingStore loadData ignored (already loading); queued one follow-up reload")
            return
        }
        isLoading = true
        errorMessage = nil
        
        Task { @MainActor in
            defer {
                self.isLoading = false
                if self.pendingReloadAfterCurrentLoad {
                    self.pendingReloadAfterCurrentLoad = false
                    self.loadData()
                }
            }
            do {
                // Try to load from Firebase first if authenticated
                if let firebaseBackend = firebaseBackend, 
                   firebaseBackend.isAuthenticated,
                   let organizationId = firebaseBackend.currentOrganization?.firestoreDocumentId {
                    
                    print("🔥🔥🔥 DEBUG: Loading bookings from Firebase for organization: \(organizationId)")
                    
                    // Load bookings from Firebase
                    let firebaseBookings = try await firebaseBackend.loadBookings(organizationId: organizationId)
                    self.bookings = firebaseBookings
                    self.smartCache?.cacheBookings(firebaseBookings)
                    
                    print("🔥🔥🔥 DEBUG: Loaded \(firebaseBookings.count) bookings from Firebase")
                    
                } else {
                    // Fallback to local storage
                    print("🔥🔥🔥 DEBUG: Loading bookings from local storage (Firebase not available or not authenticated)")
                    print("🔥🔥🔥 DEBUG: Firebase backend: \(firebaseBackend != nil)")
                    print("🔥🔥🔥 DEBUG: Authenticated: \(firebaseBackend?.isAuthenticated ?? false)")
                    print("🔥🔥🔥 DEBUG: Organization: \(firebaseBackend?.currentOrganization?.name ?? "nil")")
                    let bookings = try await persistenceService.loadBookingData()
                    self.bookings = bookings
                    print("🔥🔥🔥 DEBUG: Loaded \(bookings.count) bookings from local storage")
                }
                
            } catch {
                self.errorMessage = error.localizedDescription
                print("🔥🔥🔥 DEBUG: Error loading bookings: \(error.localizedDescription)")
                // Fallback to local cache when Firebase denies/ fails so operative visibility does not fully disappear.
                do {
                    let cached = try await self.persistenceService.loadBookingData()
                    self.bookings = cached
                    print("🔥🔥🔥 DEBUG: Loaded \(cached.count) cached bookings after Firebase error")
                } catch {
                    print("🔥🔥🔥 DEBUG: Local bookings fallback failed: \(error.localizedDescription)")
                    // Keep previous in-memory bookings if any; do not forcibly clear.
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
    
    func addBooking(_ booking: Booking) async {
        bookings.append(booking)
        await saveData(syncingBookingIds: [booking.id])
    }

    /// Append multiple bookings then sync only the new rows (much faster than repeated full saves).
    func addBookings(_ newBookings: [Booking]) async {
        guard !newBookings.isEmpty else { return }
        bookings.append(contentsOf: newBookings)
        await saveData(syncingBookingIds: Set(newBookings.map(\.id)))
    }
    
    func updateBooking(_ booking: Booking) async {
        if let index = bookings.firstIndex(where: { $0.id == booking.id }) {
            bookings[index] = booking
            await saveData()
        }
    }
    
    func deleteBooking(_ booking: Booking) async {
        bookings.removeAll { $0.id == booking.id }
        await saveData()
    }
    
    func cancelBooking(_ booking: Booking) async {
        if let index = bookings.firstIndex(where: { $0.id == booking.id }) {
            bookings[index].status = .cancelled
            await saveData()
        }
    }
    
    func completeBooking(_ booking: Booking) async {
        if let index = bookings.firstIndex(where: { $0.id == booking.id }) {
            bookings[index].status = .completed
            await saveData()
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
        Dictionary(grouping: bookings) { Calendar.current.startOfDay(for: $0.date) }
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
            ($0.status == .confirmed || $0.status == .tentative)
        }.sorted { $0.date < $1.date }
    }
    
    var todaysBookings: [Booking] {
        let today = Calendar.current.startOfDay(for: Date())
        return bookings.filter { 
            Calendar.current.isDate($0.date, inSameDayAs: today) &&
            ($0.status == .confirmed || $0.status == .tentative)
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
        let dayStart = Calendar.current.startOfDay(for: date)
        return bookings.filter { 
            $0.operativeId == operative.id && 
            Calendar.current.isDate($0.date, inSameDayAs: dayStart) &&
            ($0.status == .confirmed || $0.status == .tentative)
        }
    }
    
    func bookings(for project: Project, on date: Date) -> [Booking] {
        let dayStart = Calendar.current.startOfDay(for: date)
        return bookings.filter { 
            $0.projectId == project.id && 
            Calendar.current.isDate($0.date, inSameDayAs: dayStart) &&
            ($0.status == .confirmed || $0.status == .tentative)
        }
    }
    
    func bookings(for operative: Operative, from startDate: Date, to endDate: Date) -> [Booking] {
        bookings.filter { 
            $0.operativeId == operative.id && 
            $0.date >= startDate && 
            $0.date <= endDate &&
            ($0.status == .confirmed || $0.status == .tentative)
        }.sorted { $0.date < $1.date }
    }
    
    func bookings(for project: Project, from startDate: Date, to endDate: Date) -> [Booking] {
        bookings.filter { 
            $0.projectId == project.id && 
            $0.date >= startDate && 
            $0.date <= endDate &&
            ($0.status == .confirmed || $0.status == .tentative)
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
    
    private func saveData(syncingBookingIds: Set<UUID>? = nil) async {
        do {
            // Save to local storage
            try await persistenceService.saveBookingData(bookings: bookings)
            smartCache?.cacheBookings(bookings)

            let bookingsToSave: [Booking]
            if let ids = syncingBookingIds, !ids.isEmpty {
                bookingsToSave = bookings.filter { ids.contains($0.id) }
            } else {
                bookingsToSave = bookings
            }

            guard !bookingsToSave.isEmpty else {
                ScheduleChangeNotifier.postBookingStoreDidChange()
                return
            }

            let organizationId = await DataPersistenceManager.shared.waitForOrganization(
                firebaseBackend: firebaseBackend,
                maxWaitSeconds: smartCache?.isOnline == false ? 1 : 10
            ) ?? firebaseBackend?.resolvedOrganizationIdForOfflineWrites()

            if smartCache?.isOnline == false {
                if let organizationId {
                    for booking in bookingsToSave {
                        OfflineOutboxStore.shared.enqueueSaveBooking(booking, organizationId: organizationId)
                    }
                    print("🔥🔥🔥 DEBUG: Queued \(bookingsToSave.count) bookings for offline sync")
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
                for booking in bookingsToSave {
                    do {
                        try await firebaseBackend.saveBooking(booking, organizationId: organizationId)
                    } catch {
                        failedCount += 1
                        if OfflineWriteSupport.shouldQueue(error: error, isOnline: smartCache?.isOnline ?? true),
                           let orgId = firebaseBackend.resolvedOrganizationIdForOfflineWrites() {
                            OfflineOutboxStore.shared.enqueueSaveBooking(booking, organizationId: orgId)
                        }
                        print("🔥🔥🔥 DEBUG: Error saving booking \(booking.id.uuidString): \(error)")
                    }
                }

                if failedCount > 0 {
                    if OfflineOutboxStore.shared.pendingCount > 0 {
                        errorMessage = "Some bookings saved locally and will sync when you're back online."
                    } else {
                        errorMessage = "Some bookings could not be synced to cloud (\(failedCount))."
                    }
                    print("🔥🔥🔥 DEBUG: Saved \(bookingsToSave.count - failedCount)/\(bookingsToSave.count) bookings to Firebase")
                } else {
                    errorMessage = nil
                    print("🔥🔥🔥 DEBUG: Successfully saved \(bookingsToSave.count) bookings to Firebase")
                }
            } else {
                print("🔥🔥🔥 DEBUG: Saved \(bookings.count) bookings locally (Firebase not available or not authenticated)")
                if let organizationId = firebaseBackend?.resolvedOrganizationIdForOfflineWrites() {
                    for booking in bookingsToSave {
                        OfflineOutboxStore.shared.enqueueSaveBooking(booking, organizationId: organizationId)
                    }
                }
            }
        } catch {
            errorMessage = "Failed to save data: \(error.localizedDescription)"
        }
        ScheduleChangeNotifier.postBookingStoreDidChange()
    }
    
    func clearAllData() async {
        bookings.removeAll()
        await saveData()
    }
}
