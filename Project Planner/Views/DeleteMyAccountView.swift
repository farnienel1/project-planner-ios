//
//  DeleteMyAccountView.swift
//  Project Planner
//
//  Settings › Personal › Delete my account
//

import FirebaseAuth
import SwiftUI

struct DeleteMyAccountView: View {
    @EnvironmentObject var firebaseBackend: FirebaseBackend
    @EnvironmentObject var userStore: UserStore

    @State private var confirmation = ""
    @State private var password = ""
    @State private var message: String?
    @State private var showsDeleteButton = true
    @State private var isDeleting = false

    private let consequences = [
        "This permanently deletes your Project Planner login. You will not be able to sign in again.",
        "Timesheets, invoices and other company records stay with the organisation. Your name on those records becomes “Deleted user”.",
        "This does not cancel your organisation’s subscription. An admin must manage billing separately."
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                SettingsHubChrome.card {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(Array(consequences.enumerated()), id: \.offset) { index, line in
                            Text("\(index + 1). \(line)")
                                .font(.subheadline)
                                .foregroundStyle(Color.primary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(.vertical, 14)
                }

                SettingsHubChrome.card {
                    VStack(alignment: .leading, spacing: 8) {
                        labeledField("Type DELETE") {
                            TextField("DELETE", text: $confirmation)
                                .textFieldStyle(RoundedBorderTextFieldStyle())
                                .textInputAutocapitalization(.characters)
                                .autocorrectionDisabled()
                                .accessibilityIdentifier("deleteMyAccount.confirmation")
                        }
                        Divider().overlay(Color(.separator))
                        labeledField("Current password") {
                            CustomSecureField(title: "Current password", text: $password)
                        }
                    }
                    .padding(.vertical, 8)
                }

                if let message {
                    Text(message)
                        .font(.subheadline)
                        .foregroundStyle(PPColor.danger)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 4)
                        .padding(.bottom, 8)
                        .accessibilityIdentifier("deleteMyAccount.message")
                }

                if showsDeleteButton {
                    Button(action: deleteAccount) {
                        HStack(spacing: 8) {
                            if isDeleting {
                                ProgressView()
                                    .progressViewStyle(CircularProgressViewStyle(tint: .white))
                            }
                            Text(isDeleting ? "Deleting…" : "Delete my account")
                                .font(.body.weight(.semibold))
                        }
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity, minHeight: 52)
                        .background(PPColor.danger)
                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .disabled(isDeleting)
                    .padding(.top, 8)
                    .accessibilityIdentifier("deleteMyAccount.submit")
                }
            }
            .padding(16)
        }
        .background(PPColor.page.ignoresSafeArea())
        .navigationTitle("Delete your account?")
        .navigationBarTitleDisplayMode(.inline)
        .ppNavyNavigationBar()
    }

    private func labeledField<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(Color.primary)
            content()
        }
        .padding(.vertical, 8)
    }

    private func deleteAccount() {
        guard !isDeleting else { return }
        isDeleting = true
        message = nil
        let typedConfirmation = confirmation
        let typedPassword = password
        Task {
            let session = AccountDeletionSession()
            session.user = Auth.auth().currentUser
            let result = await AccountDeletionClient.perform(
                email: Self.authEmail(of: session.user),
                confirmation: typedConfirmation,
                password: typedPassword,
                confirmPassword: {
                    let current = Auth.auth().currentUser ?? session.user
                    session.user = try await Self.reauthenticate(user: current, password: typedPassword)
                },
                idToken: {
                    guard let live = session.user ?? Auth.auth().currentUser else {
                        throw AccountDeletionClient.TokenError.notSignedIn
                    }
                    return try await live.getIDToken(forcingRefresh: true)
                },
                tokenUserId: { session.user?.uid },
                sessionAfterFailure: {
                    await Self.sessionAfterFailedDelete()
                },
                userId: session.user?.uid,
                clearRememberedOrganization: {
                    firebaseBackend.clearLocalOrganizationCache()
                },
                clearPersistence: { uid in
                    await PersistenceService().clearUserData(for: uid)
                },
                signOut: {
                    AppSignOut.perform(firebaseBackend: firebaseBackend, userStore: userStore)
                }
            )
            isDeleting = false
            message = result.failureMessage
            if result.hidesDeleteButton {
                showsDeleteButton = false
            }
        }
    }

    /// After an ambiguous delete response. A nil user, or reload / token refresh failing with
    /// user-not-found, invalid-credential, or user-token-expired, means the account is already gone.
    /// A successful reload means the user still exists, so the failure stays a failure.
    @MainActor
    private static func sessionAfterFailedDelete() async -> AccountDeletionClient.SessionAfterFailure {
        guard let user = Auth.auth().currentUser else {
            return AccountDeletionClient.sessionAfterFailure(reload: .missingUser, token: nil)
        }
        let reload = await authCheck { try await user.reload() }
        if reload == .missingUser || reload == .userStillExists {
            return AccountDeletionClient.sessionAfterFailure(reload: reload, token: nil)
        }
        if case .failed(let domain, let code) = reload, AccountDeletionClient.sessionEnded(authDomain: domain, code: code) {
            return AccountDeletionClient.sessionAfterFailure(reload: reload, token: nil)
        }
        let token = await authCheck { _ = try await user.getIDToken(forcingRefresh: true) }
        return AccountDeletionClient.sessionAfterFailure(reload: reload, token: token)
    }

    @MainActor
    private static func authCheck(
        _ call: () async throws -> Void
    ) async -> AccountDeletionClient.AuthCheck {
        do {
            try await call()
        } catch {
            let ns = error as NSError
            if Auth.auth().currentUser == nil {
                return .missingUser
            }
            return .failed(domain: ns.domain, code: ns.code)
        }
        return Auth.auth().currentUser == nil ? .missingUser : .userStillExists
    }

    /// Email/password credential for the signed-in Firebase user. A stored profile email is not used.
    private static func authEmail(of user: FirebaseAuth.User?) -> String? {
        guard let user else { return nil }
        let direct = user.email?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !direct.isEmpty { return direct }
        for info in user.providerData where info.providerID == EmailAuthProviderID {
            let email = info.email?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !email.isEmpty { return email }
        }
        return nil
    }

    /// Returns the user Firebase just reauthenticated, so the token refresh uses that session.
    private static func reauthenticate(user: FirebaseAuth.User?, password: String) async throws -> FirebaseAuth.User {
        guard let user else {
            throw AccountDeletionClient.PasswordCheckError.notSignedIn
        }
        guard let liveEmail = authEmail(of: user) else {
            throw AccountDeletionClient.PasswordCheckError.notSignedIn
        }
        let credential = EmailAuthProvider.credential(withEmail: liveEmail, password: password)
        do {
            let result = try await user.reauthenticate(with: credential)
            return result.user
        } catch {
            let ns = error as NSError
            throw AccountDeletionClient.passwordCheckFailure(authDomain: ns.domain, code: ns.code)
        }
    }
}

/// Holds the user across reauth and the token refresh that follows it.
private final class AccountDeletionSession: @unchecked Sendable {
    var user: FirebaseAuth.User?
}
