//
//  InvoicingPeriodResolver.swift
//  Project Planner
//
//  Resolves the organisation's current invoicing period for warnings look-ahead and reports.
//

import Foundation

struct InvoicingPeriodInfo: Hashable, Sendable {
    struct ScheduleRow: Hashable, Sendable {
        let label: String
        let summary: String
    }

    let scheduleRows: [ScheduleRow]
    let currentPeriodLabel: String
    let currentPeriodStart: Date
    let currentPeriodEnd: Date
    let currentPeriodEndLabel: String
}

enum InvoicingPeriodResolver {
    static func resolve(
        invoicing: OrganizationInvoicingSettings,
        referenceDate: Date = Date(),
        calendar: Calendar = .current
    ) -> InvoicingPeriodInfo {
        if invoicing.paymentRunMode == .recurringTimeframe {
            return recurringPeriod(invoicing: invoicing, referenceDate: referenceDate, calendar: calendar)
        }
        return dateRangePeriod(invoicing: invoicing, referenceDate: referenceDate, calendar: calendar)
    }

    /// End date of the invoicing period that contains `referenceDate` (used for warnings look-ahead).
    static func warningCoverageEnd(
        invoicing: OrganizationInvoicingSettings,
        referenceDate: Date = Date(),
        calendar: Calendar = .current
    ) -> Date {
        resolve(invoicing: invoicing, referenceDate: referenceDate, calendar: calendar).currentPeriodEnd
    }

    // MARK: - Private

    private static func dateRangePeriod(
        invoicing: OrganizationInvoicingSettings,
        referenceDate: Date,
        calendar: Calendar
    ) -> InvoicingPeriodInfo {
        let ranges = invoicing.normalizedRanges
        let scheduleRows = ranges.enumerated().map { index, range in
            InvoicingPeriodInfo.ScheduleRow(
                label: "Period \(index + 1)",
                summary: rangeScheduleSummary(range)
            )
        }

        let today = calendar.startOfDay(for: referenceDate)
        let dayOfMonth = calendar.component(.day, from: today)
        guard let matchIndex = ranges.firstIndex(where: { $0.contains(day: dayOfMonth) }),
              let bounds = dateRangeBounds(for: ranges[matchIndex], containing: today, calendar: calendar) else {
            let fallbackEnd = calendar.startOfDay(for: referenceDate)
            return InvoicingPeriodInfo(
                scheduleRows: scheduleRows,
                currentPeriodLabel: "Not configured",
                currentPeriodStart: fallbackEnd,
                currentPeriodEnd: fallbackEnd,
                currentPeriodEndLabel: formattedDay(fallbackEnd, calendar: calendar)
            )
        }

        return InvoicingPeriodInfo(
            scheduleRows: scheduleRows,
            currentPeriodLabel: periodLabel(start: bounds.start, end: bounds.end, calendar: calendar),
            currentPeriodStart: bounds.start,
            currentPeriodEnd: bounds.end,
            currentPeriodEndLabel: formattedDay(bounds.end, calendar: calendar)
        )
    }

