import XCTest
import FirebaseFirestore
@testable import Project_Planner

/// Owner decision 23 Nov: the iPhone VO tracker reorders as web does (RULEBOOK 1.52.0 / 1.63.0 §22). The plan, the
/// refusals and the writes come from the packed rulebook; these tests lock the wiring and the save's shape.
@MainActor
final class VariationTrackerDragTests: XCTestCase {
    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    }

    private func source(_ path: String) throws -> String {
        try String(contentsOf: repoRoot.appendingPathComponent(path), encoding: .utf8)
    }

    private func role(admin: Bool = false, superAdmin: Bool = false, manager: Bool = false, operative: Bool = false) -> CanonicalBusinessEngine.CanonicalStaffAccountRole {
        .init(isSuperAdmin: superAdmin, isAdmin: admin, isManager: manager, isOperativeMode: operative)
    }

    // MARK: Who

    func testCanRenumberVariationsIsAdminsAndTheJobsManagers() {
        XCTAssertTrue(CanonicalBusinessEngine.canRenumberVariations(role(admin: true), managesJob: false))
        XCTAssertTrue(CanonicalBusinessEngine.canRenumberVariations(role(superAdmin: true), managesJob: false))
        XCTAssertTrue(CanonicalBusinessEngine.canRenumberVariations(role(manager: true), managesJob: true))
        XCTAssertFalse(CanonicalBusinessEngine.canRenumberVariations(role(manager: true), managesJob: false), "a manager of another job")
        XCTAssertFalse(CanonicalBusinessEngine.canRenumberVariations(role(operative: true), managesJob: true))
        XCTAssertFalse(CanonicalBusinessEngine.canRenumberVariations(role(admin: true, operative: true), managesJob: true), "operative mode")
    }

    func testReorderIsOnlineOnly() {
        XCTAssertEqual(OfflinePolicy.availability(UnlistedOfflineAction.renumberVariations), .onlineOnly)
        XCTAssertFalse(OfflinePolicy.isEnabled(.renumberVariations, isOnline: false))
        XCTAssertTrue(OfflinePolicy.isEnabled(.renumberVariations, isOnline: true))
    }

    // MARK: Plan

    func testDraggedOrderRenumbersOpenVariations() throws {
        let rows = [
            LogicFixtures.variation(id: "A", voNumber: "VO-001", sequence: 1),
            LogicFixtures.variation(id: "B", voNumber: "VO-002", sequence: 2),
            LogicFixtures.variation(id: "C", voNumber: "VO-003", sequence: 3),
        ].map(\.rulebookInput)
        let plan = try XCTUnwrap(CanonicalBusinessEngine.variationRenumberPlanChanges(
            rows: rows, order: ["C", "A", "B"], prefix: "VO-", padding: 3, orderLocked: false
        ))
        XCTAssertNil(plan.refused)
        XCTAssertEqual(plan.rows.map(\.id), ["C", "A", "B"])
        XCTAssertEqual(plan.rows.map(\.to), ["VO-001", "VO-002", "VO-003"])
        XCTAssertEqual(Set(plan.changes.map(\.id)), ["A", "B", "C"])
        XCTAssertEqual(plan.changes.first(where: { $0.id == "C" })?.sequence, 1)
    }

    func testOpeningTheTrackerPlansNoChange() throws {
        let rows = [
            LogicFixtures.variation(id: "A", voNumber: "VO-001", sequence: 1),
            LogicFixtures.variation(id: "B", voNumber: "VO-002", sequence: 2),
        ].map(\.rulebookInput)
        let plan = try XCTUnwrap(CanonicalBusinessEngine.variationRenumberPlanChanges(
            rows: rows, order: [], prefix: "VO-", padding: 3, orderLocked: false
        ))
        XCTAssertTrue(plan.changes.isEmpty)
        XCTAssertTrue(plan.rows.allSatisfy { !$0.changed })
    }

    func testPinnedVariationNeverMovesAndALockedOrderIsRefused() throws {
        let rows = [
            LogicFixtures.variation(id: "A", voNumber: "VO-001", sequence: 1),
            LogicFixtures.variation(id: "B", voNumber: "VO-002", sequence: 2, status: .submitted),
            LogicFixtures.variation(id: "C", voNumber: "VO-003", sequence: 3),
        ].map(\.rulebookInput)
        let moved = try XCTUnwrap(CanonicalBusinessEngine.variationRenumberPlanChanges(
            rows: rows, order: ["B", "A", "C"], prefix: "VO-", padding: 3, orderLocked: false
        ))
        XCTAssertEqual(moved.refused, CanonicalBusinessEngine.variationPinnedMessage)
        XCTAssertFalse(CanonicalBusinessEngine.variationPinnedMessage.isEmpty)

        // Open rows swap around the pinned one; it keeps its place and number.
        let around = try XCTUnwrap(CanonicalBusinessEngine.variationRenumberPlanChanges(
            rows: rows, order: ["C", "A"], prefix: "VO-", padding: 3, orderLocked: false
        ))
        XCTAssertNil(around.refused)
        XCTAssertEqual(around.rows.map(\.id), ["C", "B", "A"])
        XCTAssertEqual(around.rows.map(\.to), ["VO-001", "VO-002", "VO-003"])

        let locked = try XCTUnwrap(CanonicalBusinessEngine.variationRenumberPlanChanges(
            rows: rows, order: ["C", "A"], prefix: "VO-", padding: 3, orderLocked: true
        ))
        XCTAssertEqual(locked.refused, CanonicalBusinessEngine.variationOrderLockedMessage)
    }

    func testPinnedMoveTextNamesTheStatus() {
        let text = CanonicalBusinessEngine.variationPinnedMoveText(voNumber: "VO-003", status: "submitted")
        XCTAssertEqual(text, "VO-003 is submitted and locked. \(CanonicalBusinessEngine.variationPinnedMessage)")
        XCTAssertEqual(CanonicalBusinessEngine.variationPinnedMoveText(voNumber: "VO-001", status: "open"), CanonicalBusinessEngine.variationPinnedMessage)
    }

    // MARK: Refusals

    func testConflictWhenTheVariationsChangedSinceLoad() throws {
        let base = [LogicFixtures.variation(id: "A", voNumber: "VO-001", sequence: 1)]
        var changed = base
        changed[0].sequence = 4
        XCTAssertEqual(CanonicalBusinessEngine.variationRenumberConflict(base: base.map(\.rulebookInput), live: base.map(\.rulebookInput)), false)
        XCTAssertEqual(CanonicalBusinessEngine.variationRenumberConflict(base: base.map(\.rulebookInput), live: changed.map(\.rulebookInput)), true)
        XCTAssertEqual(CanonicalBusinessEngine.variationRenumberStaleMessage, "Someone else changed the variations — reload")
    }

    func testStaleNumberLocksAreOpenVariationsOnly() throws {
        var reopened = LogicFixtures.variation(id: "A", voNumber: "VO-001", sequence: 1)
        reopened.voNumberLocked = true
        let submitted = LogicFixtures.variation(id: "B", voNumber: "VO-002", sequence: 2, status: .submitted)
        let stale = try XCTUnwrap(CanonicalBusinessEngine.variationStaleNumberLocks(rows: [reopened, submitted].map(\.rulebookInput)))
        XCTAssertEqual(stale, ["A"])
    }

    func testChangedRowWithOnlySettingsCopiesRefusesTheSave() throws {
        let change = RulebookVariationPlanRow(id: "X", from: "VO-003", to: "VO-001", changed: true, pinned: false, sequence: 1)
        let refused = try XCTUnwrap(CanonicalBusinessEngine.variationRenumberMissingRefusal(changes: [change], storedIds: []))
        XCTAssertTrue(refused?.contains("VO-003") == true)
        let fine = try XCTUnwrap(CanonicalBusinessEngine.variationRenumberMissingRefusal(changes: [change], storedIds: ["x"]))
        XCTAssertNil(fine, "ids compare without case")
    }

    // MARK: Writes

    func testRenumberWriteAppendsHistoryAndKeepsAPinnedNumber() throws {
        let at = Timestamp(date: Date(timeIntervalSince1970: 1_800_000_000))
        let open: [String: Any] = ["voNumber": "VO-003", "sequence": 3, "status": "open", "numberHistory": []]
        let write = try XCTUnwrap(CanonicalBusinessEngine.variationRenumberWriteFields(stored: open, to: "VO-001", sequence: 1, at: at, byUid: "u1"))
        let set = try XCTUnwrap(write)
        XCTAssertEqual(set["voNumber"] as? String, "VO-001")
        XCTAssertEqual((set["sequence"] as? NSNumber)?.intValue, 1)
        let history = try XCTUnwrap(set["numberHistory"] as? [[String: Any]])
        XCTAssertEqual(history.count, 1)
        XCTAssertEqual(history.first?["from"] as? String, "VO-003")
        XCTAssertEqual(history.first?["to"] as? String, "VO-001")
        XCTAssertEqual(history.first?["byUid"] as? String, "u1")
        XCTAssertTrue(history.first?["at"] is Timestamp, "the instant is written as a Firestore timestamp")

        let submitted: [String: Any] = ["voNumber": "VO-002", "sequence": 2, "status": "submitted", "voNumberLocked": true]
        let pinned = try XCTUnwrap(CanonicalBusinessEngine.variationRenumberWriteFields(stored: submitted, to: "VO-009", sequence: 5, at: at, byUid: "u1"))
        XCTAssertNil(pinned?["voNumber"], "a pinned number never changes")
        XCTAssertEqual((pinned?["sequence"] as? NSNumber)?.intValue, 5)
    }

    func testTrackerVersionGoesUp() throws {
        let fields = try XCTUnwrap(CanonicalBusinessEngine.variationTrackerRenumberedFields(stored: ["parentId": "p", "version": 4, "enabled": true]))
        XCTAssertEqual((fields?["version"] as? NSNumber)?.intValue, 5)
    }

    // MARK: The save mirrors web `applyVariationOrder`

    func testSaveUsesTheRulebookAndWritesEveryCopy() throws {
        let text = try source("Project Planner/Core/FirebaseBackend+Variations.swift")
        for name in [
            "variationStaleNumberLocks", "variationRenumberConflict", "variationRenumberPlanChanges",
            "variationRenumberMissingRefusal", "variationRenumberWriteFields", "variationTrackerRenumberedFields",
            "variationItemDocument(organizationId: orgId, variationId: write.id)", "saveVariationToSettingsFallback(next",
            "db.runTransaction",
        ] {
            XCTAssertTrue(text.contains(name), name)
        }
        let view = try source("Project Planner/Views/Variations/VariationTrackerView.swift")
        XCTAssertTrue(view.contains("userStore.canRenumberVariations(on: project)"))
        XCTAssertTrue(view.contains("OfflinePolicy.isEnabled(.renumberVariations"))
        XCTAssertTrue(view.contains("applyVariationOrder("))
        XCTAssertTrue(view.contains("notifyVariationRenumbered("))
        XCTAssertTrue(try source("Project Planner/Views/Variations/VariationsListView.swift").contains("project: project"))
    }
}
