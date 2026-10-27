//
//  AppLockViews.swift
//  Project Planner
//
//  Screens for the optional Face ID / Touch ID lock. State and decisions live in `AppLockService`.
//

import SwiftUI

/// Full-screen cover while the signed-in app is locked. Sign out is always offered, so a phone whose passcode
/// was removed can still get back in with the account password.
struct AppLockView: View {
    @EnvironmentObject private var appLock: AppLockService
    @EnvironmentObject private var firebaseBackend: FirebaseBackend
    @EnvironmentObject private var userStore: UserStore

    /// Ask once per lock on our own; after a cancel the user taps the button.
    /// This view lives in its own window outside the SwiftUI scene, so it reads UIKit's app state, not `scenePhase`.
    @State private var didAutoPrompt = false
    @State private var showingSignOutAlert = false

    var body: some View {
        VStack(spacing: 20) {
            Spacer()
            Image("AppLogo")
                .resizable()
                .scaledToFit()
                .frame(width: 96, height: 96)
                .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            Text("Project Planner is locked")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(ProjectWorksRevampColors.ink)
            if let message = appLock.lastError {
                Text(message)
                    .font(.system(size: 13))
                    .foregroundStyle(ProjectWorksRevampColors.muted)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
                    .accessibilityIdentifier("appLock.error")
            }
            Button {
                Task { await appLock.unlock() }
            } label: {
                Label("Unlock with \(appLock.biometry.displayName)", systemImage: appLock.biometry.systemImage)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: 280)
                    .padding(.vertical, 14)
                    .background(ProjectWorksRevampColors.blue)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            .disabled(appLock.isAuthenticating || !appLock.deviceCanLock)
            .opacity(appLock.deviceCanLock ? 1 : 0.4)
            .accessibilityIdentifier("appLock.unlock")
            Spacer()
            Button("Sign out") { showingSignOutAlert = true }
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(ProjectWorksRevampColors.muted)
                .padding(.bottom, 24)
                .accessibilityIdentifier("appLock.signOut")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(ProjectWorksRevampColors.canvas.ignoresSafeArea())
        .onAppear(perform: autoPromptIfActive)
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
            autoPromptIfActive()
        }
        .alert("Sign Out", isPresented: $showingSignOutAlert) {
            Button("Cancel", role: .cancel) { }
            Button("Sign Out", role: .destructive) {
                AppSignOut.perform(firebaseBackend: firebaseBackend, userStore: userStore)
            }
        } message: {
            Text("You'll need your email and password to sign back in.")
        }
    }

    private func autoPromptIfActive() {
        guard UIApplication.shared.applicationState == .active, !didAutoPrompt, appLock.deviceCanLock else { return }
        didAutoPrompt = true
        Task { await appLock.unlock() }
    }
}

/// Hides bookings in the app switcher preview while the lock is on.
struct AppPrivacyCover: View {
    var body: some View {
        Image("AppLogo")
            .resizable()
            .scaledToFit()
            .frame(width: 96, height: 96)
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(ProjectWorksRevampColors.canvas.ignoresSafeArea())
    }
}

/// One-time offer shown after a password sign-in.
struct AppLockSignInOfferView: View {
    @EnvironmentObject private var appLock: AppLockService

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: appLock.biometry.systemImage)
                .font(.system(size: 44, weight: .regular))
                .foregroundStyle(ProjectWorksRevampColors.blue)
                .padding(.top, 28)
            Text("Lock the app with \(appLock.biometry.displayName)?")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(ProjectWorksRevampColors.ink)
                .multilineTextAlignment(.center)
            Text("Project Planner will ask for \(appLock.biometry.displayName) when you open it, or come back after 30 minutes away. You can change this any time in Settings.")
                .font(.system(size: 13))
                .foregroundStyle(ProjectWorksRevampColors.muted)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
            if let message = appLock.lastError {
                Text(message)
                    .font(.system(size: 12))
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
            }
            Button {
                Task {
                    if await appLock.setEnabled(true) {
                        appLock.showSignInOffer = false
                    }
                }
            } label: {
                Text("Turn on \(appLock.biometry.displayName)")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(ProjectWorksRevampColors.blue)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            .disabled(appLock.isAuthenticating)
            .padding(.horizontal, 24)
            .accessibilityIdentifier("appLockOffer.turnOn")
            Button("Not now") { appLock.dismissSignInOffer() }
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(ProjectWorksRevampColors.muted)
                .accessibilityIdentifier("appLockOffer.notNow")
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity)
        .background(ProjectWorksRevampColors.canvas.ignoresSafeArea())
        .presentationDetents([.height(380)])
        .interactiveDismissDisabled(appLock.isAuthenticating)
    }
}

/// What sits above the app while the lock is on.
enum AppLockOverlay: Equatable {
    case none, locked, privacy
}

/// Hosts the lock in its own window above the app's window, so it also covers open sheets and full-screen
/// covers. A view in the root `ZStack` sits underneath anything presented modally.
final class AppLockWindowPresenter {
    private var window: UIWindow?
    private var shown: AppLockOverlay = .none

    func update<Locked: View, Privacy: View>(
        _ overlay: AppLockOverlay,
        locked: () -> Locked,
        privacy: () -> Privacy
    ) {
        guard overlay != shown else { return }
        shown = overlay
        switch overlay {
        case .none:
            window?.isHidden = true
            window?.rootViewController = nil
            window = nil
        case .locked:
            present(AnyView(locked()))
        case .privacy:
            present(AnyView(privacy()))
        }
    }

    private func present(_ content: AnyView) {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        guard let scene = scenes.first(where: { $0.activationState == .foregroundActive })
            ?? scenes.first(where: { $0.activationState == .foregroundInactive })
            ?? scenes.first else { return }
        let target = window ?? UIWindow(windowScene: scene)
        target.windowLevel = .alert + 1
        // Match the theme the main window was given in `ThemePreference.applyToKeyWindows()`.
        target.overrideUserInterfaceStyle = scene.windows.first(where: { $0 !== target })?.overrideUserInterfaceStyle ?? .unspecified
        let host = UIHostingController(rootView: content)
        host.view.backgroundColor = .clear
        target.rootViewController = host
        target.isHidden = false
        window = target
    }
}
