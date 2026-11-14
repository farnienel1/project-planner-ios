//
//  Rulebook+BookingDayBreakdown.swift
//  Project Planner
//
//  Typed wrappers for the booking picker rules of rulebook 1.18.0 (docs/RULEBOOK.md §4.3; web
//  `lib/canonical/bookingSlots.ts`, glue `lib/scheduling/bookingSlotRules.ts`):
//  - `customHoursPrefillForDays`: the one pair of custom times a multi-day picker opens with, and the selection's kind
//    (weekday-only / weekend-only / a refused mix). A picker re-applies it only when the kind changes
//    (`CustomHoursKindTracker`, web `useCustomHoursPrefillOnKindChange`), so a manual edit survives adding a day.
//  - `weekendBookingBreakdown`: one row per selected day, each priced by `payrollHoursResult` under the rules in effect
//    on that day. Weekend booking screens show these rows instead of the standard-day summary.
//  Both are called with the organisation's policy STATE (`payrollTimePolicyTimeline` over the four stored fields), so
//  each day uses the working hours in effect on it. Swift maps inputs and shows results; nothing is calculated here.
//

import Foundation
import SwiftUI

/// `customHoursPrefillForDays` → `{ start, end, kind }`.
nonisolated struct RulebookCustomHoursPrefill: Equatable, Hashable, Sendable {
    nonisolated enum Kind: String, Sendable {
        case weekday
        case weekend
        /// The selection mixes weekdays and weekend days (refused by every picker); the times are not applied.
        case mixed = "none"
    }

    let start: String
    let end: String
    let kind: Kind

    init(start: String, end: String, kind: Kind) {
        self.start = start
        self.end = end
        self.kind = kind
    }

    init?(json: Any?) {
        guard let row = json as? [String: Any],
              let start = row["start"] as? String,
              let end = row["end"] as? String,
              let kind = (row["kind"] as? String).flatMap(Kind.init(rawValue:)) else { return nil }
        self.init(start: start, end: end, kind: kind)
    }
}

/// One `weekendBookingBreakdown` row (`BookingDayBreakdownRow`).
nonisolated struct RulebookBookingDayBreakdownRow: Equatable, Hashable, Sendable, Identifiable {
    var id: String { dayKey }
    let dayKey: String
    /// "Saturday", "Sunday", or the weekday's name.
    let weekdayLabel: String
    let start: String
    let end: String
    let workedHours: Double
    /// A set-window weekend day: the hours the worked part of the window counts as; else nil.
    let countsAsHours: Double?
    let standardHours: Double
    let overtimeHours: Double
    let multiplier: Double
    let paidHoursEquivalent: Double
    /// e.g. "Saturday 07:30–14:00 = 8h (counts as a full day)".
    let line: String
    /// RULEBOOK 1.19.0: the unpaid break taken off (`payrollHoursResult.unpaidBreakHours`), 0 when none.
    let unpaidBreakHours: Double
    /// RULEBOOK 1.19.0: the row in the Mon–Fri style (set hours / unpaid break / outside hours × rate / total).
    let lines: [RulebookBookingDayBreakdownLine]
    /// RULEBOOK 1.39.0 `explanation.rule`: the day's rule, e.g. "Saturday full day: 07:30–14:00 counts as 8h, hours
    /// outside it at 2×". Empty from a script older than 1.39.0.
    let explanationRule: String
    /// RULEBOOK 1.39.0 `explanation.steps`, e.g. ["Booked 07:30–10:30 = 3h of the 6.5h window → 8h × 3 ÷ 6.5 = 3.69h"].
    let explanationSteps: [String]

    init?(json: Any?) {
        guard let row = json as? [String: Any],
              let dayKey = row["dayKey"] as? String,
              let weekdayLabel = row["weekdayLabel"] as? String,
              let line = row["line"] as? String else { return nil }
        func number(_ key: String) -> Double { (row[key] as? NSNumber)?.doubleValue ?? 0 }
        self.dayKey = dayKey
        self.weekdayLabel = weekdayLabel
        self.start = row["start"] as? String ?? ""
        self.end = row["end"] as? String ?? ""
        self.workedHours = number("workedHours")
        self.countsAsHours = (row["countsAsHours"] as? NSNumber)?.doubleValue
        self.standardHours = number("standardHours")
        self.overtimeHours = number("overtimeHours")
        self.multiplier = number("multiplier")
        self.paidHoursEquivalent = number("paidHoursEquivalent")
        self.line = line
        self.unpaidBreakHours = number("unpaidBreakHours")
        self.lines = (row["lines"] as? [[String: Any]] ?? []).compactMap(RulebookBookingDayBreakdownLine.init(json:))
        let explanation = row["explanation"] as? [String: Any]
        self.explanationRule = explanation?["rule"] as? String ?? ""
        self.explanationSteps = explanation?["steps"] as? [String] ?? []
    }
}

