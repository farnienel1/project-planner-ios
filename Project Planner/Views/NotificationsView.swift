//
//  NotificationsView.swift
//  Project Planner
//
//  Created by Assistant on 06/12/2025.
//

import SwiftUI

struct NotificationsView: View {
    @EnvironmentObject var notificationService: NotificationService
    @Environment(\.dismiss) private var dismiss

    @State private var filterOption: FilterOption = .newest
    @State private var showingFilterOptions = false

    enum FilterOption: String, CaseIterable {
        case newest = "Newest"
        case oldest = "Oldest"
        case date = "Date"

        var displayName: String { rawValue }
    }

    var filteredNotifications: [AppNotification] {
        let sorted: [AppNotification]
        switch filterOption {
        case .newest:
            sorted = notificationService.notifications.sorted { $0.createdAt > $1.createdAt }
        case .oldest:
            sorted = notificationService.notifications.sorted { $0.createdAt < $1.createdAt }
        case .date:
            let grouped = Dictionary(grouping: notificationService.notifications) { notification in
                Calendar.current.startOfDay(for: notification.createdAt)
            }
            sorted = grouped.values.flatMap { $0 }.sorted { $0.createdAt > $1.createdAt }
        }
        return Array(sorted.prefix(100))
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                HStack {
                    Spacer()
                    Button {
                        showingFilterOptions = true
                    } label: {
                        Label("Filter", systemImage: "line.3.horizontal.decrease.circle")
                            .font(.subheadline)
                            .foregroundStyle(.blue)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(Color(.systemGroupedBackground))

                if filteredNotifications.isEmpty {
                    ScrollView {
                        VStack(spacing: 16) {
                            Image(systemName: "bell.slash")
                                .font(.system(size: 60))
                                .foregroundStyle(.secondary)
                            Text("No Notifications")
                                .font(.title2.weight(.semibold))
                            Text("You're all caught up!")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, minHeight: 320)
                        .padding(.top, 80)
                    }
                    .refreshable {
                        await notificationService.loadNotifications()
                    }
                } else {
                    List {
                        ForEach(filteredNotifications) { notification in
                            NotificationRowView(notification: notification)
                                .listRowSeparator(.visible)
                        }
                    }
                    .listStyle(.plain)
                    .refreshable {
                        await notificationService.loadNotifications()
                    }
                }
            }
            .navigationTitle("Notifications")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .confirmationDialog("Filter Notifications", isPresented: $showingFilterOptions, titleVisibility: .visible) {
                ForEach(FilterOption.allCases, id: \.self) { option in
                    Button(option.displayName) { filterOption = option }
                }
                Button("Cancel", role: .cancel) {}
            }
            .task {
                await notificationService.markAllAsRead()
            }
            .onDisappear {
                notificationService.prepareInboxPresentation()
            }
        }
    }
}

struct NotificationRowView: View {
    let notification: AppNotification

    @State private var isMessageExpanded = false

    private var messageExceedsPreview: Bool {
        let message = notification.message
        return message.count > 180 || message.contains("\n")
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: iconForType(notification.type))
                .font(.title3)
                .foregroundStyle(colorForType(notification.type))
                .frame(width: 30)

            VStack(alignment: .leading, spacing: 6) {
                Text(notification.title)
                    .font(.headline)
                    .foregroundStyle(.primary)

                Text(notification.message)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .lineLimit(isMessageExpanded ? nil : 6)

                if messageExceedsPreview {
                    Button(isMessageExpanded ? "Show less" : "Show more") {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            isMessageExpanded.toggle()
                        }
                    }
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.blue)
                    .buttonStyle(.plain)
                }

                Text(notification.createdAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 8)
    }

    private func iconForType(_ type: AppNotification.NotificationType) -> String {
        switch type {
        case .bookingCreated: return "calendar.badge.plus"
        case .operativeCreated: return "person.badge.plus"
        case .managerCreated: return "person.badge.key"
        case .clientCreated: return "person.2.badge.plus"
        case .projectCreated: return "folder.badge.plus"
        case .smallWorksCreated: return "hammer.fill"
        case .bookingClash: return "exclamationmark.triangle"
        case .warningRemoved: return "xmark.octagon"
        case .taskCompleted: return "checkmark.circle"
        case .taskCreated: return "list.bullet.rectangle"
        case .holidayRequestSubmitted: return "sun.max"
        case .holidayRequestApproved: return "sun.max.fill"
        case .holidayRequestDeclined: return "xmark.circle.fill"
        case .timesheetPendingManagerSignoff: return "signature"
        case .timesheetSignedByManager: return "checkmark.seal.fill"
        case .lineManagerPeerUpdate: return "person.2.fill"
        }
    }

    private func colorForType(_ type: AppNotification.NotificationType) -> Color {
        switch type {
        case .bookingCreated: return .blue
        case .operativeCreated: return .green
        case .managerCreated: return .purple
        case .clientCreated: return .orange
        case .projectCreated: return .indigo
        case .smallWorksCreated: return .orange
        case .bookingClash: return .red
        case .warningRemoved: return .orange
        case .taskCompleted: return .green
        case .taskCreated: return .blue
        case .holidayRequestSubmitted: return .orange
        case .holidayRequestApproved: return .green
        case .holidayRequestDeclined: return .red
        case .timesheetPendingManagerSignoff: return .orange
        case .timesheetSignedByManager: return .green
        case .lineManagerPeerUpdate: return .blue
        }
    }
}

#Preview {
    NotificationsView()
        .environmentObject(NotificationService())
}
