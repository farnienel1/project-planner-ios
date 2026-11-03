//
//  PayrollHoursEngine.swift
//  Project Planner
//
//  Single payroll calculation path for bookings across schedule, reports, timesheets, and invoicing.
//

import Foundation

struct PayrollHoursSegment: Equatable {
    enum Kind: Equatable {
        case standardWindow
        case outsideWindow
        case allHoursMultiplier
    }

    var kind: Kind
    var clockStart: String?
    var clockEnd: String?
    var baseHours: Double
    var multiplier: Double

    var paidHours: Double { baseHours * multiplier }

    var multiplierLabel: String {
        let m = multiplier
        if abs(m - m.rounded()) < 0.05 {
            return String(format: "%.0f", m)
        }
        return String(format: "%.1f", m)
    }
}

struct PayrollHoursResult: Equatable {
    var totalPaidHours: Double
    var segments: [PayrollHoursSegment]
    /// Multiplier for hours outside the standard window on this day (`payrollHoursResult.outsideMultiplier`).
    var outsideMultiplier: Double = 1
    /// RULEBOOK 1.19.0: the unpaid break taken off (`payrollHoursResult.unpaidBreakHours`), 0 when none.
    var unpaidBreakHours: Double = 0
    /// `payrollHoursResult.standardHours` / `outsideHours` (1.20.2 `bookingHoursLabel` reads them).
    var standardHours: Double = 0
    var outsideHours: Double = 0

    /// The paid hours of the multiplied segments (outside the window, or every hour at N×), as the pay rule prices
    /// them: Sunday 07:30–14:00 every hour ×2 → 13; a weekday 06:30–16:30 → 3 (2h × 1.5).
    var paidOvertimeHours: Double {
        segments.filter { $0.kind != .standardWindow }.reduce(0) { $0 + $1.paidHours }
    }

    /// RULEBOOK 1.20.2 §6/§10 `bookingHoursLabel`: the booking's hours as the pay rule gives them for its day (never
    /// the clock duration), with the multiplier sum — Saturday 07:30–14:00 on an 8h window → "8h"; Sunday every hour
    /// ×2 → "13h (6.5h × 2)"; a weekday with overtime → "10.25h (7.25h + 2h × 1.5)". Memoised in the wrapper.
    var paidHoursLabel: String {
        CanonicalBusinessEngine.bookingHoursLabel(RulebookBookingHoursInput(
            totalPaidHours: totalPaidHours,
            standardHours: standardHours,
            outsideHours: outsideHours,
            outsideMultiplier: outsideMultiplier
        ))
    }

    var breakdownSummary: String {
        guard !segments.isEmpty else { return ScheduleCoverageFormat.hours(totalPaidHours) + "h" }
        let parts = segments.map { segment -> String in
            switch segment.kind {
            case .standardWindow:
                if let s = segment.clockStart, let e = segment.clockEnd {
                    return "\(s)–\(e) → \(ScheduleCoverageFormat.hours(segment.paidHours))h"
                }
                return "\(ScheduleCoverageFormat.hours(segment.paidHours))h"
            case .outsideWindow, .allHoursMultiplier:
                let multSuffix = segment.multiplier == 1 ? "" : " × \(segment.multiplierLabel) (Multiplier)"
                if let s = segment.clockStart, let e = segment.clockEnd {
                    return "\(s)–\(e) → \(ScheduleCoverageFormat.hours(segment.baseHours))h\(multSuffix) = \(ScheduleCoverageFormat.hours(segment.paidHours))h"
                }
                return "\(ScheduleCoverageFormat.hours(segment.baseHours))h\(multSuffix) = \(ScheduleCoverageFormat.hours(segment.paidHours))h"
            }
        }
        return parts.joined(separator: " · ") + " · Total \(ScheduleCoverageFormat.hours(totalPaidHours))h"
    }
}

enum PayrollHoursEngine {
    /// Paid hours for a booking on `day` (its organisation-zone day), from the rulebook's `payrollHoursResult`. The web
    /// app runs the same function, so Daily Overview, the weekly report, timesheets and invoicing show the same hours on
    /// both. There is no Swift copy of the rule. `policy` is the policy in effect on `day`
    /// (`PayrollTimePolicyCatalog.policy(for:organization:)`, history first, RULEBOOK 1.19.0); the whole policy goes to
    /// the script, so each weekend day's own lunch break (`breakPaid`, `breakMinutes`, window) is priced as web prices it.
    /// The script's input for one booking on `day`. A mapping, not a rule.
    static func canonicalInput(booking: Booking, day: Date, policy: OrgPayrollTimePolicy) -> RulebookPayrollHoursInput {
        RulebookPayrollHoursInput(
            booking: CanonicalPayrollBooking(
                timeSlot: booking.timeSlot.rawValue,
                workStartTime: booking.workStartTime,
                workEndTime: booking.workEndTime,
                isBreakRemoved: booking.isBreakRemoved,
                otMultiplierOverride: booking.otMultiplierOverride
            ),
            dayKey: CanonicalBusinessEngine.dayKey(for: day),
            policy: policy
        )
    }

