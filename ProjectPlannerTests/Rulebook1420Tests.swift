import FirebaseFirestore
import XCTest
@testable import Project_Planner

/// RULEBOOK 1.42.0 through `CanonicalBusinessEngine` (owner decisions 13 Nov):
///   - option B: the Projects / Small works toggle is an add-and-edit permission, never a view permission. Every screen
///     shows the rulebook's row text (`PERMISSION_TOGGLE_CATALOGUE`, `PROJECTS_TOGGLE_*`, `SMALL_WORKS_TOGGLE_*`);
///   - several managers per project or small works, on create and on edit, saved in `managerIds` / `managerId` /
///     `managerUserIds` through `jobWriteFields`; a manager without the toggle sends no manager-list field.
@MainActor
final class Rulebook1420Tests: XCTestCase {
    private typealias Role = CanonicalBusinessEngine.CanonicalStaffAccountRole

    // MARK: Toggle text

    func testTheProjectsAndSmallWorksRowsReadAsAddAndEdit() throws {
        // Read from the packed script (no Swift copy of the text exists).
        let projectsLabel = try XCTUnwrap(CanonicalBusinessEngine.constant("PROJECTS_TOGGLE_LABEL", as: String.self))
        let projectsHelp = try XCTUnwrap(CanonicalBusinessEngine.constant("PROJECTS_TOGGLE_HELP", as: String.self))
        let smallWorksLabel = try XCTUnwrap(CanonicalBusinessEngine.constant("SMALL_WORKS_TOGGLE_LABEL", as: String.self))
        let smallWorksHelp = try XCTUnwrap(CanonicalBusinessEngine.constant("SMALL_WORKS_TOGGLE_HELP", as: String.self))
        XCTAssertEqual(projectsLabel, "Projects — add & edit")
        XCTAssertEqual(smallWorksLabel, "Small Works — add & edit")
        XCTAssertEqual(
            projectsHelp,
            "Add new projects, edit any project and choose its managers. Without this, a manager still sees every project and can edit the projects they manage."
        )
        XCTAssertTrue(smallWorksHelp.hasPrefix("Add new small works"))

        for level in [RulebookPermissionLevel.admin, .manager] {
            for mode in [RulebookPermissionToggleMode.add, .edit, .summary] {
                let rows = CanonicalBusinessEngine.permissionToggleRows(level: level, user: nil, mode: mode)
                let projects = try XCTUnwrap(rows.first { $0.field == "projects" })
                let smallWorks = try XCTUnwrap(rows.first { $0.field == "smallWorks" })
                XCTAssertEqual(projects.label, projectsLabel, "Add User, its summary and Edit User")
                XCTAssertEqual(projects.help, projectsHelp)
                XCTAssertEqual(smallWorks.label, smallWorksLabel)
                XCTAssertEqual(smallWorks.help, smallWorksHelp)
                XCTAssertFalse(projects.help.localizedCaseInsensitiveContains("see only"), "never the pre-1.42 view wording")
            }
        }
    }

    func testChangeUserTypeFallbackNamesAreNeverRawKeys() {
        for field in ["operatives", "annualLeaveSelfBook", "weeklyReports", "dailyOverview", "subContractors", "qualifications",
                      "projects", "smallWorks", "materials", "siteAudit", "somethingNew"] {
            let name = EditUserView.permissionFallbackName(field)
            XCTAssertNotEqual(name, field, field)
            XCTAssertFalse(name.isEmpty)
        }
    }

    // MARK: Several managers per job

    private func viewer(_ role: Role, projects: Bool = false, smallWorks: Bool = false, uid: String) -> JobAccessViewer {
        JobAccessViewer(role: role, projectsToggle: projects, smallWorksToggle: smallWorks, uid: uid, ids: [uid], email: "\(uid)@x.t")
    }

    private var toggleManager: JobAccessViewer {
        viewer(Role(isSuperAdmin: false, isAdmin: false, isManager: true, isOperativeMode: false), projects: true, smallWorks: true, uid: "t1")
    }

    private var plainManager: JobAccessViewer {
        viewer(Role(isSuperAdmin: false, isAdmin: false, isManager: true, isOperativeMode: false), uid: "m1")
    }

    private let first = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
    private let second = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
    private let third = UUID(uuidString: "33333333-3333-3333-3333-333333333333")!