/// RULEBOOK 1.39.0 §4.3 `bookingHoursExplanation` → `{ dayKey, weekdayLabel, kind, rule, steps, totalPaidHours, fullDayHours }`.
nonisolated struct RulebookBookingHoursExplanation: Equatable, Hashable, Sendable {
    let dayKey: String
    let weekdayLabel: String
    /// `weekday`, `weekendWindow` or `weekendAllHours`.
    let kind: String
    let rule: String
    let steps: [String]
    let totalPaidHours: Double
    let fullDayHours: Double?

    init?(json: Any?) {
        guard let row = json as? [String: Any],
              let dayKey = row["dayKey"] as? String,
              let weekdayLabel = row["weekdayLabel"] as? String,
              let rule = row["rule"] as? String else { return nil }
        self.dayKey = dayKey
        self.weekdayLabel = weekdayLabel
        self.kind = row["kind"] as? String ?? ""
        self.rule = rule
        self.steps = row["steps"] as? [String] ?? []
        self.totalPaidHours = (row["totalPaidHours"] as? NSNumber)?.doubleValue ?? 0
        self.fullDayHours = (row["fullDayHours"] as? NSNumber)?.doubleValue
    }
}

/// RULEBOOK 1.39.0 §4.3 `bookingShortfall` → `{ label, fullDayHours, missingHours, value }`, e.g. "Short of a full Saturday (8h)".
nonisolated struct RulebookBookingShortfall: Equatable, Hashable, Sendable {
    let label: String
    let fullDayHours: Double
    let missingHours: Double
    /// e.g. "4.31h".
    let value: String

    init?(json: Any?) {
        guard let row = json as? [String: Any],
              let label = row["label"] as? String,
              let value = row["value"] as? String else { return nil }
        self.label = label
        self.value = value
        self.fullDayHours = (row["fullDayHours"] as? NSNumber)?.doubleValue ?? 0
        self.missingHours = (row["missingHours"] as? NSNumber)?.doubleValue ?? 0
    }
}

/// One block of a booking's hours on screen: the figure (`line`, may be empty) and the words that explain it (`detail`:
/// the day's rule, then the steps). Text only; every word is the script's.
nonisolated struct RulebookBreakdownSection: Equatable, Hashable, Sendable {
    let line: String
    let detail: [String]
}

/// One `BookingDayBreakdownLine` (1.19.0): `kind` is `standard`, `break`, `outside` or `total`. Values only.
nonisolated struct RulebookBookingDayBreakdownLine: Equatable, Hashable, Sendable {
    let kind: String
    let label: String
    let value: String

    init?(json: [String: Any]) {
        guard let kind = json["kind"] as? String, let label = json["label"] as? String,
              let value = json["value"] as? String else { return nil }
        self.kind = kind
        self.label = label
        self.value = value
    }
}

/// Script answers for the 1.18.0 picker calls keyed by their exact input, so a redraw or a tap does not run the packed
/// script again. It stores what the script returned; it is not a second copy of the rule.
nonisolated private final class BookingPickerMemo<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var store: [BookingPickerMemoKey: Value] = [:]
    private let limit = 256

    func value(for key: BookingPickerMemoKey, compute: () -> Value?) -> Value? {
        lock.lock()
        if let hit = store[key] {
            lock.unlock()
            return hit
        }
        lock.unlock()
        guard let value = compute() else { return nil }
        lock.lock()
        if store.count >= limit { store.removeAll(keepingCapacity: true) }
        store[key] = value
        lock.unlock()
        return value
    }
}

