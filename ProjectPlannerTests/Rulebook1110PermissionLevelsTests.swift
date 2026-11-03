import XCTest
@testable import Project_Planner

/// RULEBOOK 1.11.0 §8, §11, §16, §17 through `CanonicalBusinessEngine`: permission toggles by level
/// (`effectivePermissions`, `lockedPermissionFields`, `permissionToggleRows`), Change user type
/// (`accountTypeChangeWrites`), line managers (`lineManagerCandidates`, `lineManagerOptions`, `lineManagerSummary`),
/// PAYE timesheets (`showsMyTimesheets`, `timesheetDaysForPerson`), booking `jobCollection`
/// (`bookingJobCollectionFields`, `jobCollectionForJobId`, `jobKind`) and the roster level (`organizationLevelFor`).
@MainActor
final class Rulebook1110PermissionLevelsTests: XCTestCase {
    override func setUp() {
        super.setUp()
        EffectivePermissionsCache.reset()
        BookingJobCollectionContext.reset()
    }

    override func tearDown() {
        EffectivePermissionsCache.reset()
        BookingJobCollectionContext.reset()
        super.tearDown()
    }

    private func user(
        id: String,
        role: UserRole,
        permissions: UserPermissions,
        isSuperAdmin: Bool = false,
        organizationId: String = "ORG-1",
        isActive: Bool = true,
        passwordSet: Bool = true,
        employmentType: EmploymentType = .selfEmployed
    ) -> AppUser {
        AppUser(
            id: id,
            email: "\(id.lowercased())@example.com",
            organizationId: organizationId,
            role: role,
            firstName: id,
            surname: "Test",
            isActive: isActive,
            passwordSet: passwordSet,
            permissions: permissions,
            isSuperAdmin: isSuperAdmin,
            employmentType: employmentType
        )
    }

    // MARK: Effective permissions

    func testAnAdminHasEveryToggleOnExceptAnnualLeaveManagement() {
        let admin = user(id: "ADMIN", role: .admin, permissions: UserPermissions(adminAccess: true, operatives: false, weeklyReports: false, wholesalersOrderHistory: false))
        XCTAssertEqual(admin.permissionLevel, .admin)
        let effective = admin.effectivePermissions
        XCTAssertTrue(effective.operatives, "Operatives is on and locked for admins")
        XCTAssertTrue(effective.weeklyReports)
        XCTAssertTrue(effective.wholesalersOrderHistory)
        XCTAssertTrue(effective.materials)
        XCTAssertTrue(effective.siteAudit)
        XCTAssertFalse(effective.operativeMode, "an admin has no operative mode")
        XCTAssertFalse(effective.annualLeaveSelfBook, "the one toggle an admin can change keeps its stored value")
        XCTAssertFalse(admin.permissions.operatives, "the stored toggle is not rewritten")
    }

    func testAManagerHasMaterialsAndSiteAuditOnButWholesalersAsStored() {
        let manager = user(id: "MGR", role: .manager, permissions: UserPermissions(manager: true, materials: false, siteAudit: false, wholesalersOrderHistory: false))
        XCTAssertEqual(manager.permissionLevel, .manager)
        let effective = manager.effectivePermissions
        XCTAssertTrue(effective.materials)
        XCTAssertTrue(effective.siteAudit)
        XCTAssertFalse(effective.wholesalersOrderHistory)
        XCTAssertEqual(CanonicalBusinessEngine.lockedPermissionFields(manager.permissionSubject).map { Set($0) }, ["materials", "siteAudit"])
    }

    func testAdminRowsAreAllOnAndLockedExceptAnnualLeaveManagement() {
        let rows = CanonicalBusinessEngine.permissionToggleRows(level: .admin, user: nil, mode: .edit)
        XCTAssertFalse(rows.isEmpty, "the packed script answered")
        let visible = rows.filter(\.visible)
        XCTAssertTrue(visible.contains { $0.field == "adminAccess" })
        XCTAssertTrue(visible.contains { $0.field == "operatives" })
        XCTAssertTrue(visible.contains { $0.field == "materials" })
        XCTAssertTrue(visible.contains { $0.field == "siteAudit" })
        for row in visible where row.field != "annualLeaveSelfBook" {
            XCTAssertTrue(row.value, "\(row.field) reads on for an admin")
            XCTAssertFalse(row.editable, "\(row.field) is locked for an admin")
        }
        XCTAssertEqual(visible.first { $0.field == "annualLeaveSelfBook" }?.editable, true)
    }

