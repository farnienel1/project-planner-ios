//
//  ProjectStore.swift
//  Project Planner
//
//  Created by Assistant on 29/09/2025.
//

import Foundation
import Combine
import FirebaseAuth

@MainActor
class ProjectStore: ObservableObject {
    @Published var projects: [Project] = []
    @Published var clients: [Client] = []
    @Published var jobTypes: Set<String> = []
    @Published var isLoading: Bool = false
    @Published var errorMessage: String?
    @Published var isOffline: Bool = false
    
    private let persistenceService: PersistenceService
    private var firebaseBackend: FirebaseBackend?
    private var notificationService: NotificationService?
    private var smartCache: SmartCacheService?
    private var cancellables = Set<AnyCancellable>()
    private var didAttemptOrgAutoSwitch = false

    private func isPermissionDeniedError(_ error: Error?) -> Bool {
        guard let nsError = error as NSError? else { return false }
        return nsError.domain == "FIRFirestoreErrorDomain" && nsError.code == 7
    }
    
    init(persistenceService: PersistenceService? = nil) {
        self.persistenceService = persistenceService ?? PersistenceService()
        
        // Listen for user sign in/out notifications
        NotificationCenter.default.addObserver(
            forName: .userDidSignIn,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            if let userId = notification.object as? String {
                Task { @MainActor [weak self] in
                    self?.setCurrentUser(userId)
                }
            }
        }
        
        NotificationCenter.default.addObserver(
            forName: .userDidSignOut,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.setCurrentUser(nil)
            }
        }
        
