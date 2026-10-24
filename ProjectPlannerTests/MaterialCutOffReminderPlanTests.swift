import XCTest
@testable import Project_Planner

@MainActor
final class MaterialCutOffReminderPlanTests: XCTestCase {
    func testNewHourReplacesThePendingIdentifierSet() {
        let previous = MaterialCutOffReminderPlan.replacement(
            hour: 16,
            minute: 0,
            includeSaturday: false,
            includeSunday: false
        )
        let next = MaterialCutOffReminderPlan.replacement(
            hour: 15,
            minute: 30,
            includeSaturday: false,
            includeSunday: false
        )

        XCTAssertEqual(next.identifiersToClear, previous.identifiersToClear)
        XCTAssertEqual(next.identifiersToClear.count, 7)
        XCTAssertTrue(previous.slots.allSatisfy { next.identifiersToClear.contains($0.identifier) })
        XCTAssertEqual(next.slots.map(\.components.hour), Array(repeating: 15, count: 5))
        XCTAssertEqual(next.slots.map(\.components.minute), Array(repeating: 30, count: 5))
        XCTAssertFalse(next.slots.contains { $0.components.hour == 16 && $0.components.minute == 0 })
        XCTAssertEqual(
            Set(next.slots.map(\.identifier)),
            Set(next.slots.map(\.identifier)).intersection(Set(next.identifiersToClear))
        )
    }
}
