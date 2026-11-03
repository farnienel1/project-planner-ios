//
//  OperativeBookingInterval.swift
//  Project Planner
//
//  Time overlap for operative project bookings (clock windows + legacy slots mapped to org standard day).
//

import Foundation

enum OperativeBookingInterval {
    /// Clock interval for clash detection, in minutes from midnight: the canonical script's
    /// `slotInterval` with the stored slot and stored clock times. Clock times win; the named slot
    /// applies only when the script rejects the clock pair. The day input is always the weekday
    /// standard day and break, on every day of the week. A finish before the start crosses midnight (RULEBOOK 1.13.0
    /// Q5): the script runs it past 24:00; the clock times are passed unchanged.
    static func clashInterval(for booking: Booking, policy: OrgPayrollTimePolicy) -> (Int, Int)? {
        CanonicalBusinessEngine.slotInterval(
            timeSlot: booking.timeSlot.rawValue,
            workStartTime: booking.workStartTime,
            workEndTime: booking.workEndTime,
            day: CanonicalStandardDayInput(policy: policy)
        )?.tuple
    }

    static func closedIntervalsOverlap(_ a: (Int, Int), _ b: (Int, Int)) -> Bool {
        a.0 < b.1 && b.0 < a.1
    }

    static func bookingsOverlap(_ a: Booking, _ b: Booking, policy: OrgPayrollTimePolicy) -> Bool {
        guard let ia = clashInterval(for: a, policy: policy),
              let ib = clashInterval(for: b, policy: policy) else {
            return legacyOperativeSlotClash(a.timeSlot, b.timeSlot)
        }
        return closedIntervalsOverlap(ia, ib)
    }

    /// Wall-clock hours overlapping the org standard day window for the booking's calendar day.
    static func hoursInsideStandardClockWindow(booking: Booking, policy: OrgPayrollTimePolicy) -> Double {
        guard let iv = clashInterval(for: booking, policy: policy) else { return 0 }
        let timeline = PayrollTimePolicyCatalog.timelinePolicy(for: booking.date, policy: policy)
        guard let ds = timeline.standardWindowStartMinutes,
              let de = timeline.standardWindowEndMinutes, de > ds else { return 0 }
        let overlapStart = max(iv.0, ds)
        let overlapEnd = min(iv.1, de)
        guard overlapEnd > overlapStart else { return 0 }
        return Double(overlapEnd - overlapStart) / 60.0
    }

    static func coversFullStandardDay(_ booking: Booking, policy: OrgPayrollTimePolicy) -> Bool {
        guard let iv = clashInterval(for: booking, policy: policy) else { return false }
        let timeline = PayrollTimePolicyCatalog.timelinePolicy(for: booking.date, policy: policy)
        guard !timeline.allHoursAtMultiplier,
              let ws = timeline.standardWindowStartMinutes,
              let we = timeline.standardWindowEndMinutes else { return false }
        return iv.0 <= ws && iv.1 >= we
    }

    private static func legacyOperativeSlotClash(_ a: TimeSlot, _ b: TimeSlot) -> Bool {
        if a == .fullDay || b == .fullDay { return true }
        if a == b { return true }
        return false
    }

    // Timesheet pay: every booking is paid on its own (rulebook §6). Overlaps are only flagged, with
    // `overlappingBookingIds` in TimesheetPayrollCollector; bookings are never merged.
}

extension Booking {
    func scheduleLabel(policy: OrgPayrollTimePolicy = .default) -> String {
        if timeSlot == .morning || timeSlot == .afternoon,
           let iv = OperativeBookingInterval.clashInterval(for: self, policy: policy) {
            return "\(ManagerScheduleInterval.formatMinutes(iv.0))–\(ManagerScheduleInterval.formatMinutes(iv.1))"
        }
        if let s = workStartTime, let e = workEndTime, !s.isEmpty, !e.isEmpty {
            var base = "\(s)–\(e)"
            if isBreakRemoved { base += " · no break" }
            return base
        }
        return timeSlot.displayName
    }

    /// Paid hours for UI: uses the shared payroll engine (weekday/weekend OT, multipliers, break rules).
    func paidBookedHours(policy: OrgPayrollTimePolicy = .default) -> Double {
        payrollHoursResult(policy: policy).totalPaidHours
    }

