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

/// Notification payloads are `[AnyHashable: Any]`, which is not Sendable. The box only
/// carries the same dictionary onto the main queue.
private struct NotificationUserInfoBox: @unchecked Sendable {
    let value: [AnyHashable: Any]
    init(_ value: [AnyHashable: Any]) { self.value = value }
}

extension Notification.Name {
    /// Main-thread only. `userInfo["uid"]` is a non-empty String when signed in; absent when signed out.
    static let firebaseAuthUIDChanged = Notification.Name("app.firebaseAuthUIDChanged")
    /// Home's first frame is on screen. The launch logo stays up until this fires.
    static let plannerHomeDidDraw = Notification.Name("app.plannerHomeDidDraw")
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

/// UIKit creates this on the main thread during launch and calls it synchronously.
/// This module's default isolation is MainActor. A MainActor delegate makes that call
/// hop back onto the main actor while already on the main thread, so the first frame
/// never arrives: white launch screen, then the system kills the app.
nonisolated final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    var onPushToken: ((String) -> Void)?
    private var firebaseAuthStateHandle: AuthStateDidChangeListenerHandle?

    /// Runs before `didFinishLaunching` — configures Firebase before Messaging / Auth swizzler touches the default app (fixes I-COR000003 noise and bad first-frame auth).
    nonisolated func application(
        _ application: UIApplication,
        willFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        MainActor.assumeIsolated {
            _ = FirebaseStartup.configureIfNeeded()
            print("🔥🔥🔥 DEBUG: Firebase configured in willFinishLaunching (defaultApp: \(FirebaseApp.app() != nil))")
        }
        return true
    }

    nonisolated func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        MainActor.assumeIsolated {
            _ = FirebaseStartup.configureIfNeeded()
            print("🔥🔥🔥 DEBUG: Firebase ready in didFinishLaunching (defaultApp: \(FirebaseApp.app() != nil))")
        }

        firebaseAuthStateHandle = installAuthUIDNotifications()

        UNUserNotificationCenter.current().delegate = self
        requestRemoteNotificationRegistration(application: application)
#if canImport(FirebaseMessaging)
        Messaging.messaging().delegate = self
#endif
        return true
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound, .badge, .list])
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let info = NotificationUserInfoBox(response.notification.request.content.userInfo)
        DispatchQueue.main.async {
            NotificationCenter.default.post(
                name: .openNotificationDeepLink,
                object: nil,
                userInfo: NotificationDeepLink.userInfo(from: info.value)
            )
        }
        completionHandler()
    }

    nonisolated func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
#if canImport(FirebaseMessaging)
        Messaging.messaging().apnsToken = deviceToken
#endif
    }

    nonisolated func application(
        _ application: UIApplication,
        didReceiveRemoteNotification userInfo: [AnyHashable: Any],
        fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void
    ) {
#if canImport(FirebaseMessaging)
        Messaging.messaging().appDidReceiveMessage(userInfo)
#endif
        completionHandler(.newData)
    }

    nonisolated private func requestRemoteNotificationRegistration(application: UIApplication) {
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
    nonisolated func messaging(_ messaging: Messaging, didReceiveRegistrationToken fcmToken: String?) {
        guard let token = fcmToken, !token.isEmpty else { return }
        print("🔥🔥🔥 DEBUG: Received FCM token")
        Task { @MainActor in
            self.onPushToken?(token)
        }
    }
}
#endif

/// Firebase calls this off the main actor. A closure formed on the main actor crashes there.
private nonisolated func installAuthUIDNotifications() -> AuthStateDidChangeListenerHandle {
    Auth.auth().addStateDidChangeListener { _, user in
        let uid = user?.uid
        DispatchQueue.main.async {
            if let uid, !uid.isEmpty {
                NotificationCenter.default.post(name: .firebaseAuthUIDChanged, object: nil, userInfo: ["uid": uid])
            } else {
                NotificationCenter.default.post(name: .firebaseAuthUIDChanged, object: nil, userInfo: [:])
            }
        }
    }
}

