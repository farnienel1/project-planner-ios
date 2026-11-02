//
//  AppSignOut.swift
//  Project Planner
//
//  Central sign-out so every entry point (Settings, main menu, quick menu) behaves the same.
//

import Foundation

enum AppSignOut {
    /// RULEBOOK §13: this device's push token is removed from every `users` document it was written to before
    /// Firebase Auth signs out (bounded wait), so the next person on this phone never gets this account's pushes.
    @MainActor
    static func perform(firebaseBackend: FirebaseBackend, userStore: UserStore) {
        Task { @MainActor in
            await firebaseBackend.removeThisDevicePushTokenBeforeSignOut()
            do {
                try firebaseBackend.signOut()
            } catch {
                print("🔥🔥🔥 DEBUG: Sign out error: \(error.localizedDescription)")
            }
            userStore.clearOnSignOut()
            AppLockService.shared.deactivate()
            firebaseBackend.syncPublishedAuthFromAuthSession()
        }
    }
}

/// Whether the sign-out token cleanup has finished (`FirebaseBackend.removeThisDevicePushTokenBeforeSignOut`).
final class PushTokenRemovalProgress {
    var finished = false
}
