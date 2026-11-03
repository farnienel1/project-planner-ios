//
//  AppSignOut.swift
//  Project Planner
//
//  Central sign-out so every entry point (Settings, main menu, quick menu) behaves the same.
//

import Foundation

enum AppSignOut {
    /// The Settings / menu sign-out. RULEBOOK §13: goes through `FirebaseBackend.signOutRemovingPushToken`, the one
    /// path that removes this device's push token before Firebase Auth signs out (bounded wait).
    @MainActor
    static func perform(firebaseBackend: FirebaseBackend, userStore: UserStore) {
        Task { @MainActor in
            await firebaseBackend.signOutRemovingPushToken(reason: .userRequested)
            userStore.clearOnSignOut()
            AppLockService.shared.deactivate()
            firebaseBackend.syncPublishedAuthFromAuthSession()
        }
    }
}

/// Why the app is signing out. Only `userRequested` is the person's own choice; the rest are forced sign-outs.
enum SignOutReason: String, Sendable {
    case userRequested
    case sessionExpired
    case trialBlocked
}

/// RULEBOOK §13 order of a sign-out: the push-token clean-up first, for at most `timeoutSeconds`, then the
/// sign-out itself — always, whether the clean-up finished, failed or is still waiting on the network.
@MainActor
enum SignOutSequence {
    /// Default wait for the token clean-up before signing out anyway.
    static let defaultCleanupTimeoutSeconds: Double = 5

    /// Returns whether the clean-up finished inside the timeout. `signOut` runs exactly once either way.
    @discardableResult
    static func run(
        timeoutSeconds: Double = defaultCleanupTimeoutSeconds,
        cleanup: @escaping @MainActor () async -> Void,
        signOut: @MainActor () -> Void
    ) async -> Bool {
        let progress = PushTokenRemovalProgress()
        let work = Task { @MainActor in
            await cleanup()
            progress.finished = true
        }
        let step = 0.05
        var waited = 0.0
        while !progress.finished && waited < timeoutSeconds {
            try? await Task.sleep(nanoseconds: UInt64(step * 1_000_000_000))
            waited += step
        }
        let finished = progress.finished
        if !finished { work.cancel() }
        signOut()
        return finished
    }
}

/// Whether the sign-out token cleanup has finished (`SignOutSequence`).
final class PushTokenRemovalProgress {
    var finished = false
}
