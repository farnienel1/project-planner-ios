import XCTest
@testable import Project_Planner

@MainActor
final class TimesheetSubmissionCanonicalTests: XCTestCase {
    func testPay20AndPay5DefaultsComeFromTheScript() throws {
        let closeHour = try XCTUnwrap(CanonicalBusinessEngine.timesheetCloseOfPlayHour)
        let closeMinute = try XCTUnwrap(CanonicalBusinessEngine.timesheetCloseOfPlayMinute)
        let notifyHour = try XCTUnwrap(CanonicalBusinessEngine.timesheetNotifyHour)
        let notifyMinute = try XCTUnwrap(CanonicalBusinessEngine.timesheetNotifyMinute)

        let pay20 = try XCTUnwrap(CanonicalBusinessEngine.defaultTimesheetSubmissionFromPaymentDay(20))
        XCTAssertEqual(pay20.notifyDay, 17)
        XCTAssertEqual(pay20.notifyHour, notifyHour)
        XCTAssertEqual(pay20.notifyMinute, notifyMinute)
        XCTAssertEqual(pay20.timesheetDeadlineDay, 19)
        XCTAssertEqual(pay20.timesheetDeadlineHour, closeHour)
        XCTAssertEqual(pay20.timesheetDeadlineMinute, closeMinute)
        XCTAssertFalse(pay20.notifyCustomised)

        let pay5 = try XCTUnwrap(CanonicalBusinessEngine.defaultTimesheetSubmissionFromPaymentDay(5))
        XCTAssertEqual(pay5.notifyDay, 2)
        XCTAssertEqual(pay5.timesheetDeadlineDay, 4)
        XCTAssertEqual(pay5.notifyHour, notifyHour)
        XCTAssertEqual(pay5.timesheetDeadlineHour, closeHour)

        XCTAssertEqual(CanonicalBusinessEngine.monthDayOffsetBefore(paymentDay: 5, daysBefore: 3), 2)
        XCTAssertEqual(CanonicalBusinessEngine.monthDayOffsetBefore(paymentDay: 5, daysBefore: 1), 4)
        XCTAssertEqual(
            CanonicalBusinessEngine.paymentDateAfterPeriodEnd(periodEndDayKey: "2026-10-31", paymentDays: [5]),
            "2026-11-05"
        )

        let kept = pay20.customised(notifyDay: 10)
        let unchanged = try XCTUnwrap(
            CanonicalBusinessEngine.timesheetSubmissionAfterPaymentDayChange(kept, paymentDay: 5)
        )
        XCTAssertEqual(unchanged.notifyDay, 10)
        XCTAssertEqual(unchanged.timesheetDeadlineDay, 19)
        let refreshed = try XCTUnwrap(
            CanonicalBusinessEngine.timesheetSubmissionAfterPaymentDayChange(pay20, paymentDay: 5)
        )
        XCTAssertEqual(refreshed.notifyDay, 2)
        XCTAssertEqual(refreshed.timesheetDeadlineDay, 4)

        XCTAssertEqual(
            CanonicalBusinessEngine.timesheetSubmissionNoticeCopy(
                CanonicalBusinessEngine.CanonicalTimesheetNoticeCopyInput(
                    mode: "date_ranges",
                    deadlineDay: pay20.timesheetDeadlineDay,
                    paymentDay: 20,
                    deadlineHour: pay20.timesheetDeadlineHour,
                    deadlineMinute: pay20.timesheetDeadlineMinute
                )
            ),
            "Timesheets need to be submitted by close of play on the 19th for payment on the 20th."
        )
        XCTAssertEqual(
            CanonicalBusinessEngine.timesheetSubmissionNoticeCopy(
                CanonicalBusinessEngine.CanonicalTimesheetNoticeCopyInput(
                    mode: "date_ranges",
                    deadlineDay: pay5.timesheetDeadlineDay,
                    paymentDay: 5,
                    deadlineHour: pay5.timesheetDeadlineHour,
                    deadlineMinute: pay5.timesheetDeadlineMinute
                )
            ),
            "Timesheets need to be submitted by close of play on the 4th for payment on the 5th."
        )
    }

    func testSixteenthToThirtyFirstPaidOnTheFifthLandsNextMonth() throws {
        let pay5 = try XCTUnwrap(CanonicalBusinessEngine.defaultTimesheetSubmissionFromPaymentDay(5))
        let reference = try XCTUnwrap(isoDate("2026-11-02T08:00:00+00:00"))
        let notices = try XCTUnwrap(
            CanonicalBusinessEngine.dueTimesheetSubmissionNotices(
                reference: reference,
                invoicing: invoicing(
                    ranges: [(16, 31)],
                    paymentDates: [5],
                    timesheet: [pay5]
                )
            )
        )
        let november = try XCTUnwrap(notices.first { $0.paymentDayKey == "2026-11-05" })
        XCTAssertEqual(november.notifyDayKey, "2026-11-02")
        XCTAssertEqual(november.deadlineDayKey, "2026-11-04")
        XCTAssertEqual(
            november.message,
            "Timesheets need to be submitted by close of play on the 4th for payment on the 5th."
        )
        XCTAssertEqual(november.title, CanonicalBusinessEngine.timesheetSubmissionNoticeTitle)
    }

