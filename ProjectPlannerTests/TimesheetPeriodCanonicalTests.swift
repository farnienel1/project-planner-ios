import FirebaseFirestore
import XCTest
@testable import Project_Planner

@MainActor
final class TimesheetPeriodCanonicalTests: XCTestCase {
    func testDocumentIdIsOrganisationZoneUnixStart() throws {
        let id = try XCTUnwrap(
            CanonicalBusinessEngine.timesheetDocumentId(
                userId: "user-1",
                startDayKey: "2026-10-01",
                timeZone: "Europe/London"
            )
        )
        var london = Calendar(identifier: .gregorian)
        london.timeZone = try XCTUnwrap(TimeZone(identifier: "Europe/London"))
        let londonMidnight = try XCTUnwrap(london.date(from: DateComponents(year: 2026, month: 10, day: 1)))
        let stamp = Int(londonMidnight.timeIntervalSince1970)
        XCTAssertEqual(id, "timesheet_user-1_\(stamp)")

        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        let utcMidnight = try XCTUnwrap(utc.date(from: DateComponents(year: 2026, month: 10, day: 1)))
        XCTAssertNotEqual(stamp, Int(utcMidnight.timeIntervalSince1970))
        XCTAssertFalse(id.contains("\(Int(utcMidnight.timeIntervalSince1970))"))
        XCTAssertNil(CanonicalBusinessEngine.timesheetDocumentId(userId: "", startDayKey: "2026-10-01"))
    }

    func testListBucketsComeFromTheScript() throws {
        let awaiting = try fields(operative: signed, manager: nil, exported: nil)
        XCTAssertEqual(CanonicalBusinessEngine.timesheetListBucket(awaiting, hasLineManager: true), "awaiting")
        XCTAssertEqual(CanonicalBusinessEngine.isTimesheetAwaitingSignOff(awaiting, hasLineManager: true), true)
        XCTAssertEqual(CanonicalBusinessEngine.isTimesheetExported(awaiting), false)

        let signedOff = try fields(operative: signed, manager: signed, exported: nil)
        XCTAssertEqual(CanonicalBusinessEngine.timesheetListBucket(signedOff, hasLineManager: true), "signed")
        XCTAssertEqual(CanonicalBusinessEngine.isTimesheetFullySigned(signedOff, hasLineManager: true), true)

        let exported = try fields(operative: signed, manager: signed, exported: signed)
        XCTAssertEqual(CanonicalBusinessEngine.timesheetListBucket(exported, hasLineManager: true), "exported")
        XCTAssertEqual(CanonicalBusinessEngine.isTimesheetExported(exported), true)

        let noManager = try fields(operative: signed, manager: nil, exported: nil)
        XCTAssertEqual(CanonicalBusinessEngine.timesheetListBucket(noManager, hasLineManager: false), "signed")
    }

    func testSignOffAndExportWritesComeFromTheScript() throws {
        let operative = try XCTUnwrap(
            CanonicalBusinessEngine.timesheetSignOffWriteFields(
                role: "operative",
                signedAtMs: signed.timeIntervalSince1970 * 1000,
                signedByName: "Ada Lovelace",
                signatureImageBase64: "sig"
            )
        )
        XCTAssertEqual(operative.operativeSignedByName, "Ada Lovelace")
        XCTAssertEqual(operative.operativeSignatureImageBase64, "sig")
        XCTAssertNotNil(operative.operativeSignedAtMs)
        XCTAssertNil(operative.approvedAtMs)

        let manager = try XCTUnwrap(
            CanonicalBusinessEngine.timesheetSignOffWriteFields(
                role: "manager",
                signedAtMs: signed.timeIntervalSince1970 * 1000,
                signedByName: "Grace Hopper",
                signedByUserId: "manager-1",
                signatureImageBase64: "mgr"
            )
        )
        XCTAssertEqual(manager.managerSignedByName, "Grace Hopper")
        XCTAssertEqual(manager.managerSignedByUserId, "manager-1")
        XCTAssertEqual(manager.managerSignatureImageBase64, "mgr")
        XCTAssertEqual(manager.approvedAtMs, manager.managerSignedAtMs)
        XCTAssertEqual(manager.approvedByName, "Grace Hopper")

        let exported = try XCTUnwrap(
            CanonicalBusinessEngine.timesheetExportWriteFields(exportedAtMs: signed.timeIntervalSince1970 * 1000)
        )
        XCTAssertEqual(exported.exportedAtMs, signed.timeIntervalSince1970 * 1000)

        var draft = TimesheetDraft()
        XCTAssertTrue(
            TimesheetDraftStore.applySignOff(
                to: &draft,
                role: "manager",
                signedAt: signed,
                signedByName: "Grace Hopper",
                signedByUserId: "manager-1",
                signatureImageBase64: "mgr"
            )
        )
        let signedMap = TimesheetDraftStore.asFirestoreMap(draft)
        XCTAssertNotNil(signedMap["managerSignedAt"] as? Timestamp)
        XCTAssertEqual(signedMap["managerSignedByName"] as? String, "Grace Hopper")
        XCTAssertEqual(signedMap["approvedByName"] as? String, "Grace Hopper")
        XCTAssertNotNil(signedMap["approvedAt"] as? Timestamp)
        XCTAssertNil(signedMap["exportedAt"] as? Timestamp)

        var invoiced = TimesheetDraft()
        invoiced.managerNote = "Generate Invoice does not export"
        let invoiceMap = TimesheetDraftStore.asFirestoreMap(invoiced)
        XCTAssertNil(invoiceMap["exportedAt"] as? Timestamp)

        XCTAssertTrue(TimesheetDraftStore.applyExport(to: &draft, at: signed))
        let exportedMap = TimesheetDraftStore.asFirestoreMap(draft)
        XCTAssertNotNil(exportedMap["exportedAt"] as? Timestamp)
    }

