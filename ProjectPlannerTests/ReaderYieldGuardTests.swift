import XCTest
import FirebaseFirestore
@testable import Project_Planner

/// A non-empty snapshot or load whose rulebook reader produced no record is a failed read, never "the company has
/// no projects / no people": the list on screen stays and the refusal is recorded (`LiveSnapshotMerge` `rowCount`,
/// `ReaderDiagnostics`). Also locks the read-side causes found while tracing empty Projects and people lists:
/// non-finite numbers in a document, small works documents typed "CAT A", and user rows the script could not read.
@MainActor
final class ReaderYieldGuardTests: XCTestCase {
    private struct Row: Identifiable, Equatable {
        let id: Int
        let value: String
    }

    override func setUp() {
        super.setUp()
        ReaderDiagnostics.shared.reset()
    }

    // MARK: - LiveSnapshotMerge rowCount

    func testAServerSnapshotTheReaderCouldNotReadKeepsTheList() {
        let existing = [Row(id: 1, value: "a"), Row(id: 2, value: "b")]
        XCTAssertNil(
            LiveSnapshotMerge.apply(existing: existing, incoming: [Row](), fromCache: false, rowCount: 5, collection: "projects"),
            "5 documents and 0 records is a failed read: keep what is on screen"
        )
        let event = ReaderDiagnostics.shared.events.last
        XCTAssertEqual(event?.collection, "projects")
        XCTAssertEqual(event?.rowCount, 5)
        XCTAssertEqual(event?.parsedCount, 0)
        XCTAssertEqual(event?.keptCount, 2)
    }

    func testAnEmptyServerCollectionStillEmptiesTheList() {
        let existing = [Row(id: 1, value: "a")]
        XCTAssertEqual(LiveSnapshotMerge.apply(existing: existing, incoming: [Row](), fromCache: false, rowCount: 0), [],
                       "a record deleted on web leaves this device; no documents means really empty")
        XCTAssertTrue(ReaderDiagnostics.shared.events.isEmpty)
    }

    func testARefusalWithNothingOnScreenIsStillRecorded() {
        XCTAssertEqual(LiveSnapshotMerge.apply(existing: [Row](), incoming: [Row](), fromCache: false, rowCount: 3, collection: "users"), [])
        XCTAssertEqual(ReaderDiagnostics.shared.events.count, 1)
        XCTAssertTrue(ReaderDiagnostics.shared.summary().contains("users"))
    }

    func testAPartlyReadSnapshotStillReplacesTheList() {
        let existing = [Row(id: 1, value: "a"), Row(id: 2, value: "b")]
        let server = [Row(id: 2, value: "b edited")]
        XCTAssertEqual(LiveSnapshotMerge.apply(existing: existing, incoming: server, fromCache: false, rowCount: 3), server)
    }

    func testACacheSnapshotTheReaderCouldNotReadKeepsTheList() {
        let existing = [Row(id: 1, value: "a")]
        XCTAssertNil(LiveSnapshotMerge.apply(existing: existing, incoming: [Row](), fromCache: true, rowCount: 1))
    }

    func testThePlaceholderDocumentIsNotAReadableRow() {
        XCTAssertEqual(LiveSnapshotMerge.readableRowCount(ids: ["INITIAL-PLACEHOLDER"]), 0)
        XCTAssertEqual(LiveSnapshotMerge.readableRowCount(ids: ["INITIAL-PLACEHOLDER", "a", "B"]), 2)
        XCTAssertEqual(LiveSnapshotMerge.readableRowCount(ids: []), 0)
        let rows: LiveDocumentRows = [(id: "INITIAL-PLACEHOLDER", data: [:])]
        XCTAssertFalse(LiveSnapshotMerge.refusesUnreadSnapshot(
            collection: "projects",
            rowCount: LiveSnapshotMerge.readableRowCount(rows),
            parsedCount: 0,
            existingCount: 4,
            fromCache: false
        ), "a collection holding only the placeholder is empty")
    }