    private func job(managers: [UUID]) -> Project {
        Project(
            jobNumber: "TEST-J-142", siteName: "TEST-Site", addressLine1: "1 Road", townCity: "Leeds", postcode: "LS1",
            client: Client(name: "TEST-Client"), startDate: Date(timeIntervalSince1970: 1_790_000_000),
            endDate: Date(timeIntervalSince1970: 1_790_100_000), jobType: .catA, manager: .custom,
            managerId: managers.first, managerIds: managers
        )
    }

    private func form(for job: Project, managers: [UUID]) -> EditProjectSnapshot {
        EditProjectSnapshot(
            jobNumber: job.jobNumber, siteName: job.siteName, addressLine1: job.addressLine1,
            addressLine2: job.addressLine2 ?? "", townCity: job.townCity, postcode: job.postcode,
            startDate: job.startDate, endDate: job.endDate, worksType: job.customJobType ?? "",
            description: job.description ?? "", clientId: job.client.id, managerIds: managers,
            locationMode: EditLocationMode.addressFields.rawValue, pinLatitude: nil, pinLongitude: nil
        )
    }

    private func managerRow(_ id: UUID) -> Manager {
        Manager(id: id, firstName: "TEST", lastName: id.uuidString.prefix(4).description, email: "", mobileNumber: "")
    }

    func testCreateWithTwoManagersStoresBothTheFirstAsManagerId() throws {
        let created = job(managers: [first, second])
        XCTAssertTrue(CanonicalBusinessEngine.canCreateJob(toggleManager, kind: .projects))
        let fields = FirebaseBackend.jobSaveFields(created, previous: nil, organizationId: "TEST-ORG", viewer: toggleManager)
        XCTAssertEqual(fields.payload["managerIds"] as? [String], [first.uuidString, second.uuidString])
        XCTAssertEqual(fields.payload["managerId"] as? String, first.uuidString)
    }

    func testEditAddsAndRemovesManagersThroughJobWriteFields() throws {
        let stored = job(managers: [first, second])
        let added = EditProjectView.editedJob(
            from: stored, form: form(for: stored, managers: [first, second, third]),
            client: stored.client, jobType: stored.jobType, managers: [first, second, third].map(managerRow)
        )
        XCTAssertEqual(added.allAssignedManagerIds, [first, second, third])
        let addFields = FirebaseBackend.jobSaveFields(added, previous: stored, organizationId: "TEST-ORG", viewer: toggleManager)
        let addWrite = try XCTUnwrap(CanonicalBusinessEngine.peopleDocumentWrite(
            "jobWriteFields", before: try XCTUnwrap(addFields.previous), next: addFields.payload
        ))
        XCTAssertTrue(addWrite.setKeys.contains("managerIds"), "a third manager is written")
        XCTAssertFalse(addWrite.setKeys.contains("siteName"), "nothing else changes")

        let removed = EditProjectView.editedJob(
            from: stored, form: form(for: stored, managers: [second]),
            client: stored.client, jobType: stored.jobType, managers: [managerRow(second)]
        )
        let removeFields = FirebaseBackend.jobSaveFields(removed, previous: stored, organizationId: "TEST-ORG", viewer: toggleManager)
        XCTAssertEqual(removeFields.payload["managerIds"] as? [String], [second.uuidString])
        XCTAssertEqual(removeFields.payload["managerId"] as? String, second.uuidString)
    }

    func testAManagerWithoutTheToggleNeverChangesTheList() {
        XCTAssertFalse(CanonicalBusinessEngine.canChangeJobManagers(plainManager, kind: .projects))
        XCTAssertFalse(CanonicalBusinessEngine.canCreateJob(plainManager, kind: .smallWorks))
        let stored = job(managers: [first])
        let edited = EditProjectView.editedJob(
            from: stored, form: form(for: stored, managers: [first, second]),
            client: stored.client, jobType: stored.jobType, managers: [first, second].map(managerRow)
        )
        let fields = FirebaseBackend.jobSaveFields(edited, previous: stored, organizationId: "TEST-ORG", viewer: plainManager)
        for key in CanonicalBusinessEngine.jobManagerListFields {
            XCTAssertNil(fields.payload[key], "\(key) is not sent by a manager without the toggle")
        }
    }

