import XCTest
@testable import Project_Planner

@MainActor
final class ScheduleWeekGridTests: XCTestCase {
    func testAdminOperativeAndManagerBookingsAreOneRowKeyedByUserId() {
        let operativeId = UUID()
        let admin = AppUser(
            id: "admin-1",
            email: "admin@example.com",
            organizationId: "org",
            role: .admin,
            firstName: "Test",
            surname: "Admin",
            permissions: UserPermissions(adminAccess: true)
        )
        let roster = Operative(
            id: operativeId,
            firstName: "Test",
            lastName: "Admin",
            email: admin.email,
            startDate: Date(timeIntervalSince1970: 0)
        )
        let fromBothCollections = ScheduleWeekGrid.staffRows(
            operativeIds: [operativeId],
            userIds: ["admin-1"],
            operatives: [roster],
            users: [admin]
        )
        XCTAssertEqual(fromBothCollections.count, 1)
        let row = fromBothCollections[0]
        XCTAssertEqual(row.id, "admin-1")
        XCTAssertEqual(row.role, .admin)
        XCTAssertEqual(row.role.tone, .blue)
        XCTAssertEqual(row.role.badge, "Admin")
        XCTAssertFalse(row.savesAsOperativeBooking)
        XCTAssertEqual(row.operativeIds, [operativeId])
        XCTAssertEqual(row.userIds, ["admin-1"])
        XCTAssertEqual(
            ScheduleWeekGrid.saveTarget(for: row, jobType: .catA),
            .managerSiteBookings(userId: "admin-1", locationType: .project)
        )

        let operativeCollectionOnly = ScheduleWeekGrid.staffRows(
            operativeIds: [operativeId],
            userIds: [],
            operatives: [roster],
            users: [admin]
        )
        XCTAssertEqual(operativeCollectionOnly.map(\.id), ["admin-1"])
        XCTAssertEqual(operativeCollectionOnly.map(\.role), [.admin])
        XCTAssertEqual(operativeCollectionOnly.map(\.role.tone), [.blue])
    }

    func testOperativeBookedOnTheManagerCollectionStaysGreenAndSavesToBookings() {
        let operativeId = UUID()
        let user = AppUser(
            id: "op-user",
            email: "op@example.com",
            organizationId: "org",
            role: .operative,
            firstName: "Pat",
            surname: "Operative",
            permissions: UserPermissions(operativeMode: true)
        )
        let roster = Operative(
            id: operativeId,
            firstName: "Pat",
            lastName: "Operative",
            email: user.email,
            startDate: Date(timeIntervalSince1970: 0)
        )
        let rows = ScheduleWeekGrid.staffRows(
            operativeIds: [],
            userIds: ["op-user"],
            operatives: [roster],
            users: [user]
        )
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].id, "op-user")
        XCTAssertEqual(rows[0].role, .operative)
        XCTAssertEqual(rows[0].role.tone, .green)
        XCTAssertEqual(rows[0].role.badge, "Op")
        XCTAssertTrue(rows[0].savesAsOperativeBooking)
        XCTAssertEqual(
            ScheduleWeekGrid.saveTarget(for: rows[0], jobType: .smallWorks),
            .operativeBookings(operativeId: operativeId)
        )
    }

    func testManagerRowIsBlueAndSmallWorksSavesAsSmallWork() {
        let manager = AppUser(
            id: "mgr-1",
            email: "manager@example.com",
            organizationId: "org",
            role: .manager,
            firstName: "Mia",
            surname: "Manager",
            permissions: UserPermissions(manager: true)
        )
        let rows = ScheduleWeekGrid.staffRows(
            operativeIds: [],
            userIds: ["mgr-1"],
            operatives: [],
            users: [manager]
        )
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].role, .manager)
        XCTAssertEqual(rows[0].role.tone, .blue)
        XCTAssertEqual(rows[0].role.badge, "Mgr")
        XCTAssertEqual(rows[0].id, "mgr-1")
        XCTAssertEqual(
            ScheduleWeekGrid.saveTarget(for: rows[0], jobType: .smallWorks),
            .managerSiteBookings(userId: "mgr-1", locationType: .smallWork)
        )
    }

    func testSubcontractorRowIsPurpleAndHasNoQuickAddSave() {
        let id = UUID()
        let rows = ScheduleWeekGrid.subcontractorRows(ids: [id]) { _ in "Sparkes" }
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].role, .subcontractor)
        XCTAssertEqual(rows[0].role.tone, .purple)
        XCTAssertEqual(rows[0].role.badge, "Sub")
        XCTAssertNil(ScheduleWeekGrid.saveTarget(for: rows[0], jobType: .catA))
    }

    func testDifferentPeopleStayOnSeparateRows() {
        let adminOperative = UUID()
        let otherOperative = UUID()
        let admin = AppUser(
            id: "admin-1",
            email: "admin@example.com",
            organizationId: "org",
            role: .admin,
            firstName: "Test",
            surname: "Admin",
            permissions: UserPermissions(adminAccess: true)
        )
        let other = AppUser(
            id: "op-2",
            email: "other@example.com",
            organizationId: "org",
            role: .operative,
            firstName: "Other",
            surname: "Person",
            permissions: UserPermissions(operativeMode: true)
        )
        let rows = ScheduleWeekGrid.staffRows(
            operativeIds: [adminOperative, otherOperative],
            userIds: ["admin-1"],
            operatives: [
                Operative(id: adminOperative, firstName: "Test", lastName: "Admin", email: admin.email, startDate: .distantPast),
                Operative(id: otherOperative, firstName: "Other", lastName: "Person", email: other.email, startDate: .distantPast)
            ],
            users: [admin, other]
        )
        XCTAssertEqual(Set(rows.map(\.id)), Set(["admin-1", "op-2"]))
        XCTAssertEqual(rows.first { $0.id == "admin-1" }?.role, .admin)
        XCTAssertEqual(rows.first { $0.id == "op-2" }?.role, .operative)
    }

    func testQuickAddClocksComeFromTheSharedHalves() {
        let clocks = ScheduleWeekGrid.slotClocks(policy: .default)
        XCTAssertEqual(clocks?.fullDay.label, "07:30–16:00")
        XCTAssertEqual(clocks?.morning.label, "07:30–12:00")
        XCTAssertEqual(clocks?.afternoon.label, "12:30–16:00")
    }
}
