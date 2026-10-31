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
    /// `parseWarningDetection(raw).clashLookaheadDaysFallback` (`lookaheadDaysMissing` / `lookaheadDaysInvalid`):
    /// the saved "Set number of days" could not be used, so the scan used 7. Never written to Firestore;
    /// cleared when the user picks a mode or a number on the settings screen.
    var clashLookaheadDaysFallback: String? = nil

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
        case clashLookaheadDaysFallback
    }

    init?(canonical: CanonicalBusinessEngine.CanonicalWarningDetection, clashLookaheadDaysFallback: String? = nil) {
        guard let mode = WarningClashLookaheadMode(rawValue: canonical.clashLookaheadMode) else { return nil }
        self.init(
            detectClashes: canonical.detectClashes,
            clashLookaheadMode: mode,
            clashLookaheadDays: canonical.clashLookaheadDays,
            includeWeekendsForUnbookedLabour: canonical.includeWeekendsForUnbookedLabour,
            excludedUserIdsFromUnbookedWarnings: canonical.excludedUserIdsFromUnbookedWarnings
        )
        self.clashLookaheadDaysFallback = clashLookaheadDaysFallback
    }

    /// `parseWarningDetection(raw)` with its fallback reason kept. Nil when the script did not answer.
    init?(firestoreRaw raw: [String: Any]?) {
        guard let parsed = CanonicalBusinessEngine.parseWarningDetection(raw) else { return nil }
        self.init(
            canonical: parsed,
            clashLookaheadDaysFallback: CanonicalBusinessEngine.warningLookaheadDaysFallback(raw: raw)
        )
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
        clashLookaheadDaysFallback = try c.decodeIfPresent(String.self, forKey: .clashLookaheadDaysFallback)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(detectClashes, forKey: .detectClashes)
        try c.encode(clashLookaheadMode, forKey: .clashLookaheadMode)
        try c.encode(clashLookaheadDays, forKey: .clashLookaheadDays)
        try c.encode(includeWeekendsForUnbookedLabour, forKey: .includeWeekendsForUnbookedLabour)
        try c.encode(excludedUserIdsFromUnbookedWarnings, forKey: .excludedUserIdsFromUnbookedWarnings)
        try c.encodeIfPresent(clashLookaheadDaysFallback, forKey: .clashLookaheadDaysFallback)
    }

    // The scan window, its Full week days and its summary copy come from the script
    // (`CanonicalBusinessEngine.warningScanWindow`: `coverageWindow`, `clashScanDays`). No Swift calendar here.

    /// Notice for `coverageWindow.fallbackReason` (RULEBOOK §5: never a silent fallback). Same words as web
    /// `warningLookaheadFallbackNotice`. Nil when the saved number of days was used.
    static func lookaheadFallbackNotice(_ reason: String?) -> String? {
        switch reason {
        case "lookaheadDaysMissing":
            return "No number of days is saved for this company, so warnings scan 7 days (today and the next 6). Choose a number and save to change it."
        case "lookaheadDaysInvalid":
            return "The saved number of days is not valid, so warnings scan 7 days (today and the next 6). Choose a number and save to fix it."
        default:
            return nil
        }
    }

    static func fromFirestore(_ data: [String: Any]) -> OrgWarningDetectionSettings {
        var s = OrgWarningDetectionSettings.default
        if let clashes = firestoreBool(data["detectClashes"]) { s.detectClashes = clashes }
        if let raw = data["clashLookaheadMode"] as? String,
           let mode = WarningClashLookaheadMode(rawValue: raw) {
            s.clashLookaheadMode = mode
        }
        if let days = firestoreInt(data["clashLookaheadDays"]) {
            s.clashLookaheadDays = days
        }
        if let weekends = firestoreBool(data["includeWeekendsForUnbookedLabour"]) {
            s.includeWeekendsForUnbookedLabour = weekends
        }
        s.excludedUserIdsFromUnbookedWarnings = excludedUserIds(from: data)
        return s
    }

    /// Canonical key wins when it parses to at least one id. An empty or unreadable
    /// value falls through to older names. Firestore often hands the array back as
    /// `NSArray`, which does not cast to `[String]`.
    static func excludedUserIds(from data: [String: Any]) -> [String] {
        let canonical = stringIds(from: data["excludedUserIdsFromUnbookedWarnings"])
        if !canonical.isEmpty { return canonical }
        let keys = [
            "excludedUserIds",
            "excludedUsers",
            "excludedUserIdsFromWarnings",
            "unbookedWarningExcludedUserIds",
        ]
        var ids: [String] = []
        var seen = Set<String>()
        for key in keys {
            for id in stringIds(from: data[key]) where seen.insert(id).inserted {
                ids.append(id)
            }
        }
        return ids
    }

    private static func stringIds(from value: Any?) -> [String] {
        guard let value else { return [] }
        if value is NSNull { return [] }
        if let ids = value as? [String] {
            return cleaned(ids)
        }
        if let text = value as? String {
            return cleaned(text.split(separator: ",").map(String.init))
        }
        if let map = value as? [String: Any] {
            if let one = idString(from: map) { return [one] }
            return cleaned(map.compactMap { key, raw -> String? in
                if raw is NSNull { return nil }
                if let flag = raw as? Bool, flag == false { return nil }
                return key
            })
        }
        if let rows = value as? [Any] {
            return cleaned(rows.compactMap(idString(from:)))
        }
        if let rows = value as? NSArray {
            return cleaned(rows.compactMap { idString(from: $0) })
        }
        let mirror = Mirror(reflecting: value)
        if mirror.displayStyle == .collection || mirror.displayStyle == .set {
            return cleaned(mirror.children.compactMap { idString(from: $0.value) })
        }
        return []
    }

    private static func idString(from value: Any) -> String? {
        if let text = value as? String {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        if let map = value as? [String: Any] {
            for key in ["id", "userId", "uid", "userID"] {
                if let text = map[key] as? String {
                    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty { return trimmed }
                }
            }
        }
        return nil
    }

    private static func cleaned(_ ids: [String]) -> [String] {
        var seen = Set<String>()
        return ids
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    private static func firestoreInt(_ value: Any?) -> Int? {
        if let days = value as? Int { return days }
        if let days = value as? Int64 { return Int(days) }
        if let days = value as? Double { return Int(days) }
        if let days = value as? NSNumber { return days.intValue }
        if let text = value as? String, let days = Int(text.trimmingCharacters(in: .whitespacesAndNewlines)) {
            return days
        }
        return nil
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

