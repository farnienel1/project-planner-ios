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
        subcontractorStore.setFirebaseBackend(firebaseBackend)

        notificationService.setFirebaseBackend(firebaseBackend)
        notificationService.setUserStore(userStore)
        notificationService.setOperativeStore(operativeStore)
        notificationService.setProjectStore(projectStore)
        notificationService.setAppSettingsStore(appSettings)
        notificationService.setHolidayStore(holidayStore)

        appSettings.setFirebaseBackend(firebaseBackend)
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
        }

        print("🔥🔥🔥 DEBUG: ✅ Org data bootstrap requests finished")

        // Do NOT load the full notifications collection here. Large orgs (100–200+ docs)
        // plus a live listener jetsam the Simulator on launch. Notifications load on demand
        // from NotificationsView; unread badge warms after a long idle delay.
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 35_000_000_000)
            print("🔥🔥🔥 DEBUG: Warming unread notification badge (post-quiet)…")
            await notificationService.warmUnreadBadgeIfNeeded()
            print("🔥🔥🔥 DEBUG: Unread badge warm finished")
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

    /// Kept in sync with notifications only; routing uses `Auth` + `firebaseBackend` so we never sit on an empty “session” gate.
    @State private var firebaseAuthUID: String?
    /// Avoid flashing the login screen while Firebase session / profile are still resolving.
    @State private var hasResolvedInitialAuth = false
    /// Bumps only when the signed-in user moves from one organisation to another.
    /// Keying ContentView on the first nil → org id remounted Home and ran startup twice.
    @State private var contentShellEpoch = 0

    /// Prefer backend flag first so we’re not gated on `FirebaseApp.app()` before `ensureFirebaseAppConfigured()` runs; only then read Auth.
    private var showMainExperience: Bool {
        if firebaseBackend.isAuthenticated { return true }
        guard FirebaseApp.app() != nil else { return false }
        return Auth.auth().currentUser != nil
    }

    private var isSessionLoading: Bool {
        if firebaseBackend.isSwitchingOrganization { return true }
        return !hasResolvedInitialAuth
    }

    @ViewBuilder
    private var authenticatedShell: some View {
        if userStore.isDeactivatedForLastUsedOrganization {
            AccountDeactivatedView()
                .environmentObject(firebaseBackend)
                .environmentObject(userStore)
        } else if let currentUser = userStore.currentUser, !currentUser.policyAccepted {
            PolicyAcceptanceView()
                .environmentObject(firebaseBackend)
                .environmentObject(userStore)
        } else {
            VStack(spacing: 0) {
                OfflineStatusBanner()
                ContentView()
                    .id(contentShellEpoch)
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
                .appColorScheme(appSettings.settings.colorScheme)
        }
    }

    var body: some View {
        ZStack {
            ProjectWorksRevampColors.canvas.ignoresSafeArea()
            if hasResolvedInitialAuth && showMainExperience {
                authenticatedShell
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if hasResolvedInitialAuth {
                AuthenticationView()
                    .environmentObject(firebaseBackend)
                    .environmentObject(userStore)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            AppLaunchSplashView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .opacity(isSessionLoading ? 1 : 0)
                .allowsHitTesting(isSessionLoading)
                .accessibilityHidden(!isSessionLoading)
                .zIndex(1)
        }
        .background(ProjectWorksRevampColors.canvas)
        .onReceive(NotificationCenter.default.publisher(for: .plannerHomeDidDraw)) { _ in
            print("🔥🔥🔥 DEBUG: PP_LAUNCH_VISIBLE home")
        }
        .onChange(of: firebaseBackend.isAuthenticated) { _, signedIn in
            guard !signedIn else { return }
            guard FirebaseApp.app() != nil else { return }
            // Listener / startup can briefly report signed-out before Keychain catches up — don’t wipe profile or you get a blank main shell.
            if Auth.auth().currentUser != nil {
                firebaseBackend.syncPublishedAuthFromAuthSession()
                return
            }
            userStore.clearOnSignOut()
        }
        .onReceive(NotificationCenter.default.publisher(for: .firebaseAuthUIDChanged)) { note in
            if let uid = note.userInfo?["uid"] as? String, !uid.isEmpty {
                firebaseAuthUID = uid
                print("🔥🔥🔥 DEBUG: RootView auth uid → \(uid)")
            } else {
                if FirebaseApp.app() != nil, Auth.auth().currentUser != nil {
                    firebaseAuthUID = Auth.auth().currentUser?.uid
                    print("🔥🔥🔥 DEBUG: RootView ignored spurious auth clear notification; Firebase session still present")
                    return
                }
                firebaseAuthUID = nil
                hasResolvedInitialAuth = true
                userStore.clearOnSignOut()
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
            print("🔥🔥🔥 DEBUG: RootView onAppear — auth uid: \(firebaseAuthUID ?? "nil"), backend.isAuthenticated: \(firebaseBackend.isAuthenticated), showMain: \(showMainExperience), profileLoading: \(userStore.isHomeProfileLoading), defaultApp: \(FirebaseApp.app() != nil)")

            appDelegate.onPushToken = { token in
                Task {
                    await firebaseBackend.registerPushToken(token)
                }
            }

            appSettings.setupObservers()
            // Do not call applyToKeyWindows here. Setting the window style during the first
            // frame replaces the logo with a black window.
            if showMainExperience {
                userStore.unblockLaunchProfileIfNeeded()
            }
            // The logo already covered the first frame. Clear it before any Firestore work.
            // Waiting for the next main-queue turn left "Loading your jobs" up when that
            // queue was busy, until the system killed the app.
            hasResolvedInitialAuth = true
            print("🔥🔥🔥 DEBUG: PP splash off user=\(userStore.currentUser != nil) showMain=\(showMainExperience)")

            // Profile and org data start together. A fixed 1.5s pause left Home empty, then the
            // organisation wait added another half second before disk jobs could show.
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
            guard let oldId, let newId, oldId != newId else { return }
            contentShellEpoch += 1
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
