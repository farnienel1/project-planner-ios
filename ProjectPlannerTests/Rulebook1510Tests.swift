import XCTest
@testable import Project_Planner

/// RULEBOOK 1.51.0 §7 (owner decisions 15 Nov, Q1–Q4) and §4.3 on iOS through `CanonicalBusinessEngine`: the weekly
/// report's Pay Summary (`weeklyReportPayRows`), Annual Leave (`weeklyReportLeaveRows`), clash Detail
/// (`weeklyReportClashDetail`), sub contractor days (`subcontractorDayValue` with hours) and the Working hours history
/// (`payrollPolicyHistoryRows`). The Pay Summary case is web's own (`lib/canonical/canonical.test.ts`, "1.51.0 owner
/// fortnight"), so the rows iOS renders are the rows web renders; expected values checked in node against the packed
/// script (rulebook 1.51.0, sha256 84d71b13…6af6ef4).
@MainActor
final class Rulebook1510Tests: XCTestCase {
    private var weekend: [String: Any] {
        [
            "allHoursAtMultiplierMode": false,
            "allHoursMultiplier": 2,
            "definedWindowStart": "07:30",
            "definedWindowEnd": "14:00",
            "countsAsStandardHours": 8,
            "outsideWindowMultiplier": 1.5,
            "breakPaid": true,
        ]
    }

    private func policy() throws -> [String: Any] {
        var base = try XCTUnwrap(CanonicalBusinessEngine.callJSON("parsePayrollPolicy", arguments: [[String: Any]()]) as? [String: Any])
        base["standardDayStart"] = "07:00"
        base["standardDayEnd"] = "16:00"
        base["unpaidBreakMinutes"] = 30
        base["breakWindowStart"] = "12:00"
        base["breakWindowEnd"] = "12:30"
        base["standardPaidHours"] = 8.5
        base["paidHoursDerived"] = true
        base["weekdayOutsideStandardMultiplier"] = 1.5
        base["saturday"] = weekend
        var sunday = weekend
        sunday["sameAsSaturday"] = false
        base["sunday"] = sunday
        return base
    }

    private func booking(_ id: String, _ dayKey: String, _ start: String, _ end: String, ot: Double? = nil) -> [String: Any] {
        var row: [String: Any] = [
            "id": id, "personId": "u-admin", "dayKey": dayKey, "timeSlot": "CUSTOM_HOURS",
            "workStartTime": start, "workEndTime": end, "status": "Confirmed",
            "jobId": "proj1", "jobNumber": "C646", "jobName": "1 Carnaby Street", "locationKind": "project",
        ]
        if let ot { row["otMultiplierOverride"] = ot }
        return row
    }

    private let adminSubject: [String: Any] = ["id": "u-admin", "email": "admin@x.com", "role": "admin", "adminAccess": true, "isActive": true]

    private func input(employmentType: String = "self_employed", viewer: [String: Any]?) throws -> [String: Any] {
        [
            "people": [[
                "id": "u-admin",
                "name": "Test Admin",
                "role": "Admin User",
                "ids": ["u-admin", "op-admin"],
                "user": ["id": "u-admin", "payBasis": "day", "dayRate": 240, "employmentType": employmentType],
                "hasLineManager": false,
                "paySubject": adminSubject,
            ]],
            "bookings": [
                booking("b02", "2026-11-02", "07:00", "16:00"),
                booking("b03", "2026-11-03", "07:00", "16:00"),
                booking("b04", "2026-11-04", "07:00", "16:00"),
                booking("b05", "2026-11-05", "07:00", "21:00"),
                booking("b06", "2026-11-06", "07:00", "23:00"),
                booking("b09", "2026-11-09", "07:00", "22:30", ot: 2),
                booking("b10", "2026-11-10", "07:00", "16:00"),
                booking("b14", "2026-11-14", "07:30", "14:00"),
                booking("b15", "2026-11-15", "07:30", "14:00"),
            ],
            "organization": try policy(),
            "payRateHistory": [
                ["id": "h1", "userId": "u-admin", "dayRate": 250, "payBasis": "day", "effectiveAt": "2026-01-01T00:00:00Z"],
                ["id": "h2", "userId": "u-admin", "dayRate": 240, "payBasis": "day", "effectiveAt": "2026-11-14T00:00:00Z"],
            ],
            "range": ["start": "2026-11-01", "end": "2026-11-15"],
            "timeZone": "Europe/London",
            "currency": "GBP",
            "roster": [adminSubject],
            "viewer": viewer.map { $0 as Any } ?? NSNull(),
        ]
    }

