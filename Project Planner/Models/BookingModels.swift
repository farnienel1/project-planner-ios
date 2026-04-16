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
    var createdAt: Date
    var updatedAt: Date
    
    init(
        id: UUID = UUID(),
        operativeId: UUID,
        projectId: UUID,
        date: Date,
        timeSlot: TimeSlot,
        bookedBy: String,
        notes: String? = nil,
        status: BookingStatus = .confirmed,
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
        self.createdAt = createdAt ?? Date()
        self.updatedAt = updatedAt ?? Date()
    }
}

enum TimeSlot: String, CaseIterable, Identifiable, Codable {
    case morning = "AM"
    case afternoon = "PM"
    case fullDay = "FULL DAY"
    case evening = "Evening"
    case overtime = "Overtime"
    
    var id: String { rawValue }
    
    var displayName: String {
        switch self {
        case .morning: return "AM"
        case .afternoon: return "PM"
        case .fullDay: return "FULL DAY"
        case .evening: return "Evening"
        case .overtime: return "Overtime"
        }
    }
    
    var shortDisplayName: String {
        switch self {
        case .morning: return "AM"
        case .afternoon: return "PM"
        case .fullDay: return "FULL DAY"
        case .evening: return "Eve"
        case .overtime: return "OT"
        }
    }
    
    var duration: TimeInterval {
        switch self {
        case .morning, .afternoon: return 4 * 3600 // 4 hours
        case .fullDay: return 8 * 3600 // 8 hours
        case .evening: return 4 * 3600 // 4 hours
        case .overtime: return 2 * 3600 // 2 hours
        }
    }
    
    var startTime: Date {
        let calendar = Calendar.current
        let components = calendar.dateComponents([.year, .month, .day], from: Date())
        
        switch self {
        case .morning, .fullDay:
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

enum BookingStatus: String, CaseIterable, Identifiable, Codable {
    case confirmed = "Confirmed"
    case tentative = "Tentative"
    case cancelled = "Cancelled"
    case completed = "Completed"
    
    var id: String { rawValue }
    
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

