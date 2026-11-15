import XCTest
@testable import Project_Planner

/// RULEBOOK 1.49.0 (owner decisions 15 Nov): a weekend full day pays one day rate, weekend "Counts as" follows
/// Monday–Friday by default, and the unpaid break is allowed for in "counts as". Everything through
/// `CanonicalBusinessEngine` (`payrollHoursResult` with its `standardPartDayHours` / `overtimePartDayHours`,
/// `payForHours`, `weekendCountsAsHours`, `validatePayrollTimePolicy`). Expected values were checked in node against the
/// packed script this branch mirrors and match web `lib/weekly-report/weekendDayRate149.test.ts`.
@MainActor
final class Rulebook1490Tests: XCTestCase {
    private let org = "TEST-org-149"

    override func setUp() {
        super.setUp()
        OrganizationRulebookContext.update(from: Organization(firestoreDocumentId: org, name: "TEST-Company 149"))
    }

    override func tearDown() {
        OrganizationRulebookContext.update(from: nil)
        super.tearDown()
    }

    /// 07:00–16:00, 30 min unpaid 12:00–12:30 (8.5h day), ×1.5; Saturday and Sunday 07:30–14:00 counts as 8 (paid break).
    private var ownerPolicy: OrgPayrollTimePolicy {
        var policy = OrgPayrollTimePolicy.default
        policy.standardDayStart = "07:00"
        policy.standardDayEnd = "16:00"
        policy.unpaidBreakMinutes = 30
        policy.breakPaid = false
        policy.breakWindowStart = "12:00"
        policy.breakWindowEnd = "12:30"
        policy.standardPaidHours = 8.5
        policy.paidHoursDerived = true
        policy.weekdayOutsideStandardMultiplier = 1.5
        let weekend = OrgWeekendDayPayrollSettings(
            allHoursAtMultiplierMode: false,
            allHoursMultiplier: 2,
            useCustomStandardDayWindow: true,
            customStandardStart: "07:30",
            customStandardEnd: "14:00",
            countsAsHours: 8,
            outsideStandardWindowMultiplier: 1.5,
            breakPaid: true
        )
        policy.saturday = weekend
        policy.sunday = weekend
        policy.sundaySameAsSaturday = false
        return policy
    }

    private func booking(_ dayKey: String, _ start: String, _ end: String, ot: Double? = nil, operativeId: UUID) -> Booking {
        Booking(
            operativeId: operativeId,
            projectId: UUID(),
            date: OrganizationRulebookContext.date(fromDayKey: dayKey)!,
            timeSlot: .customHours,
            bookedBy: "TEST-Admin",
            workStartTime: start,
            workEndTime: end,
            otMultiplierOverride: ot
        )
    }

    private func historyRow(_ userId: String, _ dayKey: String, _ rate: Double) -> OperativeDayRateHistoryEntry {
        let day = OrganizationRulebookContext.date(fromDayKey: dayKey)!
        return OperativeDayRateHistoryEntry(id: UUID(), userId: userId, operativeId: nil, dayRate: rate, effectiveAt: day, createdAt: day)
    }

