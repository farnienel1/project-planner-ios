import Foundation
import Combine

/// What this phone knows about its own remote-push set-up, for Settings → My notifications → Notifications check.
/// RULEBOOK §13: a device push token belongs to the signed-in account and is written to its own `users/{uid}`
/// (`pushTokens`, `pushTokenUpdatedAt`). Each step that can silently fail — APNs registration, the FCM token, the
/// save to the account — records its outcome here so the check can say which one did. Device-only state, never synced.
final class PushRegistrationStatus: ObservableObject {
    static let shared = PushRegistrationStatus()

    /// Nil until iOS answers `registerForRemoteNotifications`.
    @Published private(set) var apnsRegistered: Bool?
    @Published private(set) var apnsError: String?
    /// The latest FCM token Firebase gave this device (kept so it can be saved again after sign-in).
    @Published private(set) var latestFCMToken: String?
    @Published private(set) var lastSavedAt: Date?
    @Published private(set) var lastSaveError: String?

    private init() {}

    func recordAPNsRegistered() {
        apnsRegistered = true
        apnsError = nil
    }

    func recordAPNsFailure(_ message: String) {
        apnsRegistered = false
        apnsError = message
    }

    func recordFCMToken(_ token: String) {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        latestFCMToken = trimmed
    }

    func recordSaved(at date: Date = Date()) {
        lastSavedAt = date
        lastSaveError = nil
    }

    func recordSaveFailure(_ message: String) {
        lastSaveError = message
    }

    /// Sign-out: the next account starts with no saved-token state (the FCM token itself stays; it belongs to the phone).
    func resetForSignOut() {
        lastSavedAt = nil
        lastSaveError = nil
    }

    /// The last 6 characters, for display. The full token is never shown or logged.
    nonisolated static func tokenSuffix(_ token: String?) -> String {
        let trimmed = (token ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        return "…" + String(trimmed.suffix(6))
    }
}
