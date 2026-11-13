//
//  ProjectPlannerRootView.swift
//  Project Planner
//
//  Root shell lives in a plain View so @State / onReceive update reliably.
//  @State on struct App { } is unreliable for WindowGroup content on some OS versions.
//

import SwiftUI
import FirebaseAuth
import FirebaseCore
#if canImport(FirebaseMessaging)
import FirebaseMessaging
#endif
import UIKit

/// One-time wiring of stores to Firebase (called from root `onAppear`).
enum PlannerStoreWiring {
    private static var didConnect = false

    static func connectIfNeeded(
        firebaseBackend: FirebaseBackend,
        smartCache: SmartCacheService,
        projectStore: ProjectStore,
        operativeStore: OperativeStore,
        bookingStore: BookingStore,
        managerScheduleStore: ManagerScheduleStore,
        userStore: UserStore,
        taskStore: ProjectTaskStore,
        holidayStore: HolidayStore,
        subcontractorStore: SubcontractorStore,
        notificationService: NotificationService,
        appSettings: AppSettingsStore
    ) {
        guard !didConnect else { return }
        didConnect = true

        projectStore.setFirebaseBackend(firebaseBackend)
        projectStore.setNotificationService(notificationService)
        projectStore.setSmartCache(smartCache)

        operativeStore.setFirebaseBackend(firebaseBackend)
        operativeStore.setSmartCache(smartCache)

        bookingStore.setFirebaseBackend(firebaseBackend)
        bookingStore.setSmartCache(smartCache)

        managerScheduleStore.setFirebaseBackend(firebaseBackend)
        managerScheduleStore.setSmartCache(smartCache)

        smartCache.setFirebaseBackend(firebaseBackend)

        userStore.setFirebaseBackend(firebaseBackend)
        userStore.setSmartCache(smartCache)

        taskStore.setFirebaseBackend(firebaseBackend)
        holidayStore.setFirebaseBackend(firebaseBackend)
        holidayStore.setSmartCache(smartCache)
        subcontractorStore.setFirebaseBackend(firebaseBackend)
        // RULEBOOK 1.38.0 §27: the silent, read-only data check (server count vs what each store holds).
        DataParityMonitor.shared.connect(
            firebaseBackend: firebaseBackend,
            smartCache: smartCache,
            projectStore: projectStore,
            operativeStore: operativeStore,
            bookingStore: bookingStore,
            managerScheduleStore: managerScheduleStore,
            userStore: userStore,
            taskStore: taskStore,
            holidayStore: holidayStore
        )

        // Owner report 13 Nov: an unknown booked person reads the people lists from the server once.
        UnknownBookedPersonRefresh.shared.connect(
            firebaseBackend: firebaseBackend,
            operativeStore: operativeStore,
            userStore: userStore
        )

        notificationService.setFirebaseBackend(firebaseBackend)
        notificationService.setUserStore(userStore)
        notificationService.setOperativeStore(operativeStore)
        notificationService.setProjectStore(projectStore)
        notificationService.setAppSettingsStore(appSettings)
        notificationService.setHolidayStore(holidayStore)

        appSettings.setFirebaseBackend(firebaseBackend)
        appSettings.setSmartCache(smartCache)
    }

    /// RULEBOOK §1 live screens: attaches every organisation-scoped collection listener (one per collection;
    /// `OrgLiveListeners.swift`). Safe to call again — a listener already attached for this organisation is
    /// kept, and one that failed is attached again — so the foreground calls it as bookings re-attach. All of
    /// them are removed on an organisation switch and on sign-out (`FirebaseBackend.stopScheduleLiveListeners`).
    @MainActor
    static func startOrgLiveListeners(
        firebaseBackend: FirebaseBackend,
        projectStore: ProjectStore,
        operativeStore: OperativeStore,
        subcontractorStore: SubcontractorStore,
        taskStore: ProjectTaskStore,
        holidayStore: HolidayStore,
        userStore: UserStore? = nil
    ) {
        #if DEBUG
        if UITestingMode.shouldSkipNetworkBootstrap { return }
        #endif
        guard firebaseBackend.isAuthenticated,
              firebaseBackend.hasBootstrappedOrgDataLoad,
              let organizationId = firebaseBackend.currentOrganization?.firestoreDocumentId,
              !organizationId.isEmpty else { return }
        // A launch, foreground return or organisation switch starts listener retries afresh.
        LiveListenerClock.shared.resetFailures(organizationId: organizationId)
        holidayStore.startLiveUpdates(organizationId: organizationId)
        projectStore.startLiveUpdates(organizationId: organizationId)
        operativeStore.startLiveUpdates(organizationId: organizationId)
        subcontractorStore.startLiveUpdates(organizationId: organizationId)
        taskStore.startLiveUpdates(organizationId: organizationId)
        firebaseBackend.startDismissedWarningsListener(organizationId: organizationId)
        // RULEBOOK §1: the roster is live too (before 13 Nov one roster listener failure was never retried).
        userStore?.ensureOrganizationUsersLive()
        // RULEBOOK 1.38.0 §27: the "open" data check, once these listeners have had time to load.
        DataParityMonitor.shared.listenersAttached()
        scheduleStaleCacheWatchdog(
            organizationId: organizationId,
            firebaseBackend: firebaseBackend,
            projectStore: projectStore,
            operativeStore: operativeStore,
            subcontractorStore: subcontractorStore,
            userStore: userStore
        )
    }

