//
//  NotificationService.swift
//  Project Planner
//
//  Created by Assistant on 26/11/2025.
//

import Foundation
import Combine

@MainActor
class NotificationService: ObservableObject {
    @Published var notifications: [AppNotification] = []
    @Published var unreadCount: Int = 0
    
    private var firebaseBackend: FirebaseBackend?
    private var userStore: UserStore?
    private var operativeStore: OperativeStore?
    
    func setFirebaseBackend(_ backend: FirebaseBackend) {
        self.firebaseBackend = backend
    }
    
    func setUserStore(_ store: UserStore) {
        self.userStore = store
    }
    
    func setOperativeStore(_ store: OperativeStore) {
        self.operativeStore = store
    }
    
    // MARK: - Notification Creation
    
    func notifyBookingCreated(bookingId: UUID, operativeId: UUID, projectName: String, date: Date, createdBy: String) async {
        guard let firebaseBackend = firebaseBackend,
              let organizationId = firebaseBackend.currentOrganization?.firestoreDocumentId else { return }
        
        // Notify the specific operative who was booked
        if let userStore = userStore, let operativeStore = operativeStore {
            await userStore.loadOrganizationUsers()
            
            // Find the operative by ID
            if let operative = operativeStore.allOperatives.first(where: { $0.id == operativeId }) {
                // Find the AppUser for this operative by matching email
                if let operativeUser = userStore.organizationUsers.first(where: { user in
                    user.email.lowercased() == operative.email.lowercased() && user.permissions.operativeMode
                }) {
                    // Create notification for this specific operative
                    let notification = AppNotification(
                        organizationId: organizationId,
                        type: .bookingCreated,
                        title: "You've Been Booked",
                        message: "\(createdBy) booked you for \(projectName) on \(date.formatted(date: .abbreviated, time: .omitted))",
                        userId: operativeUser.id, // Target specific operative
                        relatedId: bookingId,
                        requiresPermission: nil // No permission check needed since it's user-specific
                    )
                    await saveNotification(notification)
                }
            }
        }
        
        // Also notify admins and managers
        let adminManagerNotification = AppNotification(
            organizationId: organizationId,
            type: .bookingCreated,
            title: "New Booking Created",
            message: "\(createdBy) created a booking for \(projectName) on \(date.formatted(date: .abbreviated, time: .omitted))",
            relatedId: bookingId,
            requiresPermission: "canBookWork" // Admins and managers who can book work
        )
        await saveNotification(adminManagerNotification)
    }
    
    func notifyOperativeCreated(operativeId: UUID, operativeName: String, createdBy: String) async {
        guard let firebaseBackend = firebaseBackend,
              let organizationId = firebaseBackend.currentOrganization?.firestoreDocumentId else { return }
        
        // Only notify users who can view operatives
        let notification = AppNotification(
            organizationId: organizationId,
            type: .operativeCreated,
            title: "New Operative Created",
            message: "\(createdBy) created a new operative: \(operativeName)",
            relatedId: operativeId,
            requiresPermission: "canViewOperatives"
        )
        
        await saveNotification(notification)
    }
    
    func notifyManagerCreated(managerId: UUID, managerName: String, createdBy: String) async {
        guard let firebaseBackend = firebaseBackend,
              let organizationId = firebaseBackend.currentOrganization?.firestoreDocumentId else { return }
        
        // Only notify users who can view managers
        let notification = AppNotification(
            organizationId: organizationId,
            type: .managerCreated,
            title: "New Manager Created",
            message: "\(createdBy) created a new manager: \(managerName)",
            relatedId: managerId,
            requiresPermission: "canViewManagers"
        )
        
        await saveNotification(notification)
    }
    
    func notifyClientCreated(clientId: UUID, clientName: String, createdBy: String) async {
        guard let firebaseBackend = firebaseBackend,
              let organizationId = firebaseBackend.currentOrganization?.firestoreDocumentId else { return }
        
        let notification = AppNotification(
            organizationId: organizationId,
            type: .clientCreated,
            title: "New Client Created",
            message: "\(createdBy) added a new client: \(clientName)",
            relatedId: clientId,
            requiresPermission: "superAdminOrAdmin"
        )
        
        await saveNotification(notification)
    }
    
