import XCTest
@testable import Project_Planner

/// 1.37.3: the project / small-works Scheduling week grid names each row through the rulebook's
/// `resolveBookingPerson` (web `ProjectScheduleWeekOverview.tsx` with `findUserByAnyId` and the roster's
/// `userIdAliases`), so a booking under a former invite id, a same-email document, a catalogue row or another letter
/// case lands on the person's row with their level's pill; an id that names nobody reads "Unknown person" with a
/// neutral pill, never "Op". Taps follow `canWriteBooking` (`ScheduleGridTapGate`).
@MainActor
final class ScheduleGridPeopleTests: XCTestCase {
    private typealias Role = CanonicalBusinessEngine.CanonicalStaffAccountRole

    nonisolated override func setUp() {
        super.setUp()
        JobAccessContext.updateViewer(nil)
    }

    nonisolated override func tearDown() {
        JobAccessContext.updateViewer(nil)
        super.tearDown()
    }

    private func account(
        _ id: String,
        email: String,
        first: String,
        last: String,
        role: UserRole,
        permissions: UserPermissions
    ) -> AppUser {
        AppUser(
            id: id,
            email: email,
            organizationId: "TEST-org",
            role: role,
            firstName: first,
            surname: last,
            permissions: permissions
        )
    }

    // MARK: Row resolution

