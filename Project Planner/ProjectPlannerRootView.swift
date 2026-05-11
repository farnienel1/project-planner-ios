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

    /// Prefer backend flag first so we’re not gated on `FirebaseApp.app()` before `ensureFirebaseAppConfigured()` runs; only then read Auth.
    private var showMainExperience: Bool {
        if firebaseBackend.isAuthenticated { return true }
        guard FirebaseApp.app() != nil else { return false }
        return Auth.auth().currentUser != nil
    }

    var body: some View {
        ZStack {
            Color(.systemGroupedBackground).ignoresSafeArea()
            Group {
                if showMainExperience {
                    if firebaseBackend.shouldShowSetupFlow {
                        OrganisationSetupFlow()
                            .environmentObject(firebaseBackend)
                            .environmentObject(projectStore)
                            .environmentObject(operativeStore)
                            .environmentObject(userStore)
                            .environmentObject(taskStore)
                            .onDisappear {
                                print("🔥🔥🔥 DEBUG: OrganisationSetupFlow disappeared, setting shouldShowSetupFlow to false")
                                firebaseBackend.shouldShowSetupFlow = false
                            }
                    } else if let currentUser = userStore.currentUser, !currentUser.policyAccepted {
                        PolicyAcceptanceView()
                            .environmentObject(firebaseBackend)
                            .environmentObject(userStore)
                    } else {
                        ContentView()
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
                } else {
                    AuthenticationView()
                        .environmentObject(firebaseBackend)
                        .environmentObject(userStore)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .preferredColorScheme(.light)
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
            print("🔥🔥🔥 DEBUG: RootView onAppear — auth uid: \(firebaseAuthUID ?? "nil"), backend.isAuthenticated: \(firebaseBackend.isAuthenticated), showMain: \(showMainExperience), defaultApp: \(FirebaseApp.app() != nil)")

            Task {
                await firebaseBackend.syncAuthStateFromSessionIfNeeded()
                if firebaseBackend.isAuthenticated {
                    await userStore.loadCurrentUser()
                }
            }

            DispatchQueue.main.async {
                if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene {
                    windowScene.windows.forEach { window in
                        window.overrideUserInterfaceStyle = .light
                    }
                }

                appDelegate.onPushToken = { token in
                    Task {
                        await firebaseBackend.registerPushToken(token)
                    }
                }

                Task {
                    var waitCount = 0
                    while firebaseBackend.currentOrganization == nil && waitCount < 10 {
                        print("🔥🔥🔥 DEBUG: Waiting for organization to load... (\(waitCount + 1)/10)")
                        try? await Task.sleep(nanoseconds: 500_000_000)
                        waitCount += 1
                    }

                    if let organizationId = firebaseBackend.currentOrganization?.firestoreDocumentId {
                        print("🔥🔥🔥 DEBUG: ✅ Organization loaded: \(organizationId), starting data load...")

                        projectStore.loadData()
                        operativeStore.loadData()
                        bookingStore.loadData()
                        managerScheduleStore.loadData()
                        Task {
                            await subcontractorStore.loadData()
                        }
                        Task {
                            await taskStore.loadData()
                        }
                        Task {
                            await holidayStore.loadData()
                        }
                        Task {
                            await notificationService.loadNotifications()
                        }

                        print("🔥🔥🔥 DEBUG: ✅ All data loading complete!")
                    } else {
                        print("🔥🔥🔥 DEBUG: ⚠️ Organization not loaded after waiting, attempting recovery...")
                        if let userId = firebaseBackend.currentUser?.uid,
                           let userEmail = firebaseBackend.currentUser?.email {
                            let recovered = await firebaseBackend.recoverMissingOrganizationLink(userId: userId, userEmail: userEmail)
                            if recovered {
                                print("🔥🔥🔥 DEBUG: ✅ Organization recovered, loading data...")
                                projectStore.loadData()
                                operativeStore.loadData()
                                bookingStore.loadData()
                                managerScheduleStore.loadData()
                                Task {
                                    await subcontractorStore.loadData()
                                }
                                Task {
                                    await taskStore.loadData()
                                }
                                Task {
                                    await holidayStore.loadData()
                                }
                                Task {
                                    await notificationService.loadNotifications()
                                }
                            } else {
                                print("🔥🔥🔥 DEBUG: ❌ Could not recover organization - data may not load")
                            }
                        }
                    }
                }

                Task { @MainActor in
                    appSettings.setupObservers()
                }
            }
        }
    }
}
