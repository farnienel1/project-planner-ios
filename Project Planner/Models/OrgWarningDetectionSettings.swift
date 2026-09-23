//
//  OrgWarningDetectionSettings.swift
//  Project Planner
//
//  Company-wide warning detection horizon and unbooked-labour rules.
//

import Foundation

nonisolated enum WarningClashLookaheadMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case endOfInvoicingPeriod
    case numberOfDays
    case endOfWorkingWeek

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .endOfInvoicingPeriod: return "Invoicing period"
        case .numberOfDays: return "Set number of days"
        case .endOfWorkingWeek: return "Full week"
        }
    }
}

nonisolated struct OrgWarningDetectionSettings: Codable, Hashable, Sendable {
    var detectClashes: Bool
    var clashLookaheadMode: WarningClashLookaheadMode
    /// Used when `clashLookaheadMode == .numberOfDays`.
    var clashLookaheadDays: Int
    /// When true, Sat/Sun count for unbooked labour warnings only.
    var includeWeekendsForUnbookedLabour: Bool
    /// Org user ids omitted from unbooked-labour warnings (e.g. PAYE staff).
    var excludedUserIdsFromUnbookedWarnings: [String]

    nonisolated static let `default` = OrgWarningDetectionSettings(
        detectClashes: true,
        clashLookaheadMode: .numberOfDays,
        clashLookaheadDays: 7,
        includeWeekendsForUnbookedLabour: false,
        excludedUserIdsFromUnbookedWarnings: []
    )

    nonisolated enum CodingKeys: String, CodingKey {
        case detectClashes
        case clashLookaheadMode
        case clashLookaheadDays
        case includeWeekendsForUnbookedLabour
        case excludedUserIdsFromUnbookedWarnings
    }

    init(
        detectClashes: Bool = true,
        clashLookaheadMode: WarningClashLookaheadMode = .numberOfDays,
        clashLookaheadDays: Int = 7,
        includeWeekendsForUnbookedLabour: Bool = false,
        excludedUserIdsFromUnbookedWarnings: [String] = []
    ) {
        self.detectClashes = detectClashes
        self.clashLookaheadMode = clashLookaheadMode
        self.clashLookaheadDays = clashLookaheadDays
        self.includeWeekendsForUnbookedLabour = includeWeekendsForUnbookedLabour
        self.excludedUserIdsFromUnbookedWarnings = excludedUserIdsFromUnbookedWarnings
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        detectClashes = try c.decodeIfPresent(Bool.self, forKey: .detectClashes) ?? true
        clashLookaheadMode = try c.decodeIfPresent(WarningClashLookaheadMode.self, forKey: .clashLookaheadMode) ?? .numberOfDays
        clashLookaheadDays = try c.decodeIfPresent(Int.self, forKey: .clashLookaheadDays) ?? 7
        includeWeekendsForUnbookedLabour = try c.decodeIfPresent(Bool.self, forKey: .includeWeekendsForUnbookedLabour) ?? false
        excludedUserIdsFromUnbookedWarnings = try c.decodeIfPresent([String].self, forKey: .excludedUserIdsFromUnbookedWarnings) ?? []
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(detectClashes, forKey: .detectClashes)
        try c.encode(clashLookaheadMode, forKey: .clashLookaheadMode)
        try c.encode(clashLookaheadDays, forKey: .clashLookaheadDays)
        try c.encode(includeWeekendsForUnbookedLabour, forKey: .includeWeekendsForUnbookedLabour)
        try c.encode(excludedUserIdsFromUnbookedWarnings, forKey: .excludedUserIdsFromUnbookedWarnings)
    }

    /// Inclusive end of the warnings scan window.
    /// - numberOfDays: today through today+(N-1)  (N calendar days)
    /// - endOfWorkingWeek ("Full week"): Sunday of the current week (Mon–Sun)
    /// - endOfInvoicingPeriod: end of the payment-run segment that contains today
    func coverageEnd(
        from today: Date,
        invoicing: OrganizationInvoicingSettings = .default,
        calendar: Calendar = .current
    ) -> Date {
        let start = calendar.startOfDay(for: today)
        switch clashLookaheadMode {
        case .numberOfDays:
            let days = max(1, min(clashLookaheadDays, 366))
            // Inclusive window: N=1 → today only; N=7 → today … today+6.
            return calendar.startOfDay(
                for: calendar.date(byAdding: .day, value: days - 1, to: start) ?? start
            )
        case .endOfWorkingWeek:
            // Full calendar week ending Sunday. Weekend unbooked warnings use the toggle below.
            return Self.endOfCalendarWeek(from: start, calendar: calendar)
        case .endOfInvoicingPeriod:
            // Active payment-run segment only (e.g. 1–16 while today is in that range).
            return calendar.startOfDay(
                for: InvoicingPeriodResolver.warningScanBounds(
                    invoicing: invoicing,
                    referenceDate: start,
                    calendar: calendar
                ).end
            )
        }
    }

    /// Inclusive start of the warnings scan window.
    /// - numberOfDays: today (forward look-ahead)
    /// - endOfWorkingWeek ("Full week"): Monday of the current week (includes past days this week)
    /// - endOfInvoicingPeriod: start of the active payment-run segment containing today
    func coverageStart(
        from today: Date,
        invoicing: OrganizationInvoicingSettings = .default,
        calendar: Calendar = .current
    ) -> Date {
        let start = calendar.startOfDay(for: today)
        switch clashLookaheadMode {
        case .endOfInvoicingPeriod:
            return calendar.startOfDay(
                for: InvoicingPeriodResolver.warningScanBounds(
                    invoicing: invoicing,
                    referenceDate: start,
                    calendar: calendar
                ).start
            )
        case .endOfWorkingWeek:
            return Self.startOfCalendarWeek(from: start, calendar: calendar)
        case .numberOfDays:
            return start
        }
    }

    func isUnbookedLabourWeekday(_ weekday: Int) -> Bool {
        if includeWeekendsForUnbookedLabour {
            return weekday >= 1 && weekday <= 7
        }
        return weekday >= 2 && weekday <= 6
    }

    /// Human-readable end of the detection window (from today).
    func detectionHorizonEndLabel(
        from today: Date = Date(),
        invoicing: OrganizationInvoicingSettings = .default,
        calendar: Calendar = .current
    ) -> String {
        let end = coverageEnd(from: today, invoicing: invoicing, calendar: calendar)
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter.string(from: end)
    }

    /// Inclusive number of calendar days in the detection window.
    func detectionHorizonDayCount(
        from today: Date = Date(),
        invoicing: OrganizationInvoicingSettings = .default,
        calendar: Calendar = .current
    ) -> Int {
        let start = coverageStart(from: today, invoicing: invoicing, calendar: calendar)
        let end = coverageEnd(from: today, invoicing: invoicing, calendar: calendar)
        let days = calendar.dateComponents([.day], from: start, to: end).day ?? 0
        return max(1, days + 1)
    }

    /// Scan window description for the settings UI.
    func detectionScanSummary(
        from today: Date = Date(),
        invoicing: OrganizationInvoicingSettings = .default,
        calendar: Calendar = .current
    ) -> String {
        let start = coverageStart(from: today, invoicing: invoicing, calendar: calendar)
        let end = coverageEnd(from: today, invoicing: invoicing, calendar: calendar)
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        let startLabel = formatter.string(from: start)
        let endLabel = formatter.string(from: end)
        switch clashLookaheadMode {
        case .numberOfDays:
            let count = max(1, min(clashLookaheadDays, 366))
            return "Scans \(count) calendar day\(count == 1 ? "" : "s"): \(startLabel) through \(endLabel). Includes clashes, unbooked labour, and materials cut-off in that window."
        case .endOfInvoicingPeriod:
            let bounds = InvoicingPeriodResolver.warningScanBounds(invoicing: invoicing, referenceDate: today, calendar: calendar)
            return "Scans the active payment-run period (\(bounds.label)): \(startLabel) through \(endLabel). Includes past, present, and future clashes and unbooked labour inside this timeframe."
        case .endOfWorkingWeek:
            return "Scans your current week (\(startLabel) through \(endLabel)). To exclude weekends, use the toggle below."
        }
    }

    // MARK: - Private

    /// Monday of the week containing `date` (Calendar weekday: 1 = Sun … 2 = Mon).
    private static func startOfCalendarWeek(from date: Date, calendar: Calendar) -> Date {
        let weekday = calendar.component(.weekday, from: date)
        let monday = 2
        var subtract = weekday - monday
        if subtract < 0 { subtract += 7 }
        return calendar.startOfDay(for: calendar.date(byAdding: .day, value: -subtract, to: date) ?? date)
    }

    /// Sunday of the week containing `date` (Calendar weekday: 1 = Sun).
    private static func endOfCalendarWeek(from date: Date, calendar: Calendar) -> Date {
        let weekday = calendar.component(.weekday, from: date)
        let add = (8 - weekday) % 7  // days until Sunday; 0 when already Sunday
        return calendar.startOfDay(for: calendar.date(byAdding: .day, value: add, to: date) ?? date)
    }

    static func fromFirestore(_ data: [String: Any]) -> OrgWarningDetectionSettings {
        var s = OrgWarningDetectionSettings.default
        if let v = data["detectClashes"] as? Bool { s.detectClashes = v }
        if let raw = data["clashLookaheadMode"] as? String,
           let mode = WarningClashLookaheadMode(rawValue: raw) {
            s.clashLookaheadMode = mode
        }
        if let days = data["clashLookaheadDays"] as? Int {
            s.clashLookaheadDays = days
        } else if let days = data["clashLookaheadDays"] as? Double {
            s.clashLookaheadDays = Int(days)
        }
        if let v = data["includeWeekendsForUnbookedLabour"] as? Bool {
            s.includeWeekendsForUnbookedLabour = v
        }
        if let ids = data["excludedUserIdsFromUnbookedWarnings"] as? [String] {
            s.excludedUserIdsFromUnbookedWarnings = ids
        }
        return s
    }

    func asFirestoreDictionary() -> [String: Any] {
        [
            "detectClashes": detectClashes,
            "clashLookaheadMode": clashLookaheadMode.rawValue,
            "clashLookaheadDays": clashLookaheadDays,
            "includeWeekendsForUnbookedLabour": includeWeekendsForUnbookedLabour,
            "excludedUserIdsFromUnbookedWarnings": excludedUserIdsFromUnbookedWarnings,
        ]
    }
}

