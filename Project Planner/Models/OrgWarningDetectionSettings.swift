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
        case .endOfInvoicingPeriod: return "End of invoicing period"
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
        clashLookaheadMode: .endOfWorkingWeek,
        clashLookaheadDays: 28,
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
        clashLookaheadMode: WarningClashLookaheadMode = .endOfWorkingWeek,
        clashLookaheadDays: Int = 28,
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
        clashLookaheadMode = try c.decodeIfPresent(WarningClashLookaheadMode.self, forKey: .clashLookaheadMode) ?? .endOfWorkingWeek
        clashLookaheadDays = try c.decodeIfPresent(Int.self, forKey: .clashLookaheadDays) ?? 28
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

    /// How far ahead (from `today`) warnings should scan for clashes, unbooked labour, and materials.
    func coverageEnd(from today: Date, calendar: Calendar = .current) -> Date {
        let start = calendar.startOfDay(for: today)
        switch clashLookaheadMode {
        case .numberOfDays:
            let days = max(1, min(clashLookaheadDays, 366))
            return calendar.startOfDay(for: calendar.date(byAdding: .day, value: days, to: start) ?? start)
        case .endOfWorkingWeek:
            return Self.endOfWorkingWeek(from: start, calendar: calendar)
        case .endOfInvoicingPeriod:
            return Self.endOfInvoicingPeriodStub(from: start, calendar: calendar)
        }
    }

    /// Past window for warnings (unchanged default: 14 days back).
    func coverageStart(from today: Date, calendar: Calendar = .current) -> Date {
        let start = calendar.startOfDay(for: today)
        return calendar.startOfDay(for: calendar.date(byAdding: .day, value: -14, to: start) ?? start)
    }

    func isUnbookedLabourWeekday(_ weekday: Int) -> Bool {
        if includeWeekendsForUnbookedLabour {
            return weekday >= 1 && weekday <= 7
        }
        return weekday >= 2 && weekday <= 6
    }

    /// Human-readable end of the detection window (from today).
    func detectionHorizonEndLabel(from today: Date = Date(), calendar: Calendar = .current) -> String {
        let end = coverageEnd(from: today, calendar: calendar)
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter.string(from: end)
    }

    /// Inclusive number of calendar days from today through the detection end date.
    func detectionHorizonDayCount(from today: Date = Date(), calendar: Calendar = .current) -> Int {
        let start = calendar.startOfDay(for: today)
        let end = coverageEnd(from: today, calendar: calendar)
        let days = calendar.dateComponents([.day], from: start, to: end).day ?? 0
        return max(1, days + 1)
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

    /// Placeholder until invoicing periods exist: last day of the current calendar month.
    private static func endOfInvoicingPeriodStub(from date: Date, calendar: Calendar) -> Date {
        var comps = calendar.dateComponents([.year, .month], from: date)
        comps.day = 1
        guard let monthStart = calendar.date(from: comps),
              let nextMonth = calendar.date(byAdding: .month, value: 1, to: monthStart),
              let lastDay = calendar.date(byAdding: .day, value: -1, to: nextMonth) else {
            return date
        }
        return calendar.startOfDay(for: lastDay)
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

