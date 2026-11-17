import XCTest
@testable import Project_Planner

/// RULEBOOK 1.57.0 (snapshot gap, J1 for reports, latest revision's claims) and 1.58.0 (a missing material brand reads
/// "N/A") on iOS through `CanonicalBusinessEngine`. Expected values follow web `lib/canonical/canonical.test.ts`
/// ("1.57.0 …" and "1.58.0 …" tests) against the packed script this branch mirrors.
@MainActor
final class Rulebook1580Tests: XCTestCase {
    // MARK: 1.57.0 — a signed snapshot that lacks a booking the person signed

    private let nowMs = Date().timeIntervalSince1970 * 1000

    private func liveLine(_ id: String, extra: [String: Any] = [:]) -> [String: Any] {
        var line: [String: Any] = [
            "id": "op-\(id)-normal",
            "bookingId": id,
            "bookingCollection": "bookings",
            "bookingFingerprint": "\(id)|2026-11-10|FULL DAY||||0|",
            "bookingCreatedAt": nowMs - 86_400_000,
            "bookingUpdatedAt": nowMs - 86_400_000,
        ]
        for (key, value) in extra { line[key] = value }
        return line
    }

    /// Signed by the person for bookings a and b; the line manager's snapshot holds only b.
    private func gapSheet(exported: Bool = false) -> [String: Any] {
        let signedAt = nowMs - 120_000
        var sheet: [String: Any] = [
            "operativeSignedAt": signedAt,
            "operativeSignedBookings": ["a", "b"].map { id -> [String: Any] in
                ["bookingId": id, "collection": "bookings", "fingerprint": "\(id)|2026-11-10|FULL DAY||||0|", "personId": "u1", "place": ""]
            },
            "operativeSignedBookingsAt": signedAt,
            "operativeSignedBookingsSignedAt": signedAt,
            "managerSignedAt": nowMs - 60_000,
            "weeklyReportOverride": [
                "approvedAt": nowMs - 60_000,
                "lines": [["id": "op-b-normal", "bookingId": "b", "bookingFingerprint": "b|2026-11-10|FULL DAY||||0|"]],
            ] as [String: Any],
        ]
        if exported { sheet["exportedAt"] = nowMs - 10_000 }
        return sheet
    }

    private func change(_ sheet: [String: Any], lines: [[String: Any]]) throws -> RulebookSignedTimesheetChange {
        try XCTUnwrap(CanonicalBusinessEngine.signedTimesheetBookingChanges(
            sheet: sheet, liveLines: lines, liveBookings: nil, personIds: nil, liveLoaded: true, selfSigned: false
        ))
    }

    func testSnapshotGapIsReportedApartAndTheLineManagerCounterSignsAgain() throws {
        let open = try change(gapSheet(), lines: [liveLine("a"), liveLine("b")])
        XCTAssertTrue(open.reopened)
        XCTAssertEqual(open.waitingFor, "lineManager")
        XCTAssertTrue(open.waitingForLineManager)
        XCTAssertFalse(open.waitingForPerson, "the person has nothing to sign again")
        XCTAssertEqual(open.snapshotGapBookingIds, ["a"])
        XCTAssertEqual(open.addedBookingIds, [], "the gap is never inside addedBookingIds")
        XCTAssertTrue(open.snapshotGapOnly)
        XCTAssertFalse(CanonicalBusinessEngine.signedTimesheetActions(open).mayExport, "a broken snapshot is never exported")

        let exported = try change(gapSheet(exported: true), lines: [liveLine("a"), liveLine("b")])
        XCTAssertTrue(exported.exported)
        XCTAssertTrue(exported.changed, "exported: a revision is due")

        // Never for an Office / WFH / Site survey / custom-place booking, nor a signed booking no longer live.
        XCTAssertFalse(try change(gapSheet(), lines: [liveLine("a", extra: ["scheduleOptionPlace": true]), liveLine("b")]).changed)
        XCTAssertFalse(try change(gapSheet(), lines: [liveLine("b")]).changed)
        // A PAYE day or a leave line is never a timesheet line, so never a gap.
        XCTAssertFalse(try change(gapSheet(), lines: [liveLine("a", extra: ["isPayeDay": true]), liveLine("b")]).changed)
        XCTAssertFalse(try change(gapSheet(), lines: [liveLine("a", extra: ["isLeave": true]), liveLine("b")]).changed)
        // No current record (signed before 1.47.0): nothing new is read.
        var noRecord = gapSheet()
        noRecord["operativeSignedBookings"] = NSNull()
        XCTAssertFalse(try change(noRecord, lines: [liveLine("a"), liveLine("b")]).changed)
    }

