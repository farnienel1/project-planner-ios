import XCTest
import FirebaseFirestore
@testable import Project_Planner

/// 1.33.1 owner reports (10 Nov): the My Projects ⚙ Save stayed on "Saving…" for ever with Cancel greyed out, and the
/// Projects screen took about 20 s to show the My list. These lock the fixes: the write is exactly the shape the
/// security rules accept, a save never waits longer than `FirestoreWriteAck`'s bound, Cancel is never locked, and a
/// list screen asks the rulebook again only when an input changed.
@MainActor
final class MyWorksPicksSaveTests: XCTestCase {
    private var appRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Project Planner")
    }

    // MARK: Write shape (firestore.rules `worksListPicks`: projects, smallWorks, updatedAt == request.time)

    private static let ruleAllowedKeys: Set<String> = ["projects", "smallWorks", "updatedAt"]

    func testWriteIsMyWorksPicksWriteFieldsWithTheServerTimeAndNothingElse() throws {
        let write = try XCTUnwrap(FirebaseBackend.myWorksPicksWrite(organizationId: " ORG-1 ", uid: "U-1", kind: .projects, ids: ["a", "b", "a"]))
        XCTAssertEqual(write.path, CanonicalBusinessEngine.myWorksPicksPath(organizationId: "ORG-1", uid: "U-1"))
        let rulebook = try XCTUnwrap(CanonicalBusinessEngine.myWorksPicksWriteFields(kind: .projects, ids: ["a", "b", "a"]))
        XCTAssertEqual(Set(write.fields.keys), Set(rulebook.keys), "the rulebook's keys, no write metadata")
        XCTAssertTrue(Set(write.fields.keys).isSubset(of: Self.ruleAllowedKeys))
        XCTAssertEqual(write.fields["projects"] as? [String], rulebook["projects"] as? [String])
        XCTAssertNil(write.fields["smallWorks"], "the other kind is left as stored (merge)")
        XCTAssertTrue(write.fields["updatedAt"] is FieldValue, "updatedAt is the server timestamp, never a client Date")
        XCTAssertNil(write.fields["updatedBy"])
        XCTAssertNil(write.fields["updatedFrom"])

        let small = try XCTUnwrap(FirebaseBackend.myWorksPicksWrite(organizationId: "ORG-1", uid: "U-1", kind: .smallWorks, ids: []))
        XCTAssertEqual(Set(small.fields.keys), ["smallWorks", "updatedAt"])
        XCTAssertEqual(small.fields["smallWorks"] as? [String], [])
    }

    func testNoWriteWithoutAPath() {
        XCTAssertNil(FirebaseBackend.myWorksPicksWrite(organizationId: "", uid: "U-1", kind: .projects, ids: ["a"]))
        XCTAssertNil(FirebaseBackend.myWorksPicksWrite(organizationId: "ORG-1", uid: " ", kind: .projects, ids: ["a"]))
    }

    // MARK: Bounded save

    func testSaveResolvesAsPendingSyncWhenTheServerDoesNotAnswer() async {
        let model = MyWorksPicksModel()
        let task = model.start(timeoutSeconds: 0.2) {
            try await Task.sleep(nanoseconds: 30_000_000_000)
        }
        let outcome = await task.value
        XCTAssertEqual(outcome, .pendingSync)
        XCTAssertTrue(model.pendingSync)
        XCTAssertNil(model.saveError)
    }

    func testRefusedSaveIsShownAndNotPending() async {
        let model = MyWorksPicksModel()
        let outcome = await model.start(timeoutSeconds: 5) {
            throw NSError(domain: "FIRFirestoreErrorDomain", code: 7, userInfo: [NSLocalizedDescriptionKey: "Missing or insufficient permissions."])
        }.value
        guard case .refused(let message) = outcome else { return XCTFail("expected a refusal, got \(outcome)") }
        XCTAssertTrue(message.hasPrefix(MyWorksPicksModel.saveFailedMessage))
        XCTAssertEqual(model.saveError, message)
        XCTAssertFalse(model.pendingSync)
    }

    func testConfirmedSaveClearsPendingAndShowsTheListAtOnce() async {
        let model = MyWorksPicksModel()
        let picks = MyWorksPicks(projects: ["P1"], smallWorks: nil)
        let task = model.start(timeoutSeconds: 5, optimistic: picks) {}
        XCTAssertEqual(model.picks, picks, "the list follows before the server answers")
        let outcome = await task.value
        XCTAssertEqual(outcome, .saved)
        XCTAssertFalse(model.pendingSync)
        XCTAssertNil(model.saveError)
    }

    func testAnOlderSaveNeverOverwritesANewerOnesState() async {
        let model = MyWorksPicksModel()
        let first = model.start(timeoutSeconds: 5) {
            try await Task.sleep(nanoseconds: 100_000_000)
            throw NSError(domain: "x", code: 1, userInfo: [NSLocalizedDescriptionKey: "late"])
        }
        let second = model.start(timeoutSeconds: 5) {}
        _ = await second.value
        _ = await first.value
        XCTAssertNil(model.saveError, "the newer save won")
    }

    // MARK: Listener answers

    func testSnapshotsOnlyPublishWhatChangedAndAnErrorKeepsTheList() {
        let model = MyWorksPicksModel()
        let picks = MyWorksPicks(projects: ["P1"], smallWorks: nil)
        model.receive(picks: picks, error: nil, fromCache: true)
        XCTAssertTrue(model.loaded)
        XCTAssertFalse(model.confirmedByServer)
        model.receive(picks: picks, error: nil, fromCache: false)
        XCTAssertTrue(model.confirmedByServer)
        XCTAssertEqual(model.picks, picks)
        model.receive(picks: .neverSaved, error: "denied", fromCache: false)
        XCTAssertEqual(model.picks, picks, "a read error never drops the shown list to the pre-fill")
        XCTAssertEqual(model.error, "denied")
    }

    // MARK: Cancel and the sheet

    func testCancelIsNeverLockedAndSaveNeverWaits() throws {
        XCTAssertTrue(MyWorksPickerSheet.cancelAlwaysEnabled)
        let source = try String(contentsOf: appRoot.appendingPathComponent("Views/MyWorksPickerSheet.swift"), encoding: .utf8)
        XCTAssertFalse(source.contains("disabled(saving)"), "Cancel is never tied to a saving state")
        XCTAssertFalse(source.contains("Saving…"), "Save never waits for the server")
        XCTAssertFalse(source.contains("try await onSave"), "Save hands the write to Firestore and returns")
        XCTAssertFalse(source.contains("myWorksPickerRows("), "the rows are a snapshot passed in, never computed by the sheet")
    }

    // MARK: List screen cache

    private func job(_ id: String, smallWorks: Bool = false, _ data: [String: Any]) throws -> Project {
        try XCTUnwrap(FirebaseBackend.jobs(fromDocuments: [(id: id, data: data)], smallWorks: smallWorks).first)
    }

    private func inputs(projects: [Project], deadlineJobIds: [String] = []) -> WorksListScreenInputs {
        let role = CanonicalBusinessEngine.CanonicalStaffAccountRole(isSuperAdmin: false, isAdmin: false, isManager: true, isOperativeMode: false)
        let viewer = JobAccessViewer(role: role, projectsToggle: false, smallWorksToggle: false, uid: "U-M", ids: ["U-M"], email: "u-m@x.t")
        return WorksListScreenInputs(
            kind: .projects,
            projects: projects,
            smallWorks: [],
            viewer: viewer,
            operatives: [],
            bookings: [],
            managerSiteBookings: [],
            tasks: [],
            deadlineJobIds: deadlineJobIds
        )
    }

    func testListAnswersAreAskedOncePerInputChangeNotPerRender() throws {
        let projects = [try job("P1", ["managerUserIds": ["U-M"]]), try job("P2", ["managerUserIds": ["X"]])]
        let cache = WorksListScreenCache()
        let first = inputs(projects: projects)
        for _ in 0..<20 {
            _ = cache.answers(first)
            _ = cache.myList(first, picks: .neverSaved, loaded: true)
        }
        XCTAssertEqual(cache.baseComputations, 1)
        XCTAssertEqual(cache.myListComputations, 1)
        XCTAssertEqual(cache.myList(first, picks: .neverSaved, loaded: true).map(\.documentId), ["P1"], "pre-filled with the jobs they manage")
        XCTAssertEqual(cache.answers(first).visible.map(\.documentId), ["P1", "P2"])

        // New picks: only `myWorksList` is asked again.
        let saved = MyWorksPicks(projects: ["P2"], smallWorks: nil)
        XCTAssertEqual(cache.myList(first, picks: saved, loaded: true).map(\.documentId), ["P2"])
        XCTAssertEqual(cache.baseComputations, 1)
        XCTAssertEqual(cache.myListComputations, 2)

        // A store change: asked again once.
        let changed = inputs(projects: projects, deadlineJobIds: ["P2"])
        _ = cache.answers(changed)
        _ = cache.answers(changed)
        XCTAssertEqual(cache.baseComputations, 2)
    }

    func testPickerRowsAreTheRulebooksAnswer() throws {
        let projects = [try job("P1", ["managerUserIds": ["U-M"]]), try job("P2", ["managerUserIds": ["X"]])]
        let cache = WorksListScreenCache()
        let rows = cache.pickerRows(inputs(projects: projects), picks: .neverSaved)
        XCTAssertEqual(rows.map(\.job.documentId), ["P1", "P2"])
        XCTAssertEqual(rows.map(\.picked), [true, false])
    }
}
