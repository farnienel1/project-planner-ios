import XCTest
@testable import Project_Planner

/// RULEBOOK 1.33.0 on iOS through `CanonicalBusinessEngine` (the "access" half of the 1.33 iOS work): Daily Overview
/// and Home team scope (§6, §23), My Projects / My Small works (§21), the line manager lock (§11), the Materials
/// catalogue gate (§16) and `userActiveWrites` with the person's own company (§11). Every expected value was checked in
/// node against the packed `canonical-business.js` 1.33.0 (sha256 59556c57…3326b8e24) with the JSON these wrappers
/// send.
@MainActor
final class Rulebook1330AccessTests: XCTestCase {
    private typealias Role = CanonicalBusinessEngine.CanonicalStaffAccountRole

    private func viewer(_ role: Role, uid: String) -> JobAccessViewer {
        JobAccessViewer(role: role, projectsToggle: false, smallWorksToggle: false, uid: uid, ids: [uid], email: "\(uid.lowercased())@x.t")
    }

    private var managerRole: Role { Role(isSuperAdmin: false, isAdmin: false, isManager: true, isOperativeMode: false) }
    private var adminRole: Role { Role(isSuperAdmin: false, isAdmin: true, isManager: false, isOperativeMode: false) }
    private var operativeRole: Role { Role(isSuperAdmin: false, isAdmin: false, isManager: false, isOperativeMode: true) }

    // MARK: Daily Overview and Home team scope (§6, §23)

    private let scopeRoster: [[String: Any]] = [
        ["id": "MGR", "email": "mgr@x.t", "isActive": true, "role": ["isManager": true]],
        ["id": "REP", "email": "rep@x.t", "isActive": true, "assignedManagerUserIds": ["MGR"]],
        ["id": "OTHER", "email": "other@x.t", "isActive": true, "assignedManagerUserIds": ["BOSS"]],
    ]
    private let scopeOperatives: [[String: Any]] = [
        ["id": "OP-REP", "email": "rep@x.t"],
        ["id": "OP-OTHER", "email": "other@x.t"],
    ]

    func testAManagersDailyOverviewIsThemselvesAndTheirReports() {
        let scope = CanonicalBusinessEngine.dailyOverviewScopeFor(
            viewer: viewer(managerRole, uid: "MGR"), roster: scopeRoster, people: [], operatives: scopeOperatives
        )
        XCTAssertEqual(scope["kind"] as? String, "jobs")
        XCTAssertEqual(scope["jobIds"] as? [String], [], "no job part (owner decision 5 Nov, Q-D1)")
        XCTAssertEqual(Set(scope["personIds"] as? [String] ?? []), ["mgr", "rep", "op-rep"])
        XCTAssertTrue(CanonicalBusinessEngine.isDailyOverviewRowInScope(scope, personIds: ["OP-REP"], email: nil))
        XCTAssertFalse(CanonicalBusinessEngine.isDailyOverviewRowInScope(scope, personIds: ["OP-OTHER"], email: nil),
                       "a non-report booked on their job is not shown")
        XCTAssertTrue(CanonicalBusinessEngine.isDailyOverviewRowInScope(scope, personIds: ["x"], email: "rep@x.t"), "on the report's email")
        XCTAssertTrue(CanonicalBusinessEngine.isDailyOverviewRowInScope(scope, personIds: ["mgr"], email: nil), "themselves, any case")
        XCTAssertFalse(CanonicalBusinessEngine.isDailyOverviewRowInScope(scope, personIds: [], email: nil, subcontractor: true),
                       "subcontractor bookings are for admins only")
    }

    func testAnAdminSeesEveryoneAndEverySubcontractor() {
        let scope = CanonicalBusinessEngine.dailyOverviewScopeFor(
            viewer: viewer(adminRole, uid: "ADM"), roster: scopeRoster, people: [], operatives: scopeOperatives
        )
        XCTAssertEqual(scope["kind"] as? String, "all")
        XCTAssertTrue(CanonicalBusinessEngine.isDailyOverviewRowInScope(scope, personIds: [], email: nil, subcontractor: true))
        XCTAssertTrue(CanonicalBusinessEngine.isDailyOverviewRowInScope(nil, personIds: ["anyone"], email: nil), "no scope keeps every row")
        let operative = CanonicalBusinessEngine.dailyOverviewScopeFor(
            viewer: viewer(operativeRole, uid: "OP"), roster: scopeRoster, people: [], operatives: scopeOperatives
        )
        XCTAssertEqual(operative["personIds"] as? [String], [], "an operative's Daily Overview covers nobody")
    }

