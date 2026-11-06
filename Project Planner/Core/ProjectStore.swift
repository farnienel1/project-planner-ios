//
//  ProjectStore.swift
//  Project Planner
//
//  Created by Assistant on 29/09/2025.
//

import Foundation
import Combine
import FirebaseFirestore
import FirebaseAuth

@MainActor
class ProjectStore: ObservableObject {
    @Published var projects: [Project] = [] {
        // RULEBOOK 1.10.0 §17: the loaded jobs feed `canWriteBooking` and the job fields of the read context (1.33.0:
        // every manager reads every booking, so `bookingQueryPlan` no longer depends on them).
        didSet {
            JobAccessContext.updateJobs(projects)
            revision &+= 1
        }
    }
    /// Bumped on every change to `projects`, so booking-flow conflict labels can be memoised per data version.
    private(set) var revision = 0
    /// The last read of the `smallWorks` collection (load or listener), every document the rulebook reader accepted.
    /// `smallWorks` lists from `projects`, plus any of these whose id a `projects` document also holds (that id is
    /// kept once in `projects`, as the project): web lists each collection on its own screen, so neither is lost.
    @Published private(set) var smallWorksDocuments: [Project] = []
    @Published var clients: [Client] = []
    @Published var jobTypes: Set<String> = []
    @Published var isLoading: Bool = false
    /// The organisation whose jobs load last finished (read or failed). Warnings wait for it.
    private(set) var finishedLoadOrganizationId: String?
    @Published var errorMessage: String?
    @Published var isOffline: Bool = false
    /// True when the latest Firebase read was empty/failed and the list is coming from memory or disk.
    @Published var lastWorkLoadUnreliable: Bool = false
    
    private let persistenceService: PersistenceService
    private var firebaseBackend: FirebaseBackend?
    private var readPlanObserver: NSObjectProtocol?
    private var readPlanOrganizationId: String?
    private var notificationService: NotificationService?
    private var smartCache: SmartCacheService?
    private var cancellables = Set<AnyCancellable>()
    private var didAttemptOrgAutoSwitch = false
    private var pendingReloadAfterCurrentLoad = false
    private var loadGeneration = 0
    /// Jobs and clients this device just created whose save has not finished. A listener snapshot taken before
    /// the create reached Firestore must not drop them (the create would then never be written).
    private var pendingCreateIds = Set<UUID>()

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
            // Persistence key only — do not loadData here. Launch/org bootstrap owns the first load.
            // Calling loadData on sign-in + organizationDidLoad + bootstrap triple-loads and jetsams Simulator.
            if let userId = notification.object as? String {
                Task { @MainActor [weak self] in
                    self?.persistenceService.setCurrentUser(userId)
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
                guard let self else { return }
                // Initial launch: PlannerStoreWiring.bootstrapOrgDataIfNeeded owns the first load.
                // Reloading here too stacks duplicate Firebase reads and jetsams the Simulator.
                guard self.firebaseBackend?.hasBootstrappedOrgDataLoad == true else {
                    print("🔥🔥🔥 DEBUG: ProjectStore skipping organizationDidLoad reload (pre-bootstrap)")
                    return
                }
                print("🔥🔥🔥 DEBUG: ProjectStore ignoring organizationDidLoad reload (bootstrap owns loads)")
            }
        }

        // No `.syncOfflineChanges` observer: projects, small works and clients are online-only edits
        // (RULEBOOK §2), so there is nothing to replay. Re-saving every in-memory record on foreground
        // overwrote web edits from a stale copy and re-created jobs and clients deleted on web.
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
        if isLoading {
            // During bootstrap a second kick must not queue another full projects storm.
            if firebaseBackend?.isBootstrappingOrgDataLoad == true {
                print("🔥🔥🔥 DEBUG: ProjectStore loadData ignored (already loading during bootstrap); not queueing follow-up")
                return
            }
            pendingReloadAfterCurrentLoad = true
            print("🔥🔥🔥 DEBUG: ProjectStore loadData ignored (already loading); queued one follow-up reload")
            return
        }