    /// Wall-clock overtime hours outside the standard window (weekday or weekend), for badges.
    func overtimeHoursBeyondPaidStandard(policy: OrgPayrollTimePolicy = .default) -> Double {
        let result = payrollHoursResult(policy: policy)
        return result.segments
            .filter { $0.kind == .outsideWindow || $0.kind == .allHoursMultiplier }
            .reduce(0) { $0 + $1.baseHours }
    }

    /// Second line under the person’s name (daily overview / my schedule): clock-first, full-day phrasing, OT hint.
    func scheduleCoverageSubtitle(policy: OrgPayrollTimePolicy = .default) -> (text: String, emphasizedOvertime: Bool) {
        let timeline = PayrollTimePolicyCatalog.timelinePolicy(for: date, policy: policy)
        // "Full standard day" only when nothing runs past it. A 07:30–19:15 day covers the standard
        // day too, but must show its clock times and overtime, as web does.
        let hasCustomClock = !(workStartTime ?? "").isEmpty && !(workEndTime ?? "").isEmpty
        let runsIntoOvertime = hasCustomClock && overtimeHoursBeyondPaidStandard(policy: policy) > 0.05
        if OperativeBookingInterval.coversFullStandardDay(self, policy: policy), !runsIntoOvertime {
            if let start = timeline.standardWindowStart, let end = timeline.standardWindowEnd {
                return ("Full standard day · \(start)–\(end)", false)
            }
        }
        if let s = workStartTime, let e = workEndTime, !s.isEmpty, !e.isEmpty {
            let result = payrollHoursResult(policy: policy)
            // RULEBOOK 1.20.4 (`CanonicalBusinessEngine.payrollMultipliedHours`): hours at the multiplier as clock hours with the break as plain hours
            // (`payrollMultipliedHours` → "6.5h × 2 − 0.5h break = 12.5h"), never the back-calculated base.
            if let multiplied = result.multipliedHours, multiplied.clockHours > 0.05 {
                let stdShow = max(0, result.totalPaidHours - multiplied.paidHours)
                let text = stdShow > 0.005 ? "\(ScheduleCoverageFormat.hours(stdShow))h + \(multiplied.text)" : multiplied.text
                return ("\(s)–\(e) · \(text)", true)
            }
            var t = "\(s)–\(e)"
            // RULEBOOK 1.19.0: "break removed" only on a day that takes an unpaid break off (`unpaidBreakAppliesOnDay`).
            if isBreakRemoved,
               CanonicalBusinessEngine.unpaidBreakAppliesOnDay(policy: policy, dayKey: CanonicalBusinessEngine.bookingDayKey(date)) {
                t += " · break removed"
            }
            return (t, false)
        }
        switch timeSlot {
        case .fullDay:
            if let start = timeline.standardWindowStart, let end = timeline.standardWindowEnd {
                return ("Full standard day · \(start)–\(end)", false)
            }
            return ("Full standard day · \(policy.standardDayStart)–\(policy.standardDayEnd)", false)
        case .morning, .afternoon:
            return (scheduleLabel(policy: policy), false)
        default:
            return (scheduleLabel(policy: policy), false)
        }
    }

    func scheduleCoveragePillHours(policy: OrgPayrollTimePolicy = .default) -> String {
        ScheduleCoverageFormat.hours(paidBookedHours(policy: policy)) + "h"
    }

    /// The multiplier `payrollHoursResult` pays this booking's outside hours at (override, weekend day, or weekday).
    func effectiveWeekdayOtMultiplier(policy: OrgPayrollTimePolicy = .default) -> Double {
        payrollHoursResult(policy: policy).outsideMultiplier
    }

    func minutesSortKey(policy: OrgPayrollTimePolicy = .default) -> Int {
        OperativeBookingInterval.clashInterval(for: self, policy: policy)?.0 ?? 0
    }

    /// Weekly-report day units (`reportDayValue`): weighted paid hours over the standard day, capped at 1.5.
    func reportDayValue(policy: OrgPayrollTimePolicy = .default) -> Double {
        let paidHrs = paidBookedHours(policy: policy)
        // Nil only when the script did not run; bookings are then unreadable too.
        return CanonicalBusinessEngine.reportDayValue(totalPaidHours: paidHrs, standardPaidHours: CanonicalBusinessEngine.weekdayPaidHours(policy)) ?? 0
    }

