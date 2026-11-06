import XCTest
import UIKit
@testable import Project_Planner

/// The overtime screens' look helpers (no rule): how ✕ ✓ ⚙ draw the rulebook's looks (RULEBOOK 1.33.0
/// `overtimeChoiceView`), and the overtime report PDF layout (page breaks, the builder). The figures, labels and the
/// report's rows come from the rulebook (`Rulebook1330OvertimeTests`).
@MainActor
final class OvertimeScreenLookTests: XCTestCase {
    // MARK: ✕ ✓ ⚙

    func testTheRulebookLooksMapToTheCircles() {
        XCTAssertEqual(OvertimeButtonLook(rulebook: "filled"), .filled)
        XCTAssertEqual(OvertimeButtonLook(rulebook: "grey"), .greyed)
        XCTAssertEqual(OvertimeButtonLook(rulebook: "idle"), .outlined)
        XCTAssertEqual(OvertimeButtonLook(rulebook: "anything else"), .outlined)
    }

    func testNothingChosenIsIdleEverywhere() {
        XCTAssertEqual(OvertimeChoiceLook.idle.tick, "idle")
        XCTAssertEqual(OvertimeChoiceLook.idle.cross, "idle")
        XCTAssertEqual(OvertimeChoiceLook.idle.cog, "idle")
        XCTAssertFalse(OvertimeChoiceLook.idle.figureStruck)
        XCTAssertFalse(OvertimeChoiceLook.idle.complete)
    }

    // MARK: Report PDF layout

    func testAReportTableRowIsTheRulebookRow() {
        let row = OvertimeReportTableRow(OvertimeReportRows.TableRow(
            bookingId: "TEST-B1", day: "Wed 4 Nov", job: "J-1 TEST Site", time: "06:30–14:00", overtime: "0h",
            note: "Declined by TEST-Lee", declined: true
        ))
        XCTAssertEqual(row, OvertimeReportTableRow(
            day: "Wed 4 Nov", job: "J-1 TEST Site", time: "06:30–14:00", overtime: "0h", note: "Declined by TEST-Lee", declined: true
        ))
        XCTAssertEqual(OvertimeReportPDFLayout.pageLabel(1, of: 3), "Page 2 of 3")
    }

    func testRowsThatFitStayOnOnePageWithTheTotal() {
        let pagination = OvertimeReportPDFLayout.paginate(
            rowHeights: [30, 30, 30], firstTableTop: 100, nextTableTop: 50, bottom: 400,
            tableHeader: 24, emptyHeight: 30, gap: 12, totals: 46
        )
        XCTAssertEqual(pagination.pages, [[0, 1, 2]])
        XCTAssertEqual(pagination.totalsPage, 0)
        XCTAssertEqual(pagination.pageCount, 1)
    }

    func testRowsBreakOntoNewPagesAndTheTotalFollowsTheLastRow() {
        // Page 1: 100 + 24 header, room for 3 rows of 50 under 300. Page 2 (top 50 + 24): room for 4 more.
        let pagination = OvertimeReportPDFLayout.paginate(
            rowHeights: Array(repeating: 50, count: 5), firstTableTop: 100, nextTableTop: 50, bottom: 300,
            tableHeader: 24, emptyHeight: 30, gap: 12, totals: 46
        )
        XCTAssertEqual(pagination.pages, [[0, 1, 2], [3, 4]])
        XCTAssertEqual(pagination.totalsPage, 1)
    }

    func testTheTotalMovesToItsOwnPageWhenItDoesNotFit() {
        let pagination = OvertimeReportPDFLayout.paginate(
            rowHeights: [50, 50, 50], firstTableTop: 100, nextTableTop: 50, bottom: 300,
            tableHeader: 24, emptyHeight: 30, gap: 12, totals: 46
        )
        XCTAssertEqual(pagination.pages, [[0, 1, 2], []])
        XCTAssertEqual(pagination.totalsPage, 1)
    }

    func testAnEmptyReportIsOnePage() {
        let pagination = OvertimeReportPDFLayout.paginate(rowHeights: [], firstTableTop: 100, nextTableTop: 50, bottom: 400)
        XCTAssertEqual(pagination.pages, [[]])
        XCTAssertEqual(pagination.totalsPage, 0)
    }

    func testTheBuilderDrawsAPDFWithOnePagePerPaginationPage() {
        let rows = (0..<60).map {
            OvertimeReportTableRow(day: "Day \($0)", job: "TEST-J\($0) A long job name that wraps", time: "06:00–18:00", overtime: "3h × 1.5 = 4.5h")
        }
        let data = OvertimeReportPDFBuilder.makeData(OvertimeReportPDFBuilder.Content(
            title: "Overtime report", companyName: "TEST-Company", personName: "TEST-Sam", period: "26 Oct – 25 Nov",
            generated: "6 Nov 2026, 14:05", columns: ["Day", "Job", "Start–Finish", "Overtime"], rows: rows,
            totalLabel: "Total overtime", totalValue: "270h", emptyMessage: "There is no overtime in this range.",
            footer: "TEST-Company · Overtime report · TEST-Sam", outOfDateNote: "Out of date: TEST", logo: nil
        ))
        let document = CGPDFDocument(CGDataProvider(data: data as CFData)!)
        XCTAssertNotNil(document)
        XCTAssertGreaterThan(document?.numberOfPages ?? 0, 1)
    }
}