nonisolated private struct BookingPickerMemoKey: Hashable, Sendable {
    /// The stored working-hours fields as sorted JSON (policy state), or nil for a single policy.
    let document: String?
    let policy: OrgPayrollTimePolicy?
    let dayKeys: [String]
    let start: String?
    let end: String?
    let isBreakRemoved: Bool
    let todayKey: String
    let timeZone: String
    /// RULEBOOK 1.43.0 §25: the booking's own overtime rate (nil = the organisation's), priced in the rows.
    var otMultiplierOverride: Double? = nil
}

extension CanonicalBusinessEngine {
    /// RULEBOOK 1.43.0 §25: a booking's own overtime rate as the script reads it — a positive number, else nil (the
    /// organisation's rate). A mapping only: `weekendBookingBreakdown` / `payrollHoursResult` decide what it prices.
    nonisolated static func bookingOwnRate(_ value: Double?) -> Double? {
        guard let value, value.isFinite, value > 0 else { return nil }
        return value
    }

    /// The script argument for an optional rate: the number, or JSON null.
    nonisolated static func bookingOwnRateArgument(_ value: Double?) -> Any {
        if let rate = bookingOwnRate(value) { return rate }
        return NSNull()
    }
}

extension CanonicalBusinessEngine {
    nonisolated private static let customHoursPrefillMemo = BookingPickerMemo<RulebookCustomHoursPrefill>()
    nonisolated private static let weekendBreakdownMemo = BookingPickerMemo<[RulebookBookingDayBreakdownRow]>()