    func notifyProjectCreated(projectId: UUID, siteName: String, jobNumber: String, createdBy: String) async {
        guard let firebaseBackend = firebaseBackend,
              let organizationId = firebaseBackend.currentOrganization?.firestoreDocumentId else { return }
        
        let detail = jobNumber.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? siteName
            : "\(jobNumber) · \(siteName)"
        let notification = AppNotification(
            organizationId: organizationId,
            type: .projectCreated,
            title: "New Project",
            message: "\(createdBy) added a new project: \(detail)",
            relatedId: projectId,
            requiresPermission: "superAdminOrAdmin"
        )
        await saveNotification(notification)
    }
    
    func notifySmallWorksCreated(smallWorkId: UUID, siteName: String, jobNumber: String, createdBy: String) async {
        guard let firebaseBackend = firebaseBackend,
              let organizationId = firebaseBackend.currentOrganization?.firestoreDocumentId else { return }
        
        let detail = jobNumber.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? siteName
            : "\(jobNumber) · \(siteName)"
        let notification = AppNotification(
            organizationId: organizationId,
            type: .smallWorksCreated,
            title: "New Small Works",
            message: "\(createdBy) added new small works: \(detail)",
            relatedId: smallWorkId,
            requiresPermission: "superAdminOrAdmin"
        )
        await saveNotification(notification)
    }
    
    func notifyBookingClash(booking1Id: UUID, booking2Id: UUID, operativeName: String, date: Date, userId1: String, userId2: String) async {
        guard let firebaseBackend = firebaseBackend,
              let organizationId = firebaseBackend.currentOrganization?.firestoreDocumentId else { return }
        
        let message = "Booking clash detected for \(operativeName) on \(date.formatted(date: .abbreviated, time: .omitted))"
        
        // Send notification to both users involved in the clash
        let notification1 = AppNotification(
            organizationId: organizationId,
            type: .bookingClash,
            title: "Booking Clash",
            message: message,
            userId: userId1,
            relatedId: booking1Id,
            requiresPermission: "canBookWork"
        )
        
        let notification2 = AppNotification(
            organizationId: organizationId,
            type: .bookingClash,
            title: "Booking Clash",
            message: message,
            userId: userId2,
            relatedId: booking2Id,
            requiresPermission: "canBookWork"
        )
        
        await saveNotification(notification1)
        await saveNotification(notification2)
    }
    
    func notifyTaskCompleted(taskId: UUID, taskTitle: String, completedBy: String, assignedToUserId: String) async {
        guard let firebaseBackend = firebaseBackend,
              let organizationId = firebaseBackend.currentOrganization?.firestoreDocumentId else { return }
        
        // Only notify the user who assigned the task
        let notification = AppNotification(
            organizationId: organizationId,
            type: .taskCompleted,
            title: "Task Completed",
            message: "\(completedBy) completed the task: \(taskTitle)",
            userId: assignedToUserId,
            relatedId: taskId,
            requiresPermission: nil // Task creator always gets notified
        )
        
        await saveNotification(notification)
    }
    