    func testManagerAndOperativeRows() {
        let manager = CanonicalBusinessEngine.permissionToggleRows(level: .manager, user: nil, mode: .add).filter(\.visible)
        XCTAssertFalse(manager.contains { $0.field == "adminAccess" })
        XCTAssertEqual(manager.first { $0.field == "materials" }?.editable, false)
        XCTAssertEqual(manager.first { $0.field == "siteAudit" }?.editable, false)
        XCTAssertEqual(manager.first { $0.field == "wholesalersOrderHistory" }?.editable, true)
        let operative = CanonicalBusinessEngine.permissionToggleRows(level: .operative, user: nil, mode: .add).filter(\.visible)
        XCTAssertEqual(operative.map(\.field), ["materials", "siteAudit"])
        XCTAssertTrue(operative.allSatisfy(\.editable))
        let summary = CanonicalBusinessEngine.permissionToggleRows(level: .manager, user: nil, mode: .summary)
        XCTAssertTrue(summary.allSatisfy { !$0.editable }, "summary rows are never editable")
    }

    func testAddUserDefaultsComeFromTheRulebook() throws {
        let admin = try XCTUnwrap(CanonicalBusinessEngine.addUserPermissionDefaults(.admin))
        XCTAssertEqual(admin["operatives"], true)
        XCTAssertEqual(admin["annualLeaveSelfBook"], false)
        let operative = try XCTUnwrap(CanonicalBusinessEngine.addUserPermissionDefaults(.operative))
        XCTAssertEqual(operative["operativeMode"], true)
        XCTAssertEqual(operative["materials"], false)
        XCTAssertEqual(operative["siteAudit"], false, "1.14.0: every toggle the adder can change starts off")
        XCTAssertTrue(UserPermissions().applying(operative).operativeMode)
    }

    func testRulebookMapRoundTrips() {
        var permissions = UserPermissions()
        permissions.setFlag("weeklyReports", true)
        permissions.setFlag("skills", true)
        XCTAssertTrue(permissions.weeklyReports)
        XCTAssertFalse(permissions.skills, "skills is retired")
        XCTAssertEqual(permissions.rulebookMap.count, UserPermissions.rulebookFields.count)
        XCTAssertEqual(UserPermissions().applying(permissions.rulebookMap), permissions)
    }

    // MARK: Change user type

    func testChangeUserTypeWritesTheProfileTheMembersEntryAndTheMembership() throws {
        let person: [String: Any] = ["id": "U1", "email": "u1@example.com", "organizationId": "ORG-1", "role": "manager", "manager": true]
        let plan = try XCTUnwrap(CanonicalBusinessEngine.accountTypeChangeWrites(person: person, kind: .admin, organizationId: "ORG-1", roster: [], permissions: nil))
        guard case .ok(let role, let permissions, let writes, let note) = plan else { return XCTFail("refused") }
        XCTAssertEqual(role, .admin)
        // RULEBOOK 1.15.0 §11 `accountTypePermissions`: a type change keeps the stored toggles (Operatives was never
        // stored, so it stays off underneath; an admin reads it on through `effectivePermissions`). Checked in node.
        XCTAssertEqual(permissions["adminAccess"], true)
        XCTAssertEqual(permissions["operatives"], false)
        XCTAssertNil(note)
        var paths: [String] = []
        for write in writes {
            switch write {
            case .userProfile(let path, _), .organizationMember(let path, _): paths.append(path)
            case .membership(let path, let role, _):
                paths.append(path)
                XCTAssertEqual(role, "admin")
            }
        }
        XCTAssertEqual(paths, ["users/U1", "organizations/ORG-1", "users/U1/orgMemberships/ORG-1"])
    }

    func testChangeUserTypeOfAnotherCompanysProfileLeavesThatProfileAlone() throws {
        let person: [String: Any] = ["id": "U2", "email": "u2@example.com", "organizationId": "ORG-OTHER", "role": "manager"]
        let plan = try XCTUnwrap(CanonicalBusinessEngine.accountTypeChangeWrites(person: person, kind: .operative, organizationId: "ORG-1", roster: [], permissions: nil))
        guard case .ok(_, _, let writes, let note) = plan else { return XCTFail("refused") }
        XCTAssertNotNil(note)
        XCTAssertFalse(writes.contains { if case .userProfile = $0 { return true }; return false })
    }

    func testASuperAdminStaysAnAdmin() throws {
        let person: [String: Any] = ["id": "SA", "email": "sa@example.com", "organizationId": "ORG-1", "isSuperAdmin": true, "role": "admin"]
        let plan = try XCTUnwrap(CanonicalBusinessEngine.accountTypeChangeWrites(person: person, kind: .manager, organizationId: "ORG-1", roster: [], permissions: nil))
        guard case .refused(let reason, _) = plan else { return XCTFail("a super admin was demoted") }
        XCTAssertEqual(reason, "super_admin")
    }

    // MARK: Line managers

    func testLineManagerCandidatesAreActiveStaffNeverTheSubject() {
        let roster = [
            user(id: "ADMIN", role: .admin, permissions: UserPermissions(adminAccess: true)),
            user(id: "MGR", role: .manager, permissions: UserPermissions(manager: true)),
            user(id: "OP", role: .operative, permissions: UserPermissions(operativeMode: true)),
            user(id: "GONE", role: .manager, permissions: UserPermissions(manager: true), isActive: false),
            user(id: "PENDING", role: .manager, permissions: UserPermissions(manager: true), passwordSet: false),
        ]
        let subject = roster[1]
        let ids = LineManagerRulebook.candidates(for: subject, roster: roster).map(\.id)
        XCTAssertEqual(ids, ["ADMIN"])
    }

