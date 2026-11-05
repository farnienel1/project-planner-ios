import SwiftUI
import XCTest
@testable import Project_Planner

/// UI-only layout metrics (no snapshots): the Home quick-action / job Manage grid and the Scheduling booking action
/// cards share one set of metrics, so tiles cannot drift apart again.
@MainActor
final class TileLayoutMetricsTests: XCTestCase {
    func testQuickActionGridHasEqualTopAlignedFlexibleColumns() {
        let columns = PPQuickActionGrid.columns
        XCTAssertEqual(columns.count, PPMetrics.quickActionColumns)
        XCTAssertEqual(columns.count, 4)
        for column in columns {
            guard case .flexible = column.size else {
                return XCTFail("Every quick-action column is flexible so all four share the width equally")
            }
            XCTAssertEqual(column.alignment, .top, "A one-line label must not re-centre its icon against a two-line neighbour")
            XCTAssertEqual(column.spacing, PPMetrics.quickActionColumnSpacing)
        }
    }

    func testQuickActionTileReservesTwoLabelLinesAndFitsGlyphInTile() {
        XCTAssertEqual(PPQuickActionGrid.labelLines, 2)
        XCTAssertEqual(PPQuickActionGrid.iconSize, PPMetrics.quickActionIcon)
        XCTAssertGreaterThan(PPQuickActionGrid.glyphBox, 0)
        XCTAssertLessThan(PPQuickActionGrid.glyphBox, PPQuickActionGrid.iconSize)
    }

    func testBookingActionCardsReserveTwoSubtitleLinesAndFitTheIcon() {
        XCTAssertEqual(PPBookingActionCardMetrics.subtitleLines, 2)
        XCTAssertGreaterThanOrEqual(
            PPBookingActionCardMetrics.minHeight,
            PPBookingActionCardMetrics.iconSize + 2 * PPBookingActionCardMetrics.padding
        )
    }
}
