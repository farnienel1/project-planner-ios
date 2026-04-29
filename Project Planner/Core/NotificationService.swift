//
//  NotificationService.swift
//  Project Planner
//
//  Created by Assistant on 26/11/2025.
//

import Foundation
import Combine
import UserNotifications
import FirebaseFirestore

@MainActor
class NotificationService: ObservableObject {
    @Published var notifications: [AppNotification] = []
    @Published var unreadCount: Int = 0
    @Published var bookingToastMessage: String?
    
    private var firebaseBackend: FirebaseBackend?
    private var userStore: UserStore?
    private var operativeStore: OperativeStore?
    private var holidayStore: HolidayStore?
    private var seenBookingNotificationIds: Set<UUID> = []
    private var seenHolidayRequestNotificationKeys: Set<String> = []
    private var seenHolidayDecisionNotificationKeys: Set<String> = []
    private var seenLocalAlertNotificationKeys: Set<String> = []
    private var notificationsListener: ListenerRegistration?
    private var listenerScopeKey: String?
    private var hasRequestedLocalNotificationPermission = false
    private let localAlertCutoffAtLaunch = Date()
    
    func setFirebaseBackend(_ backend: FirebaseBackend) {
        self.firebaseBackend = backend
        requestLocalNotificationPermissionIfNeeded()
    }
    
    func setUserStore(_ store: UserStore) {
        self.userStore = store
    }
    
    func setOperativeStore(_ store: OperativeStore) {
        self.operativeStore = store
    }

