//
//  WarningModels.swift
//  Project Planner
//

import Foundation
import CoreGraphics

nonisolated struct Warning: Identifiable, Hashable, Codable, Sendable {
    nonisolated var id: String { resolutionKey }
    let resolutionKey: String
    let type: WarningType
    let title: String
    let message: String
    let severity: WarningSeverity
    var occurrenceDate: Date?

    var operativeClash: OperativeClashWarningDetails?
    var managerClash: ManagerClashWarningDetails?
    var unbookedLabour: UnbookedLabourWarningDetails?
    var materialsCutoff: MaterialsCutoffWarningDetails?
    var bookingClashDetails: BookingClashDetails?
    var operativeEmail: String?

    enum WarningType: String, Hashable, Codable {
        case operativeBookingClash
        case managerLocationClash
        case unbookedLabour
        case materialsCutoff
        case qualificationExpiry
        case operativeNotVerified
    }

    enum WarningSeverity: String, Hashable, CaseIterable, Codable {
        case low
        case medium
        case high
    }

    /// Who the clash belongs to — titles and weekly-report type labels use this.
    enum ClashPersonKind: String, Hashable, Codable {
        case operative
        case manager
        case admin

        nonisolated var bookingClashTitle: String {
            switch self {
            case .operative: return "Operative booking clash"
            case .manager: return "Manager booking clash"
            case .admin: return "Admin booking clash"
            }
        }
    }

    /// High / medium / low scheduling warnings (excludes qualification & verification).
    var isCorePriorityWarning: Bool {
        switch type {
        case .operativeBookingClash, .unbookedLabour, .managerLocationClash, .materialsCutoff:
            return true
        case .qualificationExpiry, .operativeNotVerified:
            return false
        }
    }

    /// Operative, manager, and admin booking clashes can be ticked onto the weekly report.
    var requiresWeeklyReportApproval: Bool {
        type == .operativeBookingClash || type == .managerLocationClash
    }

    var clashPersonKind: ClashPersonKind? {
        if type == .operativeBookingClash { return .operative }
        return managerClash?.resolvedPersonKind
    }

    var clashEntries: [ClashTimelineEntry] {
        if let clash = operativeClash { return clash.allEntries }
        if let clash = managerClash { return clash.allEntries }
        return []
    }

    var clashPersonName: String? {
        operativeClash?.operativeName ?? managerClash?.personName
    }

    var clashDate: Date? {
        operativeClash?.date ?? managerClash?.date ?? occurrenceDate
    }

    /// Human-readable summary for admin notifications when a warning is removed without resolving.
    var removalNotificationDetail: String {
        let dateText = occurrenceDate.map {
            $0.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).year())
        } ?? ""

        switch type {
        case .operativeBookingClash:
            if let clash = operativeClash {
                let places = clash.allEntries.map { entry in
                    if let jobNumber = entry.jobNumber {
                        if let siteName = entry.siteName {
                            return "\(jobNumber) (\(siteName))"
                        }
                        return jobNumber
                    }
                    return entry.locationLabel
                }.joined(separator: " · ")
                return "\(clash.operativeName) on \(dateText): \(title). \(places). \(clash.overlapSummary)."
            }
        case .managerLocationClash:
            if let clash = managerClash {
                let places = clash.allEntries.map { entry in
                    if let jobNumber = entry.jobNumber {
                        if let siteName = entry.siteName {
                            return "\(jobNumber) (\(siteName))"
                        }
                        return jobNumber
                    }
                    return entry.locationLabel
                }.joined(separator: " · ")
                return "\(clash.personName) on \(dateText): \(title). \(places). \(clash.overlapSummary)."
            }
        case .unbookedLabour:
            if let detail = unbookedLabour {
                let names = detail.names.joined(separator: ", ")
                return "\(title) on \(dateText): \(names). \(message)"
            }
        case .materialsCutoff:
            if let detail = materialsCutoff {
                return "\(title): \(detail.jobNumber) · \(detail.siteName). \(message)"
            }
        case .qualificationExpiry, .operativeNotVerified:
            break
        }
        if dateText.isEmpty {
            return "\(title). \(message)"
        }
        return "\(title) on \(dateText). \(message)"
    }

    struct ClashTimelineEntry: Hashable, Codable, Sendable {
        var bookingId: UUID
        var managerBookingId: UUID?
        var jobNumber: String?
        var siteName: String?
        var isSmallWorks: Bool
        var locationLabel: String
        var timeLabel: String
        var startMinutes: Int
        var endMinutes: Int
        var hoursLabel: String

        nonisolated var span: (Int, Int) { (startMinutes, endMinutes) }

        /// Full-day / all-day bands (WFH, office, FULL DAY) — hatched on the clash strip.
        nonisolated var treatsAsAllDay: Bool {
            let span = max(0, endMinutes - startMinutes)
            if span >= (23 * 60) { return true }
            let t = timeLabel.lowercased()
            let h = hoursLabel.lowercased()
            return t.contains("full day") || t == "all day" || t.contains("full-day") || h.contains("full day")
        }

        nonisolated var displayTitle: String {
            if let siteName, jobNumber != nil {
                return siteName
            }
            return locationLabel
        }

        nonisolated var rowId: String {
            if let managerBookingId { return "m-\(managerBookingId.uuidString)" }
            return "o-\(bookingId.uuidString)"
        }
    }

    struct OperativeClashWarningDetails: Hashable, Codable, Sendable {
        var operativeId: UUID
        var operativeName: String
        var date: Date
        var bookingAId: UUID
        var bookingBId: UUID
        var entryA: ClashTimelineEntry
        var entryB: ClashTimelineEntry
        var overlapMinutes: Int
        var overlapSummary: String
        var overlapDetail: String
        /// All overlapping bookings for this person on this day. Falls back to A/B for older caches.
        var entries: [ClashTimelineEntry]? = nil

        var allEntries: [ClashTimelineEntry] {
            if let entries, entries.count >= 2 { return entries }
            return [entryA, entryB]
        }
    }

    struct ManagerClashWarningDetails: Hashable, Codable, Sendable {
        var userId: String
        var personName: String
        var date: Date
        var bookingAId: UUID
        var bookingBId: UUID
        var entryA: ClashTimelineEntry
        var entryB: ClashTimelineEntry
        var overlapMinutes: Int
        var overlapSummary: String
        var overlapDetail: String
        var isLocationClash: Bool
        var personKind: ClashPersonKind? = nil
        /// All overlapping bookings for this person on this day. Falls back to A/B for older caches.
        var entries: [ClashTimelineEntry]? = nil

        var resolvedPersonKind: ClashPersonKind { personKind ?? .manager }

        var allEntries: [ClashTimelineEntry] {
            if let entries, entries.count >= 2 { return entries }
            return [entryA, entryB]
        }
    }

    struct UnbookedLabourWarningDetails: Hashable, Codable, Sendable {
        var date: Date
        var names: [String]
        var personKeys: [String] = []

        init(date: Date, names: [String], personKeys: [String] = []) {
            self.date = date
            self.names = names
            self.personKeys = personKeys
        }

        enum CodingKeys: String, CodingKey {
            case date, names, personKeys
        }

        nonisolated init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            date = try c.decode(Date.self, forKey: .date)
            names = try c.decodeIfPresent([String].self, forKey: .names) ?? []
            personKeys = try c.decodeIfPresent([String].self, forKey: .personKeys) ?? []
        }

        nonisolated func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(date, forKey: .date)
            try c.encode(names, forKey: .names)
            try c.encode(personKeys, forKey: .personKeys)
        }
    }

    struct MaterialsCutoffWarningDetails: Hashable, Codable, Sendable {
        var projectId: UUID
        var jobNumber: String
        var siteName: String
        var targetDate: Date
        var itemCount: Int?
    }

    struct BookingClashDetails: Hashable, Codable, Sendable {
        var user1Name: String
        var user2Name: String
        var project1Number: String?
        var project1Name: String?
        var project2Number: String?
        var project2Name: String?
        var smallWork1Number: String?
        var smallWork1Name: String?
        var smallWork2Number: String?
        var smallWork2Name: String?
        var timeSlot1: String
        var timeSlot2: String
        var date: Date
        var operativeName: String
    }
    /// Person or people affected by this warning (for weekly report export).
    var affectedPersonNames: String {
        switch type {
        case .operativeBookingClash:
            return operativeClash?.operativeName ?? title
        case .managerLocationClash:
            return managerClash?.personName ?? title
        case .unbookedLabour:
            return unbookedLabour?.names.joined(separator: ", ") ?? ""
        case .materialsCutoff, .qualificationExpiry, .operativeNotVerified:
            return ""
        }
    }
}

