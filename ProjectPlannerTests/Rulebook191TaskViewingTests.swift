//
//  Rulebook191TaskViewingTests.swift
//  RULEBOOK 1.91.0 §34 (owner 25 Nov): the Tasks sort and filter wrappers read the packed script's answers.
//

import XCTest
@testable import Project_Planner

@MainActor
final class Rulebook191TaskViewingTests: XCTestCase {
    func testUnknownSortReadsOverdueFirst() {
        XCTAssertEqual(TaskViewingRulebook.parseSort("bogus"), .overdueFirst)
        XCTAssertEqual(TaskViewingRulebook.parseSort("due_latest"), .dueLatest)
    }

    func testFiltersAreParsedAndCounted() {
        let filters = TaskViewingRulebook.parseFilters(["priority": "High", "junk": 1])
        XCTAssertEqual(filters.priority, "High")
        XCTAssertEqual(filters.projectId, "")
        XCTAssertEqual(TaskViewingRulebook.activeFilterCount(filters), 1)
        XCTAssertEqual(TaskViewingRulebook.activeFilterCount(.none), 0)
    }

    func testDueFilterLabelsComeFromTheRulebook() {
        let labels = Dictionary(uniqueKeysWithValues: TaskViewingRulebook.dueFilterChoices().map { ($0.choice, $0.label) })
        XCTAssertEqual(labels[.overdue], "Overdue")
        XCTAssertEqual(labels[.week], "Next 7 days")
        XCTAssertEqual(labels[.none], "No due date")
    }
}