    func setHolidayStore(_ store: HolidayStore) {
        self.holidayStore = store
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

    func notifyHolidayRequestSubmitted(bookingId: UUID, operativeName: String, startDate: Date, endDate: Date, assignedManagerUserId: String?) async {
        guard let firebaseBackend = firebaseBackend,
              let organizationId = firebaseBackend.currentOrganization?.firestoreDocumentId else { return }
        let dateRange = "\(startDate.formatted(date: .abbreviated, time: .omitted)) – \(endDate.formatted(date: .abbreviated, time: .omitted))"

        let recipients = await holidayRequestRecipients(assignedManagerUserId: assignedManagerUserId)
        print("🔥🔥🔥 DEBUG: [HOLIDAY NOTIFY SUBMIT] bookingId=\(bookingId.uuidString) operative=\(operativeName) assignedManager=\(assignedManagerUserId ?? "nil") resolvedRecipients=\(recipients)")
        for mid in recipients {
            let targetId = resolvedRecipientUserId(mid)
            print("🔥🔥🔥 DEBUG: [HOLIDAY NOTIFY SUBMIT] writing notification target=\(targetId) original=\(mid)")
            let toManager = AppNotification(
                organizationId: organizationId,
                type: .holidayRequestSubmitted,
                title: "Holiday Request",
                message: "\(operativeName) requested holiday \(dateRange). Tap to review.",
                userId: targetId,
                relatedId: bookingId,
                requiresPermission: nil
            )
            await saveNotification(toManager)
        }
    }

    func notifyHolidayRequestSubmittedByUser(
        bookingId: UUID,
        requesterName: String,
        startDate: Date,
        endDate: Date,
        assignedManagerUserId: String?
    ) async {
        guard let firebaseBackend = firebaseBackend,
              let organizationId = firebaseBackend.currentOrganization?.firestoreDocumentId else { return }
        let dateRange = "\(startDate.formatted(date: .abbreviated, time: .omitted)) – \(endDate.formatted(date: .abbreviated, time: .omitted))"
        let recipients = await holidayRequestRecipients(assignedManagerUserId: assignedManagerUserId)
        print("🔥🔥🔥 DEBUG: [HOLIDAY NOTIFY SUBMIT_BY_USER] bookingId=\(bookingId.uuidString) requester=\(requesterName) assignedManager=\(assignedManagerUserId ?? "nil") resolvedRecipients=\(recipients)")
        for managerId in recipients {
            let targetId = resolvedRecipientUserId(managerId)
            print("🔥🔥🔥 DEBUG: [HOLIDAY NOTIFY SUBMIT_BY_USER] writing notification target=\(targetId) original=\(managerId)")
            let toManager = AppNotification(
                organizationId: organizationId,
                type: .holidayRequestSubmitted,
                title: "Holiday Request",
                message: "\(requesterName) requested holiday \(dateRange). Tap to review.",
                userId: targetId,
                relatedId: bookingId,
                requiresPermission: nil
            )
            await saveNotification(toManager)
        }
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
        let targetId = resolvedRecipientUserId(userId)
        print("🔥🔥🔥 DEBUG: [HOLIDAY NOTIFY DECISION] bookingId=\(bookingId.uuidString) approved=\(approved) decidedBy=\(decidedByName) target=\(targetId) original=\(userId)")
        let notification = AppNotification(
            organizationId: organizationId,
            type: approved ? .holidayRequestApproved : .holidayRequestDeclined,
            title: approved ? "Holiday Approved" : "Holiday Declined",
            message: approved ? "\(decidedByName) approved your holiday request." : "\(decidedByName) declined your holiday request.",
            userId: targetId,
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
            let fetched = try? await firebaseBackend.loadNotifications(organizationId: organizationId)
            let fallbackExisting = notifications.filter { $0.requiresPermission != "syntheticAnnualLeave" }
            let allNotifications = fetched ?? fallbackExisting
            print("🔥🔥🔥 DEBUG: [NOTIFY LOAD] currentUser=\(currentUser.id) totalLoaded=\(allNotifications.count)")
            
            // Filter notifications based on user permissions
            let filteredNotifications = allNotifications.filter { notification in
                shouldShowNotification(notification, for: currentUser)
            }
            let synthetic = syntheticAnnualLeaveNotifications(for: currentUser, organizationId: organizationId)
            let merged = (filteredNotifications + synthetic).sorted { $0.createdAt > $1.createdAt }
            let targetedToCurrent = allNotifications.filter { $0.userId == currentUser.id }.count
            let broadcastCount = allNotifications.filter { $0.userId == nil }.count
            print("🔥🔥🔥 DEBUG: [NOTIFY LOAD] targetedToCurrent=\(targetedToCurrent) broadcasts=\(broadcastCount) filteredVisible=\(filteredNotifications.count)")
            
            await MainActor.run {
                self.notifications = merged
                self.unreadCount = self.notifications.filter { !$0.isRead }.count
                self.processBookingToasts(from: self.notifications)
                self.processHolidayRequestAlerts(from: self.notifications)
                self.processHolidayDecisionAlerts(from: self.notifications)
                self.processGeneralLocalAlerts(from: self.notifications)
            }
            startNotificationsListenerIfNeeded(organizationId: organizationId, userId: currentUser.id)
        } catch {
            print("🔥🔥🔥 DEBUG: Error loading notifications: \(error)")
        }
    }
    
    func markAsRead(_ notification: AppNotification) async {
        if notification.requiresPermission == "syntheticAnnualLeave" {
            if let index = notifications.firstIndex(where: { $0.id == notification.id }) {
                notifications[index].isRead = true
                unreadCount = notifications.filter { !$0.isRead }.count
            }
            return
        }
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
            print("🔥🔥🔥 DEBUG: [NOTIFY SAVE OK] id=\(notification.id.uuidString) type=\(notification.type.rawValue) target=\(notification.userId ?? "broadcast") related=\(notification.relatedId?.uuidString ?? "none")")
        } catch {
            print("🔥🔥🔥 DEBUG: Error saving notification: \(error)")
            print("🔥🔥🔥 DEBUG: Notification target userId: \(notification.userId ?? "broadcast"), type: \(notification.type.rawValue), relatedId: \(notification.relatedId?.uuidString ?? "none")")
        }
    }

