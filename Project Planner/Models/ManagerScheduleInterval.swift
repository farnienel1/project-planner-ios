//
//  ManagerScheduleInterval.swift
//  Project Planner
//
//  Interval overlap for manager self-bookings (clock times + legacy AM/PM/full day mapped to org standard day).
//

import Foundation

enum ManagerScheduleInterval {
    nonisolated static func parseMinutes(_ hhmm: String) -> Int? {
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

    /// A manager booking's clock interval (labels, sort order, calendar export): the canonical script's `slotInterval`
    /// with the stored slot and clock times, the named slot read on the booking's own day (RULEBOOK 1.23.1
    /// `CanonicalBusinessEngine.bookingStandardDayOn`).
    static func clashInterval(for booking: ManagerSiteBooking, policy: OrgPayrollTimePolicy) -> (Int, Int)? {
        CanonicalBusinessEngine.slotInterval(
            timeSlot: booking.timeSlot.rawValue,
            workStartTime: booking.workStartTime,
            workEndTime: booking.workEndTime,
            day: CanonicalBusinessEngine.bookingStandardDayOn(policy: policy, dayKey: OrganizationRulebookContext.dayKey(booking.date))
        )?.tuple
    }

    /// RULEBOOK 1.23.0 §5 `CanonicalBusinessEngine.bookingRequestClashIds` with the booked day's working hours (see
    /// `OperativeBookingInterval.bookingsOverlap`). True when the script did not answer.
    static func bookingsOverlap(_ a: ManagerSiteBooking, _ b: ManagerSiteBooking, policy: OrgPayrollTimePolicy) -> Bool {
        guard let ids = CanonicalBusinessEngine.bookingRequestClashIds(
            request: a.rulebookClashBooking,
            existing: [b.rulebookClashBooking],
            day: CanonicalBusinessEngine.bookingDayInput(policy: policy)
        ) else { return true }
        return !ids.isEmpty
    }

    /// True when the booking’s clash interval fully covers the org standard day window.
    static func coversFullStandardDay(_ booking: ManagerSiteBooking, policy: OrgPayrollTimePolicy) -> Bool {
        guard let iv = clashInterval(for: booking, policy: policy),
              let ws = parseMinutes(policy.standardDayStart),
              let we = parseMinutes(policy.standardDayEnd),
              we > ws else { return false }
        return iv.0 <= ws && iv.1 >= we
    }

    // RULEBOOK 1.22.0 §6: a person's paid hours and cover across several bookings on one day are
    // `CanonicalBusinessEngine.managerCoverageHours` (merged blocks, break taken off once by the pay rule, `covered` =
    // `standardDayCoverage`). The Swift `combinedPaidBookedHours` that was here is deleted.
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
        payrollHoursResult(policy: policy).totalPaidHours
    }

    func payrollHoursResult(policy: OrgPayrollTimePolicy = .default) -> PayrollHoursResult {
        PayrollHoursEngine.compute(booking: operativePayrollProbe(), day: date, policy: policy)
    }

    func effectiveWeekdayOtMultiplier(policy: OrgPayrollTimePolicy = .default) -> Double {
        payrollHoursResult(policy: policy).outsideMultiplier
    }

    /// Maps manager schedule booking into the shared operative payroll probe shape.
    func operativePayrollProbe() -> Booking {
        let slot: TimeSlot = {
            switch timeSlot {
            case .morning: return .morning
            case .afternoon: return .afternoon
            case .fullDay: return .fullDay
            case .customHours: return .customHours
            }
        }()
        return Booking(
            operativeId: UUID(),
            projectId: locationId ?? UUID(),
            date: date,
            timeSlot: slot,
            bookedBy: userId,
            workStartTime: workStartTime,
            workEndTime: workEndTime,
            isBreakRemoved: isBreakRemoved,
            // RULEBOOK 1.29.0 §25: a manager site booking's own overtime rate prices its overtime part too
            // (CanonicalBusinessEngine payrollHoursResult via PayrollHoursEngine).
            otMultiplierOverride: otMultiplierOverride
        )
    }

    func scheduleCoverageSubtitle(policy: OrgPayrollTimePolicy = .default) -> (text: String, emphasizedOvertime: Bool) {
        operativePayrollProbe().scheduleCoverageSubtitle(policy: policy)
    }

    func scheduleCoveragePillHours(policy: OrgPayrollTimePolicy = .default) -> String {
        ScheduleCoverageFormat.hours(paidBookedHours(policy: policy)) + "h"
    }

    /// Sort position: the start of the script's interval for the stored slot and clocks.
    func minutesSortKey(policy: OrgPayrollTimePolicy = .default) -> Int {
        ManagerScheduleInterval.clashInterval(for: self, policy: policy)?.0 ?? 0
    }

    /// Rough “day units” for reports from paid hours (includes break toggle and OT).
    /// Weekly-report day units (`reportDayValue`): weighted paid hours over the standard day, capped at 1.5.
    func reportDayValue(policy: OrgPayrollTimePolicy = .default) -> Double {
        let paidHrs = paidBookedHours(policy: policy)
        // Nil only when the script did not run; bookings are then unreadable too.
        return CanonicalBusinessEngine.reportDayValue(totalPaidHours: paidHrs, standardPaidHours: CanonicalBusinessEngine.weekdayPaidHours(policy)) ?? 0
    }

    /// Start/end instants on the booking’s calendar day (for Calendar export and reminders).
    func calendarBlock(on day: Date, policy: OrgPayrollTimePolicy = .default) -> (start: Date, end: Date) {
        let cal = Calendar.current
        let startOfDay = cal.startOfDay(for: day)
        // The script's slotInterval with the stored slot and clocks.
        guard let interval = ManagerScheduleInterval.clashInterval(for: self, policy: policy) else {
            let end = cal.date(byAdding: .hour, value: timeSlot == .morning || timeSlot == .afternoon ? 4 : 8, to: startOfDay) ?? startOfDay
            return (startOfDay, end)
        }
        let start = cal.date(byAdding: .minute, value: interval.0, to: startOfDay) ?? startOfDay
        let end = cal.date(byAdding: .minute, value: interval.1, to: startOfDay) ?? startOfDay
        return (start, end)
    }

    /// Clock hours this booking occupies: the length of its `slotInterval` (the rulebook's interval for the stored slot
    /// and clock times, `CanonicalBusinessEngine.slotInterval`). 0 when the script did not answer — no Swift fallback.
    func totalBookedHours(policy: OrgPayrollTimePolicy = .default) -> Double {
        guard let iv = ManagerScheduleInterval.clashInterval(for: self, policy: policy) else { return 0 }
        return Double(max(0, iv.1 - iv.0)) / 60.0
    }

    func overtimeHoursBeyondPaidStandard(policy: OrgPayrollTimePolicy = .default) -> Double {
        payrollHoursResult(policy: policy).segments
            .filter { $0.kind == .outsideWindow || $0.kind == .allHoursMultiplier }
            .reduce(0) { $0 + $1.baseHours }
    }
}