enum WarningTimelineMath: Sendable {
    nonisolated static let dayMinutes = 24 * 60

    nonisolated static func overlapMinutes(_ a: (Int, Int), _ b: (Int, Int)) -> Int {
        let start = max(a.0, b.0)
        let end = min(a.1, b.1)
        return max(0, end - start)
    }

    nonisolated static func overlapFraction(_ a: (Int, Int), _ b: (Int, Int)) -> (start: CGFloat, width: CGFloat) {
        let start = max(a.0, b.0)
        let end = min(a.1, b.1)
        guard end > start else { return (0, 0) }
        return (
            CGFloat(start) / CGFloat(dayMinutes),
            CGFloat(end - start) / CGFloat(dayMinutes)
        )
    }

    nonisolated static func barFraction(start: Int, end: Int) -> (left: CGFloat, width: CGFloat) {
        let s = max(0, min(start, dayMinutes))
        let e = max(s, min(end, dayMinutes))
        return (CGFloat(s) / CGFloat(dayMinutes), CGFloat(e - s) / CGFloat(dayMinutes))
    }

    nonisolated static func formatMinutesRange(_ start: Int, _ end: Int) -> String {
        func hhmm(_ m: Int) -> String {
            let h = m / 60
            let min = m % 60
            return String(format: "%d:%02d", h, min)
        }
        return "\(hhmm(start)) – \(hhmm(end))"
    }

