import XCTest
@testable import Project_Planner

/// RULEBOOK 1.28.0 (owner decisions of 4 Nov) on iOS through `CanonicalBusinessEngine`: the admin self-manage toggles
/// (Annual Leave Management `annualLeaveSelfBook`, Timesheet self-sign `timesheetSelfSign`) decide self-approval and
/// when an admin needs a line manager; the organisation's Super Admin (`isOrganizationSuperAdmin`, passed as
/// `organizationSuperAdmin`) always reads both on and locked. Every answer comes from the packed script
/// (`selfManageToggles`, `timesheetSelfSigned`, `canSelfBookAnnualLeave`, `lineManagerRequired`,
/// `lineManagerRequiredError`, `usersMissingLineManager`, `effectivePermissions`, `permissionToggleRows`,
/// `keepStoredLockedPermissions`); nothing is decided in Swift.
@MainActor
final class Rulebook1280Tests: XCTestCase {
    private let orgB = "TEST-ORG-B"

    override func setUp() {
        super.setUp()
        EffectivePermissionsCache.reset()
        OrganizationRulebookContext.update(
            from: Organization(firestoreDocumentId: orgB, name: "TEST-Company B", creatorUserId: "TEST-FOUNDER")
        )
    }

    override func tearDown() {
        OrganizationRulebookContext.update(from: nil)
        EffectivePermissionsCache.reset()
        super.tearDown()
    }

    // MARK: Helpers

    private func admin(
        _ id: String,
        selfBook: Bool = false,
        selfSign: Bool = false,
        lineManagers: [String] = [],
        isSuperAdmin: Bool = false,
        organizationId: String? = nil,
        employmentType: EmploymentType = .selfEmployed
    ) -> AppUser {
        var user = AppUser(
            id: id,
            email: "\(id.lowercased())@example.test",
            organizationId: organizationId ?? orgB,
            role: .admin,
            firstName: id,
            surname: "Test",
            passwordSet: true,
            permissions: UserPermissions(adminAccess: true, manager: true, annualLeaveSelfBook: selfBook, timesheetSelfSign: selfSign),
            isSuperAdmin: isSuperAdmin,
            employmentType: employmentType
        )
        user.setLineManagerUserIds(lineManagers)
        user.hasNoLineManager = lineManagers.isEmpty
        return user
    }

    private var adminMessage: String? {
        CanonicalBusinessEngine.constant("ADMIN_LINE_MANAGER_REQUIRED_MESSAGE", as: String.self)
    }

    private var payeAdminMessage: String? {
        CanonicalBusinessEngine.constant("PAYE_ADMIN_LINE_MANAGER_REQUIRED_MESSAGE", as: String.self)
    }

    private func selfManageRows(_ user: AppUser, viewerIsSubject: Bool = false) -> [String: RulebookPermissionToggleRow] {
        let rows = CanonicalBusinessEngine.permissionToggleRows(
            level: .admin,
            user: user.permissionSubject,
            mode: .edit,
            viewerIsSubject: viewerIsSubject
        )
        var out: [String: RulebookPermissionToggleRow] = [:]
        for row in rows where row.field == "annualLeaveSelfBook" || row.field == "timesheetSelfSign" { out[row.field] = row }
        return out
    }

    // MARK: Packed script

    func testThePackedScriptIsRulebook1280OrLater() throws {
        let stamp = try XCTUnwrap(CanonicalBusinessEngine.rulebookStamp())
        let parts = stamp.version.split(separator: ".").compactMap { Int($0) }
        XCTAssertFalse(parts.lexicographicallyPrecedes([1, 28, 0]), "rulebook \(stamp.version) predates 1.28.0")
        let exports = Set(CanonicalBusinessEngine.exportNames())
        for name in [
            "selfManageToggles", "isSuperAdminAccount", "isPayeAccount", "isOrganizationSuperAdmin", "lineManagerRequired",
            "keepStoredLockedPermissions", "permissionToggleRows", "ADMIN_LINE_MANAGER_REQUIRED_MESSAGE",
            "PAYE_ADMIN_LINE_MANAGER_REQUIRED_MESSAGE", "OWN_SELF_MANAGE_MESSAGE", "SUPER_ADMIN_SELF_MANAGE_MESSAGE",
            "TIMESHEET_SELF_SIGN_PAYE_NOTE",
        ] {
            XCTAssertTrue(exports.contains(name), "\(name) is not exported")
        }
        XCTAssertTrue(UserPermissions.rulebookFields.contains("timesheetSelfSign"))
        let membershipKeys = CanonicalBusinessEngine.constant("ORG_MEMBERSHIP_PERMISSION_KEYS", as: [String].self) ?? []
        XCTAssertTrue(membershipKeys.contains("timesheetSelfSign"))
        // 1.32.0 (§7, §11, owner decision 5 Nov) adds the Weekly report to the admin-only fields.
        XCTAssertEqual(CanonicalBusinessEngine.adminOnlyPermissionFields, ["timesheetSelfSign", "weeklyReports"])
    }

