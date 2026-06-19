//
//  TimesheetPayrollPolicy.swift
//  Project Planner
//
//  Shared rules for timesheet visibility, pay-run periods, and employment-type-aware rates.
//

import Foundation

struct WeekRange: Hashable {
    let start: Date
    let end: Date
    let title: String

    static func current(settings: OrganizationInvoicingSettings = .default) -> WeekRange {
        TimesheetPayrollPolicy.timesheetWeekRange(for: settings)
    }

    static func from(start: Date) -> WeekRange {
        let cal = Calendar.current
        let normalized = cal.startOfDay(for: start)
        let weekStart = normalized.startOfISOWeek ?? normalized
        let end = cal.date(byAdding: .day, value: 6, to: weekStart) ?? weekStart
        let title = "\(weekStart.formatted(date: .abbreviated, time: .omitted)) - \(end.formatted(date: .abbreviated, time: .omitted))"
        return WeekRange(start: weekStart, end: end, title: title)
    }

    func offset(byWeeks weeks: Int) -> WeekRange {
        let cal = Calendar.current
        let shifted = cal.date(byAdding: .day, value: 7 * weeks, to: start) ?? start
        return .from(start: shifted)
    }
}

enum TimesheetPayrollPolicy {
    /// Whether payroll amounts apply on a calendar day (self-employed only).
    static func isBillableSelfEmployedDay(_ user: AppUser, on day: Date, calendar: Calendar = .current) -> Bool {
        user.employmentType(on: calendar.startOfDay(for: day)) == .selfEmployed
    }

    /// Open timesheet period for signing (most recent completed pay run).
    static func timesheetWeekRange(
        for settings: OrganizationInvoicingSettings,
        referenceDate: Date = Date(),
        calendar: Calendar = .current
    ) -> WeekRange {
        let today = calendar.startOfDay(for: referenceDate)

        if settings.paymentRunMode == .recurringTimeframe {
            guard let startOfCurrentWeek = today.startOfISOWeek else { return WeekRange.from(start: today) }
            let startOffset = settings.recurringRunStartDay.isoWeekOffset
            let endOffset = settings.recurringRunEndDay.isoWeekOffset

            guard let baseWeekStart = calendar.date(byAdding: .day, value: -7, to: startOfCurrentWeek),
                  var startDate = calendar.date(byAdding: .day, value: startOffset, to: baseWeekStart),
                  var endDate = calendar.date(byAdding: .day, value: endOffset, to: baseWeekStart) else {
                return WeekRange.from(start: today)
            }
            if endOffset < startOffset {
                endDate = calendar.date(byAdding: .day, value: 7, to: endDate) ?? endDate
            }
            while endDate >= today {
                startDate = calendar.date(byAdding: .day, value: -7, to: startDate) ?? startDate
                endDate = calendar.date(byAdding: .day, value: -7, to: endDate) ?? endDate
            }
            startDate = calendar.startOfDay(for: startDate)
            endDate = calendar.startOfDay(for: endDate)
            let title = "\(startDate.formatted(date: .abbreviated, time: .omitted)) - \(endDate.formatted(date: .abbreviated, time: .omitted))"
            return WeekRange(start: startDate, end: endDate, title: title)
        }

        return monthDateRangePeriod(for: settings, referenceDate: referenceDate, calendar: calendar)
    }

    /// Pay date for a completed timesheet period (when the user is considered paid).
    static func payDate(
        forPeriodEnding periodEnd: Date,
        settings: OrganizationInvoicingSettings,
        calendar: Calendar = .current
    ) -> Date? {
        let periodEndDay = calendar.startOfDay(for: periodEnd)

        if settings.paymentRunMode == .recurringTimeframe {
            if settings.paymentDateMode == .recurringDate {
                let dayAfterPeriod = calendar.date(byAdding: .day, value: 1, to: periodEndDay) ?? periodEndDay
                return nextCalendarWeekday(
                    settings.recurringPaymentDay,
                    onOrAfter: dayAfterPeriod,
                    calendar: calendar
                )
            }
            return specificMonthPayDate(after: periodEndDay, paymentDays: settings.normalizedPaymentDates, calendar: calendar)
        }

        return specificMonthPayDate(after: periodEndDay, paymentDays: settings.normalizedPaymentDates, calendar: calendar)
    }

