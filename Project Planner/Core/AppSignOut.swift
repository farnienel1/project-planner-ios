//
//  AppSignOut.swift
//  Project Planner
//
//  Central sign-out so every entry point (Settings, main menu, quick menu) behaves the same.
//

import Foundation

enum AppSignOut {
    @MainActor
    static func perform(firebaseBackend: FirebaseBackend, userStore: UserStore) {
        do {
            try firebaseBackend.signOut()
        } catch {
            print("🔥🔥🔥 DEBUG: Sign out error: \(error.localizedDescription)")
        }
        userStore.clearOnSignOut()
        firebaseBackend.syncPublishedAuthFromAuthSession()
    }
}
