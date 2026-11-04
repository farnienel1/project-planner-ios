import FirebaseFirestore
import XCTest
@testable import Project_Planner

/// RULEBOOK 1.30.3 §11 on iOS through `CanonicalBusinessEngine`: the project and small-works manager picker offers
/// `jobManagerCandidates(roster)` and reads a job's stored managers through `jobManagerAssignments(job, roster,
/// catalogue)`. An edit keeps every stored manager id as stored (never an empty-email manager row, never a match on an
/// empty email), leaves the legacy `manager` label alone and trims the job number as create does.
@MainActor
final class Rulebook1303JobManagerTests: XCTestCase {
    private let org = "TEST-ORG-1303"

    private func user(_ id: String, role: UserRole, admin: Bool = false, manager: Bool = false, active: Bool = true, signedUp: Bool = true) -> AppUser {
        AppUser(
            id: id,
            email: "\(id.lowercased())@example.test",
            organizationId: org,
            role: role,
            firstName: "TEST-\(id)",
            surname: "Person",
            isActive: active,
            passwordSet: signedUp,
            permissions: UserPermissions(adminAccess: admin, manager: manager)
        )
    }

    private var roster: [AppUser] {
        [
            user("ADMIN-1", role: .admin, admin: true),
            user("MGR-1", role: .manager, manager: true),
            user("OP-1", role: .operative),
            user("MGR-OLD", role: .manager, manager: true, active: false),
            user("MGR-INVITE", role: .manager, manager: true, signedUp: false),
        ]
    }

    func testThePickerOffersOnlyActiveSignedUpAdminsAndManagers() throws {
        let candidates = try XCTUnwrap(CanonicalBusinessEngine.jobManagerCandidates(roster: JobManagerRulebook.roster(roster)))
        XCTAssertEqual(Set(candidates.map(\.id)), ["ADMIN-1", "MGR-1"], "never an operative, inactive person or open invite")
        XCTAssertFalse(CanonicalBusinessEngine.jobManagerNoCandidatesMessage.isEmpty)
        XCTAssertEqual(CanonicalBusinessEngine.jobManagerCandidates(roster: [])?.isEmpty, true)

        let catalogueRow = Manager(firstName: "TEST-MGR-1", lastName: "Person", email: "MGR-1@example.test", mobileNumber: "")
        let offered = ProjectManagerPickerSupport.availableManagers(candidates: candidates, catalogue: [catalogueRow], excluding: [])
        XCTAssertEqual(offered.count, 2)
        XCTAssertTrue(offered.contains { $0.id == catalogueRow.id }, "a candidate on a catalogue email is that row")
        XCTAssertTrue(offered.contains { $0.id == ProjectManagerPickerSupport.stableManagerId(email: "admin-1@example.test") })
        XCTAssertTrue(
            ProjectManagerPickerSupport.availableManagers(candidates: candidates, catalogue: [catalogueRow], excluding: [catalogueRow])
                .allSatisfy { $0.id != catalogueRow.id },
            "someone already on the job is left off"
        )
    }

    /// A web job naming a catalogue row of a person who is an operative now, and an id nobody loaded.
    private func webJob(manager: String = "Jane Smith", jobNumber: String = "J-1303") throws -> Project {
        try XCTUnwrap(FirebaseBackend.jobs(fromDocuments: [(id: "web-job-1303", data: [
            "jobNumber": jobNumber,
            "siteName": "TEST-Site",
            "client": ["id": "client-1303", "name": "TEST-Client"],
            "manager": manager,
            "managerIds": ["cat-op-1", "web-mgr-not-loaded"],
            "createdAt": Timestamp(seconds: 1_791_190_800, nanoseconds: 0),
        ])], smallWorks: false).first)
    }

