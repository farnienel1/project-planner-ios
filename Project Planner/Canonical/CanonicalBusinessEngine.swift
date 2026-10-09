//
//  CanonicalBusinessEngine.swift
//  Project Planner
//
//  Evaluates lib/canonical from the web app. The JavaScript file is generated;
//  do not edit canonical-business.js by hand.
//

import Foundation
import JavaScriptCore

struct CanonicalDayWindow: Equatable {
    let startDayKey: String
    let endDayKey: String
}

/// Half-open `[start, end)` in minutes since midnight, the script's `MinuteInterval`.
nonisolated struct CanonicalMinuteInterval: Codable, Hashable, Sendable {
    let start: Int
    let end: Int

    init(start: Int, end: Int) {
        self.start = start
        self.end = end
    }

    init(_ tuple: (Int, Int)) {
        self.init(start: tuple.0, end: tuple.1)
    }

    var tuple: (Int, Int) { (start, end) }
    var minutes: Int { max(0, end - start) }
}

/// The script's `StandardDayInput`. Fields go through unchanged; the script applies the
/// 07:30–16:00 day and 12:00–12:30 break fallbacks.
nonisolated struct CanonicalStandardDayInput: Codable, Hashable, Sendable {
    var standardDayStart: String?
    var standardDayEnd: String?
    var breakWindowStart: String?
    var breakWindowEnd: String?

    init(
        standardDayStart: String? = nil,
        standardDayEnd: String? = nil,
        breakWindowStart: String? = nil,
        breakWindowEnd: String? = nil
    ) {
        self.standardDayStart = standardDayStart
        self.standardDayEnd = standardDayEnd
        self.breakWindowStart = breakWindowStart
        self.breakWindowEnd = breakWindowEnd
    }

    /// The organisation policy as stored. Weekday callers pass this.
    init(policy: OrgPayrollTimePolicy) {
        self.init(
            standardDayStart: policy.standardDayStart,
            standardDayEnd: policy.standardDayEnd,
            breakWindowStart: policy.breakWindowStart,
            breakWindowEnd: policy.breakWindowEnd
        )
    }
}

/// The script's `HalfDayWindows`: the standard day and its AM and PM halves.
nonisolated struct CanonicalHalfDayWindows: Codable, Hashable, Sendable {
    let day: CanonicalMinuteInterval
    let am: CanonicalMinuteInterval
    let pm: CanonicalMinuteInterval
    /// `break` when the unpaid break separates the halves, `midpoint` otherwise.
    let pivot: String
    let breakWindow: CanonicalMinuteInterval?
}

/// One person the leave-coverage scan knows about (`LeavePerson` in the script).
nonisolated struct CanonicalLeavePerson: Codable, Hashable, Sendable {
    var personKey: String
    var name: String
    var userId: String?
    var operativeIds: [String]?
}

/// One annual-leave record (`LeaveRecord` in the script).
nonisolated struct CanonicalLeaveRecord: Codable, Hashable, Sendable {
    var id: String
    var userId: String?
    var operativeId: String?
    var startDayKey: String
    var endDayKey: String
    var timeSlot: String?
    var approved: Bool
}

/// One booking the leave-coverage scan compares against leave (`LeaveBooking` in the script).
nonisolated struct CanonicalLeaveBooking: Codable, Hashable, Sendable {
    var id: String
    /// Operative id for operative bookings, user id for manager bookings.
    var personId: String
    /// `operative` or `manager`.
    var kind: String
    var dayKey: String
    var timeSlot: String?
    var workStartTime: String?
    var workEndTime: String?
    var label: String?
}

/// Payload for `leaveCoverageRows` (`LeaveCoverageInput` in the script).
nonisolated struct CanonicalLeaveCoverageInput: Codable, Hashable, Sendable {
    var timeZone: String? = "Europe/London"
    var startDayKey: String
    var endDayKey: String
    var day: CanonicalStandardDayInput?
    var includeWeekends: Bool
    var excludedUserIds: [String]?
    var people: [CanonicalLeavePerson]
    var leave: [CanonicalLeaveRecord]
    var bookings: [CanonicalLeaveBooking]
}

