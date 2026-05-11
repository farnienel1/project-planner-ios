//
//  OperativeStore.swift
//  Project Planner
//
//  Created by Assistant on 29/09/2025.
//

import Foundation
import Combine
import FirebaseAuth

@MainActor
class OperativeStore: ObservableObject {
    @Published var operatives: [Operative] = []
    
    @Published var managers: [Manager] = []
    /// Organisation skill catalogue (`organizations/{orgId}/skills`). Operative `skills` stores these document ids.
    @Published var organizationSkills: [OrganizationSkill] = []
    @Published var qualifications: [Qualification] = []
    @Published var isLoading: Bool = false
    @Published var errorMessage: String?
    @Published var isOffline: Bool = false
    
    private(set) var firebaseBackend: FirebaseBackend?
    private var smartCache: SmartCacheService?
    private var cancellables = Set<AnyCancellable>()
    
    init() {
        // Listen for user sign in/out notifications
        NotificationCenter.default.addObserver(
            forName: .userDidSignIn,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            if let userId = notification.object as? String {
                Task { @MainActor [weak self] in
                    await self?.setCurrentUser(userId)
                }
            }
        }
        
        NotificationCenter.default.addObserver(
            forName: .userDidSignOut,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.setCurrentUser(nil)
            }
        }
        
