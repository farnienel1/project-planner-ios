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

    /// Site audit drafts on this phone (owner decision 12 Nov): a sign-out removes them.
    static var siteAuditDrafts: Int {
        SiteAuditDraftStore.shared.totalDraftCount()
    }

    static func draftsLine(_ count: Int) -> String? {
        guard count > 0 else { return nil }
        return count == 1
            ? "1 site audit draft on this phone will be deleted."
            : "\(count) site audit drafts on this phone will be deleted."
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

    /// "Finishing sync…": Sync now or Sign out anyway is waiting for the device's sync (at most
    /// `finishSyncTimeoutSeconds`). The screen is covered so taps do not stack.
    @State private var isSyncing = false

    /// A Storage upload or save can stall for minutes; a sign-out never waits longer than this.
    static let finishSyncTimeoutSeconds: Double = 12

    func body(content: Content) -> some View {
        // Read when the alert is built, so the count is the one on the device now.
        let pending = PendingSyncCount.current
        let draftsLine = PendingSyncCount.draftsLine(PendingSyncCount.siteAuditDrafts)
        let baseMessage = pending > 0 ? PendingSyncCount.message(pending) : "Are you sure you want to sign out?"
        return content
            .overlay {
                if isSyncing {
                    ZStack {
                        Color.black.opacity(0.25).ignoresSafeArea()
                        VStack(spacing: 10) {
                            ProgressView()
                            Text("Finishing sync…")
                                .font(.subheadline.weight(.semibold))
                        }
                        .padding(20)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityAddTraits(.isModal)
                    .accessibilityIdentifier("\(idPrefix).finishingSync")
                }
            }
            .alert(pending > 0 ? "Changes waiting to sync" : "Sign Out", isPresented: $isPresented) {
                if pending > 0 {
                    Button("Sync now") {
                        guard !isSyncing else { return }
                        isSyncing = true
                        SiteAuditOfflineStore.shared.resetAttempts()
                        // The device's one sync guard: if a background pass is sending now, this waits for it
                        // (and runs once more after it) instead of a second pass sending the same items.
                        Task { @MainActor in
                            // At most `finishSyncTimeoutSeconds`; a stalled upload keeps going in the background.
                            await SingleFlight.offlineSync.run(timeoutSeconds: Self.finishSyncTimeoutSeconds) {
                                _ = await OfflineSyncCoordinator.processOutbox(firebaseBackend: firebaseBackend)
                                await SiteAuditOfflineStore.shared.syncPending(firebaseBackend: firebaseBackend)
                            }
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
                        guard !isSyncing else { return }
                        isSyncing = true
                        Task { @MainActor in
                            // Let a pass that is sending now finish first, but never wait longer than the limit.
                            await SingleFlight.offlineSync.waitUntilIdle(timeoutSeconds: Self.finishSyncTimeoutSeconds)
                            isSyncing = false
                            AppSignOut.perform(firebaseBackend: firebaseBackend, userStore: userStore)
                        }
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
                Text(draftsLine.map { "\(baseMessage)\n\n\($0)" } ?? baseMessage)
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
