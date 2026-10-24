import XCTest
@testable import Project_Planner

@MainActor
final class LocalNotificationBannerPolicyTests: XCTestCase {
    private func event(
        id: String,
        type: AppNotification.NotificationType,
        relatedId: String? = nil,
        targetUserId: String? = "user-a",
        isRead: Bool = false,
        isSynthetic: Bool = false,
        isFutureScheduledDeadline: Bool = false
    ) -> LocalNotificationBannerPolicy.Event {
        LocalNotificationBannerPolicy.Event(
            id: id,
            type: type,
            relatedId: relatedId,
            targetUserId: targetUserId,
            isRead: isRead,
            isSynthetic: isSynthetic,
            isFutureScheduledDeadline: isFutureScheduledDeadline
        )
    }

    func testSecondTimesheetStillSchedulesAfterTheFirstWasShown() {
        let first = event(id: "timesheet-1", type: .timesheetPendingManagerSignoff)
        let second = event(id: "timesheet-2", type: .timesheetPendingManagerSignoff)
        let seen = Set([LocalNotificationBannerPolicy.dedupeKey(for: first)])

        XCTAssertFalse(
            LocalNotificationBannerPolicy.shouldScheduleBanner(for: first, currentUserId: "user-a", seenKeys: seen)
        )
        XCTAssertTrue(
            LocalNotificationBannerPolicy.shouldScheduleBanner(for: second, currentUserId: "user-a", seenKeys: seen)
        )
    }

    func testSecondWarningDismissalStillSchedulesWhenRelatedIdIsMissing() {
        let first = event(id: "warning-1", type: .warningRemoved, targetUserId: nil)
        let second = event(id: "warning-2", type: .warningRemoved, targetUserId: nil)
        let seen = Set([LocalNotificationBannerPolicy.dedupeKey(for: first)])

        XCTAssertTrue(
            LocalNotificationBannerPolicy.shouldScheduleBanner(for: second, currentUserId: "user-a", seenKeys: seen)
        )
    }

    func testBookingCreatedForCurrentUserSchedules() {
        let booking = event(id: "booking-1", type: .bookingCreated, relatedId: "job-1")
        XCTAssertTrue(
            LocalNotificationBannerPolicy.shouldScheduleBanner(for: booking, currentUserId: "user-a", seenKeys: [])
        )
    }

    func testTargetedEventForSomeoneElseDoesNotSchedule() {
        let booking = event(id: "booking-1", type: .bookingCreated, targetUserId: "user-b")
        XCTAssertFalse(
            LocalNotificationBannerPolicy.shouldScheduleBanner(for: booking, currentUserId: "user-a", seenKeys: [])
        )
    }

    func testReadBroadcastDoesNotSchedule() {
        let created = event(id: "op-1", type: .operativeCreated, targetUserId: nil, isRead: true)
        XCTAssertFalse(
            LocalNotificationBannerPolicy.shouldScheduleBanner(for: created, currentUserId: "user-a", seenKeys: [])
        )
    }

    func testOnDeviceClocksDoNotScheduleAnImmediateBanner() {
        for type in [
            AppNotification.NotificationType.deadlineReminder,
            .deadlineDue,
            .materialOrderCutOff,
            .qualificationExpiry,
        ] {
            let row = event(id: type.rawValue, type: type, relatedId: "clock-1")
            XCTAssertFalse(
                LocalNotificationBannerPolicy.shouldScheduleBanner(for: row, currentUserId: "user-a", seenKeys: []),
                type.rawValue
            )
        }
    }

    func testTimesheetSubmissionReminderDoesNotScheduleASecondLocalBanner() {
        let row = event(id: "ts-1", type: .timesheetSubmissionReminder, relatedId: "2026-10-17")
        XCTAssertFalse(
            LocalNotificationBannerPolicy.shouldScheduleBanner(for: row, currentUserId: "user-a", seenKeys: [])
        )
    }

    func testFutureDeadlineDoesNotScheduleAnImmediateBanner() {
        let reminder = event(
            id: "due-1",
            type: .deadlineReminder,
            relatedId: "deadline-1",
            isFutureScheduledDeadline: true
        )
        XCTAssertFalse(
            LocalNotificationBannerPolicy.shouldScheduleBanner(for: reminder, currentUserId: "user-a", seenKeys: [])
        )
    }

    func testSyntheticHolidayDecisionDoesNotScheduleButRequestDoes() {
        let decision = event(id: "leave-1", type: .holidayRequestApproved, isSynthetic: true)
        let request = event(id: "leave-2", type: .holidayRequestSubmitted, isSynthetic: true)
        XCTAssertFalse(
            LocalNotificationBannerPolicy.shouldScheduleBanner(for: decision, currentUserId: "user-a", seenKeys: [])
        )
        XCTAssertTrue(
            LocalNotificationBannerPolicy.shouldScheduleBanner(for: request, currentUserId: "user-a", seenKeys: [])
        )
    }
}
