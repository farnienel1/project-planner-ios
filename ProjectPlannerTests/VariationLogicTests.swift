import XCTest
@testable import Project_Planner

@MainActor
final class VariationLogicTests: XCTestCase {
    /// Releasing a main-actor store at the end of a test hits a Swift runtime crash in this host.
    private static var retained: [AnyObject] = []

    private func keep(_ object: AnyObject) {
        Self.retained.append(object)
    }
    func testNextNumberIsSequentialAndUniquePerProject() {
        let projectA = [
            LogicFixtures.variation(id: "1", voNumber: "VO-001", sequence: 1),
            LogicFixtures.variation(id: "2", voNumber: "VO-002", sequence: 2),
        ]
        XCTAssertEqual(VariationNumbering.nextFree(existing: projectA), "VO-003")

        let projectB = [
            LogicFixtures.variation(id: "9", voNumber: "VO-001", sequence: 1),
        ]
        XCTAssertEqual(VariationNumbering.nextFree(existing: projectB), "VO-002")
        XCTAssertNotEqual(
            VariationNumbering.nextFree(existing: projectA),
            VariationNumbering.nextFree(existing: [])
        )
        XCTAssertEqual(VariationNumbering.nextFree(existing: []), "VO-001")
    }

    func testReorderingDoesNotReuseOrRenumber() {
        let createdFirst = LogicFixtures.variation(
            id: "1",
            voNumber: "VO-001",
            sequence: 30,
            createdAt: Date(timeIntervalSince1970: 10)
        )
        let createdLater = LogicFixtures.variation(
            id: "2",
            voNumber: "VO-003",
            sequence: 1,
            createdAt: Date(timeIntervalSince1970: 20)
        )
        let middle = LogicFixtures.variation(id: "3", voNumber: "VO-002", sequence: 2)
        let forward = VariationNumbering.nextFree(existing: [createdFirst, createdLater, middle])
        let reversed = VariationNumbering.nextFree(existing: [middle, createdLater, createdFirst])
        XCTAssertEqual(forward, "VO-004")
        XCTAssertEqual(reversed, forward)

        let store = VariationStore(parentId: "project-a", parentType: .project)
        keep(store)
        var tracker = VariationTracker.disabled(parentId: "project-a", parentType: .project)
        tracker.enabled = true
        store.tracker = tracker
        store.variations = [createdLater, middle, createdFirst]
        XCTAssertEqual(store.nextVoNumber(), "VO-004")
        XCTAssertEqual(store.visibleVariations.map(\.voNumber), ["VO-003", "VO-002", "VO-001"])
    }

    func testClosedDeletedAndGapsAreNotReused() {
        let existing = [
            LogicFixtures.variation(id: "1", voNumber: "VO-001", sequence: 1, status: .closed),
            LogicFixtures.variation(id: "2", voNumber: "VO-003", sequence: 3, status: .submitted),
            LogicFixtures.variation(id: "4", voNumber: "VO-004", sequence: 4, isDeleted: true),
        ]
        XCTAssertEqual(
            VariationNumbering.nextFree(existing: existing),
            "VO-005",
            "VO-002 is a gap and VO-004 is deleted; neither is reused"
        )
    }

    func testDuplicateCheckIgnoresDeletedAndTheRowBeingEdited() {
        let store = VariationStore(parentId: "project-a", parentType: .project)
        keep(store)
        store.variations = [
            LogicFixtures.variation(id: "1", voNumber: "VO-001", sequence: 1),
            LogicFixtures.variation(id: "2", voNumber: " vo-002 ", sequence: 2, isDeleted: true),
        ]
        XCTAssertTrue(store.voNumberIsDuplicate("vo-001", excludingId: nil))
        XCTAssertFalse(store.voNumberIsDuplicate("VO-001", excludingId: "1"))
        XCTAssertFalse(store.voNumberIsDuplicate("VO-002", excludingId: nil))
        XCTAssertFalse(store.voNumberIsDuplicate("VO-003", excludingId: nil))
    }

    func testStatusOrderAndLabourCounts() {
        XCTAssertEqual(VariationStatus.allCases, [.open, .submitted, .closed])
        XCTAssertEqual(VariationStatus.open.title, "Open")
        XCTAssertEqual(VariationStatus.submitted.title, "Submitted")
        XCTAssertEqual(VariationStatus.closed.title, "Closed")

        var variation = LogicFixtures.variation(id: "1", voNumber: "VO-001", sequence: 1)
        variation.labour = [
            VariationLabourLine(id: "l1", trade: "Electrical", hours: 3.5),
            VariationLabourLine(id: "l2", trade: "Labourer", hours: 4),
        ]
        variation.materials = [
            VariationMaterialLine(id: "m1", name: "Cable", quantity: "10m"),
        ]
        variation.evidence = [
            VariationEvidenceItem(
                id: "e1",
                fileName: "a.jpg",
                contentType: "image/jpeg",
                sizeBytes: 10,
                storagePath: "path",
                downloadURL: "https://example.invalid/a.jpg",
                uploadedByUid: "user-1",
                uploadedAt: Date(timeIntervalSince1970: 0),
                isPending: false
            ),
            VariationEvidenceItem(
                id: "e2",
                fileName: "pending.jpg",
                contentType: "image/jpeg",
                sizeBytes: 10,
                storagePath: "",
                downloadURL: "",
                uploadedByUid: "user-1",
                uploadedAt: Date(timeIntervalSince1970: 0),
                isPending: true
            ),
        ]
        variation.recomputeCounts()
        XCTAssertClose(variation.totalLabourHours, 7.5)
        XCTAssertEqual(variation.materialLineCount, 1)
        XCTAssertEqual(variation.evidenceCount, 1)
    }

    func testCustomPrefixAndPadding() {
        XCTAssertEqual(VariationNumbering.format(prefix: "SW-", padding: 4, value: 7), "SW-0007")
        let existing = [LogicFixtures.variation(id: "1", voNumber: "SW-0007", sequence: 1)]
        XCTAssertEqual(VariationNumbering.nextFree(existing: existing, prefix: "SW-", padding: 4), "SW-0008")
    }
}