    /// RULEBOOK §1: "a cache may give the first paint; it is never the only read". Owner report 13 Nov: the people
    /// lists were a cached copy with no listener delivering, so booked catalogue operatives read "Unknown person" until
    /// a relaunch. `LiveListenerAttachPolicy.needsServerRead` grace seconds after the listeners are attached, a list
    /// that has had no server snapshot (or no listener) is read from the server once; the read attaches what is missing.
    @MainActor
    private static func scheduleStaleCacheWatchdog(
        organizationId: String,
        firebaseBackend: FirebaseBackend,
        projectStore: ProjectStore,
        operativeStore: OperativeStore,
        subcontractorStore: SubcontractorStore,
        userStore: UserStore?
    ) {
        let grace: TimeInterval = 20
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64((grace + 1) * 1_000_000_000))
            guard firebaseBackend.isAuthenticated,
                  organizationIdsMatch(firebaseBackend.currentOrganization?.firestoreDocumentId, organizationId) else { return }
            let clock = LiveListenerClock.shared
            let online = operativeStore.deviceOnline
            let now = Date()
            if LiveListenerAttachPolicy.needsServerRead(
                attachedAt: clock.attachedAt(key: "operatives", organizationId: organizationId),
                lastServerSnapshotAt: clock.lastServerSnapshotAt(key: "operatives", organizationId: organizationId),
                online: online,
                now: now,
                grace: grace
            ) {
                NSLog("STALE_CACHE_SERVER_READ collection=operatives org=%@", organizationId)
                operativeStore.loadData()
                operativeStore.startLiveUpdates(organizationId: organizationId)
            }
            // The roster: no listener, or a listener that never had a server snapshot (cache only).
            if let userStore, LiveListenerAttachPolicy.needsServerRead(
                attachedAt: userStore.organizationUsersListenerAttached(organizationId: organizationId)
                    ? clock.attachedAt(key: "users", organizationId: organizationId) ?? now.addingTimeInterval(-grace)
                    : nil,
                lastServerSnapshotAt: clock.lastServerSnapshotAt(key: "users", organizationId: organizationId),
                online: online,
                now: now,
                grace: grace
            ) {
                NSLog("STALE_CACHE_SERVER_READ collection=users org=%@", organizationId)
                if userStore.organizationUsersListenerAttached(organizationId: organizationId) {
                    Task { await userStore.loadOrganizationUsers(forceRefresh: true) }
                } else {
                    userStore.ensureOrganizationUsersLive()
                }
            }
            // The organisation settings document (working hours, warning settings, payment runs, …).
            if LiveListenerAttachPolicy.needsServerRead(
                attachedAt: clock.attachedAt(key: "organization", organizationId: organizationId),
                lastServerSnapshotAt: clock.lastServerSnapshotAt(key: "organization", organizationId: organizationId),
                online: online,
                now: now,
                grace: grace
            ) {
                NSLog("STALE_CACHE_SERVER_READ collection=organization org=%@", organizationId)
                firebaseBackend.reattachOrganizationDocumentListenerIfCurrent(organizationId: organizationId)
            }
            // Planned listeners retry their own failed parts; this only attaches one that is missing. A recorded
            // listener, even a slow one, is left alone (never two listeners for one key, no needless re-listen).
            for key in LiveListenerAttachPolicy.plannedWatchdogKeys {
                let recorded = DataParityListenerLedger.shared.snapshot(key: key, organizationId: organizationId)
                guard LiveListenerAttachPolicy.plannedListenerNeedsReattach(
                    listenerRecorded: recorded != nil,
                    online: online
                ) else { continue }
                NSLog("STALE_CACHE_SERVER_READ collection=%@ org=%@ listener=missing", key, organizationId)
                switch key {
                case "projects", "smallWorks":
                    // A no-op for the slice already attached (`needsAttach`).
                    projectStore.startLiveUpdates(organizationId: organizationId)
                case "subcontractorBookings":
                    subcontractorStore.startLiveUpdates(organizationId: organizationId)
                default:
                    // Bookings and manager site bookings: their stores asked for them; with no request yet there is
                    // nothing to attach here (the store attaches it when it loads).
                    firebaseBackend.reattachScheduleListenerForDataCheck(collection: key)
                }
            }
        }
    }

    /// Single-flight org data load from the root shell (ContentView must not repeat this on appear).
    @MainActor
    static func bootstrapOrgDataIfNeeded(
        firebaseBackend: FirebaseBackend,
        userStore: UserStore,
        projectStore: ProjectStore,
        operativeStore: OperativeStore,
        bookingStore: BookingStore,
        managerScheduleStore: ManagerScheduleStore,
        subcontractorStore: SubcontractorStore,
        taskStore: ProjectTaskStore,
        holidayStore: HolidayStore,
        notificationService: NotificationService
    ) async {
        #if DEBUG
        if UITestingMode.shouldSkipNetworkBootstrap {
            print("UITestingMode: skipping network bootstrap")
            return
        }
        #endif
        guard firebaseBackend.isAuthenticated else { return }
        guard !userStore.isDeactivatedForLastUsedOrganization else {
            print("🔥🔥🔥 DEBUG: bootstrapOrgDataIfNeeded skipped — account deactivated for last-used organisation")
            return
        }
        // Claim the lock before any await so a second caller cannot pass the guard while we wait for org.
        if firebaseBackend.hasBootstrappedOrgDataLoad || firebaseBackend.isBootstrappingOrgDataLoad {
            print("🔥🔥🔥 DEBUG: bootstrapOrgDataIfNeeded skipped (hasBootstrapped=\(firebaseBackend.hasBootstrappedOrgDataLoad), inFlight=\(firebaseBackend.isBootstrappingOrgDataLoad))")
            return
        }
        firebaseBackend.isBootstrappingOrgDataLoad = true
        defer { firebaseBackend.isBootstrappingOrgDataLoad = false }

        // Disk jobs can paint while the organisation document is still in flight.
        await projectStore.warmLocalCacheForLaunch()

        var profileWait = 0
        while userStore.currentUser == nil && Auth.auth().currentUser != nil && profileWait < 60 {
            try? await Task.sleep(nanoseconds: 50_000_000)
            profileWait += 1
        }
        guard !userStore.isDeactivatedForLastUsedOrganization else {
            print("🔥🔥🔥 DEBUG: bootstrapOrgDataIfNeeded skipped after profile wait — account deactivated")
            return
        }

        var waitCount = 0
        if firebaseBackend.currentOrganization == nil {
            print("🔥🔥🔥 DEBUG: Waiting for organization to load...")
        }
        while firebaseBackend.currentOrganization == nil && waitCount < 50 {
            try? await Task.sleep(nanoseconds: 100_000_000)
            waitCount += 1
        }

        if firebaseBackend.currentOrganization == nil {
            print("🔥🔥🔥 DEBUG: ⚠️ Organization not loaded after waiting, attempting recovery...")
            if userStore.isDeactivatedForLastUsedOrganization {
                print("🔥🔥🔥 DEBUG: Skipping org recovery — account deactivated for last-used organisation")
                return
            }
            if let userId = firebaseBackend.currentUser?.uid,
               let userEmail = firebaseBackend.currentUser?.email {
                let recovered = await firebaseBackend.recoverMissingOrganizationLink(userId: userId, userEmail: userEmail)
                if !recovered {
                    print("🔥🔥🔥 DEBUG: ❌ Could not recover organization - data may not load")
                    return
                }
            } else {
                return
            }
        }

        // Another path may have finished bootstrap while we waited/recovered.
        if firebaseBackend.hasBootstrappedOrgDataLoad {
            print("🔥🔥🔥 DEBUG: bootstrapOrgDataIfNeeded aborted after wait — already bootstrapped")
            return
        }

        guard let organizationId = firebaseBackend.currentOrganization?.firestoreDocumentId else { return }
        WarningsService.shared.adoptOrganization(organizationId)
        firebaseBackend.hasBootstrappedOrgDataLoad = true
        print("🔥🔥🔥 DEBUG: ✅ Organization loaded, starting single-flight data bootstrap...")

        // Home-critical stores first (projects / operatives / bookings / tasks).
        // Holidays + subcontractors are deferred: awaiting them on this path hung launch
        // (writable-org repair + weekend purge) and blocked the MainActor after TaskStore.
        projectStore.loadData()
        operativeStore.loadData()
        bookingStore.loadData()

        await Task.yield()
        managerScheduleStore.loadData()
        await taskStore.loadData()
        await Task.yield()

        print("🔥🔥🔥 DEBUG: ✅ Home-critical org bootstrap finished (projects/operatives/bookings/tasks kicked)")
        // RULEBOOK §1: keep the shared collections live from now on, not only after the deferred holiday and
        // subcontractor loads below finish (a hang there left every listener unattached). Attaching again later is a
        // no-op for a listener already attached.
        startOrgLiveListeners(
            firebaseBackend: firebaseBackend,
            projectStore: projectStore,
            operativeStore: operativeStore,
            subcontractorStore: subcontractorStore,
            taskStore: taskStore,
            holidayStore: holidayStore,
            userStore: userStore
        )

        // Keep Home/warnings/reminders quiet while secondary loads land and UI settles.
        firebaseBackend.launchQuietUntil = Date().addingTimeInterval(30)
        print("🔥🔥🔥 DEBUG: Launch quiet period until \(firebaseBackend.launchQuietUntil?.description ?? "nil")")

        // Secondary collections: do not await on the launch path.
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            print("🔥🔥🔥 DEBUG: Starting deferred holiday load...")
            await holidayStore.loadData()
            print("🔥🔥🔥 DEBUG: Deferred holiday load finished; starting subcontractors...")
            try? await Task.sleep(nanoseconds: 500_000_000)
            await subcontractorStore.loadData()
            print("🔥🔥🔥 DEBUG: ✅ Deferred secondary org loads finished")
            // Then keep every shared collection live (a web edit shows without a pull-to-refresh).
            guard organizationIdsMatch(firebaseBackend.currentOrganization?.firestoreDocumentId, organizationId) else { return }
            startOrgLiveListeners(
                firebaseBackend: firebaseBackend,
                projectStore: projectStore,
                operativeStore: operativeStore,
                subcontractorStore: subcontractorStore,
                taskStore: taskStore,
                holidayStore: holidayStore,
                userStore: userStore
            )
        }

        print("🔥🔥🔥 DEBUG: ✅ Org data bootstrap requests finished")

        // Inbox listener only (newest 150 notification docs). Not a company-data refresh.
        // A few seconds after Home's critical loads so the bell updates without the user refreshing.
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            print("🔥🔥🔥 DEBUG: Starting notification inbox listener…")
            notificationService.startInboxListenerIfNeeded()
        }
    }
}

