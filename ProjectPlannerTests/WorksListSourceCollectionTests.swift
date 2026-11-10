import XCTest
@testable import Project_Planner

/// Owner bug (iOS 1.33): Projects → ⚙ "My Projects" listed small works, and Small works → ⚙ listed projects.
/// RULEBOOK §17 / §21 `jobKind`: the collection a job document was read from decides its kind, never `jobType`.
/// `Project.sourceCollection` carries that collection into `worksListJSON` (`collection`), the store slices and the
/// writes, so the picker (`myWorksPickerRows`), the My list (`myWorksList`) and the lists (`worksListMembership`)
/// follow the document's own collection.
@MainActor
final class WorksListSourceCollectionTests: XCTestCase {
    private typealias Role = CanonicalBusinessEngine.CanonicalStaffAccountRole

    private var admin: JobAccessViewer {
        JobAccessViewer(
            role: Role(isSuperAdmin: false, isAdmin: true, isManager: false, isOperativeMode: false),
            projectsToggle: true,
            smallWorksToggle: true,
            uid: "ADM",
            ids: ["ADM"],
            email: "adm@x.t"
        )
    }

    private func read(_ id: String, smallWorks: Bool, _ data: [String: Any]) throws -> Project {
        try XCTUnwrap(FirebaseBackend.jobs(fromDocuments: [(id: id, data: data)], smallWorks: smallWorks).first)
    }

    private func job(_ name: String, jobType: JobType, sourceCollection: JobKind? = nil) -> Project {
        Project(
            jobNumber: "TEST-\(name)",
            siteName: name,
            addressLine1: "1 Test Street",
            townCity: "London",
            postcode: "W1 1AA",
            client: Client(id: UUID(), name: "TEST-Client", contactPerson: nil, email: "", phone: "", address: ""),
            startDate: Date(),
            endDate: Date(),
            jobType: jobType,
            manager: .na,
            sourceCollection: sourceCollection
        )
    }

    private func pickerIds(_ jobs: [Project], kind: JobKind) -> [String] {
        CanonicalBusinessEngine.myWorksPickerRows(
            jobs,
            picks: .neverSaved,
            viewer: admin,
            context: RulebookWorksListContext(),
            kind: kind
        ).map { $0.job.documentId }
    }

    private func myListIds(_ jobs: [Project], kind: JobKind) -> [String] {
        let all = jobs.map(\.documentId)
        let picks = MyWorksPicks(projects: all, smallWorks: all)
        return CanonicalBusinessEngine.myWorksList(
            jobs,
            picks: picks,
            viewer: admin,
            context: RulebookWorksListContext(),
            kind: kind
        ).map(\.documentId)
    }

    // MARK: - The reader records the collection

    func testASmallWorksDocumentTypedCatAIsOnlyInTheSmallWorksPickerAndLists() throws {
        let smallWork = try read("SW-CATA", smallWorks: true, ["siteName": "Small job", "jobType": "CAT A"])
        let project = try read("PRJ-1", smallWorks: false, ["siteName": "Project", "jobType": "CAT A"])
        XCTAssertEqual(smallWork.sourceCollection, .smallWorks)
        XCTAssertEqual(smallWork.jobKind, .smallWorks)
        XCTAssertEqual(smallWork.worksListJSON(index: 0)["collection"] as? String, "smallWorks")

        // The views pass `projectStore.projects + projectStore.smallWorks`.
        let jobs = [project, smallWork, smallWork]
        XCTAssertEqual(pickerIds(jobs, kind: .projects), ["PRJ-1"])
        XCTAssertEqual(pickerIds(jobs, kind: .smallWorks), ["SW-CATA"])
        XCTAssertEqual(myListIds(jobs, kind: .projects), ["PRJ-1"])
        XCTAssertEqual(myListIds(jobs, kind: .smallWorks), ["SW-CATA"])
        XCTAssertEqual(CanonicalBusinessEngine.worksListMembership(jobs, kind: .projects).map(\.documentId), ["PRJ-1"])
        XCTAssertEqual(CanonicalBusinessEngine.worksListMembership(jobs, kind: .smallWorks).map(\.documentId), ["SW-CATA"])
    }

    func testAProjectsDocumentTypedSmallWorksIsOnlyInProjects() throws {
        let project = try read("PRJ-SW", smallWorks: false, ["siteName": "Old web project", "jobType": "Small Works"])
        let smallWork = try read("SW-1", smallWorks: true, ["siteName": "Small job", "jobType": "Small Works"])
        XCTAssertEqual(project.sourceCollection, .projects)
        XCTAssertEqual(project.worksListJSON(index: 0)["collection"] as? String, "projects")

        let jobs = [project, smallWork, smallWork]
        XCTAssertEqual(pickerIds(jobs, kind: .projects), ["PRJ-SW"])
        XCTAssertEqual(pickerIds(jobs, kind: .smallWorks), ["SW-1"])
        XCTAssertEqual(myListIds(jobs, kind: .projects), ["PRJ-SW"])
        XCTAssertEqual(myListIds(jobs, kind: .smallWorks), ["SW-1"])
    }

