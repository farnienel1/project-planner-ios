//
//  Project_PlannerApp.swift
//  Project Planner
//
//  Created by Assistant on 29/09/2025.
//

import SwiftUI
import Firebase
import FirebaseAuth
#if canImport(FirebaseMessaging)
import FirebaseMessaging
#endif
import UIKit
import UserNotifications

final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    var onPushToken: ((String) -> Void)?

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        requestRemoteNotificationRegistration(application: application)
#if canImport(FirebaseMessaging)
        Messaging.messaging().delegate = self
#endif
        return true
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        // Ensure local notifications are shown as real banners while app is foregrounded.
        completionHandler([.banner, .sound, .badge, .list])
    }

    func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
#if canImport(FirebaseMessaging)
        Messaging.messaging().apnsToken = deviceToken
#endif
    }

    private func requestRemoteNotificationRegistration(application: UIApplication) {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge, .sound]) { granted, error in
            if let error {
                print("🔥🔥🔥 DEBUG: Push permission request failed: \(error.localizedDescription)")
                return
            }
            guard granted else {
                print("🔥🔥🔥 DEBUG: Push permission not granted")
                return
            }
            DispatchQueue.main.async {
                application.registerForRemoteNotifications()
            }
        }
    }
}

#if canImport(FirebaseMessaging)
extension AppDelegate: MessagingDelegate {
    func messaging(_ messaging: Messaging, didReceiveRegistrationToken fcmToken: String?) {
        guard let token = fcmToken, !token.isEmpty else { return }
        print("🔥🔥🔥 DEBUG: Received FCM token")
        onPushToken?(token)
    }
}
#endif

@main
struct Project_PlannerApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var firebaseBackend = FirebaseBackend()
    @StateObject private var smartCache = SmartCacheService()
    @StateObject private var projectStore = ProjectStore()
    @StateObject private var operativeStore = OperativeStore()
    @StateObject private var bookingStore = BookingStore()
    @StateObject private var managerScheduleStore = ManagerScheduleStore()
    @StateObject private var userStore = UserStore()
    @StateObject private var taskStore = ProjectTaskStore()
    @StateObject private var holidayStore = HolidayStore()
    @StateObject private var appSettings = AppSettingsStore()
    @StateObject private var notificationService = NotificationService()
    
    init() {
        // Configure Firebase
        FirebaseApp.configure()
        print("🔥🔥🔥 DEBUG: Firebase configured in Project_PlannerApp")
    }
    
    var body: some Scene {
        print("🔥🔥🔥 DEBUG: App body is being called!")
        return WindowGroup {
            Group {
                if firebaseBackend.isAuthenticated {
                    if firebaseBackend.shouldShowSetupFlow {
                        OrganisationSetupFlow()
                            .environmentObject(firebaseBackend)
                            .environmentObject(projectStore)
                            .environmentObject(operativeStore)
                            .environmentObject(userStore)
                            .environmentObject(taskStore)
                            .preferredColorScheme(.light) // Force light mode always
                            .onDisappear {
                                print("🔥🔥🔥 DEBUG: OrganisationSetupFlow disappeared, setting shouldShowSetupFlow to false")
                                firebaseBackend.shouldShowSetupFlow = false
                            }
                    } else {
                        // Check if user needs to accept privacy policy (first login or existing user who hasn't accepted)
                        // This will show for:
                        // 1. New users who haven't accepted yet
                        // 2. Existing users (like farnienelyt@gmail.com) who don't have policyAccepted set to true
                        if let currentUser = userStore.currentUser, !currentUser.policyAccepted {
                            PolicyAcceptanceView()
                                .environmentObject(firebaseBackend)
                                .environmentObject(userStore)
                        } else {
                            ContentView()
                                .environmentObject(firebaseBackend)
                                .environmentObject(projectStore)
                                .environmentObject(operativeStore)
                                .environmentObject(bookingStore)
                                .environmentObject(managerScheduleStore)
                                .environmentObject(userStore)
                                .environmentObject(taskStore)
                                .environmentObject(holidayStore)
                                .environmentObject(appSettings)
                                .environmentObject(notificationService)
                                .appColorScheme(appSettings.settings.colorScheme)
                                .preferredColorScheme(.light) // Force light mode always
                        }
                    }
                } else {
                        AuthenticationView()
                        .environmentObject(firebaseBackend)
                        .preferredColorScheme(.light) // Force light mode always
                }
            }
            .preferredColorScheme(.light) // Force light mode for entire app - overrides system settings
            .onAppear {
                print("🔥🔥🔥 DEBUG: App appeared - isAuthenticated: \(firebaseBackend.isAuthenticated), shouldShowSetupFlow: \(firebaseBackend.shouldShowSetupFlow)")
                
                // Force light mode at window level to override system settings
                DispatchQueue.main.async {
                    if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene {
                        windowScene.windows.forEach { window in
                            window.overrideUserInterfaceStyle = .light
                        }
                    }
                }
                
                // Set up smart cache for all stores
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

                notificationService.setFirebaseBackend(firebaseBackend)
                notificationService.setUserStore(userStore)
                notificationService.setOperativeStore(operativeStore)
                notificationService.setProjectStore(projectStore)
                notificationService.setAppSettingsStore(appSettings)
                notificationService.setHolidayStore(holidayStore)
                appDelegate.onPushToken = { token in
                    Task {
                        await firebaseBackend.registerPushToken(token)
                    }
                }
#if canImport(FirebaseMessaging)
                Messaging.messaging().token { token, error in
                    if let error {
                        print("🔥🔥🔥 DEBUG: Failed to fetch current FCM token: \(error.localizedDescription)")
                        return
                    }
                    guard let token, !token.isEmpty else { return }
                    Task {
                        await firebaseBackend.registerPushToken(token)
                    }
                }
#endif
                
                // Wait for organization to load, then load all data
                Task {
                    // Wait for organization to be loaded (with retries)
                    var waitCount = 0
                    while firebaseBackend.currentOrganization == nil && waitCount < 10 {
                        print("🔥🔥🔥 DEBUG: Waiting for organization to load... (\(waitCount + 1)/10)")
                        try? await Task.sleep(nanoseconds: 500_000_000) // 0.5 seconds
                        waitCount += 1
                    }
                    
                    if let organizationId = firebaseBackend.currentOrganization?.firestoreDocumentId {
                        print("🔥🔥🔥 DEBUG: ✅ Organization loaded: \(organizationId), starting data load...")
                        
                        // Load all data stores in parallel
                        projectStore.loadData()
                        operativeStore.loadData()
                        bookingStore.loadData()
                        managerScheduleStore.loadData()
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
                        print("🔥🔥🔥 DEBUG: Projects: \(projectStore.projects.count), Operatives: \(operativeStore.operatives.count), Managers: \(operativeStore.managers.count), Bookings: \(bookingStore.bookings.count), Tasks: \(taskStore.tasks.count)")
                    } else {
                        print("🔥🔥🔥 DEBUG: ⚠️ Organization not loaded after waiting, attempting recovery...")
                        // Try to trigger organization load
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
                                    await taskStore.loadData()
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
                
                // Set up observers for settings
                Task { @MainActor in
                    appSettings.setupObservers()
                }
            }
        }
    }
}