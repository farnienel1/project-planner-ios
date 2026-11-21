//
//  Rulebook1630Tests.swift
//  RULEBOOK 1.63.0 §22 (owner decisions 17 Nov, A / B, bug C): reopening a variation unpins it; the tracker is on by default.
//

import XCTest
@testable import Project_Planner

final class Rulebook1630Tests: XCTestCase {
    func testReopenClearsTheNumberLockInTheSameWrite() {
        XCTAssertTrue(CanonicalBusinessEngine.variationStatusLocksNumber(status: "submitted"))
        XCTAssertTrue(CanonicalBusinessEngine.variationStatusLocksNumber(status: "closed"))
        XCTAssertFalse(CanonicalBusinessEngine.variationStatusLocksNumber(status: "open"))
        // Legacy words lock and pin alike (review of #388).
        for word in ["sent", "complete", "done", "Submitted", "open", "weird"] {
            XCTAssertEqual(
                CanonicalBusinessEngine.variationStatusLocksNumber(status: word),
                CanonicalBusinessEngine.variationIsPinned(status: word, voNumberLocked: false),
                word
            )
        }
        XCTAssertFalse(CanonicalBusinessEngine.variationIsPinned(status: "open", voNumberLocked: true))
        XCTAssertTrue(CanonicalBusinessEngine.variationIsPinned(status: "submitted", voNumberLocked: false))
    }

    func testTrackerIsOnWhenNothingIsStored() {
        XCTAssertTrue(VariationCodec.tracker(from: [:], parentId: "JOB-1", parentType: .smallWork).enabled)
        XCTAssertEqual(VariationCodec.tracker(from: [:], parentId: "JOB-1", parentType: .smallWork).parentType, .smallWork)
        XCTAssertTrue(VariationCodec.tracker(from: ["parentId": "JOB-1", "orderLocked": false], parentId: "JOB-1").enabled)
        XCTAssertFalse(VariationCodec.tracker(from: ["parentId": "JOB-1", "enabled": false], parentId: "JOB-1").enabled)
    }

    func testTrackerOrderIsSequenceThenNumberThenId() {
        // A job never switched on: no positions. The order follows the VO number, never the creation date.
        let rows: [[String: Any]] = [
            ["id": "b-made-first", "voNumber": "VO-002"],
            ["id": "a-made-second", "voNumber": "VO-001", "sequence": 0],
            ["id": "c-made-third", "voNumber": "VO-003"],
        ]
        XCTAssertEqual(CanonicalBusinessEngine.variationTrackerOrder(rows: rows), ["a-made-second", "b-made-first", "c-made-third"])
        let plan = CanonicalBusinessEngine.variationRenumberPlan(rows: rows, prefix: "VO-", padding: 3, orderLocked: false)
        XCTAssertEqual(plan?.rows.filter(\.changed).count, 0)
    }
}