    /// Web's owner fortnight: five rows, £3,141.76, the same text in every cell.
    func testTheOwnersFortnightRowsMatchWeb() throws {
        let report = try XCTUnwrap(CanonicalBusinessEngine.weeklyReportPayRows(try input(viewer: adminSubject)))
        XCTAssertEqual(report.grandTotal, 3141.76, accuracy: 0.001)
        let person = try XCTUnwrap(report.people.first)
        XCTAssertEqual(person.personTotal, 3141.76, accuracy: 0.001)
        XCTAssertEqual(person.lines.map(\.dates), ["1–13 Nov", "1–13 Nov", "1–13 Nov", "14–15 Nov", "14–15 Nov"])
        XCTAssertEqual(person.lines.map(\.line), [
            "Weekday standard",
            "Weekday overtime ×1.5 (12h × 1.5 = 18h)",
            "Weekday overtime ×2 (6.5h × 2 = 13h)",
            "Saturday 14 Nov window (counts as a full day)",
            "Sunday 15 Nov window (counts as a full day)",
        ])
        XCTAssertEqual(person.lines.map(\.hours), [59.5, 18, 13, 8, 8])
        XCTAssertEqual(person.lines.map(\.days), [7, 2.12, 1.53, 1, 1])
        XCTAssertEqual(person.lines.map(\.rateText), ["£250.00/day", "£250.00/day", "£250.00/day", "£240.00/day", "£240.00/day"])
        XCTAssertEqual(person.lines.map(\.pay), [1750, 529.41, 382.35, 240, 240])
        XCTAssertNil(person.lines.first?.payLabel)
        // The check line: no sheets passed, so no timesheet yet.
        XCTAssertEqual(person.check?.label, "Timesheet: Not started · no timesheet yet")
        // The Pay Summary as the exports render it (Person | Role | Dates | Line | Hours | Days | Rate | Pay).
        let section = WeeklyReportView.paySummarySection(report)
        XCTAssertEqual(section.headers, ["Person", "Role", "Dates", "Line", "Hours", "Days", "Rate", "Pay"])
        XCTAssertEqual(section.rows.first, ["Test Admin", "Admin User", "1–13 Nov", "Weekday standard", "59.5h", "7.00", "£250.00/day", "£1,750.00"])
        XCTAssertEqual(section.rows[5], ["", "", "", "Test Admin total", "", "", "", "£3,141.76"])
        XCTAssertEqual(section.rows[6][3], "Timesheet: Not started · no timesheet yet")
        XCTAssertTrue(section.spanRows.contains(6))
        XCTAssertEqual(section.totalRow?.last, "£3,141.76")
        // RULEBOOK 1.53.0 (A9, owner confirmed 15 Nov): `weeklyReportPaySummaryNote` under the Pay Summary while labour
        // rows are shown (no pay is hidden here, so no `PAY_HIDDEN_NOTE`). Before 1.53.0 there was no note.
        XCTAssertEqual(section.note, "Days are rounded; Pay is worked out from the exact hours.")
    }

    func testAPayePersonHasNoRows() throws {
        let report = try XCTUnwrap(CanonicalBusinessEngine.weeklyReportPayRows(try input(employmentType: "paye", viewer: adminSubject)))
        XCTAssertTrue(report.people.isEmpty)
        XCTAssertEqual(report.grandTotal, 0, accuracy: 0.001)
    }

    /// A viewer who may not see this person's pay sees "—" and the hidden note; nothing is shown with no viewer.
    func testANonAdminViewerSeesNoPay() throws {
        let other: [String: Any] = ["id": "u-op", "email": "op@x.com", "role": "operative", "operativeMode": true, "isActive": true]
        let report = try XCTUnwrap(CanonicalBusinessEngine.weeklyReportPayRows(try input(viewer: other)))
        let person = try XCTUnwrap(report.people.first)
        XCTAssertEqual(person.personTotalLabel, "—")
        XCTAssertTrue(person.lines.allSatisfy { $0.payLabel == "—" })
        XCTAssertEqual(report.hiddenPeople, 1)
        XCTAssertEqual(report.grandTotal, 0, accuracy: 0.001)
        XCTAssertNotNil(WeeklyReportView.paySummarySection(report).note)

        let noViewer = try XCTUnwrap(CanonicalBusinessEngine.weeklyReportPayRows(try input(viewer: nil)))
        XCTAssertEqual(noViewer.people.first?.personTotalLabel, "—")
    }

