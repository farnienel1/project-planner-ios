//
//  AppLockService.swift
//  Project Planner
//
//  Optional Face ID / Touch ID lock over the signed-in app. A per-user, per-device preference:
//  nothing is written to Firestore and the web app is unaffected, so there is no rulebook function for it.
//

import Combine
import Foundation
import LocalAuthentication

/// Pure decisions, kept apart from `LAContext` so they can be unit tested.
nonisolated enum AppLockPolicy {
    /// The app stays unlocked if it comes back within this many seconds of going to the background.
    static let gracePeriod: TimeInterval = 30 * 60

    static func shouldLockOnReturn(enabled: Bool, backgroundedAt: Date?, now: Date, gracePeriod: TimeInterval = gracePeriod) -> Bool {
        guard enabled, let backgroundedAt else { return false }
        return now.timeIntervalSince(backgroundedAt) >= gracePeriod
    }

    /// A restored session (cold launch) locks; a password sign-in the user just typed does not.
    static func shouldLockOnActivate(enabled: Bool, isInteractiveSignIn: Bool) -> Bool {
        enabled && !isInteractiveSignIn
    }

    /// Offered once per user on this device, right after they sign in with their password.
    static func shouldOfferAfterSignIn(enabled: Bool, alreadyOffered: Bool, isInteractiveSignIn: Bool, deviceCanLock: Bool) -> Bool {
        isInteractiveSignIn && deviceCanLock && !enabled && !alreadyOffered
    }

    static func enabledKey(uid: String) -> String { "appLock.enabled.\(uid)" }
    static func offeredKey(uid: String) -> String { "appLock.offered.\(uid)" }
}

final class AppLockService: ObservableObject {
    /// `FirebaseBackend` and `AuthenticationView` are not handed the environment, so they reach the lock through this.
    static let shared = AppLockService()

    enum Biometry: Equatable {
        case faceID, touchID, opticID, passcodeOnly, unavailable

        var displayName: String {
            switch self {
            case .faceID: return "Face ID"
            case .touchID: return "Touch ID"
            case .opticID: return "Optic ID"
            case .passcodeOnly, .unavailable: return "Passcode"
            }
        }

        var systemImage: String {
            switch self {
            case .faceID: return "faceid"
            case .touchID: return "touchid"
            case .opticID: return "opticid"
            case .passcodeOnly, .unavailable: return "lock.fill"
            }
        }
    }

    @Published private(set) var isEnabled = false
    @Published private(set) var isLocked = false
    @Published private(set) var isAuthenticating = false
    @Published private(set) var biometry: Biometry = .unavailable
    @Published var showSignInOffer = false
    @Published var lastError: String?

    private(set) var currentUID: String?
    private var backgroundedAt: Date?
    private var interactiveSignInPending = false
    private let defaults: UserDefaults
    private let now: () -> Date

    init(defaults: UserDefaults = .standard, now: @escaping () -> Date = Date.init) {
        self.defaults = defaults
        self.now = now
        refreshBiometry()
    }

    /// The device has a passcode set (Face ID / Touch ID optional). Without one there is nothing to unlock with.
    var deviceCanLock: Bool { biometry != .unavailable }

