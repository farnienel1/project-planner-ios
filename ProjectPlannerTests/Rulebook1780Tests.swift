import XCTest
@testable import Project_Planner

/// RULEBOOK 1.78.0 (owner decision 23 Nov, point 4) on iOS through `CanonicalBusinessEngine`: the
/// `timesheet_signoff_reminder` notice ("Timesheets waiting for your sign-off" before payday), written by the server
/// (Cloud Function `timesheetSignOffReminders`). iOS only reads and routes it. Expected values checked in node against
/// the packed script (rulebook 1.78.0).
@MainActor
final class Rulebook1780Tests: XCTestCase {
    func testSignOffReminderDecodesAndOpensUserTimesheetsAwaiting() throws {
        XCTAssertEqual(AppNotification.NotificationType(stored: "timesheet_signoff_reminder"), .timesheetSignOffReminder)
        XCTAssertTrue(CanonicalBusinessEngine.knownNotificationTypes.contains("timesheet_signoff_reminder"))
        XCTAssertEqual(CanonicalBusinessEngine.notificationDeliversDevicePush("timesheet_signoff_reminder"), true)
        let destination = try XCTUnwrap(CanonicalBusinessEngine.notificationDestination(
            type: "timesheet_signoff_reminder", relatedId: "2026-12-05", dayKey: "2026-11-16", catalogue: nil, role: "manager", deepLinkUserId: nil
        ))
        XCTAssertEqual(destination.kind, "timesheetTeamAwaiting")
        XCTAssertEqual(destination.dayKey, "2026-11-16")
        XCTAssertNil(destination.userId)
        XCTAssertEqual(UserNotificationToggle.preference(for: .timesheetSignOffReminder), .timesheetSignoff)
    }

    func testSignOffReminderTextComesFromThePackedRulebook() throws {
        let notice = try XCTUnwrap(CanonicalBusinessEngine.callJSON(
            "timesheetSignOffReminderNotice",
            arguments: [["count": 3, "paymentDayKey": "2026-11-27", "names": ["Olly One", "Pat Two", "Quin Three"]]]
        ) as? [String: Any])
        XCTAssertEqual(notice["title"] as? String, "Timesheets waiting for your sign-off")
        XCTAssertEqual(notice["message"] as? String, "3 timesheets are waiting for you to sign off before payday Fri 27 Nov.")
        XCTAssertEqual(notice["detail"] as? String, "Olly One, Pat Two, Quin Three")
    }

    func testLineManagerReminderSettingComesFromThePackedRulebook() throws {
        XCTAssertEqual(CanonicalBusinessEngine.lineManagerReminderDaysOptions, [1, 2, 3])
        XCTAssertEqual(CanonicalBusinessEngine.lineManagerReminderLabel, "Line manager sign-off reminder")
        XCTAssertEqual(CanonicalBusinessEngine.lineManagerReminderDaysLabel, "Days before payday")
        XCTAssertEqual(
            CanonicalBusinessEngine.lineManagerReminderAdminNote,
            "Admins are also reminded about people with no line manager, and about any timesheet still not signed off 24 hours before payday."
        )
        XCTAssertEqual(CanonicalBusinessEngine.parseLineManagerReminderDays(nil), 2)
        XCTAssertEqual(CanonicalBusinessEngine.parseLineManagerReminderDays(3), 3)
        XCTAssertEqual(CanonicalBusinessEngine.parseLineManagerReminderDays(9), 2)
        XCTAssertEqual(CanonicalBusinessEngine.lineManagerReminderSummary(1), "Sent at 08:00, 1 day before payday.")
        let fields = try XCTUnwrap(CanonicalBusinessEngine.lineManagerReminderWriteFields(
            storedInvoicing: ["lineManagerReminderDaysBeforePayday": 2], days: 3
        ))
        XCTAssertEqual(fields["invoicing.lineManagerReminderDaysBeforePayday"] as? Int, 3)
        let unchanged = try XCTUnwrap(CanonicalBusinessEngine.lineManagerReminderWriteFields(
            storedInvoicing: ["lineManagerReminderDaysBeforePayday": 3], days: 3
        ))
        XCTAssertTrue(unchanged.isEmpty)
    }

    func testInvoicingToFirestoreNeverWritesTheReminderFromSwiftSettings() throws {
        // Swift's `CanonicalInvoicingSettings` does not carry the field, so the main write never resets a stored choice.
        let written = try XCTUnwrap(CanonicalBusinessEngine.invoicingToFirestore(OrganizationInvoicingSettings.default.canonicalInvoicingSettings()))
        XCTAssertNil(written["lineManagerReminderDaysBeforePayday"])
    }
}
