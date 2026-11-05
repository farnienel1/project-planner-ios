import XCTest
@testable import Project_Planner

/// RULEBOOK 1.31.3 iOS follow-on (web hand-off v1.31.3): mirror only. 1.31.2 and 1.31.3 restructure
/// `firestore.rules` on web with no behaviour change, so iOS calls no new `CanonicalBusinessEngine` function.
final class Rulebook1313Tests: XCTestCase {
    func testRulebookVersionIs1313() {
        XCTAssertEqual(CanonicalBusinessEngine.rulebookStamp()?.version, "1.31.3")
    }
}