    private func startNotificationsListenerIfNeeded(organizationId: String, userId: String) {
        let key = "\(organizationId)|\(userId)"
        if listenerScopeKey == key, notificationsListener != nil {
            return
        }
        notificationsListener?.remove()
        listenerScopeKey = key

        notificationsListener = Firestore.firestore()
            .collection("organizations")
            .document(organizationId)
            .collection("notifications")
            .order(by: "createdAt", descending: true)
            .limit(to: 250)
            .addSnapshotListener { [weak self] snapshot, error in
                guard let self else { return }
                if let error {
                    print("🔥🔥🔥 DEBUG: Notifications listener error: \(error.localizedDescription)")
                    return
                }
                guard let docs = snapshot?.documents,
                      let currentUser = self.userStore?.currentUser else { return }

                let parsed = docs.compactMap { self.parseNotificationDocument($0) }
                let filtered = parsed.filter { self.shouldShowNotification($0, for: currentUser) }
                let sorted = filtered.sorted { $0.createdAt > $1.createdAt }

                Task { @MainActor in
                    self.notifications = sorted
                    self.unreadCount = sorted.filter { !$0.isRead }.count
                    self.processBookingToasts(from: sorted)
                    self.processHolidayRequestAlerts(from: sorted)
                    self.processHolidayDecisionAlerts(from: sorted)
                    self.processGeneralLocalAlerts(from: sorted)
                }
            }
    }

    private func parseNotificationDocument(_ doc: QueryDocumentSnapshot) -> AppNotification? {
        let data = doc.data()
        guard let typeString = data["type"] as? String,
              let type = AppNotification.NotificationType(rawValue: typeString),
              let title = data["title"] as? String,
              let message = data["message"] as? String,
              let createdAt = (data["createdAt"] as? Timestamp)?.dateValue(),
              let isRead = data["isRead"] as? Bool,
              let orgId = data["organizationId"] as? String else {
            return nil
        }

        let id = UUID(uuidString: doc.documentID) ?? UUID()
        let userId = data["userId"] as? String
        let relatedIdString = data["relatedId"] as? String
        let relatedId = relatedIdString.flatMap(UUID.init(uuidString:))
        let requiresPermission = data["requiresPermission"] as? String

        return AppNotification(
            id: id,
            organizationId: orgId,
            type: type,
            title: title,
            message: message,
            userId: userId,
            relatedId: relatedId,
            isRead: isRead,
            createdAt: createdAt,
            requiresPermission: requiresPermission
        )
    }

    private func processBookingToasts(from notifications: [AppNotification]) {
        guard userStore?.isOperativeMode() == true else { return }
        let bookingNotifications = notifications
            .filter { $0.type == .bookingCreated }
            .sorted { $0.createdAt > $1.createdAt }
        for n in bookingNotifications where !seenBookingNotificationIds.contains(n.id) {
            seenBookingNotificationIds.insert(n.id)
            if !n.isRead {
                bookingToastMessage = n.message
                scheduleLocalBookingAlert(message: n.message)
            }
            break
        }
    }

    private func processHolidayRequestAlerts(from notifications: [AppNotification]) {
        let requests = notifications
            .filter { $0.type == .holidayRequestSubmitted }
            .sorted { $0.createdAt > $1.createdAt }
        for n in requests {
            let key = notificationDedupKey(for: n)
            guard !seenHolidayRequestNotificationKeys.contains(key) else { continue }
            seenHolidayRequestNotificationKeys.insert(key)
            triggerLocalAlertIfNeeded(for: n)
            break
        }
    }

    private func processHolidayDecisionAlerts(from notifications: [AppNotification]) {
        let decisions = notifications
            .filter { $0.type == .holidayRequestApproved || $0.type == .holidayRequestDeclined }
            .sorted { $0.createdAt > $1.createdAt }
        for n in decisions {
            let key = notificationDedupKey(for: n)
            guard !seenHolidayDecisionNotificationKeys.contains(key) else { continue }
            seenHolidayDecisionNotificationKeys.insert(key)
            triggerLocalAlertIfNeeded(for: n)
            break
        }
    }