        NotificationCenter.default.addObserver(
            forName: .organizationDidLoad,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                print("🔥🔥🔥 DEBUG: ProjectStore received organizationDidLoad notification - reloading data")
                self?.loadData()
                // After loading, sync any local data to Firebase
                if let self = self, (!self.projects.isEmpty || !self.clients.isEmpty) {
                    print("🔥🔥🔥 DEBUG: Syncing local projects/clients to Firebase after organization load")
                    _ = await self.saveDataWithRetry(description: "syncing local data to Firebase after organization load")
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
                print("🔥🔥🔥 DEBUG: ProjectStore received syncOfflineChanges notification - syncing all data to Firebase")
                if let self = self, (!self.projects.isEmpty || !self.clients.isEmpty) {
                    _ = await self.saveDataWithRetry(description: "syncing offline changes to Firebase")
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
        print("🔥🔥🔥 DEBUG: ProjectStore.setFirebaseBackend called - Firebase backend connected!")
        self.firebaseBackend = firebaseBackend
    }
    
    func setNotificationService(_ service: NotificationService) {
        self.notificationService = service
    }
    
    func setSmartCache(_ smartCache: SmartCacheService) {
        self.smartCache = smartCache
        self.isOffline = !smartCache.isOnline
    }
    
    private func creatorDisplayNameForNotifications() -> String {
        guard let fb = firebaseBackend else { return "Someone" }
        if let name = fb.currentUser?.displayName?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
            return name
        }
        if let email = fb.currentUser?.email, !email.isEmpty { return email }
        return "Someone"
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
                // Try to load from Firebase first if authenticated
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
                                print("🔥🔥🔥 DEBUG: ⚠️ Could not recover organization, will try loading from local storage")
                            }
                        }
                    }
                    
                    // Now try to load with organization (may still be nil if recovery failed)
                    if let organizationId = firebaseBackend.currentOrganization?.firestoreDocumentId {
                        print("🔥🔥🔥 DEBUG: ========== LOADING DATA FOR ORGANIZATION: \(organizationId) ==========")
                        print("🔥🔥🔥 DEBUG: Organization name: \(firebaseBackend.currentOrganization?.name ?? "N/A")")
                        
                        // Load projects/small works from Firebase, but never wipe existing in-memory data on failed reads.
                        let existingProjectsBeforeLoad = self.projects
                        var firebaseProjects: [Project] = []
                        var projectsLoaded = false
                        var projectsError: Error?
                        do {
                            firebaseProjects = try await withTimeout(seconds: 10) {
                                try await firebaseBackend.loadProjects(organizationId: organizationId)
                            }
                            firebaseProjects = firebaseProjects.filter { $0.jobType != .smallWorks }
                            projectsLoaded = true
                            print("🔥🔥🔥 DEBUG: ✅ Successfully loaded \(firebaseProjects.count) projects from Firebase (excluding small works)")
                        } catch {
                            projectsError = error
                            print("🔥🔥🔥 DEBUG: ❌❌❌ ERROR loading projects: \(error.localizedDescription)")
                        }

                        var firebaseSmallWorks: [Project] = []
                        var smallWorksLoaded = false
                        var smallWorksError: Error?
                        do {
                            firebaseSmallWorks = try await withTimeout(seconds: 10) {
                                try await firebaseBackend.loadSmallWorks(organizationId: organizationId)
                            }
                            smallWorksLoaded = true
                            print("🔥🔥🔥 DEBUG: ✅ Successfully loaded \(firebaseSmallWorks.count) small works from Firebase")
                        } catch {
                            smallWorksError = error
                            print("🔥🔥🔥 DEBUG: ❌❌❌ ERROR loading small works: \(error.localizedDescription)")
                        }

                        let allItems = firebaseProjects + firebaseSmallWorks
                        if projectsLoaded || smallWorksLoaded {
                            if allItems.isEmpty && !existingProjectsBeforeLoad.isEmpty {
                                self.projects = existingProjectsBeforeLoad
                                print("🔥🔥🔥 DEBUG: Remote returned 0 projects/small works, preserving \(existingProjectsBeforeLoad.count) existing items")
                            } else {
                                self.projects = allItems
                            }
                            print("🔥🔥🔥 DEBUG: ✅ Total loaded: \(firebaseProjects.count) projects + \(firebaseSmallWorks.count) small works")
                        } else {
                            self.projects = existingProjectsBeforeLoad
                            print("🔥🔥🔥 DEBUG: Both project and small works loads failed; preserving \(existingProjectsBeforeLoad.count) in-memory items")
                        }
                        
                        if self.projects.isEmpty {
                            print("🔥🔥🔥 DEBUG: ⚠️⚠️⚠️ WARNING: No projects or small works loaded! This could mean:")
                            print("🔥🔥🔥 DEBUG: 1. No data exists in Firebase for this organization")
                            print("🔥🔥🔥 DEBUG: 2. Data exists but is being filtered out due to format issues")
                            print("🔥🔥🔥 DEBUG: 3. Permission issues preventing read access")
                        }
                        
                        // Load clients separately from Firebase (not from projects)
                        let existingClientsBeforeLoad = self.clients
                        do {
                            let firebaseClients = try await withTimeout(seconds: 10) {
                                try await firebaseBackend.loadClients(organizationId: organizationId)
                            }
                            if firebaseClients.isEmpty {
                                // Avoid wiping in-memory clients on transient empty reads.
                                let inferred = extractClientsFromProjects(allItems)
                                if !existingClientsBeforeLoad.isEmpty {
                                    self.clients = existingClientsBeforeLoad
                                    print("🔥🔥🔥 DEBUG: Firebase returned 0 clients, preserving \(existingClientsBeforeLoad.count) existing in-memory clients")
                                } else {
                                    self.clients = inferred
                                    print("🔥🔥🔥 DEBUG: Firebase returned 0 clients, using \(inferred.count) inferred clients from projects/small works")
                                }
                            } else {
                                self.clients = firebaseClients
                                print("🔥🔥🔥 DEBUG: Loaded \(firebaseClients.count) clients from Firebase clients collection")
                            }
                        } catch {
                            print("🔥🔥🔥 DEBUG: Error loading clients from Firebase, extracting from projects: \(error.localizedDescription)")
                            // Fallback: extract clients from all loaded work items
                            let inferred = extractClientsFromProjects(allItems)
                            self.clients = inferred.isEmpty ? existingClientsBeforeLoad : inferred
                        }
                        
                        // Load job types from Firebase
                        do {
                            let firebaseJobTypes = try await withTimeout(seconds: 5) {
                                try await firebaseBackend.loadJobTypes(organizationId: organizationId)
                            }
                            self.jobTypes = firebaseJobTypes
                            print("🔥🔥🔥 DEBUG: Loaded \(firebaseJobTypes.count) job types from Firebase")
                        } catch {
                            print("🔥🔥🔥 DEBUG: Error loading job types from Firebase: \(error.localizedDescription)")
                        }
                        
                        let permissionDeniedWhileLoadingWork =
                            isPermissionDeniedError(projectsError) || isPermissionDeniedError(smallWorksError)
                        let shouldTryOrgAutoSwitch =
                            !didAttemptOrgAutoSwitch &&
                            (allItems.isEmpty || permissionDeniedWhileLoadingWork)

                        if shouldTryOrgAutoSwitch,
                           let userId = firebaseBackend.currentUser?.uid {
                            print("🔥🔥🔥 DEBUG: Work data missing/denied in current org — attempting auto-switch to org with work data")
                            let switched = await firebaseBackend.autoSwitchToOrganizationWithWorkData(
                                userId: userId,
                                currentOrganizationId: organizationId
                            )
                            if switched {
                                didAttemptOrgAutoSwitch = true
                                print("🔥🔥🔥 DEBUG: ✅ Org auto-switch applied. Reloading project data now...")
                                self.loadData()
                                return
                            } else {
                                print("🔥🔥🔥 DEBUG: Org auto-switch found no better org")
                            }
                        }

                        print("🔥🔥🔥 DEBUG: Summary — store now \(self.projects.count) projects, \(self.clients.count) clients (Firebase batches ok: projects=\(projectsLoaded), smallWorks=\(smallWorksLoaded); raw doc counts \(firebaseProjects.count)+\(firebaseSmallWorks.count))")
                    } else {
                        // Organization still nil after recovery attempt - try finding a better org before local fallback.
                        if !didAttemptOrgAutoSwitch, let userId = firebaseBackend.currentUser?.uid {
                            print("🔥🔥🔥 DEBUG: Organization still nil — attempting org auto-switch recovery")
                            let switched = await firebaseBackend.autoSwitchToOrganizationWithWorkData(
                                userId: userId,
                                currentOrganizationId: ""
                            )
                            if switched {
                                didAttemptOrgAutoSwitch = true
                                print("🔥🔥🔥 DEBUG: ✅ Org auto-switch recovery succeeded. Reloading data now...")
                                self.loadData()
                                return
                            }
                        }

                        // Local fallback
                        print("🔥🔥🔥 DEBUG: Organization still nil after recovery, loading from local storage")
                        let (projects, clients) = try await persistenceService.loadProjectData()
                        self.projects = projects
                        self.clients = clients
                        print("🔥🔥🔥 DEBUG: Loaded \(projects.count) projects and \(clients.count) clients from local storage")
                    }
                    
                } else {
                    // Fallback to local storage
                    print("🔥🔥🔥 DEBUG: Loading data from local storage (Firebase not available or not authenticated)")
                    do {
                        let (projects, clients) = try await persistenceService.loadProjectData()
                        self.projects = projects
                        self.clients = clients
                        print("🔥🔥🔥 DEBUG: Loaded \(projects.count) projects and \(clients.count) clients from local storage")
                        
                        // If we have local data but Firebase is available, try to sync it
                        if let firebaseBackend = firebaseBackend,
                           !firebaseBackend.isAuthenticated,
                           !projects.isEmpty {
                            print("🔥🔥🔥 DEBUG: Found local projects but Firebase not authenticated - projects will be available locally")
                        }
                    } catch {
                        print("🔥🔥🔥 DEBUG: Error loading from local storage: \(error.localizedDescription)")
                        // Don't throw - just use empty arrays
                        self.projects = []
                        self.clients = []
                    }
                }
                
                print("🔥🔥🔥 DEBUG: Finished loading - Total projects: \(self.projects.count), Total clients: \(self.clients.count)")
                
            } catch {
                self.errorMessage = error.localizedDescription
                print("🔥🔥🔥 DEBUG: Error loading data: \(error.localizedDescription)")
                print("🔥🔥🔥 DEBUG: Stack trace: \(Thread.callStackSymbols.prefix(5).joined(separator: "\n"))")
                // Don't clear existing data on error - keep what we have
                if self.projects.isEmpty && self.clients.isEmpty {
                    print("🔥🔥🔥 DEBUG: No existing data, starting with empty arrays")
                } else {
                    print("🔥🔥🔥 DEBUG: Keeping existing data: \(self.projects.count) projects, \(self.clients.count) clients")
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
    
    private func loadSampleData() {
        let sampleClients = Client.defaultClients
        let sampleProjects = createSampleProjects(with: sampleClients)
        
        self.projects = sampleProjects
        self.clients = sampleClients
    }
    
    private func loadDemoData() -> [Project]? {
        let userDefaults = UserDefaults.standard
        guard let data = userDefaults.data(forKey: "demo@projectplanner.com_projects"),
              let demoProjects = try? JSONDecoder().decode([Project].self, from: data) else {
            return nil
        }
        return demoProjects
    }
    
    private func extractClientsFromProjects(_ projects: [Project]) -> [Client] {
        let uniqueClients = Set(projects.map { $0.client })
        return Array(uniqueClients)
    }
    
    private func createSampleProjects(with clients: [Client]) -> [Project] {
        let date = Date()
        let nextWeek = Calendar.current.date(byAdding: .day, value: 7, to: date) ?? date
        
        var components = DateComponents()
        components.day = 31
        components.month = 10
        components.year = Calendar.current.component(.year, from: Date())
        let oct31 = Calendar.current.date(from: components) ?? nextWeek
        
        components.month = 3
        components.day = 3
        components.year = Calendar.current.component(.year, from: Date()) + 1
        let march3 = Calendar.current.date(from: components) ?? nextWeek
        
        return [
            Project(
                jobNumber: "C646",
                siteName: "Lancelot Place",
                siteAddress: "8 Lancelot Place, SW7 1DR, London",
                client: clients.first { $0.name == "RED Construction" } ?? clients[0],
                startDate: date,
                endDate: oct31,
                jobType: .catA,
                manager: .na,
                isLive: true
            ),
            Project(
                jobNumber: "C709",
                siteName: "Tower Hotel",
                siteAddress: "Tower Hotel, St Katherine's Way, E1W 1LD",
                client: clients.first { $0.name == "RED Construction" } ?? clients[0],
                startDate: Calendar.current.date(byAdding: .month, value: -2, to: date) ?? date,
                endDate: march3,
                jobType: .catA,
                manager: .na,
                isLive: true
            ),
            Project(
                jobNumber: "C842",
                siteName: "Ferrari Garage Temps",
                siteAddress: "133-135 Old Brompton Road, SW7 3RP",
                client: clients.first { $0.name == "Pryer Construction" } ?? clients[1],
                startDate: Calendar.current.date(byAdding: .day, value: -5, to: date) ?? date,
                endDate: Calendar.current.date(byAdding: .day, value: 3, to: date) ?? nextWeek,
                jobType: .smallWorks,
                manager: .na,
                isLive: true
            )
        ]
    }
    
    // MARK: - Project Operations
    
    func addProject(_ project: Project) async throws {
        print("🔥🔥🔥 DEBUG: ========== ADD PROJECT START ==========")
        print("🔥🔥🔥 DEBUG: addProject called with project: \(project.siteName)")
        print("🔥🔥🔥 DEBUG: Project ID: \(project.id.uuidString)")
        print("🔥🔥🔥 DEBUG: Current projects count before adding: \(projects.count)")
        
        // Add to local array first
        projects.append(project)
        print("🔥🔥🔥 DEBUG: Current projects count after adding: \(projects.count)")
        
        // CRITICAL: Save immediately with retry logic and check result
        let saveResult = await saveDataWithRetry(description: "adding project \(project.siteName)")
        
        // Check if save was successful
        switch saveResult {
        case .success:
            print("🔥🔥🔥 DEBUG: ✅ Save operation completed successfully")
            if firebaseBackend?.isAuthenticated == true,
               firebaseBackend?.currentOrganization != nil {
                await notificationService?.notifyProjectCreated(
                    projectId: project.id,
                    siteName: project.siteName,
                    jobNumber: project.jobNumber,
                    createdBy: creatorDisplayNameForNotifications()
                )
            }
        case .failure(let error):
            print("🔥🔥🔥 DEBUG: ❌❌❌ Save operation failed: \(error.localizedDescription)")
            // Remove from local array if save failed
            projects.removeAll { $0.id == project.id }
            throw error
        }
        
        // CRITICAL: Reload data immediately after save to ensure it's persisted
        print("🔥🔥🔥 DEBUG: Reloading data to verify project was saved...")
        if let firebaseBackend = firebaseBackend,
           firebaseBackend.isAuthenticated,
           let organizationId = firebaseBackend.currentOrganization?.firestoreDocumentId {
            do {
                // Wait a brief moment for Firebase to propagate
                try? await Task.sleep(nanoseconds: 500_000_000) // 0.5 seconds
                
                // Reload projects from Firebase
                let loadedProjects = try await firebaseBackend.loadProjects(organizationId: organizationId)
                print("🔥🔥🔥 DEBUG: Reloaded \(loadedProjects.count) projects from Firebase")
                
                // Check if our project is in the loaded list
                let verified = loadedProjects.contains { $0.id == project.id }
                if verified {
                    print("🔥🔥🔥 DEBUG: ✅✅✅ VERIFIED: Project \(project.siteName) was saved and loaded successfully!")
                    // Update local array with reloaded data to ensure consistency
                    self.projects = loadedProjects
                } else {
                    print("🔥🔥🔥 DEBUG: ⚠️⚠️⚠️ WARNING: Project save verification failed!")
                    print("🔥🔥🔥 DEBUG: Project ID we're looking for: \(project.id.uuidString)")
                    print("🔥🔥🔥 DEBUG: Loaded project IDs: \(loadedProjects.map { $0.id.uuidString }.joined(separator: ", "))")
                    print("🔥🔥🔥 DEBUG: Retrying save...")
                    // Retry save
                    let retryResult = await saveDataWithRetry(description: "re-saving project \(project.siteName) after verification failure")
                    
                    switch retryResult {
                    case .success:
                        // Reload again after retry
                        try? await Task.sleep(nanoseconds: 500_000_000)
                        let retryLoadedProjects = try await firebaseBackend.loadProjects(organizationId: organizationId)
                        self.projects = retryLoadedProjects
                        if retryLoadedProjects.contains(where: { $0.id == project.id }) {
                            print("🔥🔥🔥 DEBUG: ✅ Project saved successfully after retry!")
                        } else {
                            print("🔥🔥🔥 DEBUG: ❌❌❌ CRITICAL: Project still not found after retry!")
                            throw NSError(domain: "ProjectStore", code: -1, userInfo: [NSLocalizedDescriptionKey: "Project could not be verified in Firebase after save"])
                        }
                    case .failure(let error):
                        print("🔥🔥🔥 DEBUG: ❌ Retry save failed: \(error.localizedDescription)")
                        throw error
                    }
                }
            } catch {
                print("🔥🔥🔥 DEBUG: ❌ Could not verify project save: \(error.localizedDescription)")
                print("🔥🔥🔥 DEBUG: Error type: \(type(of: error))")
                let nsError = error as NSError
                print("🔥🔥🔥 DEBUG: Error domain: \(nsError.domain), code: \(nsError.code)")
                // Don't throw here - save may have succeeded even if verification failed
            }
        } else {
            print("🔥🔥🔥 DEBUG: ⚠️ Cannot verify save - Firebase not available or not authenticated")
            print("🔥🔥🔥 DEBUG: Firebase backend: \(firebaseBackend != nil)")
            print("🔥🔥🔥 DEBUG: Authenticated: \(firebaseBackend?.isAuthenticated ?? false)")
            print("🔥🔥🔥 DEBUG: Organization: \(firebaseBackend?.currentOrganization?.name ?? "nil")")
            // If Firebase is not available, save should have already thrown an error
        }
        print("🔥🔥🔥 DEBUG: ========== ADD PROJECT END ==========")
    }
    
    func addSmallWorks(_ smallWork: Project) async throws {
        print("🔥🔥🔥 DEBUG: ========== ADD SMALL WORKS START ==========")
        print("🔥🔥🔥 DEBUG: addSmallWorks called with small works: \(smallWork.siteName)")
        print("🔥🔥🔥 DEBUG: Small Works ID: \(smallWork.id.uuidString)")
        print("🔥🔥🔥 DEBUG: Current projects count before adding: \(projects.count)")
        
        // Add to local array first
        projects.append(smallWork)
        print("🔥🔥🔥 DEBUG: Current projects count after adding: \(projects.count)")
        
        // CRITICAL: Wait for organization before saving
        let organizationId = await DataPersistenceManager.shared.waitForOrganization(
            firebaseBackend: firebaseBackend,
            maxWaitSeconds: 15
        )
        
        guard let organizationId = organizationId,
              let firebaseBackend = firebaseBackend else {
            print("🔥🔥🔥 DEBUG: ⚠️ Cannot save small works to Firebase - organization not loaded. Keeping local save.")
            do {
                try await persistenceService.saveProjectData(projects: projects, clients: clients)
                print("🔥🔥🔥 DEBUG: ✅ Small Works saved locally while Firebase org is unavailable")
            } catch {
                print("🔥🔥🔥 DEBUG: ❌ Failed local save while org unavailable: \(error.localizedDescription)")
                projects.removeAll { $0.id == smallWork.id }
                throw error
            }
            return
        }
        
        // CRITICAL: Ensure user document has organizationId before saving
        // This prevents "user not linked to organization" errors
        print("🔥🔥🔥 DEBUG: [addSmallWorks] Ensuring user document is linked to organization: \(organizationId)")
        do {
            try await firebaseBackend.ensureUserDocumentLinked(organizationId: organizationId)
            print("🔥🔥🔥 DEBUG: [addSmallWorks] ✅ User document verified/updated with organizationId")
            // Wait a moment for the update to propagate in Firestore
            try? await Task.sleep(nanoseconds: 500_000_000) // 0.5 seconds
        } catch {
            print("🔥🔥🔥 DEBUG: [addSmallWorks] ⚠️ Could not ensure user document is linked: \(error.localizedDescription)")
            let nsError = error as NSError
            if nsError.domain == "FIRFirestoreErrorDomain" && nsError.code == 7 {
                print("🔥🔥🔥 DEBUG: [addSmallWorks] ⚠️ Permission denied - this is OK, validation will check organization members")
            } else {
                // Try recovery as fallback
                print("🔥🔥🔥 DEBUG: [addSmallWorks] Attempting recovery as fallback...")
                if let userId = firebaseBackend.currentUser?.uid,
                   let userEmail = firebaseBackend.currentUser?.email {
                    let recovered = await firebaseBackend.recoverMissingOrganizationLink(userId: userId, userEmail: userEmail)
                    if recovered {
                        print("🔥🔥🔥 DEBUG: [addSmallWorks] ✅ Recovered organization link via fallback")
                        await firebaseBackend.loadUserOrganization(userId: userId)
                        // Wait for organization to load
                        try? await Task.sleep(nanoseconds: 500_000_000) // 0.5 seconds
                    } else {
                        print("🔥🔥🔥 DEBUG: [addSmallWorks] ⚠️ Recovery also failed - continuing anyway (validation will check members)")
                    }
                }
            }
        }
        
        // Save to local storage first
        do {
            try await persistenceService.saveProjectData(projects: projects, clients: clients)
            print("🔥🔥🔥 DEBUG: Small Works saved to local storage")
        } catch {
            print("🔥🔥🔥 DEBUG: ⚠️ Failed to save to local storage: \(error.localizedDescription)")
        }
        
        // CRITICAL: Save Small Works directly to Firebase (same pattern as addProject)
        let saveResult = await DataPersistenceManager.shared.saveWithRetry(
            operation: {
                try await firebaseBackend.saveSmallWorks(smallWork, organizationId: organizationId)
            },
            description: "saving small works \(smallWork.siteName)",
            onSuccess: { _ in
                print("🔥🔥🔥 DEBUG: ✅ Small Works saved successfully to Firebase")
            },
            onFailure: { error in
                print("🔥🔥🔥 DEBUG: ❌ Failed to save Small Works: \(error.localizedDescription)")
            }
        )
        
        // Check if save was successful
        switch saveResult {
        case .success:
            print("🔥🔥🔥 DEBUG: ✅ Save operation completed successfully")
            if firebaseBackend.isAuthenticated,
               firebaseBackend.currentOrganization != nil {
                await notificationService?.notifySmallWorksCreated(
                    smallWorkId: smallWork.id,
                    siteName: smallWork.siteName,
                    jobNumber: smallWork.jobNumber,
                    createdBy: creatorDisplayNameForNotifications()
                )
            }
        case .failure(let error):
            print("🔥🔥🔥 DEBUG: ❌❌❌ Save operation failed: \(error.localizedDescription)")
            // Remove from local array if save failed
            projects.removeAll { $0.id == smallWork.id }
            throw error
        }
        
        // CRITICAL: Reload data immediately after save to ensure it's persisted
        print("🔥🔥🔥 DEBUG: Reloading data to verify small works was saved...")
        do {
            // Wait a brief moment for Firebase to propagate
            try? await Task.sleep(nanoseconds: 500_000_000) // 0.5 seconds
            
            // Reload small works from Firebase
            let loadedSmallWorks = try await firebaseBackend.loadSmallWorks(organizationId: organizationId)
            print("🔥🔥🔥 DEBUG: Reloaded \(loadedSmallWorks.count) small works from Firebase")
            
            // Check if our small works is in the loaded list
            let verified = loadedSmallWorks.contains { $0.id == smallWork.id }
            if verified {
                print("🔥🔥🔥 DEBUG: ✅✅✅ VERIFIED: Small Works \(smallWork.siteName) was saved and loaded successfully!")
                // Update local array with reloaded data to ensure consistency
                let currentProjects = projects.filter { $0.jobType != .smallWorks }
                self.projects = currentProjects + loadedSmallWorks
            } else {
                print("🔥🔥🔥 DEBUG: ⚠️⚠️⚠️ WARNING: Small Works save verification failed!")
                print("🔥🔥🔥 DEBUG: Small Works ID we're looking for: \(smallWork.id.uuidString)")
                print("🔥🔥🔥 DEBUG: Loaded small works IDs: \(loadedSmallWorks.map { $0.id.uuidString }.joined(separator: ", "))")
                print("🔥🔥🔥 DEBUG: Retrying save...")
                // Retry save directly
                let retryResult = await DataPersistenceManager.shared.saveWithRetry(
                    operation: {
                        try await firebaseBackend.saveSmallWorks(smallWork, organizationId: organizationId)
                    },
                    description: "re-saving small works \(smallWork.siteName) after verification failure",
                    onSuccess: { _ in
                        print("🔥🔥🔥 DEBUG: ✅ Retry save successful")
                    },
                    onFailure: { error in
                        print("🔥🔥🔥 DEBUG: ❌ Retry save failed: \(error.localizedDescription)")
                    }
                )
                
                switch retryResult {
                case .success:
                    // Reload again after retry
                    try? await Task.sleep(nanoseconds: 500_000_000)
                    let retryLoadedSmallWorks = try await firebaseBackend.loadSmallWorks(organizationId: organizationId)
                    let currentProjects = projects.filter { $0.jobType != .smallWorks }
                    self.projects = currentProjects + retryLoadedSmallWorks
                    if retryLoadedSmallWorks.contains(where: { $0.id == smallWork.id }) {
                        print("🔥🔥🔥 DEBUG: ✅ Small Works saved successfully after retry!")
                    } else {
                        print("🔥🔥🔥 DEBUG: ❌❌❌ CRITICAL: Small Works still not found after retry!")
                        throw NSError(domain: "ProjectStore", code: -1, userInfo: [NSLocalizedDescriptionKey: "Small Works could not be verified in Firebase after save"])
                    }
                case .failure(let error):
                    print("🔥🔥🔥 DEBUG: ❌ Retry save failed: \(error.localizedDescription)")
                    throw error
                }
            }
        } catch {
            print("🔥🔥🔥 DEBUG: ❌ Could not verify small works save: \(error.localizedDescription)")
            print("🔥🔥🔥 DEBUG: Error type: \(type(of: error))")
            let nsError = error as NSError
            print("🔥🔥🔥 DEBUG: Error domain: \(nsError.domain), code: \(nsError.code)")
            // Don't throw here - save may have succeeded even if verification failed
        }
        print("🔥🔥🔥 DEBUG: ========== ADD SMALL WORKS END ==========")
    }
    
    func updateProject(_ project: Project) async {
        if let index = projects.firstIndex(where: { $0.id == project.id }) {
            projects[index] = project
            // CRITICAL: Save immediately with retry logic
            // The saveDataInternal function will automatically route to the correct collection
            // based on jobType (projects vs smallWorks)
            _ = await saveDataWithRetry(description: "updating \(project.jobType == .smallWorks ? "small works" : "project") \(project.siteName)")
        }
    }
    
    func deleteProject(_ project: Project) async {
        let projectName = project.siteName
        projects.removeAll { $0.id == project.id }
        
        // Delete from Firebase if available
        if let firebaseBackend = firebaseBackend,
           firebaseBackend.isAuthenticated,
           let organizationId = firebaseBackend.currentOrganization?.firestoreDocumentId {
            _ = await DataPersistenceManager.shared.saveWithRetry(
                operation: {
                    // Delete from appropriate collection based on job type
                    if project.jobType == .smallWorks {
                        try await firebaseBackend.deleteSmallWorks(project, organizationId: organizationId)
                    } else {
                        try await firebaseBackend.deleteProject(project, organizationId: organizationId)
                    }
                },
                description: "deleting \(project.jobType == .smallWorks ? "small works" : "project") \(projectName)",
                onSuccess: { _ in
                    print("🔥🔥🔥 DEBUG: ✅ \(project.jobType == .smallWorks ? "Small Works" : "Project") \(projectName) deleted from Firebase")
                },
                onFailure: { error in
                    print("🔥🔥🔥 DEBUG: ❌ Failed to delete \(project.jobType == .smallWorks ? "small works" : "project") \(projectName) from Firebase: \(error.localizedDescription)")
                }
            )
        }
        
        // CRITICAL: Save state immediately
        _ = await saveDataWithRetry(description: "saving state after deleting \(project.jobType == .smallWorks ? "small works" : "project") \(projectName)")
    }
    
    func toggleProjectStatus(_ project: Project) async {
        if let index = projects.firstIndex(where: { $0.id == project.id }) {
            projects[index].isLive.toggle()
            // CRITICAL: Save immediately with retry logic
            _ = await saveDataWithRetry(description: "toggling project status for \(project.siteName)")
        }
    }
    
    // MARK: - Client Operations
    
    func addClient(_ client: Client) async {
        print("🔥🔥🔥 DEBUG: addClient called with client: \(client.name)")
        print("🔥🔥🔥 DEBUG: Current clients count before adding: \(clients.count)")
        clients.append(client)
        print("🔥🔥🔥 DEBUG: Current clients count after adding: \(clients.count)")
        
        let saveResult = await saveDataWithRetry(description: "adding client \(client.name)")
        if case .success = saveResult,
           firebaseBackend?.isAuthenticated == true,
           firebaseBackend?.currentOrganization != nil {
            await notificationService?.notifyClientCreated(
                clientId: client.id,
                clientName: client.name,
                createdBy: creatorDisplayNameForNotifications()
            )
        }
    }
    
    func updateClient(_ client: Client) async {
        if let index = clients.firstIndex(where: { $0.id == client.id }) {
            clients[index] = client
            // CRITICAL: Save immediately with retry logic
            _ = await saveDataWithRetry(description: "updating client \(client.name)")
        }
    }
    
    func deleteClient(_ client: Client) async {
        let clientName = client.name
        clients.removeAll { $0.id == client.id }
        
        // Delete from Firebase if available
        if let firebaseBackend = firebaseBackend,
           firebaseBackend.isAuthenticated,
           let organizationId = firebaseBackend.currentOrganization?.firestoreDocumentId {
            _ = await DataPersistenceManager.shared.saveWithRetry(
                operation: {
                    try await firebaseBackend.deleteClient(client, organizationId: organizationId)
                },
                description: "deleting client \(clientName)",
                onSuccess: { _ in
                    print("🔥🔥🔥 DEBUG: ✅ Client \(clientName) deleted from Firebase")
                },
                onFailure: { error in
                    print("🔥🔥🔥 DEBUG: ❌ Failed to delete client \(clientName) from Firebase: \(error.localizedDescription)")
                }
            )
        }
        
        // CRITICAL: Save state immediately
        _ = await saveDataWithRetry(description: "saving state after deleting client \(clientName)")
    }
    
    // MARK: - Computed Properties
    
    var liveProjects: [Project] {
        projects.filter { $0.isLive && $0.jobType != .smallWorks }
    }
    
    var smallWorks: [Project] {
        projects.filter { $0.isLive && $0.jobType == .smallWorks }
    }
    
    var upcomingProjects: [Project] {
        projects.filter { $0.status == ProjectStatus.upcoming }
    }
    
    var activeProjects: [Project] {
        projects.filter { $0.status == ProjectStatus.active }
    }
    
    var completedProjects: [Project] {
        projects.filter { $0.status == ProjectStatus.completed }
    }
    
    var projectsByStatus: [ProjectStatus: [Project]] {
        Dictionary(grouping: projects, by: { $0.status })
    }
    
    var projectsByClient: [Client: [Project]] {
        Dictionary(grouping: projects, by: { $0.client })
    }
    
    // MARK: - Persistence
    
    /// Save data with retry logic - ensures data is never lost
    private func saveDataWithRetry(description: String = "saving project data") async -> Result<Void, Error> {
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
                // Data is still in memory, will retry on next operation
            }
        )
    }
    
    /// Internal save implementation
    private func saveData() async {
        _ = await saveDataWithRetry(description: "saving project data")
    }
    
    /// Internal save implementation (actual save logic)
    private func saveDataInternal() async throws {
        print("🔥🔥🔥 DEBUG: ProjectStore.saveData() called")
        print("🔥🔥🔥 DEBUG: Number of projects to save: \(projects.count)")
        print("🔥🔥🔥 DEBUG: Number of clients to save: \(clients.count)")
        
        do {
            // Save to local storage
            try await persistenceService.saveProjectData(projects: projects, clients: clients)
            print("🔥🔥🔥 DEBUG: Projects and clients saved to local storage")
            
            // CRITICAL: Wait for organization to load before saving to Firebase
            // This ensures we never save locally when Firebase is available but org isn't ready
            let organizationId = await DataPersistenceManager.shared.waitForOrganization(
                firebaseBackend: firebaseBackend,
                maxWaitSeconds: 15
            )
            
            if let organizationId = organizationId,
               let firebaseBackend = firebaseBackend {
                print("🔥🔥🔥 DEBUG: Organization ID: \(organizationId)")
                
                // Verify and fix user document organizationId before saving
                if let userId = firebaseBackend.currentUser?.uid,
                   let userEmail = firebaseBackend.currentUser?.email {
                    // Try to ensure user document has organizationId
                    let recovered = await firebaseBackend.recoverMissingOrganizationLink(userId: userId, userEmail: userEmail)
                    if recovered {
                        print("🔥🔥🔥 DEBUG: ✅ Recovered organization link for user")
                        // Reload organization to ensure it's set
                        await firebaseBackend.loadUserOrganization(userId: userId)
                    }
                }
                
                // Before saving, attempt to repair membership/linking so writes are authorized.
                await firebaseBackend.repairCurrentUserOrganizationAccess(organizationId: organizationId)

                // Save projects to Firebase (excluding small works - they have their own collection)
                var projectSaveErrors: [String] = []
                let regularProjects = projects.filter { $0.jobType != .smallWorks }
                for project in regularProjects {
                    do {
                        try await firebaseBackend.saveProject(project, organizationId: organizationId)
                        print("🔥🔥🔥 DEBUG: Successfully saved project \(project.siteName) to Firebase")
                    } catch {
                        let errorMsg = "Error saving project \(project.siteName) to Firebase: \(error.localizedDescription)"
                        print("🔥🔥🔥 DEBUG: \(errorMsg)")
                        projectSaveErrors.append(errorMsg)
                    }
                }
                
                // Save small works to separate collection
                var smallWorksSaveErrors: [String] = []
                let smallWorksProjects = projects.filter { $0.jobType == .smallWorks }
                for smallWork in smallWorksProjects {
                    do {
                        try await firebaseBackend.saveSmallWorks(smallWork, organizationId: organizationId)
                        print("🔥🔥🔥 DEBUG: Successfully saved small works \(smallWork.siteName) to Firebase")
                    } catch {
                        let errorMsg = "Error saving small works \(smallWork.siteName) to Firebase: \(error.localizedDescription)"
                        print("🔥🔥🔥 DEBUG: \(errorMsg)")
                        smallWorksSaveErrors.append(errorMsg)
                    }
                }
                
                // Save clients to Firebase
                var clientSaveErrors: [String] = []
                for client in clients {
                    do {
                        try await firebaseBackend.saveClient(client, organizationId: organizationId)
                        print("🔥🔥🔥 DEBUG: Successfully saved client \(client.name) to Firebase")
                    } catch {
                        let errorMsg = "Error saving client \(client.name) to Firebase: \(error.localizedDescription)"
                        print("🔥🔥🔥 DEBUG: \(errorMsg)")
                        clientSaveErrors.append(errorMsg)
                    }
                }
                
                // Save job types to Firebase
                do {
                    try await firebaseBackend.saveJobTypes(organizationId: organizationId, jobTypes: jobTypes)
                    print("🔥🔥🔥 DEBUG: Successfully saved \(jobTypes.count) job types to Firebase")
                } catch {
                    let errorMsg = "Error saving job types to Firebase: \(error.localizedDescription)"
                    print("🔥🔥🔥 DEBUG: \(errorMsg)")
                }
                
                if !projectSaveErrors.isEmpty || !smallWorksSaveErrors.isEmpty || !clientSaveErrors.isEmpty {
                    let allErrors = projectSaveErrors + smallWorksSaveErrors + clientSaveErrors
                    let joined = allErrors.joined(separator: "; ")
                    print("🔥🔥🔥 DEBUG: Some Firebase saves failed: \(joined)")
                    // Keep local state without forcing retry storms on partial/permission failures.
                    self.errorMessage = "Some cloud saves failed. Local data is kept."
                } else {
                    print("🔥🔥🔥 DEBUG: Successfully saved \(regularProjects.count) projects, \(smallWorksProjects.count) small works, and \(clients.count) clients to Firebase")
                }
            } else {
                print("🔥🔥🔥 DEBUG: Saved \(projects.count) projects and \(clients.count) clients locally (Firebase not available or not authenticated)")
                print("🔥🔥🔥 DEBUG: Firebase backend: \(firebaseBackend != nil)")
                print("🔥🔥🔥 DEBUG: Authenticated: \(firebaseBackend?.isAuthenticated ?? false)")
                print("🔥🔥🔥 DEBUG: Organization: \(firebaseBackend?.currentOrganization?.name ?? "nil")")
                print("🔥🔥🔥 DEBUG: ⚠️ Local-only save mode active. Data is saved locally and will sync when Firebase org access is restored.")
            }
        } catch {
            errorMessage = "Failed to save data: \(error.localizedDescription)"
            // Re-throw so retry logic can handle it
            throw error
        }
    }
    
    func clearAllData() async {
        projects.removeAll()
        clients.removeAll()
        jobTypes.removeAll()
        await saveData()
    }
    
    // MARK: - Job Types Management
    
    func addJobType(_ jobType: String) {
        jobTypes.insert(jobType)
        Task {
            await saveData()
        }
    }
    
    func removeJobType(_ jobType: String) {
        jobTypes.remove(jobType)
        Task {
            await saveData()
        }
    }
}