    func testAFormerManagerIsShownAsSuchAndAnUnknownIdIsKeptAsStored() throws {
        let job = try webJob()
        var catalogueRow = Manager(
            id: Manager.stableId(forFirestoreDocumentId: "cat-op-1"),
            firstName: "TEST-OP-1", lastName: "Person", email: "op-1@example.test", mobileNumber: ""
        )
        catalogueRow.firestoreDocumentId = "cat-op-1"
        let assignments = CanonicalBusinessEngine.jobManagerAssignments(
            job: JobManagerRulebook.job(job),
            roster: JobManagerRulebook.roster(roster),
            catalogue: JobManagerRulebook.catalogue([catalogueRow])
        )
        let rows = ProjectManagerPickerSupport.assignedManagers(for: job, assignments: assignments, catalogue: [catalogueRow])
        XCTAssertEqual(rows.map(\.state), [.former, .unknown])
        XCTAssertEqual(rows.first?.note, "Former manager — no longer a manager")
        XCTAssertEqual(rows.first?.manager.id, catalogueRow.id)

        let unknown = try XCTUnwrap(rows.last?.manager)
        XCTAssertEqual(unknown.email, "", "no email is made up for a manager not loaded")
        XCTAssertEqual(rows.map(\.manager.id), job.allAssignedManagerIds, "every stored id is kept, in stored order")
        XCTAssertEqual(job.storedManagerId(for: unknown.id), "web-mgr-not-loaded")
    }

    func testSavingKeepsStoredIdsAndNeverCreatesOrMatchesAnEmptyEmailRow() async throws {
        let job = try webJob()
        let store = OperativeStore()
        // A junk row an older build created for a manager it had not loaded.
        let junk = Manager(firstName: "Assigned", lastName: "manager", email: "", mobileNumber: "")
        store.managers = [junk]
        let notLoadedId = try XCTUnwrap(job.allAssignedManagerIds.last)
        let notLoaded = Manager(id: notLoadedId, firstName: "", lastName: "", email: "", mobileNumber: "")
        let pickedWithoutEmail = Manager(firstName: "TEST", lastName: "NoEmail", email: "", mobileNumber: "")

        let resolved = await ProjectManagerPickerSupport.resolveManagersForSave(
            [notLoaded, pickedWithoutEmail],
            keepingStored: Set(job.allAssignedManagerIds),
            operativeStore: store
        )
        XCTAssertEqual(resolved.map(\.id), [notLoaded.id, pickedWithoutEmail.id], "never repointed at the empty-email row")
        XCTAssertEqual(store.managers.map(\.id), [junk.id], "no manager row is created without an email")

        var edited = job
        edited.managerIds = resolved.map(\.id)
        edited.managerId = resolved.first?.id
        let payload = FirebaseBackend.jobDocumentPayload(edited, organizationId: org)
        XCTAssertEqual((payload["managerIds"] as? [String])?.first, "web-mgr-not-loaded", "the unresolved id is written back as stored")
    }

    func testAnEditLeavesTheStoredManagerLabelAndTrimsTheJobNumber() throws {
        let job = try webJob(manager: "Jane Smith", jobNumber: "J-1303")
        let form = EditProjectSnapshot(
            jobNumber: "  J-1303 \n",
            siteName: job.siteName,
            addressLine1: job.addressLine1,
            addressLine2: job.addressLine2 ?? "",
            townCity: job.townCity,
            postcode: job.postcode,
            startDate: job.startDate,
            endDate: job.endDate,
            worksType: job.customJobType ?? "",
            description: job.description ?? "",
            clientId: job.client.id,
            managerIds: job.allAssignedManagerIds,
            locationMode: EditLocationMode.addressFields.rawValue,
            pinLatitude: nil,
            pinLongitude: nil
        )
        let managers = job.allAssignedManagerIds.map { Manager(id: $0, firstName: "", lastName: "", email: "", mobileNumber: "") }
        let edited = EditProjectView.editedJob(from: job, form: form, client: job.client, jobType: job.jobType, managers: managers)
        XCTAssertEqual(edited.jobNumber, "J-1303", "trimmed as on create")
        XCTAssertEqual(edited.manager, job.manager, "the legacy label stays as read, never Custom")
        XCTAssertEqual(edited.documentId, "web-job-1303")

        let fields = FirebaseBackend.jobSaveFields(edited, previous: job, organizationId: org, viewer: nil)
        let write = try XCTUnwrap(CanonicalBusinessEngine.peopleDocumentWrite(
            "jobWriteFields",
            before: try XCTUnwrap(fields.previous),
            next: fields.payload
        ))
        for key in ["manager", "jobNumber", "managerIds", "managerId"] {
            XCTAssertFalse(write.setKeys.contains(key), "\(key) is unchanged, so it is not sent")
            XCTAssertFalse(write.removeKeys.contains(key))
        }
    }
}
