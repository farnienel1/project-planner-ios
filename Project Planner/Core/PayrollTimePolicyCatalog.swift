//
//  PayrollTimePolicyCatalog.swift
//  Project Planner
//
//  Date-aware payroll policy resolution and scheduled working-hours changes.
//

import Foundation

/// Future working-hours change queued on the organisation document.
struct OrgPayrollTimePolicyScheduledChange: Codable, Hashable {
    var policy: OrgPayrollTimePolicy
    /// Start of calendar day (local) when `policy` becomes live.
    var effectiveFrom: Date

    func asFirestoreDictionary() -> [String: Any] {
        [
            "policy": policy.asFirestoreDictionary(),
            "effectiveFrom": PayrollTimePolicyCatalog.dayKey(effectiveFrom),
        ]
    }

    static func fromFirestore(_ data: [String: Any]) -> OrgPayrollTimePolicyScheduledChange? {
        guard let policyDict = data["policy"] as? [String: Any] else { return nil }
        let policy = OrgPayrollTimePolicy.fromFirestore(policyDict)
        let day: Date = {
            if let s = data["effectiveFrom"] as? String, let d = PayrollTimePolicyCatalog.date(fromDayKey: s) {
                return d
            }
            if let ts = data["effectiveFrom"] as? Timestamp {
                return Calendar.current.startOfDay(for: ts.dateValue())
            }
            return Calendar.current.startOfDay(for: Date())
        }()
        return OrgPayrollTimePolicyScheduledChange(policy: policy, effectiveFrom: day)
    }
}

enum PayrollTimePolicyCatalog {
    /// Visual standard window for schedule/timesheet timeline bars on a given day.
    struct DayTimelinePolicy: Equatable {
        enum DayKind: Equatable {
            case weekday
            case saturday
            case sunday
        }

        let dayKind: DayKind
        /// Blue “standard” band; nil when every hour is paid at the multiplier.
        let standardWindowStart: String?
        let standardWindowEnd: String?
        let allHoursAtMultiplier: Bool
        let outsideMultiplier: Double

        var standardWindowStartMinutes: Int? {
            guard let s = standardWindowStart else { return nil }
            return ManagerScheduleInterval.parseMinutes(s)
        }

        var standardWindowEndMinutes: Int? {
            guard let e = standardWindowEnd else { return nil }
            return ManagerScheduleInterval.parseMinutes(e)
        }
    }

