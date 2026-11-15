import XCTest
@testable import Project_Planner

/// RULEBOOK 1.53.0 (calculation sweep) on iOS through `CanonicalBusinessEngine`, the cases of web
/// `lib/canonical/canonical.test.ts` "1.53.0 A1…A9" and the review of #235. Expected values checked in node against the
/// packed script (rulebook 1.53.0, sha256 886912f4…84b38b2).
@MainActor
final class Rulebook1530Tests: XCTestCase {
    private let adminSubject: [String: Any] = ["id": "u-admin", "email": "admin@x.com", "role": "admin", "adminAccess": true, "isActive": true]

    private func policy() throws -> [String: Any] {
        let weekend: [String: Any] = [
            "allHoursAtMultiplierMode": false, "allHoursMultiplier": 2, "definedWindowStart": "07:30",
            "definedWindowEnd": "14:00", "countsAsStandardHours": 8, "outsideWindowMultiplier": 1.5, "breakPaid": true,
        ]
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

    /// A1: a run signed self-employed keeps its pay on the weekly report after a later switch to PAYE (£632.35, the
    /// invoice); before 1.53.0 the 5 Nov line was dropped as a PAYE day and the report showed £500.00.
    func testSignedRunKeepsItsPayAfterALaterPayeSwitch() throws {
        let override: [String: Any] = [
            "lines": [
                ["id": "op-b02-normal", "bookingId": "b02", "date": "2026-11-02", "paidHours": 8.5, "days": 1, "amount": 250, "isOvertime": false, "payBasis": "day"],
                ["id": "op-b03-normal", "bookingId": "b03", "date": "2026-11-03", "paidHours": 8.5, "days": 1, "amount": 250, "isOvertime": false, "payBasis": "day"],
                ["id": "op-b05-normal", "bookingId": "b05", "date": "2026-11-05", "paidHours": 4.5, "days": 0.53, "amount": 132.35, "isOvertime": false, "payBasis": "day"],
                ["id": "op-b06-paye", "bookingId": "b06", "date": "2026-11-06", "paidHours": 8.5, "days": 1, "amount": 0, "isOvertime": false, "isPayeDay": true],
            ] as [[String: Any]],
            "priceWork": [] as [Any],
            "expenses": [] as [Any],
        ]
        let sheet: [String: Any] = [
            "operativeSignedAt": "2026-11-16T10:00:00Z", "operativeSignedByName": "Test Admin",
            "operativeSignatureImageBase64": "x", "weeklyReportOverride": override,
        ]
        let input: [String: Any] = [
            "people": [[
                "id": "u-admin", "name": "Test Admin", "role": "Admin", "ids": ["u-admin", "op-admin"],
                "user": [
                    "id": "u-admin", "payBasis": "day", "dayRate": 250, "employmentType": "paye",
                    "employmentTypeTransitionFrom": "self_employed", "employmentTypeEffectiveAt": "2026-11-04T00:00:00Z",
                ] as [String: Any],
                "hasLineManager": false,
                "paySubject": adminSubject,
            ] as [String: Any]],
            "bookings": [
                booking("b02", "2026-11-02", "07:00", "16:00"), booking("b03", "2026-11-03", "07:00", "16:00"),
                booking("b04", "2026-11-04", "07:00", "16:00"), booking("b05", "2026-11-05", "07:00", "21:00"),
                booking("b06", "2026-11-06", "07:00", "23:00"), booking("b09", "2026-11-09", "07:00", "22:30", ot: 2),
                booking("b10", "2026-11-10", "07:00", "16:00"), booking("b14", "2026-11-14", "07:30", "14:00"),
                booking("b15", "2026-11-15", "07:30", "14:00"),
            ],
            "organization": try policy(),
            "payRateHistory": [] as [Any],
            "range": ["start": "2026-11-01", "end": "2026-11-15"],
            "timeZone": "Europe/London",
            "currency": "GBP",
            "roster": [adminSubject],
            "viewer": adminSubject,
            "timesheetWeeks": [["userId": "u-admin", "weekStart": "2026-11-01", "weekEnd": "2026-11-15", "override": override] as [String: Any]],
            "sheets": [["personId": "u-admin", "startDayKey": "2026-11-01", "endDayKey": "2026-11-15", "sheet": sheet, "payrollLines": [] as [Any]] as [String: Any]],
        ]
        let report = try XCTUnwrap(CanonicalBusinessEngine.weeklyReportPayRows(input))
        let person = try XCTUnwrap(report.people.first)
        XCTAssertEqual(person.personTotal, 632.35, accuracy: 0.001)
        XCTAssertEqual(person.check?.label, "Timesheet: Signed · Invoice £632.35 ✓")
    }

    /// A2: a declined labour line counts no hours (`timesheetTotals.hours`).
    func testDeclinedLabourLineCountsNoHours() throws {
        let lines: [[String: Any]] = [
            ["id": "op-B1-normal", "amount": 200, "dayKey": "2026-10-20", "paidHours": 8, "bookingPaidHours": 9.5, "bookingOvertimeHours": 1, "isOvertimeLine": false],
            ["id": "op-B1-ot", "amount": 37.5, "dayKey": "2026-10-20", "paidHours": 1, "otMultiplier": 1.5, "isOvertimeLine": true],
            ["id": "op-B2-normal", "amount": 200, "dayKey": "2026-10-21", "paidHours": 8, "bookingPaidHours": 8, "isOvertimeLine": false],
        ]
        let sheet: [String: Any] = [
            "managerSignedAt": "2026-10-25T10:00:00Z",
            "payrollLineReviews": ["op-B2-normal": ["decision": "declined"], "op-B1-ot": ["decision": "declined"]],
        ]
        let totals = try XCTUnwrap(CanonicalBusinessEngine.callJSON(
            "timesheetTotals", arguments: [["sheet": sheet, "payrollLines": lines, "extrasMode": "decided"] as [String: Any]]
        ) as? [String: Any])
        XCTAssertEqual((totals["labour"] as? NSNumber)?.doubleValue, 200)
        XCTAssertEqual((totals["hours"] as? NSNumber)?.doubleValue, 8)
        XCTAssertEqual((totals["overtimeHours"] as? NSNumber)?.doubleValue, 0)
    }

    /// A4: undo removes every stored document of the clash, matched ignoring case and order.
    func testClashUndoFindsEveryDocument() throws {
        let docs = try XCTUnwrap(CanonicalBusinessEngine.clashDocumentsToRemove(
            bookingAId: "a-1",
            bookingBId: "B-2",
            resolutionKey: nil,
            acceptedClashes: [(id: "B-2|A-1", bookingAId: nil, bookingBId: nil), (id: "other", bookingAId: "b-2", bookingBId: "a-1"), (id: "x|y", bookingAId: nil, bookingBId: nil)],
            resolutions: [(id: "B-2|A-1", resolutionKey: nil), (id: "r2", resolutionKey: "a-1|b-2"), (id: "mgr-clash-x", resolutionKey: nil)]
        ))
        XCTAssertEqual(docs.acceptedClash, ["a-1|B-2", "B-2|A-1", "other"])
        XCTAssertEqual(docs.resolution, ["a-1|B-2", "B-2|A-1", "r2"])
        // An approval saved under the old order still approves the clash.
        let approved = CanonicalBusinessEngine.callJSON(
            "isClashApproved", arguments: [["bookingAId": "a-1", "bookingBId": "B-2"], ["approvedKeys": ["b-2|A-1"]]]
        ) as? Bool
        XCTAssertEqual(approved, true)
    }

    /// A6: Up next under every id the viewer goes by; today kept all day; Completed kept; cancelled and past left out.
    func testHomeUpNextRows() throws {
        let book = { (id: String, person: String, day: String, status: String, slot: String, start: String?, end: String?) in
            RulebookHomeUpNextBooking(id: id, personId: person, dayKey: day, status: status, timeSlot: slot, workStartTime: start, workEndTime: end)
        }
        let answer = try XCTUnwrap(CanonicalBusinessEngine.homeUpNextRows(
            now: Date(timeIntervalSince1970: 1_794_830_400), // Monday 16 Nov 2026, 12:00 UTC
            timeZone: "Europe/London",
            viewer: ["id": "U-SAM", "email": "sam@x.com"],
            roster: [
                ["id": "U-SAM", "email": "sam@x.com", "formerUserIds": ["invite-1"]],
                ["id": "u-sam-2", "email": "SAM@x.com"],
                ["id": "u-other", "email": "o@x.com"],
            ],
            operatives: [["id": "op-sam", "email": "Sam@X.com"]],
            bookings: [
                book("b-today", "OP-SAM", "2026-11-16", "Confirmed", "CUSTOM_HOURS", "07:30", "16:00"),
                book("b-done", "u-sam-2", "2026-11-17", "Completed", "FULL DAY", nil, nil),
                book("b-invite", "INVITE-1", "2026-11-18", "Tentative", "FULL DAY", nil, nil),
                book("b-cancelled", "op-sam", "2026-11-17", "Cancelled", "FULL DAY", nil, nil),
                book("b-past", "op-sam", "2026-11-15", "Confirmed", "FULL DAY", nil, nil),
                book("b-other", "u-other", "2026-11-16", "Confirmed", "FULL DAY", nil, nil),
            ],
            managerSiteBookings: [
                RulebookHomeUpNextBooking(id: "m1", personId: "U-SAM-2", dayKey: "2026-11-17", status: nil, timeSlot: "CUSTOM_HOURS", workStartTime: "06:00", workEndTime: "09:00"),
            ],
            policy: ["standardDayStart": "07:30", "standardDayEnd": "16:00"]
        ))
        XCTAssertEqual(answer.rows.map(\.id), ["b-today", "m1", "b-done", "b-invite"])
        XCTAssertEqual(answer.rows.map(\.startText), ["07:30", "06:00", "07:30", "07:30"])
        XCTAssertEqual(answer.rows.first?.timeRange, "07:30–16:00")
        XCTAssertEqual(answer.days.map(\.dayKey), ["2026-11-16", "2026-11-17"])
    }

    /// A7: a bank holiday or weekend inside a week of leave is not a leave day on Daily Overview.
    func testDailyOverviewLeaveSkipsBankHolidays() throws {
        let records = [
            (id: "L1", startDayKey: "2026-12-21", endDayKey: "2026-12-29", timeSlot: "FULL DAY", status: "approved"),
            (id: "L2", startDayKey: "2026-12-28", endDayKey: "2026-12-28", timeSlot: "AM", status: "pending"),
            (id: "L3", startDayKey: "2026-12-24", endDayKey: "2026-12-24", timeSlot: "PM", status: "Accepted"),
        ]
        let bank = ["2026-12-25", "2026-12-28"]
        func ids(_ day: String) -> Set<String>? {
            CanonicalBusinessEngine.dailyOverviewLeaveRecordIds(records: records, dayKey: day, timeZone: "Europe/London", bankHolidayDayKeys: bank)
        }
        XCTAssertEqual(ids("2026-12-24"), ["L1", "L3"])
        XCTAssertEqual(ids("2026-12-25"), [])
        XCTAssertEqual(ids("2026-12-26"), [])
        XCTAssertEqual(ids("2026-12-29"), ["L1"])
    }

    /// 1.53.0 §5: a booking crossing midnight clashes with the next morning's booking that starts before it ends
    /// (Book labour now checks the day before, the day and the day after); a booking two days away never.
    func testOvernightBookingClashesTheNextMorning() throws {
        let request = RulebookClashBooking(id: "new", dayKey: "2026-11-16", timeSlot: "CUSTOM_HOURS", workStartTime: "22:00", workEndTime: "06:00")
        let nextMorning = RulebookClashBooking(id: "next", dayKey: "2026-11-17", timeSlot: "CUSTOM_HOURS", workStartTime: "05:00", workEndTime: "09:00")
        let later = RulebookClashBooking(id: "later", dayKey: "2026-11-17", timeSlot: "CUSTOM_HOURS", workStartTime: "06:00", workEndTime: "09:00")
        XCTAssertTrue(BookingClashWindow.clashes(request: request, existing: [nextMorning], policy: .default))
        XCTAssertFalse(BookingClashWindow.clashes(request: request, existing: [later], policy: .default))
        let day = try XCTUnwrap(OrganizationRulebookContext.date(fromDayKey: "2026-11-16"))
        XCTAssertEqual(BookingClashWindow.dayKeys(around: day), ["2026-11-15", "2026-11-16", "2026-11-17"])
    }

    /// A9 and the Role column: Days rounded with the note; the user level, never "Admin User".
    func testWeeklyReportDaysNoteAndRole() {
        XCTAssertEqual(CanonicalBusinessEngine.weeklyReportDaysText(18 / 8.5, kind: "weekdayOvertime"), "2.12")
        let labour = RulebookWeeklyReportPayRow(kind: "weekdayOvertime", dates: "", line: "", hours: 18, days: 2.12, daysExact: 18 / 8.5, rateText: "", pay: 529.41, payLabel: nil, source: "live")
        let claim = RulebookWeeklyReportPayRow(kind: "expenses", dates: "", line: "", hours: 0, days: 0, rateText: "", pay: 40, payLabel: nil, source: "claim")
        XCTAssertEqual(CanonicalBusinessEngine.weeklyReportPaySummaryNote([labour]), "Days are rounded; Pay is worked out from the exact hours.")
        XCTAssertEqual(CanonicalBusinessEngine.weeklyReportPaySummaryNote([claim]), "")
        let superAdmin = AppUser(id: "sa", email: "sa@x.com", organizationId: "org", role: .admin, isSuperAdmin: true)
        let manager = AppUser(id: "m", email: "m@x.com", organizationId: "org", role: .manager, permissions: UserPermissions(manager: true))
        XCTAssertEqual(WeeklyReportView.userLevelText(superAdmin), "Admin (Super Admin)")
        XCTAssertEqual(WeeklyReportView.userLevelText(manager), "Manager")
        XCTAssertEqual(WeeklyReportView.userLevelText(nil), "Operative")
        XCTAssertEqual(CanonicalBusinessEngine.bookingJobLabel(nil), "Deleted job")
    }

    /// Review of #235 (1): the check line's line manager is an ACTIVE one (`hasActiveLineManager`), as web.
    func testWeeklyReportPersonNeedsAnActiveLineManager() throws {
        func hasLineManager(managerActive: Bool) throws -> Bool? {
            let lineManager = AppUser(id: "lm", email: "lm@x.com", organizationId: "org", role: .manager, isActive: managerActive, passwordSet: true, permissions: UserPermissions(manager: true))
            let person = AppUser(id: "p", email: "p@x.com", organizationId: "org", role: .operative, passwordSet: true, assignedManagerUserIds: ["lm"])
            let built = WeeklyReportPayInputs.build(WeeklyReportPayInputs.Sources(
                users: [person, lineManager],
                bookingNameUsers: [person, lineManager],
                operatives: [],
                bookings: [],
                managerBookings: [],
                projects: [],
                smallWorks: [],
                history: .empty,
                organization: [:],
                startDayKey: "2026-11-01",
                endDayKey: "2026-11-15",
                roleLabel: { _ in "Operative" }
            ))
            let people = try XCTUnwrap(built.input["people"] as? [[String: Any]])
            return people.first { ($0["id"] as? String) == "p" }?["hasLineManager"] as? Bool
        }
        XCTAssertEqual(try hasLineManager(managerActive: false), false)
        XCTAssertEqual(try hasLineManager(managerActive: true), true)
    }
}
