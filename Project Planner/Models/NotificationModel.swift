//
//  NotificationModel.swift
//  Project Planner
//
//  Created by Assistant on 26/11/2025.
//

import Foundation

struct AppNotification: Identifiable, Codable, Hashable {
    nonisolated enum NotificationType: String, Codable, Sendable {
        case bookingCreated = "booking_created"
        case operativeCreated = "operative_created"
        case managerCreated = "manager_created"
        case clientCreated = "client_created"
        case projectCreated = "project_created"
        case smallWorksCreated = "small_works_created"
        case bookingClash = "booking_clash"
        case warningRemoved = "warning_removed"
        case taskCompleted = "task_completed"
        case taskCreated = "task_created"
        case holidayRequestSubmitted = "holiday_request_submitted"
        case holidayRequestApproved = "holiday_request_approved"
        case holidayRequestDeclined = "holiday_request_declined"
        case timesheetPendingManagerSignoff = "timesheet_pending_manager_signoff"
        case timesheetSignedByManager = "timesheet_signed_by_manager"
        case lineManagerPeerUpdate = "line_manager_peer_update"
        case materialAdded = "material_added"
        case toolboxTalkIssued = "toolbox_talk_issued"
        case deadlineAssigned = "deadline_assigned"
        case deadlineReminder = "deadline_reminder"
        case deadlineDue = "deadline_due"
        case qualificationExpiry = "qualification_expiry"
        case materialOrderCutOff = "material_order_cut_off"
        case variationAdded = "variation_added"
        case variationFromTracker = "variation_from_tracker"
        case variationNumbersUpdated = "variation_numbers_updated"
        case timesheetSubmissionReminder = "timesheet_submission_reminder"
        /// Web health-and-safety toolbox reminder. Destination and preference key come from the script.
        case hsToolboxReminder = "hs_toolbox_reminder"
        /// Web feedback board: a status change on an idea this user raised or voted for.
        case ideaStatus = "idea_status"
        /// Web feedback board: an idea this user raised or voted for has shipped.
        case ideaShipped = "idea_shipped"
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
    /// Optional deep-link payload used by notifications that open a specific timesheet review.
    var deepLinkUserId: String?
    var deepLinkWeekStart: Date?
    /// `YYYY-MM-DD` for destinations that open a day. Optional.
    var dayKey: String?
    /// `projects` or `smallWorks` when the row names a job catalogue. Optional.
    var catalogue: String?
    
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
        requiresPermission: String? = nil,
        deepLinkUserId: String? = nil,
        deepLinkWeekStart: Date? = nil,
        dayKey: String? = nil,
        catalogue: String? = nil
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
        self.deepLinkUserId = deepLinkUserId
        self.deepLinkWeekStart = deepLinkWeekStart
        self.dayKey = dayKey
        self.catalogue = catalogue
    }

    /// `YYYY-MM-DD` stored on the row, or the same shape in `relatedId` when that field is the payment day.
    static func inboxDayKey(storedDayKey: String?, relatedId: String?) -> String? {
        if let storedDayKey, isInboxDayKey(storedDayKey) { return storedDayKey }
        if let relatedId, isInboxDayKey(relatedId) { return relatedId }
        let trimmed = storedDayKey?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    static func isInboxDayKey(_ value: String) -> Bool {
        value.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil
    }
}




