import XCTest
@testable import Project_Planner

/// RULEBOOK §1 partial writes / §2 online-only organisation records: a save writes only the records the user
/// changed, and an edit of a record deleted on another device never re-creates it.
@MainActor
final class RecordWritePlanTests: XCTestCase {
    private func job(_ name: String) -> Project {
        Project(
            id: UUID(),
            jobNumber: "TEST-1",
            siteName: name,
            addressLine1: "1 Test Street",
            townCity: "London",
            postcode: "W1 1AA",
            client: Client(id: UUID(), name: "TEST-Client", contactPerson: nil, email: "", phone: "", address: ""),
            startDate: Date(),
            endDate: Date(),
            jobType: .catA,
            manager: .na
        )
    }

    func testAnEditOfAMissingDocumentIsRefusedNotRecreated() {
        XCTAssertEqual(RecordWritePlan.action(mode: .update, documentExists: false), .refuseDeletedElsewhere)
        XCTAssertEqual(RecordWritePlan.action(mode: .update, documentExists: true), .update)
    }

    func testOnlyAGenuineCreateCreates() {
        XCTAssertEqual(RecordWritePlan.action(mode: .create, documentExists: false), .create)
        // A create that finds the document already there (a retry) becomes a partial update.
        XCTAssertEqual(RecordWritePlan.action(mode: .create, documentExists: true), .update)
        // Legacy upsert (subcontractors, material catalogue) is unchanged.
        XCTAssertEqual(RecordWritePlan.action(mode: nil, documentExists: false), .create)
    }

    func testAChangeSetSavesOnlyTheRecordItNames() {
        let a = job("TEST-A"), b = job("TEST-B"), c = job("TEST-C")
        var edited = b
        edited.siteName = "TEST-B edited"
        let changes = ProjectStoreChangeSet.updateWork(edited, previous: b)
        let toSave = changes.worksToSave(from: [a, edited, c])
        XCTAssertEqual(toSave.map { $0.work.id }, [b.id])
        XCTAssertEqual(toSave.first?.mode, .update)
        XCTAssertEqual(toSave.first?.previous?.siteName, "TEST-B", "the edited copy is the baseline")
        XCTAssertTrue(changes.clientsToSave(from: [a.client, b.client]).isEmpty)
    }

    func testLocalOnlyWritesNothingAndAVanishedRecordIsSkipped() {
        let a = job("TEST-A")
        XCTAssertTrue(ProjectStoreChangeSet.localOnly.isEmpty)
        XCTAssertTrue(ProjectStoreChangeSet.localOnly.worksToSave(from: [a]).isEmpty)
        XCTAssertTrue(ProjectStoreChangeSet.createWork(a).worksToSave(from: []).isEmpty)
        XCTAssertEqual(ProjectStoreChangeSet.createWork(a).worksToSave(from: [a]).first?.mode, .create)
    }

    func testDeletedElsewhereIsFinalWithNeutralCopy() {
        let error = RecordDeletedElsewhereError(collection: "projects", documentId: "ABC")
        XCTAssertEqual(error.localizedDescription, "This was deleted on another device.")
    }
}
