//
//  OrgWarningDetectionSettings.swift
//  Project Planner
//
//  Company-wide warning detection horizon and unbooked-labour rules.
//

import Foundation

enum WarningClashLookaheadMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case endOfInvoicingPeriod
    case numberOfDays
    case endOfWorkingWeek

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .endOfInvoicingPeriod: return "Invoicing period"
        case .numberOfDays: return "Set number of days"
        case .endOfWorkingWeek: return "End of the working week"
        }
    }
}

struct OrgWarningDetectionSettings: Codable, Hashable, Sendable {
    var detectClashes: Bool
    var clashLookaheadMode: WarningClashLookaheadMode
    /// Used when `clashLookaheadMode == .numberOfDays`.
    var clashLookaheadDays: Int
    /// When true, Sat/Sun count for unbooked labour warnings only.
    var includeWeekendsForUnbookedLabour: Bool
    /// Org user ids omitted from unbooked-labour warnings (e.g. PAYE staff).
    var excludedUserIdsFromUnbookedWarnings: [String]

    static let `default` = OrgWarningDetectionSettings(
        detectClashes: true,
        clashLookaheadMode: .numberOfDays,
        clashLookaheadDays: 7,
        includeWeekendsForUnbookedLabour: false,
        excludedUserIdsFromUnbookedWarnings: []
    )

    enum CodingKeys: String, CodingKey {
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
    /// - endOfWorkingWeek: today through Friday of the current working week
    /// - endOfInvoicingPeriod: end of the current invoicing period
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
            let friday = Self.endOfWorkingWeek(from: start, calendar: calendar)
            // Never end before today (e.g. weekend after Friday → next Friday).
            return max(start, friday)
        case .endOfInvoicingPeriod:
            let periodEnd = InvoicingPeriodResolver.warningCoverageEnd(
                invoicing: invoicing,
                referenceDate: start,
                calendar: calendar
            )
            return max(start, calendar.startOfDay(for: periodEnd))
        }
    }

    /// Inclusive start of the warnings scan window.
    /// - numberOfDays / endOfWorkingWeek: today (matches settings copy “today through …”)
    /// - endOfInvoicingPeriod: current period start (clashes inside the whole period)
    func coverageStart(
        from today: Date,
        invoicing: OrganizationInvoicingSettings = .default,
        calendar: Calendar = .current
    ) -> Date {
        let start = calendar.startOfDay(for: today)
        switch clashLookaheadMode {
        case .endOfInvoicingPeriod:
            let periodStart = InvoicingPeriodResolver.resolve(
                invoicing: invoicing,
                referenceDate: start,
                calendar: calendar
            ).currentPeriodStart
            return calendar.startOfDay(for: periodStart)
        case .numberOfDays, .endOfWorkingWeek:
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

    /// Inclusive number of calendar days from today through the detection end date.
    func detectionHorizonDayCount(
        from today: Date = Date(),
        invoicing: OrganizationInvoicingSettings = .default,
        calendar: Calendar = .current
    ) -> Int {
        let start = calendar.startOfDay(for: today)
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
            let period = InvoicingPeriodResolver.resolve(invoicing: invoicing, referenceDate: today, calendar: calendar)
            return "Scans the current invoicing period (\(period.currentPeriodLabel)): \(startLabel) through \(endLabel). Clashes use the whole period; unbooked labour from today onward inside it."
        case .endOfWorkingWeek:
            return "Scans today through Friday of this working week: \(startLabel) through \(endLabel). Resets each Monday."
        }
    }

    // MARK: - Private

    /// Friday of the week containing `date` (Calendar weekday: 1 = Sun … 6 = Fri).
    private static func endOfWorkingWeek(from date: Date, calendar: Calendar) -> Date {
        let weekday = calendar.component(.weekday, from: date)
        let friday = 6
        var add = friday - weekday
        if add < 0 { add += 7 }
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