    func testHomeOnSiteFiguresFollowTheDailyOverviewScope() throws {
        let now = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-11-04T10:00:00Z"))
        var input: [String: Any] = [
            "nowMs": (now.timeIntervalSince1970 * 1000).rounded(),
            "timeZone": "Europe/London",
            "viewer": ["id": "MGR", "email": "mgr@x.t"],
            "roster": [],
            "operatives": [
                ["id": "OP-REP", "email": "rep@x.t", "isActive": true],
                ["id": "OP-OTHER", "email": "other@x.t", "isActive": true],
            ],
            "managers": [],
            "tasks": [],
            "bookings": [
                ["operativeId": "OP-REP", "dayKey": "2026-11-04", "status": "Confirmed"],
                ["operativeId": "OP-OTHER", "dayKey": "2026-11-04", "status": "Confirmed"],
            ],
            "managerSiteBookings": [],
            "holidays": [],
            "nonWorkingDayKeys": [],
        ]
        let everyone = try XCTUnwrap(CanonicalBusinessEngine.homeOverviewMetrics(input))
        XCTAssertEqual(everyone.peopleOnSiteToday, 2)
        input["scope"] = CanonicalBusinessEngine.dailyOverviewScopeFor(
            viewer: viewer(managerRole, uid: "MGR"), roster: scopeRoster, people: [], operatives: scopeOperatives
        )
        let team = try XCTUnwrap(CanonicalBusinessEngine.homeOverviewMetrics(input))
        XCTAssertEqual(team.peopleOnSiteToday, 1, "a manager's Home counts their own team, like their Daily Overview")
        XCTAssertEqual(team.operativesOnSiteToday, 1)
    }

    // MARK: My Projects / My Small works (§21)

    private func job(_ id: String, smallWorks: Bool = false, _ data: [String: Any]) throws -> Project {
        try XCTUnwrap(FirebaseBackend.jobs(fromDocuments: [(id: id, data: data)], smallWorks: smallWorks).first)
    }

    private func myJobs() throws -> [Project] {
        [
            try job("P1", ["managerUserIds": ["U-M"]]),
            try job("P2", ["managerUserIds": ["X"]]),
            try job("S1", smallWorks: true, ["managerUserIds": ["U-M"]]),
        ]
    }

    func testTheMyListIsPrefilledWithTheJobsTheyManageUntilTheFirstSave() throws {
        let jobs = try myJobs()
        let manager = viewer(managerRole, uid: "U-M")
        let context = RulebookWorksListContext()
        XCTAssertEqual(
            CanonicalBusinessEngine.myWorksList(jobs, picks: .neverSaved, viewer: manager, context: context, kind: .projects).map(\.documentId),
            ["P1"]
        )
        XCTAssertEqual(
            CanonicalBusinessEngine.myWorksList(jobs, picks: .neverSaved, viewer: manager, context: context, kind: .smallWorks).map(\.documentId),
            ["S1"]
        )
        let saved = MyWorksPicks(projects: ["p2"], smallWorks: nil)
        XCTAssertEqual(
            CanonicalBusinessEngine.myWorksList(jobs, picks: saved, viewer: manager, context: context, kind: .projects).map(\.documentId),
            ["P2"],
            "the saved picks replace the pre-fill; ids compare without case"
        )
        let emptied = MyWorksPicks(projects: [], smallWorks: nil)
        XCTAssertTrue(
            CanonicalBusinessEngine.myWorksList(jobs, picks: emptied, viewer: manager, context: context, kind: .projects).isEmpty,
            "a saved empty list stays empty"
        )
        let rows = CanonicalBusinessEngine.myWorksPickerRows(jobs, picks: .neverSaved, viewer: manager, context: context, kind: .projects)
        XCTAssertEqual(rows.map { $0.job.documentId }, ["P1", "P2"])
        XCTAssertEqual(rows.map { $0.picked }, [true, false])
    }

