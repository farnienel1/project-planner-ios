//
//  OperativeStore.swift
//  Project Planner
//
//  Created by Assistant on 29/09/2025.
//

import Foundation
import Combine
import FirebaseFirestore
import FirebaseAuth

@MainActor
class OperativeStore: ObservableObject {
    @Published var operatives: [Operative] = [] {
        // RULEBOOK 1.10.0 §17: the signed-in account's own booking ids (`bookingIdsForAccount`) for `bookingQueryPlan`.
        didSet {
            JobAccessContext.updateOperatives(operatives)
            RulebookCatalogueOperativeSnapshot.update(operatives)
            revision &+= 1
            scheduleCataloguePayOverlay()
        }
    }
    /// Bumped on every change to `operatives` or `managers`, so pickers can memoise what they build from them.
    private(set) var revision = 0
    /// RULEBOOK 1.27.0 §8: bumped by every rows change, so a catalogue pay overlay that finishes after newer rows
    /// arrived is dropped.
    private var cataloguePayOverlayGeneration = 0
    /// True while the overlay's own result is being published (it must not schedule another read).
    private var publishingCataloguePayOverlay = false
    
    @Published var managers: [Manager] = [] {
        // RULEBOOK 1.10.0: `canSeeJob` / `jobManagerUserIds` match a job's managers-list ids by this list's emails.
        didSet {
            JobAccessContext.updateManagers(allManagers)
            revision &+= 1
        }
    }
    /// Organisation skill catalogue is retired. Kept empty so legacy decode/lookups stay safe.
    @Published var organizationSkills: [OrganizationSkill] = []
    @Published var qualifications: [Qualification] = []
    @Published var isLoading: Bool = false
    /// The organisation whose operatives load last finished (read or failed). Warnings wait for it.
    private(set) var finishedLoadOrganizationId: String?
    @Published var errorMessage: String?
    @Published var isOffline: Bool = false
    
    private(set) var firebaseBackend: FirebaseBackend?
    private var smartCache: SmartCacheService?
    private var cancellables = Set<AnyCancellable>()
    private var pendingReloadAfterCurrentLoad = false
    private var loadGeneration = 0
    