    /// `payrollHoursResult` as the script returns it (`standardHours`, `outsideHours`, `outsideMultiplier`).
    /// Timesheet and invoice pay lines read these fields, as web's collector does.
    static func canonicalResult(booking: Booking, day: Date, policy: OrgPayrollTimePolicy) -> CanonicalPayrollHours? {
        CanonicalBusinessEngine.payrollHoursResult(canonicalInput(booking: booking, day: day, policy: policy))?.hours
    }

    /// The whole `payrollHoursResult` answer, with `workedHours` and (1.19.0) `unpaidBreakHours`.
    static func rulebookResult(booking: Booking, day: Date, policy: OrgPayrollTimePolicy) -> RulebookPayrollHours? {
        CanonicalBusinessEngine.payrollHoursResult(canonicalInput(booking: booking, day: day, policy: policy))
    }

    /// `workedHoursSplit(payrollHoursResult)`: hours worked inside / outside the standard window,
    /// never multiplied. Daily Overview's Standard and OT figures (web buildDailyOverview.ts).
    static func workedHoursSplit(booking: Booking, day: Date, policy: OrgPayrollTimePolicy) -> CanonicalWorkedHoursSplit? {
        CanonicalBusinessEngine.workedHoursSplit(canonicalInput(booking: booking, day: day, policy: policy))
    }

    static func compute(booking: Booking, day: Date, policy: OrgPayrollTimePolicy) -> PayrollHoursResult {
        let input = canonicalInput(booking: booking, day: day, policy: policy)
        guard let answer = CanonicalBusinessEngine.payrollHoursResult(input) else {
            NSLog("PAYROLL_HOURS_UNAVAILABLE slot=%@ — canonical script did not answer", booking.timeSlot.rawValue)
            return PayrollHoursResult(totalPaidHours: 0, segments: [])
        }
        let result = answer.hours
        return PayrollHoursResult(
            totalPaidHours: result.totalPaidHours,
            segments: result.segments.map { segment in
                PayrollHoursSegment(
                    kind: segmentKind(segment.kind),
                    clockStart: segment.clockStart,
                    clockEnd: segment.clockEnd,
                    baseHours: segment.baseHours,
                    multiplier: segment.multiplier
                )
            },
            outsideMultiplier: result.outsideMultiplier,
            unpaidBreakHours: answer.unpaidBreakHours,
            standardHours: result.standardHours,
            outsideHours: result.outsideHours
        )
    }

    static func compute(choice: OperativeDayBookingChoice, day: Date, policy: OrgPayrollTimePolicy) -> PayrollHoursResult {
        let probe = choice.bookingProbe(
            operativeId: UUID(),
            projectId: UUID(),
            date: day,
            bookedBy: ""
        )
        return compute(booking: probe, day: day, policy: policy)
    }

    private static func segmentKind(_ raw: String) -> PayrollHoursSegment.Kind {
        switch raw {
        case "outsideWindow": return .outsideWindow
        case "allHoursMultiplier": return .allHoursMultiplier
        default: return .standardWindow
        }
    }
}

extension Booking {
    func payrollHoursResult(policy: OrgPayrollTimePolicy) -> PayrollHoursResult {
        PayrollHoursEngine.compute(booking: self, day: date, policy: policy)
    }

    /// `workedHoursSplit(payrollHoursResult)` for this booking on its own day.
    func workedHoursSplit(policy: OrgPayrollTimePolicy) -> CanonicalWorkedHoursSplit? {
        PayrollHoursEngine.workedHoursSplit(booking: self, day: date, policy: policy)
    }
}

extension ManagerSiteBooking {
    /// `workedHoursSplit(payrollHoursResult)` for this manager booking on its own day.
    func workedHoursSplit(policy: OrgPayrollTimePolicy) -> CanonicalWorkedHoursSplit? {
        PayrollHoursEngine.workedHoursSplit(booking: operativePayrollProbe(), day: date, policy: policy)
    }
}

extension ManagerScheduleInterval {
    static func formatMinutes(_ minutes: Int) -> String {
        let clamped = Swift.min(Swift.max(0, minutes), 24 * 60 - 1)
        let h = clamped / 60
        let m = clamped % 60
        return String(format: "%02d:%02d", h, m)
    }
}
