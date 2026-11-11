import XCTest

/// Annual leave → Book time off: tapping a weekend, a bank holiday or a day that already has full-day leave opens a
/// small sheet ("Already booked — This day already has annual leave on it."). Failure before: its Close pill had
/// the padding and fill applied outside the Button, so only the word "Close" took a tap and a tap on the pill did
/// nothing. These lock the pill inside the button's label.
final class LeaveInfoSheetCloseTests: XCTestCase {
    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    }

    private func closeButtonBlock() throws -> String {
        let text = try String(
            contentsOf: repoRoot.appendingPathComponent("Project Planner/Views/HolidayView.swift"),
            encoding: .utf8
        )
        let marker = try XCTUnwrap(text.range(of: ".accessibilityIdentifier(\"leave.close\")"), "leave.close not found")
        let start = try XCTUnwrap(
            text[..<marker.lowerBound].range(of: "Button", options: .backwards),
            "no Button before leave.close"
        )
        return String(text[start.lowerBound..<marker.upperBound])
    }

    func testTheWholeClosePillIsTheButton() throws {
        let block = try closeButtonBlock()
        XCTAssertTrue(block.contains("bankHolidayTooltip = nil"), "Close must clear the sheet's message")
        let label = try XCTUnwrap(block.range(of: "} label: {"), "the pill must be the Button's label")
        let styling = block[label.upperBound...]
        for modifier in [".frame(maxWidth: .infinity)", ".padding(.vertical, 14)", ".background(AnnualLeavePalette.soft)", ".contentShape("] {
            XCTAssertTrue(styling.contains(modifier), "\(modifier) must be inside the label")
        }
    }

    func testTheSheetCanGrowForLargerText() throws {
        let text = try String(
            contentsOf: repoRoot.appendingPathComponent("Project Planner/Views/HolidayView.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(text.contains(".presentationDetents([.height(220), .medium])"))
    }
}
