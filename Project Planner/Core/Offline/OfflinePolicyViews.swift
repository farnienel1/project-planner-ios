//
//  OfflinePolicyViews.swift
//  Project Planner
//
//  SwiftUI pieces for RULEBOOK §2. The decisions come from `OfflinePolicy`; these only show them.
//

import SwiftUI

/// Disables an online-only control while offline and shows "Connect to the internet to change this".
struct OnlineOnlyModifier: ViewModifier {
    let isOnline: Bool
    var showsMessage: Bool = true

    func body(content: Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            content
                .disabled(!isOnline)
            if !isOnline && showsMessage {
                Label(OfflinePolicy.onlineOnlyMessage, systemImage: "wifi.slash")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("offlinePolicy.onlineOnlyMessage")
            }
        }
    }
}

/// Uses `SmartCacheService.isOnline` from the environment.
struct EnvironmentOnlineOnlyModifier: ViewModifier {
    @EnvironmentObject private var smartCache: SmartCacheService
    var showsMessage: Bool = true

    func body(content: Content) -> some View {
        content.modifier(OnlineOnlyModifier(isOnline: smartCache.isOnline, showsMessage: showsMessage))
    }
}

extension View {
    /// RULEBOOK §2 online-only control: disabled offline, with the standard message under it.
    func onlineOnly(isOnline: Bool, showsMessage: Bool = true) -> some View {
        modifier(OnlineOnlyModifier(isOnline: isOnline, showsMessage: showsMessage))
    }

    /// Same as `onlineOnly(isOnline:)`, reading `SmartCacheService` from the environment.
    func onlineOnly(showsMessage: Bool = true) -> some View {
        modifier(EnvironmentOnlineOnlyModifier(showsMessage: showsMessage))
    }

    /// Applies `OfflinePolicy` for `action`: online-only actions are disabled offline with the message.
    @ViewBuilder
    func offlinePolicy(_ action: OfflineAction, isOnline: Bool, showsMessage: Bool = true) -> some View {
        if OfflinePolicy.availability(action) == .onlineOnly {
            onlineOnly(isOnline: isOnline, showsMessage: showsMessage)
        } else {
            self
        }
    }
}

/// "Pending sync" chip for a row whose change is still in the outbox.
struct PendingSyncBadge: View {
    var body: some View {
        Label(OfflinePolicy.pendingSyncMessage, systemImage: "icloud.and.arrow.up")
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.orange)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Color.orange.opacity(0.12), in: Capsule())
            .accessibilityIdentifier("offlinePolicy.pendingSync")
    }
}

/// Shows `PendingSyncBadge` while the outbox holds a change for `entityId` (a booking UUID string). 1.33.1 review
/// item 3: given a booking's `collection` and stored `documentKey`, also while Firestore holds a write to it whose
/// confirmation wait timed out (`SDKPendingWrites`, `BookingPendingSync`).
struct PendingSyncIndicator: View {
    let entityId: String
    var collection: String? = nil
    var documentKey: String? = nil
    @ObservedObject private var outbox = OfflineOutboxStore.shared
    @ObservedObject private var sdkPending = SDKPendingWrites.shared

    init(entityId: String, collection: String? = nil, documentKey: String? = nil) {
        self.entityId = entityId
        self.collection = collection
        self.documentKey = documentKey
    }

    /// A labour booking row.
    init(booking: Booking) {
        self.init(entityId: booking.id.uuidString, collection: "bookings", documentKey: booking.documentKey)
    }

    /// A manager schedule booking row.
    init(managerBooking: ManagerSiteBooking) {
        self.init(entityId: managerBooking.id.uuidString, collection: "managerSiteBookings", documentKey: managerBooking.documentKey)
    }

    var body: some View {
        if BookingPendingSync.isPending(entityId: entityId, collection: collection, documentKey: documentKey) {
            PendingSyncBadge()
        }
    }
}

/// "Last updated [date/time]" for the read-only offline screens (Daily Overview, warnings,
/// weekly report, My Schedule). Shows nothing while online.
struct LastUpdatedOfflineLabel: View {
    @EnvironmentObject private var smartCache: SmartCacheService

    var body: some View {
        if !smartCache.isOnline, let text = OfflinePolicy.lastUpdatedMessage(smartCache.lastSyncedAt) {
            Label(text, systemImage: "clock.arrow.circlepath")
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("offlinePolicy.lastUpdated")
        }
    }
}
