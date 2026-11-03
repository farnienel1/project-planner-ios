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
    /// 1.20.2: `previous` is the saved policy (`validatePayrollTimePolicy(policy, previous)`), so a time stored off
    /// the 30-minute step is refused only once it is changed.
    nonisolated static func validateDerivedPayrollTimePolicy(_ policy: OrgPayrollTimePolicy, previous: OrgPayrollTimePolicy? = nil) -> String? {
        guard let derived = withDerivedWeekdayPaidHours(policy) else { return "Could not check these working hours." }
        return validatePayrollTimePolicy(derived, previous: previous)
    }

    // MARK: - Working-hours time step (1.20.2 §4.3)

    /// `PAYROLL_POLICY_TIME_STEP_MINUTES` (30): every working-hours clock time is on this step. Break length is not.
    nonisolated static var payrollPolicyTimeStepMinutes: Int {
        constant("PAYROLL_POLICY_TIME_STEP_MINUTES", as: Int.self) ?? 30
    }

    /// `PAYROLL_POLICY_TIME_STEP_MESSAGE`.
    nonisolated static var payrollPolicyTimeStepMessage: String {
        constant("PAYROLL_POLICY_TIME_STEP_MESSAGE", as: String.self) ?? "Working hours use 30-minute steps (e.g. 07:30)."
    }

    nonisolated private static let timeOnStepMemo = RulebookAnswerMemo<String, Bool>(limit: 256)

    /// `payrollPolicyTimeOnStep(value)`: whether a working-hours clock time is on the 30-minute step.
    nonisolated static func payrollPolicyTimeOnStep(_ value: String) -> Bool {
        timeOnStepMemo.value(for: value) {
            callJSON("payrollPolicyTimeOnStep", arguments: [value]) as? Bool
        } ?? true
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

// MARK: - Booking rows and booking requests (RULEBOOK 1.20.2 §2, §6, §10)

/// `BookingRequestIdentityInput`: one booking (stored or requested) as `bookingRequestIdentity` reads it.
nonisolated struct RulebookBookingRequest: Hashable, Sendable {
    var personId: String
    var dayKey: String
    var timeSlot: String
    /// Manager bookings: `project`, `small_work`, `office`, …; operative bookings leave it nil.
    var locationType: String? = nil
    /// The job id (operative `projectId`, manager `locationId`).
    var locationId: String? = nil
    var customLocationName: String? = nil
    var workStartTime: String? = nil
    var workEndTime: String? = nil
    var isBreakRemoved: Bool = false

    fileprivate var scriptArgument: [String: Any] {
        var out: [String: Any] = [
            "personId": personId, "dayKey": dayKey, "timeSlot": timeSlot, "isBreakRemoved": isBreakRemoved,
        ]
        if let locationType { out["locationType"] = locationType }
        if let locationId { out["locationId"] = locationId }
        if let customLocationName { out["customLocationName"] = customLocationName }
        if let workStartTime { out["workStartTime"] = workStartTime }
        if let workEndTime { out["workEndTime"] = workEndTime }
        return out
    }
}

/// The `payrollHoursResult` fields `bookingHoursLabel` reads. RULEBOOK 1.20.3: the segments (kind, base hours,
/// multiplier, unpaid break) let the script show clock hours at the multiplier and the break as plain hours; without
/// them it falls back to `outsideHours` ("6.25h × 2").
nonisolated struct RulebookBookingHoursInput: Hashable, Sendable {
    var totalPaidHours: Double
    var standardHours: Double
    var outsideHours: Double
    var outsideMultiplier: Double
    var segments: [RulebookMultipliedHoursInput.Segment] = []
}

extension CanonicalBusinessEngine {
    nonisolated private static let requestIdentityMemo = RulebookAnswerMemo<RulebookBookingRequest, String>(limit: 2048)
    nonisolated private static let hoursLabelMemo = RulebookAnswerMemo<RulebookBookingHoursInput, String>(limit: 2048)

    /// RULEBOOK 1.20.2 §2 `bookingRequestIdentity(input)`: same person, day, slot, place and — for custom hours — the
    /// same start, finish and break. Nil when the script did not answer.
    nonisolated static func bookingRequestIdentity(_ request: RulebookBookingRequest) -> String? {
        requestIdentityMemo.value(for: request) {
            callJSON("bookingRequestIdentity", arguments: [request.scriptArgument]) as? String
        }
    }

    /// RULEBOOK 1.20.2 §2 `isSameBookingRequest(a, b)` (compared through the memoised identities). A new booking is
    /// "already booked" only when this is true; a booking that only matches person|day|slot|place is never skipped.
    /// False when the script did not answer, so a save is never dropped on a missing answer.
    nonisolated static func isSameBookingRequest(_ a: RulebookBookingRequest, _ b: RulebookBookingRequest) -> Bool {
        guard let left = bookingRequestIdentity(a), let right = bookingRequestIdentity(b) else { return false }
        return left == right
    }

    /// RULEBOOK 1.20.2 §6/§10 `bookingHoursLabel(result)`: the pay rule's hours for a booking row, with the multiplier
    /// sum — "8h", "13h (6.5h × 2)", "11h (8h + 2h × 1.5)". Memoised by the four figures.
    nonisolated static func bookingHoursLabel(_ input: RulebookBookingHoursInput) -> String {
        hoursLabelMemo.value(for: input) {
            var argument: [String: Any] = [
                "totalPaidHours": input.totalPaidHours, "standardHours": input.standardHours,
                "outsideHours": input.outsideHours, "outsideMultiplier": input.outsideMultiplier,
            ]
            if !input.segments.isEmpty {
                argument["segments"] = input.segments.map {
                    ["kind": $0.kind, "baseHours": $0.baseHours, "multiplier": $0.multiplier, "unpaidBreakHours": $0.unpaidBreakHours]
                }
            }
            return (callJSON("bookingHoursLabel", arguments: [argument]) as? [String: Any])?["label"] as? String
        } ?? "\(input.totalPaidHours)h"
    }
}

extension ManagerSiteBooking {
    /// This manager booking as a `bookingRequestIdentity` input (RULEBOOK 1.20.2 §2). A mapping only.
    var bookingRequest: RulebookBookingRequest {
        RulebookBookingRequest(
            personId: userId,
            dayKey: OrganizationRulebookContext.dayKey(date),
            timeSlot: timeSlot.rawValue,
            locationType: locationType.rawValue,
            locationId: locationId?.uuidString,
            customLocationName: customLocationName,
            workStartTime: workStartTime,
            workEndTime: workEndTime,
            isBreakRemoved: isBreakRemoved
        )
    }
}

extension Booking {
    /// This operative booking as a `bookingRequestIdentity` input (RULEBOOK 1.20.2 §2). `personId` is the stored
    /// operative id the caller has already matched to the person (`samePersonIds`). A mapping only.
    func bookingRequest(personId: String) -> RulebookBookingRequest {
        RulebookBookingRequest(
            personId: personId,
            dayKey: OrganizationRulebookContext.dayKey(date),
            timeSlot: timeSlot.rawValue,
            locationId: projectId.uuidString,
            workStartTime: workStartTime,
            workEndTime: workEndTime,
            isBreakRemoved: isBreakRemoved
        )
    }
}

// MARK: - Lunch-break step (RULEBOOK 1.20.3 §4.3)

extension CanonicalBusinessEngine {
    /// `PAYROLL_BREAK_TIME_STEP_MINUTES` (15): lunch-break start, end and length are picked on this step.
    nonisolated static var payrollBreakTimeStepMinutes: Int {
        constant("PAYROLL_BREAK_TIME_STEP_MINUTES", as: Int.self) ?? 15
    }

    /// `PAYROLL_BREAK_TIME_STEP_MESSAGE`.
    nonisolated static var payrollBreakTimeStepMessage: String {
        constant("PAYROLL_BREAK_TIME_STEP_MESSAGE", as: String.self)
            ?? "Lunch break times and length use 15-minute steps (e.g. 10:45)."
    }

    nonisolated private static let breakTimeOnStepMemo = RulebookAnswerMemo<String, Bool>(limit: 256)
    nonisolated private static let breakMinutesOnStepMemo = RulebookAnswerMemo<Int, Bool>(limit: 256)

    /// `payrollBreakTimeOnStep(value)`: whether a lunch-break clock time is on the 15-minute step.
    nonisolated static func payrollBreakTimeOnStep(_ value: String) -> Bool {
        breakTimeOnStepMemo.value(for: value) {
            callJSON("payrollBreakTimeOnStep", arguments: [value]) as? Bool
        } ?? true
    }

    /// `payrollBreakMinutesOnStep(minutes)`: whether a break length is on the 15-minute step.
    nonisolated static func payrollBreakMinutesOnStep(_ minutes: Int) -> Bool {
        breakMinutesOnStepMemo.value(for: minutes) {
            callJSON("payrollBreakMinutesOnStep", arguments: [minutes]) as? Bool
        } ?? true
    }
}

// MARK: - Working hours weekend preview (RULEBOOK 1.20.3 §4.3)

/// `weekendDayPreview(draft, weekday, timeZone)`: the example hours, the summary and the priced rows.
nonisolated struct RulebookWeekendDayPreview: Hashable, Sendable {
    let dayKey: String
    let start: String
    let end: String
    /// "07:30–14:00 counts as 8h · Unpaid break 12:00–12:30, 30 min — 30 min taken off · 7.5h paid".
    let summary: String
    let rows: [RulebookBookingDayBreakdownRow]
}

extension CanonicalBusinessEngine {
    nonisolated private struct WeekendPreviewKey: Hashable, Sendable {
        let policy: OrgPayrollTimePolicy
        let weekday: String
        let timeZone: String
    }

    nonisolated private static let weekendPreviewMemo = RulebookAnswerMemo<WeekendPreviewKey, RulebookWeekendDayPreview>(limit: 64)

    /// RULEBOOK 1.20.3 `weekendDayPreview(policy, weekday, timeZone)` from the draft being edited (memoised by the
    /// whole draft), so Paid / Unpaid, length and times change it at once. `weekday` is `saturday` or `sunday`.
    nonisolated static func weekendDayPreview(
        policy: OrgPayrollTimePolicy,
        weekday: String,
        timeZone: String = OrganizationRulebookContext.timeZoneIdentifier
    ) -> RulebookWeekendDayPreview? {
        weekendPreviewMemo.value(for: WeekendPreviewKey(policy: policy, weekday: weekday, timeZone: timeZone)) {
            guard let policyJSON = payrollPolicyJSON(policy),
                  let row = callJSON("weekendDayPreview", arguments: [policyJSON, weekday, timeZone]) as? [String: Any],
                  let summary = row["summary"] as? String else { return nil }
            return RulebookWeekendDayPreview(
                dayKey: row["dayKey"] as? String ?? "",
                start: row["start"] as? String ?? "",
                end: row["end"] as? String ?? "",
                summary: summary,
                rows: (row["rows"] as? [Any] ?? []).compactMap(RulebookBookingDayBreakdownRow.init(json:))
            )
        }
    }
}

// MARK: - Hours at a multiplier (RULEBOOK 1.20.3 / 1.20.4 §8)

/// `payrollMultipliedHours(result)`: the clock hours at the multiplier, the multiplier, the unpaid break taken off
/// them as plain hours, the hours they pay and `multipliedHoursText` ("6.5h × 2 − 0.5h break = 12.5h").
nonisolated struct RulebookMultipliedHours: Hashable, Sendable {
    let clockHours: Double
    let multiplier: Double
    let breakHours: Double
    let paidHours: Double
    let text: String
}

/// The `payrollHoursResult` fields `payrollMultipliedHours` reads (segment kind, base hours, multiplier, break).
nonisolated struct RulebookMultipliedHoursInput: Hashable, Sendable {
    nonisolated struct Segment: Hashable, Sendable {
        let kind: String
        let baseHours: Double
        let multiplier: Double
        let unpaidBreakHours: Double
    }

    let segments: [Segment]
    let outsideMultiplier: Double
}

extension CanonicalBusinessEngine {
    nonisolated private static let multipliedMemo = RulebookAnswerMemo<RulebookMultipliedHoursInput, RulebookMultipliedHoursBox>(limit: 2048)
    nonisolated private static let multipliedTextMemo = RulebookAnswerMemo<String, String>(limit: 512)

    /// RULEBOOK 1.20.3 `payrollMultipliedHours(result)`. Nil when the booking has no hours at a multiplier (or the
    /// script did not answer). Display only: pay stays `outsideHours × outsideMultiplier`.
    nonisolated static func payrollMultipliedHours(_ input: RulebookMultipliedHoursInput) -> RulebookMultipliedHours? {
        multipliedMemo.value(for: input) {
            let argument: [String: Any] = [
                "outsideMultiplier": input.outsideMultiplier,
                "segments": input.segments.map {
                    ["kind": $0.kind, "baseHours": $0.baseHours, "multiplier": $0.multiplier, "unpaidBreakHours": $0.unpaidBreakHours]
                },
            ]
            let raw = callJSON("payrollMultipliedHours", arguments: [argument])
            if raw is NSNull { return RulebookMultipliedHoursBox(value: nil) }
            guard let row = raw as? [String: Any], let text = row["text"] as? String else { return nil }
            func number(_ key: String) -> Double { (row[key] as? NSNumber)?.doubleValue ?? 0 }
            return RulebookMultipliedHoursBox(value: RulebookMultipliedHours(
                clockHours: number("clockHours"), multiplier: number("multiplier"), breakHours: number("breakHours"),
                paidHours: number("paidHours"), text: text
            ))
        }?.value
    }

    /// RULEBOOK 1.20.4 `multipliedHoursText({ clockHours, multiplier, breakHours })`: "6.5h × 2 − 0.5h break = 12.5h",
    /// or "6.5h × 2 = 13h" with no break — for figures summed over several lines.
    nonisolated static func multipliedHoursText(clockHours: Double, multiplier: Double, breakHours: Double) -> String {
        let key = "\(clockHours)|\(multiplier)|\(breakHours)"
        return multipliedTextMemo.value(for: key) {
            callJSON(
                "multipliedHoursText",
                arguments: [["clockHours": clockHours, "multiplier": multiplier, "breakHours": breakHours]]
            ) as? String
        } ?? "\(clockHours)h × \(multiplier)"
    }

    /// RULEBOOK 1.20.4 `parseMultipliedHoursText(text)`: a signed line's stored "6.5h × 2 − 0.5h break = 12.5h" (after
    /// an optional "OT "), read back so it shows like a live line. Nil for any other text (older sheets).
    nonisolated static func parseMultipliedHoursText(_ text: String) -> (clockHours: Double, multiplier: Double, breakHours: Double)? {
        let box = parsedTextMemo.value(for: text) {
            guard let row = callJSON("parseMultipliedHoursText", arguments: [text]) as? [String: Any] else {
                return ParsedMultipliedTextBox(value: nil)
            }
            func number(_ key: String) -> Double { (row[key] as? NSNumber)?.doubleValue ?? 0 }
            return ParsedMultipliedTextBox(value: [number("clockHours"), number("multiplier"), number("breakHours")])
        }
        guard let values = box?.value, values.count == 3 else { return nil }
        return (values[0], values[1], values[2])
    }

    nonisolated private struct ParsedMultipliedTextBox: Sendable {
        let value: [Double]?
    }

    nonisolated private static let parsedTextMemo = RulebookAnswerMemo<String, ParsedMultipliedTextBox>(limit: 1024)

    /// RULEBOOK 1.20.4: the hours a pay line shows — for an overtime line whose text is `multipliedHoursText` (live or
    /// signed, read back with `parseMultipliedHoursText`), that text; otherwise the line's hours ("7.25h").
    nonisolated static func payLineHoursText(details: String, paidHours: Double, isOvertimeLine: Bool) -> String {
        if isOvertimeLine, let parsed = parseMultipliedHoursText(details) {
            return multipliedHoursText(clockHours: parsed.clockHours, multiplier: parsed.multiplier, breakHours: parsed.breakHours)
        }
        let rounded = (paidHours * 100).rounded() / 100
        var text = String(format: "%.2f", rounded)
        while text.hasSuffix("0") { text.removeLast() }
        if text.hasSuffix(".") { text.removeLast() }
        return "\(text)h"
    }
}

/// A memoised `payrollMultipliedHours` answer, including "no hours at a multiplier".
nonisolated struct RulebookMultipliedHoursBox: Hashable, Sendable {
    let value: RulebookMultipliedHours?
}
