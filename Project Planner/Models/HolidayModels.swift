//
//  HolidayModels.swift
//  Project Planner
//
//  Holiday booking: self-booked (admin/manager) or operative request (pending approval).
//

import Foundation

nonisolated enum HolidayStatus: String, Codable, CaseIterable, Sendable {
    case pending = "pending"
    case approved = "approved"
    case rejected = "rejected"
}

nonisolated enum HolidayTimeSlot: String, Codable, CaseIterable, Sendable {
    case fullDay = "FULL DAY"
    case morning = "AM"
    case afternoon = "PM"

    var dayValue: Double {
        switch self {
        case .fullDay: return 1.0
        case .morning, .afternoon: return 0.5
        }
    }
}

/// One holiday booking. Either self-booked by an app user (userId set, status .approved) or requested by an operative (operativeId set, status pending/approved/rejected).
/// Loaded records come from the rulebook reader `parseHolidayDocuments` (§1 "Document readers", §9): the
/// Firestore document id, the stored `userId` / `operativeId` strings and the organisation-zone day keys are
/// kept exactly as the reader returned them.
nonisolated struct HolidayBooking: Identifiable, Codable, Hashable, Sendable {
    /// SwiftUI identity only (`Manager.stableId(forFirestoreDocumentId:)` of `documentId` for loaded records).
    /// Never used to address the Firestore document: use `documentId`.
    let id: UUID
    /// `organizations/{orgId}/holidayBookings/{documentId}`, stored case (web ids need not be UUIDs).
    let documentId: String
    var organizationId: String
    var userId: String?
    /// The stored `operativeId`, kept even when it is not a UUID.
    var operativeIdRaw: String?
    var startDate: Date {
        didSet { startDayKey = OrganizationRulebookContext.dayKey(startDate) }
    }
    var endDate: Date {
        didSet { endDayKey = OrganizationRulebookContext.dayKey(endDate) }
    }
    /// Organisation-zone `YYYY-MM-DD` of the first and last day (from `parseHolidayDocument` when loaded).
    private(set) var startDayKey: String
    private(set) var endDayKey: String
    var status: HolidayStatus
    var timeSlot: HolidayTimeSlot
    var approvedByUserId: String?
    var approvedAt: Date?
    var cancellationRequestedAt: Date?
    var cancellationRequestedByUserId: String?
    /// Reason written when a line manager declines a request. Shown on the employee's notification.
    var decisionNote: String?
    var createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        documentId: String? = nil,
        organizationId: String,
        userId: String? = nil,
        operativeId: UUID? = nil,
        operativeIdRaw: String? = nil,
        startDate: Date,
        endDate: Date,
        startDayKey: String? = nil,
        endDayKey: String? = nil,
        status: HolidayStatus = .approved,
        timeSlot: HolidayTimeSlot = .fullDay,
        approvedByUserId: String? = nil,
        approvedAt: Date? = nil,
        cancellationRequestedAt: Date? = nil,
        cancellationRequestedByUserId: String? = nil,
        decisionNote: String? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        let storedDocumentId = documentId?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let storedOperativeId = operativeIdRaw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        self.id = id
        self.documentId = storedDocumentId.isEmpty ? id.uuidString : storedDocumentId
        self.organizationId = organizationId
        self.userId = userId
        self.operativeIdRaw = storedOperativeId.isEmpty ? operativeId?.uuidString : storedOperativeId
        self.startDate = startDate
        self.endDate = endDate
        self.startDayKey = startDayKey ?? OrganizationRulebookContext.dayKey(startDate)
        self.endDayKey = endDayKey ?? OrganizationRulebookContext.dayKey(endDate)
        self.status = status
        self.timeSlot = timeSlot
        self.approvedByUserId = approvedByUserId
        self.approvedAt = approvedAt
        self.cancellationRequestedAt = cancellationRequestedAt
        self.cancellationRequestedByUserId = cancellationRequestedByUserId
        self.decisionNote = decisionNote
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    /// The stored operative id as a UUID, for screens that match it against `Operative.id`.
    /// Nil when the stored id is not a UUID; rule inputs use `operativeIdRaw`.
    var operativeId: UUID? {
        get { operativeIdRaw.flatMap { UUID(uuidString: $0) } }
        set { operativeIdRaw = newValue?.uuidString }
    }

    /// `approved` from the reader: status is approved (a pending cancellation is still approved leave).
    var isApproved: Bool { status == .approved }

    var isOperativeRequest: Bool { !(operativeIdRaw ?? "").isEmpty }
    var isSelfBooked: Bool { userId != nil }
}