    func calendarBlock(on day: Date, policy: OrgPayrollTimePolicy = .default) -> (start: Date, end: Date) {
        let cal = Calendar.current
        let startOfDay = cal.startOfDay(for: day)
        // The script's slotInterval with the stored slot and clocks (calendar export and reminders).
        guard let iv = OperativeBookingInterval.clashInterval(for: self, policy: policy) else {
            let end = cal.date(byAdding: .hour, value: 8, to: startOfDay) ?? startOfDay
            return (startOfDay, end)
        }
        let start = cal.date(byAdding: .minute, value: iv.0, to: startOfDay) ?? startOfDay
        let end = cal.date(byAdding: .minute, value: iv.1, to: startOfDay) ?? startOfDay
        return (start, end)
    }

    /// Clock hours this booking occupies: the length of its `slotInterval` (the rulebook's interval for the stored slot
    /// and clock times — an overnight 22:00–02:00 is 22:00 to 26:00, 4h; a FULL DAY / AM / PM its window). No Swift copy of
    /// the slot table or the overnight rule (`CanonicalBusinessEngine.slotInterval`); 0 when the script did not answer.
    func totalBookedHours(policy: OrgPayrollTimePolicy = .default) -> Double {
        guard let iv = OperativeBookingInterval.clashInterval(for: self, policy: policy) else { return 0 }
        return Double(max(0, iv.1 - iv.0)) / 60.0
    }
}

enum ScheduleCoverageFormat {
    /// Hours as the pay rule gives them, to the hundredth with trailing zeros dropped (7.25 → "7.25", 3.5 → "3.5",
    /// 8 → "8"). RULEBOOK 1.20.0: a derived weekday day is often a quarter hour (owner example 7.25h), so the display
    /// never rounds it to the half hour (it used to show 7.25 as "7.5").
    static func hours(_ h: Double) -> String {
        let rounded = (h * 100).rounded() / 100
        var text = String(format: "%.2f", rounded)
        while text.hasSuffix("0") { text.removeLast() }
        if text.hasSuffix(".") { text.removeLast() }
        return text == "-0" ? "0" : text
    }

    static func multiplier(_ m: Double) -> String {
        if abs(m - m.rounded()) < 0.05 {
            return String(format: "%.0f", m)
        }
        return String(format: "%.1f", m)
    }

}

extension OperativeDayBookingChoice {
    /// Maps a persisted operative booking into the scheduling picker model.
    init(from booking: Booking) {
        if booking.timeSlot == .customHours,
           let s = booking.workStartTime, let e = booking.workEndTime,
           !s.isEmpty, !e.isEmpty {
            self.init(
                timeSlot: .customHours,
                workStartTime: s,
                workEndTime: e,
                isBreakRemoved: booking.isBreakRemoved,
                otMultiplierOverride: booking.otMultiplierOverride
            )
        } else {
            self.init(
                timeSlot: booking.timeSlot,
                workStartTime: booking.workStartTime,
                workEndTime: booking.workEndTime,
                isBreakRemoved: booking.isBreakRemoved,
                otMultiplierOverride: booking.otMultiplierOverride
            )
        }
    }

    func scheduleLabel(policy: OrgPayrollTimePolicy) -> String {
        let probe = Booking(
            operativeId: UUID(),
            projectId: UUID(),
            date: Date(),
            timeSlot: timeSlot,
            bookedBy: "",
            workStartTime: workStartTime,
            workEndTime: workEndTime,
            isBreakRemoved: isBreakRemoved,
            otMultiplierOverride: otMultiplierOverride
        )
        return probe.scheduleLabel(policy: policy)
    }

    func bookingProbe(operativeId: UUID, projectId: UUID, date: Date, bookedBy: String) -> Booking {
        Booking(
            operativeId: operativeId,
            projectId: projectId,
            date: date,
            timeSlot: timeSlot,
            bookedBy: bookedBy,
            workStartTime: workStartTime,
            workEndTime: workEndTime,
            isBreakRemoved: isBreakRemoved,
            otMultiplierOverride: otMultiplierOverride
        )
    }
}
