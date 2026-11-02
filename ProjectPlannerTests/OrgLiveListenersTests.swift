import XCTest
@testable import Project_Planner

/// RULEBOOK §1 live listeners: one listener per collection per organisation, all removed on an organisation
/// switch, and a server snapshot replaces the list while a cache snapshot never empties it.
@MainActor
final class OrgLiveListenersTests: XCTestCase {
    private struct Row: Identifiable, Equatable {
        let id: Int
        let value: String
    }

    func testSameTargetAttachesOnceAndANewOrganisationReplacesIt() {
        let registry = OrgListenerRegistry()
        var removed: [String] = []
        XCTAssertTrue(registry.needsAttach(key: "holidayBookings", target: "holidayBookings:org-a|"))
        registry.set(key: "holidayBookings", target: "holidayBookings:org-a|") { removed.append("a") }
        XCTAssertFalse(registry.needsAttach(key: "holidayBookings", target: "holidayBookings:org-a|"),
                       "foreground re-attach of the same listener is a no-op")
        XCTAssertTrue(registry.needsAttach(key: "holidayBookings", target: "holidayBookings:org-b|"))
        registry.set(key: "holidayBookings", target: "holidayBookings:org-b|") { removed.append("b") }
        XCTAssertEqual(removed, ["a"], "the other organisation's listener is removed")
        XCTAssertEqual(registry.count, 1)
    }

    func testRemoveAllDropsEveryListener() {
        let registry = OrgListenerRegistry()
        var removed = Set<String>()
        for key in ["projects", "smallWorks", "clients", "operatives"] {
            registry.set(key: key, target: "\(key):org-a|") { removed.insert(key) }
        }
        registry.removeAll()
        XCTAssertEqual(removed, ["projects", "smallWorks", "clients", "operatives"])
        XCTAssertEqual(registry.count, 0)
        XCTAssertTrue(registry.needsAttach(key: "projects", target: "projects:org-a|"))
    }

    func testAFailedListenerRemovesOnlyItself() {
        let registry = OrgListenerRegistry()
        let old = registry.set(key: "tasks", target: "tasks:org-a|") {}
        var newerRemoved = false
        registry.set(key: "tasks", target: "tasks:org-b|") { newerRemoved = true }
        registry.remove(key: "tasks", token: old)
        XCTAssertTrue(registry.isAttached(key: "tasks"), "a late error from the replaced listener keeps the new one")
        XCTAssertFalse(newerRemoved)
    }

    func testServerSnapshotReplacesTheList() {
        let existing = [Row(id: 1, value: "a"), Row(id: 2, value: "b")]
        let server = [Row(id: 2, value: "b edited")]
        XCTAssertEqual(LiveSnapshotMerge.apply(existing: existing, incoming: server, fromCache: false), server,
                       "a record deleted on web leaves this device")
        XCTAssertEqual(LiveSnapshotMerge.apply(existing: existing, incoming: [Row](), fromCache: false), [],
                       "an empty server collection is empty")
    }

    func testCacheSnapshotNeverEmptiesOrShrinksTheList() {
        let existing = [Row(id: 1, value: "a"), Row(id: 2, value: "b")]
        XCTAssertNil(LiveSnapshotMerge.apply(existing: existing, incoming: [Row](), fromCache: true))
        let merged = LiveSnapshotMerge.apply(existing: existing, incoming: [Row(id: 2, value: "b2")], fromCache: true)
        XCTAssertEqual(merged, [Row(id: 1, value: "a"), Row(id: 2, value: "b2")])
        let grown = [Row(id: 1, value: "a"), Row(id: 2, value: "b"), Row(id: 3, value: "c")]
        XCTAssertEqual(LiveSnapshotMerge.apply(existing: existing, incoming: grown, fromCache: true), grown)
    }
}
