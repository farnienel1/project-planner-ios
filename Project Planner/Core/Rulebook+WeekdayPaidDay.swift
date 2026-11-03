//
//  Rulebook+WeekdayPaidDay.swift
//  Project Planner
//
//  Typed wrappers for rulebook 1.20.0 / 1.20.1 (docs/RULEBOOK.md §4.3, §5, §8, §9; web
//  `lib/canonical/organizationSettings.ts`, `engine.ts`):
//  - the Monday–Friday paid day is derived from start, finish and the unpaid break (`derivedWeekdayPaidHours`,
//    `weekdayPaidHours`, `withDerivedWeekdayPaidHours`, `weekdayPaidDayPreview`);
//  - annual-leave halves split the working day at its exact middle (`leaveHalfDayWindows`, `leaveHalfDayLabel`,
//    `leaveComparableInterval`).
//  Every answer comes from the packed script through `CanonicalBusinessEngine.callJSON`, memoised by its input so a
//  redraw never runs the script again. Swift maps values only; no rule is decided here.
//

import Foundation

/// `weekdayPaidDayPreview(policy)`: the live line under Monday–Friday in Working hours.
nonisolated struct RulebookWeekdayPaidDayPreview: Hashable, Sendable {
    let start: String
    let end: String
    let dayMinutes: Int
    let breakMinutes: Int
    let breakPaid: Bool
    let paidHours: Double
    /// "06:30–14:30 = 8h − 45 min unpaid break = 7h15m".
    let line: String
}

/// `leaveHalfDayWindows(policy)`: the working day and its two leave halves, in minutes after midnight.
nonisolated struct RulebookLeaveHalfDayWindows: Hashable, Sendable {
    let day: CanonicalMinuteInterval
    let am: CanonicalMinuteInterval
    let pm: CanonicalMinuteInterval
}

extension CanonicalBusinessEngine {
    nonisolated private static let weekdayPaidHoursMemo = RulebookAnswerMemo<OrgPayrollTimePolicy, Double>(limit: 512)
    nonisolated private static let derivedPolicyMemo = RulebookAnswerMemo<OrgPayrollTimePolicy, OrgPayrollTimePolicy>(limit: 64)
    nonisolated private static let weekdayPreviewMemo = RulebookAnswerMemo<OrgPayrollTimePolicy, RulebookWeekdayPaidDayPreview>(limit: 64)
    nonisolated private static let leaveHalvesMemo = RulebookAnswerMemo<CanonicalStandardDayInput, RulebookLeaveHalfDayWindows>(limit: 256)
    nonisolated private static let leaveLabelMemo = RulebookAnswerMemo<String, String>(limit: 512)

    // MARK: - Weekday paid day (§4.3, §8)

    /// RULEBOOK 1.20.0 §4.3 `weekdayPaidHours(policy)`: the paid hours of a Monday–Friday full day — what FULL DAY pays,
    /// what a day rate is divided by, the weekly-report day unit, the unbooked day and Home. Derived from start, finish
    /// and the unpaid break when the policy is `paidHoursDerived`; a policy saved before 1.20.0 keeps its stored
    /// `standardPaidHours`. Pass the policy in effect on the day. The stored figure only when the script did not run.
    nonisolated static func weekdayPaidHours(_ policy: OrgPayrollTimePolicy) -> Double {
        weekdayPaidHoursMemo.value(for: policy) {
            guard let json = payrollPolicyJSON(policy) else { return nil }
            return (callJSON("weekdayPaidHours", arguments: [json]) as? NSNumber)?.doubleValue
        } ?? policy.standardPaidHours
    }

    /// RULEBOOK 1.20.0 §4.3 `withDerivedWeekdayPaidHours(policy)`: the policy a 1.20.0 working-hours save writes —
    /// `paidHoursDerived: true` and `standardPaidHours` = the derived day. Nil when the script did not answer.
    nonisolated static func withDerivedWeekdayPaidHours(_ policy: OrgPayrollTimePolicy) -> OrgPayrollTimePolicy? {
        derivedPolicyMemo.value(for: policy) {
            guard let json = payrollPolicyJSON(policy) else { return nil }
            return payrollPolicy(fromJSON: callJSON("withDerivedWeekdayPaidHours", arguments: [json]))
        }
    }

    /// RULEBOOK 1.20.0 §4.3: the save check of a Working hours draft — `validatePayrollTimePolicy(withDerivedWeekdayPaidHours(draft))`
    /// ("The working day must give between 1 and 12 paid hours (finish − start − unpaid break)."). Nil when it can be saved.
    nonisolated static func validateDerivedPayrollTimePolicy(_ policy: OrgPayrollTimePolicy) -> String? {
        guard let derived = withDerivedWeekdayPaidHours(policy) else { return "Could not check these working hours." }
        return validatePayrollTimePolicy(derived)
    }