    func testALoadThatReadNothingIsReported() {
        XCTAssertTrue(LiveSnapshotMerge.loadYieldedNothing(collection: "smallWorks", documentIds: ["a", "b"], parsedCount: 0))
        XCTAssertFalse(LiveSnapshotMerge.loadYieldedNothing(collection: "smallWorks", documentIds: ["a", "b"], parsedCount: 1))
        XCTAssertFalse(LiveSnapshotMerge.loadYieldedNothing(collection: "smallWorks", documentIds: ["INITIAL-PLACEHOLDER"], parsedCount: 0))
        XCTAssertEqual(ReaderDiagnostics.shared.events.count, 1)
        XCTAssertTrue(ReaderDiagnostics.scriptAnswers())
    }

    // MARK: - Read-side causes

    func testANonFiniteNumberNoLongerStopsTheReader() throws {
        let json = try XCTUnwrap(FirebaseBackend.firestoreJSON([
            "dayRate": Double.nan,
            "hourlyRate": Double.infinity,
            "isActive": true,
            "latitude": 51.5,
        ]) as? [String: Any])
        XCTAssertTrue(json["dayRate"] is NSNull)
        XCTAssertTrue(json["hourlyRate"] is NSNull)
        XCTAssertEqual(json["isActive"] as? Bool, true)
        XCTAssertEqual(json["latitude"] as? Double, 51.5)
        XCTAssertTrue(JSONSerialization.isValidJSONObject(json))

        let operative = CanonicalBusinessEngine.parseOperativeDocument(
            documentId: "op-1",
            data: ["firstName": "Ann", "lastName": "Lee", "email": "ann@example.com", "dayRate": Double.nan]
        )
        XCTAssertEqual(operative?.text("firstName"), "Ann", "one NaN field used to make the whole document unreadable")
        let job = FirebaseBackend.jobs(fromDocuments: [(id: "job-1", data: ["siteName": "S", "latitude": Double.nan])], smallWorks: false)
        XCTAssertEqual(job.count, 1)
    }

    func testASmallWorksDocumentTypedCatAIsStillASmallWork() throws {
        let smallWork = try XCTUnwrap(FirebaseBackend.jobs(
            fromDocuments: [(id: "sw-1", data: ["siteName": "Kitchen", "jobType": "CAT A"])],
            smallWorks: true
        ).first)
        XCTAssertEqual(smallWork.jobType, .smallWorks, "the small works listener kept only .smallWorks and dropped this job")
        let project = try XCTUnwrap(FirebaseBackend.jobs(
            fromDocuments: [(id: "p-1", data: ["siteName": "Office", "jobType": "CAT B"])],
            smallWorks: false
        ).first)
        XCTAssertEqual(project.jobType, .catB, "a projects document keeps its stored type")
    }

    func testARosterRowTheRulebookCouldNotReadKeepsTheReadRow() {
        let read = AppUser(id: "u1", email: "a@example.com", organizationId: "org", role: .admin, firstName: "A", isActive: true, passwordSet: true)
        var unread = AppUser(id: "u1", email: "a@example.com", organizationId: "org", role: .viewer, isActive: true, passwordSet: true)
        unread.parsedWithoutRulebook = true
        var stranger = AppUser(id: "u2", email: "b@example.com", organizationId: "org", role: .viewer, isActive: true, passwordSet: true)
        stranger.parsedWithoutRulebook = true

        let kept = UserStore.rosterKeepingReadRows([unread, stranger], onScreen: [read])
        XCTAssertEqual(kept.map(\.id), ["u1", "u2"])
        XCTAssertEqual(kept.first?.role, .admin, "the admin read before keeps their role")
        XCTAssertFalse(kept.first?.parsedWithoutRulebook ?? true)
        XCTAssertTrue(kept.last?.parsedWithoutRulebook ?? false, "nobody to fall back on: the row stays")
        XCTAssertEqual(UserStore.rosterKeepingReadRows([read], onScreen: []), [read])
    }
}
