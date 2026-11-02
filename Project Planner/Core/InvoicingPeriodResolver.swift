//
//  InvoicingPeriodResolver.swift
//  Project Planner
//
//  The organisation's current payment run for warnings look-ahead and reports. The period itself is
//  the rulebook's `invoicingPeriod` (organisation zone); this file only formats it.
//

import Foundation

nonisolated struct InvoicingPeriodInfo: Hashable, Sendable {
    nonisolated struct ScheduleRow: Hashable, Sendable {
        let label: String
        let summary: String
    }

    let scheduleRows: [ScheduleRow]
    let currentPeriodLabel: String
    let currentPeriodStart: Date
    let currentPeriodEnd: Date
    let currentPeriodEndLabel: String
}

nonisolated enum InvoicingPeriodResolver {
    /// The payment run containing `referenceDate`: `invoicingPeriod` from the rulebook, in the zone of
    /// `calendar` (the organisation zone by default). When no date-range run contains the day, the script
    /// falls back to the run with the latest end day (never "Not configured").
    static func resolve(
        invoicing: OrganizationInvoicingSettings,
        referenceDate: Date = Date(),
        calendar: Calendar = CanonicalBusinessEngine.businessCalendar
    ) -> InvoicingPeriodInfo {
        let rows = scheduleRows(for: invoicing)
        let zone = calendar.timeZone.identifier
        guard let window = CanonicalBusinessEngine.invoicingPeriod(invoicing, reference: referenceDate, timeZone: zone),
              let start = CanonicalBusinessEngine.date(fromDayKey: window.startDayKey, calendar: calendar),
              let end = CanonicalBusinessEngine.date(fromDayKey: window.endDayKey, calendar: calendar) else {
            let today = calendar.startOfDay(for: referenceDate)
            return InvoicingPeriodInfo(
                scheduleRows: rows,
                currentPeriodLabel: "Not configured",
                currentPeriodStart: today,
                currentPeriodEnd: today,
                currentPeriodEndLabel: formattedDay(today, calendar: calendar)
            )
        }
        return InvoicingPeriodInfo(
            scheduleRows: rows,
            currentPeriodLabel: periodLabel(start: start, end: end, calendar: calendar),
            currentPeriodStart: start,
            currentPeriodEnd: end,
            currentPeriodEndLabel: formattedDay(end, calendar: calendar)
        )
    }

    /// Start date of the invoicing period that contains `referenceDate` (reports / UI “current period”).
    static func warningCoverageStart(
        invoicing: OrganizationInvoicingSettings,
        referenceDate: Date = Date(),
        calendar: Calendar = CanonicalBusinessEngine.businessCalendar
    ) -> Date {
        warningScanBounds(invoicing: invoicing, referenceDate: referenceDate, calendar: calendar).start
    }

    /// End date for warnings look-ahead (see `warningScanBounds`).
    static func warningCoverageEnd(
        invoicing: OrganizationInvoicingSettings,
        referenceDate: Date = Date(),
        calendar: Calendar = CanonicalBusinessEngine.businessCalendar
    ) -> Date {
        warningScanBounds(invoicing: invoicing, referenceDate: referenceDate, calendar: calendar).end
    }

    /// Warnings “Invoicing period” window driven by payment-run settings.
    /// Uses the **active** payment-run segment that contains `referenceDate`
    /// (e.g. ranges 1–16 and 17–31 → while today is the 10th, scan 1st–16th inclusive,
    /// including past days already in that timeframe). Recurring runs use the current
    /// recurring period.
    static func warningScanBounds(
        invoicing: OrganizationInvoicingSettings,
        referenceDate: Date = Date(),
        calendar: Calendar = CanonicalBusinessEngine.businessCalendar
    ) -> (start: Date, end: Date, label: String) {
        let period = resolve(invoicing: invoicing, referenceDate: referenceDate, calendar: calendar)
        return (period.currentPeriodStart, period.currentPeriodEnd, period.currentPeriodLabel)
    }

    // MARK: - Private (display only)

    private static func scheduleRows(for invoicing: OrganizationInvoicingSettings) -> [InvoicingPeriodInfo.ScheduleRow] {
        if invoicing.paymentRunMode == .recurringTimeframe {
            return [InvoicingPeriodInfo.ScheduleRow(label: "Recurring", summary: invoicing.recurringRunDisplaySummary)]
        }
        return invoicing.normalizedRanges.enumerated().map { index, range in
            InvoicingPeriodInfo.ScheduleRow(label: "Period \(index + 1)", summary: rangeScheduleSummary(range))
        }
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