    func testMembershipAndStoredToggleCarryTimesheetSelfSign() throws {
        let mapped = FirebaseBackend.userPermissions(fromMembership: ["timesheetSelfSign": true], fallback: UserPermissions())
        XCTAssertTrue(mapped.timesheetSelfSign)
        var permissions = UserPermissions()
        permissions.setFlag("timesheetSelfSign", true)
        XCTAssertEqual(permissions.flag("timesheetSelfSign"), true)
        XCTAssertEqual(permissions.rulebookMap["timesheetSelfSign"], true)
        let data = try JSONEncoder().encode(permissions)
        XCTAssertTrue(try JSONDecoder().decode(UserPermissions.self, from: data).timesheetSelfSign)
    }

    // MARK: (1) The lone creator with no isSuperAdmin flag

    func testLoneUnflaggedCreatorIsTheSuperAdminAndNeverStranded() {
        let founder = admin("TEST-FOUNDER")
        XCTAssertFalse(founder.isSuperAdmin)
        XCTAssertEqual(founder.organizationSuperAdmin, true, "the creator is the Super Admin without the flag")
        XCTAssertEqual(RulebookPeople.person(founder)["organizationSuperAdmin"] as? Bool, true)
        XCTAssertTrue(AnnualLeaveSelfBookPolicy.canSelfBookAnnualLeave(for: founder, users: [founder]))
        XCTAssertEqual(RulebookPeople.timesheetSelfSigned(founder, users: [founder]), true)
        XCTAssertEqual(RulebookPeople.leaveSubmitLabel(founder, users: [founder]), "Submit")
        XCTAssertNil(AnnualLeaveApproval.lineManagerRequiredError(for: founder, users: [founder]))
        XCTAssertTrue(AnnualLeaveApproval.usersMissingLineManager([founder]).isEmpty)
        XCTAssertEqual(founder.effectivePermissions.annualLeaveSelfBook, true)
        XCTAssertEqual(founder.effectivePermissions.timesheetSelfSign, true)
        XCTAssertFalse(founder.permissions.timesheetSelfSign, "the derived on value is never stored")

        let rows = selfManageRows(founder)
        for field in ["annualLeaveSelfBook", "timesheetSelfSign"] {
            XCTAssertEqual(rows[field]?.value, true, field)
            XCTAssertEqual(rows[field]?.editable, false, "\(field) is locked on for the Super Admin")
            XCTAssertEqual(rows[field]?.note, CanonicalBusinessEngine.superAdminSelfManageMessage, field)
        }
    }

    // MARK: (2) Admin with both toggles and no line manager

    func testAdminWithBothTogglesNeedsNoLineManagerAndSelfApproves() {
        let solo = admin("TEST-ADMIN-BOTH", selfBook: true, selfSign: true)
        let users = [admin("TEST-FOUNDER"), solo]
        XCTAssertEqual(solo.organizationSuperAdmin, false)
        XCTAssertNil(AnnualLeaveApproval.lineManagerRequiredError(for: solo, users: users))
        XCTAssertEqual(CanonicalBusinessEngine.lineManagerRequired(user: RulebookPeople.person(solo)), false)
        XCTAssertTrue(AnnualLeaveSelfBookPolicy.canSelfBookAnnualLeave(for: solo, users: users))
        XCTAssertEqual(RulebookPeople.timesheetSelfSigned(solo, users: users), true)
        XCTAssertEqual(RulebookPeople.leaveSubmitLabel(solo, users: users), "Submit")
        XCTAssertFalse(AnnualLeaveApproval.usersMissingLineManager(users).map(\.id).contains("TEST-ADMIN-BOTH"))
        let rows = selfManageRows(solo)
        XCTAssertEqual(rows["annualLeaveSelfBook"]?.editable, true)
        XCTAssertEqual(rows["timesheetSelfSign"]?.editable, true)
        XCTAssertNil(rows["timesheetSelfSign"]?.note)
    }

