//
//  ManagerScheduleInterval.swift
//  Project Planner
//
//  Interval overlap for manager self-bookings (clock times + legacy AM/PM/full day mapped to org standard day).
//

import Foundation

enum ManagerScheduleInterval {
    static func parseMinutes(_ hhmm: String) -> Int? {
        let trimmed = hhmm.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = trimmed.split(separator: ":")
        guard parts.count == 2,
              let h = Int(parts[0]),
              let m = Int(parts[1]),
              h >= 0, h < 24, m >= 0, m < 60 else { return nil }
        return h * 60 + m
    }

    /// Closed intervals [start, end] in minutes from midnight; touching endpoints do not overlap.
    static func closedIntervalsOverlap(_ a: (Int, Int), _ b: (Int, Int)) -> Bool {
        a.0 < b.1 && b.0 < a.1
    }

    /// Interval used for clash detection.
    static func clashInterval(for booking: ManagerSiteBooking, policy: OrgPayrollTimePolicy) -> (Int, Int)? {
        if let s = booking.workStartTime, let e = booking.workEndTime,
           let sm = parseMinutes(s), let em = parseMinutes(e), em > sm {
            return (sm, em)
        }
        guard let dayStart = parseMinutes(policy.standardDayStart),
              let dayEnd = parseMinutes(policy.standardDayEnd),
              dayEnd > dayStart else {
            if booking.timeSlot == .fullDay { return (0, 24 * 60) }
            return nil
        }
        switch booking.timeSlot {
        case .fullDay:
            return (dayStart, dayEnd)
        case .morning:
            let mid = dayStart + (dayEnd - dayStart) / 2
            return (dayStart, mid)
        case .afternoon:
            let mid = dayStart + (dayEnd - dayStart) / 2
            return (mid, dayEnd)
        case .customHours:
            return (dayStart, dayEnd)
        }
    }

    static func bookingsOverlap(_ a: ManagerSiteBooking, _ b: ManagerSiteBooking, policy: OrgPayrollTimePolicy) -> Bool {
        guard let ia = clashInterval(for: a, policy: policy),
              let ib = clashInterval(for: b, policy: policy) else {
            return legacySlotPairClash(a.timeSlot, b.timeSlot)
        }
        return closedIntervalsOverlap(ia, ib)
    }

    /// True when the booking’s clash interval fully covers the org standard day window.
    static func coversFullStandardDay(_ booking: ManagerSiteBooking, policy: OrgPayrollTimePolicy) -> Bool {
        guard let iv = clashInterval(for: booking, policy: policy),
              let ws = parseMinutes(policy.standardDayStart),
              let we = parseMinutes(policy.standardDayEnd),
              we > ws else { return false }
        return iv.0 <= ws && iv.1 >= we
    }

    private static func legacySlotPairClash(_ a: ManagerTimeSlot, _ b: ManagerTimeSlot) -> Bool {
        if a == .fullDay || b == .fullDay { return true }
        if a == b { return true }
        if (a == .morning && b == .afternoon) || (a == .afternoon && b == .morning) { return false }
        return true
    }
}

extension ManagerSiteBooking {
    /// User-facing time line: clock range when set, otherwise legacy slot label.
    func scheduleLabel(policy: OrgPayrollTimePolicy = .default) -> String {
        if let s = workStartTime, let e = workEndTime,
           !s.isEmpty, !e.isEmpty {
            var base = "\(s)–\(e)"
            if isBreakRemoved { base += " · no break" }
            return base
        }
        return timeSlot.displayName
    }

    func paidBookedHours(policy: OrgPayrollTimePolicy = .default) -> Double {
        if let s = workStartTime, let e = workEndTime,
           let sm = ManagerScheduleInterval.parseMinutes(s),
           let em = ManagerScheduleInterval.parseMinutes(e), em > sm {
            var wall = Double(em - sm) / 60.0
            if !isBreakRemoved {
                wall = max(0, wall - policy.standardUnpaidBreakHours)
            }
            return wall
        }
        // Legacy AM/PM/full day mapped to org clock window: show paid hours (e.g. 8h), not raw span (e.g. 8.5h).
        switch timeSlot {
        case .fullDay, .customHours:
            return max(policy.standardPaidHours, 0)
        case .morning, .afternoon:
            return max(policy.standardPaidHours, 0) / 2
        }
    }

