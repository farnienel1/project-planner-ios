//
//  OperativeBookingInterval.swift
//  Project Planner
//
//  Time overlap for operative project bookings (clock windows + legacy slots mapped to org standard day).
//

import Foundation

enum OperativeBookingInterval {
    static func clashInterval(for booking: Booking, policy: OrgPayrollTimePolicy) -> (Int, Int)? {
        if let s = booking.workStartTime, let e = booking.workEndTime,
           let sm = ManagerScheduleInterval.parseMinutes(s), let em = ManagerScheduleInterval.parseMinutes(e), em > sm {
            return (sm, em)
        }
        guard let dayStart = resolvedStandardWindowStart(for: booking, policy: policy),
              let dayEnd = resolvedStandardWindowEnd(for: booking, policy: policy),
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
        case .evening:
            let end = min(dayEnd + 240, 24 * 60)
            return end > dayEnd ? (dayEnd, end) : nil
        case .overtime:
            let startOT = min(dayEnd + 240, 24 * 60)
            let endOT = min(dayEnd + 360, 24 * 60)
            return endOT > startOT ? (startOT, endOT) : nil
        }
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

    private static func resolvedStandardWindowStart(for booking: Booking, policy: OrgPayrollTimePolicy) -> Int? {
        let timeline = PayrollTimePolicyCatalog.timelinePolicy(for: booking.date, policy: policy)
        if timeline.allHoursAtMultiplier { return nil }
        return timeline.standardWindowStartMinutes
            ?? ManagerScheduleInterval.parseMinutes(policy.standardDayStart)
    }

    private static func resolvedStandardWindowEnd(for booking: Booking, policy: OrgPayrollTimePolicy) -> Int? {
        let timeline = PayrollTimePolicyCatalog.timelinePolicy(for: booking.date, policy: policy)
        if timeline.allHoursAtMultiplier { return nil }
        return timeline.standardWindowEndMinutes
            ?? ManagerScheduleInterval.parseMinutes(policy.standardDayEnd)
    }

    private static func legacyOperativeSlotClash(_ a: TimeSlot, _ b: TimeSlot) -> Bool {
        if a == .fullDay || b == .fullDay { return true }
        if a == b { return true }
        return false
    }
}

extension Booking {
    func scheduleLabel(policy: OrgPayrollTimePolicy = .default) -> String {
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
            .reduce(0) { $0 + $1.paidHours }
    }

    /// Second line under the person’s name (daily overview / my schedule): clock-first, full-day phrasing, OT hint.
    func scheduleCoverageSubtitle(policy: OrgPayrollTimePolicy = .default) -> (text: String, emphasizedOvertime: Bool) {
        let timeline = PayrollTimePolicyCatalog.timelinePolicy(for: date, policy: policy)
        if OperativeBookingInterval.coversFullStandardDay(self, policy: policy) {
            if let start = timeline.standardWindowStart, let end = timeline.standardWindowEnd {
                return ("Full standard day · \(start)–\(end)", false)
            }
        }
        if let s = workStartTime, let e = workEndTime, !s.isEmpty, !e.isEmpty {
            let result = payrollHoursResult(policy: policy)
            let ot = overtimeHoursBeyondPaidStandard(policy: policy)
            if ot > 0.05, let outside = result.segments.first(where: { $0.kind == .outsideWindow || $0.kind == .allHoursMultiplier }) {
                let stdShow = result.totalPaidHours - ot
                let multStr = outside.multiplierLabel
                return ("\(s)–\(e) · \(ScheduleCoverageFormat.hours(stdShow))h + \(ScheduleCoverageFormat.hours(ot))h × \(multStr) (Multiplier)", true)
            }
            var t = "\(s)–\(e)"
            if isBreakRemoved {
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

    func effectiveWeekdayOtMultiplier(policy: OrgPayrollTimePolicy = .default) -> Double {
        PayrollTimePolicyCatalog.effectiveMultiplier(for: self, policy: policy)
    }

    func minutesSortKey(policy: OrgPayrollTimePolicy = .default) -> Int {
        if let s = workStartTime, let m = ManagerScheduleInterval.parseMinutes(s) { return m }
        guard let interval = OperativeBookingInterval.clashInterval(for: self, policy: policy) else {
            return 0
        }
        return interval.0
    }

    func reportDayValue(policy: OrgPayrollTimePolicy = .default) -> Double {
        let paidHrs = paidBookedHours(policy: policy)
        let standard = max(policy.standardPaidHours, 0.01)
        return min(1.5, paidHrs / standard)
    }

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
        guard let iv = OperativeBookingInterval.clashInterval(for: self, policy: policy) else {
            let end = cal.date(byAdding: .hour, value: 8, to: startOfDay) ?? startOfDay
            return (startOfDay, end)
        }
        let start = cal.date(byAdding: .minute, value: iv.0, to: startOfDay) ?? startOfDay
        let end = cal.date(byAdding: .minute, value: iv.1, to: startOfDay) ?? startOfDay
        return (start, end)
    }

    /// Wall-clock hours for this booking (explicit times or legacy slot mapped to the org day).
    func totalBookedHours(policy: OrgPayrollTimePolicy = .default) -> Double {
        if let s = workStartTime, let e = workEndTime,
           let sm = ManagerScheduleInterval.parseMinutes(s),
           let em = ManagerScheduleInterval.parseMinutes(e), em > sm {
            return Double(em - sm) / 60.0
        }
        if let iv = OperativeBookingInterval.clashInterval(for: self, policy: policy) {
            return Double(iv.1 - iv.0) / 60.0
        }
        switch timeSlot {
        case .fullDay: return max(policy.standardPaidHours, 0)
        case .morning, .afternoon: return max(policy.standardPaidHours, 0) / 2
        case .evening: return 4
        case .overtime: return 2
        case .customHours: return max(policy.standardPaidHours, 0)
        }
    }
}

enum ScheduleCoverageFormat {
    static func hours(_ h: Double) -> String {
        let rounded = (h * 2).rounded() / 2
        if abs(rounded - rounded.rounded(.towardZero)) < 0.01 {
            return String(format: "%.0f", rounded)
        }
        return String(format: "%.1f", rounded)
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