    func testNoLineManagerIsOfferedOnlyToAdmins() {
        XCTAssertTrue(LineManagerRulebook.allowsNoLineManager(for: user(id: "A", role: .admin, permissions: UserPermissions(adminAccess: true))))
        XCTAssertFalse(LineManagerRulebook.allowsNoLineManager(for: user(id: "M", role: .manager, permissions: UserPermissions(manager: true))))
        XCTAssertFalse(LineManagerRulebook.allowsNoLineManager(for: user(id: "O", role: .operative, permissions: UserPermissions(operativeMode: true))))
    }

    func testPayBasisNoteIsTheRulebooks() {
        XCTAssertTrue(CanonicalBusinessEngine.payBasisSaveNote.contains("not both"))
        XCTAssertFalse(CanonicalBusinessEngine.payBasisSaveNote.contains("both kept"))
    }

    // MARK: PAYE timesheets

    func testAPAYEPersonHasNoMyTimesheets() throws {
        let paye = user(id: "PAYE", role: .operative, permissions: UserPermissions(operativeMode: true), employmentType: .paye)
        let selfEmployed = user(id: "SE", role: .operative, permissions: UserPermissions(operativeMode: true), employmentType: .selfEmployed)
        let zone = "Europe/London"
        XCTAssertEqual(CanonicalBusinessEngine.showsMyTimesheets(person: CanonicalBusinessEngine.timesheetPerson(paye), startDayKey: "2026-11-01", endDayKey: "2026-11-15", timeZone: zone), false)
        XCTAssertEqual(CanonicalBusinessEngine.showsMyTimesheets(person: CanonicalBusinessEngine.timesheetPerson(selfEmployed), startDayKey: "2026-11-01", endDayKey: "2026-11-15", timeZone: zone), true)
        let days = try XCTUnwrap(CanonicalBusinessEngine.timesheetDaysForPerson(person: CanonicalBusinessEngine.timesheetPerson(selfEmployed), startDayKey: "2026-11-01", endDayKey: "2026-11-03", timeZone: zone))
        XCTAssertEqual(days, ["2026-11-01", "2026-11-02", "2026-11-03"])
    }

    // MARK: Booking jobCollection

    func testBookingsCarryTheirJobsCollection() {
        XCTAssertEqual(CanonicalBusinessEngine.jobCollectionForJobId("abc", projects: ["ABC"], smallWorks: ["SW-1"]), "projects")
        XCTAssertEqual(CanonicalBusinessEngine.jobCollectionForJobId("sw-1", projects: ["ABC"], smallWorks: ["SW-1"]), "smallWorks")
        XCTAssertNil(CanonicalBusinessEngine.jobCollectionForJobId("both", projects: ["BOTH"], smallWorks: ["both"]), "ambiguous ids carry none")
        XCTAssertEqual(CanonicalBusinessEngine.bookingJobCollectionFields(collection: "bookings", jobCollection: "small_works"), ["jobCollection": "smallWorks"])
        XCTAssertEqual(CanonicalBusinessEngine.bookingJobCollectionFields(collection: "managerSiteBookings", jobCollection: nil, locationType: "office"), [:])
        XCTAssertEqual(CanonicalBusinessEngine.bookingJobCollectionFields(collection: "managerSiteBookings", jobCollection: nil, locationType: "small_work"), ["jobCollection": "smallWorks"])
        XCTAssertEqual(CanonicalBusinessEngine.jobKind(jobType: "Small Works", collection: "projects"), "projects", "the collection decides")
    }

    // MARK: Roster level

    func testTheLevelInThisOrganisationNeverComesFromAnotherCompanysFlags() throws {
        let creator = try XCTUnwrap(CanonicalBusinessEngine.organizationLevelFor(organizationId: "ORG-1", userId: "C", user: ["organizationId": "ORG-2"], membership: nil, membersRole: "manager", creatorUserId: "C"))
        XCTAssertEqual(creator.level, .admin)
        XCTAssertTrue(creator.isSuperAdmin)
        let member = try XCTUnwrap(CanonicalBusinessEngine.organizationLevelFor(organizationId: "ORG-1", userId: "M", user: ["organizationId": "ORG-2", "adminAccess": true], membership: nil, membersRole: "manager", creatorUserId: "C"))
        XCTAssertEqual(member.level, .manager)
        XCTAssertEqual(member.source, "members")
        let shown = user(id: "M", role: .admin, permissions: UserPermissions(adminAccess: true), organizationId: "ORG-2").atOrganizationLevel(member)
        XCTAssertEqual(shown.role, .manager)
        XCTAssertFalse(shown.permissions.adminAccess)
    }
}