struct ProjectPlannerRootView: View {
    let appDelegate: AppDelegate

    @EnvironmentObject private var firebaseBackend: FirebaseBackend
    @EnvironmentObject private var smartCache: SmartCacheService
    @EnvironmentObject private var projectStore: ProjectStore
    @EnvironmentObject private var operativeStore: OperativeStore
    @EnvironmentObject private var bookingStore: BookingStore
    @EnvironmentObject private var managerScheduleStore: ManagerScheduleStore
    @EnvironmentObject private var userStore: UserStore
    @EnvironmentObject private var taskStore: ProjectTaskStore
    @EnvironmentObject private var holidayStore: HolidayStore
    @EnvironmentObject private var subcontractorStore: SubcontractorStore
    @EnvironmentObject private var appSettings: AppSettingsStore
    @EnvironmentObject private var notificationService: NotificationService
    @EnvironmentObject private var appLock: AppLockService
    @Environment(\.scenePhase) private var scenePhase
    /// `platformConfig/app.minimumIosBuild`: blocks an outdated build with "Update required". Never blocks on a failed read.
    @StateObject private var forcedUpdate = ForcedUpdateGate()
    /// Set once a cached "not accepted" copy has waited `LegalGateState.cacheGraceSeconds` for the server copy; cleared
    /// when a server copy or another person arrives, so each cache-only phase gets its own grace period.
    @State private var legalCacheGraceExpired = false
    /// The legal gate's ticks, kept while the gate is rebuilt (`PolicyAcceptanceDraft`).
    @StateObject private var legalAcceptanceDraft = PolicyAcceptanceDraft()