    func testWhoGetsTheMyListAndItsDefault() {
        XCTAssertTrue(CanonicalBusinessEngine.hasMyWorksList(viewer(managerRole, uid: "M")))
        XCTAssertTrue(CanonicalBusinessEngine.hasMyWorksList(viewer(adminRole, uid: "A")))
        XCTAssertFalse(CanonicalBusinessEngine.hasMyWorksList(viewer(operativeRole, uid: "O")))
        XCTAssertFalse(CanonicalBusinessEngine.hasMyWorksList(nil))
        XCTAssertEqual(CanonicalBusinessEngine.defaultWorksListTab(viewer(managerRole, uid: "M")), "mine")
        XCTAssertEqual(CanonicalBusinessEngine.defaultWorksListTab(viewer(operativeRole, uid: "O")), "active")
        XCTAssertEqual(CanonicalBusinessEngine.myWorksTabLabel(.projects), "My Projects")
        XCTAssertEqual(CanonicalBusinessEngine.myWorksTabLabel(.smallWorks), "My Small works")
        XCTAssertEqual(CanonicalBusinessEngine.myWorksEmptyTitle(.projects), "No projects in your list yet")
        XCTAssertEqual(CanonicalBusinessEngine.myWorksEmptyActionLabel(.projects), "Choose projects")
    }

    func testThePicksDocument() throws {
        XCTAssertEqual(
            CanonicalBusinessEngine.myWorksPicksPath(organizationId: "ORG", uid: "U"),
            "organizations/ORG/worksListPicks/U"
        )
        XCTAssertNil(CanonicalBusinessEngine.myWorksPicksPath(organizationId: "", uid: "U"))
        XCTAssertEqual(CanonicalBusinessEngine.parseMyWorksPicks(["projects": ["x", "X"]]), MyWorksPicks(projects: ["x"], smallWorks: nil))
        XCTAssertEqual(CanonicalBusinessEngine.parseMyWorksPicks(nil), .neverSaved)
        let fields = try XCTUnwrap(CanonicalBusinessEngine.myWorksPicksWriteFields(kind: .projects, ids: ["a", "A", "b"]))
        XCTAssertEqual(fields["projects"] as? [String], ["a", "b"])
        XCTAssertNil(fields["smallWorks"], "a save writes one kind; the other is left as stored (merge)")
        XCTAssertNotNil(fields["updatedAt"])
        XCTAssertEqual(CanonicalBusinessEngine.myWorksPicksAfterToggle(["a", "b"], jobId: "A", picked: false), ["b"])
        XCTAssertEqual(CanonicalBusinessEngine.myWorksPicksAfterToggle(["a"], jobId: "c", picked: true), ["a", "c"])
    }

    // MARK: Line manager set once, then locked (§11)

    private func person(_ id: String, role: UserRole, admin: Bool = false, manager: Bool = false, operatives: Bool = false, operative: Bool = false, lineManagers: [String] = []) -> AppUser {
        AppUser(
            id: id,
            email: "\(id.lowercased())@example.test",
            organizationId: "TEST-ORG",
            role: role,
            passwordSet: true,
            permissions: UserPermissions(adminAccess: admin, manager: manager || admin, operatives: operatives, operativeMode: operative),
            assignedManagerUserIds: lineManagers
        )
    }

    func testOnlyAnAdminChangesALineManagerOnceThePersonIsAdded() {
        let admin = person("ADM", role: .admin, admin: true)
        let opsManager = person("MGR", role: .manager, manager: true, operatives: true)
        let plainManager = person("M2", role: .manager, manager: true)
        let operative = person("OP", role: .operative, operative: true, lineManagers: ["MGR"])
        let otherManager = person("M3", role: .manager, manager: true)
        XCTAssertTrue(CanonicalBusinessEngine.canChangeLineManager(actor: admin.lineManagerAccessRow, target: operative.lineManagerAccessRow))
        XCTAssertFalse(CanonicalBusinessEngine.canChangeLineManager(actor: opsManager.lineManagerAccessRow, target: operative.lineManagerAccessRow),
                       "locked once added")
        XCTAssertTrue(CanonicalBusinessEngine.canChangeLineManager(actor: opsManager.lineManagerAccessRow, target: operative.lineManagerAccessRow, isCreate: true))
        XCTAssertTrue(CanonicalBusinessEngine.canChangeLineManager(
            actor: opsManager.lineManagerAccessRow, target: operative.lineManagerAccessRow, invitation: (accepted: false, invitedBy: "mgr")
        ), "their own unaccepted invitation")
        XCTAssertFalse(CanonicalBusinessEngine.canChangeLineManager(
            actor: opsManager.lineManagerAccessRow, target: operative.lineManagerAccessRow, invitation: (accepted: true, invitedBy: "MGR")
        ))
        XCTAssertFalse(CanonicalBusinessEngine.canChangeLineManager(actor: opsManager.lineManagerAccessRow, target: otherManager.lineManagerAccessRow, isCreate: true),
                       "operatives only")
        XCTAssertFalse(CanonicalBusinessEngine.canChangeLineManager(actor: plainManager.lineManagerAccessRow, target: operative.lineManagerAccessRow, isCreate: true))
        XCTAssertEqual(CanonicalBusinessEngine.lineManagerLockedMessage, "Only an admin can change the line manager once this person has been added.")
    }

