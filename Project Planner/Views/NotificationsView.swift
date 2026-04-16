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
    @EnvironmentObject var projectStore: ProjectStore
    @EnvironmentObject var operativeStore: OperativeStore
    @EnvironmentObject var bookingStore: BookingStore
    @EnvironmentObject var taskStore: ProjectTaskStore
    
    @Environment(\.dismiss) private var dismiss
    
    @State private var filterOption: FilterOption = .newest
    @State private var showingFilterOptions = false
    
    enum FilterOption: String, CaseIterable {
        case newest = "Newest"
        case oldest = "Oldest"
        case date = "Date"
        
        var displayName: String {
            return self.rawValue
        }
    }
    
    var filteredNotifications: [AppNotification] {
        let sorted: [AppNotification]
        
        switch filterOption {
        case .newest:
            sorted = notificationService.notifications.sorted { $0.createdAt > $1.createdAt }
        case .oldest:
            sorted = notificationService.notifications.sorted { $0.createdAt < $1.createdAt }
        case .date:
            // Group by date, then sort newest first within each date
            let grouped = Dictionary(grouping: notificationService.notifications) { notification in
                Calendar.current.startOfDay(for: notification.createdAt)
            }
            sorted = grouped.values.flatMap { $0 }
                .sorted { $0.createdAt > $1.createdAt }
        }
        
        // Limit to latest 100
        return Array(sorted.prefix(100))
    }
    
    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                // Filter Button
                HStack {
                    Spacer()
                    Button(action: {
                        showingFilterOptions = true
                    }) {
                        HStack {
                            Image(systemName: "line.3.horizontal.decrease.circle")
                            Text("Filter")
                        }
                        .font(.subheadline)
                        .foregroundColor(.blue)
                    }
                    .padding(.horizontal)
                    .padding(.vertical, 8)
                }
                .background(Color(.systemGroupedBackground))
                
                if filteredNotifications.isEmpty {
                    VStack(spacing: 16) {
                        Image(systemName: "bell.slash")
                            .font(.system(size: 60))
                            .foregroundColor(.secondary)
                        Text("No Notifications")
                            .font(.title2)
                            .fontWeight(.semibold)
                        Text("You're all caught up!")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List {
                        ForEach(filteredNotifications) { notification in
                            NotificationRowView(notification: notification)
                                .onTapGesture {
                                    handleNotificationTap(notification)
                                }
                        }
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle("Notifications")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
            .confirmationDialog("Filter Notifications", isPresented: $showingFilterOptions, titleVisibility: .visible) {
                ForEach(FilterOption.allCases, id: \.self) { option in
                    Button(option.displayName) {
                        filterOption = option
                    }
                }
                Button("Cancel", role: .cancel) {}
            }
            .onAppear {
                Task {
                    await notificationService.loadNotifications()
                }
            }
        }
    }
    
    private func handleNotificationTap(_ notification: AppNotification) {
        Task {
            // Mark as read
            await notificationService.markAsRead(notification)
            
            // Navigate based on notification type
            await MainActor.run {
                switch notification.type {
                case .bookingCreated:
                    if let bookingId = notification.relatedId {
                        // Navigate to booking or project
                        NotificationCenter.default.post(
                            name: NSNotification.Name("navigateToBooking"),
                            object: nil,
                            userInfo: ["bookingId": bookingId.uuidString]
                        )
                    }
                case .taskCreated, .taskCompleted:
                    if let taskId = notification.relatedId {
                        // Navigate to task
                        NotificationCenter.default.post(
                            name: NSNotification.Name("navigateToTask"),
                            object: nil,
                            userInfo: ["taskId": taskId.uuidString]
                        )
                    }
                case .operativeCreated:
                    if notification.relatedId != nil {
                        // Navigate to operatives tab
                        NotificationCenter.default.post(
                            name: NSNotification.Name("selectTab"),
                            object: nil,
                            userInfo: ["tab": 3]
                        )
                    }
                case .managerCreated:
                    if notification.relatedId != nil {
                        // Navigate to managers tab
                        NotificationCenter.default.post(
                            name: NSNotification.Name("selectTab"),
                            object: nil,
                            userInfo: ["tab": 4]
                        )
                    }
                case .clientCreated:
                    // Navigate to clients (if available)
                    NotificationCenter.default.post(
                        name: NSNotification.Name("navigateToClients"),
                        object: nil
                    )
                case .projectCreated:
                    NotificationCenter.default.post(
                        name: NSNotification.Name("selectTab"),
                        object: nil,
                        userInfo: ["tab": 1]
                    )
                case .smallWorksCreated:
                    NotificationCenter.default.post(
                        name: NSNotification.Name("selectTab"),
                        object: nil,
                        userInfo: ["tab": 2]
                    )
                case .bookingClash:
                    // Navigate to warnings or bookings
                    NotificationCenter.default.post(
                        name: NSNotification.Name("navigateToWarnings"),
                        object: nil
                    )
                case .holidayRequestSubmitted, .holidayRequestApproved:
                    NotificationCenter.default.post(
                        name: NSNotification.Name("openHoliday"),
                        object: nil,
                        userInfo: ["showRequests": true]
                    )
                }
                
                dismiss()
            }
        }
    }
}

struct NotificationRowView: View {
    let notification: AppNotification
    @EnvironmentObject var notificationService: NotificationService
    
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            // Icon based on type
            Image(systemName: iconForType(notification.type))
                .font(.title3)
                .foregroundColor(colorForType(notification.type))
                .frame(width: 30)
            
            VStack(alignment: .leading, spacing: 4) {
                Text(notification.title)
                    .font(.headline)
                    .foregroundColor(.primary)
                
                Text(notification.message)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .lineLimit(2)
                
                Text(notification.createdAt, style: .relative)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            
            Spacer()
            
            if !notification.isRead {
                Circle()
                    .fill(Color.blue)
                    .frame(width: 8, height: 8)
            }
        }
        .padding(.vertical, 8)
        .contentShape(Rectangle())
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
        case .taskCompleted: return "checkmark.circle"
        case .taskCreated: return "list.bullet.rectangle"
        case .holidayRequestSubmitted: return "sun.max"
        case .holidayRequestApproved: return "sun.max.fill"
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
        case .taskCompleted: return .green
        case .taskCreated: return .blue
        case .holidayRequestSubmitted: return .orange
        case .holidayRequestApproved: return .green
        }
    }
}

#Preview {
    NotificationsView()
        .environmentObject(NotificationService())
        .environmentObject(UserStore())
        .environmentObject(ProjectStore())
        .environmentObject(OperativeStore())
        .environmentObject(BookingStore())
        .environmentObject(ProjectTaskStore())
}