    func refreshBiometry() {
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            biometry = .unavailable
            return
        }
        _ = context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)
        switch context.biometryType {
        case .faceID: biometry = .faceID
        case .touchID: biometry = .touchID
        case .opticID: biometry = .opticID
        default: biometry = .passcodeOnly
        }
    }

    // MARK: Session

    /// Call just before the sign-in screen hands over, so the next `activate` does not lock the user straight out.
    func noteInteractiveSignIn() {
        interactiveSignInPending = true
    }

    /// The signed-in user is known. Safe to call repeatedly with the same uid.
    func activate(uid: String) {
        let isInteractive = interactiveSignInPending
        interactiveSignInPending = false
        guard uid != currentUID else { return }
        currentUID = uid
        refreshBiometry()
        isEnabled = defaults.bool(forKey: AppLockPolicy.enabledKey(uid: uid))
        backgroundedAt = nil
        isLocked = AppLockPolicy.shouldLockOnActivate(enabled: isEnabled, isInteractiveSignIn: isInteractive)
        showSignInOffer = AppLockPolicy.shouldOfferAfterSignIn(
            enabled: isEnabled,
            alreadyOffered: defaults.bool(forKey: AppLockPolicy.offeredKey(uid: uid)),
            isInteractiveSignIn: isInteractive,
            deviceCanLock: deviceCanLock
        )
    }

    /// Clears the lock for sign-out. The user's on/off choice stays saved for their next sign-in.
    func deactivate() {
        currentUID = nil
        isEnabled = false
        isLocked = false
        showSignInOffer = false
        backgroundedAt = nil
        lastError = nil
    }

    // MARK: Lifecycle

    func appDidEnterBackground() {
        guard isEnabled, !isLocked else { return }
        backgroundedAt = now()
    }

    func appDidBecomeActive() {
        refreshBiometry()
        if AppLockPolicy.shouldLockOnReturn(enabled: isEnabled, backgroundedAt: backgroundedAt, now: now()) {
            isLocked = true
            lastError = nil
        }
        backgroundedAt = nil
    }

    // MARK: Unlock and toggle

    func unlock() async {
        guard isLocked, !isAuthenticating else { return }
        if await authenticate(reason: "Unlock Project Planner") {
            isLocked = false
            lastError = nil
        }
    }

    /// Turning the lock on or off both need a successful check, so a borrowed unlocked phone cannot switch it off
    /// and nobody turns on a lock they cannot open. Returns the saved state.
    @discardableResult
    func setEnabled(_ enabled: Bool) async -> Bool {
        guard let uid = currentUID, enabled != isEnabled else { return isEnabled }
        refreshBiometry()
        if enabled && !deviceCanLock {
            lastError = "Set a passcode on this iPhone first (Settings → Face ID & Passcode)."
            return isEnabled
        }
        let reason = enabled ? "Turn on the app lock" : "Turn off the app lock"
        // Passcode removed since the lock was turned on: let the user switch it off rather than strand the setting.
        let allowed = (!enabled && !deviceCanLock) ? true : await authenticate(reason: reason)
        guard allowed, uid == currentUID else { return isEnabled }
        defaults.set(enabled, forKey: AppLockPolicy.enabledKey(uid: uid))
        defaults.set(true, forKey: AppLockPolicy.offeredKey(uid: uid))
        isEnabled = enabled
        lastError = nil
        return isEnabled
    }

    func dismissSignInOffer() {
        if let uid = currentUID {
            defaults.set(true, forKey: AppLockPolicy.offeredKey(uid: uid))
        }
        showSignInOffer = false
    }

    #if DEBUG
    /// `-showAppLockOffer` previews the sign-in offer without typing a password.
    func forceSignInOfferForPreview() {
        guard currentUID != nil, deviceCanLock, !isEnabled else { return }
        showSignInOffer = true
    }
    #endif

    private func authenticate(reason: String) async -> Bool {
        isAuthenticating = true
        defer { isAuthenticating = false }
        let context = LAContext()
        context.localizedFallbackTitle = "Use Passcode"
        do {
            // `.deviceOwnerAuthentication` falls back to the passcode when Face ID fails or is locked out.
            return try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)
        } catch let error as LAError {
            switch error.code {
            case .userCancel, .appCancel, .systemCancel:
                lastError = nil
            case .passcodeNotSet, .biometryNotEnrolled, .biometryNotAvailable:
                refreshBiometry()
                lastError = "This iPhone has no passcode set, so it can't be unlocked here. Sign out and sign in with your password."
            default:
                lastError = "Couldn't confirm it's you. Try again."
            }
            return false
        } catch {
            lastError = "Couldn't confirm it's you. Try again."
            return false
        }
    }
}
