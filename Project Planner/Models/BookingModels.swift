//
//  BookingModels.swift
//  Project Planner
//
//  Created by Assistant on 29/09/2025.
//

import Foundation

// MARK: - Booking Models

struct Booking: Identifiable, Codable, Hashable {
    let id: UUID
    var operativeId: UUID
    var projectId: UUID
    var date: Date
    var timeSlot: TimeSlot
    var bookedBy: String
    var notes: String?
    var status: BookingStatus
    /// Clock window when `timeSlot == .customHours`, `"HH:mm"`.
    var workStartTime: String?
    var workEndTime: String?
    var isBreakRemoved: Bool
    /// When set, weekday OT outside the org standard window uses this multiplier instead of `OrgPayrollTimePolicy.weekdayOutsideStandardMultiplier`.
    var otMultiplierOverride: Double?
    var bookingGroupId: String?
    var createdAt: Date
    var updatedAt: Date
    /// Stored Firestore strings when they are not the UUIDs above. Web books a person who has no
    /// operative record under their `users/{uid}` id, which is not a UUID; the UUID fields then hold
    /// `StableBookingIdentity.uuid(for:)` and these keep the real id for coverage, lookups and saves.
    var storedOperativeId: String? = nil
    var storedProjectId: String? = nil
    var documentId: String? = nil

    /// The id written to `operativeId`.
    var operativeKey: String {
        storedOperativeId ?? StableBookingIdentity.rawId(for: operativeId) ?? operativeId.uuidString
    }
    /// The id written to `projectId`.
    var projectKey: String { storedProjectId ?? projectId.uuidString }
    /// The Firestore document id under `organizations/{orgId}/bookings`.
    var documentKey: String { documentId ?? id.uuidString }

    init(
        id: UUID = UUID(),
        operativeId: UUID,
        projectId: UUID,
        date: Date,
        timeSlot: TimeSlot,
        bookedBy: String,
        notes: String? = nil,
        status: BookingStatus = .confirmed,
        workStartTime: String? = nil,
        workEndTime: String? = nil,
        isBreakRemoved: Bool = false,
        otMultiplierOverride: Double? = nil,
        bookingGroupId: String? = nil,
        createdAt: Date? = nil,
        updatedAt: Date? = nil
    ) {
        self.id = id
        self.operativeId = operativeId
        self.projectId = projectId
        self.date = date
        self.timeSlot = timeSlot
        self.bookedBy = bookedBy
        self.notes = notes
        self.status = status
        self.workStartTime = workStartTime
        self.workEndTime = workEndTime
        self.isBreakRemoved = isBreakRemoved
        self.otMultiplierOverride = otMultiplierOverride
        self.bookingGroupId = bookingGroupId
        self.createdAt = createdAt ?? Date()
        self.updatedAt = updatedAt ?? Date()
    }
}

/// Per-day operative selection in multi-day scheduling (legacy slot and/or explicit hours).
struct OperativeDayBookingChoice: Equatable, Hashable {
    var timeSlot: TimeSlot
    var workStartTime: String?
    var workEndTime: String?
    var isBreakRemoved: Bool
    /// Optional OT multiplier for weekday hours outside the org standard window (nil = org default).
    var otMultiplierOverride: Double?

    init(timeSlot: TimeSlot, workStartTime: String? = nil, workEndTime: String? = nil, isBreakRemoved: Bool = false, otMultiplierOverride: Double? = nil) {
        self.timeSlot = timeSlot
        self.workStartTime = workStartTime
        self.workEndTime = workEndTime
        self.isBreakRemoved = isBreakRemoved
        self.otMultiplierOverride = otMultiplierOverride
    }

    static func legacy(_ slot: TimeSlot) -> OperativeDayBookingChoice {
        OperativeDayBookingChoice(timeSlot: slot, workStartTime: nil, workEndTime: nil, isBreakRemoved: false, otMultiplierOverride: nil)
    }
}

enum TimeSlot: String, CaseIterable, Identifiable, Codable {
    case morning = "AM"
    case afternoon = "PM"
    case fullDay = "FULL DAY"
    case evening = "Evening"
    case overtime = "Overtime"
    case customHours = "CUSTOM_HOURS"