    /// RULEBOOK 1.20.0 §4.3 `weekdayPaidDayPreview(policy)`. Nil when the script did not answer.
    nonisolated static func weekdayPaidDayPreview(_ policy: OrgPayrollTimePolicy) -> RulebookWeekdayPaidDayPreview? {
        weekdayPreviewMemo.value(for: policy) {
            guard let json = payrollPolicyJSON(policy),
                  let row = callJSON("weekdayPaidDayPreview", arguments: [json]) as? [String: Any],
                  let line = row["line"] as? String else { return nil }
            func number(_ value: Any?) -> Double { (value as? NSNumber)?.doubleValue ?? 0 }
            return RulebookWeekdayPaidDayPreview(
                start: row["start"] as? String ?? policy.standardDayStart,
                end: row["end"] as? String ?? policy.standardDayEnd,
                dayMinutes: Int(number(row["dayMinutes"])),
                breakMinutes: Int(number(row["breakMinutes"])),
                breakPaid: (row["breakPaid"] as? Bool) ?? policy.breakPaid,
                paidHours: number(row["paidHours"]),
                line: line
            )
        }
    }

    // MARK: - Leave halves (§9)

    /// RULEBOOK 1.20.0 §9 `leaveHalfDayWindows(policy)`: the exact middle of the working day, ignoring the break
    /// (06:30–14:30 → AM 06:30–10:30, PM 10:30–14:30). For annual leave only; stored AM / PM bookings keep
    /// `halfDayWindows`. Nil when the script did not answer.
    nonisolated static func leaveHalfDayWindows(_ input: CanonicalStandardDayInput) -> RulebookLeaveHalfDayWindows? {
        leaveHalvesMemo.value(for: input) {
            guard let row = callJSON("leaveHalfDayWindows", arguments: [standardDayArgument(input)]) as? [String: Any],
                  let day = minuteInterval(row["day"]),
                  let am = minuteInterval(row["am"]),
                  let pm = minuteInterval(row["pm"]) else { return nil }
            return RulebookLeaveHalfDayWindows(day: day, am: am, pm: pm)
        }
    }

    /// `leaveHalfDayWindows` for the weekday policy in effect on the day.
    nonisolated static func leaveHalfDayWindows(policy: OrgPayrollTimePolicy) -> RulebookLeaveHalfDayWindows? {
        leaveHalfDayWindows(CanonicalStandardDayInput(policy: policy))
    }

    /// RULEBOOK 1.20.0 §9 `leaveHalfDayLabel(timeSlot, policy)`: "Full day", "AM 06:30–10:30", "PM 10:30–14:30".
    /// Nil when the script did not answer.
    nonisolated static func leaveHalfDayLabel(timeSlot: String, policy: OrgPayrollTimePolicy) -> String? {
        let input = CanonicalStandardDayInput(policy: policy)
        let key = "\(timeSlot)|\(input.standardDayStart ?? "")|\(input.standardDayEnd ?? "")"
        return leaveLabelMemo.value(for: key) {
            callJSON("leaveHalfDayLabel", arguments: [timeSlot, standardDayArgument(input)]) as? String
        }
    }

    /// The clock range of a leave slot ("06:30–10:30"; the whole day for full-day leave), from `leaveHalfDayWindows`.
    nonisolated static func leaveSlotClockRange(timeSlot: String, policy: OrgPayrollTimePolicy) -> String? {
        guard let halves = leaveHalfDayWindows(policy: policy) else { return nil }
        // `timeSlot` is a leave slot the script already normalised (`FULL DAY` / `AM` / `PM`, `normalizeHolidayTimeSlot`).
        let slot = timeSlot.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        let half = slot == "AM" ? halves.am : slot == "PM" ? halves.pm : halves.day
        return "\(clockText(half.start))–\(clockText(half.end))"
    }

    /// `HH:mm` of minutes after midnight (a display mapping of the script's minutes).
    nonisolated private static func clockText(_ minutes: Int) -> String {
        String(format: "%02d:%02d", (minutes / 60) % 24, minutes % 60)
    }

    nonisolated private static func standardDayArgument(_ input: CanonicalStandardDayInput) -> [String: Any] {
        var out: [String: Any] = [:]
        if let value = input.standardDayStart { out["standardDayStart"] = value }
        if let value = input.standardDayEnd { out["standardDayEnd"] = value }
        if let value = input.breakWindowStart { out["breakWindowStart"] = value }
        if let value = input.breakWindowEnd { out["breakWindowEnd"] = value }
        return out
    }

    nonisolated private static func minuteInterval(_ value: Any?) -> CanonicalMinuteInterval? {
        guard let map = value as? [String: Any],
              let start = (map["start"] as? NSNumber)?.intValue,
              let end = (map["end"] as? NSNumber)?.intValue else { return nil }
        return CanonicalMinuteInterval(start: start, end: end)
    }
}