    /// Kept in sync with notifications only; routing uses `Auth` + `firebaseBackend` so we never sit on an empty “session” gate.
    @State private var firebaseAuthUID: String?
    /// Only covers the shell while an organisation switch is in progress.
    /// Bumps only when the signed-in user moves from one organisation to another.
    /// Keying ContentView on the first nil → org id remounted Home and ran startup twice.
    @State private var contentShellEpoch = 0

    /// Prefer backend flag first so we’re not gated on `FirebaseApp.app()` before `ensureFirebaseAppConfigured()` runs; only then read Auth.
    private var showMainExperience: Bool {
        if firebaseBackend.isAuthenticated { return true }
        guard FirebaseApp.app() != nil else { return false }
        return Auth.auth().currentUser != nil
    }

    /// Launch must not cover Home. A full-screen logo on the first frames left a white window.
    /// This cover is only for an organisation switch, after Home is already on screen.
    private var showSplash: Bool {
        firebaseBackend.isSwitchingOrganization
    }

    @State private var lockWindow = AppLockWindowPresenter()

    /// The privacy cover hides bookings in the app switcher. Not while our own Face ID prompt is up,
    /// which also makes the scene inactive.
    private var lockOverlay: AppLockOverlay {
        guard showMainExperience else { return .none }
        if appLock.isLocked { return .locked }
        if appLock.isEnabled && !appLock.isAuthenticating && scenePhase != .active { return .privacy }
        return .none
    }

