import XCTest
import UIKit
@testable import Project_Planner

/// The overtime screens' look helpers (no rule): which of ✕ ✓ ⚙ shows as picked, and the overtime report PDF layout
/// (table rows from the saved copy, page breaks, the total box text). The figures and labels themselves come from the
/// rulebook and are covered by `Rulebook1320OvertimeTests`.
@MainActor
final class OvertimeScreenLookTests: XCTestCase {
    // MARK: ✕ ✓ ⚙

    func testNothingDecidedShowsThreeOutlinedCircles() {
        for button in [OvertimeLineChoice.tick, .cross, .cog] {
            XCTAssertEqual(OvertimeLineChoice.look(of: button, chosen: nil), .outlined)
        }
        XCTAssertFalse(OvertimeLineChoice.strikesFigure(nil))
    }

    func testTickFillsTickAndGreysTheOthers() {
        XCTAssertEqual(OvertimeLineChoice.look(of: .tick, chosen: .tick), .filled)
        XCTAssertEqual(OvertimeLineChoice.look(of: .cross, chosen: .tick), .greyed)
        XCTAssertEqual(OvertimeLineChoice.look(of: .cog, chosen: .tick), .greyed)
        XCTAssertFalse(OvertimeLineChoice.strikesFigure(.tick))
    }

    func testCrossFillsCrossGreysTheOthersAndStrikesTheFigure() {
        XCTAssertEqual(OvertimeLineChoice.look(of: .cross, chosen: .cross), .filled)
        XCTAssertEqual(OvertimeLineChoice.look(of: .tick, chosen: .cross), .greyed)
        XCTAssertEqual(OvertimeLineChoice.look(of: .cog, chosen: .cross), .greyed)
        XCTAssertTrue(OvertimeLineChoice.strikesFigure(.cross))
    }

    func testCogLeavesTickAndCrossAvailable() {
        XCTAssertEqual(OvertimeLineChoice.look(of: .cog, chosen: .cog), .filled)
        XCTAssertEqual(OvertimeLineChoice.look(of: .tick, chosen: .cog), .outlined)
        XCTAssertEqual(OvertimeLineChoice.look(of: .cross, chosen: .cog), .outlined)
        XCTAssertTrue(OvertimeLineChoice.strikesFigure(.cog))
    }

    func testChoiceFromActionsAndSentLines() {
        XCTAssertEqual(OvertimeLineChoice(.keep), .tick)
        XCTAssertEqual(OvertimeLineChoice(.approve), .tick)
        XCTAssertEqual(OvertimeLineChoice(.strike), .cross)
        XCTAssertEqual(OvertimeLineChoice(.edit(start: "07:00", end: "17:00", multiplier: nil)), .cog)
        XCTAssertEqual(OvertimeLineChoice(requestAction: "keep"), .tick)
        XCTAssertEqual(OvertimeLineChoice(requestAction: "strike"), .cross)
        XCTAssertEqual(OvertimeLineChoice(requestAction: "edit"), .cog)
        XCTAssertNil(OvertimeLineChoice(requestAction: "other"))

        let sent = OvertimeRequestLine(
            bookingId: "TEST-b1", collection: "bookings", dayKey: "2026-11-02", jobId: nil, fingerprint: "f",
            action: "strike", proposedStart: "07:30", proposedEnd: "16:00", proposedMultiplier: nil, cancel: false,
            overtimeHoursBefore: 1.5, overtimeHoursAfter: 0
        )
        // The unsent proposal wins over the sent line, the sent line over the line state.
        XCTAssertEqual(OvertimeLinesView.choice(proposal: .keep, sentLine: sent, state: "waiting"), .tick)
        XCTAssertEqual(OvertimeLinesView.choice(proposal: nil, sentLine: sent, state: "waiting"), .cross)
        XCTAssertEqual(OvertimeLinesView.choice(proposal: nil, sentLine: nil, state: "approved"), .tick)
        XCTAssertNil(OvertimeLinesView.choice(proposal: nil, sentLine: nil, state: "needsReview"))
    }

    // MARK: Report PDF layout

    func testTableRowsReadTheSavedFieldsOneForOne() {
        let saved: [[String: Any]] = [
            ["dayLabel": "Mon 2 Nov", "jobNumber": "TEST-J1", "jobName": "Kitchen refit", "start": "06:00", "end": "18:00", "text": "3h × 1.5 = 4.5h"],
            ["dayLabel": "Tue 3 Nov", "jobNumber": "", "jobName": "Office", "start": "", "end": "", "text": "1h × 1.5 = 1.5h"],
        ]
        let rows = OvertimeReportPDFLayout.tableRows(savedLines: saved, rulebookRows: ["a", "b"])
        XCTAssertEqual(rows, [
            OvertimeReportTableRow(day: "Mon 2 Nov", job: "TEST-J1 Kitchen refit", time: "06:00–18:00", overtime: "3h × 1.5 = 4.5h"),
            OvertimeReportTableRow(day: "Tue 3 Nov", job: "Office", time: "", overtime: "1h × 1.5 = 1.5h"),
        ])
    }

    func testTableRowsFallBackToTheRulebookRowsWhenTheCountsDiffer() {
        let rows = OvertimeReportPDFLayout.tableRows(savedLines: nil, rulebookRows: ["Mon 2 Nov · TEST-J1 · 3h × 1.5 = 4.5h"])
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.fullText, "Mon 2 Nov · TEST-J1 · 3h × 1.5 = 4.5h")
    }

    func testTotalAndTitleSplitTheRulebookText() {
        let total = OvertimeReportPDFLayout.splitTotal("Total overtime: 12.5h")
        XCTAssertEqual(total.label, "Total overtime")
        XCTAssertEqual(total.value, "12.5h")
        XCTAssertEqual(OvertimeReportPDFLayout.splitTotal("Total").label, "Total")
        XCTAssertEqual(OvertimeReportPDFLayout.documentTitle("Overtime report · TEST-Sam"), "Overtime report")
        XCTAssertEqual(OvertimeReportPDFLayout.documentTitle(""), "Overtime report")
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
            generated: "6 Nov 2026, 14:05", rows: rows, totalLabel: "Total overtime", totalValue: "270h",
            emptyMessage: "There is no overtime in this range.", logo: nil
        ))
        let document = CGPDFDocument(CGDataProvider(data: data as CFData)!)
        XCTAssertNotNil(document)
        XCTAssertGreaterThan(document?.numberOfPages ?? 0, 1)
    }
}