    func testLineManagerChangedIgnoresOrderAndCase() {
        var before = person("OP", role: .operative, operative: true, lineManagers: ["A", "b"])
        var after = before
        after.setLineManagerUserIds(["B", "a"])
        XCTAssertFalse(CanonicalBusinessEngine.lineManagerChanged(before: before.lineManagerAccessRow, after: after.lineManagerAccessRow))
        after.setLineManagerUserIds(["A"])
        XCTAssertTrue(CanonicalBusinessEngine.lineManagerChanged(before: before.lineManagerAccessRow, after: after.lineManagerAccessRow))
        before.setLineManagerUserIds([])
        after = before
        after.hasNoLineManager = !before.hasNoLineManager
        XCTAssertTrue(CanonicalBusinessEngine.lineManagerChanged(before: before.lineManagerAccessRow, after: after.lineManagerAccessRow))
    }

    // MARK: Bundle (§11, §16)

    func testTheMaterialsCatalogueIsAdminsOnly() {
        XCTAssertFalse(CanonicalBusinessEngine.canManageMaterialCatalogue(managerRole))
        XCTAssertTrue(CanonicalBusinessEngine.canManageMaterialCatalogue(adminRole))
        XCTAssertFalse(CanonicalBusinessEngine.canManageMaterialCatalogue(Role(isSuperAdmin: true, isAdmin: true, isManager: false, isOperativeMode: true)))
    }

    func testDeactivatingNeverWritesAnotherCompanysUsersDocument() {
        let writes = CanonicalBusinessEngine.userActiveWrites(
            organizationId: "ORG",
            personId: "OP",
            email: "op@x.t",
            personOrganizationId: "OTHER",
            isActive: false,
            roster: [
                ["id": "OP", "email": "op@x.t", "organizationId": "OTHER"],
                ["id": "op2", "email": "OP@x.t", "organizationId": "ORG"],
            ]
        )
        XCTAssertEqual(writes.map(\.path), ["users/op2", "users/OP/orgMemberships/ORG"])
    }

    // MARK: Pre-merge review fixes (PR #202)

    /// The rules compare `assignedManagerUserIds` element by element (`lineManagersUnchanged`), so a save keeps the
    /// stored order and appends new ids sorted; the picker's `Set` order never reaches Firestore.
    func testLineManagerSaveKeepsTheStoredOrder() {
        XCTAssertEqual(AppUser.stableLineManagerOrder(stored: ["B", "A"], selected: ["A", "B"]), ["B", "A"])
        XCTAssertEqual(AppUser.stableLineManagerOrder(stored: ["B", "A"], selected: ["D", "A", "C", "B"]), ["B", "A", "C", "D"])
        XCTAssertEqual(AppUser.stableLineManagerOrder(stored: ["B", "A"], selected: ["A"]), ["A"])
        XCTAssertEqual(AppUser.stableLineManagerOrder(stored: [], selected: [" Z ", "Y", ""]), ["Y", "Z"])
    }

    /// A queued delete for another organisation than the open one is judged by the security rules, not this device.
    func testOfflineDeleteOfAnotherOrganisationLetsTheServerDecide() {
        XCTAssertNil(FirebaseBackend.offlineDeleteAllowed(
            collection: "bookings",
            data: ["projectId": "JOB-1"],
            sameOrganization: false
        ))
    }
}
