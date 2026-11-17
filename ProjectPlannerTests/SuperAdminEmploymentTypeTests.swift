import XCTest
@testable import Project_Planner

/// 17 Nov owner bug: the Super Admin could never be set to PAYE. Web Edit User hid Employment type and the annual leave
/// allowance for every Super Admin; on iPhone the Employment type menu showed, but `UserStore.updateUserEmploymentType`
/// refused every Super Admin (and the organisation creator) without a message, and Edit user hid the annual leave
/// allowance sections for the Super Admin (and the allowance fields for every admin). The rulebook hides neither for
/// any level (§4.4, §8): who may change pay is `canChangePersonPay`, and only the Super Admin edits their own profile
/// (`canEditTargetUserPermissions`). These tests keep it that way.
@MainActor
final class SuperAdminEmploymentTypeTests: XCTestCase {
    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    }

    private func source(_ path: String) throws -> String {
        try String(contentsOf: repoRoot.appendingPathComponent(path), encoding: .utf8)
    }

    /// The text of a declaration from its marker to its closing brace.
    private func body(_ text: String, marker: String) throws -> String {
        let start = try XCTUnwrap(text.range(of: marker), "missing \(marker)")
        var depth = 0
        var seenOpen = false
        var index = start.lowerBound
        while index < text.endIndex {
            let ch = text[index]
            if ch == "{" { depth += 1; seenOpen = true }
            if ch == "}" { depth -= 1 }
            index = text.index(after: index)
            if seenOpen && depth == 0 { break }
        }
        return String(text[start.lowerBound..<index])
    }

    func testTheSuperAdminMayChangeTheirOwnPayAndEmploymentType() {
        // §8: an admin may change pay, including their own (the Super Admin is an admin).
        XCTAssertTrue(CanonicalBusinessEngine.canChangePersonPay(
            writerUserId: "super-1", writerIsPlatformOwner: false, writerIsAdmin: true, writerIsManager: false,
            writerHasOperativesAccess: false, writerIsOperativeMode: false,
            subjectUserId: "super-1", subjectIsOperative: false
        ))
        // Unchanged: an operative never changes their own.
        XCTAssertFalse(CanonicalBusinessEngine.canChangePersonPay(
            writerUserId: "op-1", writerIsPlatformOwner: false, writerIsAdmin: false, writerIsManager: false,
            writerHasOperativesAccess: false, writerIsOperativeMode: true,
            subjectUserId: "op-1", subjectIsOperative: true
        ))
    }

    func testDataHealthListsASuperAdminWithNoStoredEmploymentType() {
        let roster: [[String: Any]] = [
            ["id": "super-1", "email": "super@example.com", "isSuperAdmin": true, "role": "admin", "isActive": true],
            ["id": "admin-1", "email": "admin@example.com", "role": "admin", "employmentType": "paye", "isActive": true],
            ["id": "op-1", "email": "op@example.com", "role": "operative", "employmentType": "self_employed", "isActive": true],
        ]
        let ids = CanonicalBusinessEngine.callJSON("usersMissingEmploymentType", arguments: [roster]) as? [String]
        XCTAssertEqual(ids, ["super-1"])
    }

    /// Edit user shows the annual leave allowance for every level: operative, manager, admin and the Super Admin.
    func testEditUserShowsTheLeaveAllowanceForEveryLevel() throws {
        let text = try source("Project Planner/Views/ManageUsersView.swift")
        for marker in [
            "private var shouldShowAnnualLeaveAccessToggle: Bool {",
            "private var shouldShowAnnualLeaveEntitlementSection: Bool {",
        ] {
            let decl = try body(text, marker: marker)
            XCTAssertFalse(decl.contains("if isViewingSuperAdminProfile { return false }"), "\(marker) must not hide the Super Admin")
            XCTAssertFalse(decl.contains("isSuperAdmin {"), "\(marker) must not hide the Super Admin")
            for level in ["permissions.operativeMode", "permissions.manager", "permissions.adminAccess", "isViewingSuperAdminProfile"] {
                XCTAssertTrue(decl.contains(level), "\(marker) must show for \(level)")
            }
        }
    }

    /// Edit user's Employment type row is decided by `canViewPay` / `canChangePay` only — never by the Super Admin flag.
    func testEditUserEmploymentTypeRowIsNotHiddenForTheSuperAdmin() throws {
        let text = try source("Project Planner/Views/ManageUsersView.swift")
        let start = try XCTUnwrap(text.range(of: "if isGhostProfile || !userStore.canViewPay(of: displayedUser, context: .profile) {"))
        let row = String(text[start.lowerBound...].prefix(1_600))
        XCTAssertTrue(row.contains("label: \"Employment type\""))
        XCTAssertFalse(row.contains("isSuperAdmin"))
        XCTAssertFalse(row.contains("isViewingSuperAdminProfile"))
    }

    /// The saves never refuse the Super Admin's own employment type or leave allowance.
    func testUserStoreSavesDoNotRefuseTheSuperAdmin() throws {
        let text = try source("Project Planner/Core/UserStore.swift")
        for marker in [
            "func updateUserEmploymentType(userId: String, employmentType: EmploymentType, effectiveAt: Date? = nil) async -> Bool {",
            "func updateUserAnnualLeaveEntitlement(",
            "func updateUserAnnualLeaveEnabled(userId: String, enabled: Bool) async -> Bool {",
        ] {
            let decl = try body(text, marker: marker)
            XCTAssertFalse(decl.contains("if isOrganizationCreator(userId: userId) { return false }"), marker)
            let collapsed = decl.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            XCTAssertFalse(
                collapsed.contains("if updated.isSuperAdmin || isOrganizationCreator(userId: updated.id) { return false }"),
                "\(marker) must not refuse every Super Admin"
            )
            XCTAssertTrue(collapsed.contains("!canEditTargetUserPermissions(updated)"), "\(marker) keeps the Super Admin's profile to the Super Admin")
        }
    }
}
