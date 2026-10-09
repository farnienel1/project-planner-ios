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

    struct CanonicalPaymentRunRange: Codable, Equatable, Sendable {
        var startDay: Int
        var endDay: Int
    }

    struct CanonicalWarningDetection: Codable, Equatable, Sendable {
        var detectClashes: Bool
        var clashLookaheadMode: String
        var clashLookaheadDays: Int
        var includeWeekendsForUnbookedLabour: Bool
        var excludedUserIdsFromUnbookedWarnings: [String]
    }

    /// `startDay` then `startDate`, `endDay` then `endDate`. Empty input is 1–15 then 16–31.
    static func parsePaymentRunDateRanges(_ data: [String: Any]?) -> [CanonicalPaymentRunRange]? {
        let json = data.flatMap(jsonObjectFragment) ?? "null"
        return decodeExpression(
            [CanonicalPaymentRunRange].self,
            "ProjectPlannerCanonical.parsePaymentRunDateRanges(\(json))"
        )
    }

    /// Top-level `warningDetection`. Nil data is the script default (7 days, clashes on, weekends off).
    static func parseWarningDetection(_ data: [String: Any]?) -> CanonicalWarningDetection? {
        let json = data.flatMap(jsonObjectFragment) ?? "null"
        return decodeExpression(
            CanonicalWarningDetection.self,
            "ProjectPlannerCanonical.parseWarningDetection(\(json))"
        )
    }

    /// The map written to `organizations/{orgId}.warningDetection`. Not nested under `settings`.
    static func warningDetectionToFirestore(_ settings: CanonicalWarningDetection) -> [String: Any]? {
        guard let json = jsonFragment(settings) else { return nil }
        return objectDictionary("ProjectPlannerCanonical.warningDetectionToFirestore(\(json))")
    }

    struct CanonicalInvoicingSettings: Codable, Equatable, Sendable {
        var paymentRunMode: String
        var paymentDateMode: String
        var recurringRunStartDay: String
        var recurringRunEndDay: String
        var recurringPaymentDay: String
        var paymentRunDateRanges: [CanonicalPaymentRunRange]
        var paymentDates: [String]
        var noteToUsers: String
    }

    /// Web `startDay`/`endDay`, then older iOS `startDate`/`endDate`. Missing ranges are 1–15 and 16–31.
    static func parseInvoicing(_ data: [String: Any]?) -> CanonicalInvoicingSettings? {
        let json = data.flatMap(jsonObjectFragment) ?? "null"
        return decodeExpression(
            CanonicalInvoicingSettings.self,
            "ProjectPlannerCanonical.parseInvoicing(\(json))"
        )
    }

    /// Both day-field pairs on every payment-run row, plus the rest of the invoicing map web writes.
    static func invoicingToFirestore(_ settings: CanonicalInvoicingSettings) -> [String: Any]? {
        guard let json = jsonFragment(settings) else { return nil }
        return objectDictionary("ProjectPlannerCanonical.invoicingToFirestore(\(json))")
    }

    static func paymentRunRangeToFirestore(startDay: Int, endDay: Int) -> [String: Any]? {
        objectDictionary("ProjectPlannerCanonical.paymentRunRangeToFirestore({ startDay: \(startDay), endDay: \(endDay) })")
    }

    /// `nil` when the script accepts the settings. A string is the reason to refuse the save.
    static func validateInvoicingSettings(_ settings: CanonicalInvoicingSettings) -> String? {
        guard let json = jsonFragment(settings) else {
            return "Could not check these payment run settings."
        }
        guard let value = evaluate("JSON.stringify(ProjectPlannerCanonical.validateInvoicingSettings(\(json)))"),
              value.isString,
              let text = value.toString() else {
            return "Could not check these payment run settings."
        }
        if text == "null" { return nil }
        guard let data = text.data(using: .utf8),
              let message = try? JSONDecoder().decode(String.self, from: data),
              !message.isEmpty else {
            return "Could not check these payment run settings."
        }
        return message
    }

    /// The web unbooked scan adds Saturday and Sunday after `coverageWindow` when the horizon is a working week.
    /// The coverage window itself stays Monday–Friday.
    static func unbookedLabourWindowEnd(
        coverageEnd: Date,
        clashLookaheadMode: String,
        includeWeekends: Bool,
        calendar: Calendar = businessCalendar
    ) -> Date {
        let end = calendar.startOfDay(for: coverageEnd)
        guard includeWeekends, clashLookaheadMode == WarningClashLookaheadMode.endOfWorkingWeek.rawValue else {
            return end
        }
        let weekday = calendar.component(.weekday, from: end)
        let iso = weekday == 1 ? 7 : weekday - 1
        guard (1...5).contains(iso) else { return end }
        return calendar.date(byAdding: .day, value: 7 - iso, to: end) ?? end
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

    // MARK: - User profile

    struct CanonicalStaffAccountRole: Codable, Hashable, Sendable {
        var isSuperAdmin: Bool
        var isAdmin: Bool
        var isManager: Bool
        var isOperativeMode: Bool
    }

    struct CanonicalEmploymentChange: Equatable, Sendable {
        var employmentType: String
        var employmentTypeTransitionFrom: String?
        var employmentTypeEffectiveAt: Date?
    }

    /// `paye` or `self_employed`. `selfEmployed` is accepted on read only.
    static func normalizeEmploymentType(_ raw: String?) -> String? {
        decode(String.self, function: "normalizeEmploymentType", arguments: [raw])
    }

    static func employmentTypeOnDay(
        employmentType: String?,
        transitionFrom: String?,
        effectiveAt: Date?,
        date: Date,
        timeZone: String = "Europe/London"
    ) -> String? {
        let user = CanonicalEmploymentUser(
            employmentType: employmentType,
            employmentTypeTransitionFrom: transitionFrom,
            employmentTypeEffectiveAt: effectiveAt.map { isoString(from: $0) }
        )
        return decode(String.self, function: "employmentTypeOnDay", arguments: [user, isoString(from: date), timeZone])
    }

    static func isBillableSelfEmployedDay(
        employmentType: String?,
        transitionFrom: String?,
        effectiveAt: Date?,
        date: Date,
        timeZone: String = "Europe/London"
    ) -> Bool {
        let user = CanonicalEmploymentUser(
            employmentType: employmentType,
            employmentTypeTransitionFrom: transitionFrom,
            employmentTypeEffectiveAt: effectiveAt.map { isoString(from: $0) }
        )
        return decode(Bool.self, function: "isBillableSelfEmployedDay", arguments: [user, isoString(from: date), timeZone]) ?? false
    }

    /// `effectiveAt == nil` is the script's immediate change: the new type is stored and the transition is cleared.
    static func applyEmploymentTypeChange(
        previousType: String?,
        nextType: String,
        previousTransitionFrom: String?,
        previousEffectiveAt: Date?,
        effectiveAt: Date?,
        now: Date = Date(),
        timeZone: String = "Europe/London"
    ) -> CanonicalEmploymentChange? {
        let payload = CanonicalEmploymentChangeInput(
            previousType: previousType,
            nextType: nextType,
            previousTransitionFrom: previousTransitionFrom,
            previousEffectiveAt: previousEffectiveAt.map { isoString(from: $0) },
            effectiveAt: effectiveAt.map { isoString(from: $0) } ?? "immediate",
            now: isoString(from: now),
            timeZone: timeZone
        )
        guard let payloadJSON = jsonFragment(payload) else { return nil }
        let expression = """
        (() => {
          const input = \(payloadJSON);
          const asDate = (value) => (typeof value === "string" && value !== "immediate" ? new Date(value) : value);
          input.now = asDate(input.now);
          input.previousEffectiveAt = asDate(input.previousEffectiveAt);
          input.effectiveAt = asDate(input.effectiveAt);
          return ProjectPlannerCanonical.applyEmploymentTypeChange(input);
        })()
        """
        guard let decoded = decodeExpression(CanonicalEmploymentChangeWire.self, expression) else {
            return nil
        }
        return CanonicalEmploymentChange(
            employmentType: decoded.employmentType,
            employmentTypeTransitionFrom: decoded.employmentTypeTransitionFrom,
            employmentTypeEffectiveAt: parseScriptDate(decoded.employmentTypeEffectiveAt)
        )
    }

    static func employmentEffectiveLabel(
        employmentType: String?,
        transitionFrom: String?,
        effectiveAt: Date?,
        now: Date = Date(),
        timeZone: String = "Europe/London"
    ) -> String? {
        let user = CanonicalEmploymentUser(
            employmentType: employmentType,
            employmentTypeTransitionFrom: transitionFrom,
            employmentTypeEffectiveAt: effectiveAt.map { isoString(from: $0) }
        )
        guard let userJSON = jsonFragment(user), let nowJSON = jsonFragment(isoString(from: now)), let zoneJSON = jsonFragment(timeZone) else {
            return nil
        }
        let expression = """
        (() => {
          const user = \(userJSON);
          if (typeof user.employmentTypeEffectiveAt === "string") user.employmentTypeEffectiveAt = new Date(user.employmentTypeEffectiveAt);
          return ProjectPlannerCanonical.employmentEffectiveLabel(user, new Date(\(nowJSON)), \(zoneJSON));
        })()
        """
        return decodeExpression(String.self, expression)
    }

    /// `operative`, `manager`, or `admin`.
    static func accountKindFromFlags(
        isSuperAdmin: Bool,
        role: String?,
        adminAccess: Bool,
        manager: Bool,
        operativeMode: Bool
    ) -> String? {
        let flags = CanonicalAccountFlags(
            isSuperAdmin: isSuperAdmin,
            role: role,
            adminAccess: adminAccess,
            manager: manager,
            operativeMode: operativeMode
        )
        return decode(String.self, function: "accountKindFromFlags", arguments: [flags])
    }

    static func canViewStaffWarnings(_ role: CanonicalStaffAccountRole) -> Bool {
        decode(Bool.self, function: "canViewStaffWarnings", arguments: [role]) ?? false
    }

    static func isStaffAccount(_ role: CanonicalStaffAccountRole) -> Bool {
        decode(Bool.self, function: "isStaffAccount", arguments: [role]) ?? false
    }

    static func seesEveryJob(_ role: CanonicalStaffAccountRole) -> Bool {
        decode(Bool.self, function: "seesEveryJob", arguments: [role]) ?? false
    }

    /// Every admin and every manager. Operative mode wins over a stale admin or manager flag.
    static func canSeeVariations(_ role: CanonicalStaffAccountRole) -> Bool {
        decode(Bool.self, function: "canSeeVariations", arguments: [role]) ?? false
    }

    /// Admin and super admin only. Managers see variations; they do not manage the tracker.
    static func canManageVariationTracker(_ role: CanonicalStaffAccountRole) -> Bool {
        decode(Bool.self, function: "canManageVariationTracker", arguments: [role]) ?? false
    }

    static func canEditWorkCatalogue(
        _ role: CanonicalStaffAccountRole,
        catalogue: String,
        projects: Bool,
        smallWorks: Bool
    ) -> Bool {
        struct Toggles: Codable {
            var projects: Bool
            var smallWorks: Bool
        }
        return decode(
            Bool.self,
            function: "canEditWorkCatalogue",
            arguments: [role, catalogue, Toggles(projects: projects, smallWorks: smallWorks)]
        ) ?? false
    }

    static func receivesJobNotification(
        userId: String,
        role: CanonicalStaffAccountRole,
        assignedManagerUserIds: [String],
        lineManagerUserIds: [String] = []
    ) -> Bool {
        struct Input: Codable {
            var userId: String
            var role: CanonicalStaffAccountRole
            var assignedManagerUserIds: [String]
            var lineManagerUserIds: [String]
        }
        return decode(
            Bool.self,
            function: "receivesJobNotification",
            arguments: [Input(
                userId: userId,
                role: role,
                assignedManagerUserIds: assignedManagerUserIds,
                lineManagerUserIds: lineManagerUserIds
            )]
        ) ?? false
    }

    // MARK: - Annual leave allowance

    struct CanonicalAnnualLeaveAllowanceCopy: Codable, Equatable, Sendable {
        var toggleTitle: String
        var toggleDescription: String
        var toggleNote: String
        var remainingTitle: String
        var remainingNote: String
    }

    struct CanonicalLeaveYearBounds: Codable, Equatable, Sendable {
        var startDayKey: String
        var endDayKey: String
        var yearKey: String
    }

    struct CanonicalLeaveBooking: Codable, Equatable, Sendable {
        var startDayKey: String
        var endDayKey: String
        var timeSlot: String?
        var status: String?
    }

    struct CanonicalAnnualLeaveBalance: Codable, Equatable, Sendable {
        var hasAllowance: Bool
        var startDayKey: String
        var endDayKey: String
        var yearKey: String
        var taken: Double
        var pending: Double
        var usedThisYear: Double
        var daysPerYear: Double
        var carriedForward: Double
        var yearAllowance: Double?
        var remaining: Double?
    }

    struct CanonicalRemainingOverride: Codable, Equatable, Sendable {
        var annualLeaveYearAllowance: Double
        var annualLeaveYearAllowanceKey: String
    }

    static func annualLeaveAllowanceCopy() -> CanonicalAnnualLeaveAllowanceCopy? {
        constant("ANNUAL_LEAVE_ALLOWANCE_COPY", as: CanonicalAnnualLeaveAllowanceCopy.self)
    }

    static func hasAnnualLeaveAllowance(_ enabled: Bool?) -> Bool {
        decode(Bool.self, function: "hasAnnualLeaveAllowance", arguments: [enabled]) ?? (enabled != false)
    }

    static func snapLeaveDays(_ value: Double) -> Double {
        decode(Double.self, function: "snapLeaveDays", arguments: [value]) ?? value
    }

    static func leaveYearBounds(startMonth: Int?, endMonth: Int?, onDayKey: String) -> CanonicalLeaveYearBounds? {
        let input = CanonicalLeaveYearInput(startMonth: startMonth, endMonth: endMonth, onDayKey: onDayKey)
        return decode(CanonicalLeaveYearBounds.self, function: "leaveYearBounds", arguments: [input])
    }

    static func annualLeaveBalance(
        annualLeaveEnabled: Bool?,
        daysPerYear: Double?,
        startMonth: Int?,
        endMonth: Int?,
        orgDaysPerYear: Double?,
        orgStartMonth: Int?,
        orgEndMonth: Int?,
        carriesOver: Bool?,
        yearAllowance: Double?,
        yearAllowanceKey: String?,
        bookings: [CanonicalLeaveBooking],
        onDayKey: String,
        timeZone: String = "Europe/London"
    ) -> CanonicalAnnualLeaveBalance? {
        let input = CanonicalAnnualLeaveBalanceInput(
            annualLeaveEnabled: annualLeaveEnabled,
            daysPerYear: daysPerYear,
            startMonth: startMonth,
            endMonth: endMonth,
            orgDaysPerYear: orgDaysPerYear,
            orgStartMonth: orgStartMonth,
            orgEndMonth: orgEndMonth,
            carriesOver: carriesOver,
            yearAllowance: yearAllowance,
            yearAllowanceKey: yearAllowanceKey,
            bookings: bookings,
            onDayKey: onDayKey,
            timeZone: timeZone
        )
        return decode(CanonicalAnnualLeaveBalance.self, function: "annualLeaveBalance", arguments: [input])
    }

    static func applyRemainingOverride(remaining: Double, taken: Double, pending: Double, yearKey: String) -> CanonicalRemainingOverride? {
        let input = CanonicalRemainingOverrideInput(remaining: remaining, taken: taken, pending: pending, yearKey: yearKey)
        return decode(CanonicalRemainingOverride.self, function: "applyRemainingOverride", arguments: [input])
    }

    static func dayKey(for date: Date, calendar: Calendar = businessCalendar) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 1970, parts.month ?? 1, parts.day ?? 1)
    }

    // MARK: - Material search

    struct CanonicalMaterialRecord: Codable, Equatable, Sendable {
        var name: String
        var brand: String
        var productCode: String
        var category: String
        var size: String
        var length: String

        init(
            name: String = "",
            brand: String = "",
            productCode: String = "",
            category: String = "",
            size: String = "",
            length: String = ""
        ) {
            self.name = name
            self.brand = brand
            self.productCode = productCode
            self.category = category
            self.size = size
            self.length = length
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
            brand = try container.decodeIfPresent(String.self, forKey: .brand) ?? ""
            productCode = try container.decodeIfPresent(String.self, forKey: .productCode) ?? ""
            category = try container.decodeIfPresent(String.self, forKey: .category) ?? ""
            size = try container.decodeIfPresent(String.self, forKey: .size) ?? ""
            length = try container.decodeIfPresent(String.self, forKey: .length) ?? ""
        }
    }

    struct CanonicalMaterialSearchHit: Codable, Equatable, Sendable {
        var index: Int
        var score: Double
    }

    static func tokenizeMaterialSearch(_ query: String) -> [String] {
        decode([String].self, function: "tokenizeMaterialSearch", arguments: [query]) ?? []
    }

    static func normalizeMaterialSearchText(_ value: String) -> String {
        decode(String.self, function: "normalizeMaterialSearchText", arguments: [value]) ?? ""
    }

    static func materialSearchScore(query: String, record: CanonicalMaterialRecord) -> Double {
        decode(Double.self, function: "materialSearchScore", arguments: [query, record]) ?? 0
    }

    static func materialRecordMatches(query: String, record: CanonicalMaterialRecord) -> Bool {
        decode(Bool.self, function: "materialRecordMatches", arguments: [query, record]) ?? false
    }

    static func catalogueRecordFromItem(_ item: CanonicalMaterialRecord) -> CanonicalMaterialRecord? {
        decode(CanonicalMaterialRecord.self, function: "catalogueRecordFromItem", arguments: [item])
    }

    /// Indexes from `rankMaterialRecords`. Nil means the script did not run.
    /// `limit` of nil or 0 returns every hit. An empty query returns every index in the original order.
    /// `cacheIdentity` keeps that record list in the script between keystrokes. Pass the same
    /// identity only when `records` is the same list. A nil identity installs the list every call.
    static func rankMaterialRecords(
        query: String,
        records: [CanonicalMaterialRecord],
        limit: Int? = nil,
        cacheIdentity: Int? = nil
    ) -> [CanonicalMaterialSearchHit]? {
        if !installMaterialSearchRecords(records, cacheIdentity: cacheIdentity) {
            return nil
        }
        guard let queryJSON = jsonFragment(query) else { return nil }
        let call: String
        if let limit, limit > 0 {
            call = "ProjectPlannerCanonical.rankMaterialRecords(\(queryJSON), ProjectPlannerCanonical.__materialSearchRecords, \(limit))"
        } else {
            call = "ProjectPlannerCanonical.rankMaterialRecords(\(queryJSON), ProjectPlannerCanonical.__materialSearchRecords)"
        }
        return decodeExpression([CanonicalMaterialSearchHit].self, call)
    }

    /// Puts `records` in the script once for this identity. Later searches with the same identity
    /// only send the query.
    @discardableResult
    static func installMaterialSearchRecords(
        _ records: [CanonicalMaterialRecord],
        cacheIdentity: Int?
    ) -> Bool {
        if let cacheIdentity, cacheIdentity == installedMaterialSearchIdentity { return true }
        guard let json = jsonFragment(records),
              evaluate("ProjectPlannerCanonical.__materialSearchRecords = \(json); true")?.toBool() == true else {
            return false
        }
        installedMaterialSearchIdentity = cacheIdentity
        return true
    }

    private static var installedMaterialSearchIdentity: Int?
    private static var materialSearchIdentitySerial = 0

    /// An identity that will not collide with another catalogue list in this process.
    static func makeMaterialSearchCacheIdentity() -> Int {
        materialSearchIdentitySerial &+= 1
        return materialSearchIdentitySerial
    }

    /// Applies the script's indexes. Does not score or drop rows itself.
    static func rankedItems<T>(
        _ items: [T],
        query: String,
        limit: Int? = nil,
        cacheIdentity: Int? = nil,
        record: (T) -> CanonicalMaterialRecord
    ) -> [T] {
        let records = items.map(record)
        guard let hits = rankMaterialRecords(
            query: query,
            records: records,
            limit: limit,
            cacheIdentity: cacheIdentity
        ) else { return [] }
        return hits.compactMap { hit in
            items.indices.contains(hit.index) ? items[hit.index] : nil
        }
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

    private struct CanonicalLeaveYearInput: Codable {
        var startMonth: Int?
        var endMonth: Int?
        var onDayKey: String
    }

    private struct CanonicalAnnualLeaveBalanceInput: Codable {
        var annualLeaveEnabled: Bool?
        var daysPerYear: Double?
        var startMonth: Int?
        var endMonth: Int?
        var orgDaysPerYear: Double?
        var orgStartMonth: Int?
        var orgEndMonth: Int?
        var carriesOver: Bool?
        var yearAllowance: Double?
        var yearAllowanceKey: String?
        var bookings: [CanonicalLeaveBooking]
        var onDayKey: String
        var timeZone: String
    }

    private struct CanonicalRemainingOverrideInput: Codable {
        var remaining: Double
        var taken: Double
        var pending: Double
        var yearKey: String
    }

    private struct CanonicalEmploymentUser: Codable {
        var employmentType: String?
        var employmentTypeTransitionFrom: String?
        var employmentTypeEffectiveAt: String?
    }

    private struct CanonicalEmploymentChangeInput: Codable {
        var previousType: String?
        var nextType: String?
        var previousTransitionFrom: String?
        var previousEffectiveAt: String?
        var effectiveAt: String
        var now: String
        var timeZone: String
    }

    private struct CanonicalEmploymentChangeWire: Codable {
        var employmentType: String
        var employmentTypeTransitionFrom: String?
        var employmentTypeEffectiveAt: String?
    }

    private struct CanonicalAccountFlags: Codable {
        var isSuperAdmin: Bool
        var role: String?
        var adminAccess: Bool
        var manager: Bool
        var operativeMode: Bool
    }

    private static func parseScriptDate(_ text: String?) -> Date? {
        guard let text, !text.isEmpty else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: text) { return date }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: text)
    }

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

    private static func objectDictionary(_ expression: String) -> [String: Any]? {
        guard let value = evaluate("JSON.stringify(\(expression))"), value.isString,
              let text = value.toString(), text != "null", text != "undefined",
              let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return object
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
