//
//  Rulebook+PayrollPolicyState.swift
//  Project Planner
//
//  Typed wrappers for the working-hours rules of rulebook 1.19.0 (docs/RULEBOOK.md §1, §4.3, §4.6, §5, §8; web
//  `lib/canonical/payrollPolicySchedule.ts`, `payrollHours.ts`, `organizationSettings.ts`, `bookingSlots.ts`):
//  - the policy STATE (`payrollTimePolicyHistory`, `payrollTimePolicyRevision`) and the policy on a day from it;
//  - the two-admin save guard (`payrollTimePolicySaveConflict`, `PAYROLL_POLICY_STALE_SAVE_MESSAGE`);
//  - each weekend day's own lunch break (`weekendBreakFor`, `payrollBreakOnDay`, `unpaidBreakAppliesOnDay`,
//    `weekendLunchBreakCopy`, `payrollDayWindows`);
//  - `payrollHoursResult` with the whole policy (weekend breaks included) and its `unpaidBreakHours`;
//  - weekend "Hours to cover" (`parseWeekendCoverage`, `resolveWeekendCoverageDay`).
//  Every answer comes from the packed script through `CanonicalBusinessEngine.callJSON`; Swift maps values only.
//

import Foundation

// MARK: - Memo

/// Script answers keyed by their exact input, so a redraw never runs the packed script again. It stores what the
/// script returned; it is not a second copy of any rule.
nonisolated final class RulebookAnswerMemo<Key: Hashable, Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var store: [Key: Value] = [:]
    private let limit: Int

    init(limit: Int = 1024) {
        self.limit = limit
    }

    func value(for key: Key, compute: () -> Value?) -> Value? {
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

/// A JSON object (a script answer) carried through a memo.
nonisolated struct RulebookJSONBox: @unchecked Sendable {
    let object: [String: Any]
}

// MARK: - payrollHoursResult with the whole policy

/// `PayrollHoursInput`: the booking fields, its organisation-zone day and the policy in effect that day. Unlike
/// `CanonicalPayrollHoursInput` (Canonical/, which predates 1.19.0), the policy is the whole Swift policy, so each
/// weekend day's `breakPaid`, `breakMinutes` and break window reach the script and the memo key.
nonisolated struct RulebookPayrollHoursInput: Hashable, Sendable {
    var booking: CanonicalPayrollBooking
    var dayKey: String
    var policy: OrgPayrollTimePolicy
    var timeZone: String = OrganizationRulebookContext.timeZoneIdentifier

    /// The script argument: `{ booking, dayKey, policy: parsePayrollPolicy(policy), timeZone }`.
    func scriptArgument() -> [String: Any]? {
        guard let policyJSON = CanonicalBusinessEngine.payrollPolicyJSON(policy) else { return nil }
        var booking: [String: Any] = [
            "timeSlot": self.booking.timeSlot,
            "isBreakRemoved": self.booking.isBreakRemoved,
        ]
        if let start = self.booking.workStartTime { booking["workStartTime"] = start }
        if let end = self.booking.workEndTime { booking["workEndTime"] = end }
        if let override = self.booking.otMultiplierOverride { booking["otMultiplierOverride"] = override }
        return ["booking": booking, "dayKey": dayKey, "policy": policyJSON, "timeZone": timeZone]
    }
}

/// `payrollHoursResult` answer (1.19.0: with `workedHours` and `unpaidBreakHours`).
nonisolated struct RulebookPayrollHours: Hashable, Sendable {
    let hours: CanonicalPayrollHours
    let workedHours: Double
    /// The unpaid break taken off this booking (hours, before any multiplier). 0 when none.
    let unpaidBreakHours: Double
    /// Each segment's own `unpaidBreakHours`, in segment order.
    let segmentUnpaidBreakHours: [Double]
}

extension CanonicalBusinessEngine {
    nonisolated private static let payrollPolicyJSONMemo = RulebookAnswerMemo<OrgPayrollTimePolicy, RulebookJSONBox>(limit: 256)
    nonisolated private static let payrollHoursMemo = RulebookAnswerMemo<RulebookPayrollHoursInput, RulebookPayrollHours>(limit: 2048)
    nonisolated private static let workedSplitMemo = RulebookAnswerMemo<RulebookPayrollHoursInput, CanonicalWorkedHoursSplit>(limit: 1024)

    /// `parsePayrollPolicy(policy)` memoised by the Swift policy (every pricing call needs it).
    nonisolated static func memoisedPayrollPolicyJSON(_ policy: OrgPayrollTimePolicy) -> [String: Any]? {
        payrollPolicyJSONMemo.value(for: policy) {
            guard let object = callJSON("parsePayrollPolicy", arguments: [policy.asFirestoreDictionary()]) as? [String: Any] else {
                return nil
            }
            return RulebookJSONBox(object: object)
        }?.object
    }

    /// `payrollHoursResult(input)` with the whole policy. Nil when the script did not answer.
    nonisolated static func payrollHoursResult(_ input: RulebookPayrollHoursInput) -> RulebookPayrollHours? {
        payrollHoursMemo.value(for: input) {
            guard let argument = input.scriptArgument(),
                  let raw = callJSON("payrollHoursResult", arguments: [argument]) as? [String: Any],
                  let data = try? JSONSerialization.data(withJSONObject: raw),
                  let hours = try? JSONDecoder().decode(CanonicalPayrollHours.self, from: data) else { return nil }
            func number(_ value: Any?) -> Double { (value as? NSNumber)?.doubleValue ?? 0 }
            let segments = raw["segments"] as? [[String: Any]] ?? []
            return RulebookPayrollHours(
                hours: hours,
                workedHours: number(raw["workedHours"]),
                unpaidBreakHours: number(raw["unpaidBreakHours"]),
                segmentUnpaidBreakHours: segments.map { number($0["unpaidBreakHours"]) }
            )
        }
    }

    /// `workedHoursSplit(payrollHoursResult(input))` with the whole policy. Nil when the script did not answer.
    nonisolated static func workedHoursSplit(_ input: RulebookPayrollHoursInput) -> CanonicalWorkedHoursSplit? {
        workedSplitMemo.value(for: input) {
            guard let argument = input.scriptArgument(),
                  let result = callJSON("payrollHoursResult", arguments: [argument]) as? [String: Any],
                  let split = callJSON("workedHoursSplit", arguments: [result]) as? [String: Any] else { return nil }
            func number(_ value: Any?) -> Double { (value as? NSNumber)?.doubleValue ?? 0 }
            return CanonicalWorkedHoursSplit(
                standardWorkedHours: number(split["standardWorkedHours"]),
                outsideWorkedHours: number(split["outsideWorkedHours"]),
                workedHours: number(result["workedHours"]),
                outsideHours: number(result["outsideHours"]),
                outsideMultiplier: number(result["outsideMultiplier"])
            )
        }
    }
}

// MARK: - Policy state (1.19.0 §1, §4.3)

/// One `payrollTimePolicyHistory` entry as the script reads it.
nonisolated struct RulebookPayrollHistoryEntry: Hashable, Sendable {
    let effectiveFrom: String
    let policy: OrgPayrollTimePolicy
}

extension CanonicalBusinessEngine {
    nonisolated private static let policyStateMemo = RulebookAnswerMemo<String, RulebookJSONBox>(limit: 32)

    /// RULEBOOK 1.19.0 §4.3: the organisation's policy STATE (`payrollTimePolicyTimeline(orgDoc, todayKey, timeZone)`,
    /// which carries `history` and `revision`), memoised by the stored fields and the day. Passed as `payrollPolicy` /
    /// `policy` to every rule that reads each day under its own working hours. Nil when the script did not answer.
    nonisolated static func payrollPolicyState(
        document: [String: Any],
        todayKey: String? = nil,
        timeZone: String = OrganizationRulebookContext.timeZoneIdentifier
    ) -> [String: Any]? {
        let today = todayKey ?? organizationDayKey(Date(), timeZoneIdentifier: timeZone)
        let compute: () -> RulebookJSONBox? = {
            guard let state = callJSON("payrollTimePolicyTimeline", arguments: [document, today, timeZone]) as? [String: Any] else {
                return nil
            }
            return RulebookJSONBox(object: state)
        }
        guard JSONSerialization.isValidJSONObject(document),
              let bytes = try? JSONSerialization.data(withJSONObject: document, options: [.sortedKeys]),
              let text = String(data: bytes, encoding: .utf8) else { return compute()?.object }
        return policyStateMemo.value(for: "\(today)|\(timeZone)|\(text)", compute: compute)?.object
    }

    nonisolated private static let dayPolicyMemo = RulebookAnswerMemo<String, OrgPayrollTimePolicy>(limit: 512)

    /// RULEBOOK 1.19.0 §4.3: `effectivePayrollTimePolicy(orgDoc, dayKey)` for the open organisation (history first), for
    /// code that has no `Organization` at hand (booking sheets). `fallback` before an organisation is loaded or when the
    /// script did not answer.
    nonisolated static func payrollPolicyInEffect(on date: Date, fallback: OrgPayrollTimePolicy) -> OrgPayrollTimePolicy {
        guard let document = OrganizationRulebookContext.payrollPolicyDocument,
              let documentKey = OrganizationRulebookContext.payrollPolicyDocumentKey else { return fallback }
        let dayKey = OrganizationRulebookContext.dayKey(date)
        return dayPolicyMemo.value(for: "\(dayKey)|\(documentKey)") {
            effectivePayrollTimePolicy(orgDocument: document, dayKey: dayKey)
        } ?? fallback
    }

    /// The open organisation's policy state (`OrganizationRulebookContext.payrollPolicyDocument`), or nil before one is
    /// loaded.
    nonisolated static var openOrganizationPayrollPolicyState: [String: Any]? {
        OrganizationRulebookContext.payrollPolicyDocument.flatMap { payrollPolicyState(document: $0) }
    }

    /// `PAYROLL_POLICY_HISTORY_START` (`1970-01-01`).
    nonisolated static var payrollPolicyHistoryStart: String {
        constant("PAYROLL_POLICY_HISTORY_START", as: String.self) ?? "1970-01-01"
    }

    /// `PAYROLL_POLICY_STALE_SAVE_MESSAGE`.
    nonisolated static var payrollPolicyStaleSaveMessage: String {
        constant("PAYROLL_POLICY_STALE_SAVE_MESSAGE", as: String.self)
            ?? "Someone else changed the working hours while you were editing. Your change was not saved — check the latest working hours and try again."
    }

    /// `payrollTimePolicySaveConflict(baseOrgDoc, liveOrgDoc, timeZone)`: the stale-save message when the working hours
    /// changed between the document the screen loaded and the one read inside the save's transaction, else nil.
    /// A script that does not answer refuses the save (nothing is written on an unchecked guard).
    nonisolated static func payrollTimePolicySaveConflict(
        baseOrgDocument: [String: Any],
        liveOrgDocument: [String: Any],
        timeZone: String = OrganizationRulebookContext.timeZoneIdentifier
    ) -> String? {
        guard let answer = callJSON("payrollTimePolicySaveConflict", arguments: [baseOrgDocument, liveOrgDocument, timeZone]) else {
            return payrollPolicyStaleSaveMessage
        }
        return answer as? String
    }

    /// `payrollTimePolicyHistoryEntries(parsePayrollTimePolicyState(orgDoc))`: every change of working hours in date
    /// order (the pending change left out). Nil when the script did not answer.
    nonisolated static func payrollTimePolicyHistoryEntries(
        orgDocument: [String: Any],
        timeZone: String = OrganizationRulebookContext.timeZoneIdentifier
    ) -> [RulebookPayrollHistoryEntry]? {
        guard let state = callJSON("parsePayrollTimePolicyState", arguments: [orgDocument, timeZone]),
              let rows = callJSON("payrollTimePolicyHistoryEntries", arguments: [state]) as? [[String: Any]] else { return nil }
        return rows.compactMap { row in
            guard let day = row["effectiveFrom"] as? String, let policy = payrollPolicy(fromJSON: row["policy"]) else { return nil }
            return RulebookPayrollHistoryEntry(effectiveFrom: day, policy: policy)
        }
    }

    /// `parsePayrollTimePolicyState(orgDoc).revision` (0 when missing).
    nonisolated static func payrollTimePolicyRevision(
        orgDocument: [String: Any],
        timeZone: String = OrganizationRulebookContext.timeZoneIdentifier
    ) -> Int {
        let state = callJSON("parsePayrollTimePolicyState", arguments: [orgDocument, timeZone]) as? [String: Any]
        return (state?["revision"] as? NSNumber)?.intValue ?? 0
    }
}

// MARK: - Weekend lunch breaks (1.19.0 §4.3)

/// `weekendBreakFor` → `{ paid, minutes, start, end }`.
nonisolated struct RulebookWeekendBreak: Hashable, Sendable {
    let paid: Bool
    let minutes: Int
    let start: String
    let end: String
}

/// `payrollBreakOnDay` → `{ start, end, minutes, paid }` (minutes from midnight).
nonisolated struct RulebookDayBreak: Hashable, Sendable {
    let start: Int
    let end: Int
    let minutes: Int
    let paid: Bool
}

/// `payrollDayWindows` → the bands an hours timeline draws for a booking day.
nonisolated struct RulebookPayrollDayWindows: Hashable, Sendable {
    /// The weekday standard day or a set-window weekend day's window; nil on an every-hour weekend day.
    let paidWindow: CanonicalMinuteInterval?
    /// The break window when an unpaid break applies that day, else nil.
    let unpaidBreak: CanonicalMinuteInterval?
    /// An every-hour weekend day's multiplier, else nil.
    let allHoursMultiplier: Double?
}

/// The weekend day a working-hours rule belongs to.
nonisolated enum RulebookWeekendDay: String, Sendable {
    case saturday
    case sunday
}

nonisolated private struct PolicyDayKey: Hashable, Sendable {
    let policy: OrgPayrollTimePolicy
    let dayKey: String
    let timeZone: String
}

nonisolated private struct PolicyWeekendKey: Hashable, Sendable {
    let policy: OrgPayrollTimePolicy
    let weekday: String
}

nonisolated private struct BoolBox: Hashable, Sendable { let value: Bool }
nonisolated private struct OptionalBreakBox: Hashable, Sendable { let value: RulebookDayBreak? }

extension CanonicalBusinessEngine {
    nonisolated private static let unpaidBreakMemo = RulebookAnswerMemo<PolicyDayKey, BoolBox>(limit: 1024)
    nonisolated private static let dayBreakMemo = RulebookAnswerMemo<PolicyDayKey, OptionalBreakBox>(limit: 1024)
    nonisolated private static let dayWindowsMemo = RulebookAnswerMemo<PolicyDayKey, RulebookPayrollDayWindows>(limit: 1024)
    nonisolated private static let lunchCopyMemo = RulebookAnswerMemo<PolicyWeekendKey, RulebookLunchBreakCopy>(limit: 128)
    nonisolated private static let weekendBreakMemo = RulebookAnswerMemo<PolicyWeekendKey, RulebookWeekendBreak>(limit: 128)

    nonisolated private static func minuteInterval(_ value: Any?) -> CanonicalMinuteInterval? {
        guard let row = value as? [String: Any],
              let start = (row["start"] as? NSNumber)?.intValue,
              let end = (row["end"] as? NSNumber)?.intValue else { return nil }
        return CanonicalMinuteInterval(start: start, end: end)
    }

    /// `weekendBreakFor(policy, policy[weekday])` (Sunday "same as Saturday" reads Saturday's rule): that day's break,
    /// each missing field the weekday one. Nil when the script did not answer.
    nonisolated static func weekendBreakFor(policy: OrgPayrollTimePolicy, weekday: RulebookWeekendDay) -> RulebookWeekendBreak? {
        weekendBreakMemo.value(for: PolicyWeekendKey(policy: policy, weekday: weekday.rawValue)) {
            guard let policyJSON = memoisedPayrollPolicyJSON(policy) else { return nil }
            let sunday = policyJSON["sunday"] as? [String: Any]
            let useSaturday = weekday == .saturday || (sunday?["sameAsSaturday"] as? Bool) == true
            let settings = useSaturday ? policyJSON["saturday"] : policyJSON["sunday"]
            guard let settings,
                  let row = callJSON("weekendBreakFor", arguments: [policyJSON, settings]) as? [String: Any],
                  let start = row["start"] as? String, let end = row["end"] as? String else { return nil }
            return RulebookWeekendBreak(
                paid: row["paid"] as? Bool ?? true,
                minutes: (row["minutes"] as? NSNumber)?.intValue ?? 0,
                start: start,
                end: end
            )
        }
    }

    /// `unpaidBreakAppliesOnDay(policy, dayKey, timeZone)`: Mon–Fri the organisation break is unpaid; Saturday / Sunday
    /// that day's `breakPaid` is false; both with a length above 0. Booking pickers offer the "No unpaid break" toggle and
    /// `customHoursBreakWarning` only when true. False when the script did not answer.
    nonisolated static func unpaidBreakAppliesOnDay(
        policy: OrgPayrollTimePolicy,
        dayKey: String,
        timeZone: String = OrganizationRulebookContext.timeZoneIdentifier
    ) -> Bool {
        unpaidBreakMemo.value(for: PolicyDayKey(policy: policy, dayKey: dayKey, timeZone: timeZone)) {
            guard let policyJSON = memoisedPayrollPolicyJSON(policy),
                  let answer = callJSON("unpaidBreakAppliesOnDay", arguments: [policyJSON, dayKey, timeZone]) as? Bool else {
                return nil
            }
            return BoolBox(value: answer)
        }?.value ?? false
    }

    /// `unpaidBreakAppliesOnDay` for a booking date, under the policy in effect on it.
    static func unpaidBreakApplies(on date: Date, organization: Organization?) -> Bool {
        unpaidBreakAppliesOnDay(
            policy: PayrollTimePolicyCatalog.policy(for: date, organization: organization),
            dayKey: bookingDayKey(date)
        )
    }

    /// `payrollBreakOnDay(policy, dayKey, timeZone)`: that day's break window and length, paid or not. Nil when the
    /// window does not form an interval or the script did not answer.
    nonisolated static func payrollBreakOnDay(
        policy: OrgPayrollTimePolicy,
        dayKey: String,
        timeZone: String = OrganizationRulebookContext.timeZoneIdentifier
    ) -> RulebookDayBreak? {
        dayBreakMemo.value(for: PolicyDayKey(policy: policy, dayKey: dayKey, timeZone: timeZone)) {
            guard let policyJSON = memoisedPayrollPolicyJSON(policy),
                  let answer = callJSON("payrollBreakOnDay", arguments: [policyJSON, dayKey, timeZone]) else { return nil }
            guard let row = answer as? [String: Any],
                  let start = (row["start"] as? NSNumber)?.intValue,
                  let end = (row["end"] as? NSNumber)?.intValue else { return OptionalBreakBox(value: nil) }
            return OptionalBreakBox(value: RulebookDayBreak(
                start: start,
                end: end,
                minutes: (row["minutes"] as? NSNumber)?.intValue ?? 0,
                paid: row["paid"] as? Bool ?? true
            ))
        }?.value
    }

    /// `payrollDayWindows(policy, dayKey, timeZone)`. Nil when the script did not answer.
    nonisolated static func payrollDayWindows(
        policy: OrgPayrollTimePolicy,
        dayKey: String,
        timeZone: String = OrganizationRulebookContext.timeZoneIdentifier
    ) -> RulebookPayrollDayWindows? {
        dayWindowsMemo.value(for: PolicyDayKey(policy: policy, dayKey: dayKey, timeZone: timeZone)) {
            guard let policyJSON = memoisedPayrollPolicyJSON(policy),
                  let row = callJSON("payrollDayWindows", arguments: [policyJSON, dayKey, timeZone]) as? [String: Any] else {
                return nil
            }
            return RulebookPayrollDayWindows(
                paidWindow: minuteInterval(row["paidWindow"]),
                unpaidBreak: minuteInterval(row["unpaidBreak"]),
                allHoursMultiplier: (row["allHoursMultiplier"] as? NSNumber)?.doubleValue
            )
        }
    }

    /// `weekendLunchBreakCopy(policy, weekday)` → `{ title, detail }`. Nil when the script did not answer.
    nonisolated static func weekendLunchBreakCopy(policy: OrgPayrollTimePolicy, weekday: RulebookWeekendDay) -> RulebookLunchBreakCopy? {
        lunchCopyMemo.value(for: PolicyWeekendKey(policy: policy, weekday: weekday.rawValue)) {
            guard let policyJSON = memoisedPayrollPolicyJSON(policy),
                  let row = callJSON("weekendLunchBreakCopy", arguments: [policyJSON, weekday.rawValue]) as? [String: Any],
                  let title = row["title"] as? String else { return nil }
            return RulebookLunchBreakCopy(title: title, detail: row["detail"] as? String ?? "")
        }
    }
}

/// `weekendLunchBreakCopy` → `{ title, detail }`.
nonisolated struct RulebookLunchBreakCopy: Hashable, Sendable {
    let title: String
    let detail: String
}

// MARK: - Weekend hours to cover (1.19.0 §4.6, §5)

/// One `warningDetection.weekendCoverage` day: `{ enabled, start, end }` (`start` / `end` `HH:MM` or nil).
nonisolated struct OrgWeekendCoverageDay: Codable, Hashable, Sendable {
    var enabled: Bool
    var start: String?
    var end: String?

    func asFirestoreDictionary() -> [String: Any] {
        let startValue: Any = start ?? NSNull()
        let endValue: Any = end ?? NSNull()
        return ["enabled": enabled, "start": startValue, "end": endValue]
    }
}

/// `warningDetection.weekendCoverage` (`parseWeekendCoverage`).
nonisolated struct OrgWeekendCoverage: Codable, Hashable, Sendable {
    var saturday: OrgWeekendCoverageDay
    var sunday: OrgWeekendCoverageDay

    /// The whole map, written as one field of the warning-settings partial update (`warningDetection.weekendCoverage`).
    func asFirestoreDictionary() -> [String: Any] {
        ["saturday": saturday.asFirestoreDictionary(), "sunday": sunday.asFirestoreDictionary()]
    }

    /// A parsed `weekendCoverage` map from the script (`parseWeekendCoverage` / `parseWarningDetection`).
    static func fromScript(_ value: Any?) -> OrgWeekendCoverage? {
        guard let map = value as? [String: Any] else { return nil }
        func day(_ raw: Any?) -> OrgWeekendCoverageDay? {
            guard let row = raw as? [String: Any] else { return nil }
            return OrgWeekendCoverageDay(
                enabled: row["enabled"] as? Bool ?? false,
                start: row["start"] as? String,
                end: row["end"] as? String
            )
        }
        guard let saturday = day(map["saturday"]), let sunday = day(map["sunday"]) else { return nil }
        return OrgWeekendCoverage(saturday: saturday, sunday: sunday)
    }
}

/// `resolveWeekendCoverageDay` → `{ enabled, start, end }`.
nonisolated struct RulebookWeekendCoverageDay: Hashable, Sendable {
    let enabled: Bool
    let start: String
    let end: String
}

nonisolated private struct CoverageDayKey: Hashable, Sendable {
    let coverage: OrgWeekendCoverage?
    let includeWeekends: Bool
    let policy: OrgPayrollTimePolicy?
    let weekday: String
}

extension CanonicalBusinessEngine {
    nonisolated private static let coverageDayMemo = RulebookAnswerMemo<CoverageDayKey, RulebookWeekendCoverageDay>(limit: 256)

    /// `parseWeekendCoverage(value, includeWeekends)`. Nil when the script did not answer.
    nonisolated static func parseWeekendCoverage(_ value: Any?, includeWeekends: Bool) -> OrgWeekendCoverage? {
        OrgWeekendCoverage.fromScript(callJSON("parseWeekendCoverage", arguments: [value ?? NSNull(), includeWeekends]))
    }

    /// `resolveWeekendCoverageDay(coverage, includeWeekends, policy, weekday)`: scanned or not, and the window that must be
    /// covered (saved "Hours to cover", else that day's set window, else the standard day). `policy` is the policy in
    /// effect that day. Nil when the script did not answer.
    nonisolated static func resolveWeekendCoverageDay(
        coverage: OrgWeekendCoverage?,
        includeWeekends: Bool,
        policy: OrgPayrollTimePolicy?,
        weekday: RulebookWeekendDay
    ) -> RulebookWeekendCoverageDay? {
        let key = CoverageDayKey(coverage: coverage, includeWeekends: includeWeekends, policy: policy, weekday: weekday.rawValue)
        return coverageDayMemo.value(for: key) {
            let policyArgument: Any = policy.flatMap { memoisedPayrollPolicyJSON($0) } ?? NSNull()
            let coverageArgument: Any = coverage?.asFirestoreDictionary() ?? NSNull()
            guard let row = callJSON(
                "resolveWeekendCoverageDay",
                arguments: [coverageArgument, includeWeekends, policyArgument, weekday.rawValue]
            ) as? [String: Any],
                  let start = row["start"] as? String, let end = row["end"] as? String else { return nil }
            return RulebookWeekendCoverageDay(enabled: row["enabled"] as? Bool ?? false, start: start, end: end)
        }
    }
}
