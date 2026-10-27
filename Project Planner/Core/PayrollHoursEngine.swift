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
    /// Paid hours for a booking on `day` (its London calendar day), from the rulebook's
    /// `payrollHoursResult`. The web app runs the same function, so Daily Overview, the weekly report,
    /// timesheets and invoicing show the same hours on both. There is no Swift copy of the rule.
    static func compute(booking: Booking, day: Date, policy: OrgPayrollTimePolicy) -> PayrollHoursResult {
        let input = CanonicalPayrollHoursInput(
            booking: CanonicalPayrollBooking(
                timeSlot: booking.timeSlot.rawValue,
                workStartTime: booking.workStartTime,
                workEndTime: booking.workEndTime,
                isBreakRemoved: booking.isBreakRemoved,
                otMultiplierOverride: booking.otMultiplierOverride
            ),
            dayKey: CanonicalBusinessEngine.dayKey(for: day),
            policy: canonicalPolicy(policy)
        )
        guard let result = CanonicalBusinessEngine.payrollHoursResult(input) else {
            NSLog("PAYROLL_HOURS_UNAVAILABLE slot=%@ — canonical script did not answer", booking.timeSlot.rawValue)
            return PayrollHoursResult(totalPaidHours: 0, segments: [])
        }
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
            outsideMultiplier: result.outsideMultiplier
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

    /// The organisation policy in the script's field names. A mapping, not a rule.
    static func canonicalPolicy(_ policy: OrgPayrollTimePolicy) -> CanonicalPayrollPolicy {
        func weekend(_ day: OrgWeekendDayPayrollSettings, sameAsSaturday: Bool? = nil) -> CanonicalWeekendPayroll {
            CanonicalWeekendPayroll(
                allHoursAtMultiplierMode: day.allHoursAtMultiplierMode,
                allHoursMultiplier: day.allHoursMultiplier,
                definedWindowStart: day.customStandardStart,
                definedWindowEnd: day.customStandardEnd,
                countsAsStandardHours: day.countsAsHours,
                outsideWindowMultiplier: day.outsideStandardWindowMultiplier,
                sameAsSaturday: sameAsSaturday
            )
        }
        return CanonicalPayrollPolicy(
            standardDayStart: policy.standardDayStart,
            standardDayEnd: policy.standardDayEnd,
            unpaidBreakMinutes: policy.unpaidBreakMinutes,
            standardPaidHours: policy.standardPaidHours,
            breakWindowStart: policy.breakWindowStart,
            breakWindowEnd: policy.breakWindowEnd,
            weekdayOutsideStandardMultiplier: policy.weekdayOutsideStandardMultiplier,
            saturday: weekend(policy.saturday),
            sunday: weekend(policy.sunday, sameAsSaturday: policy.sundaySameAsSaturday),
            breakPaid: policy.breakPaid
        )
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
}

extension ManagerScheduleInterval {
    static func formatMinutes(_ minutes: Int) -> String {
        let clamped = Swift.min(Swift.max(0, minutes), 24 * 60 - 1)
        let h = clamped / 60
        let m = clamped % 60
        return String(format: "%02d:%02d", h, m)
    }
}