    private func processGeneralLocalAlerts(from notifications: [AppNotification]) {
        // Covers tasks, bookings, and all other notification types consistently.
        let sorted = notifications.sorted { $0.createdAt > $1.createdAt }
        for notification in sorted {
            triggerLocalAlertIfNeeded(for: notification)
        }
    }

    private func scheduleLocalHolidayRequestAlert(title: String, message: String) {
        requestLocalNotificationPermissionIfNeeded()
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = message
        content.sound = .default
        let request = UNNotificationRequest(
            identifier: "holiday-request-\(UUID().uuidString)",
            content: content,
            trigger: UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)
        )
        UNUserNotificationCenter.current().add(request) { error in
            if let error {
                print("🔥🔥🔥 DEBUG: Local holiday notification error: \(error.localizedDescription)")
            }
        }
    }

    private func holidayRequestRecipients(assignedManagerUserId: String?) async -> [String] {
        if let mid = assignedManagerUserId, !mid.isEmpty {
            return [resolvedRecipientUserId(mid)]
        }
        guard let userStore else { return [] }
        if userStore.organizationUsers.isEmpty {
            await userStore.loadOrganizationUsers()
        }
        let superAdmins = userStore.organizationUsers.filter {
            $0.isActive && $0.isSuperAdmin && !$0.permissions.operativeMode
        }.map(\.id)
        if !superAdmins.isEmpty {
            return uniqueCanonicalUserIds(from: superAdmins)
        }
        let admins = userStore.organizationUsers.filter {
            $0.isActive && ($0.permissions.adminAccess || $0.role == .admin) && !$0.permissions.operativeMode
        }.map(\.id)
        return uniqueCanonicalUserIds(from: admins)
    }

    private func resolvedRecipientUserId(_ userId: String) -> String {
        guard let userStore else { return userId }
        guard let seed = userStore.organizationUsers.first(where: { $0.id == userId }) else { return userId }
        let normalizedEmail = seed.email.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let sameEmail = userStore.organizationUsers.filter {
            $0.email.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) == normalizedEmail
        }
        if let verifiedActive = sameEmail.first(where: { $0.passwordSet && $0.isActive }) {
            return verifiedActive.id
        }
        if let verified = sameEmail.first(where: { $0.passwordSet }) {
            return verified.id
        }
        return userId
    }

    private func uniqueCanonicalUserIds(from ids: [String]) -> [String] {
        Array(Set(ids.map { resolvedRecipientUserId($0) }))
    }

    private func scheduleLocalBookingAlert(message: String) {
        requestLocalNotificationPermissionIfNeeded()
        let content = UNMutableNotificationContent()
        content.title = "You've Been Booked"
        content.body = message
        content.sound = .default
        let request = UNNotificationRequest(
            identifier: "booking-\(UUID().uuidString)",
            content: content,
            trigger: UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)
        )
        UNUserNotificationCenter.current().add(request) { error in
            if let error {
                print("🔥🔥🔥 DEBUG: Local booking notification error: \(error.localizedDescription)")
            }
        }
    }

    private func requestLocalNotificationPermissionIfNeeded() {
        guard !hasRequestedLocalNotificationPermission else { return }
        hasRequestedLocalNotificationPermission = true
        Task {
            _ = await LocalNotificationService.shared.requestAuthorization()
        }
    }

    private func notificationDedupKey(for notification: AppNotification) -> String {
        let related = notification.relatedId?.uuidString ?? "none"
        return "\(notification.type.rawValue)|\(related)|\(notification.userId ?? "broadcast")"
    }

    private func triggerLocalAlertIfNeeded(for notification: AppNotification) {
        guard !notification.isRead else { return }
        guard notification.createdAt >= localAlertCutoffAtLaunch else { return }
        // Synthetic notifications are in-app fallback entries; avoid banner duplicates from generated rows.
        guard notification.requiresPermission != "syntheticAnnualLeave" else { return }
        let key = notificationDedupKey(for: notification)
        guard !seenLocalAlertNotificationKeys.contains(key) else { return }
        seenLocalAlertNotificationKeys.insert(key)
        scheduleLocalHolidayRequestAlert(title: notification.title, message: notification.message)
    }

    private func syntheticNotificationId(from key: String) -> UUID {
        let hex = String(format: "%016llx", UInt64(abs(key.hashValue)))
        let full = (hex + hex)
        let uuidString = "\(full.prefix(8))-\(full.dropFirst(8).prefix(4))-\(full.dropFirst(12).prefix(4))-\(full.dropFirst(16).prefix(4))-\(full.dropFirst(20).prefix(12))"
        return UUID(uuidString: uuidString) ?? UUID()
    }

    private func syntheticAnnualLeaveNotifications(for user: AppUser, organizationId: String) -> [AppNotification] {
        guard let holidayStore else { return [] }
        let recentCutoff = Date().addingTimeInterval(-60 * 60 * 24 * 14)

        if !user.permissions.operativeMode && (user.permissions.manager || user.permissions.adminAccess || user.isSuperAdmin || user.role == .admin) {
            let pending = holidayStore.pendingRequests.filter { request in
                let approver = approverUserId(for: request)
                if user.permissions.manager && !user.permissions.adminAccess && !user.isSuperAdmin && user.role != .admin {
                    return approver == user.id
                }
                return approver == nil || approver == user.id
            }
            return pending.map { request in
                let requester = requesterName(for: request)
                let isCancellation = request.cancellationRequestedAt != nil
                let key = "annualLeaveRequest|\(request.id.uuidString)|\(user.id)|\(isCancellation)"
                return AppNotification(
                    id: syntheticNotificationId(from: key),
                    organizationId: organizationId,
                    type: .holidayRequestSubmitted,
                    title: isCancellation ? "Annual Leave Cancellation" : "Annual Leave Request",
                    message: isCancellation ? "\(requester) requested annual leave cancellation." : "\(requester) requested annual leave.",
                    userId: user.id,
                    relatedId: request.id,
                    isRead: false,
                    createdAt: request.updatedAt,
                    requiresPermission: "syntheticAnnualLeave"
                )
            }
        }

        let myDecisions = holidayStore.myBookings(userId: user.id, operativeId: nil)
            .filter { ($0.status == .approved || $0.status == .rejected) && $0.updatedAt >= recentCutoff }
        return myDecisions.map { booking in
            let key = "annualLeaveDecision|\(booking.id.uuidString)|\(user.id)|\(booking.status.rawValue)"
            return AppNotification(
                id: syntheticNotificationId(from: key),
                organizationId: organizationId,
                type: booking.status == .approved ? .holidayRequestApproved : .holidayRequestDeclined,
                title: booking.status == .approved ? "Annual Leave Approved" : "Annual Leave Declined",
                message: booking.status == .approved ? "Your annual leave request was approved." : "Your annual leave request was declined.",
                userId: user.id,
                relatedId: booking.id,
                isRead: false,
                createdAt: booking.updatedAt,
                requiresPermission: "syntheticAnnualLeave"
            )
        }
    }

    private func approverUserId(for request: HolidayBooking) -> String? {
        guard let userStore else { return nil }
        if let uid = request.userId,
           let requester = userStore.organizationUsers.first(where: { $0.id == uid }) {
            return requester.assignedManagerUserId
        }
        if let oid = request.operativeId,
           let operative = operativeStore?.allOperatives.first(where: { $0.id == oid }),
           let requester = userStore.organizationUsers.first(where: { $0.email.lowercased() == operative.email.lowercased() }) {
            return requester.assignedManagerUserId
        }
        return nil
    }

    private func requesterName(for request: HolidayBooking) -> String {
        guard let userStore else { return "Operative" }
        if let uid = request.userId,
           let requester = userStore.organizationUsers.first(where: { $0.id == uid }) {
            return requester.fullName
        }
        if let oid = request.operativeId,
           let operative = operativeStore?.allOperatives.first(where: { $0.id == oid }) {
            return "\(operative.firstName) \(operative.lastName)"
        }
        return "Operative"
    }
}