        isLoading = true
        errorMessage = nil
        lastWorkLoadUnreliable = false
        pendingReloadAfterCurrentLoad = false
        loadGeneration += 1
        let generation = loadGeneration
        let loadingOrganizationId = firebaseBackend?.currentOrganization?.firestoreDocumentId
        
        Task {
            // Add timeout to prevent infinite loading
            let timeoutTask = Task { @MainActor in
                try? await Task.sleep(nanoseconds: 18_000_000_000)
                if isLoading && loadGeneration == generation {
                    print("🔥🔥🔥 DEBUG: ⚠️ ProjectStore load timeout - forcing completion")
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
                        // Coalesce follow-ups: one delayed reload max, and only after bootstrap finishes.
                        if firebaseBackend?.hasBootstrappedOrgDataLoad == true,
                           firebaseBackend?.isBootstrappingOrgDataLoad != true {
                            print("🔥🔥🔥 DEBUG: ProjectStore running queued follow-up reload")
                            Task { @MainActor in
                                try? await Task.sleep(nanoseconds: 1_200_000_000)
                                self.loadData()
                            }
                        }
                    }
                }
            }
            
            // Show last-known jobs immediately so a slow/failed Firebase read cannot blank the UI.
            let diskCache = await hydrateFromLocalCacheIfNeeded(generation: generation)

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
                        async let projectsOutcome: Result<[Project], Error> = {
                            do {
                                let items = try await withTimeout(seconds: 10) {
                                    try await firebaseBackend.loadProjects(organizationId: organizationId)
                                }
                                return .success(items.filter { $0.jobType != .smallWorks })
                            } catch {
                                return .failure(error)
                            }
                        }()
                        async let smallWorksOutcome: Result<[Project], Error> = {
                            do {
                                let items = try await withTimeout(seconds: 10) {
                                    try await firebaseBackend.loadSmallWorks(organizationId: organizationId)
                                }
                                return .success(items)
                            } catch {
                                return .failure(error)
                            }
                        }()
                        var loadedProjects = await projectsOutcome
                        var loadedSmallWorks = await smallWorksOutcome

                        // Auth/token races on TestFlight can return a one-shot empty snapshot.
                        // Retry once before deciding the organisation has no work.
                        if case .success(let projects) = loadedProjects,
                           case .success(let smallWorks) = loadedSmallWorks,
                           projects.isEmpty && smallWorks.isEmpty {
                            print("🔥🔥🔥 DEBUG: Both collections empty — retrying Firebase once (auth/token race)")
                            try? await Task.sleep(nanoseconds: 1_200_000_000)
                            loadedProjects = await {
                                do {
                                    let items = try await withTimeout(seconds: 10) {
                                        try await firebaseBackend.loadProjects(organizationId: organizationId)
                                    }
                                    return .success(items.filter { $0.jobType != .smallWorks })
                                } catch {
                                    return .failure(error)
                                }
                            }()
                            loadedSmallWorks = await {
                                do {
                                    let items = try await withTimeout(seconds: 10) {
                                        try await firebaseBackend.loadSmallWorks(organizationId: organizationId)
                                    }
                                    return .success(items)
                                } catch {
                                    return .failure(error)
                                }
                            }()
                        }

                        var firebaseProjects: [Project] = []
                        var projectsLoaded = false
                        var projectsError: Error?
                        switch loadedProjects {
                        case .success(let items):
                            firebaseProjects = items
                            projectsLoaded = true
                            print("🔥🔥🔥 DEBUG: ✅ Successfully loaded \(firebaseProjects.count) projects from Firebase (excluding small works)")
                        case .failure(let error):
                            projectsError = error
                            print("🔥🔥🔥 DEBUG: ❌❌❌ ERROR loading projects: \(error.localizedDescription)")
                        }

                        var firebaseSmallWorks: [Project] = []
                        var smallWorksLoaded = false
                        var smallWorksError: Error?
                        switch loadedSmallWorks {
                        case .success(let items):
                            firebaseSmallWorks = items
                            smallWorksLoaded = true
                            print("🔥🔥🔥 DEBUG: ✅ Successfully loaded \(firebaseSmallWorks.count) small works from Firebase")
                        case .failure(let error):
                            smallWorksError = error
                            print("🔥🔥🔥 DEBUG: ❌❌❌ ERROR loading small works: \(error.localizedDescription)")
                        }

