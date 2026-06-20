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
    static func compute(booking: Booking, day: Date, policy: OrgPayrollTimePolicy) -> PayrollHoursResult {
        let cal = Calendar.current
        let weekday = cal.component(.weekday, from: day)
        if weekday == 7 {
            return computeWeekend(booking: booking, weekend: policy.saturday, policy: policy, dayLabel: "Saturday")
        }
        if weekday == 1 {
            let sun = PayrollTimePolicyCatalog.resolvedSundaySettings(from: policy)
            return computeWeekend(booking: booking, weekend: sun, policy: policy, dayLabel: "Sunday")
        }
        return computeWeekday(booking: booking, policy: policy)
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

    // MARK: - Weekday

    private static func computeWeekday(booking: Booking, policy: OrgPayrollTimePolicy) -> PayrollHoursResult {
        guard let interval = OperativeBookingInterval.clashInterval(for: booking, policy: policy) else {
            return legacySlotResult(booking: booking, policy: policy)
        }
        let ds = ManagerScheduleInterval.parseMinutes(policy.standardDayStart) ?? 0
        let de = ManagerScheduleInterval.parseMinutes(policy.standardDayEnd) ?? 0
        guard de > ds else {
            return simpleWallResult(booking: booking, policy: policy, multiplier: booking.effectiveOutsideMultiplier(policy: policy, weekend: nil))
        }

        let sm = interval.0
        let em = interval.1
        let outsideMult = booking.effectiveOutsideMultiplier(policy: policy, weekend: nil)

        var segments: [PayrollHoursSegment] = []
        var total = 0.0

        let insideStart = max(sm, ds)
        let insideEnd = min(em, de)
        if insideEnd > insideStart {
            var insideHours = Double(insideEnd - insideStart) / 60.0
            if !policy.breakPaid, !booking.isBreakRemoved {
                insideHours = max(0, insideHours - breakDeductionMinutes(booking: booking, policy: policy, interval: interval) / 60.0)
            }
            if insideHours > 0.001 {
                segments.append(PayrollHoursSegment(
                    kind: .standardWindow,
                    clockStart: ManagerScheduleInterval.formatMinutes(insideStart),
                    clockEnd: ManagerScheduleInterval.formatMinutes(insideEnd),
                    baseHours: insideHours,
                    multiplier: 1
                ))
                total += insideHours
            }
        }

        if sm < ds {
            let hours = Double(min(em, ds) - sm) / 60.0
            if hours > 0.001 {
                segments.append(PayrollHoursSegment(
                    kind: .outsideWindow,
                    clockStart: ManagerScheduleInterval.formatMinutes(sm),
                    clockEnd: ManagerScheduleInterval.formatMinutes(min(em, ds)),
                    baseHours: hours,
                    multiplier: outsideMult
                ))
                total += hours * outsideMult
            }
        }
        if em > de {
            let hours = Double(em - max(sm, de)) / 60.0
            if hours > 0.001 {
                segments.append(PayrollHoursSegment(
                    kind: .outsideWindow,
                    clockStart: ManagerScheduleInterval.formatMinutes(max(sm, de)),
                    clockEnd: ManagerScheduleInterval.formatMinutes(em),
                    baseHours: hours,
                    multiplier: outsideMult
                ))
                total += hours * outsideMult
            }
        }

        if segments.isEmpty {
            return legacySlotResult(booking: booking, policy: policy)
        }
        return PayrollHoursResult(totalPaidHours: total, segments: segments)
    }

    // MARK: - Weekend

    private static func computeWeekend(
        booking: Booking,
        weekend: OrgWeekendDayPayrollSettings,
        policy: OrgPayrollTimePolicy,
        dayLabel: String
    ) -> PayrollHoursResult {
        guard let interval = OperativeBookingInterval.clashInterval(for: booking, policy: policy) else {
            return legacySlotResult(booking: booking, policy: policy)
        }

        if weekend.allHoursAtMultiplierMode {
            let wall = Double(interval.1 - interval.0) / 60.0
            let mult = booking.effectiveOutsideMultiplier(policy: policy, weekend: weekend)
            let segment = PayrollHoursSegment(
                kind: .allHoursMultiplier,
                clockStart: ManagerScheduleInterval.formatMinutes(interval.0),
                clockEnd: ManagerScheduleInterval.formatMinutes(interval.1),
                baseHours: wall,
                multiplier: mult
            )
            return PayrollHoursResult(totalPaidHours: wall * mult, segments: [segment])
        }

        let ws = ManagerScheduleInterval.parseMinutes(weekend.customStandardStart ?? policy.standardDayStart) ?? 0
        let we = ManagerScheduleInterval.parseMinutes(weekend.customStandardEnd ?? "13:00") ?? 0
        guard we > ws else {
            return simpleWallResult(booking: booking, policy: policy, multiplier: booking.effectiveOutsideMultiplier(policy: policy, weekend: weekend))
        }

        let sm = interval.0
        let em = interval.1
        let countsAs = weekend.resolvedCountsAsHours(fallback: policy.standardPaidHours)
        let outsideMult = booking.effectiveOutsideMultiplier(policy: policy, weekend: weekend)

        var segments: [PayrollHoursSegment] = []
        var total = 0.0

        let overlapStart = max(sm, ws)
        let overlapEnd = min(em, we)
        if overlapEnd > overlapStart {
            let overlapMinutes = overlapEnd - overlapStart
            let credited: Double
            if overlapStart <= ws && overlapEnd >= we {
                credited = countsAs
            } else {
                credited = countsAs * (Double(overlapMinutes) / Double(we - ws))
            }
            segments.append(PayrollHoursSegment(
                kind: .standardWindow,
                clockStart: ManagerScheduleInterval.formatMinutes(overlapStart),
                clockEnd: ManagerScheduleInterval.formatMinutes(overlapEnd),
                baseHours: credited,
                multiplier: 1
            ))
            total += credited
        }

        if sm < ws {
            let hours = Double(min(em, ws) - sm) / 60.0
            if hours > 0.001 {
                segments.append(PayrollHoursSegment(
                    kind: .outsideWindow,
                    clockStart: ManagerScheduleInterval.formatMinutes(sm),
                    clockEnd: ManagerScheduleInterval.formatMinutes(min(em, ws)),
                    baseHours: hours,
                    multiplier: outsideMult
                ))
                total += hours * outsideMult
            }
        }
        if em > we {
            let hours = Double(em - max(sm, we)) / 60.0
            if hours > 0.001 {
                segments.append(PayrollHoursSegment(
                    kind: .outsideWindow,
                    clockStart: ManagerScheduleInterval.formatMinutes(max(sm, we)),
                    clockEnd: ManagerScheduleInterval.formatMinutes(em),
                    baseHours: hours,
                    multiplier: outsideMult
                ))
                total += hours * outsideMult
            }
        }

        if segments.isEmpty {
            return legacySlotResult(booking: booking, policy: policy)
        }
        return PayrollHoursResult(totalPaidHours: total, segments: segments)
    }

    // MARK: - Helpers

    private static func breakDeductionMinutes(booking: Booking, policy: OrgPayrollTimePolicy, interval: (Int, Int)) -> Double {
        guard let bws = ManagerScheduleInterval.parseMinutes(policy.breakWindowStart),
              let bwe = ManagerScheduleInterval.parseMinutes(policy.breakWindowEnd),
              bwe > bws else { return 0 }
        let overlapStart = max(interval.0, bws)
        let overlapEnd = min(interval.1, bwe)
        guard overlapEnd > overlapStart else { return 0 }
        return Double(policy.unpaidBreakMinutes)
    }

    private static func simpleWallResult(booking: Booking, policy: OrgPayrollTimePolicy, multiplier: Double) -> PayrollHoursResult {
        let wall = booking.totalBookedHours(policy: policy)
        let segment = PayrollHoursSegment(
            kind: .allHoursMultiplier,
            clockStart: booking.workStartTime,
            clockEnd: booking.workEndTime,
            baseHours: wall,
            multiplier: multiplier
        )
        return PayrollHoursResult(totalPaidHours: wall * multiplier, segments: [segment])
    }

    private static func legacySlotResult(booking: Booking, policy: OrgPayrollTimePolicy) -> PayrollHoursResult {
        let paid: Double
        switch booking.timeSlot {
        case .fullDay, .customHours:
            paid = max(policy.standardPaidHours, 0)
        case .morning, .afternoon:
            paid = max(policy.standardPaidHours, 0) / 2
        case .evening:
            paid = 4
        case .overtime:
            paid = 2
        }
        let segment = PayrollHoursSegment(kind: .standardWindow, clockStart: nil, clockEnd: nil, baseHours: paid, multiplier: 1)
        return PayrollHoursResult(totalPaidHours: paid, segments: [segment])
    }
}

extension Booking {
    func effectiveOutsideMultiplier(policy: OrgPayrollTimePolicy, weekend: OrgWeekendDayPayrollSettings?) -> Double {
        if let override = otMultiplierOverride, override > 0 { return override }
        if let weekend {
            return weekend.allHoursAtMultiplierMode ? weekend.allHoursMultiplier : weekend.outsideStandardWindowMultiplier
        }
        return policy.weekdayOutsideStandardMultiplier
    }

    func payrollHoursResult(policy: OrgPayrollTimePolicy) -> PayrollHoursResult {
        PayrollHoursEngine.compute(booking: self, day: date, policy: policy)
    }
}

extension ManagerScheduleInterval {
    static func formatMinutes(_ minutes: Int) -> String {
        let h = minutes / 60
        let m = minutes % 60
        return String(format: "%02d:%02d", h, m)
    }
}