    func testRecurringFridayDefaultsAndWednesdayTuesdayCustomCopy() throws {
        let friday = try XCTUnwrap(CanonicalBusinessEngine.defaultTimesheetSubmissionFromPaymentWeekday("friday"))
        XCTAssertEqual(friday.notifyWeekday, "tuesday")
        XCTAssertEqual(friday.timesheetDeadlineWeekday, "thursday")
        XCTAssertEqual(CanonicalBusinessEngine.weekdayOffsetBefore(weekday: "friday", daysBefore: 3), "tuesday")
        XCTAssertEqual(CanonicalBusinessEngine.weekdayOffsetBefore(weekday: "friday", daysBefore: 1), "thursday")
        XCTAssertEqual(
            CanonicalBusinessEngine.timesheetSubmissionNoticeCopy(
                CanonicalBusinessEngine.CanonicalTimesheetNoticeCopyInput(
                    mode: "recurring_timeframe",
                    deadlineWeekday: friday.timesheetDeadlineWeekday,
                    paymentWeekday: "friday",
                    deadlineHour: friday.timesheetDeadlineHour,
                    deadlineMinute: friday.timesheetDeadlineMinute
                )
            ),
            "Please issue timesheets for the previous payment run by close of play Thursday, to be paid on Friday."
        )

        let kept = friday.customised(notifyWeekday: "monday", deadlineWeekday: "tuesday")
        let unchanged = try XCTUnwrap(
            CanonicalBusinessEngine.timesheetSubmissionAfterPaymentWeekdayChange(kept, paymentWeekday: "monday")
        )
        XCTAssertEqual(unchanged.notifyWeekday, "monday")
        XCTAssertEqual(unchanged.timesheetDeadlineWeekday, "tuesday")

        let reference = try XCTUnwrap(isoDate("2026-10-12T08:00:00+01:00"))
        var settings = OrganizationInvoicingSettings.default
        settings.paymentRunMode = .recurringTimeframe
        settings.paymentDateMode = .recurringDate
        settings.recurringRunStartDay = .wednesday
        settings.recurringRunEndDay = .tuesday
        settings.recurringPaymentDay = .friday
        settings.timesheetSubmission = [kept]
        let notices = try XCTUnwrap(
            CanonicalBusinessEngine.dueTimesheetSubmissionNotices(reference: reference, invoicing: settings)
        )
        let row = try XCTUnwrap(notices.first { $0.paymentDayKey == "2026-10-16" })
        XCTAssertEqual(row.notifyDayKey, "2026-10-12")
        XCTAssertEqual(row.deadlineDayKey, "2026-10-13")
        XCTAssertEqual(
            row.message,
            "Please issue timesheets for the previous payment run by close of play Tuesday, to be paid on Friday."
        )

        let fridayReference = try XCTUnwrap(isoDate("2026-10-13T08:00:00+01:00"))
        settings.recurringRunStartDay = .monday
        settings.recurringRunEndDay = .sunday
        settings.timesheetSubmission = [friday]
        let fridayNotices = try XCTUnwrap(
            CanonicalBusinessEngine.dueTimesheetSubmissionNotices(reference: fridayReference, invoicing: settings)
        )
        let fridayPay = try XCTUnwrap(fridayNotices.first { $0.paymentDayKey == "2026-10-16" })
        XCTAssertEqual(fridayPay.notifyDayKey, "2026-10-13")
        XCTAssertEqual(fridayPay.deadlineDayKey, "2026-10-15")
    }

