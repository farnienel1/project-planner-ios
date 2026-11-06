//
//  OfflineStatusBanner.swift
//  Project Planner
//

import SwiftUI

struct OfflineStatusBanner: View {
    @EnvironmentObject private var smartCache: SmartCacheService
    @ObservedObject private var outbox = OfflineOutboxStore.shared
    @State private var showingQueue = false

    var body: some View {
        VStack(spacing: 0) {
            if smartCache.showOfflineBanner {
                bannerContent
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .sheet(isPresented: $showingQueue) {
                        OfflineSyncQueueSheet()
                            .environmentObject(smartCache)
                    }
            }
        }
        // RULEBOOK §2: a refused replay is final; tell the person once (`BOOKING_REPLAY_REFUSED_MESSAGE`; 1.33.0 a
        // refused offline delete: `OFFLINE_DELETE_CHANGED_MESSAGE` / `OFFLINE_DELETE_REFUSED_MESSAGE`). Otherwise a
        // notice after a change that went through (`bookingDeleteSignedTimesheetWarning`).
        .alert(
            outbox.lastRefusalMessage != nil ? "Change not saved" : "Booking deleted",
            isPresented: Binding(
                get: { outbox.lastRefusalMessage != nil || outbox.lastNoticeMessage != nil },
                set: { if !$0 { dismissMessage() } }
            )
        ) {
            // The binding's setter clears the message shown (once, whichever way the alert closes).
            Button("OK", role: .cancel) {}
                .accessibilityIdentifier("offlineStatusBanner.refusedOK")
        } message: {
            Text(outbox.lastRefusalMessage ?? outbox.lastNoticeMessage ?? "")
        }
    }

    private func dismissMessage() {
        if outbox.lastRefusalMessage != nil {
            outbox.lastRefusalMessage = nil
        } else {
            outbox.lastNoticeMessage = nil
        }
    }

    @ViewBuilder
    private var bannerContent: some View {
        if smartCache.isSyncing {
            Button {
                showingQueue = true
            } label: {
                statusRow(
                    icon: "arrow.triangle.2.circlepath",
                    tint: .blue,
                    message: syncingMessage,
                    showsChevron: true
                )
            }
            .accessibilityIdentifier("offlineStatusBanner.arrowTriangle2Circlepath")
            .buttonStyle(.plain)
        } else if !smartCache.isOnline {
            Button {
                showingQueue = true
            } label: {
                statusRow(
                    icon: "wifi.slash",
                    tint: .orange,
                    message: offlineMessage,
                    showsChevron: true
                )
            }
            .accessibilityIdentifier("offlineStatusBanner.wifiSlash")
            .buttonStyle(.plain)
        } else if smartCache.pendingSyncCount > 0 {
            Button {
                showingQueue = true
            } label: {
                statusRow(
                    icon: "icloud.and.arrow.up",
                    tint: .orange,
                    message: "\(smartCache.pendingSyncCount) change\(smartCache.pendingSyncCount == 1 ? "" : "s") waiting to sync. Tap to see the queue.",
                    showsChevron: true
                )
            }
            .accessibilityIdentifier("offlineStatusBanner.icloudAndArrowUp")
            .buttonStyle(.plain)
        } else if smartCache.failedSyncCount > 0 {
            Button {
                showingQueue = true
            } label: {
                statusRow(
                    icon: "exclamationmark.triangle.fill",
                    tint: .red,
                    message: "\(smartCache.failedSyncCount) change\(smartCache.failedSyncCount == 1 ? "" : "s") could not sync. Tap to review and retry.",
                    showsChevron: true
                )
            }
            .accessibilityIdentifier("offlineStatusBanner.exclamationmarkTriangleFill")
            .buttonStyle(.plain)
        }
    }

    private var offlineMessage: String {
        if smartCache.pendingSyncCount > 0 {
            return "You are working offline. \(smartCache.pendingSyncCount) change\(smartCache.pendingSyncCount == 1 ? "" : "s") will sync when signal returns. Tap to see the queue."
        }
        return "You are working offline. Bookings, deadlines, and material changes stay on this device and sync when signal returns. Tap to see the queue."
    }