/// One booking that overlaps a leave window (`LeaveClashEntry` in the script).
nonisolated struct CanonicalLeaveClashEntry: Codable, Hashable, Sendable {
    let bookingId: String
    let kind: String
    let label: String
    let start: Int
    let end: Int
    let overlapStart: Int
    let overlapEnd: Int
}

/// One leave warning (`LeaveCoverageRow` in the script). `kind` is `leave_clash` or `leave_cover`.
nonisolated struct CanonicalLeaveCoverageRow: Codable, Hashable, Sendable {
    let id: String
    let kind: String
    let personKey: String
    let personName: String
    let userId: String?
    let operativeId: String?
    let dayKey: String
    let leaveId: String
    let leaveSlot: String
    let leaveLabel: String
    let leaveWindow: CanonicalMinuteInterval
    let clashes: [CanonicalLeaveClashEntry]
    let workingWindow: CanonicalMinuteInterval?
    let missing: [CanonicalMinuteInterval]
    let missingHours: Double
    let bookedHours: Double
    let severity: String
    let title: String
    let message: String
}

nonisolated enum CanonicalBusinessEngine {
    /// Organisation calendar. Device time zone must not decide pay periods or warning windows.
    static var businessCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/London") ?? TimeZone(secondsFromGMT: 0)!
        calendar.locale = Locale(identifier: "en_GB")
        calendar.firstWeekday = 2
        return calendar
    }

    private static let scriptLock = NSLock()

    private static let context: JSContext? = {
        let source: String?
        if let url = Bundle.main.url(forResource: "canonical-business", withExtension: "js") {
            source = try? String(contentsOf: url, encoding: .utf8)
        } else {
            source = nil
        }
        guard let source, !source.isEmpty else { return nil }
        let context = JSContext()
        context?.exceptionHandler = { _, value in
            NSLog("Canonical business script error: %@", value?.toString() ?? "")
        }
        context?.evaluateScript(source)
        return context
    }()

    static func coverageWindow(
        reference: Date,
        timeZone: String = "Europe/London",
        clashLookaheadMode: String,
        clashLookaheadDays: Int,
        paymentRunMode: String,
        ranges: [(startDay: Int, endDay: Int)],
        recurringRunStartDay: String,
        recurringRunEndDay: String
    ) -> CanonicalDayWindow? {
        guard context != nil else { return nil }
        let payload: [String: Any] = [
            "referenceIso": isoString(from: reference),
            "timeZone": timeZone,
            "clashLookaheadMode": clashLookaheadMode,
            "clashLookaheadDays": clashLookaheadDays,
            "paymentRunMode": paymentRunMode,
            "ranges": ranges.map { ["startDay": $0.startDay, "endDay": $0.endDay] },
            "recurringRunStartDay": recurringRunStartDay,
            "recurringRunEndDay": recurringRunEndDay,
        ]
        guard JSONSerialization.isValidJSONObject(payload),
              let data = try? JSONSerialization.data(withJSONObject: payload),
              let json = String(data: data, encoding: .utf8) else {
            return nil
        }
        let value = evaluate("ProjectPlannerCanonical.coverageWindow(\(json))")
        guard let result = value?.toDictionary(),
              let start = result["startDayKey"] as? String,
              let end = result["endDayKey"] as? String,
              !start.isEmpty, !end.isEmpty else {
            return nil
        }
        return CanonicalDayWindow(startDayKey: start, endDayKey: end)
    }

    /// Warning scan bounds from the shared script, or the same London calendar if the script is missing.
    static func warningBounds(
        detection: OrgWarningDetectionSettings,
        invoicing: OrganizationInvoicingSettings,
        reference: Date = Date()
    ) -> (start: Date, end: Date) {
        let calendar = businessCalendar
        let ranges = invoicing.paymentRunDateRanges.map { (startDay: $0.startDay, endDay: $0.endDay) }
        if let window = coverageWindow(
            reference: reference,
            clashLookaheadMode: detection.clashLookaheadMode.rawValue,
            clashLookaheadDays: detection.clashLookaheadDays,
            paymentRunMode: invoicing.paymentRunMode.rawValue,
            ranges: ranges,
            recurringRunStartDay: invoicing.recurringRunStartDay.rawValue,
            recurringRunEndDay: invoicing.recurringRunEndDay.rawValue
        ),
           let start = date(fromDayKey: window.startDayKey, calendar: calendar),
           let end = date(fromDayKey: window.endDayKey, calendar: calendar) {
            return (start, end)
        }
        let today = calendar.startOfDay(for: reference)
        return (
            detection.coverageStart(from: today, invoicing: invoicing, calendar: calendar),
            detection.coverageEnd(from: today, invoicing: invoicing, calendar: calendar)
        )
    }

    /// JSON array returned by a canonical row function. Nil means the script did not run.
    static func objectRows(function: String, payload: [String: Any]) -> [[String: Any]]? {
        guard JSONSerialization.isValidJSONObject(payload),
              let data = try? JSONSerialization.data(withJSONObject: payload),
              let json = String(data: data, encoding: .utf8),
              let value = evaluate("ProjectPlannerCanonical.\(function)(\(json))"),
              let raw = value.toArray() else {
            return nil
        }
        return raw.compactMap { item -> [String: Any]? in
            if let dict = item as? [String: Any] { return dict }
            guard let dict = item as? NSDictionary else { return nil }
            var out: [String: Any] = [:]
            for key in dict.allKeys {
                guard let name = key as? String, let value = dict[name] else { continue }
                out[name] = value
            }
            return out
        }
    }

    // MARK: - Standard day, AM and PM

    /// The organisation's AM and PM halves. Break-anchored when the unpaid break sits inside the
    /// day with at least an hour on each side; otherwise the wall-clock midpoint. Nil only when the
    /// script did not load. Memoised per distinct input because clash and sort loops call it often.
    static func halfDayWindows(_ input: CanonicalStandardDayInput) -> CanonicalHalfDayWindows? {
        halfDayMemo.value(for: input) {
            decode(CanonicalHalfDayWindows.self, function: "halfDayWindows", arguments: [input])
        }
    }

    /// The organisation's standard day, 07:30–16:00 when the stored pair is unparsable or inverted.
    static func standardDayWindow(_ input: CanonicalStandardDayInput) -> CanonicalMinuteInterval? {
        halfDayWindows(input)?.day
    }

    /// The unpaid break as set (12:00–12:30 for a field never set). Nil when the pair is not a window.
    static func standardBreakWindow(_ input: CanonicalStandardDayInput) -> CanonicalMinuteInterval? {
        decode(CanonicalMinuteInterval.self, function: "standardBreakWindow", arguments: [input])
    }

    /// `FULL_DAY`, `AM`, `PM`, `CUSTOM`, `EVENING`, `OVERTIME`, or `UNKNOWN` for any stored slot spelling.
    static func namedSlotKind(_ timeSlot: String?) -> String {
        decode(String.self, function: "namedSlotKind", arguments: [timeSlot]) ?? "UNKNOWN"
    }

    /// The clock interval a booking occupies. Explicit times win; named slots use the day and its
    /// halves; evening and overtime follow the day. Nil when the script has no interval for it.
    static func slotInterval(
        timeSlot: String?,
        workStartTime: String?,
        workEndTime: String?,
        day: CanonicalStandardDayInput
    ) -> CanonicalMinuteInterval? {
        let booking = SlotIntervalBooking(timeSlot: timeSlot, workStartTime: workStartTime, workEndTime: workEndTime)
        return slotIntervalMemo.value(for: SlotIntervalKey(booking: booking, day: day)) {
            decode(CanonicalMinuteInterval.self, function: "slotInterval", arguments: [booking, day])
        }
    }

    /// Sorted, merged copy of the intervals. Touching intervals join.
    static func mergeMinuteIntervals(_ intervals: [CanonicalMinuteInterval]) -> [CanonicalMinuteInterval]? {
        decode([CanonicalMinuteInterval].self, function: "mergeMinuteIntervals", arguments: [intervals])
    }

    /// The parts of `window` none of `covered` reaches.
    static func subtractMinuteIntervals(
        _ window: CanonicalMinuteInterval,
        covered: [CanonicalMinuteInterval]
    ) -> [CanonicalMinuteInterval]? {
        decode([CanonicalMinuteInterval].self, function: "subtractMinuteIntervals", arguments: [window, covered])
    }

    // MARK: - Annual leave against bookings

    /// Leave-clash and half-day-cover rows for approved leave inside the window.
    static func leaveCoverageRows(_ input: CanonicalLeaveCoverageInput) -> [CanonicalLeaveCoverageRow]? {
        decode([CanonicalLeaveCoverageRow].self, function: "leaveCoverageRows", arguments: [input])
    }

    /// `FULL_DAY`, `AM`, or `PM` for a leave record's slot.
    static func leaveSlotKind(_ timeSlot: String?) -> String {
        decode(String.self, function: "leaveSlotKind", arguments: [timeSlot]) ?? "FULL_DAY"
    }

    // MARK: - Dismissed warnings

    /// Key a dismissed qualification warning is stored under. Both apps store and read the same key.
    static func qualificationDismissKey(operativeId: String, qualificationId: String, expiryDayKey: String) -> String? {
        decode(String.self, function: "qualificationDismissKey", arguments: [operativeId, qualificationId, expiryDayKey])
    }

    /// Qualification rows minus the expired ones whose `dismissKey` is in `dismissedKeys`.
    static func withoutDismissedQualificationRows(
        _ rows: [[String: Any]],
        dismissedKeys: [String]
    ) -> [[String: Any]]? {
        guard let rowsJSON = jsonObjectFragment(rows), let keysJSON = jsonFragment(dismissedKeys) else { return nil }
        return objectRows(call: "withoutDismissedQualificationRows(\(rowsJSON), \(keysJSON))")
    }

    // MARK: - Script surface

    /// Names the packed script exports.
    static func exportNames() -> [String] {
        evaluate("Object.keys(ProjectPlannerCanonical)")?.toArray()?.compactMap { $0 as? String } ?? []
    }

    /// `typeof` for one export, or nil when the script did not load.
    static func exportKind(_ name: String) -> String? {
        guard let json = jsonFragment(name) else { return nil }
        return evaluate("typeof ProjectPlannerCanonical[\(json)]")?.toString()
    }

    /// A constant the script exports, decoded.
    static func constant<T: Decodable>(_ name: String, as type: T.Type) -> T? {
        guard let json = jsonFragment(name) else { return nil }
        return decodeExpression(type, "ProjectPlannerCanonical[\(json)]")
    }

    // MARK: - Call plumbing

    private struct SlotIntervalBooking: Codable, Hashable {
        var timeSlot: String?
        var workStartTime: String?
        var workEndTime: String?
    }

    private struct SlotIntervalKey: Hashable {
        let booking: SlotIntervalBooking
        let day: CanonicalStandardDayInput
    }

    /// Cache of script results keyed by the exact input. It stores what the script returned; it is
    /// not a second copy of the rule.
    private final class ResultMemo<Key: Hashable, Value>: @unchecked Sendable {
        private let lock = NSLock()
        private var store: [Key: Value] = [:]
        private let limit = 512

        func value(for key: Key, compute: () -> Value?) -> Value? {
            lock.lock()
            let hit = store[key]
            lock.unlock()
            if let hit { return hit }
            guard let value = compute() else { return nil }
            lock.lock()
            if store.count >= limit { store.removeAll(keepingCapacity: true) }
            store[key] = value
            lock.unlock()
            return value
        }
    }

    private static let halfDayMemo = ResultMemo<CanonicalStandardDayInput, CanonicalHalfDayWindows>()
    private static let slotIntervalMemo = ResultMemo<SlotIntervalKey, CanonicalMinuteInterval>()

    /// Calls `ProjectPlannerCanonical.function(arguments…)` and decodes the JSON of its result.
    /// A `null` or `undefined` result decodes as nil.
    private static func decode<T: Decodable>(_ type: T.Type, function: String, arguments: [Encodable?]) -> T? {
        var fragments: [String] = []
        for argument in arguments {
            guard let fragment = jsonFragment(argument) else { return nil }
            fragments.append(fragment)
        }
        return decodeExpression(type, "ProjectPlannerCanonical.\(function)(\(fragments.joined(separator: ", ")))")
    }

    private static func decodeExpression<T: Decodable>(_ type: T.Type, _ expression: String) -> T? {
        guard let value = evaluate("JSON.stringify(\(expression))"), value.isString,
              let text = value.toString(), text != "null", text != "undefined",
              let data = text.data(using: .utf8) else {
            return nil
        }
        return try? JSONDecoder().decode(type, from: data)
    }

    private static func objectRows(call: String) -> [[String: Any]]? {
        guard let value = evaluate("ProjectPlannerCanonical.\(call)"), let raw = value.toArray() else { return nil }
        return raw.compactMap { item -> [String: Any]? in
            if let dict = item as? [String: Any] { return dict }
            guard let dict = item as? NSDictionary else { return nil }
            var out: [String: Any] = [:]
            for key in dict.allKeys {
                guard let name = key as? String, let value = dict[name] else { continue }
                out[name] = value
            }
            return out
        }
    }

    /// JSON text for one `Encodable` argument. `nil` becomes `null`.
    private static func jsonFragment(_ value: Encodable?) -> String? {
        guard let value else { return "null" }
        switch value {
        case let scalar as String:
            return jsonObjectFragment(scalar)
        case let scalar as Bool:
            return jsonObjectFragment(scalar)
        case let scalar as Int:
            return jsonObjectFragment(scalar)
        case let scalar as Double:
            return jsonObjectFragment(scalar)
        default:
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.withoutEscapingSlashes]
            guard let data = try? encoder.encode(AnyEncodable(value)) else { return nil }
            return String(data: data, encoding: .utf8)
        }
    }

    /// JSON text for a plain JSON value (dictionary rows, arrays, or a scalar).
    private static func jsonObjectFragment(_ object: Any) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.fragmentsAllowed]) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    private struct AnyEncodable: Encodable {
        let value: Encodable
        init(_ value: Encodable) { self.value = value }
        func encode(to encoder: Encoder) throws { try value.encode(to: encoder) }
    }

    static func isoString(from date: Date) -> String {
        scriptLock.lock()
        defer { scriptLock.unlock() }
        return iso8601.string(from: date)
    }

    static func date(fromDayKey key: String, calendar: Calendar = businessCalendar) -> Date? {
        let parts = key.split(separator: "-")
        guard parts.count == 3,
              let year = Int(parts[0]),
              let month = Int(parts[1]),
              let day = Int(parts[2]) else {
            return nil
        }
        var components = DateComponents()
        components.calendar = calendar
        components.timeZone = calendar.timeZone
        components.year = year
        components.month = month
        components.day = day
        return calendar.date(from: components).map { calendar.startOfDay(for: $0) }
    }

    private static func evaluate(_ source: String) -> JSValue? {
        scriptLock.lock()
        defer { scriptLock.unlock() }
        guard let context else { return nil }
        context.exception = nil
        let value = context.evaluateScript(source)
        if context.exception != nil {
            NSLog("Canonical business script error: %@", context.exception?.toString() ?? "")
            context.exception = nil
            return nil
        }
        return value
    }

    private static let iso8601: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()
}