    /// The owner's reference fortnight (2–15 Nov): Mon–Fri at £250/day, the rate changed to £240 from Sat 14 Nov, and a
    /// full Saturday and Sunday window. Driven through the real `TimesheetPayrollCollector`, the invoice rows
    /// (`TimesheetInvoiceRows` → `timesheetInvoiceRows` + `invoiceLines`), the timesheet total (`timesheetTotals`) and the
    /// weekly report rows (`WeeklyReportPayInputs` → `weeklyReportPayRows`, 1.51.0) — every figure is the app's.
    func testTheOwnersReferenceFortnightIs3141Point76OnTheTimesheetTheInvoiceAndTheWeeklyReport() throws {
        let policy = ownerPolicy
        let user = LogicFixtures.selfEmployedUser(id: "TEST-user-149", email: "test-149@example.com", dayRate: 240)
        let operative = LogicFixtures.operative(id: UUID(), email: user.email, dayRate: 240)
        let history = OperativeDayRateHistoryCollection(
            byUserId: [user.id: [historyRow(user.id, "2026-10-01", 250), historyRow(user.id, "2026-11-14", 240)]],
            byOperativeId: [:]
        )
        let bookings = [
            booking("2026-11-02", "07:00", "16:00", operativeId: operative.id),
            booking("2026-11-03", "07:00", "16:00", operativeId: operative.id),
            booking("2026-11-04", "07:00", "16:00", operativeId: operative.id),
            booking("2026-11-05", "07:00", "21:00", operativeId: operative.id),
            booking("2026-11-06", "07:00", "23:00", operativeId: operative.id),
            booking("2026-11-09", "07:00", "22:30", ot: 2, operativeId: operative.id),
            booking("2026-11-10", "07:00", "16:00", operativeId: operative.id),
            booking("2026-11-14", "07:30", "14:00", operativeId: operative.id),
            booking("2026-11-15", "07:30", "14:00", operativeId: operative.id),
        ]
        let start = try XCTUnwrap(OrganizationRulebookContext.date(fromDayKey: "2026-11-02"))
        let end = try XCTUnwrap(OrganizationRulebookContext.date(fromDayKey: "2026-11-15"))

        // 1. The timesheet (collector).
        let summary = TimesheetPayrollCollector.collect(
            for: user,
            in: start...end,
            bookings: bookings,
            managerBookings: [],
            operatives: [operative],
            projects: [],
            smallWorks: [],
            history: history,
            policy: policy
        )
        XCTAssertFalse(summary.calculationFailed)
        XCTAssertEqual(CanonicalBusinessEngine.roundPennies(summary.workAmount), 3141.76, accuracy: 0.001)
        let weekendLines = summary.lineItems.filter {
            let key = OrganizationRulebookContext.dayKey($0.date)
            return key == "2026-11-14" || key == "2026-11-15"
        }
        XCTAssertEqual(weekendLines.count, 2, "a full window has no overtime line")
        for line in weekendLines {
            XCTAssertEqual(line.amount, 240, accuracy: 0.001)
            XCTAssertEqual(line.paidHours / (line.standardDayHours ?? 0), 1, accuracy: 0.0001, "1.00 day on its counts-as")
        }

        // 2. The timesheet total (`timesheetTotals`, the sum of the invoice rows).
        let totals = try XCTUnwrap(TimesheetTotalsSource.totals(
            lines: summary.lineItems, draft: TimesheetDraft(), decided: false, subject: user, period: start...end
        ))
        XCTAssertEqual(totals.total, 3141.76, accuracy: 0.001)

        // 3. The invoice rows.
        let invoice = InvoiceLineItem.invoiceLines(TimesheetInvoiceRows.rows(
            for: user, summary: summary, draft: TimesheetDraft(), extrasMode: .raw, period: start...end
        ))
        XCTAssertFalse(invoice.isEmpty)
        XCTAssertEqual(CanonicalBusinessEngine.roundPennies(invoice.reduce(0) { $0 + $1.amount }), 3141.76, accuracy: 0.001)

        // 4. The weekly report rows (RULEBOOK 1.51.0 §7): the screen's own input builder (`WeeklyReportPayInputs`) and
        // `weeklyReportPayRows` — the person sees their own pay.
        let built = WeeklyReportPayInputs.build(WeeklyReportPayInputs.Sources(
            users: [user],
            bookingNameUsers: [user],
            operatives: [operative],
            bookings: bookings,
            managerBookings: [],
            projects: [],
            smallWorks: [],
            history: history,
            organization: try XCTUnwrap(CanonicalBusinessEngine.memoisedPayrollPolicyJSON(policy)),
            startDayKey: "2026-11-02",
            endDayKey: "2026-11-15",
            viewer: user.payAccessSubject,
            currency: "GBP",
            roleLabel: { _ in "Operative" }
        ))
        let report = try XCTUnwrap(CanonicalBusinessEngine.weeklyReportPayRows(built.input))
        XCTAssertEqual(report.people.count, 1)
        let person = try XCTUnwrap(report.people.first)
        XCTAssertEqual(person.personTotal, 3141.76, accuracy: 0.001)
        XCTAssertEqual(report.grandTotal, 3141.76, accuracy: 0.001)
        XCTAssertEqual(person.lines.count, 5)
        XCTAssertEqual(person.lines.map(\.line), [
            "Weekday standard",
            "Weekday overtime ×1.5 (12h × 1.5 = 18h)",
            "Weekday overtime ×2 (6.5h × 2 = 13h)",
            "Saturday 14 Nov window (counts as a full day)",
            "Sunday 15 Nov window (counts as a full day)",
        ])
        let saturday = try XCTUnwrap(person.lines.first { $0.line.hasPrefix("Saturday") })
        XCTAssertEqual(saturday.days, 1, accuracy: 0.0001, "Saturday: 1.00 day")
        XCTAssertEqual(saturday.pay, 240, accuracy: 0.001)
        XCTAssertEqual(saturday.rateText, "£240.00/day")
        // The Project Breakdown's paid days tie to the Pay Summary's days.
        let paidDays = report.paidDays.reduce(0) { $0 + $1.days }
        XCTAssertEqual(paidDays, person.lines.reduce(0) { $0 + $1.days }, accuracy: 0.01)
    }

