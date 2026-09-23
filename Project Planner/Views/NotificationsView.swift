//
//  NotificationsView.swift
//  Project Planner
//
//  Created by Assistant on 06/12/2025.
//

import SwiftUI

struct NotificationsView: View {
    @EnvironmentObject var notificationService: NotificationService
    @EnvironmentObject var userStore: UserStore
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
        return Array(sorted.prefix(150))
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                HStack {
                    Text(filterOption.displayName)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(ProjectWorksRevampColors.muted)
                    Spacer()
                    Button {
                        showingFilterOptions = true
                    } label: {
                        Label("Filter", systemImage: "line.3.horizontal.decrease.circle")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(ProjectWorksRevampColors.blue)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)

                if filteredNotifications.isEmpty {
                    ScrollView {
                        VStack(spacing: 16) {
                            Image(systemName: "bell.slash")
                                .font(.system(size: 52))
                                .foregroundStyle(ProjectWorksRevampColors.muted)
                            Text("No Notifications")
                                .font(.system(size: 18, weight: .semibold))
                                .foregroundStyle(ProjectWorksRevampColors.ink)
                            Text("You're all caught up!")
                                .font(.system(size: 13))
                                .foregroundStyle(ProjectWorksRevampColors.muted)
                        }
                        .frame(maxWidth: .infinity, minHeight: 320)
                        .padding(.top, 80)
                    }
                    .refreshable {
                        await notificationService.loadNotifications()
                    }
                } else {
                    ScrollView {
                        LazyVStack(spacing: 10) {
                            ForEach(filteredNotifications) { notification in
                                Button {
                                    open(notification)
                                } label: {
                                    NotificationRowView(notification: notification)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                    }
                    .refreshable {
                        await notificationService.loadNotifications()
                    }
                }
            }
            .background(ProjectWorksRevampColors.canvas.ignoresSafeArea())
            .navigationTitle("Notifications")
            .navigationBarTitleDisplayMode(.inline)
            .appChromeNavigationBarSurface()
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
                // Inbox is intentionally not loaded on app launch (jetsam risk). Load here on demand.
                await notificationService.loadNotifications()
                await notificationService.markAllAsRead()
            }
            .onDisappear {
                notificationService.prepareInboxPresentation()
            }
        }
    }

    private func open(_ notification: AppNotification) {
        dismiss()
        let info = NotificationDeepLink.userInfo(for: notification)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            NotificationCenter.default.post(name: .openNotificationDeepLink, object: nil, userInfo: info)
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
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(colorForType(notification.type))
                .frame(width: 36, height: 36)
                .background(colorForType(notification.type).opacity(0.14))
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

            VStack(alignment: .leading, spacing: 6) {
                Text(notification.title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(ProjectWorksRevampColors.ink)
                    .multilineTextAlignment(.leading)

                Text(notification.message)
                    .font(.system(size: 13))
                    .foregroundStyle(ProjectWorksRevampColors.muted)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .lineLimit(isMessageExpanded ? nil : 6)

                if messageExceedsPreview {
                    Button(isMessageExpanded ? "Show less" : "Show more") {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            isMessageExpanded.toggle()
                        }
                    }
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(ProjectWorksRevampColors.blue)
                    .buttonStyle(.plain)
                }

                Text(notification.createdAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(ProjectWorksRevampColors.placeholderInk)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .background(ProjectWorksRevampColors.surface)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(ProjectWorksRevampColors.border, lineWidth: 0.5)
        )
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
        case .deadlineAssigned, .deadlineReminder, .deadlineDue: return "calendar.badge.clock"
        case .materialAdded: return "shippingbox.fill"
        case .toolboxTalkIssued: return "list.clipboard.fill"
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
        case .bookingCreated: return ProjectWorksRevampColors.blue
        case .operativeCreated: return ProjectWorksRevampColors.activeGreen
        case .managerCreated: return ProjectWorksRevampColors.jobTypePillInk
        case .clientCreated: return ProjectWorksRevampColors.upcomingAmber
        case .projectCreated: return ProjectWorksRevampColors.blueLight
        case .smallWorksCreated: return ProjectWorksRevampColors.upcomingAmber
        case .bookingClash: return ProjectWorksRevampColors.requiredPillFg
        case .warningRemoved: return ProjectWorksRevampColors.upcomingAmber
        case .taskCompleted: return ProjectWorksRevampColors.activeGreen
        case .taskCreated: return ProjectWorksRevampColors.blue
        case .deadlineAssigned, .deadlineReminder, .deadlineDue: return ProjectWorksRevampColors.upcomingAmber
        case .materialAdded: return ProjectWorksRevampColors.activeGreen
        case .toolboxTalkIssued: return ProjectWorksRevampColors.blueLight
        case .holidayRequestSubmitted: return ProjectWorksRevampColors.upcomingAmber
        case .holidayRequestApproved: return ProjectWorksRevampColors.activeGreen
        case .holidayRequestDeclined: return ProjectWorksRevampColors.requiredPillFg
        case .timesheetPendingManagerSignoff: return ProjectWorksRevampColors.upcomingAmber
        case .timesheetSignedByManager: return ProjectWorksRevampColors.activeGreen
        case .lineManagerPeerUpdate: return ProjectWorksRevampColors.blue
        }
    }
}

#Preview {
    NotificationsView()
        .environmentObject(NotificationService())
}