    private var syncingMessage: String {
        if smartCache.pendingSyncCount > 0 {
            return "Syncing \(smartCache.pendingSyncCount) change\(smartCache.pendingSyncCount == 1 ? "" : "s")…"
        }
        return "Syncing your offline changes…"
    }

    private func statusRow(icon: String, tint: Color, message: String, showsChevron: Bool) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(tint)
                .padding(.top, 1)
            Text(message)
                .font(.footnote)
                .foregroundStyle(.primary)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            if showsChevron {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.top, 2)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(tint.opacity(0.12))
        .overlay(alignment: .bottom) {
            Divider()
        }
    }
}

struct OfflineSyncQueueSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var smartCache: SmartCacheService
    @ObservedObject private var outbox = OfflineOutboxStore.shared

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack {
                        Text(smartCache.isOnline ? "Online" : "Offline")
                            .font(.subheadline.weight(.semibold))
                        Spacer()
                        if smartCache.isSyncing {
                            ProgressView()
                        }
                    }
                    if outbox.entries.isEmpty {
                        Text("Nothing waiting to sync.")
                            .foregroundStyle(.secondary)
                    }
                }

                if !outbox.entries.isEmpty {
                    Section("Waiting to sync") {
                        ForEach(outbox.entries) { entry in
                            VStack(alignment: .leading, spacing: 4) {
                                HStack(spacing: 6) {
                                    Text(entry.displayTitle)
                                        .font(.subheadline.weight(.semibold))
                                    Spacer(minLength: 4)
                                    PendingSyncBadge()
                                }
                                Text(entry.displayDetail)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                if entry.operation == .deleteBooking || entry.operation == .deleteManagerSiteBooking {
                                    // RULEBOOK 1.33.0 (owner decision 4 Nov): a queued delete can be undone here.
                                    Button("Undo delete") {
                                        OfflineSyncCoordinator.undoDelete(entryId: entry.id)
                                    }
                                    .buttonStyle(.borderless)
                                    .font(.caption.weight(.semibold))
                                    .disabled(smartCache.isSyncing)
                                    .accessibilityIdentifier("offlineSyncQueue.undoDelete")
                                }
                                if OfflineSyncCoordinator.reachedAttemptLimit(entry) {
                                    stuckEntryControls(entry)
                                }
                            }
                            .padding(.vertical, 2)
                        }
                    }
                }
            }
            .navigationTitle("Changes to sync")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                        .accessibilityIdentifier("offlineSyncQueue.done")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Retry now") {
                        Task { await smartCache.refreshConnectionAndSync() }
                    }
                    .accessibilityIdentifier("offlineSyncQueue.retryNow")
                    .disabled(smartCache.isSyncing)
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    /// An entry that stopped retrying on its own: try again, or drop it (and its local copy) for good.
    @ViewBuilder
    private func stuckEntryControls(_ entry: OfflineOutboxEntry) -> some View {
        Text("Couldn't sync after \(OfflineSyncCoordinator.maxAttempts) tries.")
            .font(.caption.weight(.semibold))
            .foregroundStyle(.red)
        HStack(spacing: 16) {
            Button("Retry") {
                OfflineSyncCoordinator.retry(entryId: entry.id)
                Task { await smartCache.refreshConnectionAndSync() }
            }
            .buttonStyle(.borderless)
            .disabled(smartCache.isSyncing)
            .accessibilityIdentifier("offlineSyncQueue.retryEntry")
            Button("Discard", role: .destructive) {
                OfflineSyncCoordinator.discard(entryId: entry.id)
            }
            .buttonStyle(.borderless)
            .disabled(smartCache.isSyncing)
            .accessibilityIdentifier("offlineSyncQueue.discardEntry")
        }
        .font(.caption.weight(.semibold))
    }
}