    func testSameAsMondayToFridayPaysOneDayAndHourlyPaysTheWeekdayDay() throws {
        var policy = ownerPolicy
        policy.saturday.countsAsFollowsWeekday = true
        policy.saturday.breakPaid = false
        XCTAssertEqual(CanonicalBusinessEngine.weekendCountsAsHours(policy.saturday, policy: policy), 8.5, accuracy: 0.0001)
        func saturdayAmount(_ user: AppUser) throws -> Double {
            let operative = LogicFixtures.operative(id: UUID(), email: user.email, dayRate: user.dayRate ?? 0)
            let day = try XCTUnwrap(OrganizationRulebookContext.date(fromDayKey: "2026-11-14"))
            let summary = TimesheetPayrollCollector.collect(
                for: user,
                in: day...day,
                bookings: [booking("2026-11-14", "07:30", "14:00", operativeId: operative.id)],
                managerBookings: [],
                operatives: [operative],
                projects: [],
                smallWorks: [],
                history: .empty,
                policy: policy
            )
            XCTAssertFalse(summary.calculationFailed)
            return summary.workAmount
        }
        let dayRate = LogicFixtures.selfEmployedUser(id: "TEST-day", email: "test-day@example.com", dayRate: 240)
        XCTAssertEqual(try saturdayAmount(dayRate), 240, accuracy: 0.001)
        var hourly = LogicFixtures.selfEmployedUser(id: "TEST-hourly", email: "test-hourly@example.com", dayRate: 0)
        hourly.dayRate = nil
        hourly.payBasis = "hourly"
        hourly.hourlyRate = 30
        XCTAssertEqual(try saturdayAmount(hourly), 255, accuracy: 0.001, "8.5h × £30")
    }

    func testCountsAsHasOneReaderAndOneFallback() {
        var unset = ownerPolicy.saturday
        unset.countsAsHours = nil
        XCTAssertEqual(CanonicalBusinessEngine.weekendCountsAsHours(unset, policy: ownerPolicy), 8, "the rulebook fallback is 8, never the weekday day")
        XCTAssertEqual(CanonicalBusinessEngine.weekendCountsAsHours(ownerPolicy.saturday, policy: ownerPolicy), 8)
    }

