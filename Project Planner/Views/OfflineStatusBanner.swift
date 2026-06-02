//
//  OfflineStatusBanner.swift
//  Project Planner
//

import SwiftUI

struct OfflineStatusBanner: View {
    @EnvironmentObject private var smartCache: SmartCacheService

    var body: some View {
        if smartCache.showOfflineBanner {
            bannerContent
                .transition(.move(edge: .top).combined(with: .opacity))
        }
    }

    @ViewBuilder
    private var bannerContent: some View {
        if smartCache.isSyncing {
            statusRow(
                icon: "arrow.triangle.2.circlepath",
                tint: .blue,
                message: syncingMessage
            )
        } else if !smartCache.isOnline {
            statusRow(
                icon: "wifi.slash",
                tint: .orange,
                message: "You are working offline. Any changes or bookings made will only appear for other users when your signal is restored."
            )
        } else if smartCache.pendingSyncCount > 0 {
            statusRow(
                icon: "icloud.and.arrow.up",
                tint: .orange,
                message: "\(smartCache.pendingSyncCount) change\(smartCache.pendingSyncCount == 1 ? "" : "s") waiting to sync. They will appear for other users once syncing completes."
            )
        } else if smartCache.failedSyncCount > 0 {
            Button {
                Task { await smartCache.retryFailedSync() }
            } label: {
                statusRow(
                    icon: "exclamationmark.triangle.fill",
                    tint: .red,
                    message: "\(smartCache.failedSyncCount) change\(smartCache.failedSyncCount == 1 ? "" : "s") could not sync. Tap to retry."
                )
            }
            .buttonStyle(.plain)
        }
    }

    private var syncingMessage: String {
        if smartCache.pendingSyncCount > 0 {
            return "Syncing \(smartCache.pendingSyncCount) change\(smartCache.pendingSyncCount == 1 ? "" : "s")…"
        }
        return "Syncing your offline changes…"
    }

    private func statusRow(icon: String, tint: Color, message: String) -> some View {
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
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(tint.opacity(0.12))
        .overlay(alignment: .bottom) {
            Divider()
        }
    }
}
