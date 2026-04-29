//
//  NotificationModel.swift
//  Project Planner
//
//  Created by Assistant on 26/11/2025.
//

import Foundation

struct AppNotification: Identifiable, Codable, Hashable {
    enum NotificationType: String, Codable {
        case bookingCreated = "booking_created"
        case operativeCreated = "operative_created"
        case managerCreated = "manager_created"
        case clientCreated = "client_created"
        case projectCreated = "project_created"
        case smallWorksCreated = "small_works_created"
        case bookingClash = "booking_clash"
        case taskCompleted = "task_completed"
        case taskCreated = "task_created"
        case holidayRequestSubmitted = "holiday_request_submitted"
        case holidayRequestApproved = "holiday_request_approved"
        case holidayRequestDeclined = "holiday_request_declined"
    }
    
    let id: UUID
    var organizationId: String
    var type: NotificationType
    var title: String
    var message: String
    var userId: String? // Target user ID (nil means all users with permission)
    var relatedId: UUID? // Related entity ID (booking, operative, manager, client, task)
    var isRead: Bool
    var createdAt: Date
    var requiresPermission: String? // Permission required to see this notification (e.g., "canViewOperatives")
    
    init(
        id: UUID = UUID(),
        organizationId: String,
        type: NotificationType,
        title: String,
        message: String,
        userId: String? = nil,
        relatedId: UUID? = nil,
        isRead: Bool = false,
        createdAt: Date = Date(),
        requiresPermission: String? = nil
    ) {
        self.id = id
        self.organizationId = organizationId
        self.type = type
        self.title = title
        self.message = message
        self.userId = userId
        self.relatedId = relatedId
        self.isRead = isRead
        self.createdAt = createdAt
        self.requiresPermission = requiresPermission
    }
}




