//
//  Project_PlannerApp.swift
//  Project Planner
//
//  Created by Assistant on 29/09/2025.
//

import SwiftUI
import FirebaseAuth
import FirebaseCore
#if canImport(FirebaseMessaging)
import FirebaseMessaging
#endif
import UIKit
import UserNotifications

extension Notification.Name {
    /// Main-thread only. `userInfo["uid"]` is a non-empty String when signed in; absent when signed out.
    static let firebaseAuthUIDChanged = Notification.Name("app.firebaseAuthUIDChanged")
}

/// Runs before any `@StateObject` on `App` — SwiftUI can construct those before `application(_:didFinishLaunchingWithOptions:)` returns.
/// **Xcode / plist:** follow `IOS_FIREBASE_XCODE_SETUP.md` in this folder so `GoogleService-Info.plist` is in the app bundle.
private enum FirebaseStartup {
    /// Xcode sometimes adds `GoogleService-Info 2.plist`; Firebase only auto-finds `GoogleService-Info.plist`.
    private static let googleServicePlistNames = ["GoogleService-Info", "GoogleService-Info 2"]

    @discardableResult
    static func configureIfNeeded() -> Bool {
        if FirebaseApp.app() != nil { return true }
        for name in googleServicePlistNames {
            if let path = Bundle.main.path(forResource: name, ofType: "plist"),
               let options = FirebaseOptions(contentsOfFile: path) {
                FirebaseApp.configure(options: options)
                print("🔥🔥🔥 DEBUG: Firebase configured from \(name).plist")
                let ok = FirebaseApp.app() != nil
                print("🔥🔥🔥 DEBUG: Firebase configureIfNeeded — defaultApp exists: \(ok)")
                return ok
            }
        }
        print("🔥🔥🔥 DEBUG: ⚠️ No GoogleService-Info plist in bundle (tried: \(googleServicePlistNames.joined(separator: ", "))). Add one with target membership, then clean build.")
        FirebaseApp.configure()
        let ok = FirebaseApp.app() != nil
        print("🔥🔥🔥 DEBUG: Firebase configureIfNeeded — defaultApp exists: \(ok)")
        return ok
    }
}

/// Subclass `NSObject` (not `UIResponder` alone) so GoogleUtilities’ Obj‑C swizzler sees a real `UIApplicationDelegate` and stops **I-SWZ001014** with `@UIApplicationDelegateAdaptor`.
final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    var onPushToken: ((String) -> Void)?
    private var firebaseAuthStateHandle: AuthStateDidChangeListenerHandle?

    /// Runs before `didFinishLaunching` — configures Firebase before Messaging / Auth swizzler touches the default app (fixes I-COR000003 noise and bad first-frame auth).
    func application(
        _ application: UIApplication,
        willFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        _ = FirebaseStartup.configureIfNeeded()
        print("🔥🔥🔥 DEBUG: Firebase configured in willFinishLaunching (defaultApp: \(FirebaseApp.app() != nil))")
        return true
    }

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        _ = FirebaseStartup.configureIfNeeded()
        print("🔥🔥🔥 DEBUG: Firebase ready in didFinishLaunching (defaultApp: \(FirebaseApp.app() != nil))")

        firebaseAuthStateHandle = Auth.auth().addStateDidChangeListener { _, user in
            DispatchQueue.main.async {
                if let uid = user?.uid, !uid.isEmpty {
                    NotificationCenter.default.post(name: .firebaseAuthUIDChanged, object: nil, userInfo: ["uid": uid])
                } else {
                    NotificationCenter.default.post(name: .firebaseAuthUIDChanged, object: nil, userInfo: [:])
                }
            }
        }

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

    init() {
        _ = FirebaseStartup.configureIfNeeded()
        // Avoid a plain white UIKit window before the first SwiftUI frame (especially during Firebase / store init).
        UIWindow.appearance().backgroundColor = UIColor.systemGroupedBackground
    }

    @StateObject private var firebaseBackend = FirebaseBackend()
    @StateObject private var smartCache = SmartCacheService()
    @StateObject private var projectStore = ProjectStore()
    @StateObject private var operativeStore = OperativeStore()
    @StateObject private var bookingStore = BookingStore()
    @StateObject private var managerScheduleStore = ManagerScheduleStore()
    @StateObject private var userStore = UserStore()
    @StateObject private var taskStore = ProjectTaskStore()
    @StateObject private var holidayStore = HolidayStore()
    @StateObject private var subcontractorStore = SubcontractorStore()
    @StateObject private var appSettings = AppSettingsStore()
    @StateObject private var notificationService = NotificationService()

    var body: some Scene {
        WindowGroup {
            ZStack {
                Color(.systemGroupedBackground).ignoresSafeArea()
                ProjectPlannerRootView(appDelegate: appDelegate)
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
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}
