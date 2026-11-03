import XCTest
@testable import Project_Planner

/// Owner report (3 Nov 2026): a small works job web lists was missing on iOS ("this can never happen again").
/// Every job document goes through the rulebook reader (`parseJobDocument`) and the job list (`workDocuments`, by id
/// only, never by job number). These lock the iOS-only places a document the reader accepts was still hidden:
/// 1. `ProjectStore.smallWorks` kept `isLive` jobs only; web's Small works list keeps inactive jobs (Completed tab).
/// 2. Inactive jobs were in no status chip but All, and All's count left them out; web counts them under Completed.
/// 3. A `smallWorks` document sharing its id with a `projects` document was dropped from Small works.
/// Reader results were checked with Node against the packed `canonical-business.js` (rulebook 1.19.0).
@MainActor
final class JobVisibilityParityTests: XCTestCase {
    private func smallWork(_ id: String, _ data: [String: Any]) throws -> Project {
        try XCTUnwrap(FirebaseBackend.jobs(fromDocuments: [(id: id, data: data)], smallWorks: true).first)
    }

    private func project(_ id: String, _ data: [String: Any]) throws -> Project {
        try XCTUnwrap(FirebaseBackend.jobs(fromDocuments: [(id: id, data: data)], smallWorks: false).first)
    }

    // MARK: - The reader accepts what web stores

    func testTheReaderKeepsABareWebSmallWorksDocument() throws {
        // Node: parseJobDocument('sw-1', {}, { kind: 'smallWorks' }) → a row (no job number, no site name, live).
        let job = try smallWork("sw-1", [:])
        XCTAssertEqual(job.jobType, .smallWorks)
        XCTAssertEqual(job.documentId, "sw-1")
        XCTAssertTrue(job.isLive)
    }

    func testTheReaderKeepsTextDatesAndATextLiveFlag() throws {
        // Node: startDayKey 2026-11-03, endDayKey 2026-11-10, isLive false.
        let job = try smallWork("sw-2", ["startDate": "2026-11-03", "endDate": "2026-11-10", "isLive": "false", "siteName": "TEST-Boiler"])
        XCTAssertFalse(job.isLive)
        XCTAssertEqual(job.status, .inactive)
        XCTAssertEqual(job.siteName, "TEST-Boiler")
    }

    func testOnlyTheLegacyPlaceholderAndABlankIdAreRefused() {
        XCTAssertTrue(FirebaseBackend.jobs(fromDocuments: [(id: "INITIAL-PLACEHOLDER", data: [:])], smallWorks: true).isEmpty)
        XCTAssertEqual(FirebaseBackend.jobRefusalReason(documentId: "INITIAL-PLACEHOLDER"), "legacy placeholder document (workDocuments)")
        XCTAssertEqual(FirebaseBackend.jobRefusalReason(documentId: "  "), "blank document id")
    }

    // MARK: - 1. Inactive small works stay listed

    func testAnInactiveSmallWorksJobIsOnTheSmallWorksList() throws {
        let store = ProjectStore()
        let off = try smallWork("sw-off", ["siteName": "TEST-Switched off", "isLive": false])
        let on = try smallWork("sw-on", ["siteName": "TEST-Live"])
        store.projects = [on, off]
        XCTAssertEqual(Set(store.smallWorks.map(\.documentId)), ["sw-on", "sw-off"], "web lists inactive small works (Completed tab)")
        XCTAssertEqual(store.jobDocumentCountsLine, "Projects 0 · Small works 2")
    }

    // MARK: - 2. Status chips group inactive under Completed (web `filterWorksByTab` / `countWorksByTab`)

    func testInactiveJobsCountAndFilterUnderCompleted() throws {
        let off = try smallWork("sw-off", ["isLive": false])
        let live = try smallWork("sw-live", ["startDate": "2020-01-01", "endDate": "2099-12-31"])
        let counts = WorksListStatusCounts.from([off, live])
        XCTAssertEqual(counts.all, 2, "All is every job on the list")
        XCTAssertEqual(counts.completed, 1)
        XCTAssertTrue(WorksListStatusCounts.matches(off, chip: .completed))
        XCTAssertFalse(WorksListStatusCounts.matches(off, chip: .active))
        XCTAssertTrue(WorksListStatusCounts.matches(off, chip: nil))
        XCTAssertTrue(WorksListStatusCounts.matches(live, chip: .active))
    }

    // MARK: - 3. A small works document sharing a project's id

    func testASmallWorksDocumentSharingAProjectIdStaysOnSmallWorks() throws {
        let sharedId = "6F1C2B3A-1111-4222-8333-444455556666"
        let asProject = try project(sharedId, ["siteName": "TEST-Shared", "jobType": "CAT A"])
        let asSmallWork = try smallWork(sharedId.lowercased(), ["siteName": "TEST-Shared"])
        // The store keeps one row per id (the project), as `workDocuments` does.
        let store = ProjectWorksMerge.uniqueWorks([asSmallWork, asProject])
        XCTAssertEqual(store.count, 1)
        XCTAssertNotEqual(store.first?.jobType, .smallWorks)
        // The Small works list still shows the small works document, as web's Small works list does.
        let list = ProjectWorksMerge.smallWorksList(store: store, smallWorksDocuments: [asSmallWork])
        XCTAssertEqual(list.map(\.documentId), [sharedId.lowercased()])
        XCTAssertEqual(list.first?.jobType, .smallWorks)
    }

    func testTheSmallWorksListNeverDoublesAJobItAlreadyHas() throws {
        let job = try smallWork("sw-1", ["siteName": "TEST-One"])
        let list = ProjectWorksMerge.smallWorksList(store: [job], smallWorksDocuments: [job])
        XCTAssertEqual(list.count, 1)
        // A small works document no longer in the store (deleted here) is not brought back by the last read.
        XCTAssertTrue(ProjectWorksMerge.smallWorksList(store: [], smallWorksDocuments: [job]).isEmpty)
    }

    // MARK: - Never by job number

    func testTwoSmallWorksSharingAJobNumberAreBothKept() throws {
        // Node: workDocuments([{ id: 'a', jobNumber: 'C646' }], [{ id: 'b', jobNumber: 'C646' }]) keeps both.
        let first = try smallWork("sw-c646-a", ["jobNumber": "C646", "siteName": "TEST-A"])
        let second = try smallWork("sw-c646-b", ["jobNumber": "C646", "siteName": "TEST-B"])
        let kept = ProjectWorksMerge.uniqueWorks([first, second])
        XCTAssertEqual(Set(kept.map(\.documentId)), ["sw-c646-a", "sw-c646-b"])
        let store = ProjectStore()
        store.projects = kept
        XCTAssertEqual(store.smallWorks.count, 2)
    }
}