                        let cachedProjects = diskCache.projects.filter { $0.jobType != .smallWorks }
                        let cachedSmallWorks = diskCache.projects.filter { $0.jobType == .smallWorks }
                        guard loadGeneration == generation else { return }
                        var merged = existingProjectsBeforeLoad
                        merged = ProjectWorksMerge.mergeWorkSlice(
                            existingAll: merged,
                            remoteSlice: projectsLoaded ? firebaseProjects : nil,
                            cachedSlice: cachedProjects,
                            isSmallWorks: false
                        )
                        merged = ProjectWorksMerge.mergeWorkSlice(
                            existingAll: merged,
                            remoteSlice: smallWorksLoaded ? firebaseSmallWorks : nil,
                            cachedSlice: cachedSmallWorks,
                            isSmallWorks: true
                        )
                        if smallWorksLoaded { self.smallWorksDocuments = firebaseSmallWorks }
                        self.projects = merged
                        let usedFallback =
                            (!projectsLoaded || (firebaseProjects.isEmpty && merged.contains { $0.jobType != .smallWorks })) ||
                            (!smallWorksLoaded || (firebaseSmallWorks.isEmpty && merged.contains { $0.jobType == .smallWorks }))
                        lastWorkLoadUnreliable = (usedFallback && !merged.isEmpty) || (!projectsLoaded && !smallWorksLoaded)
                        if !projectsLoaded && !smallWorksLoaded {
                            errorMessage = projectsError?.localizedDescription
                                ?? smallWorksError?.localizedDescription
                                ?? "Could not load projects from the server."
                        }
                        if !merged.isEmpty {
                            Task { try? await persistenceService.saveProjectData(projects: merged, clients: self.clients) }
                        }
                        print("🔥🔥🔥 DEBUG: ✅ Total loaded: \(firebaseProjects.count) projects + \(firebaseSmallWorks.count) small works (store=\(merged.count), unreliable=\(lastWorkLoadUnreliable))")
                        
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
                                let inferred = extractClientsFromProjects(merged)
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
                            let inferred = extractClientsFromProjects(merged)
                            self.clients = inferred.isEmpty ? existingClientsBeforeLoad : inferred
                        }
                        
                        // Load job types from Firebase
                        let existingJobTypesBeforeLoad = self.jobTypes
                        do {
                            let firebaseJobTypes = try await withTimeout(seconds: 5) {
                                try await firebaseBackend.loadJobTypes(organizationId: organizationId)
                            }
                            let recovered = jobTypesRecoveredFromWorks(merged)
                            // RULEBOOK 1.8.0 §1: `mergeJobTypeCatalogues` (stored list + names on live jobs + the
                            // restored defaults, canonical names). Fallback below only when the script did not answer.
                            let storedTypes = firebaseJobTypes.isEmpty ? existingJobTypesBeforeLoad : firebaseJobTypes
                            if let mergedTypes = CanonicalBusinessEngine.mergeJobTypeCatalogues(
                                stored: Array(storedTypes),
                                recovered: Array(recovered)
                            ), !mergedTypes.isEmpty {
                                self.jobTypes = Set(mergedTypes)
                            } else if firebaseJobTypes.isEmpty {
                                if !existingJobTypesBeforeLoad.isEmpty {
                                    self.jobTypes = existingJobTypesBeforeLoad.union(recovered)
                                    print("🔥🔥🔥 DEBUG: Firebase returned 0 job types, preserving \(self.jobTypes.count) in-memory/recovered types")
                                } else if !recovered.isEmpty {
                                    self.jobTypes = recovered
                                    print("🔥🔥🔥 DEBUG: Recovered \(recovered.count) job types from live projects/small works")
                                } else {
                                    self.jobTypes = Set(JobType.allCases.map(\.rawValue))
                                    print("🔥🔥🔥 DEBUG: No stored job types; seeding recommended defaults")
                                }
                            } else {
                                self.jobTypes = firebaseJobTypes.union(recovered)
                                print("🔥🔥🔥 DEBUG: Loaded \(firebaseJobTypes.count) job types from Firebase (+ \(recovered.count) recovered)")
                            }
                        } catch {
                            let recovered = jobTypesRecoveredFromWorks(merged)
                            if !existingJobTypesBeforeLoad.isEmpty {
                                self.jobTypes = existingJobTypesBeforeLoad.union(recovered)
                            } else if !recovered.isEmpty {
                                self.jobTypes = recovered
                            }
                            print("🔥🔥🔥 DEBUG: Error loading job types from Firebase: \(error.localizedDescription)")
                        }
                        
                        let permissionDeniedWhileLoadingWork =
                            isPermissionDeniedError(projectsError) || isPermissionDeniedError(smallWorksError)
                        let shouldTryOrgAutoSwitch =
                            firebaseBackend.suppressStaleOrganizationCache != true &&
                            !didAttemptOrgAutoSwitch &&
                            (merged.isEmpty || permissionDeniedWhileLoadingWork)

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

                        // Local fallback — never replace known jobs with an empty disk read.
                        print("🔥🔥🔥 DEBUG: Organization still nil after recovery, loading from local storage")
                        applyLocalProjectFallback(diskCache.projects, clients: diskCache.clients)
                        lastWorkLoadUnreliable = !self.projects.isEmpty
                        print("🔥🔥🔥 DEBUG: Loaded \(self.projects.count) projects and \(self.clients.count) clients from local storage")
                    }
                    
                } else {
                    // Fallback to local storage
                    print("🔥🔥🔥 DEBUG: Loading data from local storage (Firebase not available or not authenticated)")
                    applyLocalProjectFallback(diskCache.projects, clients: diskCache.clients)
                    lastWorkLoadUnreliable = !self.projects.isEmpty
                    print("🔥🔥🔥 DEBUG: Loaded \(self.projects.count) projects and \(self.clients.count) clients from local storage")
                }
                
            print("🔥🔥🔥 DEBUG: Finished loading - Total projects: \(self.projects.count), Total clients: \(self.clients.count)")
        }
    }
    
    /// Shows the last saved jobs before Firebase returns. Org-switch sets `suppressStaleOrganizationCache` and skips this.
    func warmLocalCacheForLaunch() async {
        guard firebaseBackend?.suppressStaleOrganizationCache != true else { return }
        guard projects.isEmpty else { return }
        _ = await hydrateFromLocalCacheIfNeeded(generation: loadGeneration)
    }

    /// Live `projects`, `smallWorks`, `clients` and `settings/jobTypes` (one listener each for the organisation),
    /// read through the same readers as the load: `jobs(fromDocuments:)` (`parseWorkDocument`, `workDocuments`),
    /// `clients(fromDocuments:)` (`parseClientDocument`) and `parseJobTypesDocument` + `mergeJobTypeCatalogues`.
    /// A server snapshot replaces that slice, so a job edited or deleted on web is edited or gone here too; that
    /// is also what keeps the in-memory copy from going stale. Cached copy first; offline keeps the last copy.
    func startLiveUpdates(organizationId: String) {
        guard let firebaseBackend else { return }
        observeReadPlan(organizationId: organizationId)
        for smallWorks in [false, true] {
            let collection = smallWorks ? "smallWorks" : "projects"
            // RULEBOOK 1.10.0 §17: the job queries `jobQueryPlan` names; re-planned on `jobReadPlanDidChange`.
            firebaseBackend.listenOrganizationPlan(
                key: collection,
                organizationId: organizationId,
                plan: firebaseBackend.jobReadSources(organizationId: organizationId, collection: collection)
            ) { [weak self] rows, fromCache in
                guard let self else { return }
                // `job(fromCanonical:)` routes by collection: every `smallWorks` document is a small work and every
                // `projects` document a project (one typed "Small Works" reads as CAT A), so this filter keeps the
                // whole snapshot and only guards the slice the listener owns.
                let incoming = FirebaseBackend.jobs(fromDocuments: rows, smallWorks: smallWorks)
                    .filter { ($0.jobType == .smallWorks) == smallWorks }
                self.applyLiveWorkSlice(
                    incoming,
                    smallWorks: smallWorks,
                    fromCache: fromCache,
                    rowCount: LiveSnapshotMerge.readableRowCount(rows)
                )
            }
        }
        firebaseBackend.listenOrganizationQuery(
            key: "clients",
            organizationId: organizationId,
            query: { $0.collection("clients") }
        ) { [weak self] rows, fromCache in
            guard let self else { return }
            let incoming = FirebaseBackend.clients(fromDocuments: rows)
            guard var next = LiveSnapshotMerge.apply(
                existing: self.clients,
                incoming: incoming,
                fromCache: fromCache,
                rowCount: LiveSnapshotMerge.readableRowCount(rows),
                collection: "clients"
            ) else { return }
            let incomingIds = Set(next.map(\.id))
            next += self.clients.filter { self.pendingCreateIds.contains($0.id) && !incomingIds.contains($0.id) }
            guard next != self.clients else { return }
            self.clients = next
            self.persistLiveSnapshotLocally()
        }
        firebaseBackend.listenOrganizationDocument(
            key: "jobTypes",
            organizationId: organizationId,
            document: { $0.collection("settings").document("jobTypes") }
        ) { [weak self] data, fromCache, _ in
            guard let self, let data, !fromCache else { return }
            let stored = CanonicalBusinessEngine.parseJobTypesDocument(data) ?? []
            guard !stored.isEmpty,
                  let merged = CanonicalBusinessEngine.mergeJobTypeCatalogues(
                    stored: stored,
                    recovered: Array(self.jobTypesRecoveredFromWorks(self.projects))
                  ), !merged.isEmpty else { return }
            let next = Set(merged)
            if next != self.jobTypes { self.jobTypes = next }
        }
    }

    /// RULEBOOK 1.10.0 §17: the job listeners follow the read plan (viewer, an operative's booked job ids).
    private func observeReadPlan(organizationId: String) {
        readPlanOrganizationId = organizationId
        guard readPlanObserver == nil else { return }
        readPlanObserver = NotificationCenter.default.addObserver(forName: .jobReadPlanDidChange, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, let orgId = self.readPlanOrganizationId,
                      self.firebaseBackend?.currentOrganization?.firestoreDocumentId == orgId else { return }
                self.startLiveUpdates(organizationId: orgId)
            }
        }
    }

    /// One collection's slice of `projects` (projects or small works) from a listener snapshot.
    private func applyLiveWorkSlice(_ incoming: [Project], smallWorks: Bool, fromCache: Bool, rowCount: Int) {
        let existingSlice = projects.filter { ($0.jobType == .smallWorks) == smallWorks }
        guard var nextSlice = LiveSnapshotMerge.apply(
            existing: existingSlice,
            incoming: incoming,
            fromCache: fromCache,
            rowCount: rowCount,
            collection: smallWorks ? "smallWorks" : "projects"
        ) else { return }
        if smallWorks, smallWorksDocuments != nextSlice { smallWorksDocuments = nextSlice }
        let incomingIds = Set(nextSlice.map(\.id))
        nextSlice += existingSlice.filter { pendingCreateIds.contains($0.id) && !incomingIds.contains($0.id) }
        guard nextSlice != existingSlice else { return }
        let others = projects.filter { ($0.jobType == .smallWorks) != smallWorks }
        projects = ProjectWorksMerge.uniqueWorks(others + nextSlice)
        if !fromCache { lastWorkLoadUnreliable = false }
        persistLiveSnapshotLocally()
    }

    private func persistLiveSnapshotLocally() {
        smartCache?.cacheProjects(projects)
        smartCache?.cacheClients(clients)
        let projects = self.projects, clients = self.clients
        Task { try? await persistenceService.saveProjectData(projects: projects, clients: clients) }
    }

    func discardInMemoryForOrganizationSwitch() {
        loadGeneration += 1
        pendingReloadAfterCurrentLoad = false
        isLoading = false
        finishedLoadOrganizationId = nil
        projects = []
        smallWorksDocuments = []
        clients = []
        jobTypes = []
        errorMessage = nil
    }

    // Helper function to add timeout to async operations
    private func hydrateFromLocalCacheIfNeeded(generation: Int) async -> (projects: [Project], clients: [Client]) {
        guard loadGeneration == generation else { return ([], []) }
        if firebaseBackend?.suppressStaleOrganizationCache == true {
            return ([], [])
        }
        do {
            let cached = try await persistenceService.loadProjectData()
            if self.projects.isEmpty && !cached.projects.isEmpty {
                self.projects = cached.projects
                print("🔥🔥🔥 DEBUG: Hydrated \(cached.projects.count) jobs from local disk before Firebase")
            }
            if self.clients.isEmpty && !cached.clients.isEmpty {
                self.clients = cached.clients
            }
            return cached
        } catch {
            print("🔥🔥🔥 DEBUG: Local project hydrate failed: \(error.localizedDescription)")
            return (self.projects, self.clients)
        }
    }

    private func applyLocalProjectFallback(_ projects: [Project], clients: [Client]) {
        if !projects.isEmpty {
            self.projects = projects
        }
        if !clients.isEmpty {
            self.clients = clients
        }
    }

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
        pendingCreateIds.insert(project.id)
        defer { pendingCreateIds.remove(project.id) }
        print("🔥🔥🔥 DEBUG: Current projects count after adding: \(projects.count)")
        
        // CRITICAL: Save immediately with retry logic and check result
        let saveResult = await saveDataWithRetry(.createWork(project), description: "adding project \(project.siteName)")
        
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
        
        // A create writes once. The live projects listener shows the saved job; no sleep, reload or re-save (a
        // second create could re-create a job deleted on another device in between).
        print("🔥🔥🔥 DEBUG: ========== ADD PROJECT END ==========")
    }
    
    func addSmallWorks(_ smallWork: Project) async throws {
        print("🔥🔥🔥 DEBUG: ========== ADD SMALL WORKS START ==========")
        print("🔥🔥🔥 DEBUG: addSmallWorks called with small works: \(smallWork.siteName)")
        print("🔥🔥🔥 DEBUG: Small Works ID: \(smallWork.id.uuidString)")
        print("🔥🔥🔥 DEBUG: Current projects count before adding: \(projects.count)")
        
        // Add to local array first
        projects.append(smallWork)
        pendingCreateIds.insert(smallWork.id)
        defer { pendingCreateIds.remove(smallWork.id) }
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
                try await firebaseBackend.saveSmallWorks(smallWork, organizationId: organizationId, mode: .create)
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
        
        // A create writes once. The live small works listener shows the saved job; no sleep, reload or re-save.
        print("🔥🔥🔥 DEBUG: ========== ADD SMALL WORKS END ==========")
    }
    
    /// `editedFrom` is the copy the editor opened with: only the fields changed from it are written, so a change
    /// another device saved meanwhile to a field this editor did not touch is not overwritten (launch data audit #5).
    /// Without it, the store copy at save time is the base (as before).
    func updateProject(_ project: Project, editedFrom base: Project? = nil) async {
        if let index = projects.firstIndex(where: { $0.id == project.id }) {
            let previous = base ?? projects[index]
            projects[index] = project
            // Saves only this job, and only the fields changed from the copy it was edited from
            // (routed to projects or smallWorks by jobType).
            _ = await saveDataWithRetry(.updateWork(project, previous: previous), description: "updating \(project.jobType == .smallWorks ? "small works" : "project") \(project.siteName)")
        }
    }
    
    func deleteProject(_ project: Project) async {
        let projectName = project.siteName
        // Only this collection's row: a project and a small works document may share an id (`smallWorksList`).
        let isSmallWorks = project.jobType == .smallWorks
        projects.removeAll { $0.id == project.id && ($0.jobType == .smallWorks) == isSmallWorks }
        if isSmallWorks { smallWorksDocuments.removeAll { $0.id == project.id } }
        
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
        _ = await saveDataWithRetry(.localOnly, description: "saving state after deleting \(project.jobType == .smallWorks ? "small works" : "project") \(projectName)")
    }
    
    func toggleProjectStatus(_ project: Project) async {
        if let index = projects.firstIndex(where: { $0.id == project.id }) {
            let previous = projects[index]
            projects[index].isLive.toggle()
            // Writes only `isLive` (+ metadata) on this job.
            _ = await saveDataWithRetry(.updateWork(projects[index], previous: previous), description: "toggling project status for \(project.siteName)")
        }
    }
    
    // MARK: - Client Operations
    
    func addClient(_ client: Client) async {
        print("🔥🔥🔥 DEBUG: addClient called with client: \(client.name)")
        print("🔥🔥🔥 DEBUG: Current clients count before adding: \(clients.count)")
        clients.append(client)
        pendingCreateIds.insert(client.id)
        defer { pendingCreateIds.remove(client.id) }
        print("🔥🔥🔥 DEBUG: Current clients count after adding: \(clients.count)")
        
        let saveResult = await saveDataWithRetry(.createClient(client), description: "adding client \(client.name)")
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
            let previous = clients[index]
            clients[index] = client
            // Only this client, only the fields changed from the copy it was edited from.
            _ = await saveDataWithRetry(.updateClient(client, previous: previous), description: "updating client \(client.name)")
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
        _ = await saveDataWithRetry(.localOnly, description: "saving state after deleting client \(clientName)")
    }
    
    // MARK: - Computed Properties
    
    /// Every small works job, live or not — what web's Small works list shows (`loadSmallWorks` keeps inactive jobs;
    /// the list files them under Completed). It used to keep `isLive` jobs only, so a small works job switched off
    /// on web vanished from iOS (Projects never had that filter). Rows come from `projects`, plus a small works
    /// document whose id a project also holds (`ProjectWorksMerge.smallWorksList`). Pickers that need live jobs
    /// filter `isLive` themselves. Do not concatenate with `projects`.
    var smallWorks: [Project] {
        ProjectWorksMerge.smallWorksList(store: projects, smallWorksDocuments: smallWorksDocuments)
    }

    /// Stored job documents this device holds, for the Settings footer (`Projects N · Small works M`), so the
    /// counts can be compared with web at a glance.
    var jobDocumentCountsLine: String {
        let projectCount = projects.filter { $0.jobType != .smallWorks }.count
        return "Projects \(projectCount) · Small works \(smallWorks.count)"
    }

    /// All loaded works for scheduling/warnings lookups (includes small works).
    var allWorks: [Project] { projects }
    
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
    private func saveDataWithRetry(_ changes: ProjectStoreChangeSet, description: String = "saving project data") async -> Result<Void, Error> {
        return await DataPersistenceManager.shared.saveWithRetry(
            operation: {
                try await self.saveDataInternal(changes)
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
    
    /// Local cache only — nothing is written to Firestore.
    private func saveData() async {
        _ = await saveDataWithRetry(.localOnly, description: "saving project data locally")
    }
    
    /// Writes the local cache, then only the records `changes` names (RULEBOOK §1 partial writes). The rest of
    /// the in-memory list is never re-saved: it may be a stale copy of what web has since edited or deleted.
    private func saveDataInternal(_ changes: ProjectStoreChangeSet) async throws {
        print("🔥🔥🔥 DEBUG: ProjectStore.saveData() — \(changes.works.count) job(s), \(changes.clients.count) client(s) changed")

        do {
            // Save to local storage
            try await persistenceService.saveProjectData(projects: projects, clients: clients)
            guard !changes.isEmpty else { return }

            // CRITICAL: Wait for organization to load before saving to Firebase
            let organizationId = await DataPersistenceManager.shared.waitForOrganization(
                firebaseBackend: firebaseBackend,
                maxWaitSeconds: 15
            )

            guard let organizationId, let firebaseBackend else {
                print("🔥🔥🔥 DEBUG: ⚠️ Saved locally only (Firebase not available or organisation not loaded)")
                return
            }

            // Verify and fix user document organizationId before saving
            if let userId = firebaseBackend.currentUser?.uid,
               let userEmail = firebaseBackend.currentUser?.email {
                let recovered = await firebaseBackend.recoverMissingOrganizationLink(userId: userId, userEmail: userEmail)
                if recovered {
                    await firebaseBackend.loadUserOrganization(userId: userId)
                }
            }
            await firebaseBackend.repairCurrentUserOrganizationAccess(organizationId: organizationId)

            var saveErrors: [String] = []
            var deletedElsewhere = false

            for item in changes.worksToSave(from: projects) {
                let work = item.work
                do {
                    if work.jobType == .smallWorks {
                        // Small works have their own collection.
                        try await firebaseBackend.saveSmallWorks(work, organizationId: organizationId, mode: item.mode, previous: item.previous)
                    } else {
                        try await firebaseBackend.saveProject(work, organizationId: organizationId, mode: item.mode, previous: item.previous)
                    }
                } catch is RecordDeletedElsewhereError {
                    // Never re-created: drop the local row and say why.
                    projects.removeAll { $0.id == work.id }
                    deletedElsewhere = true
                } catch {
                    saveErrors.append("Error saving \(work.siteName): \(error.localizedDescription)")
                }
            }

            for item in changes.clientsToSave(from: clients) {
                do {
                    try await firebaseBackend.saveClient(item.client, organizationId: organizationId, mode: item.mode, previous: item.previous)
                } catch is RecordDeletedElsewhereError {
                    clients.removeAll { $0.id == item.client.id }
                    deletedElsewhere = true
                } catch {
                    saveErrors.append("Error saving client \(item.client.name): \(error.localizedDescription)")
                }
            }

            // Job types are not written here. `settings/jobTypes` is admins and managers only
            // (RULEBOOK §16); they are written only when Job Types Management edits them (`saveJobTypesCatalogue`).

            if deletedElsewhere {
                errorMessage = RecordDeletedElsewhereError.message
                try? await persistenceService.saveProjectData(projects: projects, clients: clients)
            } else if !saveErrors.isEmpty {
                print("🔥🔥🔥 DEBUG: Some Firebase saves failed: \(saveErrors.joined(separator: "; "))")
                // Keep local state without forcing retry storms on partial/permission failures.
                // Said, never silent: the next server snapshot replaces the local edit (launch data audit #10).
                self.errorMessage = "Not saved: \(saveErrors.joined(separator: "; ")). Check your connection and try again."
            }
        } catch {
            errorMessage = "Failed to save data: \(error.localizedDescription)"
            // Re-throw so retry logic can handle it
            throw error
        }
    }

    func clearAllData() async {
        projects.removeAll()
        smallWorksDocuments.removeAll()
        clients.removeAll()
        jobTypes.removeAll()
        await saveData()
    }
    
    // MARK: - Job Types Management
    
    func addJobType(_ jobType: String) {
        let trimmed = jobType.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        jobTypes.insert(trimmed)
        Task {
            await saveJobTypesCatalogue(added: [trimmed])
        }
    }
    
    func removeJobType(_ jobType: String) {
        jobTypes.remove(jobType)
        Task {
            // RULEBOOK 1.9.0: a deliberate removal, so deleting the last job type is written (`jobTypesWriteFields`).
            await saveJobTypesCatalogue(removed: [jobType])
        }
    }

    /// Writes the job type list after an edit in Job Types Management (admins and managers, RULEBOOK §16).
    /// A settings document is online only (§2): offline, the edit stays on this device and is not queued.
    private func saveJobTypesCatalogue(added: [String] = [], removed: [String] = []) async {
        guard let firebaseBackend,
              firebaseBackend.isAuthenticated,
              let organizationId = firebaseBackend.currentOrganization?.firestoreDocumentId,
              !added.isEmpty || !removed.isEmpty else { return }
        guard firebaseBackend.userRole == .admin || firebaseBackend.userRole == .manager else {
            errorMessage = "Only admins and managers can change job types."
            return
        }
        do {
            try await firebaseBackend.saveJobTypes(organizationId: organizationId, added: added, removed: removed)
        } catch {
            errorMessage = "Job types were not saved: \(error.localizedDescription)"
            print("🔥🔥🔥 DEBUG: Error saving job types catalogue: \(error.localizedDescription)")
        }
    }

    private func jobTypesRecoveredFromWorks(_ works: [Project]) -> Set<String> {
        var names = Set<String>()
        for work in works {
            if let custom = work.customJobType?.trimmingCharacters(in: .whitespacesAndNewlines), !custom.isEmpty {
                names.insert(custom)
            }
            let typeName = work.jobType.rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if !typeName.isEmpty {
                names.insert(typeName)
            }
        }
        return names
    }
}
