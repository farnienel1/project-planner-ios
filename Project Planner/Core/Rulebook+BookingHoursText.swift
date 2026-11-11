//
//  Rulebook+BookingHoursText.swift
//  Project Planner
//
//  RULEBOOK 1.39.0 (owner answers 11 Nov): typed wrappers for the booking hours labels (web
//  `lib/canonical/bookingHoursText.ts`) and the My Schedule clash marker (`lib/canonical/myScheduleClash.ts`).
//  Wording only: every figure is the pay rule's (`payrollHoursResult` / `payrollMultipliedHours`) and every break word
//  comes from the working hours in effect on that day. Swift maps inputs and shows results; nothing is decided here.
//

import Foundation

/// RULEBOOK 1.39.0 `bookingBreakText` → `{ minutes, window, paid, label, deducted }`.
nonisolated struct RulebookBookingBreakText: Equatable, Hashable, Sendable {
    let minutes: Int
    let window: String
    let paid: Bool
    /// "30 min unpaid break 11:30–12:00" or "30 min paid break 11:30–12:00 (not deducted)".
    let label: String
    /// "30 mins deducted 11:30–12:00" (the paid label when the break is paid).
    let deducted: String

    init?(json: Any?) {
        guard let row = json as? [String: Any],
              let label = row["label"] as? String,
              let deducted = row["deducted"] as? String else { return nil }
        self.minutes = (row["minutes"] as? NSNumber)?.intValue ?? 0
        self.window = row["window"] as? String ?? ""
        self.paid = row["paid"] as? Bool ?? false
        self.label = label
        self.deducted = deducted
    }
}

/// RULEBOOK 1.39.0 `bookingHoursTiles` → `{ kind, value, label, paidHours }[]` ("9" "Standard (−0.5 break)", "6" "OT").
nonisolated struct RulebookBookingHoursTile: Equatable, Hashable, Sendable, Identifiable {
    /// `standard` or `overtime`.
    let kind: String
    let value: String
    let label: String
    let paidHours: Double
    var id: String { kind }

    init?(json: Any?) {
        guard let row = json as? [String: Any],
              let kind = row["kind"] as? String,
              let value = row["value"] as? String,
              let label = row["label"] as? String else { return nil }
        self.kind = kind
        self.value = value
        self.label = label
        self.paidHours = (row["paidHours"] as? NSNumber)?.doubleValue ?? 0
    }
}

/// RULEBOOK 1.39.0 §10 `myScheduleClashMarkers` row.
nonisolated struct RulebookMyScheduleClashMarker: Equatable, Hashable, Sendable {
    let bookingId: String
    /// `clash` (red) or `approved` (grey).
    let state: String
    let otherBookingIds: [String]
    let canOpenWarnings: Bool
    let title: String
    let message: String
    /// "Open Warnings", or nil (Close only).
    let actionLabel: String?

    var isApproved: Bool { state == "approved" }

    init?(json: Any?) {
        guard let row = json as? [String: Any],
              let bookingId = row["bookingId"] as? String,
              let state = row["state"] as? String,
              let title = row["title"] as? String,
              let message = row["message"] as? String else { return nil }
        self.bookingId = bookingId
        self.state = state
        self.otherBookingIds = row["otherBookingIds"] as? [String] ?? []
        self.canOpenWarnings = row["canOpenWarnings"] as? Bool ?? false
        self.title = title
        self.message = message
        self.actionLabel = row["actionLabel"] as? String
    }
}

/// A script answer carried through `memoCallJSON`.
nonisolated struct RulebookAnyBox: @unchecked Sendable {
    let value: Any
}

extension CanonicalBusinessEngine {
    nonisolated private static let answerMemo = RulebookAnswerMemo<String, RulebookAnyBox>(limit: 512)

    /// RULEBOOK 1.39.0 (review 11 Nov): one script call per distinct input. Screens ask these rules on every render
    /// (explanations, the shortfall line, clash markers); the answer depends only on the arguments, so it is kept by
    /// their JSON. Arguments that are not JSON are not memoised. Nil answers are never kept.
    nonisolated static func memoCallJSON(_ function: String, arguments: [Any]) -> Any? {
        guard JSONSerialization.isValidJSONObject(arguments),
              let data = try? JSONSerialization.data(withJSONObject: arguments, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8) else {
            return callJSON(function, arguments: arguments)
        }
        return answerMemo.value(for: function + "|" + text) {
            callJSON(function, arguments: arguments).map(RulebookAnyBox.init(value:))
        }?.value
    }

    // MARK: Labels (1.39.0 §4.3)

    /// `overtimeTotalText`: "12h OT × 1.5 = 18h" (Daily Overview's overtime tile); nil with no overtime.
    nonisolated static func overtimeTotalText(clockHours: Double, multiplier: Double, breakHours: Double = 0) -> String? {
        let text = callJSON("overtimeTotalText", arguments: [[
            "clockHours": clockHours, "multiplier": multiplier, "breakHours": breakHours,
        ]]) as? String
        return (text?.isEmpty ?? true) ? nil : text
    }

    /// `overtimeIncludedText`: "incl. 6h OT × 1.5 = 9h" (under My Schedule's total); nil with no overtime.
    nonisolated static func overtimeIncludedText(clockHours: Double, multiplier: Double, breakHours: Double = 0) -> String? {
        let text = callJSON("overtimeIncludedText", arguments: [[
            "clockHours": clockHours, "multiplier": multiplier, "breakHours": breakHours,
        ]]) as? String
        return (text?.isEmpty ?? true) ? nil : text
    }

