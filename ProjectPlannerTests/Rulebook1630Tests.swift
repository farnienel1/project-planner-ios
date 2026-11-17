//
//  Rulebook1630Tests.swift
//  RULEBOOK 1.63.0 §22 (owner decisions 17 Nov, A / B, bug C): reopening a variation unpins it; the tracker is on by default.
//

import XCTest
@testable import Project_Planner

final class Rulebook1630Tests: XCTestCase {
    func testReopenClearsTheNumberLockInTheSameWrite() {
        XCTAssertTrue(CanonicalBusinessEngine.variationStatusLocksNumber(status: "submitted", storedLocked: false))
        XCTAssertTrue(CanonicalBusinessEngine.variationStatusLocksNumber(status: "closed", storedLocked: true))
        XCTAssertFalse(CanonicalBusinessEngine.variationStatusLocksNumber(status: "open", storedLocked: true))
        XCTAssertFalse(CanonicalBusinessEngine.variationIsPinned(status: "open", voNumberLocked: true))
        XCTAssertTrue(CanonicalBusinessEngine.variationIsPinned(status: "submitted", voNumberLocked: false))
    }

    func testTrackerIsOnWhenNothingIsStored() {
        XCTAssertTrue(VariationCodec.tracker(from: [:], parentId: "JOB-1", parentType: .smallWork).enabled)
        XCTAssertEqual(VariationCodec.tracker(from: [:], parentId: "JOB-1", parentType: .smallWork).parentType, .smallWork)
        XCTAssertTrue(VariationCodec.tracker(from: ["parentId": "JOB-1", "orderLocked": false], parentId: "JOB-1").enabled)
        XCTAssertFalse(VariationCodec.tracker(from: ["parentId": "JOB-1", "enabled": false], parentId: "JOB-1").enabled)
    }
}