    func testTheCollectionWinsOverAMismatchedJobType() {
        // Whatever `jobType` says, the picker follows the collection the job was read from.
        let smallWorkTypedCatA = job("SW", jobType: .catA, sourceCollection: .smallWorks)
        let projectTypedSmallWorks = job("PR", jobType: .smallWorks, sourceCollection: .projects)
        let jobs = [smallWorkTypedCatA, projectTypedSmallWorks]
        XCTAssertEqual(pickerIds(jobs, kind: .projects), [projectTypedSmallWorks.documentId])
        XCTAssertEqual(pickerIds(jobs, kind: .smallWorks), [smallWorkTypedCatA.documentId])
        XCTAssertTrue(smallWorkTypedCatA.isSmallWorksDocument)
        XCTAssertFalse(projectTypedSmallWorks.isSmallWorksDocument)
    }

    func testAProjectAndASmallWorkSharingAnIdAreEachInTheirOwnPicker() throws {
        let sharedId = "6F1C2B3A-1111-4222-8333-444455556666"
        let project = try read(sharedId, smallWorks: false, ["siteName": "Twin", "jobType": "CAT A"])
        let smallWork = try read(sharedId, smallWorks: true, ["siteName": "Twin", "jobType": "CAT A"])
        let jobs = [project, smallWork]
        let projectRows = CanonicalBusinessEngine.myWorksPickerRows(
            jobs, picks: .neverSaved, viewer: admin, context: RulebookWorksListContext(), kind: .projects
        )
        let smallRows = CanonicalBusinessEngine.myWorksPickerRows(
            jobs, picks: .neverSaved, viewer: admin, context: RulebookWorksListContext(), kind: .smallWorks
        )
        XCTAssertEqual(projectRows.map { $0.job.sourceCollection }, [.projects])
        XCTAssertEqual(smallRows.map { $0.job.sourceCollection }, [.smallWorks])
    }

    // MARK: - Creates and the on-device cache

    func testNewJobsTakeTheirCollectionFromTheCreateType() {
        XCTAssertEqual(job("NEW-SW", jobType: .smallWorks).sourceCollection, .smallWorks)
        XCTAssertEqual(job("NEW-PR", jobType: .catB).sourceCollection, .projects)
    }

    func testTheCollectionSurvivesTheOnDeviceCache() throws {
        let smallWork = try read("SW-CACHE", smallWorks: true, ["siteName": "Cached", "jobType": "CAT A"])
        var mismatched = smallWork
        mismatched.jobType = .catA
        let data = try JSONEncoder().encode([mismatched])
        let decoded = try JSONDecoder().decode([Project].self, from: data)
        XCTAssertEqual(decoded.first?.sourceCollection, .smallWorks)
        XCTAssertEqual(decoded.first?.jobType, .catA)
    }

    func testAnOldCachedCopyWithoutTheFieldStillDecodes() throws {
        for (type, expected) in [(JobType.smallWorks, JobKind.smallWorks), (.catA, .projects), (.maintenance, .projects)] {
            var object = try XCTUnwrap(
                JSONSerialization.jsonObject(with: JSONEncoder().encode(job("OLD", jobType: type))) as? [String: Any]
            )
            object.removeValue(forKey: "sourceCollection")
            let old = try JSONSerialization.data(withJSONObject: object)
            let decoded = try JSONDecoder().decode(Project.self, from: old)
            XCTAssertEqual(decoded.sourceCollection, expected, "a copy saved before the field existed keeps the old guess")
            XCTAssertEqual(decoded.jobType, type)
        }
    }

    // MARK: - Writes go to the document's own collection

    func testAnEditKeepsTheCollectionItWasReadFrom() throws {
        let smallWork = try read("SW-EDIT", smallWorks: true, ["siteName": "Small job", "jobType": "CAT A"])
        let form = EditProjectSnapshot(
            jobNumber: "J-1",
            siteName: "Renamed",
            addressLine1: "1 Test Street",
            addressLine2: "",
            townCity: "London",
            postcode: "W1 1AA",
            startDate: smallWork.startDate,
            endDate: smallWork.endDate,
            worksType: "CAT A",
            description: "",
            clientId: smallWork.client.id,
            managerIds: [],
            locationMode: EditLocationMode.addressFields.rawValue,
            pinLatitude: nil,
            pinLongitude: nil
        )
        let edited = EditProjectView.editedJob(from: smallWork, form: form, client: smallWork.client, jobType: .catA, managers: [])
        XCTAssertEqual(edited.sourceCollection, .smallWorks, "an edit of a small works job is never written to projects")
        XCTAssertTrue(edited.isSmallWorksDocument)
    }

    func testASaveOfOneTwinNeverSavesTheOther() throws {
        let sharedId = "7A2D3C4B-2222-4333-8444-555566667777"
        let project = try read(sharedId, smallWorks: false, ["siteName": "Twin project", "jobType": "CAT A"])
        var smallWork = try read(sharedId, smallWorks: true, ["siteName": "Twin small work", "jobType": "CAT A"])
        let previous = smallWork
        smallWork.siteName = "Twin small work edited"

        let toSave = ProjectStoreChangeSet.updateWork(smallWork, previous: previous)
            .worksToSave(from: [project, smallWork])
        XCTAssertEqual(toSave.count, 1)
        XCTAssertEqual(toSave.first?.work.sourceCollection, .smallWorks, "the small works edit is written to smallWorks")
        XCTAssertEqual(toSave.first?.work.siteName, "Twin small work edited")

        let projectSave = ProjectStoreChangeSet.updateWork(project, previous: project).worksToSave(from: [project, smallWork])
        XCTAssertEqual(projectSave.first?.work.sourceCollection, .projects)
    }
}
