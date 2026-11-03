//
//  SignOutConfirmation.swift
//  Project Planner
//
//  Every sign-out entry point asks first. With changes still waiting in this device's queues (offline outbox, site
//  audits), it says how many and offers Sync now / Sign out anyway / Cancel, because signing out discards them
//  (`FirebaseBackend.clearDeviceQueuesOnSignOut`).
//

import SwiftUI

/// Changes on this device that a sign-out would discard.
@MainActor
enum PendingSyncCount {
    static var current: Int {
        OfflineOutboxStore.shared.pendingCount + SiteAuditOfflineStore.shared.pendingCount
    }

    static func message(_ count: Int) -> String {
        count == 1
            ? "You have 1 change waiting to sync. Signing out will discard it."
            : "You have \(count) changes waiting to sync. Signing out will discard them."
    }
}

private struct SignOutConfirmationModifier: ViewModifier {
    @Binding var isPresented: Bool
    let firebaseBackend: FirebaseBackend
    let userStore: UserStore
    let idPrefix: String

    @State private var isSyncing = false

    func body(content: Content) -> some View {
        // Read when the alert is built, so the count is the one on the device now.
        let pending = PendingSyncCount.current
        return content
            .alert(pending > 0 ? "Changes waiting to sync" : "Sign Out", isPresented: $isPresented) {
                if pending > 0 {
                    Button("Sync now") {
                        isSyncing = true
                        Task { @MainActor in
                            _ = await OfflineSyncCoordinator.processOutbox(firebaseBackend: firebaseBackend)
                            await SiteAuditOfflineStore.shared.syncPending(firebaseBackend: firebaseBackend)
                            isSyncing = false
                            if PendingSyncCount.current > 0 {
                                // Still waiting (offline or refused): ask again with the new count.
                                isPresented = true
                            } else {
                                AppSignOut.perform(firebaseBackend: firebaseBackend, userStore: userStore)
                            }
                        }
                    }
                    .accessibilityIdentifier("\(idPrefix).syncNow")
                    Button("Sign out anyway", role: .destructive) {
                        AppSignOut.perform(firebaseBackend: firebaseBackend, userStore: userStore)
                    }
                    .accessibilityIdentifier("\(idPrefix).signOutAnyway")
                    Button("Cancel", role: .cancel) { }
                        .accessibilityIdentifier("\(idPrefix).cancel")
                } else {
                    Button("Cancel", role: .cancel) { }
                        .accessibilityIdentifier("\(idPrefix).cancel")
                    Button("Sign Out", role: .destructive) {
                        AppSignOut.perform(firebaseBackend: firebaseBackend, userStore: userStore)
                    }
                    .accessibilityIdentifier("\(idPrefix).signOut")
                }
            } message: {
                Text(pending > 0 ? PendingSyncCount.message(pending) : "Are you sure you want to sign out?")
            }
    }
}

extension View {
    /// Asks before signing out; warns when queued changes would be discarded.
    func signOutConfirmation(
        isPresented: Binding<Bool>,
        firebaseBackend: FirebaseBackend,
        userStore: UserStore,
        idPrefix: String
    ) -> some View {
        modifier(SignOutConfirmationModifier(
            isPresented: isPresented,
            firebaseBackend: firebaseBackend,
            userStore: userStore,
            idPrefix: idPrefix
        ))
    }
}
