//
//  AnnualLeavePolicy.swift
//  Project Planner
//
//  Leave-year boundaries and consumption for per-user annual leave settings.
//

import Foundation

struct AnnualLeaveUsageSummary: Equatable {
    /// Human-readable leave year window, e.g. "Apr 2025 – Mar 2026".
    var leaveYearLabel: String
    var entitlementDays: Double
    var carryOverDays: Double
    var takenDays: Double
    var pendingDays: Double
    var remainingDays: Double
}

enum AnnualLeavePolicy {
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

    /// Inclusive calendar-day range for the configured leave year containing `date`.
    static func leaveYearRange(
        containing date: Date,
        startMonth: Int,
        endMonth: Int,
        calendar: Calendar = .current
    ) -> (start: Date, end: Date)? {
        let sm = clampMonth(startMonth)
        let em = clampMonth(endMonth)
        let y = calendar.component(.year, from: date)
        let m = calendar.component(.month, from: date)

        func startOfDay(_ d: Date) -> Date { calendar.startOfDay(for: d) }

        if sm > em {
            // e.g. April → March (UK-style)
            let yearStartYear = m >= sm ? y : y - 1
            guard let start = calendar.date(from: DateComponents(year: yearStartYear, month: sm, day: 1)),
                  let endMonthFirst = calendar.date(from: DateComponents(year: yearStartYear + 1, month: em, day: 1)),
                  let end = calendar.date(byAdding: DateComponents(month: 1, day: -1), to: endMonthFirst)
            else { return nil }
            return (startOfDay(start), startOfDay(end))
        }

        // Same calendar-year band (e.g. Jan–Dec or Jun–Aug)
        var bandYear = y
        if m < sm { bandYear -= 1 }
        else if m > em { bandYear += 1 }

        guard let start = calendar.date(from: DateComponents(year: bandYear, month: sm, day: 1)),
              let endMonthFirst = calendar.date(from: DateComponents(year: bandYear, month: em, day: 1)),
              let end = calendar.date(byAdding: DateComponents(month: 1, day: -1), to: endMonthFirst)
        else { return nil }
        return (startOfDay(start), startOfDay(end))
    }

    static func previousLeaveYearRange(
        beforeCurrentYearStart start: Date,
        startMonth: Int,
        endMonth: Int,
        calendar: Calendar = .current
    ) -> (start: Date, end: Date)? {
        guard let dayBefore = calendar.date(byAdding: .day, value: -1, to: start) else { return nil }
        return leaveYearRange(containing: dayBefore, startMonth: startMonth, endMonth: endMonth, calendar: calendar)
    }

    static func consumedDays(
        bookings: [HolidayBooking],
        userId: String?,
        operativeId: UUID?,
        statuses: Set<HolidayStatus>,
        rangeStart: Date,
        rangeEnd: Date,
        calendar: Calendar = .current
    ) -> Double {
        let rs = calendar.startOfDay(for: rangeStart)
        let re = calendar.startOfDay(for: rangeEnd)
        var total: Double = 0
        for b in bookings where statuses.contains(b.status) {
            let matchesUser = userId != nil && b.userId == userId
            let matchesOp = operativeId != nil && b.operativeId == operativeId
            guard matchesUser || matchesOp else { continue }

            var d = calendar.startOfDay(for: b.startDate)
            let endB = calendar.startOfDay(for: b.endDate)
            while d <= endB {
                if d >= rs && d <= re {
                    total += b.timeSlot.dayValue
                }
                guard let nx = calendar.date(byAdding: .day, value: 1, to: d) else { break }
                d = nx
            }
        }
        return total
    }