    nonisolated static func formatOverlapSummary(minutes: Int) -> (summary: String, detail: String) {
        if minutes >= dayMinutes - 30 {
            return ("Whole day clash", "Two locations booked at the same time")
        }
        let hours = Double(minutes) / 60.0
        let hStr: String
        if abs(hours - hours.rounded()) < 0.05 {
            hStr = String(format: "%.0f", hours.rounded())
        } else {
            hStr = String(format: "%.1f", hours)
        }
        return ("\(hStr)-hour overlap", "Both bookings active during the overlapping period")
    }

    nonisolated static func placeWord(_ count: Int) -> String {
        switch count {
        case 2: return "two"
        case 3: return "three"
        default: return "\(count)"
        }
    }

    struct ClashWindow: Sendable {
        var startMinutes: Int
        var endMinutes: Int
        var span: Int { max(1, endMinutes - startMinutes) }
    }

    struct ClashRegion: Sendable {
        var startMinutes: Int
        var endMinutes: Int
        var concurrency: Int
    }

    struct ClashAnalysis: Sendable {
        var regions: [ClashRegion]
        var minutes: Int
        var peak: Int
        var startMinutes: Int?
        var endMinutes: Int?
    }

    nonisolated static func formatClock(_ minutes: Int) -> String {
        let clamped = max(0, min(minutes, dayMinutes))
        if clamped == dayMinutes { return "24:00" }
        return String(format: "%02d:%02d", clamped / 60, clamped % 60)
    }

    nonisolated static func formatDuration(minutes: Int) -> String {
        let h = Double(max(0, minutes)) / 60.0
        if h > 0 && h < 1 { return "\(Int((h * 60).rounded()))m" }
        let r = (h * 10).rounded() / 10
        if abs(r - r.rounded()) < 0.05 {
            return "\(Int(r.rounded()))h"
        }
        return String(format: "%.1fh", r)
    }