    func testReportsKeepTheSignedFiguresForAGapOnlyChange() throws {
        let gap = try change(gapSheet(), lines: [liveLine("a"), liveLine("b")])
        XCTAssertNil(CanonicalBusinessEngine.signedTimesheetChangeForReports(gap), "J1: a gap-only change is no change for reports")
        XCTAssertNil(CanonicalBusinessEngine.signedTimesheetChangeForReports(nil))

        // A real booking change is kept as it is.
        let real = try XCTUnwrap(RulebookSignedTimesheetChange(json: ["changed": true, "reopened": true, "waitingFor": "person", "snapshotGapOnly": false]))
        let kept = try XCTUnwrap(CanonicalBusinessEngine.signedTimesheetChangeForReports(real))
        XCTAssertEqual(kept, real)

        // The exported gap reads "due" for the sheet itself but not for reports.
        let exportedGap = try change(gapSheet(exported: true), lines: [liveLine("a"), liveLine("b")])
        XCTAssertEqual(CanonicalBusinessEngine.timesheetRevisionReportState(revision: 0, exported: true, signedOff: true, change: exportedGap)?.state, "due")
        XCTAssertEqual(
            CanonicalBusinessEngine.timesheetRevisionReportState(
                revision: 0, exported: true, signedOff: true,
                change: CanonicalBusinessEngine.signedTimesheetChangeForReports(exportedGap)
            )?.state,
            "none"
        )

        // The report argument carries the gap and late-extras fields to `weeklyReportPayRows` / `payrunSnapshotRows`.
        XCTAssertEqual(gap.reportArgument["snapshotGapOnly"] as? Bool, true)
        XCTAssertEqual(gap.reportArgument["lateExtrasWaiting"] as? Bool, false)
        XCTAssertEqual(gap.reportArgument["waitingFor"] as? String, "lineManager")
    }

    func testAGapOnlyChangeNeverHidesLateExtrasWaiting() throws {
        let gap = try change(gapSheet(), lines: [liveLine("a"), liveLine("b")])
        let lateJSON = CanonicalBusinessEngine.callJSON(
            "timesheetChangesWithLateExtras", arguments: [gap.scriptJSON, ["waitingForLineManager": true]]
        )
        let late = try XCTUnwrap(RulebookSignedTimesheetChange(json: lateJSON))
        XCTAssertTrue(late.lateExtrasWaiting)
        let report = try XCTUnwrap(CanonicalBusinessEngine.signedTimesheetChangeForReports(late), "kept: late extras still wait")
        XCTAssertFalse(report.bookingsChanged)
        XCTAssertFalse(report.snapshotGapOnly)
        XCTAssertTrue(report.reopened)
        XCTAssertEqual(report.waitingFor, "lineManager")
    }

    func testScriptJSONRoundTripsEveryField() throws {
        let gap = try change(gapSheet(), lines: [liveLine("a"), liveLine("b")])
        XCTAssertEqual(RulebookSignedTimesheetChange(json: gap.scriptJSON), gap)
    }

    // MARK: 1.57.0 — invoice PDF wording for price work and expenses

    func testMoneyRowDetailsReadTheTitleAndDescriptionNeverRateNotSet() {
        XCTAssertEqual(InvoiceLineItem.moneyRowDetails(title: "Parking", description: ""), "Parking")
        XCTAssertEqual(InvoiceLineItem.moneyRowDetails(title: " Extra first fix ", description: " Kitchen sockets "), "Extra first fix · Kitchen sockets")
        XCTAssertEqual(InvoiceLineItem.moneyRowDetails(title: "Parking", description: "Parking"), "Parking", "a description equal to the title is not repeated")
        XCTAssertFalse(InvoiceLineItem.moneyRowDetails(title: "Parking", description: "").contains("rate not set"))
    }

    // MARK: 1.58.0 — a missing material brand reads "N/A"

    func testMissingAndLegacyCustomBrandsShowNA() {
        XCTAssertEqual(CanonicalBusinessEngine.materialBrandText(nil), "N/A")
        XCTAssertEqual(CanonicalBusinessEngine.materialBrandText(""), "N/A")
        XCTAssertEqual(CanonicalBusinessEngine.materialBrandText("Custom"), "N/A")
        XCTAssertEqual(CanonicalBusinessEngine.materialBrandText("  custom "), "N/A")
        XCTAssertEqual(CanonicalBusinessEngine.materialBrandText("Custom Cables Ltd"), "Custom Cables Ltd")
        XCTAssertEqual(CanonicalBusinessEngine.materialBrandStored("Custom"), "")
        XCTAssertEqual(CanonicalBusinessEngine.materialBrandStored(" Wago "), "Wago")
    }

    func testCatalogueReaderAndWriterNeverUseCustom() throws {
        let missing = try XCTUnwrap(FirebaseBackend.materialCatalogItem(documentId: "c1", data: ["name": "Clips"]))
        XCTAssertEqual(missing.brand, "")
        let legacy = try XCTUnwrap(FirebaseBackend.materialCatalogItem(documentId: "c2", data: ["name": "Clips", "brand": "Custom"]))
        XCTAssertEqual(legacy.brand, "")
        let typed = try XCTUnwrap(FirebaseBackend.materialCatalogItem(documentId: "c3", data: ["name": "Clips", "brand": "Custom Cables Ltd"]))
        XCTAssertEqual(typed.brand, "Custom Cables Ltd")

        // A new item with no brand saves ''.
        let fields = try XCTUnwrap(CanonicalBusinessEngine.materialCatalogueItemFields(["id": "c4", "name": "Clips", "brand": ""]))
        XCTAssertEqual(fields["brand"] as? String, "")

        // Editing the name of an item stored with "Custom" sends no brand field.
        let stored: [String: Any] = ["name": "Clips", "brand": "Custom", "category": "Other"]
        let writes = try XCTUnwrap(CanonicalBusinessEngine.materialCatalogueWrites(
            stored: [(id: "c2", data: stored)],
            next: [["id": "c2", "name": "Cable clips", "brand": "", "category": "Other"]],
            loaded: true
        ))
        let write = try XCTUnwrap(writes.write.first)
        XCTAssertEqual(write.set["name"] as? String, "Cable clips")
        XCTAssertNil(write.set["brand"], "a stored \"Custom\" is never rewritten by an edit of another field")
        XCTAssertFalse(write.remove.contains("brand"))
    }
}