    /// Self-employed users always see My Timesheet. PAYE users keep access until their open period is paid out
    /// if that period includes self-employed days (e.g. after switching SE → PAYE mid-period).
    static func canAccessMyTimesheets(
        user: AppUser,
        settings: OrganizationInvoicingSettings,
        referenceDate: Date = Date(),
        calendar: Calendar = .current
    ) -> Bool {
        let today = calendar.startOfDay(for: referenceDate)
        let isSelfEmployed = user.employmentType(on: referenceDate) == .selfEmployed

        // Self-employed always retain personal timesheet access (sign-off / invoicing).
        if isSelfEmployed {
            return true
        }

        // PAYE (etc.) with timesheets turned on in Manage Users.
        if user.timesheetsEnabled {
            return true
        }

        let period = timesheetWeekRange(for: settings, referenceDate: referenceDate, calendar: calendar)
        let hasSelfEmployedDays = calendarDays(from: period.start, to: period.end, calendar: calendar)
            .contains { isBillableSelfEmployedDay(user, on: $0, calendar: calendar) }
        guard hasSelfEmployedDays else { return false }

        guard let payDate = payDate(forPeriodEnding: period.end, settings: settings, calendar: calendar) else {
            return true
        }
        return today <= calendar.startOfDay(for: payDate)
    }

    /// Whether a user should appear on a manager's operative-timesheet roster for a given week.
    static func shouldAppearInOperativeTimesheetRoster(
        user: AppUser,
        week: WeekRange,
        settings: OrganizationInvoicingSettings,
        referenceDate: Date = Date(),
        calendar: Calendar = .current
    ) -> Bool {
        guard user.isActive else { return false }
        guard user.participatesInTimesheets(on: referenceDate) else { return false }
        let isTimesheetEligibleRole =
            user.permissions.operativeMode
            || user.permissions.manager
            || user.permissions.adminAccess
            || user.role == .manager
            || user.role == .admin
        guard isTimesheetEligibleRole else { return false }

        if user.employmentType(on: referenceDate) == .selfEmployed {
            return true
        }

        // PAYE users with timesheets enabled always appear on manager/admin rosters.
        if user.timesheetsEnabled {
            return true
        }

        let hasSelfEmployedDays = calendarDays(from: week.start, to: week.end, calendar: calendar)
            .contains { isBillableSelfEmployedDay(user, on: $0, calendar: calendar) }
        guard hasSelfEmployedDays else { return false }

        guard let payDate = payDate(forPeriodEnding: week.end, settings: settings, calendar: calendar) else {
            return true
        }
        return calendar.startOfDay(for: referenceDate) <= calendar.startOfDay(for: payDate)
    }

    /// Completed pay periods before the open period (works for weekly and month-range pay runs).
    static func previousPayPeriods(
        before referenceDate: Date = Date(),
        count: Int = 24,
        settings: OrganizationInvoicingSettings,
        calendar: Calendar = .current
    ) -> [WeekRange] {
        var periods: [WeekRange] = []
        var cursor = calendar.startOfDay(for: referenceDate)
        for _ in 0..<max(1, count) {
            let open = timesheetWeekRange(for: settings, referenceDate: cursor, calendar: calendar)
            guard let dayBefore = calendar.date(byAdding: .day, value: -1, to: open.start) else { break }
            cursor = dayBefore
            let previous = timesheetWeekRange(for: settings, referenceDate: cursor, calendar: calendar)
            if periods.contains(where: { $0.start == previous.start }) { break }
            periods.append(previous)
            cursor = previous.start
        }
        return periods
    }

    static func calendarDays(from start: Date, to end: Date, calendar: Calendar = .current) -> [Date] {
        var days: [Date] = []
        var cursor = calendar.startOfDay(for: start)
        let endDay = calendar.startOfDay(for: end)
        while cursor <= endDay {
            days.append(cursor)
            guard let next = calendar.date(byAdding: .day, value: 1, to: cursor) else { break }
            cursor = next
        }
        return days
    }

