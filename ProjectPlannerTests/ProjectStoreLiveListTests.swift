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

    func testLoadSliceKeepsTheLiveSliceAndListsTheJobsItLacks() throws {
        let live = [try job(0, smallWorks: false)]
        let read = [try job(0, smallWorks: false), try job(1, smallWorks: false)]
        let during = ProjectWorksMerge.loadSlice(remote: read, liveServerSnapshotDuringLoad: true, currentSlice: live)
        XCTAssertNil(during.slice)
        XCTAssertEqual(during.toConfirm.map(\.id), [read[1].id])
        let quiet = ProjectWorksMerge.loadSlice(remote: read, liveServerSnapshotDuringLoad: false, currentSlice: live)
        XCTAssertEqual(quiet.slice?.count, 2)
        XCTAssertEqual(quiet.toConfirm.count, 0)
        XCTAssertNil(ProjectWorksMerge.loadSlice(remote: nil, liveServerSnapshotDuringLoad: true, currentSlice: live).slice)
    }

    func testSmallWorksBesideProjectsHoldsOnlySmallWorksOncePerIdStoreFirst() throws {
        let sharedId = "BBBBBBBB-0000-4000-8000-000000000001"
        let project = try job(0, smallWorks: false, id: sharedId)
        var storeCopy = try job(1, smallWorks: true)
        storeCopy.siteName = "store copy"
        var readCopy = storeCopy
        readCopy.siteName = "read copy"
        let twin = try job(2, smallWorks: true, id: sharedId)
        let rows = ProjectWorksMerge.smallWorksBesideProjects(
            store: [project, storeCopy],
            smallWorksDocuments: [readCopy, twin, project]
        )
        XCTAssertTrue(rows.allSatisfy(\.isSmallWorksDocument), "never a projects row")
        XCTAssertEqual(Set(rows.map(\.id)).count, rows.count, "each id once")
        XCTAssertEqual(rows.first { $0.id == storeCopy.id }?.siteName, "store copy", "the store's row wins")
        let store = ProjectWorksMerge.uniqueWorks([project] + rows)
        XCTAssertEqual(store.filter { $0.id == project.id }.map(\.isSmallWorksDocument), [false], "a live twin stays folded")
    }

    // MARK: Review #212: what a removal check may restore

    private func storeWithSeven() throws -> (ProjectStore, [Project], Project) {
        let store = ProjectStore()
        let seven = try (0..<7).map { try job($0, smallWorks: false) }
        store.applyLiveWorkSlice(seven, smallWorks: false, fromCache: false, rowCount: 7)
        return (store, seven, seven[3])
    }

    func testALocalDeleteWhileTheServerReadIsInFlightStaysGone() async throws {
        let (store, seven, carnaby) = try storeWithSeven()
        store.serverJobRead = { [unowned store] _, _ in
            await store.deleteProject(carnaby)
            return .exists(carnaby)
        }
        store.applyLiveWorkSlice(seven.filter { $0.id != carnaby.id }, smallWorks: false, fromCache: false, rowCount: 6)
        await store.removalCheckTask?.value
        XCTAssertFalse(store.projects.contains { $0.id == carnaby.id })
    }

    func testAnOrganisationSwitchDuringTheCheckRestoresNothing() async throws {
        let (store, seven, carnaby) = try storeWithSeven()
        store.serverJobRead = { [unowned store] _, _ in
            store.discardInMemoryForOrganizationSwitch()
            return .exists(carnaby)
        }
        store.applyLiveWorkSlice(seven.filter { $0.id != carnaby.id }, smallWorks: false, fromCache: false, rowCount: 6)
        await store.removalCheckTask?.value
        XCTAssertTrue(store.projects.isEmpty, "the next company's store gets nothing from the previous company")
    }

    func testAnOperativePlanNeverReadsOrRestores() async throws {
        let (store, seven, carnaby) = try storeWithSeven()
        let log = ReadLog()
        store.readsWholeJobCollectionCheck = { _ in false }
        store.serverJobRead = { _, documentId in
            log.ids.append(documentId)
            return .exists(carnaby)
        }
        store.applyLiveWorkSlice(seven.filter { $0.id != carnaby.id }, smallWorks: false, fromCache: false, rowCount: 6)
        await store.removalCheckTask?.value
        XCTAssertEqual(log.ids, [])
        XCTAssertEqual(projectRows(store).count, 6)
    }

    func testAViewerDemotedToOperativeDuringTheReadGetsNothingRestored() async throws {
        let (store, seven, carnaby) = try storeWithSeven()
        final class Flag { var whole = true }
        let flag = Flag()
        store.readsWholeJobCollectionCheck = { _ in flag.whole }
        store.serverJobRead = { _, _ in
            flag.whole = false
            return .exists(carnaby)
        }
        store.applyLiveWorkSlice(seven.filter { $0.id != carnaby.id }, smallWorks: false, fromCache: false, rowCount: 6)
        await store.removalCheckTask?.value
        XCTAssertFalse(store.projects.contains { $0.id == carnaby.id })
    }

    func testAConfirmedJobIsKeptOnLaterSnapshotsWithoutAnotherReadUntilTheWindowEnds() async throws {
        let (store, seven, carnaby) = try storeWithSeven()
        let log = ReadLog()
        var clock = Date(timeIntervalSince1970: 1_000_000)
        store.now = { clock }
        store.serverJobRead = { _, documentId in
            log.ids.append(documentId)
            return .exists(carnaby)
        }
        var short = seven.filter { $0.id != carnaby.id }
        store.applyLiveWorkSlice(short, smallWorks: false, fromCache: false, rowCount: 6)
        await store.removalCheckTask?.value
        XCTAssertEqual(projectRows(store).count, 7)

        // The listener's view still lacks it: the next snapshot keeps it, no flicker, no read.
        short[0].siteName = "TEST-P-0 renamed"
        store.applyLiveWorkSlice(short, smallWorks: false, fromCache: false, rowCount: 6)
        await store.removalCheckTask?.value
        XCTAssertEqual(projectRows(store).count, 7)
        XCTAssertEqual(log.ids.count, 1)

        // After the window it is read again.
        clock = clock.addingTimeInterval(ProjectStore.confirmedJobKeepSeconds + 1)
        short[0].siteName = "TEST-P-0 renamed again"
        store.applyLiveWorkSlice(short, smallWorks: false, fromCache: false, rowCount: 6)
        await store.removalCheckTask?.value
        XCTAssertEqual(log.ids.count, 2)
        XCTAssertEqual(projectRows(store).count, 7)
    }

    func testANewerSnapshotDuringTheReadIsReadOnceMoreThenRestored() async throws {
        let (store, seven, carnaby) = try storeWithSeven()
        let log = ReadLog()
        var short = seven.filter { $0.id != carnaby.id }
        store.serverJobRead = { [unowned store] _, documentId in
            log.ids.append(documentId)
            if log.ids.count == 1 {
                short[0].siteName = "TEST-P-0 changed during the read"
                store.applyLiveWorkSlice(short, smallWorks: false, fromCache: false, rowCount: 6)
            }
            return .exists(carnaby)
        }
        store.applyLiveWorkSlice(short, smallWorks: false, fromCache: false, rowCount: 6)
        await store.removalCheckTask?.value
        XCTAssertEqual(log.ids.count, 2)
        XCTAssertTrue(projectRows(store).contains { $0.id == carnaby.id })
    }

    func testASecondNewerSnapshotDuringTheReadsSkipsTheRestore() async throws {
        let (store, seven, carnaby) = try storeWithSeven()
        let log = ReadLog()
        var short = seven.filter { $0.id != carnaby.id }
        store.serverJobRead = { [unowned store] _, documentId in
            log.ids.append(documentId)
            short[0].siteName = "TEST-P-0 change \(log.ids.count)"
            store.applyLiveWorkSlice(short, smallWorks: false, fromCache: false, rowCount: 6)
            return .exists(carnaby)
        }
        store.applyLiveWorkSlice(short, smallWorks: false, fromCache: false, rowCount: 6)
        await store.removalCheckTask?.value
        XCTAssertEqual(log.ids.count, 2)
        XCTAssertFalse(projectRows(store).contains { $0.id == carnaby.id })
    }

    // MARK: Review #212: a load while the listener answers

    func testALoadDuringALiveSnapshotKeepsTheLiveSliceAndAddsConfirmedMissingJobs() async throws {
        let store = ProjectStore()
        let seven = try (0..<7).map { try job($0, smallWorks: false) }
        let carnaby = seven[3]
        let goneOnServer = try job(9, smallWorks: false)
        store.serverJobRead = { _, documentId in
            documentId == carnaby.documentId ? .exists(carnaby) : .gone
        }
        let start = store.liveServerSnapshotCounts
        // The listener answers during the read, without the job, and with a newer copy of another.
        var live = seven.filter { $0.id != carnaby.id }
        live[0].siteName = "TEST-P-0 live"
        store.applyLiveWorkSlice(live, smallWorks: false, fromCache: false, rowCount: 6)
        await store.removalCheckTask?.value

        // The read (older) holds the job, a job gone since, and the old copy.
        store.applyWorkLoad(remoteProjects: seven + [goneOnServer], remoteSmallWorks: nil, liveSnapshotsAtStart: start)
        await store.removalCheckTask?.value

        XCTAssertTrue(projectRows(store).contains { $0.id == carnaby.id }, "a confirmed missing job is added")
        XCTAssertFalse(projectRows(store).contains { $0.id == goneOnServer.id }, "a job gone on the server is not")
        XCTAssertEqual(projectRows(store).first { $0.id == live[0].id }?.siteName, "TEST-P-0 live", "the live slice is kept")
        XCTAssertEqual(projectRows(store).count, 7)
    }

    func testALoadWithoutALiveSnapshotReplacesTheSliceAsBefore() async throws {
        let store = ProjectStore()
        let seven = try (0..<7).map { try job($0, smallWorks: false) }
        store.applyLiveWorkSlice(Array(seven.prefix(6)), smallWorks: false, fromCache: false, rowCount: 6)
        let start = store.liveServerSnapshotCounts
        store.applyWorkLoad(remoteProjects: seven, remoteSmallWorks: nil, liveSnapshotsAtStart: start)
        await store.removalCheckTask?.value
        XCTAssertEqual(projectRows(store).count, 7)
    }
}