        NotificationCenter.default.addObserver(
            forName: .organizationDidLoad,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                print("🔥🔥🔥 DEBUG: OperativeStore received organizationDidLoad notification - reloading data")
                self?.loadData()
                // Do not auto-sync local rows here: on some roles/org setups this can hit permission-denied
                // during startup and create noisy retry loops that look like the app is "stuck loading".
                // Sync still happens on explicit user actions and offline-change sync events.
            }
        }
        
        // Listen for offline sync trigger (when app comes back online)
        NotificationCenter.default.addObserver(
            forName: .syncOfflineChanges,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                print("🔥🔥🔥 DEBUG: OperativeStore received syncOfflineChanges notification - syncing all data to Firebase")
                if let self = self, (!self.operatives.isEmpty || !self.managers.isEmpty) {
                    _ = await self.saveDataWithRetry(description: "syncing offline changes to Firebase")
                }
            }
        }
    }
    
    deinit {
        NotificationCenter.default.removeObserver(self)
    }
    
    func setCurrentUser(_ userId: String?) async {
        if userId == nil {
            await clearAllData()
        }
        loadData()
    }
    
    func setFirebaseBackend(_ firebaseBackend: FirebaseBackend) {
        self.firebaseBackend = firebaseBackend
    }
    
    func setSmartCache(_ smartCache: SmartCacheService) {
        self.smartCache = smartCache
        self.isOffline = !smartCache.isOnline
    }
    
    // MARK: - Computed Properties
    
    var allOperatives: [Operative] {
        // Filter out any legacy placeholder operatives
        let nonPlaceholderOperatives = operatives.filter { operative in
            let name = operative.name.lowercased()
            let email = operative.email.lowercased()
            return !name.contains("placeholder") && !email.contains("placeholder") && !name.contains("initial")
        }
        return nonPlaceholderOperatives.sorted { operative1, operative2 in
            operative1.name < operative2.name
        }
    }
    
    var activeOperatives: [Operative] {
        // Return only active operatives, filtered and sorted
        return allOperatives.filter { $0.isActive }
    }
    
    /// Managers that are real users set up on the app — excludes any "Initial manager placeholder" or similar legacy placeholders.
    var allManagers: [Manager] {
        managers.filter { !Self.isPlaceholderManager($0) }
            .sorted { $0.fullName < $1.fullName }
    }
    
    /// Active managers only (real users, no placeholders).
    var activeManagers: [Manager] {
        allManagers.filter { $0.isActive }
    }
    
    /// Returns true if the manager is a legacy/placeholder entry (e.g. "Initial manager placeholder system") and should not be shown in the app.
    private static func isPlaceholderManager(_ manager: Manager) -> Bool {
        let name = manager.fullName.lowercased()
        let email = manager.email.lowercased()
        return name.contains("placeholder") || email.contains("placeholder")
    }
    
    // MARK: - Data Loading
    
    func loadData() {
        isLoading = true
        errorMessage = nil
        
        Task {
            // Add timeout to prevent infinite loading
            let timeoutTask = Task {
                try? await Task.sleep(nanoseconds: 30_000_000_000) // 30 seconds
                if isLoading {
                    print("🔥🔥🔥 DEBUG: ⚠️ Load timeout - forcing completion")
                    isLoading = false
                    errorMessage = "Loading timed out. Please try 'Force Reload Data' in Settings."
                }
            }
            
            defer {
                timeoutTask.cancel()
                isLoading = false
            }
            
            do {
                // Try to load from Firebase if authenticated (don't require smartCache to be online)
                if let firebaseBackend = firebaseBackend, 
                   firebaseBackend.isAuthenticated {
                    
                    // Wait for organization to load (with timeout)
                    var waitCount = 0
                    while firebaseBackend.currentOrganization == nil && waitCount < 5 {
                        print("🔥🔥🔥 DEBUG: Waiting for organization to load... (\(waitCount + 1)/5)")
                        try? await Task.sleep(nanoseconds: 1_000_000_000) // 1 second
                        waitCount += 1
                    }
                    
                    // Only attempt recovery if organization is still nil
                    if firebaseBackend.currentOrganization == nil {
                        print("🔥🔥🔥 DEBUG: ⚠️ Organization is nil, trying recovery...")
                        if let userId = firebaseBackend.currentUser?.uid,
                           let userEmail = firebaseBackend.currentUser?.email {
                            let recovered = await firebaseBackend.recoverMissingOrganizationLink(userId: userId, userEmail: userEmail)
                            if recovered {
                                print("🔥🔥🔥 DEBUG: ✅ Organization recovered, proceeding with data load")
                            } else {
                                print("🔥🔥🔥 DEBUG: ⚠️ Could not recover organization, will use cached data")
                            }
                        }
                    }
                    
                    // Now try to load with organization (may still be nil if recovery failed)
                    if let organizationId = firebaseBackend.currentOrganization?.firestoreDocumentId {
                        print("🔥🔥🔥 DEBUG: Loading operatives from Firebase for organization: \(organizationId)")
                        
                        // Load operatives from Firebase with timeout
                        let firebaseOperatives = try await withTimeout(seconds: 10) {
                            try await firebaseBackend.loadOperatives(organizationId: organizationId)
                        }
                        
                        // Load managers from Firebase (exclude placeholder/legacy entries so only real users show)
                        let firebaseManagers = try await withTimeout(seconds: 10) {
                            try await firebaseBackend.loadManagers(organizationId: organizationId)
                        }
                        let realManagers = firebaseManagers.filter { !Self.isPlaceholderManager($0) }
                        self.managers = realManagers
                        if let smartCache = smartCache {
                            smartCache.cacheManagers(realManagers)
                        }
                        
                        // Load qualifications from Firebase
                        let firebaseQualifications = try await withTimeout(seconds: 5) {
                            try await firebaseBackend.loadQualifications(organizationId: organizationId)
                        }
                        self.qualifications = firebaseQualifications
                        if let smartCache = smartCache {
                            smartCache.cacheQualifications(firebaseQualifications)
                        }
                        
                        // Load skill catalogue before normalising operative skill tokens
                        let firebaseSkills = try await withTimeout(seconds: 5) {
                            try await firebaseBackend.loadSkills(organizationId: organizationId)
                        }
                        self.organizationSkills = firebaseSkills
                        let normalizedOperatives = Self.normalizeOperativeSkillTokens(operatives: firebaseOperatives, catalog: firebaseSkills)
                        self.operatives = normalizedOperatives
                        if let smartCache = smartCache {
                            smartCache.cacheOrganizationSkills(firebaseSkills)
                            smartCache.cacheOperatives(normalizedOperatives)
                        }
                        
                        print("🔥🔥🔥 DEBUG: ✅ Loaded \(firebaseOperatives.count) operatives, \(realManagers.count) managers from Firebase (filtered from \(firebaseManagers.count) docs)")
                        isOffline = false
                    } else {
                        // Organization still nil after recovery attempt - use cached data
                        print("🔥🔥🔥 DEBUG: Organization still nil after recovery, using cached data")
                        if let smartCache = smartCache {
                            let cachedOperatives = smartCache.getCachedOperatives()
                            let cachedManagers = smartCache.getCachedManagers()
                            managers = cachedManagers.filter { !Self.isPlaceholderManager($0) }
                            let cachedSkillCatalog = smartCache.getCachedOrganizationSkills()
                            organizationSkills = cachedSkillCatalog
                            operatives = cachedSkillCatalog.isEmpty
                                ? cachedOperatives
                                : Self.normalizeOperativeSkillTokens(operatives: cachedOperatives, catalog: cachedSkillCatalog)
                            qualifications = smartCache.getCachedQualifications()
                            isOffline = !smartCache.isOnline
                        } else {
                            isOffline = true
                        }
                    }
                    
                } else {
                    // Fallback to cached data if available
                    print("🔥🔥🔥 DEBUG: Firebase not available - using cached data")
                    if let smartCache = smartCache {
                        let cachedOperatives = smartCache.getCachedOperatives()
                        let cachedManagers = smartCache.getCachedManagers()
                        managers = cachedManagers.filter { !Self.isPlaceholderManager($0) }
                        let cachedSkillCatalog = smartCache.getCachedOrganizationSkills()
                        organizationSkills = cachedSkillCatalog
                        operatives = cachedSkillCatalog.isEmpty
                            ? cachedOperatives
                            : Self.normalizeOperativeSkillTokens(operatives: cachedOperatives, catalog: cachedSkillCatalog)
                        qualifications = smartCache.getCachedQualifications()
                        isOffline = !smartCache.isOnline
                    } else {
                        isOffline = true
                    }
                }
                
                self.isLoading = false
            } catch {
                self.errorMessage = error.localizedDescription
                self.isLoading = false
                print("🔥🔥🔥 DEBUG: Error loading operatives: \(error.localizedDescription)")
                // Keep prior in-memory data whenever possible; fallback to cache before clearing.
                if let smartCache = smartCache {
                    let cachedOperatives = smartCache.getCachedOperatives()
                    let cachedManagers = smartCache.getCachedManagers().filter { !Self.isPlaceholderManager($0) }
                    let cachedSkillCatalog = smartCache.getCachedOrganizationSkills()
                    let cachedQualifications = smartCache.getCachedQualifications()
                    if !cachedManagers.isEmpty { self.managers = cachedManagers }
                    if !cachedSkillCatalog.isEmpty { self.organizationSkills = cachedSkillCatalog }
                    if !cachedQualifications.isEmpty { self.qualifications = cachedQualifications }
                    if !cachedOperatives.isEmpty {
                        self.operatives = cachedSkillCatalog.isEmpty
                            ? cachedOperatives
                            : Self.normalizeOperativeSkillTokens(operatives: cachedOperatives, catalog: cachedSkillCatalog)
                    }
                }
            }
        }
    }
    
    // Helper function to add timeout to async operations
    private func withTimeout<T>(seconds: Double, operation: @escaping () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask {
                try await operation()
            }
            
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw NSError(domain: "TimeoutError", code: -1, userInfo: [NSLocalizedDescriptionKey: "Operation timed out after \(seconds) seconds"])
            }
            
            let result = try await group.next()!
            group.cancelAll()
            return result
        }
    }

    /// Maps legacy operative skill entries (skill name strings) to catalogue document ids when possible.
    private static func normalizeOperativeSkillTokens(operatives: [Operative], catalog: [OrganizationSkill]) -> [Operative] {
        let idSet = Set(catalog.map(\.id))
        var groupedByName: [String: [OrganizationSkill]] = [:]
        for s in catalog {
            let key = s.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            groupedByName[key, default: []].append(s)
        }
        return operatives.map { op in
            var copy = op
            var newSkills = Set<String>()
            for token in op.skills {
                let tTrim = token.trimmingCharacters(in: .whitespacesAndNewlines)
                if idSet.contains(tTrim) {
                    newSkills.insert(tTrim)
                    continue
                }
                let key = tTrim.lowercased()
                guard let matches = groupedByName[key], !matches.isEmpty else {
                    newSkills.insert(tTrim)
                    continue
                }
                if matches.count == 1 {
                    newSkills.insert(matches[0].id)
                } else {
                    let opTradeKey: String = {
                        if let c = op.tradeTypeCustom?.trimmingCharacters(in: .whitespacesAndNewlines), !c.isEmpty {
                            return c.lowercased()
                        }
                        if let p = op.tradeTypePreset?.trimmingCharacters(in: .whitespacesAndNewlines), !p.isEmpty {
                            return p.lowercased()
                        }
                        return ""
                    }()
                    let preferred = matches.first {
                        $0.trade.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == opTradeKey
                    }
                    newSkills.insert((preferred ?? matches[0]).id)
                }
            }
            copy.skills = newSkills
            return copy
        }
    }
    
    // MARK: - Operative Operations
    
    func addOperative(_ operative: Operative) async {
        print("🔥🔥🔥 DEBUG: ========== ADD OPERATIVE START ==========")
        print("🔥🔥🔥 DEBUG: addOperative called with operative: \(operative.name)")
        print("🔥🔥🔥 DEBUG: Operative ID: \(operative.id.uuidString)")
        
        operatives.append(operative)
        // CRITICAL: Save immediately with retry logic
        _ = await saveDataWithRetry(description: "adding operative \(operative.name)")
        
        // Send password setup email to operative
        await sendOperativePasswordSetupEmail(operative: operative)
        
        // CRITICAL: Reload data immediately after save to ensure it's persisted
        print("🔥🔥🔥 DEBUG: Reloading data to verify operative was saved...")
        if let firebaseBackend = firebaseBackend,
           firebaseBackend.isAuthenticated,
           let organizationId = firebaseBackend.currentOrganization?.firestoreDocumentId {
            do {
                try? await Task.sleep(nanoseconds: 500_000_000) // 0.5 seconds
                let loadedOperatives = try await firebaseBackend.loadOperatives(organizationId: organizationId)
                print("🔥🔥🔥 DEBUG: Reloaded \(loadedOperatives.count) operatives from Firebase")
                
                // Check if our operative is in the loaded list
                let verified = loadedOperatives.contains { $0.id == operative.id }
                if verified {
                    print("🔥🔥🔥 DEBUG: ✅✅✅ VERIFIED: Operative \(operative.name) was saved and loaded successfully!")
                    self.operatives = loadedOperatives
                } else {
                    print("🔥🔥🔥 DEBUG: ⚠️⚠️⚠️ WARNING: Operative save verification failed!")
                }
            } catch {
                print("🔥🔥🔥 DEBUG: ❌ Could not verify operative save: \(error.localizedDescription)")
            }
        }
        NotificationCenter.default.post(name: .qualificationExpiryScheduleRefresh, object: nil)
        print("🔥🔥🔥 DEBUG: ========== ADD OPERATIVE END ==========")
    }
    
    func updateOperative(_ operative: Operative) async {
        if let index = operatives.firstIndex(where: { $0.id == operative.id }) {
            operatives[index] = operative
            // CRITICAL: Save immediately with retry logic
            _ = await saveDataWithRetry(description: "updating operative \(operative.name)")
            NotificationCenter.default.post(name: .qualificationExpiryScheduleRefresh, object: nil)
        }
    }
    
    func deleteOperative(_ operative: Operative, bookingStore: BookingStore?) async {
        let operativeName = operative.name
        let operativeId = operative.id
        
        // Delete all bookings for this operative
        if let bookingStore = bookingStore {
            let bookingsToDelete = bookingStore.bookings.filter { $0.operativeId == operativeId }
            print("🔥🔥🔥 DEBUG: Deleting \(bookingsToDelete.count) bookings for operative \(operativeName)")
            
            for booking in bookingsToDelete {
                await bookingStore.deleteBooking(booking)
            }
            
            if !bookingsToDelete.isEmpty {
                print("🔥🔥🔥 DEBUG: ✅ Deleted \(bookingsToDelete.count) bookings for operative \(operativeName)")
            }
        }
        
        // Remove from local array
        operatives.removeAll { $0.id == operative.id }
        
        // Update cache
        if let smartCache = smartCache {
            smartCache.cacheOperatives(operatives)
        }
        
        // Delete from Firebase if authenticated
        if let firebaseBackend = firebaseBackend,
           firebaseBackend.isAuthenticated,
           let organizationId = firebaseBackend.currentOrganization?.firestoreDocumentId {
            _ = await DataPersistenceManager.shared.saveWithRetry(
                operation: {
                    try await firebaseBackend.deleteOperative(operativeId: operative.id, organizationId: organizationId)
                },
                description: "deleting operative \(operativeName)",
                onSuccess: { _ in
                    print("🔥🔥🔥 DEBUG: ✅ Operative \(operativeName) deleted from Firebase")
                },
                onFailure: { error in
                    print("🔥🔥🔥 DEBUG: ❌ Failed to delete operative \(operativeName) from Firebase: \(error.localizedDescription)")
                }
            )
        }
        
        // CRITICAL: Save state immediately
        _ = await saveDataWithRetry(description: "saving state after deleting operative \(operativeName)")
        print("🔥🔥🔥 DEBUG: Deleted operative: \(operativeName)")
    }
    
    func toggleOperativeStatus(_ operative: Operative) async {
        if let index = operatives.firstIndex(where: { $0.id == operative.id }) {
            operatives[index].isActive.toggle()
            // CRITICAL: Save immediately with retry logic
            _ = await saveDataWithRetry(description: "toggling operative status for \(operative.name)")
        }
    }
    
    // MARK: - Manager Operations
    
    func addManager(_ manager: Manager) async {
        managers.append(manager)
        // CRITICAL: Save immediately with retry logic
        _ = await saveDataWithRetry(description: "adding manager \(manager.fullName)")
    }
    
    func updateManager(_ manager: Manager) async {
        if let index = managers.firstIndex(where: { $0.id == manager.id }) {
            managers[index] = manager
            // CRITICAL: Save immediately with retry logic
            _ = await saveDataWithRetry(description: "updating manager \(manager.fullName)")
        }
    }
    
    func deleteManager(_ manager: Manager) async {
        let managerName = manager.fullName
        managers.removeAll { $0.id == manager.id }
        
        // Delete from Firebase if authenticated
        if let firebaseBackend = firebaseBackend,
           firebaseBackend.isAuthenticated,
           let organizationId = firebaseBackend.currentOrganization?.firestoreDocumentId {
            _ = await DataPersistenceManager.shared.saveWithRetry(
                operation: {
                    try await firebaseBackend.deleteManager(manager, organizationId: organizationId)
                },
                description: "deleting manager \(managerName)",
                onSuccess: { _ in
                    print("🔥🔥🔥 DEBUG: ✅ Manager \(managerName) deleted from Firebase")
                },
                onFailure: { error in
                    print("🔥🔥🔥 DEBUG: ❌ Failed to delete manager \(managerName) from Firebase: \(error.localizedDescription)")
                }
            )
        }
        
        // CRITICAL: Save state immediately
        _ = await saveDataWithRetry(description: "saving state after deleting manager \(managerName)")
    }
    
    func toggleManagerStatus(_ manager: Manager) async {
        if let index = managers.firstIndex(where: { $0.id == manager.id }) {
            managers[index].isActive.toggle()
            // CRITICAL: Save immediately with retry logic
            _ = await saveDataWithRetry(description: "toggling manager status for \(manager.fullName)")
        }
    }
    
    // MARK: - Skills Operations
    
    func addOrganizationSkill(name: String, trade: String) async {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { return }
        let tradeOut = trade.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? OrganizationSkill.defaultTrade
            : trade.trimmingCharacters(in: .whitespacesAndNewlines)
        let (nk, tk) = OrganizationSkill.normalizedPair(name: trimmedName, trade: tradeOut)
        if organizationSkills.contains(where: {
            let p = OrganizationSkill.normalizedPair(name: $0.name, trade: $0.trade)
            return p.0 == nk && p.1 == tk
        }) {
            return
        }
        let newSkill = OrganizationSkill(name: trimmedName, trade: tradeOut)
        organizationSkills.append(newSkill)
        organizationSkills.sort {
            if $0.trade.localizedCaseInsensitiveCompare($1.trade) != .orderedSame {
                return $0.trade.localizedCaseInsensitiveCompare($1.trade) == .orderedAscending
            }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
        _ = await saveDataWithRetry(description: "adding organisation skill \(trimmedName)")
    }
    
    func removeOrganizationSkill(id: String) async {
        organizationSkills.removeAll { $0.id == id }
        _ = await saveDataWithRetry(description: "removing organisation skill \(id)")
    }

    func skillCatalogEntry(skillId: String) -> OrganizationSkill? {
        organizationSkills.first { $0.id == skillId }
    }
    
    // MARK: - Qualifications Operations
    
    func addQualification(_ qualification: Qualification) async {
        qualifications.append(qualification)
        _ = await saveDataWithRetry(description: "adding qualification \(qualification.name)")
    }
    
    func updateQualification(_ qualification: Qualification) async {
        if let index = qualifications.firstIndex(where: { $0.id == qualification.id }) {
            qualifications[index] = qualification
            _ = await saveDataWithRetry(description: "updating qualification \(qualification.name)")
        }
    }
    
    func deleteQualification(_ qualification: Qualification) async {
        qualifications.removeAll { $0.id == qualification.id }
        _ = await saveDataWithRetry(description: "deleting qualification \(qualification.name)")
    }
    
    // MARK: - Persistence
    
    /// Save data with retry logic - ensures data is never lost
    private func saveDataWithRetry(description: String = "saving operative data") async -> Result<Void, Error> {
        return await DataPersistenceManager.shared.saveWithRetry(
            operation: {
                try await self.saveDataInternal()
            },
            description: description,
            onSuccess: { _ in
                print("🔥🔥🔥 DEBUG: ✅ Data persistence successful: \(description)")
            },
            onFailure: { error in
                print("🔥🔥🔥 DEBUG: ❌❌❌ CRITICAL: Data persistence failed after retries: \(description)")
                print("🔥🔥🔥 DEBUG: Error: \(error.localizedDescription)")
            }
        )
    }
    
    private func saveDataInternal() async throws {
        guard let firebaseBackend = firebaseBackend,
              firebaseBackend.isAuthenticated,
              let organizationId = firebaseBackend.currentOrganization?.firestoreDocumentId else {
            print("🔥🔥🔥 DEBUG: ⚠️ Cannot save - Firebase not available or not authenticated")
            throw NSError(domain: "OperativeStore", code: -1, userInfo: [NSLocalizedDescriptionKey: "Firebase not available"])
        }
        
        // Save operatives
        for operative in operatives {
            try await firebaseBackend.saveOperative(operative, organizationId: organizationId)
        }
        
        // Save managers
        for manager in managers {
            try await firebaseBackend.saveManager(manager, organizationId: organizationId)
        }
        
        // Save skills
        try await firebaseBackend.saveSkills(organizationId: organizationId, skills: organizationSkills)
        
        // Save qualifications (saves entire collection)
        try await firebaseBackend.saveQualifications(organizationId: organizationId, qualifications: qualifications)
        
        // Update cache
        if let smartCache = smartCache {
            smartCache.cacheOperatives(operatives)
            smartCache.cacheManagers(managers)
            smartCache.cacheOrganizationSkills(organizationSkills)
            smartCache.cacheQualifications(qualifications)
        }
    }
    
    private func clearAllData() async {
        operatives.removeAll()
        managers.removeAll()
        organizationSkills.removeAll()
        qualifications.removeAll()
        
        if let smartCache = smartCache {
            smartCache.cacheOperatives([])
            smartCache.cacheManagers([])
            smartCache.cacheOrganizationSkills([])
            smartCache.cacheQualifications([])
        }
    }
    
    // MARK: - Email Operations
    
    private func sendOperativePasswordSetupEmail(operative: Operative) async {
        // This would send an email to the operative to set up their password
        // Implementation depends on your email service
        print("🔥🔥🔥 DEBUG: Would send password setup email to \(operative.email)")
    }
}