    func testABookingUnderAFormerInviteIdIsOnThePersonsRow() {
        var operative = account(
            "TEST-farnie-uid", email: "farnie@example.test", first: "Farnie", last: "Nel",
            role: .operative, permissions: UserPermissions(operativeMode: true)
        )
        operative.formerUserIds = ["TEST-old-invite-id"]
        let booked = Booking.internalOperativeId(for: "TEST-old-invite-id")

        let rows = ScheduleWeekGrid.staffRows(operativeIds: [booked], userIds: [], operatives: [], users: [operative])

        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].name, "Farnie Nel", "a former invite id names the person (was Unknown person)")
        XCTAssertEqual(rows[0].role, .operative)
        XCTAssertEqual(rows[0].role.badge, "Op")
        XCTAssertEqual(rows[0].operativeIds, [booked], "the cell still finds the booking under its stored id")
    }

    func testAnAdminsBookingUnderAFormerIdKeepsTheAdminPill() {
        var admin = account(
            "TEST-admin-uid", email: "admin@example.test", first: "Test", last: "Admin",
            role: .admin, permissions: UserPermissions(adminAccess: true)
        )
        admin.formerUserIds = ["TEST-admin-old"]
        let booked = Booking.internalOperativeId(for: "TEST-admin-old")

        let rows = ScheduleWeekGrid.staffRows(operativeIds: [booked], userIds: [], operatives: [], users: [admin])

        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].name, "Test Admin")
        XCTAssertEqual(rows[0].role, .admin, "the level decides the pill, never a default Op")
        XCTAssertEqual(rows[0].role.tone, .blue)
    }

    func testSameEmailDocumentsAreOneRow() {
        let manager = account(
            "TEST-mgr-a", email: "manager@example.test", first: "Test", last: "Manager",
            role: .manager, permissions: UserPermissions(manager: true)
        )
        let copy = account(
            "TEST-mgr-b", email: "Manager@Example.test", first: "Test", last: "Manager",
            role: .manager, permissions: UserPermissions(manager: true)
        )
        let labour = Booking.internalOperativeId(for: "TEST-mgr-b")

        let rows = ScheduleWeekGrid.staffRows(
            operativeIds: [labour],
            userIds: ["TEST-mgr-a"],
            operatives: [],
            users: [manager, copy]
        )

        XCTAssertEqual(rows.count, 1, "a booking under the other same-email document is the same person")
        XCTAssertEqual(rows[0].name, "Test Manager")
        XCTAssertEqual(rows[0].role, .manager)
        XCTAssertTrue(rows[0].userIds.contains("TEST-mgr-a"))
        XCTAssertEqual(rows[0].operativeIds, [labour])
    }

    func testACatalogueRowOnTheAccountsEmailIsTheAccountsRow() {
        let rowId = UUID()
        let catalogue = Operative(
            id: rowId,
            firstName: "Farnie",
            lastName: "Nel",
            email: "FARNIE@example.test",
            startDate: Date(timeIntervalSince1970: 0)
        )
        let operative = account(
            "TEST-farnie", email: "farnie@example.test", first: "Farnie", last: "Nel",
            role: .operative, permissions: UserPermissions(operativeMode: true)
        )

        let rows = ScheduleWeekGrid.staffRows(
            operativeIds: [rowId],
            userIds: ["TEST-farnie"],
            operatives: [catalogue],
            users: [operative]
        )

        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].name, "Farnie Nel")
        XCTAssertEqual(rows[0].role, .operative)
    }

    func testAnUpperCaseIdMatchesALowerCaseAccount() throws {
        let lower = UUID().uuidString.lowercased()
        let admin = account(
            lower, email: "upper@example.test", first: "Case", last: "Admin",
            role: .admin, permissions: UserPermissions(adminAccess: true)
        )
        let booked = try XCTUnwrap(UUID(uuidString: lower.uppercased()))

        let rows = ScheduleWeekGrid.staffRows(operativeIds: [booked], userIds: [], operatives: [], users: [admin])

        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].name, "Case Admin")
        XCTAssertEqual(rows[0].role, .admin)
    }

    func testAnIdThatNamesNobodyIsUnknownWithANeutralPill() {
        let stray = UUID()
        let someone = account(
            "TEST-someone", email: "someone@example.test", first: "Some", last: "One",
            role: .manager, permissions: UserPermissions(manager: true)
        )

        let rows = ScheduleWeekGrid.staffRows(operativeIds: [stray], userIds: [], operatives: [], users: [someone])

        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].name, unknownLabourPersonName)
        XCTAssertEqual(rows[0].role, .unknown)
        XCTAssertEqual(rows[0].role.tone, .grey)
        XCTAssertNotEqual(rows[0].role.badge, "Op")
        XCTAssertNil(ScheduleWeekGrid.saveTarget(for: rows[0], jobType: .catA), "nobody to quick add for")
    }

    // MARK: Tap gate (`canWriteBooking`)

    private func viewer(_ role: Role, uid: String) -> JobAccessViewer {
        JobAccessViewer(role: role, projectsToggle: true, smallWorksToggle: true, uid: uid, ids: [uid], email: "\(uid)@x.t")
    }

    private var admin: JobAccessViewer {
        viewer(Role(isSuperAdmin: false, isAdmin: true, isManager: false, isOperativeMode: false), uid: "TEST-admin")
    }

    private var manager: JobAccessViewer {
        viewer(Role(isSuperAdmin: false, isAdmin: false, isManager: true, isOperativeMode: false), uid: "TEST-manager")
    }

    private var operative: JobAccessViewer {
        viewer(Role(isSuperAdmin: false, isAdmin: false, isManager: false, isOperativeMode: true), uid: "TEST-operative")
    }

    private func job(managedBy managerUserIds: [String]) -> Project {
        var job = Project(
            jobNumber: "TEST-J1",
            siteName: "TEST-Kitchen refit",
            siteAddress: "1 Test Street",
            client: Client(name: "TEST-Client"),
            startDate: Date(),
            endDate: Date(),
            jobType: .catA,
            manager: .na
        )
        job.storedManagerUserIds = managerUserIds
        return job
    }

    private let taps: [ScheduleGridTapGate.Tapped] = [
        .labourBooking,
        .subcontractorBooking,
        .emptyDay(saveTarget: .operativeBookings(operativeId: UUID())),
        .scheduleDay(subcontractor: false),
        .scheduleDay(subcontractor: true),
    ]

    func testAdminsMayActOnEveryJob() {
        let other = job(managedBy: ["TEST-someone-else"])
        XCTAssertEqual(ScheduleGridTapGate.action(.labourBooking, viewer: admin, job: other, managers: []), .edit)
        XCTAssertEqual(ScheduleGridTapGate.action(.subcontractorBooking, viewer: admin, job: other, managers: []), .edit)
        XCTAssertEqual(
            ScheduleGridTapGate.action(.emptyDay(saveTarget: .operativeBookings(operativeId: UUID())), viewer: admin, job: other, managers: []),
            .quickAdd
        )
        XCTAssertEqual(ScheduleGridTapGate.action(.scheduleDay(subcontractor: false), viewer: admin, job: other, managers: []), .openScheduler)
    }

    func testAManagerActsOnlyOnJobsTheyManage() {
        let managed = job(managedBy: ["TEST-manager"])
        let other = job(managedBy: ["TEST-someone-else"])
        XCTAssertEqual(ScheduleGridTapGate.action(.labourBooking, viewer: manager, job: managed, managers: []), .edit)
        XCTAssertEqual(
            ScheduleGridTapGate.action(.emptyDay(saveTarget: .operativeBookings(operativeId: UUID())), viewer: manager, job: managed, managers: []),
            .quickAdd
        )
        XCTAssertEqual(
            ScheduleGridTapGate.action(
                .managerBooking(userId: "TEST-manager", locationType: ManagerLocationType.project.rawValue),
                viewer: manager, job: managed, managers: []
            ),
            .edit,
            "their own manager site booking on a job they manage"
        )
        for tapped in taps {
            XCTAssertEqual(
                ScheduleGridTapGate.action(tapped, viewer: manager, job: other, managers: []),
                .none,
                "a manager sees every job (1.33.0) but books only on jobs they manage: \(tapped)"
            )
        }
        XCTAssertEqual(
            ScheduleGridTapGate.action(
                .managerBooking(userId: "TEST-someone-else", locationType: ManagerLocationType.project.rawValue),
                viewer: manager, job: other, managers: []
            ),
            .none
        )
    }

    func testOperativesAndAnUnknownViewerMayDoNothing() {
        let managed = job(managedBy: ["TEST-manager"])
        for tapped in taps {
            XCTAssertEqual(ScheduleGridTapGate.action(tapped, viewer: operative, job: managed, managers: []), .none)
            XCTAssertEqual(ScheduleGridTapGate.action(tapped, viewer: nil, job: managed, managers: []), .none, "profile not loaded: no tap")
        }
    }

    func testAnEmptyDayWithNobodyToBookDoesNothing() {
        let managed = job(managedBy: ["TEST-manager"])
        XCTAssertEqual(ScheduleGridTapGate.action(.emptyDay(saveTarget: nil), viewer: admin, job: managed, managers: []), .none)
    }

    // MARK: Fresh roster after a level change

    func testALevelChangeOrNewClaimsReloadTheRoster() {
        XCTAssertTrue(UserStore.rosterNeedsFreshLoad(levelBefore: .admins, levelAfter: .managers, claimsRefreshed: false))
        XCTAssertTrue(UserStore.rosterNeedsFreshLoad(levelBefore: .managers, levelAfter: .managers, claimsRefreshed: true))
        XCTAssertFalse(UserStore.rosterNeedsFreshLoad(levelBefore: .managers, levelAfter: .managers, claimsRefreshed: false))
        XCTAssertFalse(UserStore.rosterNeedsFreshLoad(levelBefore: nil, levelAfter: .managers, claimsRefreshed: false))
    }
}
