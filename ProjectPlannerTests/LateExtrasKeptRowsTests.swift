import XCTest
@testable import Project_Planner

/// Web #347 (16 Nov scan) on iOS: a stored late extra the reader (`parseTimesheetLateExtras`) skips — a blank title, no
/// id, no valid kind, a second row of an id — is written back exactly as stored on the next owner save, in its own slot,
/// never dropped; one sharing an id with a late extra the person deleted goes with it. And the weekly report waits for
/// the pay of the catalogue operatives it prices (`cataloguePayStatus`, `catalogueReportGate`). Cases mirror web
/// `lib/timesheets/timesheetBookingChanges.test.ts` and `lib/pay/payStripStore.test.ts`.
@MainActor
final class LateExtrasKeptRowsTests: XCTestCase {
    private func labels(_ rows: [[String: Any]]) -> [String] {
        rows.map { row in "\(row["id"] ?? "")|\(row["title"] ?? "")|\(row["amount"] ?? "")" }
    }

    private let taxi: [String: Any] = ["kind": "expense", "id": "L1", "title": "Taxi", "jobNumber": "J-1", "amount": 25]
    private let blank: [String: Any] = ["kind": "expense", "id": "L2", "title": "   ", "details": "from an older iPhone", "jobNumber": "J-1", "amount": 30]
    private let duplicate: [String: Any] = ["kind": "expense", "id": "l1", "title": "Second copy", "jobNumber": "J-1", "amount": 5]

    func testSkippedRowsAreWrittenBackOnAnEdit() {
        var edited = taxi
        edited["amount"] = 13
        let written = TimesheetLateExtrasSupport.lateExtrasForWrite(
            shown: [edited],
            storedRows: [taxi, blank, duplicate],
            returnedIds: ["L1"],
            beforeIds: ["L1"],
            nextIds: ["L1"]
        )
        XCTAssertEqual(labels(written), ["L1|Taxi|13", "L2|   |30", "l1|Second copy|5"])
    }

    func testDeletingALateExtraTakesItsHiddenSameIdCopyOnly() {
        let written = TimesheetLateExtrasSupport.lateExtrasForWrite(
            shown: [],
            storedRows: [taxi, blank, duplicate],
            returnedIds: ["L1"],
            beforeIds: ["L1"],
            nextIds: []
        )
        XCTAssertEqual(labels(written), ["L2|   |30"])
    }

    func testTheReadRowIsTheFirstTitledRowOfAnIdAndABlankRowBeforeItIsKept() {
        let blankX: [String: Any] = ["kind": "expense", "id": "X1", "title": "  ", "amount": 30]
        let real: [String: Any] = ["kind": "expense", "id": "x1", "title": "Real", "amount": 7]
        XCTAssertEqual(
            TimesheetLateExtrasSupport.lateExtraReadIndexes(storedRows: [blankX, real], returnedIds: ["x1"]),
            [1]
        )
        var shown = real
        shown["amount"] = 8
        let written = TimesheetLateExtrasSupport.lateExtrasForWrite(
            shown: [shown], storedRows: [blankX, real], returnedIds: ["x1"], beforeIds: ["x1"], nextIds: ["x1"]
        )
        XCTAssertEqual(labels(written), ["X1|  |30", "x1|Real|8"])
    }

    func testEveryRowKeepsItsStoredSlotAndNewRowsAreAppended() {
        let blankX: [String: Any] = ["kind": "expense", "id": "X1", "title": " ", "amount": 30]
        let other: [String: Any] = ["kind": "expense", "id": "Y1", "title": "Other", "amount": 4]
        let junk: [String: Any] = ["id": "Z", "title": "No kind", "amount": 2]
        let real: [String: Any] = ["kind": "expense", "id": "x1", "title": "Real", "amount": 7]
        let stored: [Any] = [blankX, other, junk, real, "not a record"]
        var editedOther = other
        editedOther["amount"] = 9
        let added: [String: Any] = ["kind": "expense", "id": "N1", "title": "New", "amount": 7]
        let withNew = TimesheetLateExtrasSupport.lateExtrasForWrite(
            shown: [real, editedOther, added],
            storedRows: stored,
            returnedIds: ["Y1", "x1"],
            beforeIds: ["Y1", "x1"],
            nextIds: ["Y1", "x1", "N1"]
        )
        XCTAssertEqual(labels(withNew), ["X1| |30", "Y1|Other|9", "Z|No kind|2", "x1|Real|7", "N1|New|7"])
        let deleted = TimesheetLateExtrasSupport.lateExtrasForWrite(
            shown: [real],
            storedRows: stored,
            returnedIds: ["Y1", "x1"],
            beforeIds: ["Y1", "x1"],
            nextIds: ["x1"]
        )
        XCTAssertEqual(labels(deleted), ["X1| |30", "Z|No kind|2", "x1|Real|7"])
    }

