import SwiftUI
import UIKit
import UserNotifications

/// Settings → My notifications → Notifications check. Shows each step a remote push needs on this phone —
/// permission, Apple registration, the Firebase token and its save to the signed-in account (RULEBOOK §13:
/// `users/{uid}.pushTokens`) — and sends a `push_test` row to the signed-in user (`pushTestRecipients`), which the
/// push Cloud Function delivers to its own sender (`notificationPushesToActor`). Device-only; writes nothing else.
struct NotificationsCheckCard: View {
    @EnvironmentObject var firebaseBackend: FirebaseBackend
    @EnvironmentObject var notificationService: NotificationService
    @ObservedObject private var status = PushRegistrationStatus.shared

    @State private var permission: UNAuthorizationStatus?
    @State private var savedOnAccount: Bool?
    @State private var isChecking = false
    @State private var isSending = false
    @State private var resultText: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsHubChrome.sectionTitle("Notifications check")
                .padding(.top, 20)
            SettingsHubChrome.card {
                row("Permission", permissionText, ok: permissionOK)
                SettingsHubChrome.divider()
                row("Apple registration", apnsText, ok: status.apnsRegistered)
                SettingsHubChrome.divider()
                row("Phone token", tokenText, ok: status.latestFCMToken == nil ? false : true)
                SettingsHubChrome.divider()
                row("Saved to your account", savedText, ok: savedOnAccount)
                SettingsHubChrome.divider()
                row("Last saved", lastSavedText, ok: nil)
                SettingsHubChrome.divider()
                HStack(spacing: 12) {
                    Button {
                        Task { await sendTest() }
                    } label: {
                        Text(isSending ? "Sending…" : "Send test notification")
                            .font(.subheadline.weight(.semibold))
                    }
                    .disabled(isSending)
                    .accessibilityIdentifier("notificationsCheck.sendTest")
                    Spacer()
                    Button {
                        Task { await refresh(forceToken: true) }
                    } label: {
                        Text(isChecking ? "Checking…" : "Check again")
                            .font(.subheadline)
                    }
                    .disabled(isChecking)
                    .accessibilityIdentifier("notificationsCheck.refresh")
                }
                .padding(.vertical, 12)
                if let resultText {
                    Text(resultText)
                        .font(.caption)
                        .foregroundStyle(Color.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.bottom, 12)
                        .accessibilityIdentifier("notificationsCheck.result")
                }
                if permission == .denied {
                    Button("Open iPhone notification settings") {
                        if let url = URL(string: UIApplication.openNotificationSettingsURLString) {
                            UIApplication.shared.open(url)
                        }
                    }
                    .font(.subheadline)
                    .padding(.bottom, 12)
                }
            }
            SettingsHubChrome.footer("The test notification also appears in your notification centre. If it shows there but not on your phone, send this screen to your administrator.")
        }
        .task { await refresh(forceToken: false) }
    }

    private func row(_ title: String, _ value: String, ok: Bool?) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(title)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(Color.primary)
            Spacer(minLength: 8)
            Text(value)
                .font(.subheadline)
                .multilineTextAlignment(.trailing)
                .foregroundStyle(ok == false ? Color.red : Color.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 11)
        .accessibilityElement(children: .combine)
    }

    private var permissionOK: Bool? {
        switch permission {
        case .authorized, .provisional, .ephemeral: return true
        case .denied: return false
        default: return nil
        }
    }

    private var permissionText: String {
        switch permission {
        case .authorized: return "Allowed"
        case .provisional, .ephemeral: return "Allowed quietly"
        case .denied: return "Turned off in iPhone Settings"
        case .notDetermined: return "Not asked yet"
        case .none: return "Checking…"
        default: return "Unknown"
        }
    }

    private var apnsText: String {
        if let error = status.apnsError { return "Failed: \(error)" }
        switch status.apnsRegistered {
        case .some(true): return "Registered"
        case .some(false): return "Failed"
        case .none: return "Not yet"
        }
    }

    private var tokenText: String {
        guard let token = status.latestFCMToken else { return "Missing" }
        return "Present \(PushRegistrationStatus.tokenSuffix(token))"
    }

    private var savedText: String {
        switch savedOnAccount {
        case .some(true): return "Yes"
        case .some(false):
            if let error = status.lastSaveError { return "No: \(error)" }
            return "No"
        case .none:
            if status.latestFCMToken == nil { return "No phone token yet" }
            // The server read failed (usually offline): never show a save error as if it were the answer.
            return isChecking ? "Checking…" : "Can't check while offline"
        }
    }

    private var lastSavedText: String {
        guard let date = status.lastSavedAt else { return "Not this session" }
        return date.formatted(date: .abbreviated, time: .shortened)
    }

    private func refresh(forceToken: Bool) async {
        guard !isChecking else { return }
        isChecking = true
        defer { isChecking = false }
        permission = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
        if forceToken {
            // Asks Apple and Firebase again, then saves the token to this account.
            _ = await firebaseBackend.forceRefreshAndRegisterPushToken()
        } else {
            await firebaseBackend.reregisterPushTokenIfAvailable()
        }
        savedOnAccount = await firebaseBackend.pushTokenSavedOnOwnAccount()
    }

    private func sendTest() async {
        guard !isSending else { return }
        isSending = true
        defer { isSending = false }
        resultText = await notificationService.sendTemporaryPushDiagnosticToCurrentUser()
        savedOnAccount = await firebaseBackend.pushTokenSavedOnOwnAccount()
    }
}
