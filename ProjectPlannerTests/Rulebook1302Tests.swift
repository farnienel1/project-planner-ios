import XCTest
@testable import Project_Planner

/// RULEBOOK 1.30.2 on iOS through `CanonicalBusinessEngine`: nobody reviews their own timesheet under any of their ids
/// (`timesheetWriterIsReviewer` with `writerAliasIds` / `roster`, `userTimesheetSubjects` never lists the viewer), and
/// the self-manage toggles are read for the open organisation (`organizationSelfManageFlags`). Every answer comes from
/// the packed script; these tests lock the Swift inputs, the same cases web's `canonical.test.ts` asserts.
@MainActor
final class Rulebook1302Tests: XCTestCase {
    private let org = "TEST-ORG-1302"
    private let home = "TEST-ORG-HOME"

    override func setUp() {
        super.setUp()
        OrganizationRulebookContext.update(
            from: Organization(firestoreDocumentId: org, name: "TEST-Company 1302", creatorUserId: "TEST-FOUNDER")
        )
        RulebookRosterSnapshot.update([])
    }

    override func tearDown() {
        RulebookRosterSnapshot.update([])
        OrganizationRulebookContext.update(from: nil)
        super.tearDown()
    }

    private func person(
        _ id: String,
        role: UserRole,
        admin: Bool = false,
        manager: Bool = false,
        operativeMode: Bool = false,
        selfSign: Bool = false,
        lineManagers: [String] = [],
        aliases: [String] = []
    ) -> AppUser {
        var user = AppUser(
            id: id,
            email: "\(id.lowercased())@example.test",
            organizationId: org,
            role: role,
            firstName: id,
            surname: "Test",
            passwordSet: true,
            permissions: UserPermissions(
                adminAccess: admin,
                manager: manager || admin,
                operativeMode: operativeMode,
                timesheetSelfSign: selfSign
            )
        )
        user.setLineManagerUserIds(lineManagers)
        user.hasNoLineManager = lineManagers.isEmpty
        user.sameEmailUserIds = aliases
        return user
    }

    // MARK: timesheetWriterIsReviewer

    func testAdminOwnSheetIsTheOwnerPath() {
        let admin = person("TEST-ADMIN", role: .admin, admin: true)
        RulebookRosterSnapshot.update([admin])
        XCTAssertEqual(
            CanonicalBusinessEngine.timesheetWriterIsReviewer(
                writerUserId: admin.id,
                subjectUserId: admin.id,
                writerIsAdmin: true,
                writerFormerIds: [],
                subjectLineManagerIds: []
            ),
            false
        )
        XCTAssertFalse(TimesheetApprovalPolicy.writerIsReviewer(
            writerId: admin.id, writer: admin, subjectUserId: admin.id, subject: admin
        ))
    }

    func testAdminIsNotReviewerOfOwnSheetUnderAliasOrRosterEmail() {
        let admin = person("TEST-ADMIN", role: .admin, admin: true, aliases: ["TEST-ADMIN-OLD"])
        XCTAssertEqual(
            CanonicalBusinessEngine.timesheetWriterIsReviewer(
                writerUserId: admin.id,
                subjectUserId: "test-admin-old",
                writerIsAdmin: true,
                writerFormerIds: [],
                writerAliasIds: admin.sameEmailUserIds,
                subjectLineManagerIds: []
            ),
            false
        )
        // A second users row on the same email, known only to the roster (`personIdSet`).
        var twin = person("TEST-ADMIN-TWIN", role: .admin, admin: true)
        twin.email = admin.email
        let roster = RulebookPeople.roster([admin, twin])
        XCTAssertEqual(
            CanonicalBusinessEngine.timesheetWriterIsReviewer(
                writerUserId: admin.id,
                subjectUserId: twin.id,
                writerIsAdmin: true,
                writerFormerIds: [],
                subjectLineManagerIds: [],
                roster: roster
            ),
            false
        )
        RulebookRosterSnapshot.update([admin, twin])
        XCTAssertFalse(TimesheetApprovalPolicy.writerIsReviewer(
            writerId: admin.id, writer: admin, subjectUserId: twin.id, subject: twin
        ))
    }

