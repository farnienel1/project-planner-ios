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
        /// RULEBOOK 1.31.0 §13: an operative was deleted (company activity, `companyActivityRecipients`).
        case operativeDeleted = "operative_deleted"
        /// RULEBOOK 1.31.0 §11: a person stopped being a manager and was taken off their jobs
        /// (`JOB_MANAGER_REMOVED_NOTICE_TYPE`, company activity).
        case jobManagerRemoved = "job_manager_removed"
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
        /// RULEBOOK 1.10.0 §13: a manager or admin removed someone's approved leave (`holidayDecisionRecipients`).
        case holidayCancelledByManager = "holiday_cancelled_by_manager"
        /// RULEBOOK 1.10.0 §13: a manager or admin booked approved leave for someone (`holidayDecisionRecipients`).
        case holidayBookedForYou = "holiday_booked_for_you"
        case timesheetPendingManagerSignoff = "timesheet_pending_manager_signoff"
        case timesheetSignedByManager = "timesheet_signed_by_manager"
        case lineManagerPeerUpdate = "line_manager_peer_update"
        /// Older iOS rows. The rulebook has no `material_added`: no device push, no toggle, no destination.
        case materialAdded = "material_added"
        /// Rulebook type for a new material line (`DEVICE_PUSH_NOTIFICATION_TYPES`, toggle `materialOrderPlaced`).
        case materialOrderPlaced = "material_order_placed"
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
        /// Web feedback board: a comment on an idea this user raised or voted for (rulebook §13, `ideaRecipients`).
        case ideaComment = "idea_comment"
        /// Web feedback board: an idea this user raised or voted for was merged into another.
        case ideaMerged = "idea_merged"
        /// Settings "send a test notification" (rulebook 1.4.0 §13, `PUSH_TEST_NOTICE_TYPE`): written to the sender
        /// (`pushTestRecipients`); its push reaches the actor (`notificationPushesToActor`). No toggle.
        case pushTest = "push_test"
        /// RULEBOOK 1.8.0 §13 (`KNOWN_NOTIFICATION_TYPES`): variation types and push allow-list types nothing writes yet.
        case variation = "variation"
        case variationRenumbered = "variation_renumbered"
        case bookedOntoJob = "booked_onto_job"
        case materialOrderCreated = "material_order_created"
        /// RULEBOOK 1.29.0 §13, §25: a PAYE person sent their overtime for approval (CanonicalBusinessEngine.overtimeRequestRecipients; push).
        case overtimeRequestSubmitted = "overtime_request_submitted"
        /// RULEBOOK 1.29.0: to the requester (push). 1.33.0: "Overtime returned" after a Return (`overtimeReturnedRecipients`,
        /// `overtimeReturnedMessage`) and the reopen notice to the person (`overtimeReopenedRecipients`).
        case overtimeRequestReviewed = "overtime_request_reviewed"
        /// RULEBOOK 1.29.0: a PAYE manager or admin changed their own booking directly (`bookingHoursChangedRecipients`;
        /// inbox only).
        case bookingHoursChangedByOwner = "booking_hours_changed_by_owner"
        /// A type this build does not know. The row is kept (never dropped); its stored text is
        /// `AppNotification.storedType`.
        case unknown = "unknown"

        /// A stored type word as a case; an unknown word is `.unknown` (`parseNotificationDocument` keeps the row).
        init(stored: String) {
            self = NotificationType(rawValue: stored.trimmingCharacters(in: .whitespacesAndNewlines)) ?? .unknown
        }

        init(from decoder: Decoder) throws {
            let raw = try decoder.singleValueContainer().decode(String.self)
            self.init(stored: raw)
        }
    }
    
    /// RULEBOOK 1.8.0 §1: in-app id of the document; the stored spelling is remembered (`JobKeys`), so a non-UUID
    /// document id is kept, never replaced with a random id.
    let id: UUID
    var organizationId: String
    var type: NotificationType
    var title: String
    var message: String
    var userId: String? // Target user ID (nil means all users with permission)
    /// RULEBOOK 1.8.0 §13: `relatedId` as stored, any shape (a UUID, a day key, a Firebase uid, a job id).
    var relatedKey: String?
    /// The stored type text when `type` is `.unknown` (kept so the row is written back unchanged).
    var storedType: String? = nil
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
        relatedKey: String? = nil,
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
        self.relatedKey = relatedKey ?? relatedId?.uuidString
        self.isRead = isRead
        self.createdAt = createdAt
        self.requiresPermission = requiresPermission
        self.deepLinkUserId = deepLinkUserId
        self.deepLinkWeekStart = deepLinkWeekStart
        self.dayKey = dayKey
        self.catalogue = catalogue
    }

    /// The related id as a UUID, when it is one (views that open a booking, task or job by in-app id).
    var relatedId: UUID? {
        get { relatedKey.flatMap { UUID(uuidString: $0.trimmingCharacters(in: .whitespacesAndNewlines)) } }
        set { relatedKey = newValue?.uuidString }
    }

    /// The type word written for this row (the stored text for an unknown type).
    var typeText: String {
        type == .unknown ? (storedType ?? type.rawValue) : type.rawValue
    }

    private enum CodingKeys: String, CodingKey {
        case id, organizationId, type, title, message, userId
        // Older caches encoded the UUID under `relatedId`; it decodes as its string.
        case relatedKey = "relatedId"
        case storedType, isRead, createdAt, requiresPermission, deepLinkUserId, deepLinkWeekStart, dayKey, catalogue
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




