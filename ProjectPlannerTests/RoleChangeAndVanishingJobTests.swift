import XCTest
@testable import Project_Planner

/// Two owner reports:
/// 1. A live project created on web long ago vanished from iOS while web still listed it.
/// 2. A manager changed to admin showed as admin, then as manager again on the next visit.
@MainActor
final class RoleChangeAndVanishingJobTests: XCTestCase {
    // MARK: - Bug 1: vanishing project

    func testAProjectsDocumentTypedSmallWorksIsStillAProject() throws {
        let job = try XCTUnwrap(FirebaseBackend.jobs(
            fromDocuments: [(id: "legacy-web-job", data: ["siteName": "Old web job", "jobType": "Small Works", "isLive": true])],
            smallWorks: false
        ).first)
        XCTAssertNotEqual(job.jobType, .smallWorks, "the projects load and listener dropped this job and the small works listener never had it")
        XCTAssertEqual(job.jobType, .catA)
        XCTAssertEqual(job.documentId, "legacy-web-job", "saved back to its own projects document")
        // The projects listener keeps only rows of its own slice.
        let kept = [job].filter { ($0.jobType == .smallWorks) == false }
        XCTAssertEqual(kept.count, 1)
    }

    func testAProjectAndASmallWorkSharingAnIdKeepTheProjectWhateverTheOrder() throws {
        let sharedId = "6F1C2B3A-1111-4222-8333-444455556666"
        let project = try XCTUnwrap(FirebaseBackend.jobs(
            fromDocuments: [(id: sharedId, data: ["siteName": "Live job", "jobType": "CAT A"])],
            smallWorks: false
        ).first)
        let smallWork = try XCTUnwrap(FirebaseBackend.jobs(
            fromDocuments: [(id: sharedId.lowercased(), data: ["siteName": "Live job", "jobType": "CAT A"])],
            smallWorks: true
        ).first)
        XCTAssertEqual(project.id, smallWork.id, "older builds re-saved the small work into projects under the same id")

        // The projects listener used to pass small works first, the small works listener projects first.
        for input in [[smallWork, project], [project, smallWork]] {
            let unique = ProjectWorksMerge.uniqueWorks(input)
            XCTAssertEqual(unique.count, 1)
            XCTAssertNotEqual(unique.first?.jobType, .smallWorks, "the job stays on Projects, as web keeps the project (`workDocuments`)")
        }
    }

    // MARK: - Bug 2: role change

    private func managerDocument() -> [String: Any] {
        [
            "email": "sam@example.com",
            "firstName": "Sam",
            "surname": "Lee",
            "organizationId": "org-1",
            "role": "manager",
            "manager": true,
            "adminAccess": false,
            "permissions": ["manager": true, "adminAccess": false],
            "passwordSet": true,
            "isActive": true,
        ]
    }

    func testThePromotionPatchReadsBackAsAdmin() {
        var stored = managerDocument()
        // What `patchChangedUserPermissions` writes for manager -> administrator (top level and nested).
        stored["role"] = "admin"
        stored["adminAccess"] = true
        stored["permissions"] = ["manager": true, "adminAccess": true]
        let user = FirebaseBackend.parseAppUserDocument(userId: "u-sam", data: stored)
        XCTAssertEqual(user.role, .admin)
        XCTAssertTrue(user.permissions.adminAccess)
        let expected = UserRoleTransitionPolicy.permissions(for: .administrator, carryingFrom: user.permissions, manager: nil, operative: nil)
        XCTAssertTrue(UserTypeChangeReadBack.landed(expectedRole: .admin, expected: expected, stored: user))
    }

    func testAPromotionTheServerDidNotKeepIsReported() {
        let unchanged = FirebaseBackend.parseAppUserDocument(userId: "u-sam", data: managerDocument())
        let expected = UserRoleTransitionPolicy.permissions(for: .administrator, carryingFrom: unchanged.permissions, manager: nil, operative: nil)
        XCTAssertFalse(UserTypeChangeReadBack.landed(expectedRole: .admin, expected: expected, stored: unchanged),
                       "the screen must show manager and an error, never the admin it asked for")
        XCTAssertTrue(UserTypeChangeReadBack.notSavedMessage(stored: unchanged).contains("Manager"))
    }

    // MARK: - Change user type: the person is found under any of their ids (owner test, 4 Nov)

    private func signedInDocument(id: String, role: UserRole, updatedAt: Date) -> AppUser {
        var user = AppUser(
            id: id,
            email: "test-promote@example.com",
            organizationId: "org-test",
            role: role,
            firstName: "TEST",
            surname: "Promote",
            isActive: true,
            passwordSet: true,
            permissions: role == .admin ? UserPermissions(adminAccess: true, manager: true) : UserPermissions(manager: true)
        )
        user.documentUpdatedAt = updatedAt
        return user
    }