    // MARK: (3) Admin with one toggle and no line manager

    func testAdminWithOneToggleAndNoLineManagerIsRequiredToHaveOne() {
        let leaveOnly = admin("TEST-ADMIN-LEAVE", selfBook: true)
        let signOnly = admin("TEST-ADMIN-SIGN", selfSign: true)
        let users = [admin("TEST-FOUNDER"), leaveOnly, signOnly]
        XCTAssertNotNil(adminMessage)
        XCTAssertEqual(AnnualLeaveApproval.lineManagerRequiredError(for: leaveOnly, users: users), adminMessage)
        XCTAssertEqual(AnnualLeaveApproval.lineManagerRequiredError(for: signOnly, users: users), adminMessage)
        // Each toggle still does its own job.
        XCTAssertTrue(AnnualLeaveSelfBookPolicy.canSelfBookAnnualLeave(for: leaveOnly, users: users))
        XCTAssertEqual(RulebookPeople.timesheetSelfSigned(leaveOnly, users: users), false)
        XCTAssertFalse(AnnualLeaveSelfBookPolicy.canSelfBookAnnualLeave(for: signOnly, users: users))
        XCTAssertEqual(RulebookPeople.timesheetSelfSigned(signOnly, users: users), true)
        let missing = Set(AnnualLeaveApproval.usersMissingLineManager(users).map(\.id))
        XCTAssertEqual(missing, ["TEST-ADMIN-LEAVE", "TEST-ADMIN-SIGN"])
    }

    // MARK: (4) PAYE admin: the leave toggle only

    func testPayeAdminNeedsOnlyTheLeaveToggleAndTheTimesheetRowIsGreyed() {
        let paye = admin("TEST-ADMIN-PAYE", selfBook: true, employmentType: .paye)
        let users = [admin("TEST-FOUNDER"), paye]
        XCTAssertNil(AnnualLeaveApproval.lineManagerRequiredError(for: paye, users: users))
        let rows = selfManageRows(paye)
        XCTAssertEqual(rows["timesheetSelfSign"]?.editable, false)
        XCTAssertEqual(rows["timesheetSelfSign"]?.note, CanonicalBusinessEngine.timesheetSelfSignPayeNote)
        XCTAssertEqual(rows["annualLeaveSelfBook"]?.editable, true)

        var payeOff = paye
        payeOff.permissions.annualLeaveSelfBook = false
        XCTAssertNotNil(payeAdminMessage)
        XCTAssertEqual(AnnualLeaveApproval.lineManagerRequiredError(for: payeOff, users: users), payeAdminMessage)
    }

    // MARK: (5) A demoted admin

    func testDemotedAdminNeverSelfSignsAndTheStoredValueStaysUnderneath() throws {
        var demoted = admin("TEST-DEMOTED", selfBook: true, selfSign: true, lineManagers: ["TEST-FOUNDER"])
        demoted.role = .manager
        demoted.permissions.adminAccess = false
        let users = [admin("TEST-FOUNDER"), demoted]
        XCTAssertEqual(demoted.permissionLevel, .manager)
        XCTAssertFalse(demoted.effectivePermissions.timesheetSelfSign, "admins only")
        XCTAssertTrue(demoted.permissions.timesheetSelfSign, "the stored value is kept")
        XCTAssertEqual(RulebookPeople.timesheetSelfSigned(demoted, users: users), false)
        XCTAssertTrue(AnnualLeaveSelfBookPolicy.canSelfBookAnnualLeave(for: demoted, users: users), "managers keep Annual Leave Management")
        let managerRows = CanonicalBusinessEngine.permissionToggleRows(level: .manager, user: demoted.permissionSubject, mode: .edit)
        XCTAssertEqual(managerRows.first { $0.field == "timesheetSelfSign" }?.visible, false)
        var noManager = demoted
        noManager.setLineManagerUserIds([])
        noManager.hasNoLineManager = true
        XCTAssertEqual(
            AnnualLeaveApproval.lineManagerRequiredError(for: noManager, users: users),
            CanonicalBusinessEngine.constant("LINE_MANAGER_REQUIRED_MESSAGE", as: String.self)
        )

        // The demotion's write never carries Timesheet self-sign (`keepStoredLockedPermissions`).
        let before = CanonicalBusinessEngine.permissionSubject(
            permissions: admin("TEST-DEMOTED", selfBook: true, selfSign: true).permissions,
            role: UserRole.admin.rawValue,
            isSuperAdmin: false
        )
        let next: [String: Any] = [
            "role": "manager",
            "adminAccess": false,
            "permissions.adminAccess": false,
            "timesheetSelfSign": false,
            "permissions.timesheetSelfSign": false,
        ]
        let kept = try XCTUnwrap(CanonicalBusinessEngine.keepStoredLockedPermissions(before: before, next: next))
        XCTAssertNil(kept["timesheetSelfSign"])
        XCTAssertNil(kept["permissions.timesheetSelfSign"])
        XCTAssertEqual(kept["role"] as? String, "manager")
        XCTAssertEqual(kept["adminAccess"] as? Bool, false)
    }

