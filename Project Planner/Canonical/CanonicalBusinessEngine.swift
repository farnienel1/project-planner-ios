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

/// One account `unbookedLabourRows` considers (`LabourPerson` in the script).
nonisolated struct CanonicalUnbookedLabourPerson: Codable, Equatable, Sendable {
    var id: String
    var email: String
    var name: String
    var isActive: Bool
    var passwordSet: Bool
    var isOperativeMode: Bool
    var isManager: Bool
    var isAdmin: Bool
    var isSuperAdmin: Bool
    var status: String? = nil
}

/// One roster profile (`RosterOperative` in the script).
nonisolated struct CanonicalUnbookedLabourOperative: Codable, Equatable, Sendable {
    var id: String
    var email: String
    var name: String
    var isActive: Bool
    var isPlaceholder: Bool
    var profileWeight: Int
}

/// One booking counted toward the standard day (`LabourBooking` in the script).
nonisolated struct CanonicalUnbookedLabourBooking: Codable, Equatable, Sendable {
    var personId: String
    var dayKey: String
    var kind: String
    var timeSlot: String?
    var workStart: String?
    var workEnd: String?
}

/// One holiday the unbooked scan can treat as cover (`LabourHoliday` in the script).
nonisolated struct CanonicalUnbookedLabourHoliday: Codable, Equatable, Sendable {
    var userId: String?
    var operativeId: String?
    var startDayKey: String
    var endDayKey: String
    var approved: Bool
}

/// Payload for `unbookedLabourRows` (`UnbookedLabourInput` in the script).
nonisolated struct CanonicalUnbookedLabourInput: Codable, Equatable, Sendable {
    var timeZone: String
    var startDayKey: String
    var endDayKey: String
    var includeWeekends: Bool
    var excludedUserIds: [String]
    var standardPaidHours: Double
    var saturdayCountsAsHours: Double
    var sundayCountsAsHours: Double
    var standardDayStart: String
    var standardDayEnd: String
    var breakWindowStart: String
    var breakWindowEnd: String
    var people: [CanonicalUnbookedLabourPerson]
    var operatives: [CanonicalUnbookedLabourOperative]
    var bookings: [CanonicalUnbookedLabourBooking]
    var holidays: [CanonicalUnbookedLabourHoliday]
}

/// Payload for `unbookedLabourRowsOnDay`. The script sets the window to `dayKey`.
nonisolated struct CanonicalUnbookedLabourDayInput: Codable, Equatable, Sendable {
    var timeZone: String
    var dayKey: String
    var includeWeekends: Bool
    var excludedUserIds: [String]
    var standardPaidHours: Double
    var saturdayCountsAsHours: Double
    var sundayCountsAsHours: Double
    var standardDayStart: String
    var standardDayEnd: String
    var breakWindowStart: String
    var breakWindowEnd: String
    var people: [CanonicalUnbookedLabourPerson]
    var operatives: [CanonicalUnbookedLabourOperative]
    var bookings: [CanonicalUnbookedLabourBooking]
    var holidays: [CanonicalUnbookedLabourHoliday]
}

/// One stored booking as `parseBookingDocument` reads it (`CanonicalBooking` in the script).
/// Ids are the stored strings, which may not be UUIDs (a Firebase user id, for example).
nonisolated struct CanonicalParsedBooking: Codable, Equatable, Sendable {
    let id: String
    let operativeId: String
    let projectId: String
    let dateMs: Double
    let timeSlot: String
    let status: String
    let bookedBy: String
    let notes: String
    let workStartTime: String?
    let workEndTime: String?
    let isBreakRemoved: Bool
    let otMultiplierOverride: Double?
    let bookingGroupId: String?
    let createdAtMs: Double?
    let updatedAtMs: Double?
    let operativeIdIsUuid: Bool
    let projectIdIsUuid: Bool
}

/// `parseBookingDocument` result: a booking plus the legacy spellings it repaired, or the reasons it refused.
nonisolated struct CanonicalBookingParseResult: Codable, Equatable, Sendable {
    let ok: Bool
    let booking: CanonicalParsedBooking?
    let repairs: [String]?
    let errors: [String]?
}

/// One weekly-report pay line for `reportPayCell` / `reportPayTotal` (`ReportPayLineInput` in the script).
nonisolated struct CanonicalReportPayLine: Codable, Equatable, Sendable {
    var isPaye: Bool
    var pay: Double?
}

/// What a weekly-report pay cell shows (`ReportPayCell` in the script). `label` is `PAYE` for a PAYE line.
nonisolated struct CanonicalReportPayCell: Codable, Equatable, Sendable {
    let pay: Double?
    let label: String?
    let countsTowardPayTotal: Bool
}

/// One warning row for `sortWarningsByDate`. `dayKey` is the coverage day (`YYYY-MM-DD`), or blank when the row has no day.
nonisolated struct CanonicalWarningDateRow: Codable, Equatable, Sendable {
    var id: String
    var dayKey: String
}

