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

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if notificationService.notifications.isEmpty {
                    ScrollView {
                        VStack(spacing: 0) {
                            notificationsNavyBand
                            VStack(spacing: 14) {
                                PPIconTile(symbol: "bell.slash", family: .system, size: PPMetrics.quickActionIcon, lifted: true)
                                Text("No Notifications")
                                    .font(.system(.title3, design: .rounded))
                                    .fontWeight(.semibold)
                                    .foregroundStyle(.primary)
                                Text("You're all caught up!")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity, minHeight: 320)
                            .padding(.top, 56)
                            .ppContentSheet()
                        }
                    }
                    .refreshable {
                        await notificationService.loadNotifications()
                    }
                } else {
                    ScrollView {
                        VStack(spacing: 0) {
                            notificationsNavyBand
                            LazyVStack(spacing: 10) {
                                ForEach(notificationService.notifications) { notification in
                                    Button {
                                        open(notification)
                                    } label: {
                                        NotificationRowView(notification: notification)
                                    }
                                    .accessibilityIdentifier("notifications.row.\(notification.id)")
                                    .buttonStyle(.plain)
                                }
                            }
                            .padding(.top, 18)
                            .padding(.bottom, 24)
                            .ppContentSheet()
                        }
                    }
                    .refreshable {
                        await notificationService.loadNotifications()
                    }
                }
            }
            .background(PPColor.page.ignoresSafeArea())
            .navigationTitle("Notifications")
            .navigationBarTitleDisplayMode(.inline)
            .ppNavyNavigationBar()
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .accessibilityIdentifier("notifications.done")
                        .fontWeight(.semibold)
                        .foregroundStyle(.white)
                }
            }
            .task {
                // Inbox is intentionally not loaded on app launch (jetsam risk). Load here on demand.
                // Opening the centre does not mark rows read. The in-app number stays until a row is opened.
                await notificationService.loadNotifications()
            }
        }
    }

    /// Navy strip under the navy bar so the light sheet slides up over it, as on Home.
    private var notificationsNavyBand: some View {
        Color.clear
            .frame(maxWidth: .infinity)
            .frame(height: PPMetrics.headerBottomPadding)
            .ppNavyHeader()
    }

    private func open(_ notification: AppNotification) {
        Task { await notificationService.markAsRead(notification) }
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
        HStack(alignment: .top, spacing: 13) {
            PPIconTile(symbol: iconForType(notification.type), family: familyForType(notification.type), size: 36)

            VStack(alignment: .leading, spacing: 5) {
                Text(notification.title)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.leading)

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
                    .accessibilityIdentifier("notificationRow.showLess")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(PPColor.brand)
                    .buttonStyle(.plain)
                }

                Text(notification.createdAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption.weight(.medium))
                    .monospacedDigit()
                    .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .background(PPColor.card, in: RoundedRectangle(cornerRadius: PPMetrics.rowCardRadius, style: .continuous))
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
        case .qualificationExpiry: return "checkmark.seal"
        case .materialOrderCutOff: return "shippingbox"
        case .materialAdded, .materialOrderPlaced: return "shippingbox.fill"
        case .toolboxTalkIssued, .hsToolboxReminder: return "list.clipboard.fill"
        case .ideaStatus, .ideaShipped: return "lightbulb.fill"
        case .holidayRequestSubmitted: return "sun.max"
        case .holidayRequestApproved: return "sun.max.fill"
        case .holidayRequestDeclined: return "xmark.circle.fill"
        case .timesheetPendingManagerSignoff: return "signature"
        case .timesheetSignedByManager: return "checkmark.seal.fill"
        case .lineManagerPeerUpdate: return "person.2.fill"
        case .variationAdded, .variationFromTracker, .variationNumbersUpdated: return "plus.rectangle.on.folder"
        case .timesheetSubmissionReminder: return "clock.badge.exclamationmark"
        }
    }

    /// Icon-tile colour family for each type (Home's families; red only for warnings and declines).
    private func familyForType(_ type: AppNotification.NotificationType) -> PPFamily {
        switch type {
        case .bookingCreated: return .plan
        case .operativeCreated: return .people
        case .managerCreated: return .people
        case .clientCreated: return .people
        case .projectCreated: return .sites
        case .smallWorksCreated: return .trade
        case .bookingClash: return .alert
        case .warningRemoved: return .trade
        case .taskCompleted: return .sites
        case .taskCreated: return .plan
        case .deadlineAssigned, .deadlineReminder, .deadlineDue: return .trade
        case .qualificationExpiry: return .trade
        case .materialOrderCutOff: return .trade
        case .materialAdded, .materialOrderPlaced: return .sites
        case .toolboxTalkIssued, .hsToolboxReminder: return .plan
        case .ideaStatus, .ideaShipped: return .sites
        case .holidayRequestSubmitted: return .trade
        case .holidayRequestApproved: return .sites
        case .holidayRequestDeclined: return .alert
        case .timesheetPendingManagerSignoff: return .trade
        case .timesheetSignedByManager: return .sites
        case .lineManagerPeerUpdate: return .people
        case .variationAdded, .variationFromTracker, .variationNumbersUpdated: return .trade
        case .timesheetSubmissionReminder: return .trade
        }
    }
}

#Preview {
    NotificationsView()
        .environmentObject(NotificationService())
}
