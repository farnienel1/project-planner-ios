//
//  BookingModels.swift
//  Project Planner
//
//  Created by Assistant on 29/09/2025.
//

import CryptoKit
import Foundation

// MARK: - Booking Models

struct Booking: Identifiable, Codable, Hashable {
    let id: UUID
    /// In-app key for the booked person. A stored `operativeId` that is not a UUID (a Firebase Auth uid,
    /// web #189) maps to a stable UUID from `internalOperativeId(for:)`; `operativeKey` keeps the stored text.
    var operativeId: UUID
    /// The `operativeId` exactly as Firestore stores it. Nil on bookings made before this field existed.
    var operativeKey: String?
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

    /// The `operativeId` written to Firestore: the stored text when known, else the person behind a
    /// mapped id, else the UUID itself.
    var storedOperativeId: String {
        if let key = operativeKey?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty { return key }
        return Self.storedOperativeId(for: operativeId)
    }

    /// The stored id behind an in-app operative key (a Firebase Auth uid mapped by `internalOperativeId(for:)`).
    nonisolated static func storedOperativeId(for internalId: UUID) -> String {
        OperativeKeyRegistry.shared.rawKey(for: internalId) ?? internalId.uuidString
    }

    /// In-app UUID for a stored `operativeId`. A UUID is used as is. Any other id (a Firebase Auth uid)
    /// gets a stable name-based UUID, and the pair is remembered so saves write the original id back.
    /// Bookings read from this phone's saved copy carry `operativeKey` but have not been through
    /// `internalOperativeId(for:)` yet. Register their ids so warnings and names use the stored id before the server answers.
    nonisolated static func registerStoredOperativeKeys(_ bookings: [Booking]) {
        for booking in bookings {
            guard let key = booking.operativeKey?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !key.isEmpty, UUID(uuidString: key) == nil else { continue }
            OperativeKeyRegistry.shared.remember(raw: key, as: booking.operativeId)
        }
    }

    /// The rulebook's `bookingOccupiesDay` for this booking's status.
    nonisolated var occupiesDay: Bool { status.occupiesDay }

    nonisolated static func internalOperativeId(for raw: String) -> UUID {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let uuid = UUID(uuidString: trimmed) { return uuid }
        let derived = OperativeKeyRegistry.derivedUUID(for: trimmed)
        OperativeKeyRegistry.shared.remember(raw: trimmed, as: derived)
        return derived
    }
}

/// Maps the stable UUIDs made for non-UUID person ids back to those ids. In memory only: the mapping is
/// deterministic, so every booking read or picker row that uses a mapped id has registered it first.
nonisolated final class OperativeKeyRegistry: @unchecked Sendable {
    static let shared = OperativeKeyRegistry()
    private let lock = NSLock()
    private var rawById: [UUID: String] = [:]

    func remember(raw: String, as id: UUID) {
        lock.lock(); defer { lock.unlock() }
        rawById[id] = raw
    }

    func rawKey(for id: UUID) -> String? {
        lock.lock(); defer { lock.unlock() }
        return rawById[id]
    }

    /// Version-5-shaped UUID from SHA-256 of a fixed prefix and the id. Same input, same UUID, on every device.
    static func derivedUUID(for raw: String) -> UUID {
        let b = Array(SHA256.hash(data: Data("pp.operative-key.\(raw)".utf8)).prefix(16))
        return UUID(uuid: (b[0], b[1], b[2], b[3], b[4], b[5], (b[6] & 0x0F) | 0x50, b[7],
                           (b[8] & 0x3F) | 0x80, b[9], b[10], b[11], b[12], b[13], b[14], b[15]))
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

enum BookingStatus: String, CaseIterable, Identifiable, Codable {
    case confirmed = "Confirmed"
    case tentative = "Tentative"
    case cancelled = "Cancelled"
    case completed = "Completed"
    
    var id: String { rawValue }
    
    /// The rulebook's `bookingOccupiesDay`: the person is taken that day. Asked once per status, then remembered,
    /// because schedule, warnings and payroll screens filter every booking with it.
    nonisolated var occupiesDay: Bool { Self.occupiesDayByStatus[self] ?? (self != .cancelled) }

    private nonisolated static let occupiesDayByStatus: [BookingStatus: Bool] = {
        var map: [BookingStatus: Bool] = [:]
        for status in BookingStatus.allCases {
            if let answer = CanonicalBusinessEngine.bookingOccupiesDay(status.rawValue) { map[status] = answer }
        }
        return map
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

