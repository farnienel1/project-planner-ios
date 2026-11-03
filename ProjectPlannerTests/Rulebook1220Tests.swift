import XCTest
@testable import Project_Planner

/// RULEBOOK 1.22.0 "Money" (§6–§9, §22) on iOS through `CanonicalBusinessEngine`. Every expected value was checked in
/// node against the packed `canonical-business.js` (rulebook 1.22.0, sha256 574ee5b0…73bce27) with the JSON these
/// wrappers send. The 1.22.0 parity-fixture cases themselves run in `CanonicalParityFixtureTests`.
@MainActor
final class Rulebook1220Tests: XCTestCase {
    private let london = "Europe/London"

    private func fixtureArgument(_ function: String, index: Int = 0) throws -> [String: Any] {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "CanonicalParityFixture", withExtension: "json"))
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let cases = try XCTUnwrap(root["cases"] as? [[String: Any]]).filter { $0["function"] as? String == function }
        let args = try XCTUnwrap(cases[index]["args"] as? [Any])
        return try XCTUnwrap(args.first as? [String: Any])
    }

    func testThePackedScriptIsRulebook1220OrLater() throws {
        let stamp = try XCTUnwrap(CanonicalBusinessEngine.rulebookStamp())
        let parts = stamp.version.split(separator: ".").compactMap { Int($0) }
        XCTAssertFalse(parts.lexicographicallyPrecedes([1, 22, 0]), "rulebook \(stamp.version) predates 1.22.0")
        let names = Set(CanonicalBusinessEngine.exportNames())
        for name in [
            "timesheetTotals", "leaveReportRows", "leaveReportDayCount", "leaveReportYears", "mergeTimesheetFeedWeeks",
            "timesheetFeedCovers", "timesheetFeedLabourLines", "timesheetFeedMoneyLines", "weeklyReportTimesheetFeed",
            "nextVariationNumber", "variationNumberTaken", "variationNumberValue", "formatVariationNumber",
            "managerCoverageHours",
        ] {
            XCTAssertTrue(names.contains(name), "\(name) missing from the packed script")
        }
    }

    // MARK: Timesheet totals (§8)

    /// A declined expense, a revised price-work entry, a stale review and a PAYE day: the total is 512.5 and equals
    /// the invoice (`timesheetInvoiceRows`) for the same input.
    func testSheetTotalEqualsTheInvoice() throws {
        let input = try fixtureArgument("timesheetTotals")
        let totals = try XCTUnwrap(CanonicalBusinessEngine.timesheetTotals(input))
        XCTAssertClose(totals.total, 512.5)
        XCTAssertClose(totals.labour, 237.5)
        XCTAssertClose(totals.priceWork, 250)
        XCTAssertClose(totals.expenses, 25, "declined skip out; the stale parking review counts its own 25")
        XCTAssertClose(totals.hours, 9.5)
        XCTAssertClose(totals.overtimeHours, 1)
        XCTAssertEqual(totals.pendingEntries, 1)
        let rows = try XCTUnwrap(CanonicalBusinessEngine.callJSON("timesheetInvoiceRows", arguments: [input]) as? [[String: Any]])
        let invoice = rows.reduce(0) { $0 + ((($1["amount"] as? NSNumber)?.doubleValue) ?? 0) }
        XCTAssertClose(totals.total, invoice)
    }

    /// The same sheet from Swift models: collector-shaped lines (the booking's paid and overtime hours on the standard
    /// line, a PAYE day) and a signed draft with a declined expense and a revised price-work entry.
    func testSwiftLinesAndDraftGiveTheInvoiceTotal() throws {
        let day = LogicFixtures.day(2026, 10, 20)
        let normal = TimesheetPayrollLineItem(
            id: "op-B1-normal", date: day, jobNumber: "100", projectName: "Site", details: "07:30–17:30",
            paidHours: 8, payrollBasis: .dayRate, dayRate: 200, hourlyRate: nil, amount: 200, isPayeDay: false,
            isOvertimeLine: false, bookingId: "op-B1", bookingPaidHours: 9.5, bookingOvertimeHours: 1
        )
        let overtime = TimesheetPayrollLineItem(
            id: "op-B1-ot", date: day, jobNumber: "100", projectName: "Site (Overtime)", details: "OT 1h",
            paidHours: 1, payrollBasis: .dayRate, dayRate: 37.5, hourlyRate: nil, amount: 37.5, isPayeDay: false,
            isOvertimeLine: true, bookingId: "op-B1", otMultiplier: 1.5, otClockHours: 1
        )
        let paye = TimesheetPayrollLineItem(
            id: "op-B2-normal", date: LogicFixtures.day(2026, 10, 23), jobNumber: "100", projectName: "Site",
            details: "Full day", paidHours: 8, payrollBasis: .dayRate, dayRate: 0, hourlyRate: nil, amount: 0,
            isPayeDay: true, isOvertimeLine: false, bookingId: "op-B2", bookingPaidHours: 8, bookingOvertimeHours: 0
        )
        var draft = TimesheetDraft(
            expenseEntries: [
                TimesheetExpenseEntry(id: UUID(), title: "Skip", details: "", jobNumber: "100", date: day, amount: 40, managerDecision: .declined),
                TimesheetExpenseEntry(id: UUID(), title: "Parking", details: "", jobNumber: "100", date: day, amount: 25, managerDecision: .approved),
            ],
            priceWorkEntries: [
                TimesheetPriceWorkEntry(
                    id: UUID(), title: "Tiling", details: "", jobNumber: "100", agreedManagerName: "Manager",
                    startDate: day, amount: 300, managerDecision: .edited, managerRevisedAmount: 250
                ),
            ]
        )
        draft.managerSignedAt = day
        let signed = try XCTUnwrap(TimesheetTotalsSource.totals(lines: [normal, overtime, paye], draft: draft, decided: true))
        XCTAssertClose(signed.total, 512.5)
        XCTAssertClose(signed.standardLabour, 200)
        XCTAssertClose(signed.overtimeLabour, 37.5)
        XCTAssertClose(signed.hours, 17.5, "9.5 weighted on the booked day + 8 on the PAYE day")
        XCTAssertEqual(signed.invoiceRowCount, 4, "two labour rows (no PAYE row), price work and parking")
        var unsigned = draft
        unsigned.managerSignedAt = nil
        let raw = try XCTUnwrap(TimesheetTotalsSource.totals(lines: [normal, overtime, paye], draft: unsigned, decided: false))
        XCTAssertClose(raw.total, 602.5, "before review every entry counts at its own amount")
        XCTAssertClose(raw.submittedExtras, 365)
    }

    // MARK: Holiday Report (§9)

    func testLeaveReportSkipsWeekendsAndBankHolidaysAndMatchesTheBalance() throws {
        let nonWorking = ["2026-12-25", "2026-12-28", "2027-01-01"]
        let records = [
            RulebookLeaveReportRecord(id: "H1", userId: "USER-A", operativeId: nil, startDayKey: "2026-12-21", endDayKey: "2027-01-08", timeSlot: "FULL DAY", status: "approved"),
            RulebookLeaveReportRecord(id: "H2", userId: "user-a", operativeId: nil, startDayKey: "2027-02-05", endDayKey: "2027-02-05", timeSlot: "AM", status: "approved"),
            RulebookLeaveReportRecord(id: "H3", userId: nil, operativeId: "OP-A", startDayKey: "2027-03-06", endDayKey: "2027-03-08", timeSlot: "FULL DAY", status: "approved"),
        ]
        let report = try XCTUnwrap(CanonicalBusinessEngine.leaveReportRows(
            records: records, personIds: ["user-a", "op-a"], onDayKey: "2027-02-01", startMonth: 1, timeZone: london,
            nonWorkingDayKeys: nonWorking
        ))
        XCTAssertEqual(report.year.startDayKey, "2027-01-01")
        XCTAssertEqual(report.rows.map(\.id), ["H3", "H2", "H1"])
        XCTAssertEqual(report.rows.map(\.days), [1, 0.5, 5], "Sat–Mon is 1 day; AM is 0.5; Christmas and New Year out")
        XCTAssertClose(report.totalDays, 6.5)

        let balance = try XCTUnwrap(CanonicalBusinessEngine.annualLeaveBalance(
            annualLeaveEnabled: true, daysPerYear: 25, startMonth: 1, endMonth: 12, orgDaysPerYear: 25, orgStartMonth: 1,
            orgEndMonth: 12, carriesOver: false, yearAllowance: nil, yearAllowanceKey: nil,
            bookings: records.map {
                CanonicalBusinessEngine.CanonicalLeaveBooking(startDayKey: $0.startDayKey, endDayKey: $0.endDayKey, timeSlot: $0.timeSlot, status: $0.status)
            },
            onDayKey: "2027-02-01", nonWorkingDayKeys: nonWorking, timeZone: london
        ))
        XCTAssertClose(balance.taken, report.totalDays)
    }

    func testLeaveReportYearsFollowTheLeaveYearStart() throws {
        let years = try XCTUnwrap(CanonicalBusinessEngine.leaveReportYears(firstDayKey: "2024-06-10", todayDayKey: "2026-11-03", startMonth: 4))
        XCTAssertEqual(years.map(\.startDayKey), ["2026-04-01", "2025-04-01", "2024-04-01"])
        XCTAssertEqual(years.first?.endDayKey, "2027-03-31")
    }

    // MARK: Variation numbers (§22)

    func testVariationNumbersUseTrailingDigitsAndNeverReuseDeleted() {
        XCTAssertEqual(CanonicalBusinessEngine.nextVariationNumber(existingNumbers: ["V2-001", "V2-003", "V2-002"], prefix: "V2-", padding: 3), "V2-004")
        XCTAssertEqual(CanonicalBusinessEngine.variationNumberValue("V2-003"), 3)
        let deleted = LogicFixtures.variation(id: "4", voNumber: "VO-004", sequence: 4, isDeleted: true)
        let live = LogicFixtures.variation(id: "1", voNumber: "VO-001", sequence: 1)
        XCTAssertEqual(VariationNumbering.nextFree(existing: [live, deleted]), "VO-005", "deleted VO-004 is not reused")
        XCTAssertEqual(
            CanonicalBusinessEngine.variationNumberTaken(existing: [(id: "A", voNumber: "VO-004", isDeleted: true)], voNumber: " vo-004 ", exceptId: nil),
            true
        )
        XCTAssertEqual(
            CanonicalBusinessEngine.variationNumberTaken(existing: [(id: "ABC", voNumber: "VO-004", isDeleted: false)], voNumber: "VO-004", exceptId: "abc"),
            false
        )
    }

    // MARK: Booked cover (§6)

    func testEarlyBlockKeepsEveryHourAndCoveredIsStandardDayCoverage() throws {
        let day = LogicFixtures.day(2026, 11, 2)
        let early = LogicFixtures.managerBooking(on: day, start: "06:00", end: "09:00")
        let coverage = try XCTUnwrap(CanonicalBusinessEngine.managerCoverageHours(
            bookings: [early.rulebookCoverageBooking], dayKey: "2026-11-02", policy: .default, timeZone: london
        ))
        XCTAssertClose(coverage.paidHours, 3, "06:00–09:00 never crosses lunch: no break comes off")
        XCTAssertClose(coverage.coveredHours, 1.5)
        XCTAssertClose(coverage.missingHours, 6.5)
        XCTAssertFalse(coverage.covered)

        let standard = try XCTUnwrap(CanonicalBusinessEngine.callJSON(
            "standardDayCoverage",
            arguments: [try XCTUnwrap(CanonicalBusinessEngine.payrollPolicyJSON(.default)), [early.rulebookCoverageBooking.json]]
        ) as? [String: Any])
        XCTAssertClose((standard["missingHours"] as? NSNumber)?.doubleValue ?? -1, coverage.missingHours)

        let morning = LogicFixtures.managerBooking(on: day, start: "07:30", end: "12:00")
        let afternoon = LogicFixtures.managerBooking(on: day, start: "12:30", end: "16:00")
        let both = try XCTUnwrap(CanonicalBusinessEngine.managerCoverageHours(
            bookings: [morning.rulebookCoverageBooking, afternoon.rulebookCoverageBooking], dayKey: "2026-11-02",
            policy: .default, timeZone: london
        ))
        XCTAssertTrue(both.covered, "either side of lunch covers the standard day")
        XCTAssertClose(both.paidHours, 8)
    }
}
