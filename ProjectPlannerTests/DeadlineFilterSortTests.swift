import XCTest
@testable import Project_Planner

/// The Deadlines Filter sheet (Trade, Location, Responsible, Critical path only, Sort): the pure narrowing and order.
@MainActor
final class DeadlineFilterSortTests: XCTestCase {
    private let base = Date(timeIntervalSince1970: 1_800_000_000)

    private func item(_ title: String, dayOffset: Int = 0, trade: String? = nil, floors: [String] = [],
                      ids: [String] = [], names: [String] = [], progress: Double = 0, critical: Bool = false) -> DLDeadline {
        var d = DLDeadline(title: title, due: base.addingTimeInterval(Double(dayOffset) * 86_400))
        d.trade = trade
        d.locations = floors
        d.location = floors.first
        d.assigneeUserIds = ids
        d.assignees = names
        d.progress = progress
        d.isCritical = critical
        return d
    }

    private func onFloor(_ item: DLDeadline, _ floor: String) -> Bool {
        item.floors.contains { $0.caseInsensitiveCompare(floor) == .orderedSame }
    }

    func testLocationMatchesAnyOfSeveralFloors() {
        let multi = item("Riser", floors: ["1st Floor", "2nd Floor"])
        for floor in ["1st Floor", "2nd floor"] {
            XCTAssertTrue(DLFilterSort.matches(multi, trade: "", location: floor, responsibleIds: [],
                                               criticalOnly: false, onFloor: onFloor))
        }
        XCTAssertFalse(DLFilterSort.matches(multi, trade: "", location: "Roof", responsibleIds: [],
                                            criticalOnly: false, onFloor: onFloor))
        XCTAssertEqual(DLFilterSort.locationOptions([multi, item("Roof", floors: ["roof", "2nd floor"])]),
                       ["1st Floor", "2nd Floor", "roof"])
    }

    func testTradeResponsibleAndCriticalNarrow() {
        let a = item("A", trade: "Electrical", ids: ["ABC"], names: ["Dan"], critical: true)
        let b = item("B", trade: "Plumbing & Gas", ids: ["xyz"], names: ["Sam"])
        func pass(_ d: DLDeadline, trade: String = "", ids: Set<String> = [], critical: Bool = false) -> Bool {
            DLFilterSort.matches(d, trade: trade, location: "", responsibleIds: ids, criticalOnly: critical, onFloor: onFloor)
        }
        XCTAssertTrue(pass(a, trade: "Electrical"))
        XCTAssertFalse(pass(b, trade: "Electrical"))
        XCTAssertTrue(pass(a, ids: ["id:abc"]), "ids compare without case")
        XCTAssertFalse(pass(b, ids: ["id:abc"]))
        XCTAssertTrue(pass(a, critical: true))
        XCTAssertFalse(pass(b, critical: true))
        XCTAssertEqual(DLFilterSort.responsibleOptions([b, a, a]).map(\.name), ["Dan", "Sam"])
    }

    func testSortOrders() {
        let early = item("Early", dayOffset: 0, trade: "Plumbing & Gas", names: ["Zoe"], progress: 0.8)
        let mid = item("Mid", dayOffset: 1, trade: nil, names: [], progress: 0.1, critical: true)
        let late = item("Late", dayOffset: 2, trade: "Electrical", names: ["Amy"], progress: 0.1)
        let list = [early, mid, late]
        XCTAssertEqual(DLFilterSort.sorted(list, by: .dueDate).map(\.title), ["Early", "Mid", "Late"])
        XCTAssertEqual(DLFilterSort.sorted(list, by: .criticalFirst).map(\.title), ["Mid", "Early", "Late"])
        XCTAssertEqual(DLFilterSort.sorted(list, by: .leastProgress).map(\.title), ["Mid", "Late", "Early"])
        XCTAssertEqual(DLFilterSort.sorted(list, by: .trade).map(\.title), ["Late", "Early", "Mid"], "no trade last")
        XCTAssertEqual(DLFilterSort.sorted(list, by: .responsible).map(\.title), ["Late", "Early", "Mid"], "unassigned last")
    }

    func testStoreFilterCountAndClear() {
        let store = DLStore(items: [item("A", trade: "Electrical", floors: ["Roof"], ids: ["u1"], names: ["Dan"])])
        XCTAssertEqual(store.activeFilterCount, 0)
        store.tradeFilter = "Electrical"
        store.locationFilter = "Roof"
        store.responsibleFilter = "id:u1"
        store.criticalOnly = true
        store.sort = .trade
        store.search = "zzz"
        XCTAssertEqual(store.activeFilterCount, 4)
        XCTAssertTrue(store.isNarrowed)
        XCTAssertTrue(store.groups().isEmpty)
        XCTAssertEqual(store.scopedItems.count, 1, "filters never narrow what the counts read")
        store.clearFilters()
        XCTAssertEqual(store.activeFilterCount, 0)
        XCTAssertFalse(store.isNarrowed)
        XCTAssertEqual(store.search, "")
        XCTAssertEqual(store.sort, .trade, "Clear filters leaves the sort")
    }
}
