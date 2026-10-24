//
//  LocalNotificationBannerPolicy.swift
//  Project Planner
//
//  Whether this device should schedule a local notification for an inbox event.
//  Remote FCM/APNs delivery is a separate channel and is not decided here.
//

import Foundation

enum LocalNotificationBannerPolicy {
    struct Event: Equatable, Sendable {
        var id: String
        var type: AppNotification.NotificationType
        var relatedId: String?
        var targetUserId: String?
        /// Nil when the row is a broadcast the caller has already allowed this user to see.
        var isRead: Bool
        /// Derived on device (annual-leave fallback or a delivered OS banner). Not a new Firestore event.
        var isSynthetic: Bool
        /// Deadline reminder or due row whose fire time is still in the future.
        var isFutureScheduledDeadline: Bool
    }

    /// One key per inbox document. The id is required so a later warning, timesheet, or peer
    /// update is not treated as a repeat of an earlier row that has no related id.
    static func dedupeKey(for event: Event) -> String {
        let related = event.relatedId ?? "none"
        let target = event.targetUserId ?? "broadcast"
        return "\(event.type.rawValue)|\(related)|\(target)|\(event.id)"
    }

    static func shouldScheduleBanner(
        for event: Event,
        currentUserId: String,
        seenKeys: Set<String>
    ) -> Bool {
        if let target = event.targetUserId {
            let trimmedTarget = target.trimmingCharacters(in: .whitespacesAndNewlines)
            let trimmedMe = currentUserId.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedTarget.isEmpty, trimmedTarget == trimmedMe else { return false }
        }
        if event.isRead { return false }
        if event.isFutureScheduledDeadline { return false }
        switch event.type {
        case .deadlineReminder, .deadlineDue, .materialOrderCutOff, .qualificationExpiry:
            // On-device clocks. An inbox row must not also post an immediate banner.
            return false
        case .timesheetSubmissionReminder:
            // The inbox create is the FCM alert. This path must not add a second local banner.
            return false
        default:
            break
        }
        if event.isSynthetic {
            switch event.type {
            case .holidayRequestSubmitted:
                break
            default:
                return false
            }
        }
        return !seenKeys.contains(dedupeKey(for: event))
    }
}
