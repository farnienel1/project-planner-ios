import XCTest
@testable import Project_Planner

/// RULEBOOK 1.24.0 on iOS through `CanonicalBusinessEngine`: Add User line-manager picks after an account-type change
/// (`lineManagerSelectionAfterLevelChange`). Expected values were checked in node against the packed
/// `canonical-business.js` (rulebook 1.24.0, sha256 c18f33c8…5eb2bd).
@MainActor
final class Rulebook1240Tests: XCTestCase {
    func testThePackedScriptIsRulebook1240OrLater() throws {
        let stamp = try XCTUnwrap(CanonicalBusinessEngine.rulebookStamp())
        let parts = stamp.version.split(separator: ".").compactMap { Int($0) }
        XCTAssertFalse(parts.lexicographicallyPrecedes([1, 24, 0]), "rulebook \(stamp.version) predates 1.24.0")
        XCTAssertTrue(CanonicalBusinessEngine.exportNames().contains("lineManagerSelectionAfterLevelChange"))
    }

    /// A pick that is still a `lineManagerCandidates` row is kept (mapped onto that row's id); an operative and an
    /// unknown id are dropped; "No line manager" stays only for an admin.
    func testAccountTypeChangeKeepsValidLineManagerPicks() {
        let admin = AppUser(
            id: "TEST-admin-1", email: "test-admin@example.test", organizationId: "TEST-org", role: .admin,
            firstName: "Ada", surname: "Admin", isActive: true, passwordSet: true, permissions: UserPermissions(adminAccess: true)
        )
        let operative = AppUser(
            id: "OP-1", email: "op@example.test", organizationId: "TEST-org", role: .operative,
            isActive: true, passwordSet: true, permissions: UserPermissions(operativeMode: true)
        )
        let draft = AppUser(
            id: "invite-draft", email: "new@example.test", organizationId: "TEST-org", role: .operative,
            permissions: UserPermissions(operativeMode: true)
        )
        let toOperative = AddUserLineManagerSelection.afterAccountTypeSelection(
            previous: .admin, next: .operative,
            lineManagerIds: ["test-admin-1", "OP-1", "ghost"], hasNoLineManager: true,
            person: draft, roster: [admin, operative]
        )
        XCTAssertEqual(toOperative.lineManagerIds, ["TEST-admin-1"], "the admin pick is kept under its roster id")
        XCTAssertFalse(toOperative.hasNoLineManager, "No line manager is dropped when the type moves off admin")

        let toAdmin = AddUserLineManagerSelection.afterAccountTypeSelection(
            previous: .manager, next: .admin, lineManagerIds: ["TEST-admin-1"], hasNoLineManager: true,
            person: draft, roster: []
        )
        XCTAssertEqual(toAdmin.lineManagerIds, [], "an id the roster does not know is dropped")
        XCTAssertTrue(toAdmin.hasNoLineManager, "an admin may keep No line manager")
    }
}