    // MARK: - Private helpers

    private static func monthDateRangePeriod(
        for settings: OrganizationInvoicingSettings,
        referenceDate: Date,
        calendar: Calendar
    ) -> WeekRange {
        let today = calendar.startOfDay(for: referenceDate)
        let ranges = settings.normalizedRanges
        let dayOfMonth = calendar.component(.day, from: today)

        guard let matched = ranges.first(where: { $0.contains(day: dayOfMonth) }) else {
            return WeekRange.from(start: today)
        }

        var components = calendar.dateComponents([.year, .month], from: today)
        components.day = matched.startDay
        guard var startDate = calendar.date(from: components) else {
            return WeekRange.from(start: today)
        }
        startDate = calendar.startOfDay(for: startDate)

        components.day = matched.endDay
        guard var endDate = calendar.date(from: components) else {
            return WeekRange.from(start: today)
        }
        if matched.endDay < matched.startDay {
            endDate = calendar.date(byAdding: .month, value: 1, to: endDate) ?? endDate
        }
        endDate = calendar.startOfDay(for: endDate)

        if endDate >= today {
            startDate = calendar.date(byAdding: .month, value: -1, to: startDate) ?? startDate
            endDate = calendar.date(byAdding: .month, value: -1, to: endDate) ?? endDate
            if matched.endDay < matched.startDay, endDate < startDate {
                endDate = calendar.date(byAdding: .month, value: 1, to: endDate) ?? endDate
            }
        }

        let title = "\(startDate.formatted(date: .abbreviated, time: .omitted)) - \(endDate.formatted(date: .abbreviated, time: .omitted))"
        return WeekRange(start: startDate, end: endDate, title: title)
    }

    private static func specificMonthPayDate(
        after periodEnd: Date,
        paymentDays: [Int],
        calendar: Calendar
    ) -> Date? {
        let sortedDays = paymentDays.sorted()
        guard !sortedDays.isEmpty else { return nil }

        var monthComponents = calendar.dateComponents([.year, .month], from: periodEnd)
        for day in sortedDays {
            monthComponents.day = day
            if let candidate = calendar.date(from: monthComponents),
               calendar.startOfDay(for: candidate) >= periodEnd {
                return calendar.startOfDay(for: candidate)
            }
        }

        guard let nextMonth = calendar.date(byAdding: .month, value: 1, to: periodEnd) else { return nil }
        var nextComponents = calendar.dateComponents([.year, .month], from: nextMonth)
        nextComponents.day = sortedDays[0]
        return nextComponents.date.map { calendar.startOfDay(for: $0) }
    }

    private static func nextCalendarWeekday(
        _ day: RecurringPaymentDay,
        onOrAfter date: Date,
        calendar: Calendar
    ) -> Date {
        let targetWeekday = day.calendarWeekday
        var cursor = calendar.startOfDay(for: date)
        for _ in 0..<7 {
            if calendar.component(.weekday, from: cursor) == targetWeekday {
                return cursor
            }
            cursor = calendar.date(byAdding: .day, value: 1, to: cursor) ?? cursor
        }
        return cursor
    }
}

extension RecurringPaymentDay {
    var isoWeekOffset: Int {
        switch self {
        case .monday: return 0
        case .tuesday: return 1
        case .wednesday: return 2
        case .thursday: return 3
        case .friday: return 4
        case .saturday: return 5
        case .sunday: return 6
        }
    }

    /// `Calendar` weekday (Sunday = 1 … Saturday = 7).
    fileprivate var calendarWeekday: Int {
        (isoWeekOffset + 1) % 7 + 1
    }
}

extension Date {
    var startOfISOWeek: Date? {
        var cal = Calendar(identifier: .iso8601)
        cal.timeZone = .current
        let components = cal.dateComponents([.yearForWeekOfYear, .weekOfYear], from: self)
        return cal.date(from: components).map { Calendar.current.startOfDay(for: $0) }
    }
}