    func testOnlyAKeptRowTheReaderCouldShowGoesWithADeletedId() {
        let before = ["L1", "5"]
        func removed(_ row: [String: Any]) -> Bool {
            TimesheetLateExtrasSupport.lateExtraKeptRowRemoved(row, beforeIds: before, nextIds: [])
        }
        XCTAssertFalse(removed(["kind": "expense", "id": "l1", "title": "  ", "amount": 30]))
        XCTAssertFalse(removed(["kind": " expense ", "id": "L1", "title": "Padded", "amount": 3]))
        XCTAssertFalse(removed(["id": "L1", "title": "No kind", "amount": 4]))
        XCTAssertFalse(removed(["kind": "expense", "id": 5, "title": "Number", "amount": 5]))
        XCTAssertTrue(removed(["kind": "priceWork", "id": "l1", "title": "Shown copy", "amount": 6]))
        // Editing (same id kept) removes nothing.
        XCTAssertFalse(TimesheetLateExtrasSupport.lateExtraKeptRowRemoved(
            ["kind": "priceWork", "id": "l1", "title": "Shown copy"], beforeIds: ["L1"], nextIds: ["L1"]
        ))
    }

    // MARK: - Weekly report: catalogue operatives' pay

    func testCataloguePayStatusWaitsForTheCurrentOverlayAndNamesAFailedRead() {
        XCTAssertEqual(OperativeStore.cataloguePayStatus(operativeId: "row1", done: nil, currentGeneration: 3), .loading)
        XCTAssertEqual(
            OperativeStore.cataloguePayStatus(operativeId: "row1", done: (2, ["row1"], []), currentGeneration: 3),
            .loading
        )
        XCTAssertEqual(
            OperativeStore.cataloguePayStatus(operativeId: "ROW1", done: (3, ["row1"], []), currentGeneration: 3),
            .ready
        )
        XCTAssertEqual(
            OperativeStore.cataloguePayStatus(operativeId: "Row1", done: (3, ["row1"], ["row1"]), currentGeneration: 3),
            .failed
        )
        // A row the viewer's plan does not read never blocks (its pay is hidden from them).
        XCTAssertEqual(
            OperativeStore.cataloguePayStatus(operativeId: "row9", done: (3, ["row1"], ["row1"]), currentGeneration: 3),
            .ready
        )
    }

    func testCatalogueReportGate() {
        let rows = [(id: "b", name: "Bob"), (id: "a", name: "Ann")]
        XCTAssertEqual(PrivatePayOverlayReadiness.catalogueReportGate(operatives: rows) { _ in .ready }.status, .ready)
        XCTAssertEqual(PrivatePayOverlayReadiness.catalogueReportGate(operatives: []) { _ in .failed }.status, .ready)
        let loading = PrivatePayOverlayReadiness.catalogueReportGate(operatives: rows) { $0 == "a" ? .loading : .ready }
        XCTAssertEqual(loading.status, .loading)
        XCTAssertNil(loading.message)
        let failed = PrivatePayOverlayReadiness.catalogueReportGate(operatives: rows) { _ in .failed }
        XCTAssertEqual(failed.status, .failed)
        XCTAssertEqual(failed.message, PrivatePayOverlayReadiness.reportPeopleFailedMessage(["Ann", "Bob"]))
    }
}