    /// Who the lock preference belongs to on this device.
    private var lockOwnerID: String? {
        if let uid = firebaseAuthUID, !uid.isEmpty { return uid }
        #if DEBUG
        if UITestingMode.isEnabled, let role = UITestingMode.autoLoginRole { return "uitest-\(role)" }
        #endif
        return nil
    }

    private func activateAppLockIfSignedIn() {
        guard let owner = lockOwnerID else { return }
        #if DEBUG
        // UI test launches start unlocked unless a test asks for the lock.
        if UITestingMode.isEnabled, !CommandLine.arguments.contains("-keepAppLock") {
            UserDefaults.standard.removeObject(forKey: AppLockPolicy.enabledKey(uid: owner))
        }
        #endif
        appLock.activate(uid: owner)
        #if DEBUG
        if CommandLine.arguments.contains("-showAppLockOffer") { appLock.forceSignInOfferForPreview() }
        #endif
    }

    /// `AppUser.legalGateState` for the profile on screen (nil profile: the app shell decides as before).
    private var legalGateState: LegalGateState {
        userStore.currentUser?.legalGateState(
            isOnline: smartCache.isOnline,
            cacheGraceExpired: legalCacheGraceExpired
        ) ?? .open
    }

    /// Changes when the profile on screen changes person or moves between a cached and a server copy.
    private var legalCacheGraceKey: String {
        guard let user = userStore.currentUser else { return "" }
        return "\(user.id)|\(user.readFromLocalCache)"
    }

    @ViewBuilder
    private var authenticatedShell: some View {
        if userStore.isDeactivatedForLastUsedOrganization {
            AccountDeactivatedView()
                .environmentObject(firebaseBackend)
                .environmentObject(userStore)
        } else if let organization = firebaseBackend.currentOrganization,
                  organization.deletionState.isLocked,
                  !CanonicalBusinessEngine.isPlatformOwnerEmail(userStore.currentUser?.email) {
            // RULEBOOK 1.15.0 §20 `organizationDeletionState`: a scheduled or erased organisation is locked for every
            // member (the security rules refuse its data); only the message, Sign out and Switch organisation.
            OrganizationDeletedView(organization: organization)
                .environmentObject(firebaseBackend)
                .environmentObject(userStore)
        } else if let organization = firebaseBackend.currentOrganization,
                  organization.subscriptionAccess(viewer: userStore.currentUser) != .open {
            // RULEBOOK 1.13.0 §19 `subscriptionAccess`: blocked for everyone; iOS has no billing screen, so an admin
            // (`adminBillingOnly`) sees the same block and only `SUBSCRIPTION_LAPSED_MESSAGE` (1.14.0 §19).
            SubscriptionLapsedView()
                .environmentObject(firebaseBackend)
                .environmentObject(userStore)
        } else if firebaseBackend.sessionHasNoOrganization && firebaseBackend.currentOrganization == nil {
            NoOrganisationView()
                .environmentObject(firebaseBackend)
                .environmentObject(userStore)
        } else if legalGateState == .gate {
            // `legalPackNeedsAcceptance`: not accepted, or an older pack accepted. Decided only from a profile read
            // from `users/{uid}`; the launch placeholder never flashes the gate (`AppUser.legalGateState`).
            PolicyAcceptanceView(draft: legalAcceptanceDraft)
                .environmentObject(firebaseBackend)
                .environmentObject(userStore)
        } else if legalGateState == .checking {
            // A cached copy says acceptance is needed: wait for the server copy, never open the app on it. After the
            // grace period the cached copy decides (fail closed).
            LegalGateCheckingView()
                .task(id: userStore.currentUser?.id) {
                    try? await Task.sleep(nanoseconds: UInt64(LegalGateState.cacheGraceSeconds * 1_000_000_000))
                    if !Task.isCancelled { legalCacheGraceExpired = true }
                }
        } else {
            VStack(spacing: 0) {
                OfflineStatusBanner()
                ContentView()
                    .id(contentShellEpoch)
            }
                .sheet(isPresented: $appLock.showSignInOffer, onDismiss: appLock.dismissSignInOffer) {
                    AppLockSignInOfferView()
                        .environmentObject(appLock)
                }
                .environmentObject(firebaseBackend)
                .environmentObject(smartCache)
                .environmentObject(projectStore)
                .environmentObject(operativeStore)
                .environmentObject(bookingStore)
                .environmentObject(managerScheduleStore)
                .environmentObject(userStore)
                .environmentObject(taskStore)
                .environmentObject(holidayStore)
                .environmentObject(subcontractorStore)
                .environmentObject(appSettings)
                .environmentObject(notificationService)
                .environmentObject(appLock)
                .appColorScheme(appSettings.settings.colorScheme)
        }
    }