/// The simulator keeps an empty window in front of Home. That empty window is the white screen.
/// Only the window that already has a root controller is brought forward. Empty windows are left alone.
/// UIWindow.appearance is not used. makeKeyAndVisible is not called on every window.
enum LaunchWindowReveal {
    private static var didReveal = false

    @MainActor
    static func revealIfNeeded() {
        guard !didReveal else { return }
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        guard !scenes.isEmpty else { return }
        didReveal = true
        for scene in scenes {
            print("🔥🔥🔥 DEBUG: PP_LAUNCH_WINDOWS total=\(scene.windows.count)")
            for window in scene.windows {
                let rooted = window.rootViewController != nil
                print("🔥🔥🔥 DEBUG: PP_LAUNCH_WIN key=\(window.isKeyWindow) hidden=\(window.isHidden) rooted=\(rooted) \(Int(window.bounds.width))x\(Int(window.bounds.height))")
            }
            let rooted = scene.windows.filter { $0.rootViewController != nil }
            guard let host = rooted.first(where: \.isKeyWindow) ?? rooted.first else { continue }
            host.isHidden = false
            host.backgroundColor = UIColor(red: 0.969, green: 0.973, blue: 0.980, alpha: 1)
            if !host.isKeyWindow {
                host.makeKey()
            }
        }
    }
}

@main
struct Project_PlannerApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    @StateObject private var firebaseBackend: FirebaseBackend
    @StateObject private var smartCache: SmartCacheService
    @StateObject private var projectStore: ProjectStore
    @StateObject private var operativeStore: OperativeStore
    @StateObject private var bookingStore: BookingStore
    @StateObject private var managerScheduleStore: ManagerScheduleStore
    @StateObject private var userStore: UserStore
    @StateObject private var taskStore: ProjectTaskStore
    @StateObject private var holidayStore: HolidayStore
    @StateObject private var subcontractorStore: SubcontractorStore
    @StateObject private var appSettings: AppSettingsStore
    @StateObject private var notificationService: NotificationService

    init() {
        _ = FirebaseStartup.configureIfNeeded()
        let proxyEnabled = Bundle.main.object(forInfoDictionaryKey: "FirebaseAppDelegateProxyEnabled") as? Bool
        print("🔥🔥🔥 DEBUG: FirebaseAppDelegateProxyEnabled = \(proxyEnabled?.description ?? "nil")")
        print("🔥🔥🔥 DEBUG: PP_LAUNCH_BUILD key-host no-cover")
        // Do not touch UIWindow here. Doing it before the scene exists leaves a black window
        // and the log line "Ignoring activation message because no connection exists".
        let backend = FirebaseBackend()
        let users = UserStore()
        _firebaseBackend = StateObject(wrappedValue: backend)
        _smartCache = StateObject(wrappedValue: SmartCacheService())
        _projectStore = StateObject(wrappedValue: ProjectStore())
        _operativeStore = StateObject(wrappedValue: OperativeStore())
        _bookingStore = StateObject(wrappedValue: BookingStore())
        _managerScheduleStore = StateObject(wrappedValue: ManagerScheduleStore())
        _userStore = StateObject(wrappedValue: users)
        backend.installLaunchSession(into: users)
        _taskStore = StateObject(wrappedValue: ProjectTaskStore())
        _holidayStore = StateObject(wrappedValue: HolidayStore())
        _subcontractorStore = StateObject(wrappedValue: SubcontractorStore())
        _appSettings = StateObject(wrappedValue: AppSettingsStore())
        _notificationService = StateObject(wrappedValue: NotificationService())
    }

    var body: some Scene {
        WindowGroup {
            GeometryReader { proxy in
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
                    .frame(width: proxy.size.width, height: proxy.size.height)
            }
            .ignoresSafeArea()
            .onAppear {
                DispatchQueue.main.async {
                    LaunchWindowReveal.revealIfNeeded()
                }
            }
            .onChange(of: appSettings.settings.theme) { _, theme in
                theme.applyToKeyWindows()
            }
        }
    }
}
