import XCTest
@testable import Project_Planner

/// Regressions from the Raccord MEP report (October 2026):
/// an admin lost User Timesheets, web inbox types vanished on iOS, and a re-added operative could not be booked.
@MainActor
final class AdminTimesheetsInboxRehireTests: XCTestCase {
    private let orgId = "2C67391E-D1FE-4F9F-8055-7149ACDE1F96"

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
            id: "dul1tDjfQfMX6ruXPHb8kJX5P7g2",
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

    // MARK: - Re-added operative with an Auth uid

    private func catalogueRow(email: String, isActive: Bool = true) -> Operative {
        Operative(firstName: "Row", lastName: "Owner", email: email, startDate: Date(), isActive: isActive)
    }

    func testAuthUidOperativeWithoutCatalogueRowNeedsOne() {
        let rehired = user(
            id: "aOai6wgC5kSBH5bUoiBxa6qZHTA2",
            email: "Rehired@Test.com ",
            role: .operative,
            permissions: UserPermissions(operativeMode: true)
        )
        let anonymisedRow = catalogueRow(email: "")
        let needed = UserStore.userOnlyOperativesNeedingCatalogueRow(users: [rehired], catalogue: [anonymisedRow])
        XCTAssertEqual(needed.map(\.id), ["aOai6wgC5kSBH5bUoiBxa6qZHTA2"])
    }

    func testExistingCatalogueRowForEmailIsReusedEvenWhenInactive() {
        let rehired = user(
            id: "aOai6wgC5kSBH5bUoiBxa6qZHTA2",
            email: "rehired@test.com",
            role: .operative,
            permissions: UserPermissions(operativeMode: true)
        )
        let needed = UserStore.userOnlyOperativesNeedingCatalogueRow(
            users: [rehired],
            catalogue: [catalogueRow(email: "REHIRED@test.com", isActive: false)]
        )
        XCTAssertTrue(needed.isEmpty)
    }

    func testUuidPlaceholdersInactiveUsersAndStaffAreLeftAlone() {
        let placeholder = user(
            id: "7A27FFF5-65FD-4563-8A0D-D074647C2739",
            email: "pending@test.com",
            role: .operative,
            permissions: UserPermissions(operativeMode: true),
            passwordSet: false
        )
        let inactive = user(
            id: "inactiveAuthUid000000000000",
            email: "inactive@test.com",
            role: .operative,
            permissions: UserPermissions(operativeMode: true),
            isActive: false
        )
        let manager = user(
            id: "managerAuthUid0000000000000",
            email: "manager@test.com",
            role: .manager,
            permissions: UserPermissions(manager: true)
        )
        let needed = UserStore.userOnlyOperativesNeedingCatalogueRow(
            users: [placeholder, inactive, manager],
            catalogue: []
        )
        XCTAssertTrue(needed.isEmpty)
    }

    func testSameEmailOnTwoUserDocumentsAddsOneRow() {
        let first = user(id: "authUidAAAAAAAAAAAAAAAAAAAAA", email: "dup@test.com", role: .operative, permissions: UserPermissions(operativeMode: true))
        let second = user(id: "authUidBBBBBBBBBBBBBBBBBBBBB", email: "DUP@test.com", role: .operative, permissions: UserPermissions(operativeMode: true))
        let needed = UserStore.userOnlyOperativesNeedingCatalogueRow(users: [first, second], catalogue: [])
        XCTAssertEqual(needed.count, 1)
    }
}
