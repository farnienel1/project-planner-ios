//
//  OfflineStatusBanner.swift
//  Project Planner
//

import SwiftUI

struct OfflineStatusBanner: View {
    @EnvironmentObject private var smartCache: SmartCacheService
    @State private var showingQueue = false

    var body: some View {
        if smartCache.showOfflineBanner {
            bannerContent
                .transition(.move(edge: .top).combined(with: .opacity))
                .sheet(isPresented: $showingQueue) {
                    OfflineSyncQueueSheet()
                        .environmentObject(smartCache)
                }
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
            .buttonStyle(.plain)
        }
    }

    private var offlineMessage: String {
        if smartCache.pendingSyncCount > 0 {
            return "You are working offline. \(smartCache.pendingSyncCount) change\(smartCache.pendingSyncCount == 1 ? "" : "s") will sync when signal returns. Tap to see the queue."
        }
        return "You are working offline. Bookings and material changes stay on this device and sync when signal returns. Tap to see the queue."
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
                                Text(entry.displayTitle)
                                    .font(.subheadline.weight(.semibold))
                                Text(entry.displayDetail)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
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
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Retry now") {
                        Task { await smartCache.refreshConnectionAndSync() }
                    }
                    .disabled(smartCache.isSyncing)
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}