/// One unbooked person-day (`UnbookedLabourRow` in the script).
nonisolated struct CanonicalUnbookedLabourRow: Codable, Equatable, Sendable {
    var id: String
    var operativeId: String
    var operativeName: String
    var userId: String?
    var personKey: String
    var dayKey: String
    var missingHours: Double
    var message: String
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

    struct CanonicalPaymentRunRange: Codable, Equatable, Hashable, Sendable {
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

    /// Material catalogues seed only when the collection is empty. Qualification rows do not use this.
    static func starterCollectionShouldSeed(existingDocumentCount: Int) -> Bool? {
        decodeExpression(
            Bool.self,
            "ProjectPlannerCanonical.starterCollectionShouldSeed(\(existingDocumentCount))"
        )
    }

    /// Library codes that are not already document ids. A custom row does not count as the library.
    static func missingStarterQualificationCodes(existingDocumentIds: [String], libraryCodes: [String]) -> [String]? {
        guard let existing = jsonFragment(existingDocumentIds),
              let library = jsonFragment(libraryCodes) else { return nil }
        return decodeExpression(
            [String].self,
            "ProjectPlannerCanonical.missingStarterQualificationCodes(\(existing), \(library))"
        )
    }

    /// `startDate`/`endDate` when that pair is present, otherwise `startDay`/`endDay`. Empty input is 1–15 then 16–31.
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
        /// Deadline and notify-at rows. Empty when this save has none; the script does not invent a day.
        var timesheetSubmission: [CanonicalTimesheetSubmissionEntry] = []
        /// Earlier payment-run windows. Empty when the document has none; a save must not invent a replacement.
        var paymentRunHistory: [CanonicalPaymentRunHistoryWindow] = []
    }

    struct CanonicalPaymentRunHistoryWindow: Codable, Equatable, Hashable, Sendable {
        var paymentRunMode: String
        var ranges: [CanonicalPaymentRunRange]
        var recurringRunStartDay: String
        var recurringRunEndDay: String
        var recordedAtDayKey: String
    }

    struct CanonicalTimesheetPeriod: Codable, Equatable, Hashable, Sendable {
        var startDayKey: String
        var endDayKey: String
    }

    struct CanonicalSelectableTimesheetPeriod: Codable, Equatable, Sendable {
        var startDayKey: String
        var endDayKey: String
        var source: String
    }

    struct CanonicalTimesheetStatusFields: Codable, Equatable, Sendable {
        var operativeSignedAtMs: Double?
        var operativeSignedByName: String
        var operativeSignatureImageBase64: String
        var managerSignedAtMs: Double?
        var managerSignedByName: String
        var managerSignedByUserId: String
        var managerSignatureImageBase64: String
        var exportedAtMs: Double?
    }

    struct CanonicalTimesheetSignOffFields: Codable, Equatable, Sendable {
        var operativeSignedAtMs: Double?
        var operativeSignedByName: String?
        var operativeSignatureImageBase64: String?
        var managerSignedAtMs: Double?
        var managerSignedByName: String?
        var managerSignedByUserId: String?
        var managerSignatureImageBase64: String?
        var approvedAtMs: Double?
        var approvedByName: String?
    }

    struct CanonicalTimesheetExportFields: Codable, Equatable, Sendable {
        var exportedAtMs: Double?
    }

    struct CanonicalTimesheetPeriodWrite: Codable, Equatable, Sendable {
        var userId: String
        var weekStartKey: String
        var weekEndKey: String
    }

    struct CanonicalTimesheetPaymentRunWindow: Codable, Equatable, Sendable {
        var paymentRunMode: String
        var ranges: [CanonicalPaymentRunRange]
        var recurringRunStartDay: String
        var recurringRunEndDay: String
    }

    struct CanonicalTimesheetSubmissionListInput: Codable, Equatable, Sendable {
        var paymentRunMode: String
        var paymentDates: [String]
        var recurringPaymentDay: String
        var timesheetSubmission: [CanonicalTimesheetSubmissionEntry]?
        var paymentRunDateRanges: [CanonicalPaymentRunRange]?
    }

    struct CanonicalTimesheetNoticeCopyInput: Codable, Equatable, Sendable {
        var mode: String
        var deadlineDay: Int?
        var paymentDay: Int?
        var deadlineWeekday: String?
        var paymentWeekday: String?
        var deadlineHour: Int?
        var deadlineMinute: Int?
    }

    /// `startDate`/`endDate` when that pair is present, otherwise `startDay`/`endDay`. Missing ranges are 1–15 and 16–31.
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

    /// `startDate`/`endDate` when that pair is a day 1–31, otherwise `startDay`/`endDay`. Nil when neither pair is set.
    static func normalizePaymentRunRange(
        startDay: Int,
        endDay: Int,
        startDate: Int? = nil,
        endDate: Int? = nil
    ) -> CanonicalPaymentRunRange? {
        var fields = ["startDay: \(startDay)", "endDay: \(endDay)"]
        if let startDate {
            fields.append("startDate: \(startDate)")
        }
        if let endDate {
            fields.append("endDate: \(endDate)")
        }
        return decodeExpression(
            CanonicalPaymentRunRange.self,
            "ProjectPlannerCanonical.normalizePaymentRunRange({ \(fields.joined(separator: ", ")) })"
        )
    }

    /// `1st`, `2nd`, `11th`. Empty when the script does not treat the number as a day of the month.
    static func monthDayOrdinal(_ day: Int) -> String? {
        decodeExpression(String.self, "ProjectPlannerCanonical.monthDayOrdinal(\(day))")
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

    /// `organizations/{orgId}.name`, then leftover aliases. Empty string means the name is missing. Nil when the script did not run.
    static func parseOrganizationName(_ data: [String: Any]?) -> String? {
        let json = data.flatMap(jsonObjectFragment) ?? "null"
        return decodeExpression(String.self, "ProjectPlannerCanonical.parseOrganizationName(\(json))")
    }

    /// The `{ name }` map. Nil when the script did not run — do not invent another name field.
    static func organizationNameToFirestore(_ name: String) -> [String: Any]? {
        guard let json = jsonObjectFragment(name) else { return nil }
        return objectDictionary("ProjectPlannerCanonical.organizationNameToFirestore(\(json))")
    }

    /// `{ name }` only when `nextName` is non-empty. A blank returns `{}` so a saved name stays. Nil when the script did not run.
    static func organizationNameWriteFields(_ nextName: String, existingName: String?) -> [String: Any]? {
        guard let nextJSON = jsonObjectFragment(nextName) else { return nil }
        let existingJSON = existingName.flatMap(jsonObjectFragment) ?? "null"
        return objectDictionary("ProjectPlannerCanonical.organizationNameWriteFields(\(nextJSON), \(existingJSON))")
    }

    /// First non-empty candidate. Nil when the script did not run.
    static func coalesceOrganizationName(_ candidates: [String?]) -> String? {
        let fragments = candidates.map { jsonObjectFragment($0 ?? "") ?? "\"\"" }
        return decodeExpression(
            String.self,
            "ProjectPlannerCanonical.coalesceOrganizationName(\(fragments.joined(separator: ", ")))"
        )
    }

    /// On-screen label. Nil when the script did not run.
    static func displayOrganizationName(_ name: String?, fallback: String = "Organisation") -> String? {
        let nameJSON = jsonObjectFragment(name ?? "") ?? "\"\""
        guard let fallbackJSON = jsonObjectFragment(fallback) else { return nil }
        return decodeExpression(
            String.self,
            "ProjectPlannerCanonical.displayOrganizationName(\(nameJSON), \(fallbackJSON))"
        )
    }

    /// Days-covered 1–31 strip. True only for `date_ranges`. Nil when the script did not run.
    static func paymentRunShowsMonthCoverage(_ settings: CanonicalInvoicingSettings) -> Bool? {
        guard let json = jsonFragment(settings) else { return nil }
        return decodeExpression(Bool.self, "ProjectPlannerCanonical.paymentRunShowsMonthCoverage(\(json))")
    }

    struct CanonicalMaterialCutOffClock: Codable, Equatable, Hashable, Sendable {
        var materialOrderCutOff: Bool
        var materialCutOffHour: Int
        var materialCutOffMinute: Int
        var materialCutOffOnSaturday: Bool
        var materialCutOffOnSunday: Bool
    }

    /// Organisation `settings.materialCutOff`. Nil when the script did not answer — do not invent 16:00 here.
    static func parseMaterialCutOff(_ data: [String: Any]?) -> CanonicalMaterialCutOffClock? {
        let json = data.flatMap(jsonObjectFragment) ?? "null"
        return decodeExpression(
            CanonicalMaterialCutOffClock.self,
            "ProjectPlannerCanonical.parseMaterialCutOff(\(json))"
        )
    }

    /// Organisation map only. A user-pref hour on another key is ignored. Nil when the script did not answer.
    static func resolveMaterialCutOffClock(_ input: [String: Any]) -> CanonicalMaterialCutOffClock? {
        guard let json = jsonObjectFragment(input) else { return nil }
        return decodeExpression(
            CanonicalMaterialCutOffClock.self,
            "ProjectPlannerCanonical.resolveMaterialCutOffClock(\(json))"
        )
    }

    static func materialCutOffClockMinutes(_ clock: CanonicalMaterialCutOffClock) -> Int? {
        decode(Int.self, function: "materialCutOffClockMinutes", arguments: [clock])
    }

    static func formatMaterialCutOffClock(_ clock: CanonicalMaterialCutOffClock) -> String? {
        decode(String.self, function: "formatMaterialCutOffClock", arguments: [clock])
    }

    /// The `settings.materialCutOff` map. Nil when the script did not answer — do not write a hand-built clock.
    static func materialCutOffToFirestore(_ prefs: CanonicalMaterialCutOffClock) -> [String: Any]? {
        guard let json = jsonFragment(prefs) else { return nil }
        return objectDictionary("ProjectPlannerCanonical.materialCutOffToFirestore(\(json))")
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

    // MARK: - Stored bookings

    /// `parseBookingDocument` for each `(documentId, data)` pair, in order, in one script call.
    /// `data` must be JSON: the caller turns a Firestore Timestamp into `{ seconds, nanoseconds }`.
    /// Nil only when the script did not run; a refused document comes back with `ok == false`.
    static func parseBookingDocuments(
        _ documents: [(id: String, data: [String: Any])],
        timeZone: String = "Europe/London"
    ) -> [CanonicalBookingParseResult]? {
        if documents.isEmpty { return [] }
        let rows: [[String: Any]] = documents.map { ["id": $0.id, "data": $0.data] }
        guard let rowsJSON = jsonObjectFragment(rows),
              let options = jsonObjectFragment(["timeZone": timeZone]) else {
            return nil
        }
        return decodeExpression(
            [CanonicalBookingParseResult].self,
            "(\(rowsJSON)).map(function (row) { return ProjectPlannerCanonical.parseBookingDocument(row.id, row.data, \(options)) })"
        )
    }

    // MARK: - Annual leave against bookings

    /// Leave-clash and half-day-cover rows for approved leave inside the window.
    static func leaveCoverageRows(_ input: CanonicalLeaveCoverageInput) -> [CanonicalLeaveCoverageRow]? {
        decode([CanonicalLeaveCoverageRow].self, function: "leaveCoverageRows", arguments: [input])
    }

    /// Unbooked people inside the window. Saturday and Sunday are included only when `includeWeekends` is true.
    static func unbookedLabourRows(_ input: CanonicalUnbookedLabourInput) -> [CanonicalUnbookedLabourRow]? {
        decode([CanonicalUnbookedLabourRow].self, function: "unbookedLabourRows", arguments: [input])
    }

    /// The same rows as `unbookedLabourRows` for one London day. Not a second person loop.
    static func unbookedLabourRowsOnDay(_ input: CanonicalUnbookedLabourDayInput) -> [CanonicalUnbookedLabourRow]? {
        decode([CanonicalUnbookedLabourRow].self, function: "unbookedLabourRowsOnDay", arguments: [input])
    }

    /// `oldest` or `newest`. A missing or unrecognised value is `oldest`. Nil when the script did not answer.
    static func parseWarningsSortDirection(_ value: String?) -> String? {
        decode(String.self, function: "parseWarningsSortDirection", arguments: [value])
    }

    /// Reorders by coverage `dayKey`. Nil when the script did not answer — keep the current order.
    static func sortWarningsByDate(_ rows: [CanonicalWarningDateRow], direction: String) -> [CanonicalWarningDateRow]? {
        decode([CanonicalWarningDateRow].self, function: "sortWarningsByDate", arguments: [rows, direction])
    }

    // MARK: - Session organisation

    /// This device's UserDefaults key. Web uses `pp.webActiveOrg:{userId}` and the two may differ.
    static var iosSessionOrganizationStorageKey: String? {
        constant("IOS_SESSION_ORGANIZATION_STORAGE_KEY", as: String.self)
    }

    static func webSessionOrganizationStorageKey(userId: String) -> String? {
        decode(String.self, function: "webSessionOrganizationStorageKey", arguments: [userId])
    }

    /// False for the same account signing out. True only when a different uid is about to use this device.
    static func shouldClearRememberedOrganization(signedOutUserId: String?, nextUserId: String?) -> Bool? {
        decode(
            Bool.self,
            function: "shouldClearRememberedOrganization",
            arguments: [CanonicalRememberedOrganizationClearInput(
                signedOutUserId: signedOutUserId,
                nextUserId: nextUserId
            )]
        )
    }

    static func rememberedOrganizationSurvivesSignOut() -> Bool? {
        decode(Bool.self, function: "rememberedOrganizationSurvivesSignOut", arguments: [])
    }

    /// Company to open before membership reads finish. Nil when the script did not answer.
    static func provisionalOrganizationId(
        explicitOrganizationId: String?,
        rememberedOrganizationId: String?,
        documentOrganizationId: String?
    ) -> String? {
        decode(
            String.self,
            function: "provisionalOrganizationId",
            arguments: [CanonicalProvisionalOrganizationInput(
                explicitOrganizationId: explicitOrganizationId,
                rememberedOrganizationId: rememberedOrganizationId,
                documentOrganizationId: documentOrganizationId
            )]
        )
    }

    /// `allowed`, `denied`, or `unknown`. Nil when the script did not answer.
    static func orgAccessProbeFromReads(
        orgRead: String,
        membershipRead: String,
        listed: Bool,
        isCreator: Bool
    ) -> String? {
        decode(
            String.self,
            function: "orgAccessProbeFromReads",
            arguments: [CanonicalOrgAccessProbeInput(
                orgRead: orgRead,
                membershipRead: membershipRead,
                listed: listed,
                isCreator: isCreator
            )]
        )
    }

    /// A thrown read, including timeout and permission-denied, is `unknown`.
    static func accessProbeFromReadError() -> String? {
        decode(String.self, function: "accessProbeFromReadError", arguments: [Optional<String>.none])
    }

    /// `ProjectPlannerCanonical.hasAccess(billing, now)`.
    /// Nil billing is the script's missing map. Grace, cancel-at-period-end, and closed statuses stay in the script.
    static func hasAccess(billing: [String: Any]?, now: Date = Date()) -> Bool? {
        let json: String
        if let billing {
            guard let fragment = jsonObjectFragment(billing) else { return nil }
            json = fragment
        } else {
            json = "null"
        }
        let nowMs = Int64((now.timeIntervalSince1970 * 1000).rounded())
        return decodeExpression(
            Bool.self,
            "ProjectPlannerCanonical.hasAccess(\(json), \(nowMs))"
        )
    }

    /// Nil when the script did not answer. An empty `organizationId` is not a company to invent.
    static func chooseSessionOrganization(
        explicitOrganizationId: String?,
        rememberedOrganizationId: String?,
        documentOrganizationId: String?,
        probes: [String: String]
    ) -> CanonicalSessionOrganizationChoice? {
        decode(
            CanonicalSessionOrganizationChoice.self,
            function: "chooseSessionOrganization",
            arguments: [CanonicalSessionOrganizationInput(
                explicitOrganizationId: explicitOrganizationId,
                rememberedOrganizationId: rememberedOrganizationId,
                documentOrganizationId: documentOrganizationId,
                probes: probes
            )]
        )
    }

    /// Switcher ids. Nil when the script did not answer.
    static func sessionMembershipIds(
        discoveredIds: [String],
        previousIds: [String],
        rememberedOrganizationId: String?,
        documentOrganizationId: String?,
        explicitOrganizationId: String?,
        discoveryIncomplete: Bool
    ) -> [String]? {
        decode(
            [String].self,
            function: "sessionMembershipIds",
            arguments: [CanonicalSessionMembershipInput(
                discoveredIds: discoveredIds,
                previousIds: previousIds,
                rememberedOrganizationId: rememberedOrganizationId,
                documentOrganizationId: documentOrganizationId,
                explicitOrganizationId: explicitOrganizationId,
                discoveryIncomplete: discoveryIncomplete
            )]
        )
    }

    // MARK: - Material order delivery

    /// Orders carry a required day and time. Quotes never do. Nil when the script did not answer.
    static func materialOrderIncludesDeliveryRequired(_ requestType: String?) -> Bool? {
        decode(Bool.self, function: "materialOrderIncludesDeliveryRequired", arguments: [requestType])
    }

    /// Tomorrow in `timeZone`, or the next Monday when `now` is Saturday or Sunday. Nil when the script did not answer.
    static func defaultMaterialDeliveryDayKey(now: Date, timeZone: String = "Europe/London") -> String? {
        let key = decode(
            String.self,
            function: "defaultMaterialDeliveryDayKey",
            arguments: [isoString(from: now), timeZone]
        )
        guard let key, key.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil else {
            return nil
        }
        return key
    }

    /// The required-delivery instant for a day and clock the user chose. Nil when the script did not answer.
    static func materialDeliveryInstant(dayKey: String, clockMinutes: Int, timeZone: String = "Europe/London") -> Date? {
        guard let dayJSON = jsonFragment(dayKey), let zoneJSON = jsonFragment(timeZone) else { return nil }
        return scriptDate(from: "ProjectPlannerCanonical.materialDeliveryInstant(\(dayJSON), \(clockMinutes), \(zoneJSON))")
    }

    /// Default required delivery for an order opened at `now`. Nil when the script did not answer — do not invent 08:00.
    static func defaultMaterialDeliveryRequiredAt(now: Date, timeZone: String = "Europe/London") -> Date? {
        let reference = isoString(from: now)
        guard let referenceJSON = jsonFragment(reference), let zoneJSON = jsonFragment(timeZone) else { return nil }
        return scriptDate(
            from: "ProjectPlannerCanonical.defaultMaterialDeliveryRequiredAt(\(referenceJSON), \(zoneJSON))"
        )
    }

    /// London day key of an instant. Used when the user edits the delivery day.
    static func dayKeyInOrganizationZone(_ date: Date, timeZone: String = "Europe/London") -> String? {
        let key = decode(
            String.self,
            function: "dayKeyInOrganizationZone",
            arguments: [isoString(from: date), timeZone]
        )
        guard let key, key.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil else {
            return nil
        }
        return key
    }

    /// Clock minutes of an instant in `timeZone`. Used when the user edits the delivery time.
    static func clockMinutesFromDeliveryInstant(_ at: Date, timeZone: String = "Europe/London") -> Int? {
        let reference = isoString(from: at)
        guard let referenceJSON = jsonFragment(reference), let zoneJSON = jsonFragment(timeZone) else { return nil }
        let expression = """
        (() => {
          const at = new Date(\(referenceJSON));
          if (Number.isNaN(at.getTime())) return null;
          return ProjectPlannerCanonical.clockMinutesFromDeliveryInstant(at, \(zoneJSON));
        })()
        """
        return decodeExpression(Int.self, expression)
    }

    /// "Monday 12 October at 08:00". Nil when the script did not answer.
    static func formatMaterialDeliveryRequired(_ at: Date, timeZone: String = "Europe/London") -> String? {
        let reference = isoString(from: at)
        guard let referenceJSON = jsonFragment(reference), let zoneJSON = jsonFragment(timeZone) else { return nil }
        let expression = """
        (() => {
          const at = new Date(\(referenceJSON));
          if (Number.isNaN(at.getTime())) return null;
          return ProjectPlannerCanonical.formatMaterialDeliveryRequired(at, \(zoneJSON));
        })()
        """
        guard let label = decodeExpression(String.self, expression)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !label.isEmpty else {
            return nil
        }
        return label
    }

    /// The email and history line for an order. Quotes, and a missing instant, do not call the formatter.
    static func orderDeliveryRequiredLabel(requestType: String?, at: Date?, timeZone: String = "Europe/London") -> String? {
        guard materialOrderIncludesDeliveryRequired(requestType) == true, let at else { return nil }
        return formatMaterialDeliveryRequired(at, timeZone: timeZone)
    }

    /// `FULL_DAY`, `AM`, or `PM` for a leave record's slot.
    static func leaveSlotKind(_ timeSlot: String?) -> String {
        decode(String.self, function: "leaveSlotKind", arguments: [timeSlot]) ?? "FULL_DAY"
    }

    // MARK: - Weekly report pay

    /// One pay line: a PAYE line shows `PAYE`, no figure, and is not totalled. Nil when the script did not run.
    static func reportPayCell(_ line: CanonicalReportPayLine) -> CanonicalReportPayCell? {
        decode(CanonicalReportPayCell.self, function: "reportPayCell", arguments: [line])
    }

    /// Pay total of the lines that count; PAYE lines add nothing. Nil when the script did not run.
    static func reportPayTotal(_ lines: [CanonicalReportPayLine]) -> Double? {
        decode(Double.self, function: "reportPayTotal", arguments: [lines])
    }

    /// A person's total row: `PAYE` when every line is PAYE, otherwise the total of the counted lines.
    static func reportPersonPayCell(_ lines: [CanonicalReportPayLine]) -> CanonicalReportPayCell? {
        decode(CanonicalReportPayCell.self, function: "reportPersonPayCell", arguments: [lines])
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

    // MARK: - People lists

    /// Fields `rosterSegment` and `listedRosterUsers` read. `id` is only so the filtered rows map back onto `AppUser`.
    struct CanonicalRosterProfile: Codable, Equatable, Sendable {
        var id: String
        var email: String
        var firstName: String
        var surname: String
        var name: String
        var displayName: String
        var passwordSet: Bool
        var isActive: Bool
        var mobileNumber: String?

        init(user: AppUser) {
            id = user.id
            email = user.email
            firstName = user.firstName
            surname = user.surname
            name = user.documentName
            displayName = user.documentDisplayName
            passwordSet = user.passwordSet
            isActive = user.isActive
            mobileNumber = user.mobileNumber
        }
    }

    /// `"active"`, `"inactive"`, or `"pending"`. Nil when the script did not run.
    static func rosterSegment(_ profile: CanonicalRosterProfile) -> String? {
        decode(String.self, function: "rosterSegment", arguments: [profile])
    }

    static func rosterSegment(_ user: AppUser) -> String? {
        rosterSegment(CanonicalRosterProfile(user: user))
    }

    /// Anonymised deleted profile. Nil when the script did not run.
    static func isAnonymisedDeletedProfile(_ profile: CanonicalRosterProfile) -> Bool? {
        decode(Bool.self, function: "isAnonymisedDeletedProfile", arguments: [profile])
    }

    static func isAnonymisedDeletedProfile(_ user: AppUser) -> Bool? {
        isAnonymisedDeletedProfile(CanonicalRosterProfile(user: user))
    }

    /// Rows the people lists may show. `claimedEmails` nil means the `userEmails` read failed, so a pending invite with an email stays.
    static func listedRosterUsers(_ users: [CanonicalRosterProfile], claimedEmails: [String]?) -> [CanonicalRosterProfile]? {
        guard let usersJSON = jsonFragment(users), let claimedJSON = claimedEmailsJSON(claimedEmails) else { return nil }
        return decodeExpression(
            [CanonicalRosterProfile].self,
            "ProjectPlannerCanonical.listedRosterUsers(\(usersJSON), \(claimedJSON))"
        )
    }

    /// Same list as `listedRosterUsers` on the profiles, returned as the original accounts in that order.
    /// Nil when the script did not run. Does not classify anyone locally.
    static func listedRosterUsers(_ users: [AppUser], claimedEmails: Set<String>?) -> [AppUser]? {
        let profiles = users.map { CanonicalRosterProfile(user: $0) }
        guard let listed = listedRosterUsers(profiles, claimedEmails: claimedEmails.map(Array.init)) else {
            return nil
        }
        var byId: [String: AppUser] = [:]
        for user in users where !byId.keys.contains(user.id) {
            byId[user.id] = user
        }
        return listed.compactMap { byId[$0.id] }
    }

    /// Fields `listedCurrentLabourPeople` reads. `id` maps the filtered rows back onto the Swift model.
    struct CanonicalCurrentLabourPerson: Codable, Equatable, Sendable {
        var id: String
        var email: String
        var firstName: String
        var surname: String
        var name: String
        var displayName: String

        init(user: AppUser) {
            id = user.id
            email = user.email
            firstName = user.firstName
            surname = user.surname
            name = user.documentName
            displayName = user.documentDisplayName
        }

        init(operative: Operative) {
            id = operative.id.uuidString
            email = operative.email
            firstName = operative.firstName
            surname = operative.lastName
            // Same string as `Operative.name`. That computed property is main-actor isolated.
            name = "\(operative.firstName) \(operative.lastName)".trimmingCharacters(in: .whitespaces)
            displayName = ""
        }
    }

    /// People who can still be warned, shown as unbooked, or offered in a scheduling picker.
    /// An anonymised deleted profile is omitted. Nil when the script did not run.
    static func listedCurrentLabourPeople(_ people: [CanonicalCurrentLabourPerson]) -> [CanonicalCurrentLabourPerson]? {
        decode([CanonicalCurrentLabourPerson].self, function: "listedCurrentLabourPeople", arguments: [people])
    }

    /// Same list as `listedCurrentLabourPeople` on the profiles, in that order.
    static func listedCurrentLabourPeople(_ users: [AppUser]) -> [AppUser]? {
        let people = users.map { CanonicalCurrentLabourPerson(user: $0) }
        guard let listed = listedCurrentLabourPeople(people) else { return nil }
        var byId: [String: AppUser] = [:]
        for user in users where !byId.keys.contains(user.id) {
            byId[user.id] = user
        }
        return listed.compactMap { byId[$0.id] }
    }

    /// Same list for roster operatives. The script reads email and name; it does not read `isActive`.
    static func listedCurrentLabourPeople(_ operatives: [Operative]) -> [Operative]? {
        let people = operatives.map { CanonicalCurrentLabourPerson(operative: $0) }
        guard let listed = listedCurrentLabourPeople(people) else { return nil }
        var byId: [String: Operative] = [:]
        for operative in operatives where byId[operative.id.uuidString] == nil {
            byId[operative.id.uuidString] = operative
        }
        return listed.compactMap { byId[$0.id] }
    }

    /// One `users` row `resolveInviteEmailClaim` reads. A missing `passwordSet` stays nil so the script does not treat it as a finished account.
    struct CanonicalInviteEmailClaimUser: Codable, Equatable, Sendable {
        var userId: String?
        var email: String
        var firstName: String
        var surname: String
        var lastName: String?
        var name: String
        var displayName: String
        var passwordSet: Bool?
        var isActive: Bool?
        var mobileNumber: String?
    }

    /// `organizations/{orgId}/userEmails/{email}`. Nil `emailPointer` on the input means that read failed.
    struct CanonicalInviteEmailPointer: Codable, Equatable, Sendable {
        var exists: Bool
        var pointedUserId: String?
        var pointedUser: CanonicalInviteEmailClaimUser?
    }

    struct CanonicalInviteEmailClaimInput: Codable, Equatable, Sendable {
        var inviteEmail: String
        var existingUsers: [CanonicalInviteEmailClaimUser]
        var emailPointer: CanonicalInviteEmailPointer?
    }

    /// `action` is `allow` or `block`. `reuseUserId` is a leftover placeholder, never an anonymised tombstone.
    struct CanonicalInviteEmailClaimDecision: Codable, Equatable, Sendable {
        var action: String
        var reuseUserId: String?
    }

    /// Nil when the script did not run. Do not invent a block or an allow.
    static func resolveInviteEmailClaim(_ input: CanonicalInviteEmailClaimInput) -> CanonicalInviteEmailClaimDecision? {
        decode(CanonicalInviteEmailClaimDecision.self, function: "resolveInviteEmailClaim", arguments: [input])
    }

    /// True only when `resolveInviteEmailClaim` returns `block`. Nil when the script did not run.
    static func inviteEmailHasLiveClaim(_ input: CanonicalInviteEmailClaimInput) -> Bool? {
        decode(Bool.self, function: "inviteEmailHasLiveClaim", arguments: [input])
    }

    /// The only `users` query Add User may run: this organisation and this email.
    struct CanonicalInviteEmailOrgLookup: Codable, Equatable, Sendable {
        var organizationId: String
        var email: String
    }

    /// Nil when the script did not run. An empty organisation id or email is not a query.
    static func inviteEmailOrgLookupConstraints(organizationId: String, email: String) -> CanonicalInviteEmailOrgLookup? {
        decode(
            CanonicalInviteEmailOrgLookup.self,
            function: "inviteEmailOrgLookupConstraints",
            arguments: [organizationId, email]
        )
    }

    /// Pending invite flags. Age confirmation is not in this map.
    struct CanonicalInvitePlaceholderWriteFields: Codable, Equatable, Sendable {
        var passwordSet: Bool
        var isActive: Bool
        var isSuperAdmin: Bool
        var policyAccepted: Bool
    }

    /// Nil when the script did not run. Do not invent `passwordSet: false` locally.
    static func invitePlaceholderUserWriteFields() -> CanonicalInvitePlaceholderWriteFields? {
        decode(CanonicalInvitePlaceholderWriteFields.self, function: "invitePlaceholderUserWriteFields", arguments: [])
    }

    /// False means Add User does not create `organizations/{orgId}/operativeProfiles/{newUserId}`.
    /// Rates stay on `users/{uid}`. Nil when the script did not run. Do not treat a missing result as false.
    static func inviteWritesOperativeProfile() -> Bool? {
        decode(Bool.self, function: "inviteWritesOperativeProfile", arguments: [])
    }

    /// True only when the creator uid is the document being created. Nil when the script did not run.
    static func userCreateRequiresAgeConfirmation(creatorUserId: String, targetUserId: String) -> Bool? {
        decode(
            Bool.self,
            function: "userCreateRequiresAgeConfirmation",
            arguments: [CanonicalAgeConfirmationInput(creatorUserId: creatorUserId, targetUserId: targetUserId)]
        )
    }

    struct CanonicalAgeConfirmationInput: Codable, Equatable, Sendable {
        var creatorUserId: String
        var targetUserId: String
    }

    /// Self-create age keys. They are not written on an admin invite placeholder.
    static var userSelfCreateAgeFields: [String]? {
        constant("USER_SELF_CREATE_AGE_FIELDS", as: [String].self)
    }

    private static func claimedEmailsJSON(_ claimedEmails: [String]?) -> String? {
        guard let claimedEmails else { return "null" }
        return jsonFragment(claimedEmails)
    }

    // MARK: - Notification preferences and inbox destinations

    struct CanonicalNotificationDestination: Codable, Equatable, Sendable {
        var kind: String
        var relatedId: String?
        var dayKey: String?
        var userId: String?
    }

    struct CanonicalTimesheetSubmissionNotice: Codable, Equatable, Sendable {
        var runIndex: Int
        var occurrenceKey: String
        var paymentDayKey: String
        var deadlineDayKey: String
        var notifyDayKey: String
        var notifyHour: Int
        var notifyMinute: Int
        var deadlineHour: Int
        var deadlineMinute: Int
        var title: String
        var message: String
    }

    struct CanonicalTimesheetSubmissionEntry: Codable, Hashable, Sendable {
        var timesheetDeadlineDay: Int
        var timesheetDeadlineWeekday: String
        var timesheetDeadlineHour: Int
        var timesheetDeadlineMinute: Int
        var notifyDay: Int
        var notifyWeekday: String
        var notifyHour: Int
        var notifyMinute: Int
        var notifyCustomised: Bool

        init(
            timesheetDeadlineDay: Int = 0,
            timesheetDeadlineWeekday: String = "",
            timesheetDeadlineHour: Int = 17,
            timesheetDeadlineMinute: Int = 0,
            notifyDay: Int = 0,
            notifyWeekday: String = "",
            notifyHour: Int = 8,
            notifyMinute: Int = 0,
            notifyCustomised: Bool = false
        ) {
            self.timesheetDeadlineDay = timesheetDeadlineDay
            self.timesheetDeadlineWeekday = timesheetDeadlineWeekday
            self.timesheetDeadlineHour = timesheetDeadlineHour
            self.timesheetDeadlineMinute = timesheetDeadlineMinute
            self.notifyDay = notifyDay
            self.notifyWeekday = notifyWeekday
            self.notifyHour = notifyHour
            self.notifyMinute = notifyMinute
            self.notifyCustomised = notifyCustomised
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            timesheetDeadlineDay = try container.decodeIfPresent(Int.self, forKey: .timesheetDeadlineDay) ?? 0
            timesheetDeadlineWeekday = try container.decodeIfPresent(String.self, forKey: .timesheetDeadlineWeekday) ?? ""
            timesheetDeadlineHour = try container.decodeIfPresent(Int.self, forKey: .timesheetDeadlineHour) ?? 17
            timesheetDeadlineMinute = try container.decodeIfPresent(Int.self, forKey: .timesheetDeadlineMinute) ?? 0
            notifyDay = try container.decodeIfPresent(Int.self, forKey: .notifyDay) ?? 0
            notifyWeekday = try container.decodeIfPresent(String.self, forKey: .notifyWeekday) ?? ""
            notifyHour = try container.decodeIfPresent(Int.self, forKey: .notifyHour) ?? 8
            notifyMinute = try container.decodeIfPresent(Int.self, forKey: .notifyMinute) ?? 0
            notifyCustomised = try container.decodeIfPresent(Bool.self, forKey: .notifyCustomised) ?? false
        }
    }

    /// Toggle keys in script order. Nil when the script did not answer — do not invent a list.
    static var notificationPreferenceKeys: [String]? {
        constant("NOTIFICATION_PREFERENCE_KEYS", as: [String].self)
    }

    /// Defaults from the script. Nil when the script did not answer — do not invent a map.
    static var defaultUserNotificationPreferences: [String: Bool]? {
        constant("DEFAULT_USER_NOTIFICATION_PREFERENCES", as: [String: Bool].self)
    }

    /// `users/{uid}` fields a profile save must not drop. Nil when the script did not answer.
    static var userDocumentFields: [String]? {
        constant("USER_DOCUMENT_FIELDS", as: [String].self)
    }

    static var timesheetSubmissionNoticeType: String? {
        constant("TIMESHEET_SUBMISSION_NOTICE_TYPE", as: String.self)
    }

    static var timesheetSubmissionNoticeTitle: String? {
        constant("TIMESHEET_SUBMISSION_NOTICE_TITLE", as: String.self)
    }

    /// Close of play. Nil when the script did not answer — do not invent 17:00.
    static var timesheetCloseOfPlayHour: Int? {
        constant("TIMESHEET_CLOSE_OF_PLAY_HOUR", as: Int.self)
    }

    static var timesheetCloseOfPlayMinute: Int? {
        constant("TIMESHEET_CLOSE_OF_PLAY_MINUTE", as: Int.self)
    }

    /// Notify-at clock. Nil when the script did not answer — do not invent 08:00.
    static var timesheetNotifyHour: Int? {
        constant("TIMESHEET_NOTIFY_HOUR", as: Int.self)
    }

    static var timesheetNotifyMinute: Int? {
        constant("TIMESHEET_NOTIFY_MINUTE", as: Int.self)
    }

    /// Missing keys are on. `bookingConflicts` fills `bookingClashes` only when the new key is absent.
    /// Nil when the script did not answer.
    static func parseUserNotificationPreferences(_ raw: [String: Any]?) -> [String: Bool]? {
        let json = raw.flatMap(jsonObjectFragment) ?? "null"
        return decodeExpression(
            [String: Bool].self,
            "ProjectPlannerCanonical.parseUserNotificationPreferences(\(json))"
        )
    }

    /// Dotted `notificationPreferences.{key}` updates. Never a replacement of the map.
    /// Nil when the script did not answer.
    static func userNotificationPreferenceFieldPatch(_ prefs: [String: Bool]) -> [String: Bool]? {
        guard let json = jsonObjectFragment(prefs) else { return nil }
        return decodeExpression(
            [String: Bool].self,
            "ProjectPlannerCanonical.userNotificationPreferenceFieldPatch(\(json))"
        )
    }

    /// Nested bools for the known toggle keys. Does not include legacy keys or the cut-off clock.
    /// Nil when the script did not answer.
    static func userNotificationPreferencesToFirestore(_ prefs: [String: Bool]) -> [String: Bool]? {
        guard let json = jsonObjectFragment(prefs) else { return nil }
        return decodeExpression(
            [String: Bool].self,
            "ProjectPlannerCanonical.userNotificationPreferencesToFirestore(\(json))"
        )
    }

    /// The toggle that gates `type`, or nil when this type has no toggle or the script did not answer.
    static func notificationPreferenceKeyForType(_ type: String) -> String? {
        guard let json = jsonFragment(type) else { return nil }
        return decodeExpression(
            String.self,
            "ProjectPlannerCanonical.notificationPreferenceKeyForType(\(json))"
        )
    }

    /// Types with no toggle stay allowed. Nil when the script did not answer — do not invent a block.
    static func notificationPreferenceAllowsDelivery(prefs: [String: Bool], type: String) -> Bool? {
        guard let prefsJSON = jsonObjectFragment(prefs), let typeJSON = jsonFragment(type) else { return nil }
        return decodeExpression(
            Bool.self,
            "ProjectPlannerCanonical.notificationPreferenceAllowsDelivery(\(prefsJSON), \(typeJSON))"
        )
    }

    /// `catalogue.projects` / `catalogue.smallWorks` for My notifications. The script applies super-admin and operative rules.
    struct CanonicalWorkCatalogueToggles: Codable, Equatable, Sendable {
        var projects: Bool
        var smallWorks: Bool
    }

    /// Role plus catalogue toggles, and the optional people / clients / materials flags.
    /// A nil flag is omitted from the script call, which treats that flag as visible for staff.
    struct CanonicalNotificationPreferenceAudience: Codable, Equatable, Sendable {
        var role: CanonicalStaffAccountRole
        var catalogue: CanonicalWorkCatalogueToggles
        var canManagePeople: Bool? = nil
        var canManageClients: Bool? = nil
        var canManageMaterials: Bool? = nil
    }

    struct CanonicalNotificationPreferenceCopy: Codable, Equatable, Sendable {
        var label: String
        var description: String
    }

    /// Keys this account may see, in script order. Nil when the script did not answer — do not invent a list.
    static func visibleNotificationPreferenceKeys(
        _ audience: CanonicalNotificationPreferenceAudience
    ) -> [String]? {
        decode([String].self, function: "visibleNotificationPreferenceKeys", arguments: [audience])
    }

    /// Whether one key is on that list. Nil when the script did not answer.
    static func notificationPreferenceIsVisible(
        _ key: String,
        audience: CanonicalNotificationPreferenceAudience
    ) -> Bool? {
        decode(Bool.self, function: "notificationPreferenceIsVisible", arguments: [key, audience])
    }

    /// Label and description for a toggle. Nil when the script did not answer — do not invent copy.
    static func notificationPreferenceCopy(
        _ key: String,
        audience: CanonicalNotificationPreferenceAudience? = nil
    ) -> CanonicalNotificationPreferenceCopy? {
        let audienceArgument: Encodable? = audience
        return decode(
            CanonicalNotificationPreferenceCopy.self,
            function: "notificationPreferenceCopy",
            arguments: [key, audienceArgument]
        )
    }

    struct CanonicalUnreadNotificationRow: Codable, Equatable, Sendable {
        var userId: String?
        var isRead: Bool
    }

    /// One inbox row for visibility, order, and the unread count. `createdAt` is unix milliseconds.
    struct CanonicalInboxNotificationRow: Codable, Equatable, Sendable {
        var id: String
        var userId: String?
        var isRead: Bool
        var createdAt: Double
    }

    /// Rows `inboxNotificationVisibleToUser` keeps, newest first via `compareInboxNotificationsByCreatedAt`.
    /// Nil when the script did not answer — do not filter or sort in Swift.
    static func visibleSortedInboxNotifications(
        _ rows: [CanonicalInboxNotificationRow],
        userId: String
    ) -> [CanonicalInboxNotificationRow]? {
        guard let rowsJSON = jsonFragment(rows), let userJSON = jsonFragment(userId) else { return nil }
        return decodeExpression(
            [CanonicalInboxNotificationRow].self,
            "(\(rowsJSON)).filter(function(row){return ProjectPlannerCanonical.inboxNotificationVisibleToUser(row,\(userJSON));}).sort(ProjectPlannerCanonical.compareInboxNotificationsByCreatedAt)"
        )
    }

    /// Inbox types that send one FCM alert. Nil when the script did not answer.
    static func devicePushNotificationTypes() -> [String]? {
        decodeExpression([String].self, "ProjectPlannerCanonical.devicePushNotificationTypes()")
    }

    /// The only device-push allow-list. Nil when the script did not answer.
    static func notificationDeliversDevicePush(_ type: String) -> Bool? {
        guard let json = jsonFragment(type) else { return nil }
        return decodeExpression(Bool.self, "ProjectPlannerCanonical.notificationDeliversDevicePush(\(json))")
    }

    /// Unread rows for this user on the list the centre already shows. Nil when the script did not answer.
    static func unreadNotificationBadgeCount(
        notifications: [CanonicalUnreadNotificationRow],
        userId: String
    ) -> Int? {
        decode(Int.self, function: "unreadNotificationBadgeCount", arguments: [notifications, userId])
    }

    /// When true, opening the app clears the home-screen icon badge and leaves the in-app number alone.
    static var notificationIconBadgeClearsOnForeground: Bool? {
        constant("NOTIFICATION_ICON_BADGE_CLEARS_ON_FOREGROUND", as: Bool.self)
    }

    /// Nil when the script did not answer — do not invent a destination.
    static func notificationDestination(
        type: String,
        relatedId: String?,
        dayKey: String?,
        catalogue: String?,
        role: String,
        deepLinkUserId: String?
    ) -> CanonicalNotificationDestination? {
        let input = CanonicalNotificationDestinationInput(
            type: type,
            relatedId: relatedId,
            dayKey: dayKey,
            catalogue: catalogue,
            role: role,
            deepLinkUserId: deepLinkUserId
        )
        return decode(
            CanonicalNotificationDestination.self,
            function: "notificationDestination",
            arguments: [input]
        )
    }

    /// Notices whose notify-at has arrived at `reference`. Nil when the script did not answer.
    static func dueTimesheetSubmissionNotices(
        reference: Date,
        timeZone: String = "Europe/London",
        invoicing: OrganizationInvoicingSettings
    ) -> [CanonicalTimesheetSubmissionNotice]? {
        let referenceIso = isoString(from: reference)
        var payload: [String: Any] = [
            "referenceIso": referenceIso,
            "timeZone": timeZone,
            "paymentRunMode": invoicing.paymentRunMode.rawValue,
            "paymentDateMode": invoicing.paymentDateMode.rawValue,
            "paymentRunDateRanges": invoicing.paymentRunDateRanges.map {
                ["startDay": $0.startDay, "endDay": $0.endDay]
            },
            "paymentDates": invoicing.paymentDates,
            "recurringRunStartDay": invoicing.recurringRunStartDay.rawValue,
            "recurringRunEndDay": invoicing.recurringRunEndDay.rawValue,
            "recurringPaymentDay": invoicing.recurringPaymentDay.rawValue,
        ]
        if let entries = invoicing.timesheetSubmission, !entries.isEmpty {
            payload["timesheetSubmission"] = entries.map { entry in
                [
                    "timesheetDeadlineDay": entry.timesheetDeadlineDay,
                    "timesheetDeadlineWeekday": entry.timesheetDeadlineWeekday,
                    "timesheetDeadlineHour": entry.timesheetDeadlineHour,
                    "timesheetDeadlineMinute": entry.timesheetDeadlineMinute,
                    "notifyDay": entry.notifyDay,
                    "notifyWeekday": entry.notifyWeekday,
                    "notifyHour": entry.notifyHour,
                    "notifyMinute": entry.notifyMinute,
                    "notifyCustomised": entry.notifyCustomised,
                ]
            }
        }
        guard let json = jsonObjectFragment(payload) else { return nil }
        return decodeExpression(
            [CanonicalTimesheetSubmissionNotice].self,
            "ProjectPlannerCanonical.dueTimesheetSubmissionNotices(\(json))"
        )
    }

    static func timesheetSubmissionNoticeDedupKey(
        organizationId: String,
        paymentDayKey: String,
        runIndex: Int,
        userId: String
    ) -> String? {
        let input = CanonicalTimesheetSubmissionDedupInput(
            organizationId: organizationId,
            paymentDayKey: paymentDayKey,
            runIndex: runIndex,
            userId: userId
        )
        return decode(String.self, function: "timesheetSubmissionNoticeDedupKey", arguments: [input])
    }

    /// Deadline and notify-at for a calendar payment day. Nil when the script did not answer.
    static func defaultTimesheetSubmissionFromPaymentDay(_ paymentDay: Int) -> CanonicalTimesheetSubmissionEntry? {
        decode(
            CanonicalTimesheetSubmissionEntry.self,
            function: "defaultTimesheetSubmissionFromPaymentDay",
            arguments: [paymentDay]
        )
    }

    /// Deadline and notify-at for a recurring payday. Nil when the script did not answer.
    static func defaultTimesheetSubmissionFromPaymentWeekday(_ paymentWeekday: String) -> CanonicalTimesheetSubmissionEntry? {
        decode(
            CanonicalTimesheetSubmissionEntry.self,
            function: "defaultTimesheetSubmissionFromPaymentWeekday",
            arguments: [paymentWeekday]
        )
    }

    /// Keeps a customised row. Otherwise replaces it with the payment-day default. Nil when the script did not answer.
    static func timesheetSubmissionAfterPaymentDayChange(
        _ current: CanonicalTimesheetSubmissionEntry?,
        paymentDay: Int
    ) -> CanonicalTimesheetSubmissionEntry? {
        decode(
            CanonicalTimesheetSubmissionEntry.self,
            function: "timesheetSubmissionAfterPaymentDayChange",
            arguments: [current, paymentDay]
        )
    }

    /// Keeps a customised row. Otherwise replaces it with the weekday default. Nil when the script did not answer.
    static func timesheetSubmissionAfterPaymentWeekdayChange(
        _ current: CanonicalTimesheetSubmissionEntry?,
        paymentWeekday: String
    ) -> CanonicalTimesheetSubmissionEntry? {
        decode(
            CanonicalTimesheetSubmissionEntry.self,
            function: "timesheetSubmissionAfterPaymentWeekdayChange",
            arguments: [current, paymentWeekday]
        )
    }

    /// Inbox and preview sentence. Nil when the script did not answer — do not invent “17th” or “19th”.
    static func timesheetSubmissionNoticeCopy(_ input: CanonicalTimesheetNoticeCopyInput) -> String? {
        decode(String.self, function: "timesheetSubmissionNoticeCopy", arguments: [input])
    }

    static func parseTimesheetSubmissionList(
        _ input: CanonicalTimesheetSubmissionListInput
    ) -> [CanonicalTimesheetSubmissionEntry]? {
        decode(
            [CanonicalTimesheetSubmissionEntry].self,
            function: "parseTimesheetSubmissionList",
            arguments: [input]
        )
    }

    static func parseTimesheetSubmissionEntry(
        _ raw: CanonicalTimesheetSubmissionEntry?,
        fallback: CanonicalTimesheetSubmissionEntry
    ) -> CanonicalTimesheetSubmissionEntry? {
        decode(
            CanonicalTimesheetSubmissionEntry.self,
            function: "parseTimesheetSubmissionEntry",
            arguments: [raw, fallback]
        )
    }

    static func timesheetSubmissionToFirestore(_ entry: CanonicalTimesheetSubmissionEntry) -> [String: Any]? {
        guard let json = jsonFragment(entry) else { return nil }
        return objectDictionary("ProjectPlannerCanonical.timesheetSubmissionToFirestore(\(json))")
    }

    /// `timesheet_{userId}_{unixStartOfDay}` in the organisation zone. Nil when the script did not answer or the id is empty — do not build one from `Calendar.current`.
    static func timesheetDocumentId(userId: String, startDayKey: String, timeZone: String = "Europe/London") -> String? {
        guard let id = decode(String.self, function: "timesheetDocumentId", arguments: [userId, startDayKey, timeZone]),
              !id.isEmpty else {
            return nil
        }
        return id
    }

    /// Pay-run window that contains `referenceDayKey`. Nil when the script did not answer — do not invent a 1–15 window.
    static func timesheetPeriodFromInvoicing(
        paymentRunMode: String,
        ranges: [CanonicalPaymentRunRange],
        recurringRunStartDay: String,
        recurringRunEndDay: String,
        referenceDayKey: String,
        timeZone: String = "Europe/London"
    ) -> CanonicalTimesheetPeriod? {
        let input = CanonicalTimesheetPeriodInput(
            paymentRunMode: paymentRunMode,
            ranges: ranges,
            recurringRunStartDay: recurringRunStartDay,
            recurringRunEndDay: recurringRunEndDay,
            referenceDayKey: referenceDayKey,
            timeZone: timeZone
        )
        return decode(CanonicalTimesheetPeriod.self, function: "timesheetPeriodFromInvoicing", arguments: [input])
    }

    /// Stored start and end win. A start-only row is not stretched onto a wider live window.
    static func resolveTimesheetPeriod(
        storedStartDayKey: String,
        storedEndDayKey: String?,
        currentPeriod: CanonicalTimesheetPeriod
    ) -> CanonicalTimesheetPeriod? {
        let input = CanonicalResolveTimesheetPeriodInput(
            storedStartDayKey: storedStartDayKey,
            storedEndDayKey: storedEndDayKey,
            currentPeriod: currentPeriod
        )
        return decode(CanonicalTimesheetPeriod.self, function: "resolveTimesheetPeriod", arguments: [input])
    }

    /// True only when the stored row is that period. Nil when the script did not answer.
    static func timesheetPeriodMatches(
        storedStartDayKey: String,
        storedEndDayKey: String?,
        period: CanonicalTimesheetPeriod
    ) -> Bool? {
        struct Stored: Codable {
            var startDayKey: String
            var endDayKey: String?
        }
        return decode(
            Bool.self,
            function: "timesheetPeriodMatches",
            arguments: [Stored(startDayKey: storedStartDayKey, endDayKey: storedEndDayKey), period]
        )
    }

    /// Index of the row for this period, or -1. Nil when the script did not answer — do not pick a row by falling inside the live window.
    static func pickTimesheetRowForPeriod(
        rows: [CanonicalTimesheetPeriodCandidate],
        period: CanonicalTimesheetPeriod
    ) -> Int? {
        decode(Int.self, function: "pickTimesheetRowForPeriod", arguments: [rows, period])
    }

    struct CanonicalTimesheetPeriodCandidate: Codable, Equatable, Sendable {
        var startDayKey: String
        var endDayKey: String?
        var hasActivity: Bool?
    }

    /// `exported`, `signed`, `awaiting`, or `unsigned`. Nil when the script did not answer.
    static func timesheetListBucket(_ fields: CanonicalTimesheetStatusFields, hasLineManager: Bool) -> String? {
        decode(String.self, function: "timesheetListBucket", arguments: [fields, hasLineManager])
    }

    /// Signature and export instants. A Generate Invoice leftover on `exportedAt` is not an export. Nil when the script did not answer.
    static func parseTimesheetStatusFields(_ data: [String: Any]) -> CanonicalTimesheetStatusFields? {
        guard let json = jsonObjectFragment(data) else { return nil }
        return decodeExpression(
            CanonicalTimesheetStatusFields.self,
            "ProjectPlannerCanonical.parseTimesheetStatusFields(\(json))"
        )
    }

    static func isTimesheetFullySigned(_ fields: CanonicalTimesheetStatusFields, hasLineManager: Bool) -> Bool? {
        decode(Bool.self, function: "isTimesheetFullySigned", arguments: [fields, hasLineManager])
    }

    static func isTimesheetAwaitingSignOff(_ fields: CanonicalTimesheetStatusFields, hasLineManager: Bool) -> Bool? {
        decode(Bool.self, function: "isTimesheetAwaitingSignOff", arguments: [fields, hasLineManager])
    }

    static func isTimesheetExported(_ fields: CanonicalTimesheetStatusFields) -> Bool? {
        decode(Bool.self, function: "isTimesheetExported", arguments: [fields])
    }

    /// Operative or manager sign-off fields. Nil when the script did not answer — do not write a signature from the device clock alone.
    static func timesheetSignOffWriteFields(
        role: String,
        signedAtMs: Double,
        signedByName: String,
        signedByUserId: String? = nil,
        signatureImageBase64: String? = nil
    ) -> CanonicalTimesheetSignOffFields? {
        struct Input: Codable {
            var role: String
            var signedAtMs: Double
            var signedByName: String
            var signedByUserId: String?
            var signatureImageBase64: String?
        }
        return decode(
            CanonicalTimesheetSignOffFields.self,
            function: "timesheetSignOffWriteFields",
            arguments: [Input(
                role: role,
                signedAtMs: signedAtMs,
                signedByName: signedByName,
                signedByUserId: signedByUserId,
                signatureImageBase64: signatureImageBase64
            )]
        )
    }

    /// `{ exportedAtMs }`. Nil when the script did not answer. Generate Invoice does not call this.
    static func timesheetExportWriteFields(exportedAtMs: Double) -> CanonicalTimesheetExportFields? {
        decode(CanonicalTimesheetExportFields.self, function: "timesheetExportWriteFields", arguments: [exportedAtMs])
    }

    /// `userId`, `weekStartKey`, `weekEndKey`. Nil when the script did not answer.
    static func timesheetPeriodWriteFields(userId: String, startDayKey: String, endDayKey: String) -> CanonicalTimesheetPeriodWrite? {
        struct Input: Codable {
            var userId: String
            var startDayKey: String
            var endDayKey: String
        }
        return decode(
            CanonicalTimesheetPeriodWrite.self,
            function: "timesheetPeriodWriteFields",
            arguments: [Input(userId: userId, startDayKey: startDayKey, endDayKey: endDayKey)]
        )
    }

    /// Live window, snapshots taken when the window changed, and periods already stored on timesheet documents.
    static func selectableTimesheetPaymentRunPeriods(
        current: CanonicalTimesheetPaymentRunWindow,
        historicalWindows: [CanonicalPaymentRunHistoryWindow],
        observedPeriods: [CanonicalTimesheetPeriod],
        referenceDayKey: String,
        lookbackCount: Int = 120,
        timeZone: String = "Europe/London"
    ) -> [CanonicalSelectableTimesheetPeriod]? {
        struct Input: Codable {
            var current: CanonicalTimesheetPaymentRunWindow
            var historicalWindows: [CanonicalPaymentRunHistoryWindow]
            var observedPeriods: [CanonicalTimesheetPeriod]
            var referenceDayKey: String
            var lookbackCount: Int
            var timeZone: String
        }
        return decode(
            [CanonicalSelectableTimesheetPeriod].self,
            function: "selectableTimesheetPaymentRunPeriods",
            arguments: [Input(
                current: current,
                historicalWindows: historicalWindows,
                observedPeriods: observedPeriods,
                referenceDayKey: referenceDayKey,
                lookbackCount: lookbackCount,
                timeZone: timeZone
            )]
        )
    }

    /// Snapshot the previous window when the payment run changes. The same window returns the history unchanged. Nil when the script did not answer — do not write an empty history in its place.
    static func paymentRunHistoryAfterChange(
        previous: CanonicalTimesheetPaymentRunWindow,
        next: CanonicalTimesheetPaymentRunWindow,
        existingHistory: [CanonicalPaymentRunHistoryWindow],
        recordedAtDayKey: String
    ) -> [CanonicalPaymentRunHistoryWindow]? {
        struct Input: Codable {
            var previous: CanonicalTimesheetPaymentRunWindow
            var next: CanonicalTimesheetPaymentRunWindow
            var existingHistory: [CanonicalPaymentRunHistoryWindow]
            var recordedAtDayKey: String
        }
        return decode(
            [CanonicalPaymentRunHistoryWindow].self,
            function: "paymentRunHistoryAfterChange",
            arguments: [Input(
                previous: previous,
                next: next,
                existingHistory: existingHistory,
                recordedAtDayKey: recordedAtDayKey
            )]
        )
    }

    static func canReviewUserTimesheets(_ role: CanonicalStaffAccountRole) -> Bool? {
        decode(Bool.self, function: "canReviewUserTimesheets", arguments: [role])
    }

    static func seesEveryUserTimesheet(_ role: CanonicalStaffAccountRole) -> Bool? {
        decode(Bool.self, function: "seesEveryUserTimesheet", arguments: [role])
    }

    /// `organizations/{orgId}/timesheetExports/{stamp}_{file}`. Nil when the script did not answer.
    static func timesheetExportStoragePath(organizationId: String, fileName: String, stampSeconds: Int) -> String? {
        guard let path = decode(
            String.self,
            function: "timesheetExportStoragePath",
            arguments: [organizationId, fileName, stampSeconds]
        ), !path.isEmpty else {
            return nil
        }
        return path
    }

    private struct CanonicalTimesheetPeriodInput: Codable {
        var paymentRunMode: String
        var ranges: [CanonicalPaymentRunRange]
        var recurringRunStartDay: String
        var recurringRunEndDay: String
        var referenceDayKey: String
        var timeZone: String
    }

    private struct CanonicalResolveTimesheetPeriodInput: Codable {
        var storedStartDayKey: String
        var storedEndDayKey: String?
        var currentPeriod: CanonicalTimesheetPeriod
    }

    /// Next payment day on or after the period end, in `Europe/London` unless another zone is passed.
    /// Nil when the script did not answer.
    static func paymentDateAfterPeriodEnd(
        periodEndDayKey: String,
        paymentDays: [Int],
        timeZone: String = "Europe/London"
    ) -> String? {
        decode(
            String.self,
            function: "paymentDateAfterPeriodEnd",
            arguments: [periodEndDayKey, paymentDays, timeZone]
        )
    }

    /// Stored 1–31 day, wrapping the 31-day cycle. Nil when the script did not answer.
    static func monthDayOffsetBefore(paymentDay: Int, daysBefore: Int) -> Int? {
        decode(Int.self, function: "monthDayOffsetBefore", arguments: [paymentDay, daysBefore])
    }

    /// Weekday that many days before `weekday`. Nil when the script did not answer.
    static func weekdayOffsetBefore(weekday: String, daysBefore: Int) -> String? {
        decode(String.self, function: "weekdayOffsetBefore", arguments: [weekday, daysBefore])
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

    // MARK: - Qualification library search

    struct CanonicalQualificationSearchRecord: Codable, Equatable, Sendable {
        var name: String
        var code: String
        var awardingBody: String
        var section: String
        var subsection: String
        var notes: String

        init(
            name: String = "",
            code: String = "",
            awardingBody: String = "",
            section: String = "",
            subsection: String = "",
            notes: String = ""
        ) {
            self.name = name
            self.code = code
            self.awardingBody = awardingBody
            self.section = section
            self.subsection = subsection
            self.notes = notes
        }
    }

    struct CanonicalQualificationSearchHit: Codable, Equatable, Sendable {
        var index: Int
        var score: Double
    }

    struct CanonicalQualificationFilterChip: Codable, Equatable, Sendable {
        var key: String
        var label: String
        var count: Int
    }

    static let qualificationFilterAll = "All"
    static let qualificationFilterOther = "Other"

    struct CanonicalAssignedQualificationRow: Codable, Equatable, Sendable {
        var id: String
        var name: String
        var hasEndDate: Bool
        var createdAtIso: String
        var updatedAtIso: String
        var endDateIso: String?
    }

    struct CanonicalOperativeQualificationMaps: Codable, Equatable, Sendable {
        var qualifications: [CanonicalAssignedQualificationRow]
        var qualificationExpiryDates: [String: String]
        var qualificationCertificateURLs: [String: String]
    }

    struct CanonicalOperativeQualificationNext: Codable, Equatable, Sendable {
        var qualifications: [CanonicalAssignedQualificationRow]
        var qualificationExpiryDates: [String: String]
        var qualificationCertificateURLs: [String: String]
        var removedCertificateIds: [String]
    }

    struct CanonicalOperativeQualificationMergeInput: Encodable, Sendable {
        var previous: CanonicalOperativeQualificationMaps?
        var next: CanonicalOperativeQualificationNext
    }

    /// Assignment row written on the operative: id, name, hasEndDate, timestamps, optional endDate.
    static func assignedQualificationWriteFields(_ row: CanonicalAssignedQualificationRow) -> CanonicalAssignedQualificationRow? {
        decode(CanonicalAssignedQualificationRow.self, function: "assignedQualificationWriteFields", arguments: [row])
    }

    /// Case-insensitive lookup of a certificate download URL.
    static func qualificationCertificateUrl(urls: [String: String], qualificationId: String) -> String? {
        decode(String.self, function: "qualificationCertificateUrl", arguments: [urls, qualificationId])
    }

    static func mergeQualificationCertificateUrls(
        existing: [String: String],
        uploaded: [String: String],
        removedIds: [String] = []
    ) -> [String: String]? {
        decode(
            [String: String].self,
            function: "mergeQualificationCertificateUrls",
            arguments: [existing, uploaded, removedIds]
        )
    }

    static func removedQualificationCertificateIds(
        previousUrls: [String: String],
        nextUrls: [String: String],
        assignedIds: [String]
    ) -> [String]? {
        decode(
            [String].self,
            function: "removedQualificationCertificateIds",
            arguments: [previousUrls, nextUrls, assignedIds]
        )
    }

    /// Previous assignments not in `next` are kept. Certificate URLs merge; `removedCertificateIds` deletes only those keys.
    static func mergeOperativeQualificationWrite(
        _ input: CanonicalOperativeQualificationMergeInput
    ) -> CanonicalOperativeQualificationMaps? {
        decode(
            CanonicalOperativeQualificationMaps.self,
            function: "mergeOperativeQualificationWrite",
            arguments: [input]
        )
    }

    /// `organizations/{orgId}/operatives/{operativeId}/qualifications/{qualificationId}/certificates/{fileName}`.
    static func qualificationCertificateStoragePath(
        organizationId: String,
        operativeId: String,
        qualificationId: String,
        fileName: String
    ) -> String? {
        struct Input: Encodable {
            var organizationId: String
            var operativeId: String
            var qualificationId: String
            var fileName: String
        }
        return decode(
            String.self,
            function: "qualificationCertificateStoragePath",
            arguments: [Input(
                organizationId: organizationId,
                operativeId: operativeId,
                qualificationId: qualificationId,
                fileName: fileName
            )]
        )
    }

    static func date(fromIso value: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: value) { return date }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: value)
    }

    static func tokenizeQualificationSearch(_ query: String) -> [String] {
        decode([String].self, function: "tokenizeQualificationSearch", arguments: [query]) ?? []
    }

    static func qualificationSearchScore(query: String, record: CanonicalQualificationSearchRecord) -> Double {
        decode(Double.self, function: "qualificationSearchScore", arguments: [query, record]) ?? 0
    }

    static func qualificationMatchesSection(section: String, wanted: String) -> Bool {
        decode(Bool.self, function: "qualificationMatchesSection", arguments: [["section": section], wanted]) ?? false
    }

    static func qualificationSectionChipLabel(_ section: String) -> String {
        decode(String.self, function: "qualificationSectionChipLabel", arguments: [section]) ?? section
    }

    static func qualificationLibraryFilterChips(
        _ records: [CanonicalQualificationSearchRecord]
    ) -> [CanonicalQualificationFilterChip]? {
        decode([CanonicalQualificationFilterChip].self, function: "qualificationLibraryFilterChips", arguments: [records])
    }

    /// Indexes from `rankQualificationRecords`. Nil means the script did not run.
    /// `limit` of nil or 0 returns every hit. An empty query keeps the original order inside the section.
    static func rankQualificationRecords(
        query: String,
        records: [CanonicalQualificationSearchRecord],
        limit: Int? = nil,
        section: String? = nil
    ) -> [CanonicalQualificationSearchHit]? {
        decode(
            [CanonicalQualificationSearchHit].self,
            function: "rankQualificationRecords",
            arguments: [query, records, limit, section]
        )
    }

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

    // MARK: - File reports

    /// Input for `fileReportWriteFields` (`FileReportInput` in the script).
    struct CanonicalFileReportInput: Codable, Equatable, Sendable {
        var organizationId: String
        var storagePath: String
        var surface: String
        var parentId: String
        var fileName: String
        var reason: String
        var details: String
        var reportedByUserId: String
    }

    /// What `fileReportWriteFields` answered: the document fields, or the script's refusal code.
    enum CanonicalFileReportWrite {
        case fields([String: Any])
        case refused(String)
    }

    /// `organizations/{orgId}/fileReports` document fields without `createdAt`, or the refusal.
    /// Nil when the script did not answer.
    static func fileReportWriteFields(_ input: CanonicalFileReportInput) -> CanonicalFileReportWrite? {
        guard let json = jsonFragment(input),
              let result = objectDictionary("ProjectPlannerCanonical.fileReportWriteFields(\(json))") else {
            return nil
        }
        if result["ok"] as? Bool == true, let fields = result["fields"] as? [String: Any] {
            return .fields(fields)
        }
        return .refused(result["error"] as? String ?? "")
    }

    static func fileReportCollectionPath(organizationId: String) -> String? {
        decode(String.self, function: "fileReportCollectionPath", arguments: [organizationId])
    }

    /// Storage object path from a download URL, gs:// URL or bare path. Nil when it is not one.
    static func fileReportStoragePath(_ fileRef: String?) -> String? {
        decode(String.self, function: "fileReportStoragePath", arguments: [fileRef])
    }

    static func fileReportReasonCopy(_ reason: String) -> String? {
        decode(String.self, function: "fileReportReasonCopy", arguments: [reason])
    }

    static func fileReportStatusCopy(_ status: String) -> String? {
        decode(String.self, function: "fileReportStatusCopy", arguments: [status])
    }

    static func canReviewFileReports(_ role: CanonicalStaffAccountRole) -> Bool? {
        decode(Bool.self, function: "canReviewFileReports", arguments: [role])
    }

    private struct CanonicalFileReportReviewInput: Codable {
        var status: String
        var reviewedByUserId: String
    }

    /// Review fields without `reviewedAt`. Nil for a status other than reviewed/removed or a blank reviewer.
    static func fileReportReviewWriteFields(status: String, reviewedByUserId: String) -> [String: Any]? {
        guard let json = jsonFragment(CanonicalFileReportReviewInput(status: status, reviewedByUserId: reviewedByUserId)) else {
            return nil
        }
        return objectDictionary("ProjectPlannerCanonical.fileReportReviewWriteFields(\(json))")
    }

    /// Reason codes in script order. Nil when the script did not answer — do not invent a list.
    static var fileReportReasons: [String]? {
        constant("FILE_REPORT_REASONS", as: [String].self)
    }

    static var fileReportSurfaces: [String]? {
        constant("FILE_REPORT_SURFACES", as: [String].self)
    }

    static var fileReportDetailsMax: Int? {
        constant("FILE_REPORT_DETAILS_MAX", as: Int.self)
    }

    static var fileReportLinkLabel: String? {
        constant("FILE_REPORT_LINK_LABEL", as: String.self)
    }

    static var fileReportSentCopy: String? {
        constant("FILE_REPORT_SENT_COPY", as: String.self)
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

    struct CanonicalSessionOrganizationChoice: Codable, Equatable, Sendable {
        var organizationId: String
        var persistOrganizationId: String?
    }

    private struct CanonicalRememberedOrganizationClearInput: Codable {
        var signedOutUserId: String?
        var nextUserId: String?
    }

    private struct CanonicalProvisionalOrganizationInput: Codable {
        var explicitOrganizationId: String?
        var rememberedOrganizationId: String?
        var documentOrganizationId: String?
    }

    private struct CanonicalOrgAccessProbeInput: Codable {
        var orgRead: String
        var membershipRead: String
        var listed: Bool
        var isCreator: Bool
    }

    private struct CanonicalSessionOrganizationInput: Codable {
        var explicitOrganizationId: String?
        var rememberedOrganizationId: String?
        var documentOrganizationId: String?
        var probes: [String: String]
    }

    private struct CanonicalSessionMembershipInput: Codable {
        var discoveredIds: [String]?
        var previousIds: [String]?
        var rememberedOrganizationId: String?
        var documentOrganizationId: String?
        var explicitOrganizationId: String?
        var discoveryIncomplete: Bool?
    }

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

    private struct CanonicalNotificationDestinationInput: Codable {
        var type: String
        var relatedId: String?
        var dayKey: String?
        var catalogue: String?
        var role: String
        var deepLinkUserId: String?
    }

    private struct CanonicalTimesheetSubmissionDedupInput: Codable {
        var organizationId: String
        var paymentDayKey: String
        var runIndex: Int
        var userId: String
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

    /// JSON of a script `Date`. Nil when the script returned null or an invalid instant.
    private static func scriptDate(from expression: String) -> Date? {
        guard let text = decodeExpression(String.self, expression) else { return nil }
        return parseScriptDate(text)
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