    /// Web and iOS have stored the same day as `FULL DAY` and `FULL_DAY`. Both load.
    static func fromStored(_ raw: String) -> TimeSlot? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let direct = TimeSlot(rawValue: trimmed) { return direct }
        switch CanonicalBusinessEngine.namedSlotKind(trimmed) {
        case "FULL_DAY": return .fullDay
        case "AM": return .morning
        case "PM": return .afternoon
        case "CUSTOM": return .customHours
        case "EVENING": return .evening
        case "OVERTIME": return .overtime
        default: return nil
        }
    }

    /// Pickers that only use slot labels (excludes clock-based `customHours`).
    static var legacyPickerCases: [TimeSlot] {
        [.morning, .afternoon, .fullDay, .evening, .overtime]
    }
    
    var id: String { rawValue }
    
    var displayName: String {
        switch self {
        case .morning: return "AM"
        case .afternoon: return "PM"
        case .fullDay: return "FULL DAY"
        case .evening: return "Evening"
        case .overtime: return "Overtime"
        case .customHours: return "Custom"
        }
    }
    
    var shortDisplayName: String {
        switch self {
        case .morning: return "AM"
        case .afternoon: return "PM"
        case .fullDay: return "FULL DAY"
        case .evening: return "Eve"
        case .overtime: return "OT"
        case .customHours: return "Custom"
        }
    }
    
    var duration: TimeInterval {
        switch self {
        case .morning, .afternoon: return 4 * 3600 // 4 hours
        case .fullDay, .customHours: return 8 * 3600 // 8 hours
        case .evening: return 4 * 3600 // 4 hours
        case .overtime: return 2 * 3600 // 2 hours
        }
    }
    
    var startTime: Date {
        let calendar = Calendar.current
        let components = calendar.dateComponents([.year, .month, .day], from: Date())
        
        switch self {
        case .morning, .fullDay, .customHours:
            return calendar.date(from: DateComponents(
                year: components.year,
                month: components.month,
                day: components.day,
                hour: 8
            )) ?? Date()
        case .afternoon:
            return calendar.date(from: DateComponents(
                year: components.year,
                month: components.month,
                day: components.day,
                hour: 13
            )) ?? Date()
        case .evening:
            return calendar.date(from: DateComponents(
                year: components.year,
                month: components.month,
                day: components.day,
                hour: 17
            )) ?? Date()
        case .overtime:
            return calendar.date(from: DateComponents(
                year: components.year,
                month: components.month,
                day: components.day,
                hour: 17
            )) ?? Date()
        }
    }
}

nonisolated enum BookingStatus: String, CaseIterable, Identifiable, Codable, Sendable {
    case confirmed = "Confirmed"
    case tentative = "Tentative"
    case cancelled = "Cancelled"
    case completed = "Completed"
    
    var id: String { rawValue }

    /// Whether this status puts the person on a job that day (`bookingOccupiesDay`): Confirmed,
    /// Tentative and Completed do; Cancelled does not. Coverage, Daily Overview and clashes use this.
    var occupiesDay: Bool {
        BookingStatus.occupiesDayMemo[self] ?? false
    }

    /// One script answer per status, cached once the script has answered for all four.
    private static let occupiesDayMemo: [BookingStatus: Bool] = {
        var memo: [BookingStatus: Bool] = [:]
        for status in allCases {
            if let answer = CanonicalBusinessEngine.bookingOccupiesDay(status.rawValue) { memo[status] = answer }
        }
        return memo
    }()
    
    var color: String {
        switch self {
        case .confirmed: return "green"
        case .tentative: return "yellow"
        case .cancelled: return "red"
        case .completed: return "blue"
        }
    }
}

// MARK: - Booking Conflict Models

struct BookingConflict: Identifiable, Hashable {
    let id: UUID = UUID()
    let date: Date
    let operative: Operative
    let conflictingBookings: [Booking]
    let severity: ConflictSeverity
    
    init(date: Date, operative: Operative, conflictingBookings: [Booking]) {
        self.date = date
        self.operative = operative
        self.conflictingBookings = conflictingBookings
        
        // Determine severity based on booking types
        let hasFullDay = conflictingBookings.contains { $0.timeSlot == .fullDay }
        let hasMultipleFullDay = conflictingBookings.filter { $0.timeSlot == .fullDay }.count > 1
        
        if hasMultipleFullDay {
            self.severity = .critical
        } else if hasFullDay {
            self.severity = .high
        } else if conflictingBookings.count > 2 {
            self.severity = .medium
        } else {
            self.severity = .low
        }
    }
}

enum ConflictSeverity: String, CaseIterable {
    case low = "Low"
    case medium = "Medium"
    case high = "High"
    case critical = "Critical"
    
    var color: String {
        switch self {
        case .low: return "yellow"
        case .medium: return "orange"
        case .high: return "red"
        case .critical: return "purple"
        }
    }
    
    var description: String {
        switch self {
        case .low: return "Minor scheduling conflict"
        case .medium: return "Moderate scheduling conflict"
        case .high: return "Significant scheduling conflict"
        case .critical: return "Critical scheduling conflict"
        }
    }
}