    // MARK: (6) Toggles on with a line manager

    func testTogglesOnWithALineManagerStillSelfApprove() {
        let managed = admin("TEST-ADMIN-LM", selfBook: true, selfSign: true, lineManagers: ["TEST-FOUNDER"])
        let users = [admin("TEST-FOUNDER"), managed]
        XCTAssertNil(AnnualLeaveApproval.lineManagerRequiredError(for: managed, users: users))
        XCTAssertTrue(AnnualLeaveSelfBookPolicy.canSelfBookAnnualLeave(for: managed, users: users))
        XCTAssertEqual(RulebookPeople.timesheetSelfSigned(managed, users: users), true)
        XCTAssertEqual(RulebookPeople.leaveSubmitLabel(managed, users: users), "Submit")

        // Toggles off with a line manager: normal approval.
        let asks = admin("TEST-ADMIN-ASKS", lineManagers: ["TEST-FOUNDER"])
        XCTAssertNil(AnnualLeaveApproval.lineManagerRequiredError(for: asks, users: users + [asks]))
        XCTAssertEqual(RulebookPeople.timesheetSelfSigned(asks, users: users + [asks]), false)
        XCTAssertEqual(RulebookPeople.leaveSubmitLabel(asks, users: users + [asks]), "Submit request")
    }

    // MARK: (7) A Super Admin of company A visiting company B

    func testVisitingSuperAdminIsNotTheSuperAdminOfCompanyB() {
        let visitor = admin("TEST-VISITOR", isSuperAdmin: true, organizationId: "TEST-ORG-A")
        let users = [admin("TEST-FOUNDER"), visitor]
        XCTAssertEqual(visitor.organizationSuperAdmin, false, "the home company's flag never counts in company B")
        XCTAssertEqual(RulebookPeople.person(visitor)["organizationSuperAdmin"] as? Bool, false)
        XCTAssertFalse(AnnualLeaveSelfBookPolicy.canSelfBookAnnualLeave(for: visitor, users: users))
        XCTAssertEqual(RulebookPeople.timesheetSelfSigned(visitor, users: users), false)
        XCTAssertEqual(AnnualLeaveApproval.lineManagerRequiredError(for: visitor, users: users), adminMessage)
        XCTAssertNil(selfManageRows(visitor)["timesheetSelfSign"]?.note)

        // A flagged Super Admin whose profile is this organisation's is one.
        let flagged = admin("TEST-FLAGGED", isSuperAdmin: true)
        XCTAssertEqual(flagged.organizationSuperAdmin, true)
        XCTAssertEqual(RulebookPeople.timesheetSelfSigned(flagged, users: [flagged]), true)
    }

    // MARK: Nobody edits their own self-manage rows

    func testTheViewersOwnSelfManageRowsAreLocked() {
        let me = admin("TEST-ME", selfBook: true, lineManagers: ["TEST-FOUNDER"])
        let rows = selfManageRows(me, viewerIsSubject: true)
        for field in ["annualLeaveSelfBook", "timesheetSelfSign"] {
            XCTAssertEqual(rows[field]?.editable, false, field)
            XCTAssertEqual(rows[field]?.note, CanonicalBusinessEngine.ownSelfManageMessage, field)
        }
        XCTAssertEqual(selfManageRows(me)["timesheetSelfSign"]?.editable, true, "another admin may change them")
    }
}