    var body: some View {
        ZStack {
            if showMainExperience {
                authenticatedShell
            } else {
                AuthenticationView()
                    .environmentObject(firebaseBackend)
                    .environmentObject(userStore)
            }
            if showSplash {
                AppLaunchSplashView()
                    .zIndex(1)
            }
            if forcedUpdate.updateRequired {
                ForcedUpdateView()
                    .zIndex(2)
            }
        }
        .task { await forcedUpdate.check() }
        .onChange(of: legalCacheGraceKey) { _, _ in
            // A server copy, or another signed-in person, ends the cache-only phase: the next one waits afresh.
            legalCacheGraceExpired = false
        }
        .onChange(of: firebaseAuthUID) { _, _ in
            // RULEBOOK 1.12.0 §18: `platformConfig/app` is readable signed out too; check again when the account changes.
            Task { await forcedUpdate.check() }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(ProjectWorksRevampColors.canvas)
        .onReceive(NotificationCenter.default.publisher(for: .plannerHomeDidDraw)) { _ in
            print("🔥🔥🔥 DEBUG: PP_LAUNCH_VISIBLE home")
        }
        .onChange(of: lockOverlay, initial: true) { _, overlay in
            lockWindow.update(overlay) {
                AppLockView()
                    .environmentObject(appLock)
                    .environmentObject(firebaseBackend)
                    .environmentObject(userStore)
            } privacy: {
                AppPrivacyCover()
            }
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .background: appLock.appDidEnterBackground()
            case .active:
                appLock.appDidBecomeActive()
                Task { await forcedUpdate.check() }
                // RULEBOOK 1.38.0 §27: the silent data check on return to the foreground (throttled by the rule).
                DataParityMonitor.shared.appBecameActive()
            default: break
            }
        }
        .onChange(of: firebaseBackend.isAuthenticated) { _, signedIn in
            guard !signedIn else { return }
            #if DEBUG
            if UITestingMode.isEnabled, UITestingMode.autoLoginRole != nil { return }
            #endif
            guard FirebaseApp.app() != nil else { return }
            // Listener / startup can briefly report signed-out before Keychain catches up — don’t wipe profile or you get a blank main shell.
            if Auth.auth().currentUser != nil {
                firebaseBackend.syncPublishedAuthFromAuthSession()
                return
            }
            userStore.clearOnSignOut()
            appLock.deactivate()
        }
        .onReceive(NotificationCenter.default.publisher(for: .firebaseAuthUIDChanged)) { note in
            if let uid = note.userInfo?["uid"] as? String, !uid.isEmpty {
                firebaseAuthUID = uid
                activateAppLockIfSignedIn()
                print("🔥🔥🔥 DEBUG: RootView auth uid → \(uid)")
            } else {
                if FirebaseApp.app() != nil, Auth.auth().currentUser != nil {
                    firebaseAuthUID = Auth.auth().currentUser?.uid
                    print("🔥🔥🔥 DEBUG: RootView ignored spurious auth clear notification; Firebase session still present")
                    return
                }
                #if DEBUG
                if UITestingMode.isEnabled, UITestingMode.autoLoginRole != nil { return }
                #endif
                firebaseAuthUID = nil
                userStore.clearOnSignOut()
                appLock.deactivate()
                print("🔥🔥🔥 DEBUG: RootView auth uid cleared (signed out)")
            }
        }
        .onAppear {
            // Wire stores before any async profile load so `loadCurrentUser()` never no-ops with “FirebaseBackend not wired yet”.
            PlannerStoreWiring.connectIfNeeded(
                firebaseBackend: firebaseBackend,
                smartCache: smartCache,
                projectStore: projectStore,
                operativeStore: operativeStore,
                bookingStore: bookingStore,
                managerScheduleStore: managerScheduleStore,
                userStore: userStore,
                taskStore: taskStore,
                holidayStore: holidayStore,
                subcontractorStore: subcontractorStore,
                notificationService: notificationService,
                appSettings: appSettings
            )

            firebaseBackend.syncPublishedAuthFromAuthSession()
            if FirebaseApp.app() != nil {
                firebaseAuthUID = firebaseAuthUID ?? Auth.auth().currentUser?.uid
            }
            activateAppLockIfSignedIn()
            print("🔥🔥🔥 DEBUG: RootView onAppear — auth uid: \(firebaseAuthUID ?? "nil"), backend.isAuthenticated: \(firebaseBackend.isAuthenticated), showMain: \(showMainExperience), profileLoading: \(userStore.isHomeProfileLoading), defaultApp: \(FirebaseApp.app() != nil)")

            appDelegate.onPushToken = { token in
                Task {
                    await firebaseBackend.registerPushToken(token)
                }
            }
            appDelegate.foregroundNotificationHandler = { isRemote, type in
                notificationService.foregroundPresentationOptions(isRemote: isRemote, type: type)
            }

            appSettings.setupObservers()
            // Do not call applyToKeyWindows here. Setting the window style during the first
            // frame replaces the logo with a black window.
            if showMainExperience {
                userStore.unblockLaunchProfileIfNeeded()
            }
            print("🔥🔥🔥 DEBUG: PP splash off user=\(userStore.currentUser != nil) showMain=\(showMainExperience)")
            Task { @MainActor in
                await firebaseBackend.syncAuthStateFromSessionIfNeeded()
                if userStore.currentUser == nil {
                    userStore.unblockLaunchProfileIfNeeded()
                }
                async let profilePass: Void = loadLaunchProfile()
                async let bootstrapPass: Void = PlannerStoreWiring.bootstrapOrgDataIfNeeded(
                    firebaseBackend: firebaseBackend,
                    userStore: userStore,
                    projectStore: projectStore,
                    operativeStore: operativeStore,
                    bookingStore: bookingStore,
                    managerScheduleStore: managerScheduleStore,
                    subcontractorStore: subcontractorStore,
                    taskStore: taskStore,
                    holidayStore: holidayStore,
                    notificationService: notificationService
                )
                await profilePass
                await bootstrapPass
            }
        }
        .onChange(of: firebaseBackend.currentOrganization?.firestoreDocumentId) { oldId, newId in
            // RULEBOOK §13: save this device's push token whenever the organisation loads (a device-owned field).
            if newId != nil {
                Task { await firebaseBackend.reregisterPushTokenIfAvailable() }
            }
            guard let oldId, let newId, oldId != newId else { return }
            contentShellEpoch += 1
        }
        .onChange(of: userStore.currentUser?.id) { _, userId in
            // RULEBOOK §13: on sign-in and each time the signed-in user loads, save this device's push token to their
            // own users document — not only when Firebase calls back with a new token (that can happen before sign-in).
            guard let userId, !userId.isEmpty else { return }
            Task { await firebaseBackend.reregisterPushTokenIfAvailable() }
        }
        .onChange(of: firebaseBackend.organizationSwitchToken) { _, token in
            guard token != nil else { return }
            Task { @MainActor in
                await performQueuedOrganizationSwitch()
            }
        }
        .alert(
            "Couldn't switch organisation",
            isPresented: Binding(
                get: { firebaseBackend.organizationSwitchErrorMessage != nil },
                set: { if !$0 { firebaseBackend.organizationSwitchErrorMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) {
                firebaseBackend.organizationSwitchErrorMessage = nil
            }
                .accessibilityIdentifier("projectPlannerRoot.ok")
        } message: {
            Text(firebaseBackend.organizationSwitchErrorMessage ?? "")
        }
        .onChange(of: userStore.isDeactivatedForLastUsedOrganization) { _, isDeactivated in
            guard !isDeactivated, firebaseBackend.isAuthenticated else { return }
            guard !firebaseBackend.isSwitchingOrganization else { return }
            Task { @MainActor in
                await PlannerStoreWiring.bootstrapOrgDataIfNeeded(
                    firebaseBackend: firebaseBackend,
                    userStore: userStore,
                    projectStore: projectStore,
                    operativeStore: operativeStore,
                    bookingStore: bookingStore,
                    managerScheduleStore: managerScheduleStore,
                    subcontractorStore: subcontractorStore,
                    taskStore: taskStore,
                    holidayStore: holidayStore,
                    notificationService: notificationService
                )
            }
        }
    }

    @MainActor
    private func loadLaunchProfile() async {
        if firebaseBackend.isAuthenticated {
            await userStore.loadCurrentUser()
        }
        print("🔥🔥🔥 DEBUG: RootView profile pass done — currentUser: \(userStore.currentUser != nil ? "yes" : "no")")
    }

    @MainActor
    private func performQueuedOrganizationSwitch() async {
        guard let targetId = firebaseBackend.organizationSwitchTargetId, !targetId.isEmpty else {
            firebaseBackend.isSwitchingOrganization = false
            return
        }
        firebaseBackend.organizationSwitchTargetId = nil
        firebaseBackend.isSwitchingOrganization = true
        defer { firebaseBackend.isSwitchingOrganization = false }

        do {
            try await firebaseBackend.switchActiveOrganization(to: targetId)
            userStore.roleTestingPreset = nil
            userStore.showCachedRoster(for: targetId)
            await userStore.loadCurrentUser()

            guard !userStore.isDeactivatedForLastUsedOrganization else { return }

            WarningsService.shared.adoptOrganization(targetId)
            WarningsRefreshHelper.prepareForOrganizationSwitch()
            await userStore.loadOrganizationUsers()

            firebaseBackend.suppressStaleOrganizationCache = true
            projectStore.discardInMemoryForOrganizationSwitch()
            operativeStore.discardInMemoryForOrganizationSwitch()
            bookingStore.discardInMemoryForOrganizationSwitch()
            managerScheduleStore.discardInMemoryForOrganizationSwitch()
            holidayStore.bookings = []
            subcontractorStore.subcontractors = []
            subcontractorStore.bookings = []
            taskStore.discardInMemoryForOrganizationSwitch()
            notificationService.discardForOrganizationSwitch()
            appSettings.loadSettings()

            await PlannerStoreWiring.bootstrapOrgDataIfNeeded(
                firebaseBackend: firebaseBackend,
                userStore: userStore,
                projectStore: projectStore,
                operativeStore: operativeStore,
                bookingStore: bookingStore,
                managerScheduleStore: managerScheduleStore,
                subcontractorStore: subcontractorStore,
                taskStore: taskStore,
                holidayStore: holidayStore,
                notificationService: notificationService
            )

            try? await Task.sleep(nanoseconds: 400_000_000)
            var spins = 0
            while spins < 60 {
                let busy = firebaseBackend.isBootstrappingOrgDataLoad
                    || projectStore.isLoading
                    || operativeStore.isLoading
                    || bookingStore.isLoading
                    || taskStore.isLoading
                    || managerScheduleStore.isLoading
                    || holidayStore.isLoading
                if !busy { break }
                try? await Task.sleep(nanoseconds: 200_000_000)
                spins += 1
            }
            await holidayStore.loadData()
            spins = 0
            while holidayStore.isLoading && spins < 30 {
                try? await Task.sleep(nanoseconds: 200_000_000)
                spins += 1
            }
            _ = await WarningsRefreshHelper.refreshSharedWarnings(
                operativeStore: operativeStore,
                bookingStore: bookingStore,
                projectStore: projectStore,
                userStore: userStore,
                managerScheduleStore: managerScheduleStore,
                holidayStore: holidayStore,
                firebaseBackend: firebaseBackend,
                appSettings: appSettings,
                force: true,
                bypassLaunchQuiet: true
            )
            firebaseBackend.suppressStaleOrganizationCache = false
        } catch {
            firebaseBackend.suppressStaleOrganizationCache = false
            firebaseBackend.organizationSwitchErrorMessage = error.localizedDescription
        }
    }
}
