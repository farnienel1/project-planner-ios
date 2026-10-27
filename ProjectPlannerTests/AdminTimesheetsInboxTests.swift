import XCTest
@testable import Project_Planner

/// Regressions from the Raccord MEP report (October 2026):
/// an admin lost User Timesheets, and web inbox types vanished on iOS.
@MainActor
final class AdminTimesheetsInboxTests: XCTestCase {
    private let orgId = "0F9E8D7C-0000-4000-8000-0000000000AA"

    private func user(
        id: String,
        email: String,
        role: UserRole,
        permissions: UserPermissions,
        isActive: Bool = true,
        passwordSet: Bool = true,
        isSuperAdmin: Bool = false
    ) -> AppUser {
        AppUser(
            id: id,
            email: email,
            organizationId: orgId,
            role: role,
            firstName: "Test",
            surname: "Person",
            isActive: isActive,
            passwordSet: passwordSet,
            permissions: permissions,
            isSuperAdmin: isSuperAdmin
        )
    }

    // MARK: - User Timesheets

    func testAdminSeesUserTimesheetsWithEmptyRoster() {
        let store = UserStore()
        store.currentUser = user(
            id: "testAdminUid0001",
            email: "admin@test.com",
            role: .admin,
            permissions: UserPermissions(adminAccess: true, manager: true, operatives: true),
            isSuperAdmin: true
        )
        store.organizationUsers = []
        XCTAssertTrue(store.canAccessOperativeTimesheets())
    }

    func testAdminSeesUserTimesheetsWhenNoOperativeIsActive() {
        let store = UserStore()
        store.currentUser = user(
            id: "admin-1",
            email: "admin@test.com",
            role: .admin,
            permissions: UserPermissions(adminAccess: true)
        )
        store.organizationUsers = [
            user(id: "op-1", email: "op@test.com", role: .operative, permissions: UserPermissions(operativeMode: true), isActive: false)
        ]
        XCTAssertTrue(store.canAccessOperativeTimesheets())
    }

    func testManagerWithoutTeamStillHasNoUserTimesheets() {
        let store = UserStore()
        store.currentUser = user(
            id: "manager-1",
            email: "manager@test.com",
            role: .manager,
            permissions: UserPermissions(manager: true)
        )
        store.organizationUsers = []
        XCTAssertFalse(store.canAccessOperativeTimesheets())
    }

    func testOperativeNeverSeesUserTimesheets() {
        let store = UserStore()
        store.currentUser = user(
            id: "op-1",
            email: "op@test.com",
            role: .operative,
            permissions: UserPermissions(operativeMode: true)
        )
        XCTAssertFalse(store.canAccessOperativeTimesheets())
    }

    // MARK: - Inbox types the web writes

    func testWebInboxTypesParse() {
        XCTAssertEqual(AppNotification.NotificationType(rawValue: "hs_toolbox_reminder"), .hsToolboxReminder)
        XCTAssertEqual(AppNotification.NotificationType(rawValue: "idea_status"), .ideaStatus)
        XCTAssertEqual(AppNotification.NotificationType(rawValue: "idea_shipped"), .ideaShipped)
    }

    func testToolboxReminderUsesToolboxTalkToggleLikeTheScript() {
        XCTAssertEqual(UserNotificationToggle.preference(for: .hsToolboxReminder), .toolboxTalkIssued)
        XCTAssertNil(UserNotificationToggle.preference(for: .ideaStatus))
        XCTAssertNil(UserNotificationToggle.preference(for: .ideaShipped))
    }
}