    nonisolated private static func documentKey(_ document: [String: Any]) -> String? {
        guard JSONSerialization.isValidJSONObject(document),
              let data = try? JSONSerialization.data(withJSONObject: document, options: [.sortedKeys]) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// The organisation's policy state: `payrollTimePolicyTimeline(orgDocument, todayKey, timeZone)`.
    nonisolated private static func payrollPolicyState(
        policyDocument: [String: Any],
        todayKey: String,
        timeZone: String
    ) -> [String: Any]? {
        memoCallJSON("payrollTimePolicyTimeline", arguments: [policyDocument, todayKey, timeZone]) as? [String: Any]
    }

    // MARK: customHoursPrefillForDays (1.18.0 §4.3)

    /// RULEBOOK 1.18.0 §4.3 `customHoursPrefillForDays(policyState, dayKeys, timeZone)`: weekend-only → the first
    /// selected Saturday's set window (Sunday's when Saturday pays every hour at N×), else the standard day; weekday-only
    /// → the standard day in effect on the first selected day; a mix → kind `mixed` ("none"). `policyDocument` is the four stored
    /// working-hours fields, read into the policy state promoted to `todayKey`. Nil for no valid day or no answer.
    nonisolated static func customHoursPrefillForDays(
        policyDocument: [String: Any],
        dayKeys: [String],
        todayKey: String? = nil,
        timeZone: String = OrganizationRulebookContext.timeZoneIdentifier
    ) -> RulebookCustomHoursPrefill? {
        let today = todayKey ?? organizationDayKey(Date(), timeZoneIdentifier: timeZone)
        let compute: () -> RulebookCustomHoursPrefill? = {
            guard let state = payrollPolicyState(policyDocument: policyDocument, todayKey: today, timeZone: timeZone) else {
                return nil
            }
            return RulebookCustomHoursPrefill(json: callJSON("customHoursPrefillForDays", arguments: [state, dayKeys, timeZone]))
        }
        guard let document = documentKey(policyDocument) else { return compute() }
        let key = BookingPickerMemoKey(
            document: document, policy: nil, dayKeys: dayKeys, start: nil, end: nil,
            isBreakRemoved: false, todayKey: today, timeZone: timeZone
        )
        return customHoursPrefillMemo.value(for: key, compute: compute)
    }

    /// `customHoursPrefillForDays(policy, dayKeys, timeZone)` with one policy for every day.
    nonisolated static func customHoursPrefillForDays(
        policy: OrgPayrollTimePolicy,
        dayKeys: [String],
        timeZone: String = OrganizationRulebookContext.timeZoneIdentifier
    ) -> RulebookCustomHoursPrefill? {
        let key = BookingPickerMemoKey(
            document: nil, policy: policy, dayKeys: dayKeys, start: nil, end: nil,
            isBreakRemoved: false, todayKey: "", timeZone: timeZone
        )
        return customHoursPrefillMemo.value(for: key) {
            guard let policyJSON = payrollPolicyJSON(policy) else { return nil }
            return RulebookCustomHoursPrefill(json: callJSON("customHoursPrefillForDays", arguments: [policyJSON, dayKeys, timeZone]))
        }
    }

    /// `customHoursPrefillForDays` for the dates a picker has selected (web `customHoursPrefillForDates`): the open
    /// organisation's policy state when loaded, else `fallbackPolicy`.
    nonisolated static func customHoursPrefill(on dates: [Date], fallbackPolicy: OrgPayrollTimePolicy) -> RulebookCustomHoursPrefill? {
        let keys = dates.map { bookingDayKey($0) }
        guard !keys.isEmpty else { return nil }
        if let document = OrganizationRulebookContext.payrollPolicyDocument,
           let prefill = customHoursPrefillForDays(policyDocument: document, dayKeys: keys) {
            return prefill
        }
        return customHoursPrefillForDays(policy: fallbackPolicy, dayKeys: keys)
    }

    // MARK: weekendBookingBreakdown (1.18.0 §4.3)

    /// RULEBOOK 1.18.0 §4.3 `weekendBookingBreakdown(policyState, dayKeys, start, end, isBreakRemoved, timeZone)`: one
    /// row per selected day (de-duplicated, in date order), each from `payrollHoursResult` for that day under the rules
    /// in effect on it. Nil when the script did not answer.
    nonisolated static func weekendBookingBreakdown(
        policyDocument: [String: Any],
        dayKeys: [String],
        start: String,
        end: String,
        isBreakRemoved: Bool,
        todayKey: String? = nil,
        timeZone: String = OrganizationRulebookContext.timeZoneIdentifier,
        otMultiplierOverride: Double? = nil
    ) -> [RulebookBookingDayBreakdownRow]? {
        let today = todayKey ?? organizationDayKey(Date(), timeZoneIdentifier: timeZone)
        // RULEBOOK 1.43.0 §25: the booking's own overtime rate is the script's 7th argument (null = the organisation's).
        let rate = bookingOwnRate(otMultiplierOverride)
        let rateArgument = bookingOwnRateArgument(rate)
        let compute: () -> [RulebookBookingDayBreakdownRow]? = {
            guard let state = payrollPolicyState(policyDocument: policyDocument, todayKey: today, timeZone: timeZone),
                  let rows = callJSON(
                    "weekendBookingBreakdown",
                    arguments: [state, dayKeys, start, end, isBreakRemoved, timeZone, rateArgument]
                  ) as? [Any] else { return nil }
            return rows.compactMap(RulebookBookingDayBreakdownRow.init(json:))
        }
        guard let document = documentKey(policyDocument) else { return compute() }
        let key = BookingPickerMemoKey(
            document: document, policy: nil, dayKeys: dayKeys, start: start, end: end,
            isBreakRemoved: isBreakRemoved, todayKey: today, timeZone: timeZone, otMultiplierOverride: rate
        )
        return weekendBreakdownMemo.value(for: key, compute: compute)
    }

    /// `weekendBookingBreakdown(policy, …)` with one policy for every day. Nil when the script did not answer.
    nonisolated static func weekendBookingBreakdown(
        policy: OrgPayrollTimePolicy,
        dayKeys: [String],
        start: String,
        end: String,
        isBreakRemoved: Bool,
        timeZone: String = OrganizationRulebookContext.timeZoneIdentifier,
        otMultiplierOverride: Double? = nil
    ) -> [RulebookBookingDayBreakdownRow]? {
        let rate = bookingOwnRate(otMultiplierOverride)
        let rateArgument = bookingOwnRateArgument(rate)
        let key = BookingPickerMemoKey(
            document: nil, policy: policy, dayKeys: dayKeys, start: start, end: end,
            isBreakRemoved: isBreakRemoved, todayKey: "", timeZone: timeZone, otMultiplierOverride: rate
        )
        return weekendBreakdownMemo.value(for: key) {
            guard let policyJSON = payrollPolicyJSON(policy),
                  let rows = callJSON(
                    "weekendBookingBreakdown",
                    arguments: [policyJSON, dayKeys, start, end, isBreakRemoved, timeZone, rateArgument]
                  ) as? [Any] else { return nil }
            return rows.compactMap(RulebookBookingDayBreakdownRow.init(json:))
        }
    }

    /// The per-day rows for a booking whose selection holds a Saturday or Sunday (web `weekendBreakdownForDates`), or
    /// `[]` for a weekday-only selection, where the screen keeps its usual hours breakdown. Uses the open organisation's
    /// policy state when loaded, else `fallbackPolicy`. RULEBOOK 1.43.0: `otMultiplierOverride` is the rate on screen.
    nonisolated static func weekendBookingBreakdown(
        on dates: [Date],
        start: String,
        end: String,
        isBreakRemoved: Bool,
        fallbackPolicy: OrgPayrollTimePolicy,
        otMultiplierOverride: Double? = nil
    ) -> [RulebookBookingDayBreakdownRow] {
        let keys = dates.map { bookingDayKey($0) }
        guard keys.contains(where: { isWeekendDayKey($0) }) else { return [] }
        if let document = OrganizationRulebookContext.payrollPolicyDocument,
           let rows = weekendBookingBreakdown(
            policyDocument: document, dayKeys: keys, start: start, end: end, isBreakRemoved: isBreakRemoved,
            otMultiplierOverride: otMultiplierOverride
           ) {
            return rows
        }
        return weekendBookingBreakdown(
            policy: fallbackPolicy, dayKeys: keys, start: start, end: end, isBreakRemoved: isBreakRemoved,
            otMultiplierOverride: otMultiplierOverride
        ) ?? []
    }

    // MARK: bookingHoursExplanation / bookingShortfall (1.39.0 §4.3)

    /// RULEBOOK 1.39.0 §4.3 `bookingHoursExplanation(policyState, dayKey, booking, timeZone)` for one custom-hours booking:
    /// the day's rule and one step per part, read from `payrollHoursResult`. Uses the open organisation's policy state
    /// when loaded, else `fallbackPolicy`. Nil when the script did not answer or the times are not valid.
    nonisolated static func bookingHoursExplanation(
        on date: Date,
        start: String,
        end: String,
        isBreakRemoved: Bool,
        fallbackPolicy: OrgPayrollTimePolicy,
        timeZone: String = OrganizationRulebookContext.timeZoneIdentifier,
        otMultiplierOverride: Double? = nil
    ) -> RulebookBookingHoursExplanation? {
        let key = bookingDayKey(date)
        let booking = explanationBooking(
            start: start, end: end, isBreakRemoved: isBreakRemoved, otMultiplierOverride: otMultiplierOverride
        )
        if let document = OrganizationRulebookContext.payrollPolicyDocument,
           let state = payrollPolicyState(
            policyDocument: document,
            todayKey: organizationDayKey(Date(), timeZoneIdentifier: timeZone),
            timeZone: timeZone
           ),
           let row = RulebookBookingHoursExplanation(json: memoCallJSON("bookingHoursExplanation", arguments: [state, key, booking, timeZone])) {
            return row
        }
        return bookingHoursExplanation(
            policy: fallbackPolicy, dayKey: key, start: start, end: end, isBreakRemoved: isBreakRemoved, timeZone: timeZone,
            otMultiplierOverride: otMultiplierOverride
        )
    }

    /// `bookingHoursExplanation(policy, dayKey, booking, timeZone)` with one policy (no policy state).
    nonisolated static func bookingHoursExplanation(
        policy: OrgPayrollTimePolicy,
        dayKey: String,
        start: String,
        end: String,
        isBreakRemoved: Bool,
        timeZone: String = OrganizationRulebookContext.timeZoneIdentifier,
        otMultiplierOverride: Double? = nil
    ) -> RulebookBookingHoursExplanation? {
        guard let policyJSON = payrollPolicyJSON(policy) else { return nil }
        let booking = explanationBooking(
            start: start, end: end, isBreakRemoved: isBreakRemoved, otMultiplierOverride: otMultiplierOverride
        )
        return RulebookBookingHoursExplanation(json: memoCallJSON("bookingHoursExplanation", arguments: [policyJSON, dayKey, booking, timeZone]))
    }

    /// The custom-hours booking `bookingHoursExplanation` reads. RULEBOOK 1.43.0 §25: with the booking's own overtime
    /// rate (left out = the organisation's), so the explanation prices what the booking will be paid. A mapping only.
    nonisolated static func explanationBooking(
        start: String,
        end: String,
        isBreakRemoved: Bool,
        otMultiplierOverride: Double?
    ) -> [String: Any] {
        var booking: [String: Any] = [
            "timeSlot": "CUSTOM_HOURS", "workStartTime": start, "workEndTime": end, "isBreakRemoved": isBreakRemoved,
        ]
        if let rate = bookingOwnRate(otMultiplierOverride) { booking["otMultiplierOverride"] = rate }
        return booking
    }

    /// The explanation of a weekday selection's hours as screen sections (the weekend rows carry their own): one per
    /// weekday, days that read the same once the day name is taken off sharing one ("Monday/Tuesday full day: …"). `[]`
    /// when the selection holds a Saturday or Sunday or nothing answered. RULEBOOK 1.43.0: `otMultiplierOverride` is the
    /// booking's own overtime rate on screen (nil = the organisation's).
    nonisolated static func weekdayExplanationSections(
        on dates: [Date],
        start: String,
        end: String,
        isBreakRemoved: Bool,
        fallbackPolicy: OrgPayrollTimePolicy,
        otMultiplierOverride: Double? = nil
    ) -> [RulebookBreakdownSection] {
        guard !dates.isEmpty, !dates.contains(where: { isWeekendDayKey(bookingDayKey($0)) }) else { return [] }
        var order: [String] = []
        var groups: [String: (labels: [String], rule: String, steps: [String])] = [:]
        for date in dates {
            guard let row = bookingHoursExplanation(
                on: date, start: start, end: end, isBreakRemoved: isBreakRemoved, fallbackPolicy: fallbackPolicy,
                otMultiplierOverride: otMultiplierOverride
            ) else { continue }
            let ruleBody = row.rule.hasPrefix(row.weekdayLabel) ? String(row.rule.dropFirst(row.weekdayLabel.count)) : " " + row.rule
            let key = ruleBody + "|" + row.steps.joined(separator: "|")
            if groups[key] == nil {
                order.append(key)
                groups[key] = ([], ruleBody, row.steps)
            }
            if groups[key]?.labels.contains(row.weekdayLabel) == false {
                groups[key]?.labels.append(row.weekdayLabel)
            }
        }
        return order.compactMap { key in
            guard let group = groups[key] else { return nil }
            return RulebookBreakdownSection(line: "", detail: [group.labels.joined(separator: "/") + group.rule] + group.steps)
        }
    }

    /// One booking as `CanonicalBusinessEngine.bookingShortfall` reads it (slot and clock times). A mapping only.
    nonisolated static func shortfallRow(_ booking: Booking) -> [String: Any] {
        [
            "timeSlot": booking.timeSlot.rawValue,
            "workStartTime": booking.workStartTime ?? NSNull(),
            "workEndTime": booking.workEndTime ?? NSNull(),
        ]
    }

    /// RULEBOOK 1.39.0 §4.3 (review 11 Nov) `bookingShortfall(policyState, dayKey, bookings, timeZone)`: how much of the
    /// day's working time the person's bookings that day (existing + the new one) leave unbooked, by COVERAGE —
    /// `standardDayCoverage` on a weekday, `windowCoverage` of a set-window weekend day, lunch window excluded — never
    /// paid hours. "Short of a full Monday (07:30–16:00): 5.5h"; nil under 0.05h or on a day paid every hour at a rate.
    nonisolated static func bookingShortfall(
        on date: Date,
        bookings: [[String: Any]],
        fallbackPolicy: OrgPayrollTimePolicy,
        timeZone: String = OrganizationRulebookContext.timeZoneIdentifier
    ) -> RulebookBookingShortfall? {
        let key = bookingDayKey(date)
        if let document = OrganizationRulebookContext.payrollPolicyDocument,
           let state = payrollPolicyState(
            policyDocument: document,
            todayKey: organizationDayKey(Date(), timeZoneIdentifier: timeZone),
            timeZone: timeZone
           ) {
            return RulebookBookingShortfall(json: memoCallJSON("bookingShortfall", arguments: [state, key, bookings, timeZone]))
        }
        return bookingShortfall(policy: fallbackPolicy, dayKey: key, bookings: bookings, timeZone: timeZone)
    }

    /// `bookingShortfall(policy, dayKey, bookings, timeZone)` with one policy (no policy state).
    nonisolated static func bookingShortfall(
        policy: OrgPayrollTimePolicy,
        dayKey: String,
        bookings: [[String: Any]],
        timeZone: String = OrganizationRulebookContext.timeZoneIdentifier
    ) -> RulebookBookingShortfall? {
        guard let policyJSON = payrollPolicyJSON(policy) else { return nil }
        return RulebookBookingShortfall(json: memoCallJSON("bookingShortfall", arguments: [policyJSON, dayKey, bookings, timeZone]))
    }

    /// The breakdown rows as screen sections (RULEBOOK 1.39.0): each `collapsedBreakdownLines` line with the explanation
    /// under it (the day's rule, then the steps). Days share a section only when the figure and the explanation read
    /// the same once the day name is taken off. Text grouping only.
    nonisolated static func collapsedBreakdownSections(_ rows: [RulebookBookingDayBreakdownRow]) -> [RulebookBreakdownSection] {
        func body(_ text: String, _ label: String) -> String {
            text.hasPrefix(label) ? String(text.dropFirst(label.count)) : " " + text
        }
        var order: [String] = []
        var groups: [String: (labels: [String], line: String, rule: String, steps: [String])] = [:]
        for row in rows {
            let lineBody = body(row.line, row.weekdayLabel)
            let ruleBody = row.explanationRule.isEmpty ? "" : body(row.explanationRule, row.weekdayLabel)
            let key = lineBody + "|" + ruleBody + "|" + row.explanationSteps.joined(separator: "|")
            if groups[key] == nil {
                order.append(key)
                groups[key] = ([], lineBody, ruleBody, row.explanationSteps)
            }
            if groups[key]?.labels.contains(row.weekdayLabel) == false {
                groups[key]?.labels.append(row.weekdayLabel)
            }
        }
        return order.compactMap { key in
            guard let group = groups[key] else { return nil }
            let label = group.labels.joined(separator: "/")
            let rule = group.rule.isEmpty ? [] : [label + group.rule]
            return RulebookBreakdownSection(line: label + group.line, detail: rule + group.steps)
        }
    }

    /// `isWeekendDayKey(dayKey, timeZone)`: Saturday or Sunday in the organisation zone.
    nonisolated static func isWeekendDayKey(_ dayKey: String, timeZone: String = OrganizationRulebookContext.timeZoneIdentifier) -> Bool {
        callJSON("isWeekendDayKey", arguments: [dayKey, timeZone]) as? Bool ?? false
    }

    /// The breakdown rows as display lines, days whose figures are identical sharing one row ("Saturday/Sunday …"), as
    /// the rulebook allows (web `BookingDayBreakdownRows`). Text grouping only; every figure is the script's `line`.
    nonisolated static func collapsedBreakdownLines(_ rows: [RulebookBookingDayBreakdownRow]) -> [String] {
        var order: [String] = []
        var labels: [String: [String]] = [:]
        for row in rows {
            let body = row.line.hasPrefix(row.weekdayLabel) ? String(row.line.dropFirst(row.weekdayLabel.count)) : " " + row.line
            if labels[body] == nil {
                order.append(body)
                labels[body] = []
            }
            if labels[body]?.contains(row.weekdayLabel) == false {
                labels[body]?.append(row.weekdayLabel)
            }
        }
        return order.map { body in (labels[body] ?? []).joined(separator: "/") + body }
    }
}

/// Web `useCustomHoursPrefillOnKindChange`: a multi-day picker hands every selection's `customHoursPrefillForDays`
/// answer here and applies the returned times only when the selection's kind changes (weekend-only ↔ weekday-only).
/// `mixed` (a refused mix) and nil (no day) are ignored and never reset the remembered kind, so unticking every day and
/// ticking a day of the same kind keeps the person's own times.
nonisolated struct CustomHoursKindTracker: Equatable, Sendable {
    private(set) var appliedKind: RulebookCustomHoursPrefill.Kind?

    /// `seed` is what the picker already shows (an edited booking's day, or the times it opened with), so opening a
    /// picker never overwrites them. Nil applies the first answer.
    init(seed: RulebookCustomHoursPrefill? = nil) {
        if let seed, seed.kind != .mixed { appliedKind = seed.kind }
    }

    /// The prefill to apply now, or nil to leave the times alone.
    mutating func prefillToApply(_ prefill: RulebookCustomHoursPrefill?) -> RulebookCustomHoursPrefill? {
        guard let prefill, prefill.kind != .mixed, prefill.kind != appliedKind else { return nil }
        appliedKind = prefill.kind
        return prefill
    }
}

/// The per-day hours of a weekend booking (`weekendBookingBreakdown`, RULEBOOK 1.18.0), shown in place of the
/// standard-day summary. Takes sections the caller already computed (`collapsedBreakdownSections`), so a redraw never
/// runs the script. RULEBOOK 1.39.0: under each figure, the words that explain it (the day's rule and the steps).
/// Nothing when `sections` is empty.
struct WeekendBookingBreakdownView: View {
    let sections: [RulebookBreakdownSection]
    var title: String = "Hours by day"