    func testAdminAndLineManagerStillReviewOthers() {
        let admin = person("TEST-ADMIN", role: .admin, admin: true)
        let manager = person("TEST-MGR", role: .manager, manager: true, lineManagers: ["TEST-ADMIN"])
        let operative = person("TEST-OP", role: .operative, operativeMode: true, lineManagers: ["TEST-MGR"])
        RulebookRosterSnapshot.update([admin, manager, operative])
        XCTAssertTrue(TimesheetApprovalPolicy.writerIsReviewer(
            writerId: admin.id, writer: admin, subjectUserId: operative.id, subject: operative
        ))
        XCTAssertTrue(TimesheetApprovalPolicy.writerIsReviewer(
            writerId: manager.id, writer: manager, subjectUserId: operative.id, subject: operative
        ))
        XCTAssertFalse(TimesheetApprovalPolicy.writerIsReviewer(
            writerId: operative.id, writer: operative, subjectUserId: operative.id, subject: operative
        ))
    }

    // MARK: Self-signed vs not (owner path)

    func testSelfSignedAdminKeepsTheSnapshotOnTheOwnerPath() {
        let selfSigned = person("TEST-ADMIN-SS", role: .admin, admin: true, selfSign: true)
        let notSelfSigned = person("TEST-ADMIN-LM", role: .admin, admin: true, lineManagers: ["TEST-ADMIN-SS"])
        RulebookRosterSnapshot.update([selfSigned, notSelfSigned])
        XCTAssertFalse(TimesheetApprovalPolicy.requiresLineManagerCounterSign(for: selfSigned))
        XCTAssertTrue(TimesheetApprovalPolicy.requiresLineManagerCounterSign(for: notSelfSigned))

        let keys = ["operativeSignedAt", "weeklyReportOverride", "payrollLineReviews", "extraEntryReviews", "managerSignedAt"]
        let selfKeep = CanonicalBusinessEngine.timesheetOwnerWritableKeys(
            keys, subjectHasLineManager: TimesheetApprovalPolicy.requiresLineManagerCounterSign(for: selfSigned), managerSigned: false
        ) ?? []
        XCTAssertTrue(selfKeep.contains("weeklyReportOverride"))
        XCTAssertTrue(selfKeep.contains("operativeSignedAt"))
        XCTAssertFalse(selfKeep.contains("managerSignedAt"))
        XCTAssertFalse(selfKeep.contains("extraEntryReviews"))

        let otherKeep = CanonicalBusinessEngine.timesheetOwnerWritableKeys(
            keys, subjectHasLineManager: TimesheetApprovalPolicy.requiresLineManagerCounterSign(for: notSelfSigned), managerSigned: false
        ) ?? []
        XCTAssertFalse(otherKeep.contains("weeklyReportOverride"))
        XCTAssertFalse(otherKeep.contains("managerSignedAt"))
        XCTAssertFalse(otherKeep.contains("payrollLineReviews"))
        XCTAssertTrue(otherKeep.contains("operativeSignedAt"))
    }

    // MARK: userTimesheetSubjects

    func testUserTimesheetSubjectsNeverListTheViewer() {
        let admin = person("TEST-ADMIN", role: .admin, admin: true, aliases: ["TEST-ADMIN-OLD"])
        var aliasRow = person("TEST-ADMIN-OLD", role: .admin, admin: true)
        aliasRow.email = admin.email
        let operative = person("TEST-OP", role: .operative, operativeMode: true, lineManagers: ["TEST-ADMIN"])
        let ids = UserTimesheetAccessRulebook.subjectUserIds(viewer: admin, members: [admin, aliasRow, operative])
        XCTAssertEqual(ids, ["TEST-OP"])
    }

    // MARK: organizationSelfManageFlags

