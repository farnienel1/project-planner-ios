import XCTest
@testable import Project_Planner

/// Owner bug 24 Nov: a stored postcode "Sw1× 9Hr" (a multiplication sign for the letter x). Display and lookups read it
/// as "SW1X 9HR"; nothing is rewritten on load. Same cases as web `lib/maps/ukPostcode.test.ts`.
final class UKPostcodeTextTests: XCTestCase {
    private let stored = "Sw1\u{00D7} 9Hr"

    func testLookalikesReadAsX() {
        XCTAssertEqual(UKPostcodeText.lookalikesToX(stored), "Sw1x 9Hr")
        XCTAssertEqual(UKPostcodeText.lookalikesToX("sw1\u{2715} 9hr"), "sw1x 9hr")
        XCTAssertEqual(UKPostcodeText.lookalikesToX("SW1\u{0425} 9HR"), "SW1X 9HR")
    }

    func testStoredPostcodeDisplaysInUKForm() {
        XCTAssertEqual(UKPostcodeText.display(stored), "SW1X 9HR")
        XCTAssertEqual(UKPostcodeText.display(" sw1x9hr "), "SW1X 9HR")
        XCTAssertEqual(UKPostcodeText.display("ec4m  7ju"), "EC4M 7JU")
        XCTAssertEqual(UKPostcodeText.display("W1F 9QJ"), "W1F 9QJ")
        XCTAssertEqual(UKPostcodeText.display(""), "")
        XCTAssertEqual(UKPostcodeText.display(nil), "")
    }

    func testNonUKPostcodeShownAsStored() {
        XCTAssertEqual(UKPostcodeText.display(" D02 X285 "), "D02 X285")
        XCTAssertEqual(UKPostcodeText.display("10001"), "10001")
        XCTAssertFalse(UKPostcodeText.isUK("D02 X285"))
    }

    func testAddressTidiesOnlyThePostcode() {
        XCTAssertEqual(
            UKPostcodeText.tidyAddress("6 Lowndes Square, London, \(stored)"),
            "6 Lowndes Square, London, SW1X 9HR"
        )
        XCTAssertEqual(UKPostcodeText.tidyAddress("Unit 2 \u{00D7} 3, Leeds LS1 4AP"), "Unit 2 \u{00D7} 3, Leeds LS1 4AP")
        XCTAssertEqual(UKPostcodeText.tidyAddress("Flat 2, sw1x9hr"), "Flat 2, SW1X 9HR")
    }

    func testTypingUppercasesAndReplacesLookalikes() {
        XCTAssertEqual(UKPostcodeText.inputValue("sw1\u{00D7} 9"), "SW1X 9")
    }
}
