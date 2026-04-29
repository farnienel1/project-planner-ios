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
                // After loading, sync any local bookings to Firebase
                if let self = self, !self.bookings.isEmpty {
                    print("🔥🔥🔥 DEBUG: Syncing \(self.bookings.count) local bookings to Firebase after organization load")
                    await self.saveData()
                }
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
    }
    
    // MARK: - Data Loading
    
    func loadData() {
        isLoading = true
        errorMessage = nil
        
        Task { @MainActor in
            do {
                // Try to load from Firebase first if authenticated
                if let firebaseBackend = firebaseBackend, 
                   firebaseBackend.isAuthenticated,
                   let organizationId = firebaseBackend.currentOrganization?.firestoreDocumentId {
                    
                    print("🔥🔥🔥 DEBUG: Loading bookings from Firebase for organization: \(organizationId)")
                    
                    // Load bookings from Firebase
                    let firebaseBookings = try await firebaseBackend.loadBookings(organizationId: organizationId)
                    self.bookings = firebaseBookings
                    
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
                
                self.isLoading = false
            } catch {
                self.errorMessage = error.localizedDescription
                self.isLoading = false
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
        await saveData()
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
        notificationService: NotificationService? = nil
    ) async {
        // Update updatedAt when creating
        var updatedBooking = Booking(
            operativeId: operative.id,
            projectId: project.id,
            date: date,
            timeSlot: timeSlot,
            bookedBy: bookedBy,
            notes: notes
        )
        updatedBooking.updatedAt = Date()
        
        await addBooking(updatedBooking)
        
        // Send notification to the operative who was booked
        if let notificationService = notificationService {
            await notificationService.notifyBookingCreated(
                bookingId: updatedBooking.id,
                operativeId: operative.id,
                projectName: project.siteName,
                date: date,
                createdBy: bookedBy
            )
        }
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
    
    private func saveData() async {
        do {
            // Save to local storage
            try await persistenceService.saveBookingData(bookings: bookings)
            
            // CRITICAL: Wait for organization to load before saving to Firebase
            // This ensures we never save locally when Firebase is available but org isn't ready
            let organizationId = await DataPersistenceManager.shared.waitForOrganization(
                firebaseBackend: firebaseBackend,
                maxWaitSeconds: 10
            )
            
            if let organizationId = organizationId,
               let firebaseBackend = firebaseBackend {
                
                print("🔥🔥🔥 DEBUG: Saving bookings to Firebase for organization: \(organizationId)")
                
                // Save bookings to Firebase (only save changes, not all bookings every time)
                // For now, save all bookings - can be optimized later
                let bookingsToSave = bookings
                var failedCount = 0
                for booking in bookingsToSave {
                    do {
                        try await firebaseBackend.saveBooking(booking, organizationId: organizationId)
                    } catch {
                        failedCount += 1
                        print("🔥🔥🔥 DEBUG: Error saving booking \(booking.id.uuidString): \(error)")
                    }
                }
                
                if failedCount > 0 {
                    errorMessage = "Some bookings could not be synced to cloud (\(failedCount))."
                    print("🔥🔥🔥 DEBUG: Saved \(bookingsToSave.count - failedCount)/\(bookingsToSave.count) bookings to Firebase")
                } else {
                    print("🔥🔥🔥 DEBUG: Successfully saved \(bookingsToSave.count) bookings to Firebase")
                }
            } else {
                print("🔥🔥🔥 DEBUG: Saved \(bookings.count) bookings locally (Firebase not available or not authenticated)")
                print("🔥🔥🔥 DEBUG: Firebase backend: \(firebaseBackend != nil)")
                print("🔥🔥🔥 DEBUG: Authenticated: \(firebaseBackend?.isAuthenticated ?? false)")
                print("🔥🔥🔥 DEBUG: Organization: \(firebaseBackend?.currentOrganization?.name ?? "nil")")
                
                // If Firebase is available but organization isn't loaded yet, wait and retry
                if let firebaseBackend = firebaseBackend,
                   firebaseBackend.isAuthenticated,
                   firebaseBackend.currentOrganization == nil {
                    print("🔥🔥🔥 DEBUG: ⚠️ Organization not loaded yet - will retry save when organization loads")
                    // Organization load will trigger reload via notification, which will save
                }
            }
        } catch {
            errorMessage = "Failed to save data: \(error.localizedDescription)"
        }
    }
    
    func clearAllData() async {
        bookings.removeAll()
        await saveData()
    }
}
