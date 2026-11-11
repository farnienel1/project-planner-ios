import XCTest
@testable import Project_Planner

/// iOS 1.37.1 (owner report 11 Nov, TestFlight build 2, "Rules 1.37.0"): during a long session, Projects showed 6 while
/// web showed 7 — 1 Carnaby Street was missing — and only a cold start brought it back. The app was open across two
/// rules publishes and the deletion of C716's stale `projects` copy.
///
/// The store's only in-session read of the job collections is the live listener. A server snapshot is taken as the
/// whole collection, so a snapshot that left out a job the server still holds removed it, and nothing read the
/// collection again until a restart (`loadData` runs at launch, on pull-to-refresh and from Settings). These tests
/// drive `ProjectStore.applyLiveWorkSlice` with snapshots as the listener delivers them.
@MainActor
final class ProjectStoreLiveListTests: XCTestCase {
    private final class ReadLog {
        var ids: [String] = []
    }

    private func job(_ index: Int, smallWorks: Bool, id: String? = nil) throws -> Project {
        let documentId = id ?? String(format: "00000000-0000-4000-8000-%012ld", index + (smallWorks ? 100 : 0))
        let name = smallWorks ? "TEST-SW-\(index)" : "TEST-P-\(index)"
        return try XCTUnwrap(
            FirebaseBackend.jobs(fromDocuments: [(id: documentId, data: ["jobNumber": name, "siteName": name])], smallWorks: smallWorks).first
        )
    }

    private func projectRows(_ store: ProjectStore) -> [Project] {
        store.projects.filter { !$0.isSmallWorksDocument }
    }

    private func smallWorksRows(_ store: ProjectStore) -> [Project] {
        store.projects.filter { $0.isSmallWorksDocument }
    }

    // MARK: A snapshot that drops a live job

    func testServerSnapshotThatDropsAJobTheServerStillHoldsIsCheckedAndRestored() async throws {
        let store = ProjectStore()
        let seven = try (0..<7).map { try job($0, smallWorks: false) }
        let carnaby = seven[3]
        let log = ReadLog()
        store.serverJobRead = { smallWorks, documentId in
            log.ids.append(documentId)
            return !smallWorks && documentId == carnaby.documentId ? .exists(carnaby) : .gone
        }

        store.applyLiveWorkSlice(seven, smallWorks: false, fromCache: false, rowCount: 7)
        XCTAssertEqual(projectRows(store).count, 7)

        // The listener delivers a server snapshot without the job (the document is still on the server).
        store.applyLiveWorkSlice(seven.filter { $0.id != carnaby.id }, smallWorks: false, fromCache: false, rowCount: 6)
        await store.removalCheckTask?.value

        XCTAssertEqual(log.ids, [carnaby.documentId], "the dropped job is read again from the server, once")
        XCTAssertEqual(projectRows(store).count, 7, "the job the server still holds is back on the list in this session")
        XCTAssertTrue(projectRows(store).contains { $0.id == carnaby.id })
    }

    /// The failure as shipped: when nothing can confirm the job (no server answer), the list stays short and no other
    /// in-session path restores it — the owner's "6 until a cold start".
    func testWithoutAServerAnswerTheDroppedJobStaysOffTheListAsBefore() async throws {
        let store = ProjectStore()
        let seven = try (0..<7).map { try job($0, smallWorks: false) }
        store.serverJobRead = { _, _ in .unknown }
        store.applyLiveWorkSlice(seven, smallWorks: false, fromCache: false, rowCount: 7)
        store.applyLiveWorkSlice(Array(seven.dropLast()), smallWorks: false, fromCache: false, rowCount: 6)
        await store.removalCheckTask?.value
        XCTAssertEqual(projectRows(store).count, 6)
    }

    func testAJobDeletedOnTheServerStaysRemoved() async throws {
        let store = ProjectStore()
        let seven = try (0..<7).map { try job($0, smallWorks: false) }
        store.serverJobRead = { _, _ in .gone }
        store.applyLiveWorkSlice(seven, smallWorks: false, fromCache: false, rowCount: 7)
        store.applyLiveWorkSlice(Array(seven.dropLast()), smallWorks: false, fromCache: false, rowCount: 6)
        await store.removalCheckTask?.value
        XCTAssertEqual(projectRows(store).count, 6)
    }

    func testACacheSnapshotNeverTriggersARead() async throws {
        let store = ProjectStore()
        let seven = try (0..<7).map { try job($0, smallWorks: false) }
        let log = ReadLog()
        store.serverJobRead = { _, documentId in
            log.ids.append(documentId)
            return .gone
        }
        store.applyLiveWorkSlice(seven, smallWorks: false, fromCache: false, rowCount: 7)
        store.applyLiveWorkSlice(Array(seven.dropLast()), smallWorks: false, fromCache: true, rowCount: 6)
        await store.removalCheckTask?.value
        XCTAssertEqual(log.ids, [])
        XCTAssertEqual(projectRows(store).count, 7, "a shorter cache snapshot only adds and updates")
    }