    /// The app never passes `showAllPay`: the bridge drops it, so pay stays hidden without a viewer.
    func testShowAllPayIsNeverPassed() throws {
        var raw = try input(viewer: nil)
        raw["showAllPay"] = true
        let report = try XCTUnwrap(CanonicalBusinessEngine.weeklyReportPayRows(raw))
        XCTAssertEqual(report.people.first?.personTotalLabel, "—")
    }

    func testLeaveRowsArePerPersonAndNameAMissingPerson() throws {
        let leave = try XCTUnwrap(CanonicalBusinessEngine.weeklyReportLeaveRows(
            records: [
                ["id": "l1", "userId": "OP-ADMIN", "startDayKey": "2026-11-02", "endDayKey": "2026-11-03", "timeSlot": "FULL DAY", "status": "approved"],
                ["id": "l2", "userId": "ghost-id", "startDayKey": "2026-11-04", "endDayKey": "2026-11-04", "timeSlot": "AM", "status": "approved"],
            ],
            people: [["id": "u-admin", "name": "Test Admin", "role": "Admin User", "ids": ["u-admin", "op-admin"], "email": "admin@x.com"]],
            startDayKey: "2026-11-01",
            endDayKey: "2026-11-15",
            nonWorkingDayKeys: [],
            timeZone: "Europe/London"
        ))
        XCTAssertEqual(leave.rows.map(\.person), ["Test Admin", "Person not found (id ghost-id)"])
        XCTAssertEqual(leave.rows.map(\.days), [2, 0.5])
        XCTAssertEqual(leave.total, 2.5, accuracy: 0.001)
    }

    func testClashDetailIsFactsOnly() {
        let detail = CanonicalBusinessEngine.weeklyReportClashDetail(
            dayText: "10 Nov 2026",
            places: [("1 Carnaby Street", "07:00–16:00"), ("Office", "09:00–17:00")]
        )
        XCTAssertEqual(detail, "Booked in two places on 10 Nov 2026: 1 Carnaby Street 07:00–16:00; Office 09:00–17:00.")
        XCTAssertEqual(CanonicalBusinessEngine.weeklyReportWarningOpen, "Open")
    }

    /// Q4c: custom hours are hours worked ÷ the paid day (07:00–20:00 on an 8.5h day = 1.47), not 0.5.
    func testSubcontractorCustomHoursAreHoursOverThePaidDay() {
        XCTAssertEqual(CanonicalBusinessEngine.subcontractorDayValue("CUSTOM_HOURS", workedHours: 12.5, standardDayHours: 8.5) ?? 0, 1.47, accuracy: 0.0001)
        XCTAssertEqual(CanonicalBusinessEngine.subcontractorDayValue("FULL DAY", workedHours: nil, standardDayHours: 8.5), 1)
        XCTAssertEqual(CanonicalBusinessEngine.subcontractorDayValue("AM", workedHours: 4, standardDayHours: 8.5), 0.5)
    }

    func testWorkingHoursHistoryRows() throws {
        let current = try policy()
        let state: [String: Any] = [
            "current": current,
            "history": [
                ["effectiveFrom": "1970-01-01", "policy": current],
                ["effectiveFrom": "2026-11-03", "policy": current],
            ],
        ]
        let rows = CanonicalBusinessEngine.payrollPolicyHistoryRows(state: state, todayKey: "2026-11-15")
        XCTAssertEqual(rows.map(\.dates), ["From 3 Nov 2026", "Before 3 Nov 2026"])
        XCTAssertEqual(rows.map(\.inEffectToday), [true, false])
        XCTAssertEqual(rows.first?.overtime, "Overtime ×1.5")
        XCTAssertEqual(rows.first?.sunday.isEmpty, false)
    }
}