    static func dayKey(_ date: Date) -> String {
        let f = DateFormatter()
        f.calendar = Calendar.current
        f.locale = Locale(identifier: "en_GB")
        f.timeZone = TimeZone.current
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: Calendar.current.startOfDay(for: date))
    }

    static func date(fromDayKey key: String) -> Date? {
        let f = DateFormatter()
        f.calendar = Calendar.current
        f.locale = Locale(identifier: "en_GB")
        f.timeZone = TimeZone.current
        f.dateFormat = "yyyy-MM-dd"
        return f.date(from: key.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// Promotes a due scheduled change into live + prior policy on the org document fields.
    static func appliedPolicyState(
        current: OrgPayrollTimePolicy,
        prior: OrgPayrollTimePolicy?,
        effectiveFrom: Date,
        scheduled: OrgPayrollTimePolicyScheduledChange?
    ) -> (current: OrgPayrollTimePolicy, prior: OrgPayrollTimePolicy?, effectiveFrom: Date, scheduled: OrgPayrollTimePolicyScheduledChange?) {
        guard let scheduled else {
            return (current, prior, Calendar.current.startOfDay(for: effectiveFrom), nil)
        }
        let today = Calendar.current.startOfDay(for: Date())
        guard Calendar.current.startOfDay(for: scheduled.effectiveFrom) <= today else {
            return (current, prior, Calendar.current.startOfDay(for: effectiveFrom), scheduled)
        }
        let newPrior = current
        return (scheduled.policy, newPrior, scheduled.effectiveFrom, nil)
    }

    /// Policy that applies to bookings / timesheets on `day`.
    static func policy(for day: Date, organization: Organization?) -> OrgPayrollTimePolicy {
        guard let org = organization else { return .default }
        let cal = Calendar.current
        let target = cal.startOfDay(for: day)
        let effective = cal.startOfDay(for: org.payrollTimePolicyEffectiveFrom ?? .distantPast)
        if target >= effective {
            return org.settings.payrollTimePolicy
        }
        return org.payrollTimePolicyPrior ?? org.settings.payrollTimePolicy
    }

    static func policy(for day: Date, firebaseBackend: FirebaseBackend) -> OrgPayrollTimePolicy {
        policy(for: day, organization: firebaseBackend.currentOrganization)
    }

    static func resolvedSundaySettings(from policy: OrgPayrollTimePolicy) -> OrgWeekendDayPayrollSettings {
        if policy.sundaySameAsSaturday {
            return policy.saturday
        }
        return policy.sunday
    }

    static func weekendSettings(for day: Date, policy: OrgPayrollTimePolicy) -> OrgWeekendDayPayrollSettings {
        let wd = Calendar.current.component(.weekday, from: day)
        if wd == 7 { return policy.saturday }
        return resolvedSundaySettings(from: policy)
    }

    static func isWeekend(_ day: Date, calendar: Calendar = .current) -> Bool {
        let wd = calendar.component(.weekday, from: day)
        return wd == 1 || wd == 7
    }

    static func isWeekday(_ day: Date, calendar: Calendar = .current) -> Bool {
        !isWeekend(day, calendar: calendar)
    }

    /// True when Saturday and Sunday org rules match (or Sunday mirrors Saturday).
    static func saturdayAndSundayMatch(in policy: OrgPayrollTimePolicy) -> Bool {
        if policy.sundaySameAsSaturday { return true }
        return policy.saturday.equivalentForBatchBooking(policy.sunday, fallbackCountsAs: policy.standardPaidHours)
    }

    static func timelinePolicy(for day: Date, policy: OrgPayrollTimePolicy) -> DayTimelinePolicy {
        let wd = Calendar.current.component(.weekday, from: day)
        if wd >= 2 && wd <= 6 {
            return DayTimelinePolicy(
                dayKind: .weekday,
                standardWindowStart: policy.standardDayStart,
                standardWindowEnd: policy.standardDayEnd,
                allHoursAtMultiplier: false,
                outsideMultiplier: policy.weekdayOutsideStandardMultiplier
            )
        }
        let weekend = weekendSettings(for: day, policy: policy)
        let kind: DayTimelinePolicy.DayKind = wd == 7 ? .saturday : .sunday
        if weekend.allHoursAtMultiplierMode {
            return DayTimelinePolicy(
                dayKind: kind,
                standardWindowStart: nil,
                standardWindowEnd: nil,
                allHoursAtMultiplier: true,
                outsideMultiplier: weekend.allHoursMultiplier
            )
        }
        return DayTimelinePolicy(
            dayKind: kind,
            standardWindowStart: weekend.customStandardStart ?? policy.standardDayStart,
            standardWindowEnd: weekend.customStandardEnd ?? "13:00",
            allHoursAtMultiplier: false,
            outsideMultiplier: weekend.outsideStandardWindowMultiplier
        )
    }

    /// Multiplier applied to outside-window / all-hours segments for a booking on its calendar day.
    static func effectiveMultiplier(for booking: Booking, policy: OrgPayrollTimePolicy) -> Double {
        if let override = booking.otMultiplierOverride, override > 0 { return override }
        let result = PayrollHoursEngine.compute(booking: booking, day: booking.date, policy: policy)
        if let seg = result.segments.first(where: { $0.kind == .outsideWindow || $0.kind == .allHoursMultiplier }) {
            return seg.multiplier
        }
        return timelinePolicy(for: booking.date, policy: policy).outsideMultiplier
    }

    /// Multiplier applied to outside-window / all-hours segments for a manager booking on its calendar day.
    static func effectiveMultiplier(for booking: ManagerSiteBooking, policy: OrgPayrollTimePolicy) -> Double {
        let result = booking.payrollHoursResult(policy: policy)
        if let seg = result.segments.first(where: { $0.kind == .outsideWindow || $0.kind == .allHoursMultiplier }) {
            return seg.multiplier
        }
        return timelinePolicy(for: booking.date, policy: policy).outsideMultiplier
    }

    static func defaultWeekendBookingChoice(policy: OrgPayrollTimePolicy, day: Date) -> OperativeDayBookingChoice {
        let weekend = weekendSettings(for: day, policy: policy)
        if weekend.allHoursAtMultiplierMode {
            return OperativeDayBookingChoice(
                timeSlot: .customHours,
                workStartTime: policy.standardDayStart,
                workEndTime: policy.standardDayEnd,
                isBreakRemoved: true,
                otMultiplierOverride: weekend.allHoursMultiplier
            )
        }
        let start = weekend.customStandardStart ?? "07:30"
        let end = weekend.customStandardEnd ?? "13:00"
        return OperativeDayBookingChoice(
            timeSlot: .customHours,
            workStartTime: start,
            workEndTime: end,
            isBreakRemoved: true,
            otMultiplierOverride: nil
        )
    }
}

// Timestamp import for Firestore decode in same module as Firebase - use conditional
#if canImport(FirebaseFirestore)
import FirebaseFirestore
#endif
