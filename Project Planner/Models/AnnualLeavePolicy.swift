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
        calendar: Calendar = .current
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
        calendar: Calendar = .current
    ) -> (start: Date, end: Date)? {
        guard let dayBefore = calendar.date(byAdding: .day, value: -1, to: start) else { return nil }
        return leaveYearRange(containing: dayBefore, startMonth: startMonth, endMonth: endMonth, calendar: calendar)
    }

    static func holidayUserMatches(bookingUserId: String?, profileUserId: String?, profileEmail: String?) -> Bool {
        guard let storedRaw = bookingUserId?.trimmingCharacters(in: .whitespacesAndNewlines), !storedRaw.isEmpty else {
            return false
        }
        if let profileUserId {
            let profile = profileUserId.trimmingCharacters(in: .whitespacesAndNewlines)
            if !profile.isEmpty, storedRaw.caseInsensitiveCompare(profile) == .orderedSame { return true }
        }
        if let profileEmail {
            let email = profileEmail.trimmingCharacters(in: .whitespacesAndNewlines)
            if !email.isEmpty, storedRaw.caseInsensitiveCompare(email) == .orderedSame { return true }
        }
        return false
    }

    static func consumedDays(
        bookings: [HolidayBooking],
        userId: String?,
        operativeId: UUID?,
        profileEmail: String? = nil,
        statuses: Set<HolidayStatus>,
        rangeStart: Date,
        rangeEnd: Date,
        calendar: Calendar = .current
    ) -> Double {
        let rs = calendar.startOfDay(for: rangeStart)
        let re = calendar.startOfDay(for: rangeEnd)
        // Several requests can cover the same calendar day. A day never consumes more than 1.
        var byDay: [Date: Double] = [:]
        for b in bookings where statuses.contains(b.status) {
            let matchesUser = Self.holidayUserMatches(bookingUserId: b.userId, profileUserId: userId, profileEmail: profileEmail)
            let matchesOp = operativeId != nil && b.operativeId == operativeId
            guard matchesUser || matchesOp else { continue }

            var d = calendar.startOfDay(for: b.startDate)
            let endB = calendar.startOfDay(for: b.endDate)
            while d <= endB {
                if d >= rs && d <= re {
                    byDay[d, default: 0] += b.timeSlot.dayValue
                }
                guard let nx = calendar.date(byAdding: .day, value: 1, to: d) else { break }
                d = nx
            }
        }
        return byDay.values.reduce(0) { $0 + min(1, $1) }
    }

    static func usageSummary(
        bookings: [HolidayBooking],
        profileUserId: String,
        operativeId: UUID?,
        profileEmail: String? = nil,
        daysPerYear: Double,
        startMonth: Int,
        endMonth: Int,
        carriesOver: Bool,
        referenceDate: Date = Date(),
        calendar: Calendar = .current,
        annualLeaveEnabled: Bool = true,
        orgDaysPerYear: Double? = nil,
        orgStartMonth: Int? = nil,
        orgEndMonth: Int? = nil,
        yearAllowance: Double? = nil,
        yearAllowanceKey: String? = nil
    ) -> AnnualLeaveUsageSummary {
        _ = calendar
        let records: [CanonicalBusinessEngine.CanonicalLeaveBooking] = bookings.compactMap { booking in
            let matchesUser = holidayUserMatches(bookingUserId: booking.userId, profileUserId: profileUserId, profileEmail: profileEmail)
            let matchesOp = operativeId != nil && booking.operativeId == operativeId
            guard matchesUser || matchesOp else { return nil }
            return CanonicalBusinessEngine.CanonicalLeaveBooking(
                startDayKey: CanonicalBusinessEngine.dayKey(for: booking.startDate),
                endDayKey: CanonicalBusinessEngine.dayKey(for: booking.endDate),
                timeSlot: booking.timeSlot.rawValue,
                status: booking.status.rawValue
            )
        }
        let balance = CanonicalBusinessEngine.annualLeaveBalance(
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
            onDayKey: CanonicalBusinessEngine.dayKey(for: referenceDate)
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
        let entitlement = balance.yearAllowance ?? (balance.daysPerYear + balance.carriedForward)
        return AnnualLeaveUsageSummary(
            leaveYearLabel: label,
            entitlementDays: entitlement,
            carryOverDays: balance.carriedForward,
            takenDays: balance.taken,
            pendingDays: balance.pending,
            remainingDays: balance.remaining,
            hasAllowance: balance.hasAllowance,
            usedThisYear: balance.usedThisYear,
            yearKey: balance.yearKey
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
        profileUserId: String,
        operativeId: UUID?,
        daysPerYear: Double,
        startMonth: Int,
        endMonth: Int,
        carriesOver: Bool,
        calendar: Calendar = .current
    ) -> String? {
        let normalized = Dictionary(uniqueKeysWithValues: daySlots.map { (calendar.startOfDay(for: $0.key), $0.value) })
        guard !normalized.isEmpty else { return nil }
        let buckets = bucketStartOfDaysByLeaveYear(Array(normalized.keys), startMonth: startMonth, endMonth: endMonth, calendar: calendar)
        guard !buckets.isEmpty else {
            return "Could not determine your leave year for one or more selected dates."
        }
        for (_, days) in buckets {
            let ref = days.first ?? Date()
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
