import XCTest
@testable import Project_Planner

/// RULEBOOK 1.88.0 §8, §11 "Line managers per organisation" (web hand-off v1.88.0): which line manager applies in an
/// organisation (`organizationLineManagerFields`) and where an edit is saved (`orgLineManagerEditTarget`) are the
/// packed script's; these lock the Swift mapping and `OrgLineManagerOverlay`. TEST data.
@MainActor
final class OrgLineManagersTests: XCTestCase {
    private func jane(home: String? = "TEST-A") -> AppUser {
        var user = AppUser(id: "jane", email: "jane@example.test", organizationId: "TEST-B", role: .operative, permissions: UserPermissions())
        user.storedOrganizationId = home
        user.assignedManagerUserIds = ["bobA"]
        user.assignedManagerUserId = "bobA"
        return user
    }

    private let membership: [String: Any] = [
        "role": "operative",
        "updatedAt": Date(),
        "lineManager": ["assignedManagerUserIds": ["carolB"], "assignedManagerUserId": "carolB", "hasNoLineManager": false],
    ]

    func testVisitingMemberReadsTheMembershipMapAndComesOffAgain() {
        let shown = OrgLineManagerOverlay.apply([jane()], organizationId: "TEST-B", memberships: ["jane": membership])
        XCTAssertEqual(shown?.first?.assignedManagerUserIds, ["carolB"])
        XCTAssertEqual(shown.map { OrgLineManagerOverlay.accountFields($0[0]).ids }, ["bobA"])
        XCTAssertNil(OrgLineManagerOverlay.apply(shown ?? [], organizationId: "TEST-B", memberships: ["jane": membership]), "idempotent")
        let back = OrgLineManagerOverlay.apply(shown ?? [], organizationId: "TEST-B", memberships: [:])
        XCTAssertEqual(back?.first?.assignedManagerUserIds, ["bobA"])
        XCTAssertNil(back?.first?.orgLineManagerOverlay)
    }

    func testHomeAndNoMapAreUnchanged() {
        // Home company: the users document whatever the membership says.
        XCTAssertNil(OrgLineManagerOverlay.apply([jane(home: "TEST-B")], organizationId: "TEST-B", memberships: ["jane": membership]))
        // A membership with no `lineManager` map (every membership before 1.88.0, a flat legacy copy): as before.
        let flat: [String: Any] = ["role": "operative", "assignedManagerUserIds": ["old"]]
        XCTAssertNil(OrgLineManagerOverlay.apply([jane()], organizationId: "TEST-B", memberships: ["jane": flat]))
    }

    func testEditTarget() {
        XCTAssertEqual(CanonicalBusinessEngine.orgLineManagerEditTarget(organizationId: "TEST-A", homeOrganizationId: "test-a"), "users")
        XCTAssertEqual(CanonicalBusinessEngine.orgLineManagerEditTarget(organizationId: "TEST-B", homeOrganizationId: "TEST-A"), "membership")
        XCTAssertNil(CanonicalBusinessEngine.orgLineManagerEditTarget(organizationId: "TEST-B", homeOrganizationId: nil))
    }

    func testLineManagerIdsFollowTheOrganisation() {
        let fields = CanonicalBusinessEngine.organizationLineManagerFields(
            organizationId: "TEST-B",
            homeOrganizationId: "TEST-A",
            assignedManagerUserIds: ["bobA"],
            assignedManagerUserId: "bobA",
            hasNoLineManager: false,
            membership: membership
        )
        XCTAssertEqual(fields?.source, "membership")
        XCTAssertEqual(fields?.ids, ["carolB"])
    }

    /// Owner bug 24 Nov: the profile summary and the Edit user picker read the same line manager (list only, no legacy
    /// single id; "No line manager" stored beside ids wins on both).
    func testSummaryAndPickerAgree() {
        var manager = AppUser(id: "farnie", email: "farnienelyt@gmail.com", organizationId: "TEST-B", role: .manager, firstName: "Farnie", surname: "Nel", passwordSet: true)
        manager.permissions.manager = true
        let roster = [manager]
        var luke = AppUser(id: "luke", email: "farnienel@hotmail.com", organizationId: "TEST-B", role: .operative, passwordSet: true, assignedManagerUserIds: ["farnie"])
        luke.assignedManagerUserId = nil
        XCTAssertEqual(LineManagerRulebook.summary(for: luke, roster: roster), "Farnie Nel")
        XCTAssertEqual(LineManagerRulebook.selectedIds(for: luke, roster: roster), ["farnie"])
        luke.hasNoLineManager = true
        XCTAssertEqual(LineManagerRulebook.summary(for: luke, roster: roster), "No line manager")
        XCTAssertEqual(LineManagerRulebook.selectedIds(for: luke, roster: roster), [])
    }
}
