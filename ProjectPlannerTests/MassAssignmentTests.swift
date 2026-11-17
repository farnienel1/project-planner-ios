import XCTest
@testable import Project_Planner

/// Mass-assignment audit 17 Nov (owner approved): a person never writes their own privileges, pay or line manager when
/// their users document is created from this device; only the organisation's creator re-creates their own Super Admin
/// profile; an invite placeholder never carries `isSuperAdmin`; every invitation write is checked against a known
/// inviter.
@MainActor
final class MassAssignmentTests: XCTestCase {
    private func privilegedProfile(id: String, passwordSet: Bool = true) -> AppUser {
        AppUser(
            id: id,
            email: "test-person@example.com",
            organizationId: "TEST-ORG-MA",
            role: .admin,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            firstName: "TEST-P",
            surname: "Person",
            isActive: true,
            passwordSet: passwordSet,
            permissions: UserPermissions(
                adminAccess: true,
                operatives: true,
                skills: false,
                qualifications: true,
                materials: true,
                projects: true,
                smallWorks: true
            ),
            isSuperAdmin: true,
            policyAccepted: true,
            policyAcceptedAt: nil
        )
    }

    /// Keys that must never reach a person's own new users document unless they are the organisation's creator.
    private let privilegeKeys = [
        "role", "isSuperAdmin", "adminAccess", "manager", "operatives", "operativeMode", "annualLeaveSelfBook",
        "timesheetSelfSign", "permissions", "passwordSet", "isActive", "payBasis", "dayRate", "hourlyRate",
        "employmentType", "employmentTypeTransitionFrom", "employmentTypeEffectiveAt", "assignedManagerUserId",
        "assignedManagerUserIds", "hasNoLineManager", "organizationId", "formerUserIds", "sameEmailUserIds",
        "ghost", "inviteEmailHint",
    ]

    func testOwnProfileCreateByAnyoneButTheCreatorCarriesOnlyAllowlistedKeys() {
        var user = privilegedProfile(id: "TEST-UID-1")
        user.dayRate = 250
        user.assignedManagerUserIds = ["TEST-LM-1"]
        let payload = FirebaseBackend.userDocumentPayload(user)
        let create = FirebaseBackend.userCreatePayload(
            payload, userId: "TEST-UID-1", signedInUid: "TEST-UID-1", isOrganizationCreator: false, passwordSet: true
        )
        XCTAssertFalse(create.isEmpty)
        for key in create.keys {
            XCTAssertTrue(FirebaseBackend.ownProfileCreateAllowedFields.contains(key), "\(key) is not allow-listed")
        }
        for key in privilegeKeys {
            XCTAssertNil(create[key], "\(key) must not be self-written")
        }
        XCTAssertEqual(create["email"] as? String, "test-person@example.com")
        XCTAssertEqual(create["firstName"] as? String, "TEST-P")
    }

    func testTheCreatorReCreatesTheirOwnSuperAdminProfileWithoutGhostMarkers() {
        let payload = FirebaseBackend.userDocumentPayload(privilegedProfile(id: "TEST-CREATOR"))
        let create = FirebaseBackend.userCreatePayload(
            payload, userId: "TEST-CREATOR", signedInUid: "TEST-CREATOR", isOrganizationCreator: true, passwordSet: true
        )
        XCTAssertEqual(create["isSuperAdmin"] as? Bool, true)
        XCTAssertEqual(create["role"] as? String, UserRole.admin.rawValue)
        XCTAssertNil(create["ghost"])
        XCTAssertNil(create["inviteEmailHint"])
        XCTAssertFalse(create.values.contains { $0 is FieldValue }, "a create never sends delete sentinels")
    }

    func testAnInvitePlaceholderNeverCarriesIsSuperAdmin() {
        var placeholder = privilegedProfile(id: "TEST-PLACEHOLDER", passwordSet: false)
        placeholder.isSuperAdmin = false
        let payload = FirebaseBackend.userDocumentPayload(placeholder)
        let create = FirebaseBackend.userCreatePayload(
            payload, userId: "TEST-PLACEHOLDER", signedInUid: "TEST-ADMIN", isOrganizationCreator: false, passwordSet: false
        )
        XCTAssertNil(create["isSuperAdmin"])
        XCTAssertEqual(create["organizationId"] as? String, "TEST-ORG-MA", "someone else's document keeps the fields the rules check")
        // Even a stray `true` on a placeholder (never signed up) is dropped.
        let stray = FirebaseBackend.userCreatePayload(
            ["isSuperAdmin": true, "email": "x@example.com"], userId: "TEST-PLACEHOLDER", signedInUid: "TEST-ADMIN",
            isOrganizationCreator: false, passwordSet: false
        )
        XCTAssertNil(stray["isSuperAdmin"])
    }

    func testOnlyTheOrganisationCreatorMayRecreateTheirOwnProfile() {
        XCTAssertTrue(UserStore.mayRecreateOwnProfileAsSuperAdmin(uid: "abcUID", organizationCreatorUserId: "abcUID"))
        XCTAssertFalse(UserStore.mayRecreateOwnProfileAsSuperAdmin(uid: "abcUID", organizationCreatorUserId: "ABCUID"), "uids are case-sensitive")
        XCTAssertFalse(UserStore.mayRecreateOwnProfileAsSuperAdmin(uid: "abcUID", organizationCreatorUserId: nil))
        XCTAssertFalse(UserStore.mayRecreateOwnProfileAsSuperAdmin(uid: "abcUID", organizationCreatorUserId: ""))
        XCTAssertFalse(UserStore.mayRecreateOwnProfileAsSuperAdmin(uid: "", organizationCreatorUserId: ""))
        XCTAssertFalse(UserStore.mayRecreateOwnProfileAsSuperAdmin(uid: "someone", organizationCreatorUserId: "abcUID"))
    }

    func testEveryInvitationWriteIsCheckedAgainstAKnownInviter() throws {
        let managerInvite: [String: Any] = [
            "email": "test-new@example.com",
            "organizationId": "TEST-ORG-MA",
            "invitedBy": "test-inviter@example.com",
            "permissions": ["manager": true, "adminAccess": false, "operatives": false, "operativeMode": false],
            "isUsed": false,
        ]
        XCTAssertThrowsError(try InvitationDocument.checkedCreateFields(from: managerInvite, inviterIsAdmin: false))
        XCTAssertNoThrow(try InvitationDocument.checkedCreateFields(from: managerInvite, inviterIsAdmin: true))
        var operativeInvite = managerInvite
        operativeInvite["permissions"] = ["manager": false, "adminAccess": false, "operatives": false, "operativeMode": true]
        XCTAssertNoThrow(try InvitationDocument.checkedCreateFields(from: operativeInvite, inviterIsAdmin: false))
    }
}