    /// `bookedWithOvertimeText`: "60.5h booked (incl. 12h OT × 1.5)"; a nil multiplier (several rates) leaves it out.
    nonisolated static func bookedWithOvertimeText(bookedHours: Double, clockHours: Double, multiplier: Double?) -> String? {
        callJSON("bookedWithOvertimeText", arguments: [[
            "bookedHours": bookedHours, "clockHours": clockHours, "multiplier": multiplier.map { $0 as Any } ?? NSNull(),
        ]]) as? String
    }

    /// `bookingHoursCountText`: "17.5 hours" (never "17.5h paid").
    nonisolated static func bookingHoursCountText(_ hours: Double) -> String? {
        callJSON("bookingHoursCountText", arguments: [hours]) as? String
    }

    /// `saveHoursLabel`: "Save · 17.5 hours".
    nonisolated static func saveHoursLabel(_ hours: Double) -> String? {
        callJSON("saveHoursLabel", arguments: [hours]) as? String
    }

    /// The policy argument the 1.39.0 day rules take: the organisation's policy state when loaded (each day read under
    /// the working hours in effect on it), else `fallbackPolicy`.
    nonisolated static func dayPolicyArgument(fallbackPolicy: OrgPayrollTimePolicy, timeZone: String) -> Any? {
        if let document = OrganizationRulebookContext.payrollPolicyDocument,
           let state = memoCallJSON(
            "payrollTimePolicyTimeline",
            arguments: [document, organizationDayKey(Date(), timeZoneIdentifier: timeZone), timeZone]
           ) as? [String: Any] {
            return state
        }
        return payrollPolicyJSON(fallbackPolicy)
    }

    /// `bookingBreakText(policyOrState, dayKey, timeZone)`: that day's own lunch break in words. Nil when the day has none.
    nonisolated static func bookingBreakText(
        on date: Date,
        fallbackPolicy: OrgPayrollTimePolicy,
        timeZone: String = OrganizationRulebookContext.timeZoneIdentifier
    ) -> RulebookBookingBreakText? {
        guard let policy = dayPolicyArgument(fallbackPolicy: fallbackPolicy, timeZone: timeZone) else { return nil }
        return RulebookBookingBreakText(json: memoCallJSON("bookingBreakText", arguments: [policy, bookingDayKey(date), timeZone]))
    }

    /// `bookingHoursTiles(policyOrState, dayKey, booking, timeZone)`: the Edit booking tiles (standard with the break on
    /// it, overtime). `[]` when nothing answered.
    nonisolated static func bookingHoursTiles(
        on date: Date,
        start: String,
        end: String,
        isBreakRemoved: Bool,
        otMultiplierOverride: Double? = nil,
        fallbackPolicy: OrgPayrollTimePolicy,
        timeZone: String = OrganizationRulebookContext.timeZoneIdentifier
    ) -> [RulebookBookingHoursTile] {
        guard let policy = dayPolicyArgument(fallbackPolicy: fallbackPolicy, timeZone: timeZone) else { return [] }
        var booking: [String: Any] = [
            "timeSlot": "CUSTOM_HOURS", "workStartTime": start, "workEndTime": end, "isBreakRemoved": isBreakRemoved,
        ]
        if let otMultiplierOverride { booking["otMultiplierOverride"] = otMultiplierOverride }
        let rows = memoCallJSON("bookingHoursTiles", arguments: [policy, bookingDayKey(date), booking, timeZone]) as? [Any] ?? []
        return rows.compactMap(RulebookBookingHoursTile.init(json:))
    }

    /// RULEBOOK 1.39.0 (review) `bookingBreakDeductionText`: what the unpaid break takes off this booking — "30 mins
    /// deducted 11:30–12:00", "15 mins deducted (11:30–11:45 covered)"; nil when nothing comes off.
    nonisolated static func bookingBreakDeductionText(
        on date: Date,
        start: String,
        end: String,
        isBreakRemoved: Bool,
        fallbackPolicy: OrgPayrollTimePolicy,
        timeZone: String = OrganizationRulebookContext.timeZoneIdentifier
    ) -> String? {
        guard let policy = dayPolicyArgument(fallbackPolicy: fallbackPolicy, timeZone: timeZone) else { return nil }
        let booking: [String: Any] = [
            "timeSlot": "CUSTOM_HOURS", "workStartTime": start, "workEndTime": end, "isBreakRemoved": isBreakRemoved,
        ]
        return memoCallJSON("bookingBreakDeductionText", arguments: [policy, bookingDayKey(date), booking, timeZone]) as? String
    }

    // MARK: My Schedule clash marker (1.39.0 §10)

    /// `myScheduleClashMarkers(input)`: the markers for the viewer's own bookings, keyed by booking id (upper case, as
    /// iOS ids are stored). `input` is the Warnings clash payload (`operativeBookings`, `managerBookings`, `people`,
    /// `managerIds`, `day`) plus `decisions` (nil while the approvals have not loaded — nothing reads approved),
    /// `canOpenWarnings`, `viewerIds` and `viewerEmail`. Empty when the script did not answer.
    nonisolated static func myScheduleClashMarkers(_ input: [String: Any]) -> [String: RulebookMyScheduleClashMarker] {
        let rows = memoCallJSON("myScheduleClashMarkers", arguments: [input]) as? [Any] ?? []
        var out: [String: RulebookMyScheduleClashMarker] = [:]
        for row in rows {
            guard let marker = RulebookMyScheduleClashMarker(json: row) else { continue }
            out[marker.bookingId.uppercased()] = marker
        }
        return out
    }
}