    func testStoredOneToSevenStillMatchesAfterLiveRunBecomesOneToFifteen() throws {
        let live = try XCTUnwrap(
            CanonicalBusinessEngine.timesheetPeriodFromInvoicing(
                paymentRunMode: "date_ranges",
                ranges: [range(1, 15), range(16, 31)],
                recurringRunStartDay: "monday",
                recurringRunEndDay: "sunday",
                referenceDayKey: "2026-10-03"
            )
        )
        XCTAssertEqual(live.startDayKey, "2026-10-01")
        XCTAssertEqual(live.endDayKey, "2026-10-15")

        let stored = CanonicalBusinessEngine.CanonicalTimesheetPeriod(startDayKey: "2026-10-01", endDayKey: "2026-10-07")
        XCTAssertEqual(
            CanonicalBusinessEngine.timesheetPeriodMatches(
                storedStartDayKey: stored.startDayKey,
                storedEndDayKey: stored.endDayKey,
                period: stored
            ),
            true
        )
        XCTAssertEqual(
            CanonicalBusinessEngine.timesheetPeriodMatches(
                storedStartDayKey: stored.startDayKey,
                storedEndDayKey: stored.endDayKey,
                period: live
            ),
            false
        )
        let resolved = try XCTUnwrap(
            CanonicalBusinessEngine.resolveTimesheetPeriod(
                storedStartDayKey: stored.startDayKey,
                storedEndDayKey: stored.endDayKey,
                currentPeriod: live
            )
        )
        XCTAssertEqual(resolved.startDayKey, "2026-10-01")
        XCTAssertEqual(resolved.endDayKey, "2026-10-07")
    }

    func testOldRunStaysSelectableAfterTheWindowChanges() throws {
        let previous = CanonicalBusinessEngine.CanonicalTimesheetPaymentRunWindow(
            paymentRunMode: "date_ranges",
            ranges: [range(1, 7), range(8, 31)],
            recurringRunStartDay: "monday",
            recurringRunEndDay: "sunday"
        )
        let next = CanonicalBusinessEngine.CanonicalTimesheetPaymentRunWindow(
            paymentRunMode: "date_ranges",
            ranges: [range(1, 15), range(16, 31)],
            recurringRunStartDay: "monday",
            recurringRunEndDay: "sunday"
        )
        let history = try XCTUnwrap(
            CanonicalBusinessEngine.paymentRunHistoryAfterChange(
                previous: previous,
                next: next,
                existingHistory: [],
                recordedAtDayKey: "2026-10-12"
            )
        )
        XCTAssertEqual(history.first?.ranges.map(\.endDay), [7, 31])
        let periods = try XCTUnwrap(
            CanonicalBusinessEngine.selectableTimesheetPaymentRunPeriods(
                current: next,
                historicalWindows: history,
                observedPeriods: [],
                referenceDayKey: "2026-10-12",
                lookbackCount: 6
            )
        )
        XCTAssertTrue(periods.contains { $0.startDayKey == "2026-10-01" && $0.endDayKey == "2026-10-07" })
        XCTAssertTrue(periods.contains { $0.startDayKey == "2026-10-01" && $0.endDayKey == "2026-10-15" })

        var settings = OrganizationInvoicingSettings.default
        settings.paymentRunHistory = history
        let map = try XCTUnwrap(CanonicalBusinessEngine.invoicingToFirestore(settings.canonicalInvoicingSettings()))
        let saved = try XCTUnwrap(map["paymentRunHistory"] as? [[String: Any]])
        XCTAssertEqual(saved.count, 1)
        XCTAssertEqual(saved[0]["paymentRunMode"] as? String, "date_ranges")
        let ranges = try XCTUnwrap(saved[0]["paymentRunDateRanges"] as? [[String: Any]])
        XCTAssertEqual(int(ranges[0]["startDay"]), 1)
        XCTAssertEqual(int(ranges[0]["endDay"]), 7)
        XCTAssertEqual(int(ranges[0]["startDate"]), 1)
        XCTAssertEqual(int(ranges[0]["endDate"]), 7)
    }

    private var signed: Date {
        Date(timeIntervalSince1970: 1_759_276_800)
    }

    private func range(_ start: Int, _ end: Int) -> CanonicalBusinessEngine.CanonicalPaymentRunRange {
        CanonicalBusinessEngine.CanonicalPaymentRunRange(startDay: start, endDay: end)
    }

    private func fields(operative: Date?, manager: Date?, exported: Date?) throws -> CanonicalBusinessEngine.CanonicalTimesheetStatusFields {
        var row: [String: Any] = [
            "operativeSignedByName": operative == nil ? "" : "Ada Lovelace",
            "operativeSignatureImageBase64": operative == nil ? "" : "sig",
            "managerSignedByName": manager == nil ? "" : "Grace Hopper",
        ]
        if let operative { row["operativeSignedAt"] = operative.timeIntervalSince1970 * 1000 }
        if let manager {
            row["managerSignedAt"] = manager.timeIntervalSince1970 * 1000
            row["approvedAt"] = manager.timeIntervalSince1970 * 1000
            row["approvedByName"] = "Grace Hopper"
        }
        if let exported { row["exportedAt"] = exported.timeIntervalSince1970 * 1000 }
        return try XCTUnwrap(CanonicalBusinessEngine.parseTimesheetStatusFields(row))
    }

    private func int(_ value: Any?) -> Int? {
        if let number = value as? Int { return number }
        if let number = value as? NSNumber { return number.intValue }
        return nil
    }
}