    func testDedupKeyIsStableAndSaveMirrorsTimesheetKeys() throws {
        let first = try XCTUnwrap(
            CanonicalBusinessEngine.timesheetSubmissionNoticeDedupKey(
                organizationId: "Org-A",
                paymentDayKey: "2026-10-20",
                runIndex: 0,
                userId: "user-1"
            )
        )
        let second = try XCTUnwrap(
            CanonicalBusinessEngine.timesheetSubmissionNoticeDedupKey(
                organizationId: "Org-A",
                paymentDayKey: "2026-10-20",
                runIndex: 0,
                userId: "user-1"
            )
        )
        XCTAssertEqual(first, second)
        XCTAssertNotEqual(
            first,
            CanonicalBusinessEngine.timesheetSubmissionNoticeDedupKey(
                organizationId: "Org-A",
                paymentDayKey: "2026-11-05",
                runIndex: 1,
                userId: "user-1"
            )
        )

        let pay20 = try XCTUnwrap(CanonicalBusinessEngine.defaultTimesheetSubmissionFromPaymentDay(20))
        let pay5 = try XCTUnwrap(CanonicalBusinessEngine.defaultTimesheetSubmissionFromPaymentDay(5))
        var settings = OrganizationInvoicingSettings.default
        settings.paymentRunMode = .dateRanges
        settings.paymentDateMode = .specificDates
        settings.paymentRunDateRanges = [
            PaymentRunDateRange(startDay: 1, endDay: 15),
            PaymentRunDateRange(startDay: 16, endDay: 31),
        ]
        settings.paymentDates = [20, 5]
        settings.noteToUsers = "Bring price work on Thursday"
        settings.timesheetSubmission = [pay20, pay5]
        let map = try XCTUnwrap(CanonicalBusinessEngine.invoicingToFirestore(settings.canonicalInvoicingSettings()))
        XCTAssertEqual(map["noteToUsers"] as? String, "Bring price work on Thursday")
        XCTAssertEqual(map["paymentRunMode"] as? String, "date_ranges")
        XCTAssertEqual(map["paymentDateMode"] as? String, "specific_dates")
        let ranges = try XCTUnwrap(map["paymentRunDateRanges"] as? [[String: Any]])
        XCTAssertEqual(int(ranges[0]["startDay"]), 1)
        XCTAssertEqual(int(ranges[0]["endDay"]), 15)
        XCTAssertEqual(int(ranges[0]["startDate"]), 1)
        XCTAssertEqual(int(ranges[0]["endDate"]), 15)
        XCTAssertEqual(int(ranges[0]["notifyDay"]), 17)
        XCTAssertEqual(int(ranges[0]["timesheetDeadlineDay"]), 19)
        XCTAssertEqual(int(ranges[1]["startDay"]), 16)
        XCTAssertEqual(int(ranges[1]["notifyDay"]), 2)
        XCTAssertEqual(int(ranges[1]["timesheetDeadlineDay"]), 4)
        let saved = try XCTUnwrap(map["timesheetSubmission"] as? [[String: Any]])
        XCTAssertEqual(int(saved[0]["notifyDay"]), 17)
        XCTAssertEqual(int(saved[1]["notifyDay"]), 2)
        XCTAssertFalse(map.keys.contains("warningDetection"))
        XCTAssertFalse(map.keys.contains("payroll"))

        settings.paymentRunMode = .recurringTimeframe
        settings.recurringPaymentDay = .friday
        settings.timesheetSubmission = [try XCTUnwrap(CanonicalBusinessEngine.defaultTimesheetSubmissionFromPaymentWeekday("friday"))]
        let recurring = try XCTUnwrap(CanonicalBusinessEngine.invoicingToFirestore(settings.canonicalInvoicingSettings()))
        XCTAssertEqual(recurring["timesheetDeadlineWeekday"] as? String, "thursday")
        XCTAssertEqual(recurring["notifyWeekday"] as? String, "tuesday")
        XCTAssertEqual(int(recurring["timesheetDeadlineHour"]), CanonicalBusinessEngine.timesheetCloseOfPlayHour)
        XCTAssertEqual(int(recurring["notifyHour"]), CanonicalBusinessEngine.timesheetNotifyHour)
        XCTAssertEqual(recurring["notifyCustomised"] as? Bool, false)
        XCTAssertEqual(recurring["noteToUsers"] as? String, "Bring price work on Thursday")
        XCTAssertEqual(recurring["recurringPaymentDay"] as? String, "friday")
    }

    func testNoticeTypeReachesMyTimesheets() throws {
        XCTAssertEqual(
            CanonicalBusinessEngine.timesheetSubmissionNoticeType,
            "timesheet_submission_reminder"
        )
        let destination = try XCTUnwrap(
            CanonicalBusinessEngine.notificationDestination(
                type: "timesheet_submission_reminder",
                relatedId: "2026-10-20",
                dayKey: nil,
                catalogue: nil,
                role: "operative",
                deepLinkUserId: nil
            )
        )
        XCTAssertEqual(destination.kind, "timesheetMine")
        XCTAssertEqual(destination.dayKey, "2026-10-20")
        XCTAssertEqual(AppNotification.inboxDayKey(storedDayKey: nil, relatedId: "2026-10-20"), "2026-10-20")
    }

    private func invoicing(
        ranges: [(Int, Int)],
        paymentDates: [Int],
        timesheet: [CanonicalBusinessEngine.CanonicalTimesheetSubmissionEntry]
    ) -> OrganizationInvoicingSettings {
        var settings = OrganizationInvoicingSettings.default
        settings.paymentRunMode = .dateRanges
        settings.paymentDateMode = .specificDates
        settings.paymentRunDateRanges = ranges.map { PaymentRunDateRange(startDay: $0.0, endDay: $0.1) }
        settings.paymentDates = paymentDates
        settings.timesheetSubmission = timesheet
        return settings
    }

    private func isoDate(_ text: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: text)
    }

    private func int(_ value: Any?) -> Int? {
        (value as? NSNumber)?.intValue ?? value as? Int
    }
}

private extension CanonicalBusinessEngine.CanonicalTimesheetSubmissionEntry {
    func customised(notifyDay: Int) -> Self {
        var copy = self
        copy.notifyDay = notifyDay
        copy.notifyCustomised = true
        return copy
    }

    func customised(notifyWeekday: String, deadlineWeekday: String) -> Self {
        var copy = self
        copy.notifyWeekday = notifyWeekday
        copy.timesheetDeadlineWeekday = deadlineWeekday
        copy.notifyCustomised = true
        return copy
    }
}