    init(sections: [RulebookBreakdownSection], title: String = "Hours by day") {
        self.sections = sections
        self.title = title
    }

    /// Figures only (no explanation), for callers that hold plain lines.
    init(lines: [String], title: String = "Hours by day") {
        self.init(sections: lines.map { RulebookBreakdownSection(line: $0, detail: []) }, title: title)
    }

    var body: some View {
        if !sections.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text(title.uppercased())
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(ProjectWorksRevampColors.muted)
                    .tracking(0.6)
                BookingBreakdownSectionsView(sections: sections)
            }
            .padding(EdgeInsets(top: 10, leading: 12, bottom: 10, trailing: 12))
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(ProjectWorksRevampColors.canvas)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
    }
}

/// RULEBOOK 1.39.0: breakdown sections without a card — each figure (`line`, bold) and its explanation (`detail`:
/// the rule in muted text, then the steps; the "→" total in bold). Web draws the same text
/// (`components/scheduling/BookingHoursExplanation.tsx`).
struct BookingBreakdownSectionsView: View {
    let sections: [RulebookBreakdownSection]
    var lineColor: Color = ProjectWorksRevampColors.ink

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(sections, id: \.self) { section in
                VStack(alignment: .leading, spacing: 2) {
                    if !section.line.isEmpty {
                        Text(section.line)
                            .font(.system(size: 12, weight: .semibold))
                            .monospacedDigit()
                            .foregroundStyle(lineColor)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("booking.weekendBreakdownRow")
                    }
                    ForEach(Array(section.detail.enumerated()), id: \.offset) { index, text in
                        Text(text)
                            .font(.system(size: 11, weight: index == 0 || text.hasPrefix("→") ? .semibold : .regular))
                            .monospacedDigit()
                            .foregroundStyle(index == 0 ? ProjectWorksRevampColors.muted : ProjectWorksRevampColors.ink)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("booking.hoursExplanationLine")
                    }
                }
            }
        }
    }
}