    func testThePickerStillOffersTheOthersAfterOnePick() throws {
        let one = Manager(firstName: "TEST-A", lastName: "One", email: "a@example.test", mobileNumber: "")
        let two = Manager(firstName: "TEST-B", lastName: "Two", email: "b@example.test", mobileNumber: "")
        let roster = [
            AppUser(
                id: "A", email: "a@example.test", organizationId: "TEST-ORG", role: .manager, firstName: "TEST-A", surname: "One",
                isActive: true, passwordSet: true, permissions: UserPermissions(adminAccess: false, manager: true)
            ),
            AppUser(
                id: "B", email: "b@example.test", organizationId: "TEST-ORG", role: .admin, firstName: "TEST-B", surname: "Two",
                isActive: true, passwordSet: true, permissions: UserPermissions(adminAccess: true, manager: false)
            ),
        ]
        let candidates = try XCTUnwrap(CanonicalBusinessEngine.jobManagerCandidates(roster: JobManagerRulebook.roster(roster)))
        XCTAssertEqual(candidates.count, 2)
        let afterFirst = ProjectManagerPickerSupport.availableManagers(candidates: candidates, catalogue: [one, two], excluding: [one])
        XCTAssertEqual(afterFirst.map(\.id), [two.id], "the second manager can still be added")
        XCTAssertTrue(
            ProjectManagerPickerSupport.availableManagers(candidates: candidates, catalogue: [one, two], excluding: [one, two]).isEmpty
        )
    }

    // MARK: Multi-tick picker (coordinator request: adding several managers is easy)

    func testTickingSeveralManagersAddsThemAllInListOrder() {
        let a = managerRow(first), b = managerRow(second), c = managerRow(third)
        // Create: nobody yet; tick two of three, Done.
        let created = ProjectAssignedManagersEditor.applyingPicks(selected: [], available: [a, b, c], ticked: [c.id, a.id])
        XCTAssertEqual(created.map(\.id), [a.id, c.id], "every ticked manager, in list order")
        // Edit: A on the job; tick B and C too.
        let added = ProjectAssignedManagersEditor.applyingPicks(selected: [a], available: [b, c], ticked: [a.id, b.id, c.id])
        XCTAssertEqual(added.map(\.id), [a.id, b.id, c.id], "existing managers keep their place")
        // Edit: untick A, keep B.
        let removed = ProjectAssignedManagersEditor.applyingPicks(selected: [a, b], available: [c], ticked: [b.id])
        XCTAssertEqual(removed.map(\.id), [b.id])
        // Nothing ticked changes: the list stays as it was.
        XCTAssertEqual(ProjectAssignedManagersEditor.applyingPicks(selected: [a, b], available: [c], ticked: [a.id, b.id]).map(\.id), [a.id, b.id])
    }

    func testThePickerListsCurrentManagersFirstThenCandidatesEachOnce() {
        let a = managerRow(first), b = managerRow(second), c = managerRow(third)
        XCTAssertEqual(ProjectAssignedManagersEditor.pickerRows(selected: [b], available: [a, b, c]).map(\.id), [b.id, a.id, c.id])
    }

    // MARK: Change user type uses the rulebook rows for every toggle

    func testEveryChangeUserTypeRowHasRulebookText() throws {
        let manager = CanonicalBusinessEngine.permissionToggleRows(level: .manager, user: nil, mode: .edit)
        for field in ["operatives", "annualLeaveSelfBook", "dailyOverview", "subContractors", "qualifications", "projects", "smallWorks"] {
            let text = try XCTUnwrap(CanonicalBusinessEngine.permissionToggleText(field: field, level: .manager), field)
            let row = try XCTUnwrap(manager.first { $0.field == field })
            XCTAssertEqual(text.label, row.label)
            XCTAssertEqual(text.help, row.help)
            XCTAssertFalse(text.help.isEmpty, field)
        }
        XCTAssertNotNil(CanonicalBusinessEngine.permissionToggleText(field: "annualLeaveSelfBook", level: .admin))
        for field in ["materials", "siteAudit"] {
            XCTAssertNotNil(CanonicalBusinessEngine.permissionToggleText(field: field, level: .operative), field)
        }
        XCTAssertNil(CanonicalBusinessEngine.permissionToggleText(field: "weeklyReports", level: .manager), "admin-only, never on a manager")
        XCTAssertEqual(CanonicalBusinessEngine.permissionToggleText(field: "projects", level: .manager)?.label, "Projects — add & edit")
    }
}