    func notifyTaskCreated(taskId: UUID, taskTitle: String, createdBy: String, assignedOperativeIds: [UUID], assignedManagerIds: [UUID]) async {
        guard let firebaseBackend = firebaseBackend,
              let organizationId = firebaseBackend.currentOrganization?.firestoreDocumentId else { return }
        
        // Notify only the specific operatives assigned to this task
        // We need to match operative IDs to AppUser emails
        if let userStore = userStore, let operativeStore = operativeStore {
            // Load organization users to find operative user IDs
            await userStore.loadOrganizationUsers()
            
            // Get operatives from operativeStore to match by ID
            let operatives = operativeStore.allOperatives
            
            for operativeId in assignedOperativeIds {
                // Find the operative by ID
                if let operative = operatives.first(where: { $0.id == operativeId }) {
                    // Find the AppUser for this operative by matching email
                    if let operativeUser = userStore.organizationUsers.first(where: { user in
                        user.email.lowercased() == operative.email.lowercased() && user.permissions.operativeMode
                    }) {
                        // Create notification for this specific operative
                        let notification = AppNotification(
                            organizationId: organizationId,
                            type: .taskCreated,
                            title: "New Task Assigned",
                            message: "\(createdBy) assigned you a new task: \(taskTitle)",
                            userId: operativeUser.id, // Target specific operative
                            relatedId: taskId,
                            requiresPermission: nil // No permission check needed since it's user-specific
                        )
                        await saveNotification(notification)
                    }
                }
            }
        }
        
        // Also notify admins and managers (not operative mode users)
        let adminManagerNotification = AppNotification(
            organizationId: organizationId,
            type: .taskCreated,
            title: "New Task Created",
            message: "\(createdBy) created a new task: \(taskTitle)",
            relatedId: taskId,
            requiresPermission: "canViewProjects" // Admins and managers can view projects
        )
        await saveNotification(adminManagerNotification)
    }

    func notifyHolidayRequestSubmitted(bookingId: UUID, operativeName: String, startDate: Date, endDate: Date) async {
        guard let firebaseBackend = firebaseBackend,
              let organizationId = firebaseBackend.currentOrganization?.firestoreDocumentId else { return }
        let dateRange = "\(startDate.formatted(date: .abbreviated, time: .omitted)) – \(endDate.formatted(date: .abbreviated, time: .omitted))"
        let notification = AppNotification(
            organizationId: organizationId,
            type: .holidayRequestSubmitted,
            title: "Holiday Request",
            message: "\(operativeName) requested holiday \(dateRange). Tap to review.",
            relatedId: bookingId,
            requiresPermission: "canViewManagers"
        )
        await saveNotification(notification)
    }

    func notifyHolidayRequestSubmittedByUser(bookingId: UUID, requesterName: String, startDate: Date, endDate: Date) async {
        guard let firebaseBackend = firebaseBackend,
              let organizationId = firebaseBackend.currentOrganization?.firestoreDocumentId else { return }
        let dateRange = "\(startDate.formatted(date: .abbreviated, time: .omitted)) – \(endDate.formatted(date: .abbreviated, time: .omitted))"
        let notification = AppNotification(
            organizationId: organizationId,
            type: .holidayRequestSubmitted,
            title: "Holiday Request",
            message: "\(requesterName) requested holiday \(dateRange). Tap to review.",
            relatedId: bookingId,
            requiresPermission: "hasAdminAccess"
        )
        await saveNotification(notification)
    }

    func notifyHolidayRequestApproved(bookingId: UUID, operativeName: String, approvedByName: String) async {
        guard let firebaseBackend = firebaseBackend,
              let organizationId = firebaseBackend.currentOrganization?.firestoreDocumentId else { return }
        let notification = AppNotification(
            organizationId: organizationId,
            type: .holidayRequestApproved,
            title: "Holiday Approved",
            message: "\(approvedByName) approved \(operativeName)'s holiday request.",
            relatedId: bookingId,
            requiresPermission: "canViewManagers"
        )
        await saveNotification(notification)
    }

    func notifyHolidayRequestDecisionToUser(userId: String, bookingId: UUID, approved: Bool, decidedByName: String) async {
        guard let firebaseBackend = firebaseBackend,
              let organizationId = firebaseBackend.currentOrganization?.firestoreDocumentId else { return }
        let notification = AppNotification(
            organizationId: organizationId,
            type: approved ? .holidayRequestApproved : .holidayRequestApproved,
            title: approved ? "Holiday Approved" : "Holiday Declined",
            message: approved ? "\(decidedByName) approved your holiday request." : "\(decidedByName) declined your holiday request.",
            userId: userId,
            relatedId: bookingId,
            requiresPermission: nil
        )
        await saveNotification(notification)
    }