    /// Manager -> admin writes every same-email document. Afterwards the `rosterPeople` fold can keep the other
    /// document, so the id the editor opened is no longer a row id. Before the fix every later lookup by that id said
    /// "This person is not in the loaded user list" although the change had landed.
    func testAfterAPromotionTheFoldMayKeepTheOtherDocumentAndThePersonIsStillFound() {
        let opened = "TEST-UID-A"
        let other = "TEST-UID-B"
        let now = Date()
        let before = FirebaseBackend.foldRosterBySameEmail([
            signedInDocument(id: opened, role: .manager, updatedAt: now),
            signedInDocument(id: other, role: .manager, updatedAt: now.addingTimeInterval(-3_600)),
        ])
        XCTAssertEqual(before.users.map(\.id), [opened], "the newer document is the row the editor opens")

        // The type change wrote both documents; the other one was written last.
        let after = FirebaseBackend.foldRosterBySameEmail([
            signedInDocument(id: opened, role: .admin, updatedAt: now.addingTimeInterval(1)),
            signedInDocument(id: other, role: .admin, updatedAt: now.addingTimeInterval(2)),
        ])
        XCTAssertNil(after.users.firstIndex(where: { $0.id == opened }),
                     "reproduces the owner bug: an exact-id lookup misses the person after the fold re-keys them")
        let index = UserStore.rosterIndex(for: opened, in: after.users, aliases: after.aliases)
        XCTAssertNotNil(index)
        XCTAssertEqual(index.map { after.users[$0].role }, .admin)
        XCTAssertEqual(UserStore.rosterIndex(for: opened.lowercased(), in: after.users, aliases: after.aliases), index)
        XCTAssertNil(UserStore.rosterIndex(for: "TEST-UID-NOBODY", in: after.users, aliases: after.aliases))
    }

    /// The plan is built for the id the members map knows, so `members.{uid}` is not added under a second id.
    func testTheTypeChangeIsWrittenForTheIdTheMembersMapKnows() {
        var row = signedInDocument(id: "TEST-UID-B", role: .manager, updatedAt: Date())
        row.sameEmailUserIds = ["TEST-UID-A"]
        XCTAssertEqual(UserStore.membersKeyId(for: row, members: ["test-uid-a": "manager"]), "TEST-UID-A")
        XCTAssertEqual(UserStore.membersKeyId(for: row, members: ["TEST-UID-B": "manager"]), "TEST-UID-B")
        XCTAssertEqual(UserStore.membersKeyId(for: row, members: nil), "TEST-UID-B")
        XCTAssertEqual(UserStore.membersKeyId(for: row, members: ["someone-else": "admin"]), "TEST-UID-B")
    }

    func testAnEditorOpenedFromAnOlderRowNeverWritesItsFlagsBack() {
        let olderManager = UserPermissions(adminAccess: false, manager: true, operatives: true, weeklyReports: false)
        let storedAdmin = UserPermissions(adminAccess: true, manager: true, operatives: true, weeklyReports: true)

        // Nothing changed on screen: the stored admin flags stay as they are.
        XCTAssertEqual(
            UserPermissionsDraftMerge.applyingEdits(from: olderManager, to: olderManager, onto: storedAdmin),
            storedAdmin,
            "the old full-draft save sent adminAccess false over the promotion"
        )

        // One toggle changed on screen: only that flag moves.
        var edited = olderManager
        edited.subContractors = true
        let merged = UserPermissionsDraftMerge.applyingEdits(from: olderManager, to: edited, onto: storedAdmin)
        XCTAssertTrue(merged.adminAccess)
        XCTAssertTrue(merged.weeklyReports)
        XCTAssertTrue(merged.subContractors)
    }

    func testEveryPermissionFlagIsCoveredByTheDraftMerge() {
        // A flag missing from the list would silently never save from Edit User.
        let all = UserPermissions(
            adminAccess: true, manager: true, operatives: true, skills: true, qualifications: true, materials: true,
            projects: true, smallWorks: true, operativeMode: true, annualLeaveSelfBook: true, weeklyReports: true,
            dailyOverview: true, subContractors: true, siteAudit: true, wholesalersOrderHistory: true
        )
        let none = UserPermissions(
            adminAccess: false, manager: false, operatives: false, skills: false, qualifications: false, materials: false,
            projects: false, smallWorks: false, operativeMode: false, annualLeaveSelfBook: false, weeklyReports: false,
            dailyOverview: false, subContractors: false, siteAudit: false, wholesalersOrderHistory: false
        )
        XCTAssertEqual(UserPermissionsDraftMerge.applyingEdits(from: none, to: all, onto: none), all)
    }
}
