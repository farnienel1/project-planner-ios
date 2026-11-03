import XCTest
@testable import Project_Planner

/// The signed-in super admin vanished from Manage Users and from another manager's line-manager picker, and that
/// manager's row read "Manager +-1 more". These lock the app-side pieces of the fix.
@MainActor
final class RosterSelfAndCreatorTests: XCTestCase {
    private let orgA = "org-a"

    private func superAdmin(organizationId: String) -> AppUser {
        AppUser(
            id: "SUPER-UID",
            email: "owner@example.com",
            organizationId: organizationId,
            role: .admin,
            firstName: "Olive",
            surname: "Owner",
            isActive: true,
            passwordSet: true,
            permissions: UserPermissions(adminAccess: true, manager: true),
            isSuperAdmin: true
        )
    }

    private func manager(id: String = "MGR-1", lineManagers: [String] = []) -> AppUser {
        AppUser(
            id: id,
            email: "\(id.lowercased())@example.com",
            organizationId: orgA,
            role: .manager,
            firstName: "Mo",
            surname: "Manager",
            isActive: true,
            passwordSet: true,
            permissions: UserPermissions(manager: true),
            assignedManagerUserId: lineManagers.first,
            assignedManagerUserIds: lineManagers
        )
    }

    // MARK: Point reads

    func testTheCreatorAndSignedInAccountAreReadWhateverOrganizationIdTheirDocumentHolds() {
        let ids = LaunchStartupPolicy.pointReadUserIds(
            alreadyLoaded: ["MGR-1"],
            memberUserIds: ["MGR-1"],
            claimUserIds: [],
            explicitLinkUserIds: [],
            directoryDocumentIds: [],
            anchorUserIds: ["SUPER-UID"]
        )
        XCTAssertEqual(ids, ["SUPER-UID"], "the users query on organizationId == org-a never returns a document naming org-b")
    }

    func testAnAnchoredPersonIsNotDroppedByADeniedRead() {
        XCTAssertEqual(LaunchStartupPolicy.rosterAbsenceDecision(.permissionDenied, anchored: true), .keep)
        XCTAssertEqual(LaunchStartupPolicy.rosterAbsenceDecision(.confirmedMissing, anchored: true), .drop)
        XCTAssertEqual(LaunchStartupPolicy.rosterAbsenceDecision(.permissionDenied, anchored: false), .drop)
        XCTAssertEqual(LaunchStartupPolicy.rosterAbsenceDecision(.unconfirmed, anchored: false), .keep)
    }

    // MARK: Live listener

    func testALiveSnapshotThatOmitsTheSuperAdminDoesNotRemoveThem() {
        // The full load found the super admin through the members map; their document names org-b.
        let onScreen = [superAdmin(organizationId: "org-b"), manager()]
        var renamed = manager()
        renamed.firstName = "Morgan"
        let merged = UserStore.liveRosterMerge(onScreen: onScreen, changed: [renamed], isTombstoned: { _ in false })
        XCTAssertEqual(merged.map(\.id), ["SUPER-UID", "MGR-1"])
        XCTAssertEqual(merged.last?.firstName, "Morgan")
    }

    func testALiveSnapshotAddsNewPeopleAndKeepsAReadRowOverAnUnreadOne() {
        var unread = manager()
        unread.role = .viewer
        unread.parsedWithoutRulebook = true
        let newcomer = manager(id: "MGR-2")
        let merged = UserStore.liveRosterMerge(
            onScreen: [superAdmin(organizationId: orgA), manager()],
            changed: [unread, newcomer],
            isTombstoned: { _ in false }
        )
        XCTAssertEqual(merged.map(\.id), ["SUPER-UID", "MGR-1", "MGR-2"])
        XCTAssertEqual(merged[1].role, .manager)
    }

    // MARK: Organisation context

    func testTheRosterLoadsTheOpenOrganisationNotTheProfilesLastCompany() {
        XCTAssertEqual(UserStore.rosterOrganizationId(openOrganizationId: orgA, profileOrganizationId: "org-b"), orgA)
        XCTAssertEqual(UserStore.rosterOrganizationId(openOrganizationId: nil, profileOrganizationId: "org-b"), "org-b")
        XCTAssertEqual(UserStore.rosterOrganizationId(openOrganizationId: "  ", profileOrganizationId: "org-b"), "org-b")
    }

    // MARK: Tombstones

    func testABurialLeftByAnOlderBuildIsLiftedForTheSignedInAccount() {
        let org = "test-roster-self-\(UUID().uuidString)"
        RosterRetention.tombstone(["SUPER-UID", "GONE"], organizationId: org)
        XCTAssertTrue(RosterRetention.isTombstoned("SUPER-UID", organizationId: org))
        RosterRetention.untombstone(["SUPER-UID", ""], organizationId: org)
        XCTAssertFalse(RosterRetention.isTombstoned("SUPER-UID", organizationId: org))
        XCTAssertTrue(RosterRetention.isTombstoned("GONE", organizationId: org), "an in-app delete stays buried")
        RosterRetention.untombstone(["GONE"], organizationId: org)
    }

    // MARK: Line-manager label

    func testALineManagerIdThatResolvesToNobodyIsUnknownPersonNotMinusOne() {
        let label = LineManagerSummaryLabel.text(selectedIds: ["SUPER-UID"], roster: [manager()], hasNoLineManager: false)
        XCTAssertEqual(label, "Unknown person")
        XCTAssertFalse(label.contains("-1"))
    }

    func testLineManagerLabelNamesEveryoneAndCountsTheRest() {
        let roster = [superAdmin(organizationId: orgA), manager()]
        XCTAssertEqual(
            LineManagerSummaryLabel.text(selectedIds: ["SUPER-UID"], roster: roster, hasNoLineManager: false),
            "Olive Owner"
        )
        XCTAssertEqual(
            LineManagerSummaryLabel.text(selectedIds: ["super-uid", "MGR-1"], roster: roster, hasNoLineManager: false),
            "Mo Manager +1 more",
            "ids compare without case"
        )
        XCTAssertEqual(
            LineManagerSummaryLabel.text(selectedIds: ["MGR-1", "MISSING"], roster: roster, hasNoLineManager: false),
            "Mo Manager +1 more"
        )
        XCTAssertEqual(
            LineManagerSummaryLabel.text(selectedIds: ["A", "B"], roster: [], hasNoLineManager: false),
            "Unknown person +1 more"
        )
        XCTAssertEqual(LineManagerSummaryLabel.text(selectedIds: [], roster: roster, hasNoLineManager: false), "Select manager(s)…")
        XCTAssertEqual(LineManagerSummaryLabel.text(selectedIds: ["MGR-1"], roster: roster, hasNoLineManager: true), "No line manager")
    }
}
