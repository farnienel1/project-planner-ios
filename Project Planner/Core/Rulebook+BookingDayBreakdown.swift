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
        callJSON("payrollTimePolicyTimeline", arguments: [policyDocument, todayKey, timeZone]) as? [String: Any]
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
        timeZone: String = OrganizationRulebookContext.timeZoneIdentifier
    ) -> [RulebookBookingDayBreakdownRow]? {
        let today = todayKey ?? organizationDayKey(Date(), timeZoneIdentifier: timeZone)
        let compute: () -> [RulebookBookingDayBreakdownRow]? = {
            guard let state = payrollPolicyState(policyDocument: policyDocument, todayKey: today, timeZone: timeZone),
                  let rows = callJSON(
                    "weekendBookingBreakdown",
                    arguments: [state, dayKeys, start, end, isBreakRemoved, timeZone]
                  ) as? [Any] else { return nil }
            return rows.compactMap(RulebookBookingDayBreakdownRow.init(json:))
        }
        guard let document = documentKey(policyDocument) else { return compute() }
        let key = BookingPickerMemoKey(
            document: document, policy: nil, dayKeys: dayKeys, start: start, end: end,
            isBreakRemoved: isBreakRemoved, todayKey: today, timeZone: timeZone
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
        timeZone: String = OrganizationRulebookContext.timeZoneIdentifier
    ) -> [RulebookBookingDayBreakdownRow]? {
        let key = BookingPickerMemoKey(
            document: nil, policy: policy, dayKeys: dayKeys, start: start, end: end,
            isBreakRemoved: isBreakRemoved, todayKey: "", timeZone: timeZone
        )
        return weekendBreakdownMemo.value(for: key) {
            guard let policyJSON = payrollPolicyJSON(policy),
                  let rows = callJSON(
                    "weekendBookingBreakdown",
                    arguments: [policyJSON, dayKeys, start, end, isBreakRemoved, timeZone]
                  ) as? [Any] else { return nil }
            return rows.compactMap(RulebookBookingDayBreakdownRow.init(json:))
        }
    }

    /// The per-day rows for a booking whose selection holds a Saturday or Sunday (web `weekendBreakdownForDates`), or
    /// `[]` for a weekday-only selection, where the screen keeps its usual hours breakdown. Uses the open organisation's
    /// policy state when loaded, else `fallbackPolicy`.
    nonisolated static func weekendBookingBreakdown(
        on dates: [Date],
        start: String,
        end: String,
        isBreakRemoved: Bool,
        fallbackPolicy: OrgPayrollTimePolicy
    ) -> [RulebookBookingDayBreakdownRow] {
        let keys = dates.map { bookingDayKey($0) }
        guard keys.contains(where: { isWeekendDayKey($0) }) else { return [] }
        if let document = OrganizationRulebookContext.payrollPolicyDocument,
           let rows = weekendBookingBreakdown(
            policyDocument: document, dayKeys: keys, start: start, end: end, isBreakRemoved: isBreakRemoved
           ) {
            return rows
        }
        return weekendBookingBreakdown(
            policy: fallbackPolicy, dayKeys: keys, start: start, end: end, isBreakRemoved: isBreakRemoved
        ) ?? []
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
/// standard-day summary. Takes lines the caller already computed (`collapsedBreakdownLines`), so a redraw never runs
/// the script. Nothing when `lines` is empty.
struct WeekendBookingBreakdownView: View {
    let lines: [String]
    var title: String = "Hours by day"

    var body: some View {
        if !lines.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text(title.uppercased())
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(ProjectWorksRevampColors.muted)
                    .tracking(0.6)
                ForEach(lines, id: \.self) { line in
                    Text(line)
                        .font(.system(size: 12, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(ProjectWorksRevampColors.ink)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("booking.weekendBreakdownRow")
                }
            }
            .padding(EdgeInsets(top: 10, leading: 12, bottom: 10, trailing: 12))
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(ProjectWorksRevampColors.canvas)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
    }
}