    private static func recurringPeriod(
        invoicing: OrganizationInvoicingSettings,
        referenceDate: Date,
        calendar: Calendar
    ) -> InvoicingPeriodInfo {
        let scheduleRows = [
            InvoicingPeriodInfo.ScheduleRow(
                label: "Recurring",
                summary: invoicing.recurringRunDisplaySummary
            ),
        ]

        let today = calendar.startOfDay(for: referenceDate)
        guard let weekStart = today.startOfISOWeek else {
            return InvoicingPeriodInfo(
                scheduleRows: scheduleRows,
                currentPeriodLabel: invoicing.recurringRunDisplaySummary,
                currentPeriodStart: today,
                currentPeriodEnd: today,
                currentPeriodEndLabel: formattedDay(today, calendar: calendar)
            )
        }

        let startOffset = invoicing.recurringRunStartDay.isoWeekOffset
        let endOffset = invoicing.recurringRunEndDay.isoWeekOffset
        guard var periodStart = calendar.date(byAdding: .day, value: startOffset, to: weekStart),
              var periodEnd = calendar.date(byAdding: .day, value: endOffset, to: weekStart) else {
            return dateRangePeriod(invoicing: invoicing, referenceDate: referenceDate, calendar: calendar)
        }
        if endOffset < startOffset {
            periodEnd = calendar.date(byAdding: .day, value: 7, to: periodEnd) ?? periodEnd
        }
        periodStart = calendar.startOfDay(for: periodStart)
        periodEnd = calendar.startOfDay(for: periodEnd)

        while today < periodStart {
            periodStart = calendar.date(byAdding: .day, value: -7, to: periodStart) ?? periodStart
            periodEnd = calendar.date(byAdding: .day, value: -7, to: periodEnd) ?? periodEnd
        }
        while today > periodEnd {
            periodStart = calendar.date(byAdding: .day, value: 7, to: periodStart) ?? periodStart
            periodEnd = calendar.date(byAdding: .day, value: 7, to: periodEnd) ?? periodEnd
        }

        return InvoicingPeriodInfo(
            scheduleRows: scheduleRows,
            currentPeriodLabel: periodLabel(start: periodStart, end: periodEnd, calendar: calendar),
            currentPeriodStart: periodStart,
            currentPeriodEnd: periodEnd,
            currentPeriodEndLabel: formattedDay(periodEnd, calendar: calendar)
        )
    }

    private static func dateRangeBounds(
        for range: PaymentRunDateRange,
        containing referenceDate: Date,
        calendar: Calendar
    ) -> (start: Date, end: Date)? {
        let today = calendar.startOfDay(for: referenceDate)
        let dayOfMonth = calendar.component(.day, from: today)
        let monthAnchor = calendar.date(from: calendar.dateComponents([.year, .month], from: today)) ?? today

        func dateFor(day: Int, in month: Date) -> Date? {
            var comps = calendar.dateComponents([.year, .month], from: month)
            let daysInMonth = calendar.range(of: .day, in: .month, for: month)?.count ?? 31
            comps.day = min(max(day, 1), daysInMonth)
            return calendar.date(from: comps).map { calendar.startOfDay(for: $0) }
        }

        if range.startDay <= range.endDay {
            guard let start = dateFor(day: range.startDay, in: monthAnchor),
                  let end = dateFor(day: range.endDay, in: monthAnchor) else { return nil }
            return (start, end)
        }

        if dayOfMonth >= range.startDay {
            guard let start = dateFor(day: range.startDay, in: monthAnchor),
                  let nextMonth = calendar.date(byAdding: .month, value: 1, to: monthAnchor),
                  let end = dateFor(day: range.endDay, in: nextMonth) else { return nil }
            return (start, end)
        }

        guard let previousMonth = calendar.date(byAdding: .month, value: -1, to: monthAnchor),
              let start = dateFor(day: range.startDay, in: previousMonth),
              let end = dateFor(day: range.endDay, in: monthAnchor) else { return nil }
        return (start, end)
    }

    private static func rangeScheduleSummary(_ range: PaymentRunDateRange) -> String {
        if range.startDay <= range.endDay {
            return "\(ordinal(range.startDay)) – \(ordinal(range.endDay)) of each month"
        }
        return "\(ordinal(range.startDay)) – \(ordinal(range.endDay)) of the following month"
    }

    private static func periodLabel(start: Date, end: Date, calendar: Calendar) -> String {
        "\(formattedDay(start, calendar: calendar)) – \(formattedDay(end, calendar: calendar))"
    }

    private static func formattedDay(_ date: Date, calendar: Calendar) -> String {
        let day = calendar.component(.day, from: date)
        let month = date.formatted(.dateTime.month(.abbreviated))
        let year = calendar.component(.year, from: date)
        return "\(day) \(month) \(year)"
    }

    private static func ordinal(_ value: Int) -> String {
        let suffix: String
        let mod100 = value % 100
        if (11...13).contains(mod100) {
            suffix = "th"
        } else {
            switch value % 10 {
            case 1: suffix = "st"
            case 2: suffix = "nd"
            case 3: suffix = "rd"
            default: suffix = "th"
            }
        }
        return "\(value)\(suffix)"
    }
}