    func scheduleCoverageSubtitle(policy: OrgPayrollTimePolicy = .default) -> (text: String, emphasizedOvertime: Bool) {
        if ManagerScheduleInterval.coversFullStandardDay(self, policy: policy) {
            return ("Full standard day · \(policy.standardDayStart)–\(policy.standardDayEnd)", false)
        }
        if let s = workStartTime, let e = workEndTime, !s.isEmpty, !e.isEmpty {
            let ot = overtimeHoursBeyondPaidStandard(policy: policy)
            if ot > 0.05 {
                let stdShow = paidBookedHours(policy: policy) - ot
                let mult = policy.weekdayOutsideStandardMultiplier
                let multStr = abs(mult - mult.rounded()) < 0.05 ? String(format: "%.0f", mult) : String(format: "%.1f", mult)
                return ("\(s)–\(e) · \(ScheduleCoverageFormat.hours(stdShow))h std + \(ScheduleCoverageFormat.hours(ot))h × \(multStr)", true)
            }
            var t = "\(s)–\(e)"
            if isBreakRemoved {
                t += " · break removed"
            }
            return (t, false)
        }
        switch timeSlot {
        case .fullDay:
            return ("Full standard day · \(policy.standardDayStart)–\(policy.standardDayEnd)", false)
        case .morning, .afternoon:
            return (scheduleLabel(policy: policy), false)
        case .customHours:
            return (scheduleLabel(policy: policy), false)
        }
    }

    func scheduleCoveragePillHours(policy: OrgPayrollTimePolicy = .default) -> String {
        ScheduleCoverageFormat.hours(paidBookedHours(policy: policy)) + "h"
    }

    func minutesSortKey(policy: OrgPayrollTimePolicy = .default) -> Int {
        if let s = workStartTime, let m = ManagerScheduleInterval.parseMinutes(s) { return m }
        switch timeSlot {
        case .fullDay, .morning:
            return ManagerScheduleInterval.parseMinutes(policy.standardDayStart) ?? 0
        case .afternoon:
            let ds = ManagerScheduleInterval.parseMinutes(policy.standardDayStart) ?? 0
            let de = ManagerScheduleInterval.parseMinutes(policy.standardDayEnd) ?? (ds + 1)
            return ds + (de - ds) / 2
        case .customHours:
            return ManagerScheduleInterval.parseMinutes(policy.standardDayStart) ?? 0
        }
    }

    /// Rough “day units” for reports from paid hours (includes break toggle and OT).
    func reportDayValue(policy: OrgPayrollTimePolicy = .default) -> Double {
        let paidHrs = paidBookedHours(policy: policy)
        let standard = max(policy.standardPaidHours, 0.01)
        return min(1.5, paidHrs / standard)
    }

    /// Start/end instants on the booking’s calendar day (for Calendar export and reminders).
    func calendarBlock(on day: Date, policy: OrgPayrollTimePolicy = .default) -> (start: Date, end: Date) {
        let cal = Calendar.current
        let startOfDay = cal.startOfDay(for: day)
        if let s = workStartTime, let e = workEndTime,
           let sm = ManagerScheduleInterval.parseMinutes(s),
           let em = ManagerScheduleInterval.parseMinutes(e), em > sm {
            let start = cal.date(byAdding: .minute, value: sm, to: startOfDay) ?? startOfDay
            let end = cal.date(byAdding: .minute, value: em, to: startOfDay) ?? startOfDay
            return (start, end)
        }
        guard let ds = ManagerScheduleInterval.parseMinutes(policy.standardDayStart),
              let de = ManagerScheduleInterval.parseMinutes(policy.standardDayEnd),
              de > ds else {
            let end = cal.date(byAdding: .hour, value: timeSlot == .morning || timeSlot == .afternoon ? 4 : 8, to: startOfDay) ?? startOfDay
            return (startOfDay, end)
        }
        let mid = ds + (de - ds) / 2
        switch timeSlot {
        case .fullDay, .customHours:
            let start = cal.date(byAdding: .minute, value: ds, to: startOfDay) ?? startOfDay
            let end = cal.date(byAdding: .minute, value: de, to: startOfDay) ?? startOfDay
            return (start, end)
        case .morning:
            let start = cal.date(byAdding: .minute, value: ds, to: startOfDay) ?? startOfDay
            let end = cal.date(byAdding: .minute, value: mid, to: startOfDay) ?? startOfDay
            return (start, end)
        case .afternoon:
            let start = cal.date(byAdding: .minute, value: mid, to: startOfDay) ?? startOfDay
            let end = cal.date(byAdding: .minute, value: de, to: startOfDay) ?? startOfDay
            return (start, end)
        }
    }

    func totalBookedHours(policy: OrgPayrollTimePolicy = .default) -> Double {
        if let iv = ManagerScheduleInterval.clashInterval(for: self, policy: policy) {
            return Double(iv.1 - iv.0) / 60.0
        }
        return max(policy.standardPaidHours, 0)
    }

    func overtimeHoursBeyondPaidStandard(policy: OrgPayrollTimePolicy = .default) -> Double {
        max(0, paidBookedHours(policy: policy) - max(policy.standardPaidHours, 0))
    }
}