    static func usageSummary(
        bookings: [HolidayBooking],
        profileUserId: String,
        operativeId: UUID?,
        daysPerYear: Double,
        startMonth: Int,
        endMonth: Int,
        carriesOver: Bool,
        referenceDate: Date = Date(),
        calendar: Calendar = .current
    ) -> AnnualLeaveUsageSummary {
        let days = clampDaysPerYear(daysPerYear)
        let sm = clampMonth(startMonth)
        let em = clampMonth(endMonth)

        guard let range = leaveYearRange(containing: referenceDate, startMonth: sm, endMonth: em, calendar: calendar) else {
            return AnnualLeaveUsageSummary(
                leaveYearLabel: "—",
                entitlementDays: days,
                carryOverDays: 0,
                takenDays: 0,
                pendingDays: 0,
                remainingDays: days
            )
        }

        let taken = consumedDays(
            bookings: bookings,
            userId: profileUserId,
            operativeId: operativeId,
            statuses: [.approved],
            rangeStart: range.start,
            rangeEnd: range.end,
            calendar: calendar
        )
        let pending = consumedDays(
            bookings: bookings,
            userId: profileUserId,
            operativeId: operativeId,
            statuses: [.pending],
            rangeStart: range.start,
            rangeEnd: range.end,
            calendar: calendar
        )

        var carry: Double = 0
        if carriesOver, let prev = previousLeaveYearRange(beforeCurrentYearStart: range.start, startMonth: sm, endMonth: em, calendar: calendar) {
            let prevTaken = consumedDays(
                bookings: bookings,
                userId: profileUserId,
                operativeId: operativeId,
                statuses: [.approved],
                rangeStart: prev.start,
                rangeEnd: prev.end,
                calendar: calendar
            )
            let prevPending = consumedDays(
                bookings: bookings,
                userId: profileUserId,
                operativeId: operativeId,
                statuses: [.pending],
                rangeStart: prev.start,
                rangeEnd: prev.end,
                calendar: calendar
            )
            carry = max(0, days - prevTaken - prevPending)
        }

        let entitlement = days + carry
        let remaining = max(0, entitlement - taken - pending)
        let label = formattedLeaveYearLabel(range: range, calendar: calendar)

        return AnnualLeaveUsageSummary(
            leaveYearLabel: label,
            entitlementDays: entitlement,
            carryOverDays: carry,
            takenDays: taken,
            pendingDays: pending,
            remainingDays: remaining
        )
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
        profileUserId: String,
        operativeId: UUID?,
        daysPerYear: Double,
        startMonth: Int,
        endMonth: Int,
        carriesOver: Bool,
        calendar: Calendar = .current
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
                profileUserId: profileUserId,
                operativeId: operativeId,
                daysPerYear: daysPerYear,
                startMonth: startMonth,
                endMonth: endMonth,
                carriesOver: carriesOver,
                referenceDate: ref,
                calendar: calendar
            )
            let requested = Double(days.count) * timeSlot.dayValue
            if requested > summary.remainingDays + allowanceEpsilon {
                let rem = formatAllowanceDays(summary.remainingDays)
                let req = formatAllowanceDays(requested)
                return "In \(summary.leaveYearLabel) you have \(rem) days of annual leave left (after booked and pending), but this selection needs \(req) days. Remove dates, choose shorter slots, or wait until your allowance renews."
            }
        }
        return nil
    }

    /// Validates increasing `timeSlot` day-value on an existing booking (e.g. AM → full day). Downgrades always pass.
    static func validateTimeSlotIncreaseAgainstAllowance(
        booking: HolidayBooking,
        newTimeSlot: HolidayTimeSlot,
        bookings: [HolidayBooking],
        profileUserId: String,
        operativeId: UUID?,
        daysPerYear: Double,
        startMonth: Int,
        endMonth: Int,
        carriesOver: Bool,
        calendar: Calendar = .current
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
                profileUserId: profileUserId,
                operativeId: operativeId,
                daysPerYear: daysPerYear,
                startMonth: startMonth,
                endMonth: endMonth,
                carriesOver: carriesOver,
                referenceDate: yearStart,
                calendar: calendar
            )
            if extra > summary.remainingDays + allowanceEpsilon {
                let rem = formatAllowanceDays(summary.remainingDays)
                let ex = formatAllowanceDays(extra)
                return "In \(summary.leaveYearLabel) you have \(rem) days of annual leave left; changing to \(newTimeSlot.rawValue) would need \(ex) more days than you have available."
            }
        }
        return nil
    }

    private static func formattedLeaveYearLabel(range: (start: Date, end: Date), calendar: Calendar) -> String {
        let df = DateFormatter()
        df.calendar = calendar
        df.timeZone = calendar.timeZone
        df.dateFormat = "MMM yyyy"
        return "\(df.string(from: range.start)) – \(df.string(from: range.end))"
    }

    static func shortMonthSymbols(calendar: Calendar = .current) -> [String] {
        let df = DateFormatter()
        df.calendar = calendar
        df.locale = calendar.locale ?? .current
        return df.shortMonthSymbols
    }
}