    func testVisitingAdminTakesMembershipOnlyToggles() {
        let homeDoc: [String: Any] = [
            "organizationId": home, "role": "admin", "adminAccess": true,
            "annualLeaveSelfBook": false, "timesheetSelfSign": false
        ]
        let membership: [String: Any] = [
            "role": "admin",
            "permissions": ["adminAccess": true, "annualLeaveSelfBook": true, "timesheetSelfSign": true]
        ]
        let flags = CanonicalBusinessEngine.organizationSelfManageFlags(
            organizationId: org, userId: "TEST-VISITOR", user: homeDoc, membership: membership, creatorUserId: "TEST-FOUNDER"
        )
        XCTAssertEqual(flags?.source, "membership")
        XCTAssertEqual(flags?.annualLeaveSelfBook, true)
        XCTAssertEqual(flags?.timesheetSelfSign, true)

        var visitor = person("TEST-VISITOR", role: .admin, admin: true)
        visitor = visitor.applyingOrganizationSelfManageFlags(
            organizationId: org, userDocument: homeDoc, membership: membership, creatorUserId: "TEST-FOUNDER"
        )
        XCTAssertTrue(visitor.permissions.annualLeaveSelfBook)
        XCTAssertTrue(visitor.permissions.timesheetSelfSign)
        XCTAssertEqual(AnnualLeaveSelfBookPolicy.canSelfBookAnnualLeave(for: visitor, users: [visitor]), true)
        RulebookRosterSnapshot.update([visitor])
        XCTAssertFalse(TimesheetApprovalPolicy.requiresLineManagerCounterSign(for: visitor))
    }

    func testVisitingManagerWithHomeFlagOnlyIsOffHere() {
        let homeDoc: [String: Any] = [
            "organizationId": home, "role": "manager", "manager": true, "annualLeaveSelfBook": true
        ]
        let membership: [String: Any] = ["role": "manager", "permissions": ["manager": true]]
        let flags = CanonicalBusinessEngine.organizationSelfManageFlags(
            organizationId: org, userId: "TEST-MGR", user: homeDoc, membership: membership, creatorUserId: "TEST-FOUNDER"
        )
        XCTAssertEqual(flags?.source, "membership")
        XCTAssertEqual(flags?.annualLeaveSelfBook, false)
        XCTAssertEqual(flags?.timesheetSelfSign, false)

        // Membership not read yet: still off here, never the home flag.
        var manager = person("TEST-MGR", role: .manager, manager: true)
        manager.permissions.annualLeaveSelfBook = true
        let here = manager.applyingOrganizationSelfManageFlags(
            organizationId: org, userDocument: nil, membership: nil, creatorUserId: "TEST-FOUNDER"
        )
        XCTAssertFalse(here.permissions.annualLeaveSelfBook)
        XCTAssertEqual(AnnualLeaveSelfBookPolicy.canSelfBookAnnualLeave(for: here, users: [here]), false)
    }

    func testHomeUsersDocumentAndCreator() {
        let homeDoc: [String: Any] = [
            "organizationId": org, "role": "manager", "manager": true, "annualLeaveSelfBook": true
        ]
        let fromHome = CanonicalBusinessEngine.organizationSelfManageFlags(
            organizationId: org, userId: "TEST-MGR", user: homeDoc, membership: nil, creatorUserId: "TEST-FOUNDER"
        )
        XCTAssertEqual(fromHome?.source, "users")
        XCTAssertEqual(fromHome?.annualLeaveSelfBook, true)
        XCTAssertEqual(fromHome?.timesheetSelfSign, false)

        let creator = CanonicalBusinessEngine.organizationSelfManageFlags(
            organizationId: org, userId: "TEST-FOUNDER", user: nil, membership: nil, creatorUserId: "TEST-FOUNDER"
        )
        XCTAssertEqual(creator?.source, "creator")
        XCTAssertEqual(creator?.annualLeaveSelfBook, true)
        XCTAssertEqual(creator?.timesheetSelfSign, true)
    }
}