    init() {
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
                guard let self else { return }
                guard self.firebaseBackend?.hasBootstrappedOrgDataLoad == true else {
                    print("🔥🔥🔥 DEBUG: OperativeStore skipping organizationDidLoad reload (pre-bootstrap)")
                    return
                }
                print("🔥🔥🔥 DEBUG: OperativeStore ignoring organizationDidLoad reload (bootstrap owns loads)")
            }
        }

        // RULEBOOK 1.27.0 §8: the catalogue operatives' pay overlay follows the `privatePay` switch and the roster
        // (which decides which rows are catalogue operatives and who the viewer is).
        NotificationCenter.default.addObserver(forName: .securitySwitchesDidChange, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.securitySwitchesChanged() }
        }
        NotificationCenter.default.addObserver(forName: .rulebookRosterDidChange, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.scheduleCataloguePayOverlay() }
        }

        // No `.syncOfflineChanges` observer: operatives and managers are Manage Users / online-only edits
        // (RULEBOOK §2), so nothing is queued to replay. The old whole-roster re-save re-created rows deleted
        // on another device.
    }
    
    deinit {
        NotificationCenter.default.removeObserver(self)
    }
    
    /// RULEBOOK 1.27.0 §8 (owner decision 7) `CanonicalBusinessEngine.catalogueOperativePaySubjects` +
    /// `payProfileReadPlan`: while `privatePay` is on, each catalogue `operatives` row whose pay the signed-in person may
    /// see (admins, managers with the Operatives toggle) is shown with its `payProfiles/{rowId}` laid over
    /// (`FirebaseBackend.overlayCatalogueOperativePayIfPrivate`). Re-run when the rows, the roster or the switch change.
    /// While the switch is off nothing is read and the rows stay as stored.
    private func scheduleCataloguePayOverlay() {
        guard !publishingCataloguePayOverlay else { return }
        cataloguePayOverlayGeneration &+= 1
        guard SecuritySwitchContext.privatePay, let firebaseBackend, !operatives.isEmpty else { return }
        let generation = cataloguePayOverlayGeneration
        let rows = operatives
        let roster = RulebookRosterSnapshot.users
        Task { @MainActor [weak self] in
            let overlaid = await firebaseBackend.overlayCatalogueOperativePayIfPrivate(rows, roster: roster)
            guard let self, generation == self.cataloguePayOverlayGeneration,
                  Self.payDiffers(rows, overlaid) else { return }
            self.publishingCataloguePayOverlay = true
            self.operatives = overlaid
            self.publishingCataloguePayOverlay = false
        }
    }

    /// `Operative ==` compares ids only, so the pay fields are compared here.
    private static func payDiffers(_ before: [Operative], _ after: [Operative]) -> Bool {
        guard before.count == after.count else { return true }
        return zip(before, after).contains { old, new in
            old.dayRate != new.dayRate || old.hourlyRate != new.hourlyRate || old.payBasis != new.payBasis
        }
    }

    /// A switch changed: on → lay the catalogue pay profiles over; off → read the rows again, so no overlaid value stays.
    /// The `privatePay` value last seen by `securitySwitchesChanged`.
    private var lastPrivatePay = SecuritySwitchContext.privatePay

    private func securitySwitchesChanged() {
        let privatePay = SecuritySwitchContext.privatePay
        defer { lastPrivatePay = privatePay }
        if privatePay {
            scheduleCataloguePayOverlay()
        } else {
            cataloguePayOverlayGeneration &+= 1
            // Reload only when private pay was just switched off (an enforcedReads flip alone changes nothing here).
            guard lastPrivatePay, firebaseBackend?.currentOrganization != nil else { return }
            loadData()
        }
    }

    func setCurrentUser(_ userId: String?) async {
        if userId == nil {
            await clearAllData()
        }
        loadData()
    }
    
    func setFirebaseBackend(_ firebaseBackend: FirebaseBackend) {
        guard LaunchStartupPolicy.shouldRewireStore(isSameInstance: self.firebaseBackend === firebaseBackend) else { return }
        print("🔥🔥🔥 DEBUG: ProjectStore.setFirebaseBackend called - Firebase backend connected!")
        self.firebaseBackend = firebaseBackend
    }
    
    func setSmartCache(_ smartCache: SmartCacheService) {
        self.smartCache = smartCache
        self.isOffline = !smartCache.isOnline
    }
    
    // MARK: - Computed Properties
    
    var allOperatives: [Operative] {
        // Filter out the legacy seed rows only ("Initial operative …", "Initial manager …", any "placeholder"), the
        // same names the load drops. A real person whose name merely contains "initial" is kept (platform guardrail 3:
        // never hide old data); before 13 Nov their bookings read "Unknown person" on iOS.
        let nonPlaceholderOperatives = operatives.filter { operative in
            let name = operative.name.lowercased()
            let email = operative.email.lowercased()
            return !name.contains("placeholder") && !email.contains("placeholder")
                && !name.contains("initial operative") && !name.contains("initial manager")
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
    
    /// An empty or shorter fetch must not delete people already on screen.
    private static func keepingKnownPeople(existing: [Operative], incoming: [Operative]) -> [Operative] {
        if incoming.isEmpty && !existing.isEmpty {
            print("🔥🔥🔥 DEBUG: OPERATIVES_KEPT \(existing.count) — refused an empty fetch")
            return existing
        }
        if incoming.count >= existing.count { return incoming }
        // Two stored ids that differ only in letter case are one in-app id (`Booking.internalOperativeId`); a
        // duplicate key must not trap.
        var byId = Dictionary(existing.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for person in incoming { byId[person.id] = person }
        let merged = Array(byId.values)
        print("🔥🔥🔥 DEBUG: OPERATIVES_KEPT merged \(merged.count) (fetch had \(incoming.count))")
        return merged
    }

    private static func keepingKnownManagers(existing: [Manager], incoming: [Manager]) -> [Manager] {
        if incoming.isEmpty && !existing.isEmpty {
            print("🔥🔥🔥 DEBUG: MANAGERS_KEPT \(existing.count) — refused an empty fetch")
            return existing
        }
        var byDocument: [String: Manager] = [:]
        for person in existing {
            byDocument[person.firestoreDocumentId] = person
        }
        for person in incoming {
            byDocument[person.firestoreDocumentId] = person
        }
        let incomingDocuments = Set(incoming.map(\.firestoreDocumentId))
        var byEmail: [String: Manager] = [:]
        for person in byDocument.values {
            let email = person.email.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
            let key = email.isEmpty ? "id:\(person.firestoreDocumentId)" : email
            if let current = byEmail[key] {
                let personIsIncoming = incomingDocuments.contains(person.firestoreDocumentId)
                let currentIsIncoming = incomingDocuments.contains(current.firestoreDocumentId)
                if personIsIncoming && !currentIsIncoming {
                    byEmail[key] = person
                }
            } else {
                byEmail[key] = person
            }
        }
        let merged = Array(byEmail.values)
        print("🔥🔥🔥 DEBUG: MANAGERS_KEPT merged \(merged.count) (fetch had \(incoming.count))")
        return merged
    }

    /// Returns true if the manager is a legacy/placeholder entry (e.g. "Initial manager placeholder system") and should not be shown in the app.
    private static func isPlaceholderManager(_ manager: Manager) -> Bool {
        let name = manager.fullName.lowercased()
        let email = manager.email.lowercased()
        return name.contains("placeholder") || email.contains("placeholder")
    }
    
    // MARK: - Data Loading

    /// Live `operatives` and `managers` (one listener each for the organisation), read through
    /// `operatives(fromDocuments:)` (`parseOperativeDocument`) and `managers(fromDocuments:)`
    /// (`parseManagerDocument`). A server snapshot replaces the list (a row deleted on web leaves here too); a
    /// cache snapshot never empties it. The warnings scan and qualification reminders run again on a change.
    func startLiveUpdates(organizationId: String) {
        guard let firebaseBackend else { return }
        firebaseBackend.listenOrganizationQuery(
            key: "operatives",
            organizationId: organizationId,
            query: { $0.collection("operatives") }
        ) { [weak self] rows, fromCache in
            guard let self else { return }
            let incoming = FirebaseBackend.operatives(fromDocuments: rows)
            guard let next = LiveSnapshotMerge.apply(
                existing: self.operatives,
                incoming: incoming,
                fromCache: fromCache,
                rowCount: LiveSnapshotMerge.readableRowCount(rows),
                collection: "operatives"
            ) else { return }
            // `Operative ==` compares ids only, so a server snapshot always publishes (it fires only on a change).
            if fromCache && next.count == self.operatives.count && next.map(\.id) == self.operatives.map(\.id) { return }
            self.operatives = next
            self.smartCache?.cacheOperatives(next)
            NotificationCenter.default.post(name: .liveWarningInputsDidChange, object: nil)
            NotificationCenter.default.post(name: .qualificationExpiryScheduleRefresh, object: nil)
        }
        firebaseBackend.listenOrganizationQuery(
            key: "managers",
            organizationId: organizationId,
            query: { $0.collection("managers") }
        ) { [weak self] rows, fromCache in
            guard let self else { return }
            let incoming = FirebaseBackend.managers(fromDocuments: rows)
            guard let next = LiveSnapshotMerge.apply(
                existing: self.managers,
                incoming: incoming,
                fromCache: fromCache,
                rowCount: LiveSnapshotMerge.readableRowCount(rows),
                collection: "managers"
            ),
                  next != self.managers else { return }
            self.managers = next
            self.smartCache?.cacheManagers(next)
            NotificationCenter.default.post(name: .liveWarningInputsDidChange, object: nil)
        }
        // RULEBOOK 1.9.0 `LIVE_COLLECTIONS` `qualifications`: the library is live too. A server snapshot replaces the
        // list; an empty or cache snapshot never empties it (the starter library seeds on the one-off load).
        firebaseBackend.listenOrganizationQuery(
            key: "qualifications",
            organizationId: organizationId,
            query: { $0.collection("qualifications") }
        ) { [weak self] rows, fromCache in
            guard let self else { return }
            let incoming = FirebaseBackend.qualifications(fromDocuments: rows)
            guard !incoming.isEmpty,
                  let next = LiveSnapshotMerge.apply(existing: self.qualifications, incoming: incoming, fromCache: fromCache) else { return }
            // `Qualification ==` compares ids only; a cache snapshot with the same rows changes nothing.
            if fromCache && next.map(\.id) == self.qualifications.map(\.id) { return }
            self.qualifications = next
            self.smartCache?.cacheQualifications(next)
            NotificationCenter.default.post(name: .qualificationExpiryScheduleRefresh, object: nil)
        }
    }

    func discardInMemoryForOrganizationSwitch() {
        loadGeneration += 1
        pendingReloadAfterCurrentLoad = false
        isLoading = false
        finishedLoadOrganizationId = nil
        operatives = []
        managers = []
        organizationSkills = []
        qualifications = []
        errorMessage = nil
    }

    func loadData() {
        if isLoading {
            if firebaseBackend?.isBootstrappingOrgDataLoad == true {
                print("🔥🔥🔥 DEBUG: OperativeStore loadData ignored (already loading during bootstrap); not queueing follow-up")
                return
            }
            pendingReloadAfterCurrentLoad = true
            print("🔥🔥🔥 DEBUG: OperativeStore loadData ignored (already loading); queued one follow-up reload")
            return
        }
        isLoading = true
        errorMessage = nil
        pendingReloadAfterCurrentLoad = false
        loadGeneration += 1
        let generation = loadGeneration
        let loadingOrganizationId = firebaseBackend?.currentOrganization?.firestoreDocumentId
        
        Task {
            // Add timeout to prevent infinite loading
            let timeoutTask = Task { @MainActor in
                try? await Task.sleep(nanoseconds: 18_000_000_000)
                if isLoading && loadGeneration == generation {
                    print("🔥🔥🔥 DEBUG: ⚠️ OperativeStore load timeout - forcing completion")
                    isLoading = false
                    errorMessage = "Loading timed out. Please try 'Force Reload Data' in Settings."
                }
            }
            
            defer {
                timeoutTask.cancel()
                if loadGeneration == generation {
                    isLoading = false
                    finishedLoadOrganizationId = loadingOrganizationId
                    if pendingReloadAfterCurrentLoad {
                        pendingReloadAfterCurrentLoad = false
                        if firebaseBackend?.hasBootstrappedOrgDataLoad == true,
                           firebaseBackend?.isBootstrappingOrgDataLoad != true {
                            Task { @MainActor in
                                try? await Task.sleep(nanoseconds: 1_200_000_000)
                                self.loadData()
                            }
                        }
                    }
                }
            }
            
            do {
                if operatives.isEmpty, let smartCache {
                    let cachedOperatives = smartCache.getCachedOperatives()
                    let cachedManagers = smartCache.getCachedManagers().filter { !Self.isPlaceholderManager($0) }
                    if !cachedOperatives.isEmpty {
                        operatives = cachedOperatives
                        print("🔥🔥🔥 DEBUG: OPERATIVES_RESTORED \(cachedOperatives.count) from cache before fetch")
                    }
                    if managers.isEmpty, !cachedManagers.isEmpty {
                        managers = cachedManagers
                    }
                }
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
                        guard loadGeneration == generation else { return }
                        let keptManagers = Self.keepingKnownManagers(existing: self.managers, incoming: realManagers)
                        self.managers = keptManagers
                        if let smartCache = smartCache {
                            smartCache.cacheManagers(keptManagers)
                        }
                        
                        // Load qualifications from Firebase
                        let existingQualifications = self.qualifications
                        let firebaseQualifications = try await withTimeout(seconds: 5) {
                            try await firebaseBackend.loadQualifications(organizationId: organizationId)
                        }
                        if firebaseQualifications.isEmpty {
                            let recovered = qualificationsRecoveredFromAssignments(firebaseOperatives)
                            if !existingQualifications.isEmpty {
                                self.qualifications = existingQualifications
                            } else if !recovered.isEmpty {
                                self.qualifications = recovered
                            } else {
                                self.qualifications = []
                            }
                            if let smartCache = smartCache, !self.qualifications.isEmpty {
                                smartCache.cacheQualifications(self.qualifications)
                            }
                        } else {
                            self.qualifications = firebaseQualifications
                            if let smartCache = smartCache {
                                smartCache.cacheQualifications(firebaseQualifications)
                            }
                        }

                        // Skills catalogue is retired — do not load or rewrite it.
                        self.organizationSkills = []
                        let realOperatives = firebaseOperatives.filter { operative in
                            let name = operative.name.lowercased()
                            let email = operative.email.lowercased()
                            return !name.contains("placeholder") && !email.contains("placeholder") && !name.contains("initial operative")
                        }
                        guard loadGeneration == generation else { return }
                        self.operatives = Self.keepingKnownPeople(existing: self.operatives, incoming: realOperatives)
                        if let smartCache = smartCache {
                            smartCache.cacheOrganizationSkills([])
                            smartCache.cacheOperatives(self.operatives)
                        }
                        
                        print("🔥🔥🔥 DEBUG: ✅ Loaded \(self.operatives.count) operatives, \(self.managers.count) managers from Firebase (filtered from \(firebaseOperatives.count) docs)")
                        isOffline = false
                    } else {
                        // Organization still nil after recovery attempt - use cached data
                        print("🔥🔥🔥 DEBUG: Organization still nil after recovery, using cached data")
                        if let smartCache = smartCache {
                            let cachedOperatives = smartCache.getCachedOperatives()
                            let cachedManagers = smartCache.getCachedManagers()
                            managers = cachedManagers.filter { !Self.isPlaceholderManager($0) }
                            organizationSkills = []
                            operatives = cachedOperatives
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
                        organizationSkills = []
                        operatives = cachedOperatives
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
                if firebaseBackend?.suppressStaleOrganizationCache == true {
                    self.operatives = []
                    self.managers = []
                    self.qualifications = []
                    self.organizationSkills = []
                } else if let smartCache = smartCache {
                    let cachedOperatives = smartCache.getCachedOperatives()
                    let cachedManagers = smartCache.getCachedManagers().filter { !Self.isPlaceholderManager($0) }
                    let cachedQualifications = smartCache.getCachedQualifications()
                    if !cachedManagers.isEmpty { self.managers = cachedManagers }
                    self.organizationSkills = []
                    if !cachedQualifications.isEmpty { self.qualifications = cachedQualifications }
                    if !cachedOperatives.isEmpty {
                        self.operatives = cachedOperatives
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
            
            defer { group.cancelAll() }
            guard let result = try await group.next() else {
                throw NSError(domain: "TimeoutError", code: -1, userInfo: [NSLocalizedDescriptionKey: "Operation finished without a result"])
            }
            return result
        }
    }

    // MARK: - Operative Operations
    
    func addOperative(_ operative: Operative) async {
        print("🔥🔥🔥 DEBUG: ========== ADD OPERATIVE START ==========")
        print("🔥🔥🔥 DEBUG: addOperative called with operative: \(operative.name)")
        print("🔥🔥🔥 DEBUG: Operative ID: \(operative.id.uuidString)")
        
        operatives.append(operative)
        // A new row: created whole. Nothing else on the roster is written.
        _ = await saveSingleOperativeWithRetry(operative, previous: nil, mode: .create, description: "adding operative \(operative.name)")
        smartCache?.cacheOperatives(operatives)
        
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
    
    /// Qualification save already wrote Firestore. Keep this operative in memory without a second full rewrite.
    func replaceOperativeInMemory(_ operative: Operative) {
        if let index = operatives.firstIndex(where: { $0.id == operative.id }) {
            operatives[index] = operative
        } else {
            operatives.append(operative)
        }
        smartCache?.cacheOperatives(operatives)
        NotificationCenter.default.post(name: .qualificationExpiryScheduleRefresh, object: nil)
    }

    func updateOperative(_ operative: Operative) async {
        if let index = operatives.firstIndex(where: { $0.id == operative.id }) {
            let previous = operatives[index]
            operatives[index] = operative
            // Save ONLY this operative, and only the fields that changed from the copy it was edited from (RULEBOOK §1).
            _ = await saveSingleOperativeWithRetry(operative, previous: previous, mode: .update, description: "updating operative \(operative.name)")
            if let smartCache {
                smartCache.cacheOperatives(operatives)
            }
            NotificationCenter.default.post(name: .qualificationExpiryScheduleRefresh, object: nil)
        }
    }
    
    func deleteOperative(_ operative: Operative, bookingStore: BookingStore?) async {
        let operativeName = operative.name
        let operativeId = operative.id
        
        // This operative's bookings from today on (`bookingsToRemoveOnOperativeDelete`). Past days stay as history.
        if let bookingStore = bookingStore {
            let bookingsToDelete = bookingStore.bookingsToRemoveOnPersonDelete(personIds: [operativeId])
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
                    try await firebaseBackend.deleteOperative(documentId: operative.documentId, organizationId: organizationId)
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
        
        // The delete above is the only write; the rest of the roster is not re-saved.
        print("🔥🔥🔥 DEBUG: Deleted operative: \(operativeName)")
    }
    
    func toggleOperativeStatus(_ operative: Operative) async {
        if let index = operatives.firstIndex(where: { $0.id == operative.id }) {
            let previous = operatives[index]
            operatives[index].isActive.toggle()
            // Writes only `isActive` (+ metadata) on this row.
            _ = await saveSingleOperativeWithRetry(operatives[index], previous: previous, mode: .update, description: "toggling operative status for \(operative.name)")
            smartCache?.cacheOperatives(operatives)
        }
    }
    
    // MARK: - Manager Operations
    
    func addManager(_ manager: Manager) async {
        managers.append(manager)
        // A new row: created whole. Nothing else on the roster is written.
        _ = await saveSingleManagerWithRetry(manager, previous: nil, mode: .create, description: "adding manager \(manager.fullName)")
        smartCache?.cacheManagers(managers)
    }
    
    func updateManager(_ manager: Manager) async {
        if let index = managers.firstIndex(where: { $0.id == manager.id }) {
            let previous = managers[index]
            managers[index] = manager
            // Only the fields that changed on this row (RULEBOOK §1).
            _ = await saveSingleManagerWithRetry(manager, previous: previous, mode: .update, description: "updating manager \(manager.fullName)")
            smartCache?.cacheManagers(managers)
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
        
        smartCache?.cacheManagers(managers)
    }
    
    func toggleManagerStatus(_ manager: Manager) async {
        if let index = managers.firstIndex(where: { $0.id == manager.id }) {
            let previous = managers[index]
            managers[index].isActive.toggle()
            _ = await saveSingleManagerWithRetry(managers[index], previous: previous, mode: .update, description: "toggling manager status for \(manager.fullName)")
            smartCache?.cacheManagers(managers)
        }
    }
    
    // MARK: - Skills (retired)

    func skillCatalogEntry(skillId: String) -> OrganizationSkill? {
        organizationSkills.first { $0.id == skillId }
    }

    // MARK: - Qualifications Operations
    //
    // Organisation templates live in `organizations/{orgId}/qualifications` and are
    // shared org data. Only explicit add/update/delete below mutate that catalogue.
    // Turning a manager's `permissions.qualifications` off must never call these
    // methods and never clear staff My Qualifications assignments.
    
    func addQualification(_ qualification: Qualification) async {
        let normalized = qualification.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else { return }
        if qualifications.contains(where: {
            $0.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == normalized
        }) {
            print("🔥🔥🔥 DEBUG: Skipping duplicate qualification name: \(qualification.name)")
            return
        }
        qualifications.append(qualification)
        await persistQualificationCatalogueChange(qualification, deleting: false)
    }
    
    func updateQualification(_ qualification: Qualification) async {
        if let index = qualifications.firstIndex(where: { $0.id == qualification.id }) {
            qualifications[index] = qualification
            await persistQualificationCatalogueChange(qualification, deleting: false)
        }
    }
    
    func deleteQualification(_ qualification: Qualification) async {
        // Explicit org-catalogue delete only. Call sites must be Organisation Qualifications
        // UI actions — never permission toggles, and never `saveQualifications` with an empty
        // list used as a side effect of turning `permissions.qualifications` off.
        qualifications.removeAll { $0.id == qualification.id }
        await persistQualificationCatalogueChange(qualification, deleting: true)
    }

    private func persistQualificationCatalogueChange(_ qualification: Qualification, deleting: Bool) async {
        guard let firebaseBackend,
              firebaseBackend.isAuthenticated,
              let organizationId = firebaseBackend.currentOrganization?.firestoreDocumentId else { return }
        do {
            if deleting {
                try await firebaseBackend.deleteQualification(qualification.id, organizationId: organizationId)
            } else {
                try await firebaseBackend.saveQualification(qualification, organizationId: organizationId)
            }
            smartCache?.cacheQualifications(qualifications)
        } catch {
            print("🔥🔥🔥 DEBUG: Qualification catalogue save failed: \(error.localizedDescription)")
        }
    }
    
    // MARK: - Persistence
    
    /// Saves ONE operative row. `mode` says whether the user just made it (`.create`) or edited a stored row
    /// (`.update`, only the fields changed from `previous`). An edit of a row deleted on another device is never
    /// re-created: the local row is dropped and the person is told (`RecordDeletedElsewhereError`).
    private func saveSingleOperativeWithRetry(_ operative: Operative, previous: Operative?, mode: RecordSaveMode, description: String) async -> Result<Void, Error> {
        let result = await DataPersistenceManager.shared.saveWithRetry(
            operation: {
                guard let firebaseBackend = self.firebaseBackend,
                      firebaseBackend.isAuthenticated,
                      let organizationId = firebaseBackend.currentOrganization?.firestoreDocumentId else {
                    throw NSError(domain: "OperativeStore", code: -1, userInfo: [NSLocalizedDescriptionKey: "Firebase not available"])
                }
                try await firebaseBackend.saveOperative(operative, organizationId: organizationId, mode: mode, previous: previous)
            },
            description: description,
            onSuccess: { _ in
                print("🔥🔥🔥 DEBUG: ✅ Single operative persistence successful: \(description)")
            },
            onFailure: { error in
                print("🔥🔥🔥 DEBUG: ❌ Single operative persistence failed: \(description) — \(error.localizedDescription)")
            }
        )
        if case .failure(let error) = result, error is RecordDeletedElsewhereError {
            operatives.removeAll { $0.id == operative.id }
            smartCache?.cacheOperatives(operatives)
            errorMessage = RecordDeletedElsewhereError.message
        }
        return result
    }
    
    private func saveSingleManagerWithRetry(_ manager: Manager, previous: Manager?, mode: RecordSaveMode, description: String) async -> Result<Void, Error> {
        let result = await DataPersistenceManager.shared.saveWithRetry(
            operation: {
                guard let firebaseBackend = self.firebaseBackend,
                      firebaseBackend.isAuthenticated,
                      let organizationId = firebaseBackend.currentOrganization?.firestoreDocumentId else {
                    throw NSError(domain: "OperativeStore", code: -1, userInfo: [NSLocalizedDescriptionKey: "Firebase not available"])
                }
                try await firebaseBackend.saveManager(manager, organizationId: organizationId, mode: mode, previous: previous)
            },
            description: description,
            onSuccess: { _ in
                print("🔥🔥🔥 DEBUG: ✅ Single manager persistence successful: \(description)")
            },
            onFailure: { error in
                print("🔥🔥🔥 DEBUG: ❌ Single manager persistence failed: \(description) — \(error.localizedDescription)")
            }
        )
        if case .failure(let error) = result, error is RecordDeletedElsewhereError {
            managers.removeAll { $0.id == manager.id }
            smartCache?.cacheManagers(managers)
            errorMessage = RecordDeletedElsewhereError.message
        }
        return result
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

    private func qualificationsRecoveredFromAssignments(_ operatives: [Operative]) -> [Qualification] {
        var byName: [String: Qualification] = [:]
        for operative in operatives {
            for row in operative.qualifications {
                let name = row.name.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !name.isEmpty else { continue }
                let key = name.lowercased()
                if byName[key] == nil {
                    byName[key] = Qualification(
                        id: row.id,
                        name: name,
                        hasEndDate: false,
                        createdAt: row.createdAt,
                        updatedAt: Date()
                    )
                }
            }
        }
        return byName.values.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}

// MARK: - Ghost operatives (RULEBOOK 1.34.0 §11)

extension OperativeStore {
    /// The `operatives` catalogue row of a person, for display and the row's own fields: the row on their email; for a
    /// person with no email (a ghost), the row kept under the ghost's own id — a converted ghost keeps its row with
    /// `linkedUserId` = that id and its email cleared — so that row is the ghost, never a separate person. An empty
    /// email never matches another row.
    func operativeRow(for user: AppUser) -> Operative? {
        Self.operativeRow(for: user, in: allOperatives)
    }

    /// `operativeRow(for:)` over a given list (the store's rows, or test rows). Shared by every lookup that must find
    /// the person's own row — pay mirror, rate history `operativeId`, name sync — so an empty email never picks the
    /// first no-email row in the list.
    static func operativeRow(for user: AppUser, in rows: [Operative]) -> Operative? {
        // `personDedupeKey` (RULEBOOK 1.34.0): the email, else `id:` + the id — so a person with an email matches the
        // row on that email, and a ghost the row kept under its own id (email cleared), never another no-email row.
        let key = GhostRulebook.dedupeKey(id: user.id, email: user.email)
        guard !key.isEmpty else { return nil }
        if let row = rows.first(where: { GhostRulebook.dedupeKey(id: $0.documentId, email: $0.email) == key }) {
            return row
        }
        guard user.email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return rows.first { $0.linkedUserId?.caseInsensitiveCompare(user.id) == .orderedSame }
    }

}