    /// Fit the timeline to the booked day (prototype: pad 1h, minimum 8h span).
    nonisolated static func fitWindow(entries: [Warning.ClashTimelineEntry]) -> ClashWindow {
        let timed = entries.filter { !$0.treatsAsAllDay }
        guard !timed.isEmpty else { return ClashWindow(startMinutes: 6 * 60, endMinutes: 20 * 60) }
        var start = max(0, (timed.map(\.startMinutes).min() ?? 0) / 60 * 60 - 60)
        var end = min(dayMinutes, Int((Double(timed.map(\.endMinutes).max() ?? dayMinutes) / 60.0).rounded(.up) * 60) + 60)
        var guardCount = 0
        while end - start < 8 * 60 && guardCount < 48 {
            guardCount += 1
            if start > 0 { start = max(0, start - 60) }
            else if end < dayMinutes { end = min(dayMinutes, end + 60) }
            else { break }
        }
        return ClashWindow(startMinutes: start, endMinutes: end)
    }

    nonisolated static func axisTicks(_ window: ClashWindow) -> [Int] {
        let spanHours = Double(window.span) / 60.0
        let steps = [1, 2, 3, 4, 6]
        for step in steps {
            if Int(spanHours / Double(step)) + 1 <= 6 {
                let stepMin = step * 60
                var ticks: [Int] = []
                var t = Int((Double(window.startMinutes) / Double(stepMin)).rounded(.up)) * stepMin
                while t <= window.endMinutes {
                    ticks.append(t)
                    t += stepMin
                }
                return ticks.isEmpty ? [window.startMinutes, window.endMinutes] : ticks
            }
        }
        return [window.startMinutes, window.endMinutes]
    }

    nonisolated static func interval(of entry: Warning.ClashTimelineEntry, window: ClashWindow) -> (Int, Int) {
        let start = max(window.startMinutes, min(entry.startMinutes, window.endMinutes))
        let end = max(start, min(entry.endMinutes, window.endMinutes))
        return (start, end)
    }

    nonisolated static func analyse(entries: [Warning.ClashTimelineEntry], window: ClashWindow) -> ClashAnalysis {
        let ivs = entries.map { interval(of: $0, window: window) }
        let pts = Array(Set(ivs.flatMap { [$0.0, $0.1] })).sorted()
        var raw: [ClashRegion] = []
        if pts.count >= 2 {
            for i in 0..<(pts.count - 1) {
                let start = pts[i]
                let end = pts[i + 1]
                let concurrency = ivs.filter { $0.0 < end && $0.1 > start }.count
                if concurrency >= 2 {
                    raw.append(ClashRegion(startMinutes: start, endMinutes: end, concurrency: concurrency))
                }
            }
        }
        var regions: [ClashRegion] = []
        for r in raw {
            if let last = regions.last, last.endMinutes == r.startMinutes {
                regions[regions.count - 1].endMinutes = r.endMinutes
                regions[regions.count - 1].concurrency = max(last.concurrency, r.concurrency)
            } else {
                regions.append(r)
            }
        }
        return ClashAnalysis(
            regions: regions,
            minutes: regions.reduce(0) { $0 + ($1.endMinutes - $1.startMinutes) },
            peak: raw.map(\.concurrency).max() ?? 0,
            startMinutes: regions.first?.startMinutes,
            endMinutes: regions.last?.endMinutes
        )
    }

    nonisolated static func clashMinutes(
        for entry: Warning.ClashTimelineEntry,
        window: ClashWindow,
        analysis: ClashAnalysis
    ) -> Int {
        let iv = interval(of: entry, window: window)
        return analysis.regions.reduce(0) { sum, region in
            sum + max(0, min(region.endMinutes, iv.1) - max(region.startMinutes, iv.0))
        }
    }

    nonisolated static func fraction(in window: ClashWindow, minutes: Int) -> CGFloat {
        CGFloat(minutes - window.startMinutes) / CGFloat(window.span)
    }
}