    func testSettingsRoundTripTheSameAsMondayToFridayFlag() throws {
        var policy = ownerPolicy
        policy.saturday.countsAsFollowsWeekday = true
        let stored = policy.asFirestoreDictionary()
        let saturday = try XCTUnwrap(stored["saturday"] as? [String: Any])
        XCTAssertEqual(saturday["countsAsFollowsWeekday"] as? Bool, true)
        XCTAssertEqual(try XCTUnwrap(saturday["countsAsHours"] as? Double), 8.5, accuracy: 0.0001, "the derived value is written for older builds")
        let sunday = try XCTUnwrap(stored["sunday"] as? [String: Any])
        XCTAssertNil(sunday["countsAsFollowsWeekday"], "left out when off, as web")
        let back = OrgPayrollTimePolicy.fromFirestore(stored)
        XCTAssertEqual(back.saturday.countsAsFollowsWeekday, true)
        XCTAssertNil(back.sunday.countsAsFollowsWeekday)
        // The script reads it too (`parsePayrollPolicy`), so the save write fields keep it.
        let json = try XCTUnwrap(CanonicalBusinessEngine.payrollPolicyJSON(policy))
        XCTAssertEqual((json["saturday"] as? [String: Any])?["countsAsFollowsWeekday"] as? Bool, true)
        let derived = try XCTUnwrap(CanonicalBusinessEngine.withDerivedWeekdayPaidHours(policy))
        XCTAssertEqual(derived.saturday.countsAsFollowsWeekday, true)
    }

    func testTheCapAndTheHalfHourStepAreCheckedWithPrevious() {
        var tooMany = ownerPolicy
        tooMany.saturday.countsAsHours = 9
        XCTAssertEqual(
            CanonicalBusinessEngine.validatePayrollTimePolicy(tooMany, previous: ownerPolicy),
            "Saturday counts-as hours can't be more than the Monday–Friday paid day (8.5h)."
        )
        var offStep = ownerPolicy
        offStep.saturday.countsAsHours = 7.3
        XCTAssertEqual(
            CanonicalBusinessEngine.validatePayrollTimePolicy(offStep, previous: ownerPolicy),
            "Saturday counts-as hours use half-hour steps (e.g. 7.5)."
        )
        // A stored number left unchanged (with the weekday day unchanged) passes.
        XCTAssertNil(CanonicalBusinessEngine.validatePayrollTimePolicy(tooMany, previous: tooMany))
        // "Same as Monday–Friday" is never refused.
        var following = ownerPolicy
        following.saturday.countsAsFollowsWeekday = true
        following.saturday.countsAsHours = 9
        XCTAssertNil(CanonicalBusinessEngine.validatePayrollTimePolicy(following, previous: ownerPolicy))
    }

    func testTheStepperAndNotesComeFromTheRulebook() throws {
        let policy = ownerPolicy
        XCTAssertEqual(CanonicalBusinessEngine.weekendCountsAsMax(policy), 8.5)
        XCTAssertEqual(CanonicalBusinessEngine.weekendCountsAsStep(7.25, direction: 1, policy: policy), 7.5)
        XCTAssertEqual(CanonicalBusinessEngine.weekendCountsAsStep(7.25, direction: -1, policy: policy), 7)
        XCTAssertEqual(CanonicalBusinessEngine.weekendCountsAsCopy(.saturday)?.sameAsWeekdayLabel, "Same as Monday–Friday")
        XCTAssertEqual(CanonicalBusinessEngine.weekendCountsAsCopy(.saturday)?.label, "Counts as")
        XCTAssertNotNil(CanonicalBusinessEngine.weekdayDayRateNote(policy))
        XCTAssertNotNil(CanonicalBusinessEngine.weekendDayRateNote(policy, day: .saturday))
        var everyHour = policy
        everyHour.sunday.allHoursAtMultiplierMode = true
        XCTAssertNil(CanonicalBusinessEngine.weekendDayRateNote(everyHour, day: .sunday), "none on an every-hour day")
    }

    func testANewOrganisationStartsOnSameAsMondayToFriday() throws {
        let policy = try XCTUnwrap(CanonicalBusinessEngine.newOrganizationPayrollPolicy())
        XCTAssertEqual(policy.saturday.countsAsFollowsWeekday, true)
        XCTAssertEqual(policy.sunday.countsAsFollowsWeekday, true)
    }
}
