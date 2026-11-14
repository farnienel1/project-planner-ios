import XCTest
@testable import Project_Planner

/// 1.37.3: the project / small-works Scheduling week grid names each row through the rulebook's
/// `resolveBookingPerson` (web `ProjectScheduleWeekOverview.tsx` with `findUserByAnyId` and the roster's
/// `userIdAliases`), so a booking under a former invite id, a same-email document, a catalogue row or another letter
/// case lands on the person's row with their level's pill; an id that names nobody is left off the grid as on web
/// (1.41.0; before, "Unknown person" with a neutral pill). Taps follow `canWriteBooking` (`ScheduleGridTapGate`).
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

    func testAnIdThatNamesNobodyIsShownAsUnknownPersonLikeWeb() {
        // RULEBOOK 1.44.0 §21 (owner decision 14 Nov, question H option 1): a booking whose id names nobody is never
        // hidden. Its row reads `scheduleRowPerson`'s label with the short id, and has no Quick Add.
        let stray = UUID()
        let someone = account(
            "TEST-someone", email: "someone@example.test", first: "Some", last: "One",
            role: .manager, permissions: UserPermissions(manager: true)
        )

        let rows = ScheduleWeekGrid.staffRows(operativeIds: [stray], userIds: [], operatives: [], users: [someone])

        XCTAssertEqual(rows.count, 1, "an id that names nobody keeps its row")
        XCTAssertEqual(rows.first?.role, .unknown)
        let hint = String(Booking.storedOperativeId(for: stray).prefix(8)).uppercased()
        XCTAssertEqual(rows.first?.name, "Unknown person · \(hint)")
        XCTAssertNil(rows.first.flatMap { ScheduleWeekGrid.saveTarget(for: $0, jobType: .catA) }, "no Quick Add")
    }

    func testAStrayIdNeverHidesTheKnownPeopleBookedThatWeek() {
        var person = account(
            "TEST-farnie-uid", email: "farnie@example.test", first: "Farnie", last: "Nel",
            role: .operative, permissions: UserPermissions(operativeMode: true)
        )
        person.formerUserIds = ["TEST-old-invite-id"]
        let former = Booking.internalOperativeId(for: "TEST-old-invite-id")
        let rows = ScheduleWeekGrid.staffRows(operativeIds: [former, UUID()], userIds: [], operatives: [], users: [person])
        XCTAssertEqual(rows.filter { $0.role != .unknown }.map(\.name), ["Farnie Nel"], "the former id keeps its row")
        XCTAssertEqual(rows.filter { $0.role == .unknown }.count, 1, "the stray id is shown as an unknown person (1.44.0)")
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

    // MARK: Review #216

    func testASmallWorksJobAndAManagersOwnSmallWorkBooking() {
        var smallWorks = job(managedBy: ["TEST-manager"])
        smallWorks.sourceCollection = .smallWorks
        var other = job(managedBy: ["TEST-someone-else"])
        other.sourceCollection = .smallWorks
        let own = ScheduleGridTapGate.Tapped.managerBooking(userId: "TEST-manager", locationType: ManagerLocationType.smallWork.rawValue)
        XCTAssertEqual(ScheduleGridTapGate.action(own, viewer: manager, job: smallWorks, managers: []), .edit)
        XCTAssertEqual(ScheduleGridTapGate.action(own, viewer: manager, job: other, managers: []), .none)
        XCTAssertEqual(
            ScheduleGridTapGate.action(
                .emptyDay(saveTarget: .managerSiteBookings(userId: "TEST-manager", locationType: .smallWork)),
                viewer: manager, job: smallWorks, managers: []
            ),
            .quickAdd
        )
        XCTAssertEqual(ScheduleGridTapGate.action(own, viewer: admin, job: other, managers: []), .edit)
    }

    func testAManagerMatchedThroughAManagersRowOnTheirEmail() {
        let rowId = UUID()
        var byRow = job(managedBy: [])
        byRow.managerIds = [rowId]
        byRow.managerId = rowId
        let managers: [[String: Any]] = [["id": byRow.storedManagerId(for: rowId), "email": "TEST-manager@x.t"]]
        XCTAssertEqual(ScheduleGridTapGate.action(.labourBooking, viewer: manager, job: byRow, managers: managers), .edit)
        XCTAssertEqual(
            ScheduleGridTapGate.action(.labourBooking, viewer: manager, job: byRow, managers: [["id": byRow.storedManagerId(for: rowId), "email": "other@x.t"]]),
            .none
        )
    }

    func testAGhostWithNoEmailKeepsItsRow() {
        var ghost = account(
            "TEST-ghost-uid", email: "", first: "Gus", last: "Ghost",
            role: .operative, permissions: UserPermissions(operativeMode: true)
        )
        ghost.isGhost = true
        let booked = Booking.internalOperativeId(for: "TEST-ghost-uid")

        let rows = ScheduleWeekGrid.staffRows(operativeIds: [booked], userIds: [], operatives: [], users: [ghost])

        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].name, "Gus Ghost")
        XCTAssertEqual(rows[0].role, .operative)
        XCTAssertNotNil(ScheduleWeekGrid.saveTarget(for: rows[0], jobType: .catA))
    }

    func testWhenTheScriptDoesNotAnswerCatalogueRowsKeepTheirPillAndQuickAdd() {
        let rowId = UUID()
        let noEmailRow = Operative(id: rowId, firstName: "Cat", lastName: "Row", email: "", startDate: Date(timeIntervalSince1970: 0))
        let stray = UUID()
        let silent: StaffEmailIdentity.BookingPersonResolver = { _, _ in nil }

        let rows = ScheduleWeekGrid.staffRows(
            operativeIds: [rowId, stray],
            userIds: [],
            operatives: [noEmailRow],
            users: [],
            resolve: silent
        )

        let catalogue = rows.first { $0.operativeIds == [rowId] }
        XCTAssertEqual(catalogue?.role, .operative, "a catalogue row the id names stays an operative")
        XCTAssertEqual(catalogue.flatMap { ScheduleWeekGrid.saveTarget(for: $0, jobType: .catA) }, .operativeBookings(operativeId: rowId))
        XCTAssertNil(rows.first { $0.operativeIds == [stray] }, "an id that names nothing is left off the grid (RULEBOOK 1.41.0)")
    }

    func testWhenTheScriptDoesNotAnswerAdminsAreNotLockedOut() {
        let silent: (ScheduleGridTapGate.Write) -> Bool? = { _ in nil }
        XCTAssertEqual(ScheduleGridTapGate.action(.labourBooking, viewer: admin, answer: silent), .edit)
        XCTAssertEqual(ScheduleGridTapGate.action(.labourBooking, viewer: manager, answer: silent), .none)
        XCTAssertEqual(ScheduleGridTapGate.action(.labourBooking, viewer: operative, answer: silent), .none)
        XCTAssertEqual(ScheduleGridTapGate.action(.labourBooking, viewer: manager) { _ in true }, .edit)
        XCTAssertEqual(ScheduleGridTapGate.action(.labourBooking, viewer: admin) { _ in false }, .none, "a no from the rulebook stands")
    }

    func testAFormerIdBookingKeepsItsHoursOnThePersonsRow() {
        var person = account(
            "TEST-farnie-uid", email: "farnie@example.test", first: "Farnie", last: "Nel",
            role: .operative, permissions: UserPermissions(operativeMode: true)
        )
        person.formerUserIds = ["TEST-old-invite-id"]
        let oldId = Booking.internalOperativeId(for: "TEST-old-invite-id")
        let newId = Booking.internalOperativeId(for: "TEST-farnie-uid")
        let day = Date()
        let bookings = [
            Booking(operativeId: oldId, projectId: UUID(), date: day, timeSlot: .fullDay, bookedBy: "TEST-ADMIN"),
            Booking(operativeId: newId, projectId: UUID(), date: day, timeSlot: .morning, bookedBy: "TEST-ADMIN"),
        ]
        let totalBefore = bookings.reduce(0) { $0 + $1.paidBookedHours() }

        let rows = ScheduleWeekGrid.staffRows(operativeIds: Set(bookings.map(\.operativeId)), userIds: [], operatives: [], users: [person])

        XCTAssertEqual(rows.count, 1, "both ids are one person")
        let onRow = bookings.filter { rows[0].operativeIds.contains($0.operativeId) }.reduce(0) { $0 + $1.paidBookedHours() }
        XCTAssertEqual(onRow, totalBefore, accuracy: 0.0001, "the row's hours are the bookings' own hours, unchanged")
    }

    // MARK: Fresh roster after a level change

    func testALevelChangeOrNewClaimsReloadTheRoster() {
        XCTAssertTrue(UserStore.rosterNeedsFreshLoad(levelBefore: .admins, levelAfter: .managers, claimsRefreshed: false))
        XCTAssertTrue(UserStore.rosterNeedsFreshLoad(levelBefore: .managers, levelAfter: .managers, claimsRefreshed: true))
        XCTAssertFalse(UserStore.rosterNeedsFreshLoad(levelBefore: .managers, levelAfter: .managers, claimsRefreshed: false))
        XCTAssertFalse(UserStore.rosterNeedsFreshLoad(levelBefore: nil, levelAfter: .managers, claimsRefreshed: false))
    }
}