    // MARK: - Notification Management
    
    func loadNotifications() async {
        guard let firebaseBackend = firebaseBackend,
              let organizationId = firebaseBackend.currentOrganization?.firestoreDocumentId,
              let currentUser = userStore?.currentUser else { return }
        
        do {
            let allNotifications = try await firebaseBackend.loadNotifications(organizationId: organizationId)
            
            // Filter notifications based on user permissions
            let filteredNotifications = allNotifications.filter { notification in
                shouldShowNotification(notification, for: currentUser)
            }
            
            await MainActor.run {
                self.notifications = filteredNotifications.sorted { $0.createdAt > $1.createdAt }
                self.unreadCount = self.notifications.filter { !$0.isRead }.count
            }
        } catch {
            print("🔥🔥🔥 DEBUG: Error loading notifications: \(error)")
        }
    }
    
    func markAsRead(_ notification: AppNotification) async {
        guard let firebaseBackend = firebaseBackend,
              let organizationId = firebaseBackend.currentOrganization?.firestoreDocumentId else { return }
        
        var updatedNotification = notification
        updatedNotification.isRead = true
        
        do {
            try await firebaseBackend.saveNotification(updatedNotification, organizationId: organizationId)
            
            if let index = notifications.firstIndex(where: { $0.id == notification.id }) {
                notifications[index] = updatedNotification
                unreadCount = notifications.filter { !$0.isRead }.count
            }
        } catch {
            print("🔥🔥🔥 DEBUG: Error marking notification as read: \(error)")
        }
    }

    /// Mark all notifications as read. Call when the user opens the notification list so the badge clears.
    func markAllAsRead() async {
        guard let firebaseBackend = firebaseBackend,
              let organizationId = firebaseBackend.currentOrganization?.firestoreDocumentId else {
            return
        }
        let unread = notifications.filter { !$0.isRead }
        guard !unread.isEmpty else { return }
        for notification in unread {
            var updated = notification
            updated.isRead = true
            do {
                try await firebaseBackend.saveNotification(updated, organizationId: organizationId)
                if let index = notifications.firstIndex(where: { $0.id == notification.id }) {
                    notifications[index] = updated
                }
            } catch {
                print("🔥🔥🔥 DEBUG: Error marking notification as read: \(error)")
            }
        }
        unreadCount = 0
    }
    
    private func shouldShowNotification(_ notification: AppNotification, for user: AppUser) -> Bool {
        // If notification is targeted to a specific user, only show if it's for them
        if let userId = notification.userId {
            return userId == user.id
        }
        
        // Check if user has required permission
        if let requiredPermission = notification.requiresPermission {
            switch requiredPermission {
            case "hasAdminAccess":
                return userStore?.hasAdminAccess() ?? false
            case "canBookWork":
                return userStore?.canBookWork() ?? false
            case "canViewOperatives":
                return userStore?.canViewOperatives() ?? false
            case "canViewManagers":
                return userStore?.canViewManagers() ?? false
            case "canViewProjects":
                return userStore?.canViewProjects() ?? false
            case "superAdminOrAdmin":
                return user.isSuperAdmin || user.permissions.adminAccess || user.role == .admin
            case "operativeMode":
                // For operative mode, check if task is assigned to them
                // This is now handled by userId targeting, so this case should not be used
                // But keep it for backward compatibility
                return user.permissions.operativeMode
            default:
                return true
            }
        }
        
        // No permission requirement, show to all
        return true
    }
    
    private func saveNotification(_ notification: AppNotification) async {
        guard let firebaseBackend = firebaseBackend,
              let organizationId = firebaseBackend.currentOrganization?.firestoreDocumentId else { return }
        
        do {
            try await firebaseBackend.saveNotification(notification, organizationId: organizationId)
        } catch {
            print("🔥🔥🔥 DEBUG: Error saving notification: \(error)")
        }
    }
}



