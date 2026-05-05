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
    private var didPrimeNotificationStream = false
    private var hasRequestedLocalNotificationPermission = false
    private var didLoadPersistedLocalAlertDedupKeys = false
    /// FIFO order for dedupe keys — must not use `Set`→`Array` truncation (order is undefined and evicts random keys).
    private var localAlertDedupOrderedKeys: [String] = []
    private var lastProcessedNotificationAt: Date?
    private static let persistedLocalAlertDedupKey = "NotificationService.localAlertDedupKeysV2"
    private static let persistedLastProcessedAtKey = "NotificationService.lastProcessedNotificationAtV1"
    private static let maxPersistedDedupKeys = 400
    
    func setFirebaseBackend(_ backend: FirebaseBackend) {
        self.firebaseBackend = backend
        loadPersistedLocalAlertDedupKeysIfNeeded()
        loadLastProcessedNotificationDateIfNeeded()
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
            let targetId = await resolvedRecipientUserIdResolvingStaleIds(mid)
            print("🔥🔥🔥 DEBUG: [HOLIDAY NOTIFY SUBMIT] writing notification target=\(targetId) original=\(mid)")
            let toManager = AppNotification(
                organizationId: organizationId,
                type: .holidayRequestSubmitted,
                title: "Annual Leave Request",
                message: "\(operativeName) requested annual leave \(dateRange). Tap to review.",
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
            let targetId = await resolvedRecipientUserIdResolvingStaleIds(managerId)
            print("🔥🔥🔥 DEBUG: [HOLIDAY NOTIFY SUBMIT_BY_USER] writing notification target=\(targetId) original=\(managerId)")
            let toManager = AppNotification(
                organizationId: organizationId,
                type: .holidayRequestSubmitted,
                title: "Annual Leave Request",
                message: "\(requesterName) requested annual leave \(dateRange). Tap to review.",
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
            title: "Annual Leave Approved",
            message: "\(approvedByName) approved \(operativeName)'s annual leave request.",
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
            title: approved ? "Annual Leave Approved" : "Annual Leave Declined",
            message: approved ? "\(decidedByName) approved your annual leave request." : "\(decidedByName) declined your annual leave request.",
            userId: targetId,
            relatedId: bookingId,
            requiresPermission: nil
        )
        await saveNotification(notification)
    }

    /// Temporary: writes a targeted notification for the current signed-in user so we can validate
    /// end-to-end remote push delivery (notification write -> Cloud Function -> APNs/FCM).
    func sendTemporaryPushDiagnosticToCurrentUser() async -> String {
        guard let firebaseBackend = firebaseBackend,
              let organizationId = firebaseBackend.currentOrganization?.firestoreDocumentId else {
            return "❌ Push diagnostic failed: no active organization."
        }
        guard let currentUser = userStore?.currentUser else {
            return "❌ Push diagnostic failed: no signed-in app user."
        }

        let refreshResult = await firebaseBackend.forceRefreshAndRegisterPushToken()
        let targetId = resolvedRecipientUserId(currentUser.id)
        let tokenCount = await pushTokenCount(for: targetId)
        let notification = AppNotification(
            organizationId: organizationId,
            type: .taskCreated,
            title: "Push Diagnostic",
            message: "Temporary diagnostic ping for \(currentUser.fullName).",
            userId: targetId,
            relatedId: UUID(),
            requiresPermission: nil
        )
        await saveNotification(notification)
        return "✅ Diagnostic notification created.\n\(refreshResult)\nTarget userId: \(targetId)\nNotification id: \(notification.id.uuidString)\nKnown tokens on target doc: \(tokenCount)"
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
                // Catch-up path: if app was closed/backgrounded and new notifications arrived,
                // alert once for notifications newer than the last processed timestamp.
                if let cutoff = self.lastProcessedNotificationAt {
                    let catchUp = self.notifications.filter { $0.createdAt > cutoff }
                    self.processBookingToasts(from: catchUp)
                    self.processHolidayRequestAlerts(from: catchUp)
                    self.processHolidayDecisionAlerts(from: catchUp)
                    self.processGeneralLocalAlerts(from: catchUp)
                }
                self.advanceLastProcessedNotificationDate(using: self.notifications)
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
            if notification.requiresPermission == "syntheticAnnualLeave" {
                if let index = notifications.firstIndex(where: { $0.id == notification.id }) {
                    notifications[index].isRead = true
                }
                continue
            }
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
        unreadCount = notifications.filter { !$0.isRead }.count
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
        didPrimeNotificationStream = false

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
                let synthetic = self.syntheticAnnualLeaveNotifications(for: currentUser, organizationId: organizationId)
                let merged = (sorted + synthetic).sorted { $0.createdAt > $1.createdAt }
                let changedParsed = (snapshot?.documentChanges ?? [])
                    .compactMap { change -> AppNotification? in
                        // Alert only for newly added notifications after the stream is primed.
                        guard change.type == .added else { return nil }
                        return self.parseNotificationDocument(change.document)
                    }
                    .filter { self.shouldShowNotification($0, for: currentUser) }

                Task { @MainActor in
                    self.notifications = merged
                    self.unreadCount = merged.filter { !$0.isRead }.count
                    if !self.didPrimeNotificationStream {
                        self.primeLocalAlertDedup(with: merged)
                        self.didPrimeNotificationStream = true
                        self.advanceLastProcessedNotificationDate(using: merged)
                        return
                    }
                    self.processBookingToasts(from: changedParsed)
                    self.processHolidayRequestAlerts(from: changedParsed)
                    self.processHolidayDecisionAlerts(from: changedParsed)
                    self.processGeneralLocalAlerts(from: changedParsed)
                    self.advanceLastProcessedNotificationDate(using: merged)
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
        }
    }

    private func processGeneralLocalAlerts(from notifications: [AppNotification]) {
        // Holiday types are handled only by processHolidayRequestAlerts / processHolidayDecisionAlerts
        // so we do not double-schedule the same OS banner.
        let sorted = notifications.sorted { $0.createdAt > $1.createdAt }
        for notification in sorted {
            switch notification.type {
            case .holidayRequestSubmitted, .holidayRequestApproved, .holidayRequestDeclined:
                continue
            default:
                triggerLocalAlertIfNeeded(for: notification)
            }
        }
    }

    private func scheduleLocalHolidayRequestAlert(title: String, message: String) {
        Task {
            let granted = await LocalNotificationService.shared.requestAuthorization()
            guard granted else {
                print("🔥🔥🔥 DEBUG: Local notification permission not granted; skipping banner")
                return
            }
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
    }

    private func holidayRequestRecipients(assignedManagerUserId: String?) async -> [String] {
        if let mid = assignedManagerUserId, !mid.isEmpty {
            let canonical = await resolvedRecipientUserIdResolvingStaleIds(mid)
            return [canonical]
        }
        guard let userStore else { return [] }
        if userStore.organizationUsers.isEmpty {
            await userStore.loadOrganizationUsers()
        }
        // Fallback priority: active managers first, then super admins, then admins.
        // This keeps annual leave approval routing aligned with the line-manager flow.
        let managers = userStore.organizationUsers.filter {
            $0.isActive &&
            $0.passwordSet &&
            $0.permissions.manager &&
            !$0.permissions.operativeMode
        }.map(\.id)
        if !managers.isEmpty {
            return uniqueCanonicalUserIds(from: managers)
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

    /// When `assignedManagerUserId` (or similar) still references a pre-merge `users/{placeholderId}` row,
    /// that id is absent from `organizationUsers` (deduped to Auth UID). Load the placeholder doc by id,
    /// match on email, and return the same canonical id `resolvedRecipientUserId` would use for push targeting.
    private func resolvedRecipientUserIdResolvingStaleIds(_ userId: String) async -> String {
        let preliminary = resolvedRecipientUserId(userId)
        let trimmed = userId.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return userId }
        if let userStore, userStore.organizationUsers.contains(where: { $0.id == trimmed }) {
            return preliminary
        }
        guard let firebaseBackend else { return preliminary }
        let remote: AppUser?
        do {
            remote = try await firebaseBackend.getUserData(userId: trimmed)
        } catch {
            print("🔥🔥🔥 DEBUG: [NOTIFY] canonical id lookup failed for \(trimmed): \(error.localizedDescription)")
            remote = nil
        }
        guard let remote, let userStore else { return preliminary }
        let normalizedEmail = remote.email.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedEmail.isEmpty else { return preliminary }
        if userStore.organizationUsers.isEmpty {
            await userStore.loadOrganizationUsers()
        }
        let sameEmail = userStore.organizationUsers.filter {
            $0.email.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) == normalizedEmail
        }
        if let verifiedActive = sameEmail.first(where: { $0.passwordSet && $0.isActive }) {
            if verifiedActive.id != trimmed {
                print("🔥🔥🔥 DEBUG: [NOTIFY] resolved stale userId \(trimmed) → \(verifiedActive.id) via email \(normalizedEmail)")
            }
            return verifiedActive.id
        }
        if let verified = sameEmail.first(where: { $0.passwordSet }) {
            if verified.id != trimmed {
                print("🔥🔥🔥 DEBUG: [NOTIFY] resolved stale userId \(trimmed) → \(verified.id) via email \(normalizedEmail)")
            }
            return verified.id
        }
        return preliminary
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

    private func pushTokenCount(for userId: String) async -> Int {
        do {
            let snap = try await Firestore.firestore().collection("users").document(userId).getDocument(source: .server)
            guard let data = snap.data() else { return 0 }
            var tokens = Set<String>()
            if let single = data["pushToken"] as? String {
                let t = single.trimmingCharacters(in: .whitespacesAndNewlines)
                if !t.isEmpty { tokens.insert(t) }
            }
            if let many = data["pushTokens"] as? [String] {
                for raw in many {
                    let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !t.isEmpty { tokens.insert(t) }
                }
            }
            return tokens.count
        } catch {
            print("🔥🔥🔥 DEBUG: [PUSH DIAGNOSTIC] token lookup failed for \(userId): \(error.localizedDescription)")
            return 0
        }
    }

    private func triggerLocalAlertIfNeeded(for notification: AppNotification) {
        loadPersistedLocalAlertDedupKeysIfNeeded()
        guard !notification.isRead else { return }
        // Synthetic approve/decline is in-app fallback only (derived from holiday bookings). OS banners for
        // those come from real Firestore notification docs; otherwise operatives get repeat foreground banners.
        if notification.requiresPermission == "syntheticAnnualLeave" {
            switch notification.type {
            case .holidayRequestSubmitted:
                break
            case .holidayRequestApproved, .holidayRequestDeclined:
                return
            default:
                return
            }
        }
        let key = notificationDedupKey(for: notification)
        guard !seenLocalAlertNotificationKeys.contains(key) else { return }
        recordLocalAlertDedupKey(key)
        scheduleLocalHolidayRequestAlert(title: notification.title, message: notification.message)
    }

    private func loadPersistedLocalAlertDedupKeysIfNeeded() {
        guard !didLoadPersistedLocalAlertDedupKeys else { return }
        didLoadPersistedLocalAlertDedupKeys = true
        if let stored = UserDefaults.standard.stringArray(forKey: Self.persistedLocalAlertDedupKey) {
            localAlertDedupOrderedKeys = stored
            seenLocalAlertNotificationKeys = Set(stored)
        }
    }

    private func loadLastProcessedNotificationDateIfNeeded() {
        guard lastProcessedNotificationAt == nil else { return }
        if let ts = UserDefaults.standard.object(forKey: Self.persistedLastProcessedAtKey) as? TimeInterval {
            lastProcessedNotificationAt = Date(timeIntervalSince1970: ts)
        }
    }

    private func recordLocalAlertDedupKey(_ key: String) {
        if seenLocalAlertNotificationKeys.contains(key) { return }
        seenLocalAlertNotificationKeys.insert(key)
        localAlertDedupOrderedKeys.append(key)
        while localAlertDedupOrderedKeys.count > Self.maxPersistedDedupKeys {
            let removed = localAlertDedupOrderedKeys.removeFirst()
            seenLocalAlertNotificationKeys.remove(removed)
        }
        UserDefaults.standard.set(localAlertDedupOrderedKeys, forKey: Self.persistedLocalAlertDedupKey)
    }

    private func advanceLastProcessedNotificationDate(using notifications: [AppNotification]) {
        guard let latest = notifications.map(\.createdAt).max() else { return }
        if let current = lastProcessedNotificationAt, latest <= current { return }
        lastProcessedNotificationAt = latest
        UserDefaults.standard.set(latest.timeIntervalSince1970, forKey: Self.persistedLastProcessedAtKey)
    }

    private func primeLocalAlertDedup(with notifications: [AppNotification]) {
        // Treat current visible unread notifications as already known at stream start.
        // This prevents banner storms when opening the app with a backlog.
        for notification in notifications where !notification.isRead {
            let key = notificationDedupKey(for: notification)
            recordLocalAlertDedupKey(key)
            if notification.type == .holidayRequestSubmitted {
                seenHolidayRequestNotificationKeys.insert(key)
            }
            if notification.type == .holidayRequestApproved || notification.type == .holidayRequestDeclined {
                seenHolidayDecisionNotificationKeys.insert(key)
            }
            if notification.type == .bookingCreated {
                seenBookingNotificationIds.insert(notification.id)
            }
        }
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



