//
//  WarningModels.swift
//  Project Planner
//

import Foundation

struct Warning: Identifiable, Hashable {
    var id: String { resolutionKey }
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

    enum WarningType: String, Hashable {
        case operativeBookingClash
        case managerLocationClash
        case unbookedLabour
        case materialsCutoff
        case qualificationExpiry
        case operativeNotVerified
    }

    enum WarningSeverity: String, Hashable, CaseIterable {
        case low
        case medium
        case high
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

    /// Only manager/admin schedule overlaps are ticked to appear on the weekly report.
    var requiresWeeklyReportApproval: Bool {
        type == .managerLocationClash
    }

    struct ClashTimelineEntry: Hashable, Codable {
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
    }

    struct OperativeClashWarningDetails: Hashable, Codable {
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
    }

    struct ManagerClashWarningDetails: Hashable, Codable {
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
    }

    struct UnbookedLabourWarningDetails: Hashable, Codable {
        var date: Date
        var names: [String]
    }

    struct MaterialsCutoffWarningDetails: Hashable, Codable {
        var projectId: UUID
        var jobNumber: String
        var siteName: String
        var targetDate: Date
        var itemCount: Int?
    }

    struct BookingClashDetails: Hashable, Codable {
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
}

enum WarningTimelineMath {
    static let dayMinutes = 24 * 60

    static func overlapMinutes(_ a: (Int, Int), _ b: (Int, Int)) -> Int {
        let start = max(a.0, b.0)
        let end = min(a.1, b.1)
        return max(0, end - start)
    }

    static func overlapFraction(_ a: (Int, Int), _ b: (Int, Int)) -> (start: CGFloat, width: CGFloat) {
        let start = max(a.0, b.0)
        let end = min(a.1, b.1)
        guard end > start else { return (0, 0) }
        return (
            CGFloat(start) / CGFloat(dayMinutes),
            CGFloat(end - start) / CGFloat(dayMinutes)
        )
    }

    static func barFraction(start: Int, end: Int) -> (left: CGFloat, width: CGFloat) {
        let s = max(0, min(start, dayMinutes))
        let e = max(s, min(end, dayMinutes))
        return (CGFloat(s) / CGFloat(dayMinutes), CGFloat(e - s) / CGFloat(dayMinutes))
    }

    static func formatMinutesRange(_ start: Int, _ end: Int) -> String {
        func hhmm(_ m: Int) -> String {
            let h = m / 60
            let min = m % 60
            return String(format: "%d:%02d", h, min)
        }
        return "\(hhmm(start)) – \(hhmm(end))"
    }

    static func formatOverlapSummary(minutes: Int) -> (summary: String, detail: String) {
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
}