    // MARK: C716: a `projects` and a `smallWorks` document with one id

    private func storeWithTwin() throws -> (store: ProjectStore, twinProject: Project, twinSmallWorks: Project) {
        let store = ProjectStore()
        let twinId = "94472FA5-B93D-4EC5-B60E-F798AD5E490C"
        var projects = try (0..<7).map { try job($0, smallWorks: false) }
        let twinProject = try job(7, smallWorks: false, id: twinId)
        projects.append(twinProject)
        var smallWorks = try (0..<3).map { try job($0, smallWorks: true) }
        let twinSmallWorks = try job(3, smallWorks: true, id: twinId)
        smallWorks.append(twinSmallWorks)
        store.serverJobRead = { _, _ in .gone }
        store.applyLiveWorkSlice(projects, smallWorks: false, fromCache: false, rowCount: projects.count)
        store.applyLiveWorkSlice(smallWorks, smallWorks: true, fromCache: false, rowCount: smallWorks.count)
        return (store, twinProject, twinSmallWorks)
    }

    func testRemovingTheProjectsCopyOfATwinKeepsTheSmallWorksJobInTheStore() async throws {
        let (store, twinProject, _) = try storeWithTwin()
        XCTAssertEqual(projectRows(store).count, 8)
        XCTAssertEqual(smallWorksRows(store).count, 3, "uniqueWorks keeps one row per id: the project")

        // Owner deleted the stale `projects` copy (web PR #298 script); the projects listener delivers 7.
        let remaining = projectRows(store).filter { $0.id != twinProject.id }
        store.applyLiveWorkSlice(remaining, smallWorks: false, fromCache: false, rowCount: remaining.count)
        await store.removalCheckTask?.value

        XCTAssertEqual(projectRows(store).count, 7)
        XCTAssertEqual(smallWorksRows(store).count, 4, "the small works document comes back without another small works snapshot")
        XCTAssertTrue(smallWorksRows(store).contains { $0.id == twinProject.id })
        XCTAssertEqual(store.smallWorks.count, 4)
    }

    func testDeletingTheSmallWorksJobTrimsTheSmallWorksReadSoAProjectsSnapshotNeverBringsItBack() async throws {
        let (store, twinProject, twinSmallWorks) = try storeWithTwin()
        let remaining = projectRows(store).filter { $0.id != twinProject.id }
        store.applyLiveWorkSlice(remaining, smallWorks: false, fromCache: false, rowCount: remaining.count)
        await store.removalCheckTask?.value
        XCTAssertTrue(smallWorksRows(store).contains { $0.id == twinSmallWorks.id })

        await store.deleteProject(twinSmallWorks)
        XCTAssertFalse(store.smallWorks.contains { $0.id == twinSmallWorks.id })

        // Any later projects snapshot (one job changed on web).
        var changed = remaining
        changed[0].siteName = "TEST-P-0 renamed"
        store.applyLiveWorkSlice(changed, smallWorks: false, fromCache: false, rowCount: changed.count)
        await store.removalCheckTask?.value

        XCTAssertFalse(store.projects.contains { $0.id == twinSmallWorks.id }, "a job deleted here never comes back")
        XCTAssertFalse(store.smallWorks.contains { $0.id == twinSmallWorks.id })
        XCTAssertEqual(projectRows(store).count, 7)
    }

    // MARK: Pure helpers

    func testRemovedRowsComparesCollectionAndId() throws {
        let project = try job(0, smallWorks: false, id: "AAAAAAAA-0000-4000-8000-000000000001")
        let smallWorks = try job(0, smallWorks: true, id: "AAAAAAAA-0000-4000-8000-000000000001")
        XCTAssertEqual(ProjectWorksMerge.removedRows(existingSlice: [project], nextSlice: [smallWorks]).map(\.id), [project.id])
        XCTAssertEqual(ProjectWorksMerge.removedRows(existingSlice: [project], nextSlice: [project]).count, 0)
    }

    func testAOneOffLoadNeverReplacesANewerListenerSnapshot() throws {
        let remote = [try job(0, smallWorks: false)]
        XCTAssertNil(ProjectWorksMerge.loadSlice(remote: remote, liveServerSnapshotDuringLoad: true))
        XCTAssertEqual(ProjectWorksMerge.loadSlice(remote: remote, liveServerSnapshotDuringLoad: false)?.count, 1)
        XCTAssertNil(ProjectWorksMerge.loadSlice(remote: nil, liveServerSnapshotDuringLoad: false))
    }
}
