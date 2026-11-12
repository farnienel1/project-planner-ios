//
//  AnnualLeavePolicy.swift
//  Project Planner
//
//  Leave-year boundaries and consumption for per-user annual leave settings.
//

import Foundation

nonisolated struct AnnualLeaveUsageSummary: Equatable, Sendable {
    /// Human-readable leave year window, e.g. "Apr 2025 – Mar 2026".
    var leaveYearLabel: String
    var entitlementDays: Double
    var carryOverDays: Double
    var takenDays: Double
    var pendingDays: Double
    /// Nil when this person has no paid allowance. The year count is `usedThisYear`.
    var remainingDays: Double?
    var hasAllowance: Bool
    var usedThisYear: Double
    var yearKey: String
    /// RULEBOOK 1.40.0: this year's manual adjustments (already in `entitlementDays`); 0 with no allowance.
    var adjustmentDays: Double = 0
    /// RULEBOOK 1.40.0: leave taken this year on self-employed days, which does not come out of the allowance.
    var notCountedTakenDays: Double = 0
    /// RULEBOOK 1.40.0: the allowance is pro rata (start date, or the day PAYE began).
    var proRata: Bool = false
}

nonisolated enum AnnualLeavePolicy {
    static let defaultDaysPerYear: Double = 25
    static let defaultStartMonth: Int = 1
    static let defaultEndMonth: Int = 12
    static let defaultCarriesOver: Bool = false

    static func clampMonth(_ m: Int) -> Int {
        min(12, max(1, m))
    }

    static func clampDaysPerYear(_ d: Double) -> Double {
        min(366, max(0, d))
    }

    /// Inclusive leave year from `leaveYearBounds`. Dates are Europe/London midnights.
    static func leaveYearRange(
        containing date: Date,
        startMonth: Int,
        endMonth: Int,
        calendar: Calendar = OrganizationRulebookContext.calendar
    ) -> (start: Date, end: Date)? {
        _ = calendar
        let key = CanonicalBusinessEngine.dayKey(for: date)
        guard let bounds = CanonicalBusinessEngine.leaveYearBounds(
            startMonth: startMonth,
            endMonth: endMonth,
            onDayKey: key
        ),
        let start = CanonicalBusinessEngine.date(fromDayKey: bounds.startDayKey),
        let end = CanonicalBusinessEngine.date(fromDayKey: bounds.endDayKey) else {
            return nil
        }
        return (start, end)
    }

    static func previousLeaveYearRange(
        beforeCurrentYearStart start: Date,
        startMonth: Int,
        endMonth: Int,
        calendar: Calendar = OrganizationRulebookContext.calendar
    ) -> (start: Date, end: Date)? {
        guard let dayBefore = calendar.date(byAdding: .day, value: -1, to: start) else { return nil }
        return leaveYearRange(containing: dayBefore, startMonth: startMonth, endMonth: endMonth, calendar: calendar)
    }

    /// RULEBOOK §9 `annualLeaveBalance` over one person's records. `bookings` are already that person's own
    /// (`leaveRecordsForAccount`, `HolidayStore.myBookings(account:operatives:)`): this never matches a record to a
    /// person itself (it used to compare `userId` with the id or the email only, missing former and same-email ids).
    static func usageSummary(
        bookings: [HolidayBooking],
        daysPerYear: Double,
        startMonth: Int,
        endMonth: Int,
        carriesOver: Bool,
        referenceDate: Date = Date(),
        calendar: Calendar = OrganizationRulebookContext.calendar,
        annualLeaveEnabled: Bool = true,
        orgDaysPerYear: Double? = nil,
        orgStartMonth: Int? = nil,
        orgEndMonth: Int? = nil,
        yearAllowance: Double? = nil,
        yearAllowanceKey: String? = nil,
        nonWorkingDayKeys: [String]? = nil,
        employmentStartDayKey: String? = nil,
        maxCarryOverDays: Double? = OrganizationRulebookContext.annualLeaveDefaults?.maxCarryOverDays,
        employment: AnnualLeaveEmployment? = nil,
        adjustments: [AnnualLeaveAdjustmentRecord] = []
    ) -> AnnualLeaveUsageSummary {
        _ = calendar
        let records: [CanonicalBusinessEngine.CanonicalLeaveBooking] = bookings.map { booking in
            CanonicalBusinessEngine.CanonicalLeaveBooking(
                startDayKey: booking.startDayKey,
                endDayKey: booking.endDayKey,
                timeSlot: booking.timeSlot.rawValue,
                status: booking.status.rawValue
            )
        }
        // Bank holidays inside a multi-day record are not taken from the allowance (§9).
        // RULEBOOK 1.13.0 §4.4: pro rata in the year joined (`employmentStartDayKey`) and the carry-over cap.
        // RULEBOOK 1.40.0 §4.4: the allowance applies only on PAYE days (`employment`), with this leave year's manual
        // adjustments on top (`adjustments`).
        let balance = CanonicalBusinessEngine.annualLeaveBalanceFull(
            annualLeaveEnabled: annualLeaveEnabled,
            daysPerYear: daysPerYear,
            startMonth: startMonth,
            endMonth: endMonth,
            orgDaysPerYear: orgDaysPerYear,
            orgStartMonth: orgStartMonth,
            orgEndMonth: orgEndMonth,
            carriesOver: carriesOver,
            yearAllowance: yearAllowance,
            yearAllowanceKey: yearAllowanceKey,
            bookings: records,
            onDayKey: CanonicalBusinessEngine.dayKey(for: referenceDate),
            nonWorkingDayKeys: nonWorkingDayKeys ?? OrganizationBankHolidays.dayKeys,
            employmentStartDayKey: employmentStartDayKey,
            maxCarryOverDays: maxCarryOverDays,
            employment: employment,
            adjustments: adjustments
        )
        guard let balance else {
            return AnnualLeaveUsageSummary(
                leaveYearLabel: "—",
                entitlementDays: 0,
                carryOverDays: 0,
                takenDays: 0,
                pendingDays: 0,
                remainingDays: nil,
                hasAllowance: annualLeaveEnabled,
                usedThisYear: 0,
                yearKey: ""
            )
        }
        let label = formattedLeaveYearLabel(startDayKey: balance.startDayKey, endDayKey: balance.endDayKey)
        return AnnualLeaveUsageSummary(
            leaveYearLabel: label,
            entitlementDays: balance.hasAllowance ? balance.allowanceBeforeAdjustments + balance.adjustmentDays : 0,
            carryOverDays: balance.carriedForward,
            // With an allowance, the leave that comes out of it (PAYE days only); otherwise every day.
            takenDays: balance.shownTaken,
            pendingDays: balance.shownPending,
            remainingDays: balance.remaining,
            hasAllowance: balance.hasAllowance,
            usedThisYear: balance.usedThisYear,
            yearKey: balance.yearKey,
            adjustmentDays: balance.adjustmentDays,
            notCountedTakenDays: balance.notCountedTaken,
            proRata: balance.proRata
        )
    }

    /// RULEBOOK 1.40.0 §9: the organisation's leave year containing `date` as a label ("Jan 2026 – Dec 2026") — the
    /// Team header, never the viewer's own leave year. Nil when the script did not answer.
    static func organizationLeaveYearLabel(startMonth: Int, endMonth: Int, on date: Date = Date()) -> String? {
        guard let bounds = CanonicalBusinessEngine.leaveYearBounds(
            startMonth: startMonth,
            endMonth: endMonth,
            onDayKey: CanonicalBusinessEngine.dayKey(for: date)
        ) else { return nil }
        return formattedLeaveYearLabel(startDayKey: bounds.startDayKey, endDayKey: bounds.endDayKey)
    }

    // MARK: - Allowance caps (book / request)

    private static let allowanceEpsilon = 0.001

    /// Human-friendly count of leave days for messages (half-day aware).
    static func formatAllowanceDays(_ d: Double) -> String {
        if abs(d - (d.rounded())) < allowanceEpsilon {
            return String(Int(d.rounded()))
        }
        return String(format: "%.1f", d)
    }

    /// Groups each start-of-day into the leave-year window that contains it.
    private static func bucketStartOfDaysByLeaveYear(
        _ startOfDays: [Date],
        startMonth: Int,
        endMonth: Int,
        calendar: Calendar
    ) -> [((start: Date, end: Date), [Date])] {
        let sm = clampMonth(startMonth)
        let em = clampMonth(endMonth)
        var buckets: [((start: Date, end: Date), [Date])] = []
        for raw in startOfDays {
            let day = calendar.startOfDay(for: raw)
            guard let range = leaveYearRange(containing: day, startMonth: sm, endMonth: em, calendar: calendar) else { continue }
            if let idx = buckets.firstIndex(where: { $0.0.start == range.start && $0.0.end == range.end }) {
                if !buckets[idx].1.contains(day) {
                    buckets[idx].1.append(day)
                }
            } else {
                buckets.append((range, [day]))
            }
        }
        for i in buckets.indices {
            buckets[i].1.sort()
        }
        return buckets
    }

    /// Validates a **new** set of same-slot day bookings (not yet in `bookings`). Returns a user-facing error, or `nil` if within allowance for every touched leave year.
    static func validateProposedDayBookingsAgainstAllowance(
        selectedStartOfDays: [Date],
        timeSlot: HolidayTimeSlot,
        bookings: [HolidayBooking],
        daysPerYear: Double,
        startMonth: Int,
        endMonth: Int,
        carriesOver: Bool,
        employmentStartDayKey: String? = nil,
        calendar: Calendar = OrganizationRulebookContext.calendar
    ) -> String? {
        let sod = selectedStartOfDays.map { calendar.startOfDay(for: $0) }
        let unique = Array(Set(sod)).sorted()
        guard !unique.isEmpty else { return nil }

        let buckets = bucketStartOfDaysByLeaveYear(unique, startMonth: startMonth, endMonth: endMonth, calendar: calendar)
        guard !buckets.isEmpty else {
            return "Could not determine your leave year for one or more selected dates."
        }

        for (range, days) in buckets {
            let ref = days.first ?? range.start
            let summary = usageSummary(
                bookings: bookings,
                daysPerYear: daysPerYear,
                startMonth: startMonth,
                endMonth: endMonth,
                carriesOver: carriesOver,
                referenceDate: ref,
                calendar: calendar,
                employmentStartDayKey: employmentStartDayKey
            )
            let requested = Double(days.count) * timeSlot.dayValue
            guard summary.hasAllowance, let remaining = summary.remainingDays else { continue }
            if requested > remaining + allowanceEpsilon {
                let rem = formatAllowanceDays(remaining)
                let req = formatAllowanceDays(requested)
                return "In \(summary.leaveYearLabel) you have \(rem) days of annual leave left (after booked and pending), but this selection needs \(req) days. Remove dates, choose shorter slots, or wait until your allowance renews."
            }
        }
        return nil
    }

    /// Same allowance check when each selected day can be full, AM, or PM.
    static func validateProposedDaySlots(
        daySlots: [Date: HolidayTimeSlot],
        bookings: [HolidayBooking],
        daysPerYear: Double,
        startMonth: Int,
        endMonth: Int,
        carriesOver: Bool,
        employmentStartDayKey: String? = nil,
        calendar: Calendar = OrganizationRulebookContext.calendar
    ) -> String? {
        let normalized = Dictionary(daySlots.map { (calendar.startOfDay(for: $0.key), $0.value) }, uniquingKeysWith: { first, _ in first })
        guard !normalized.isEmpty else { return nil }
        let buckets = bucketStartOfDaysByLeaveYear(Array(normalized.keys), startMonth: startMonth, endMonth: endMonth, calendar: calendar)
        guard !buckets.isEmpty else {
            return "Could not determine your leave year for one or more selected dates."
        }
        for (_, days) in buckets {
            let ref = days.first ?? Date()
            let summary = usageSummary(
                bookings: bookings,
                daysPerYear: daysPerYear,
                startMonth: startMonth,
                endMonth: endMonth,
                carriesOver: carriesOver,
                referenceDate: ref,
                calendar: calendar,
                employmentStartDayKey: employmentStartDayKey
            )
            let requested = days.reduce(0.0) { $0 + (normalized[$1] ?? .fullDay).dayValue }
            guard summary.hasAllowance, let remaining = summary.remainingDays else { continue }
            if requested > remaining + allowanceEpsilon {
                let rem = formatAllowanceDays(remaining)
                let req = formatAllowanceDays(requested)
                return "In \(summary.leaveYearLabel) you have \(rem) days of annual leave left (after booked and pending), but this selection needs \(req) days. You can still send it, and your line manager can allow it."
            }
        }
        return nil
    }

    /// Validates increasing `timeSlot` day-value on an existing booking (e.g. AM → full day). Downgrades always pass.
    static func validateTimeSlotIncreaseAgainstAllowance(
        booking: HolidayBooking,
        newTimeSlot: HolidayTimeSlot,
        bookings: [HolidayBooking],
        daysPerYear: Double,
        startMonth: Int,
        endMonth: Int,
        carriesOver: Bool,
        employmentStartDayKey: String? = nil,
        calendar: Calendar = OrganizationRulebookContext.calendar
    ) -> String? {
        let deltaPerDay = newTimeSlot.dayValue - booking.timeSlot.dayValue
        if deltaPerDay <= allowanceEpsilon { return nil }

        var d = calendar.startOfDay(for: booking.startDate)
        let endB = calendar.startOfDay(for: booking.endDate)
        var daysInBooking: [Date] = []
        while d <= endB {
            daysInBooking.append(d)
            guard let nx = calendar.date(byAdding: .day, value: 1, to: d) else { break }
            d = nx
        }

        var extraByYear: [Date: Double] = [:]
        for day in daysInBooking {
            guard let range = leaveYearRange(containing: day, startMonth: startMonth, endMonth: endMonth, calendar: calendar) else {
                return "Could not determine your leave year for this booking."
            }
            let key = range.start
            extraByYear[key, default: 0] += deltaPerDay
        }

        for (yearStart, extra) in extraByYear {
            let summary = usageSummary(
                bookings: bookings,
                daysPerYear: daysPerYear,
                startMonth: startMonth,
                endMonth: endMonth,
                carriesOver: carriesOver,
                referenceDate: yearStart,
                calendar: calendar,
                employmentStartDayKey: employmentStartDayKey
            )
            guard summary.hasAllowance, let remaining = summary.remainingDays else { continue }
            if extra > remaining + allowanceEpsilon {
                let rem = formatAllowanceDays(remaining)
                let ex = formatAllowanceDays(extra)
                return "In \(summary.leaveYearLabel) you have \(rem) days of annual leave left; changing to \(newTimeSlot.rawValue) would need \(ex) more days than you have available."
            }
        }
        return nil
    }

    private static func formattedLeaveYearLabel(startDayKey: String, endDayKey: String) -> String {
        let calendar = CanonicalBusinessEngine.businessCalendar
        guard let start = CanonicalBusinessEngine.date(fromDayKey: startDayKey, calendar: calendar),
              let end = CanonicalBusinessEngine.date(fromDayKey: endDayKey, calendar: calendar) else {
            return "—"
        }
        let df = DateFormatter()
        df.calendar = calendar
        df.timeZone = calendar.timeZone
        df.dateFormat = "MMM yyyy"
        return "\(df.string(from: start)) – \(df.string(from: end))"
    }

    static func shortMonthSymbols(calendar: Calendar = .current) -> [String] {
        let df = DateFormatter()
        df.calendar = calendar
        df.locale = calendar.locale ?? .current
        return df.shortMonthSymbols
    }
}
