//
//  NotSyncedView.swift
//  Project Planner
//
//  RULEBOOK 1.86.0 §2 (owner decision 24 Nov): "Not synced" — one row per queued action the server refused when this
//  phone came back online (`OfflineSyncResultStore`, rows from `offlineSyncResultRows`): what the person tried, what
//  changed while they were offline, when, "Open day" (Daily Overview on that day) and "Got it" (clears the row).
//

import SwiftUI
import FirebaseAuth

struct NotSyncedView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var results = OfflineSyncResultStore.shared
    @State private var openDay: NotSyncedDay?

    private var rows: [RulebookOfflineSyncResultRow] {
        results.rows(userId: Auth.auth().currentUser?.uid)
    }

    var body: some View {
        NavigationStack {
            List {
                if rows.isEmpty {
                    Text(CanonicalBusinessEngine.offlineSyncResultEmpty)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(rows) { row in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(row.title)
                                .font(.subheadline.weight(.semibold))
                                .fixedSize(horizontal: false, vertical: true)
                            Text(row.detail)
                                .font(.subheadline)
                                .foregroundStyle(.orange)
                            if !row.whenText.isEmpty {
                                Text(row.whenText)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            HStack(spacing: 16) {
                                if let dayKey = row.dayKey,
                                   let date = CanonicalBusinessEngine.date(fromDayKey: dayKey) {
                                    Button(row.openDayLabel) { openDay = NotSyncedDay(date: date) }
                                        .accessibilityIdentifier("notSynced.\(row.id).openDay")
                                }
                                Spacer()
                                Button(row.dismissLabel) { results.dismiss(id: row.id) }
                                    .accessibilityIdentifier("notSynced.\(row.id).gotIt")
                            }
                            .buttonStyle(.borderless)
                            .font(.subheadline.weight(.semibold))
                        }
                        .padding(.vertical, 4)
                    }
                }
            }
            .navigationTitle(CanonicalBusinessEngine.offlineSyncResultTitle)
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(item: $openDay) { day in
                DailyOverviewView(displayDate: day.date)
            }
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .accessibilityIdentifier("notSynced.done")
                }
            }
            .onAppear {
                OfflineSyncResultNotification.pendingOpen = false
                results.markSeen()
            }
        }
    }
}

private struct NotSyncedDay: Identifiable, Hashable {
    let date: Date
    var id: TimeInterval { date.timeIntervalSince1970 }
}
