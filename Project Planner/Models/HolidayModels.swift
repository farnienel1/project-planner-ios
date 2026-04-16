//
//  HolidayModels.swift
//  Project Planner
//
//  Holiday booking: self-booked (admin/manager) or operative request (pending approval).
//

import Foundation

enum HolidayStatus: String, Codable, CaseIterable {
    case pending = "pending"
    case approved = "approved"
    case rejected = "rejected"
}

/// One holiday booking. Either self-booked by an app user (userId set, status .approved) or requested by an operative (operativeId set, status pending/approved/rejected).
struct HolidayBooking: Identifiable, Codable, Hashable {
    let id: UUID
    var organizationId: String
    var userId: String?
    var operativeId: UUID?
    var startDate: Date
    var endDate: Date
    var status: HolidayStatus
    var approvedByUserId: String?
    var approvedAt: Date?
    var createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        organizationId: String,
        userId: String? = nil,
        operativeId: UUID? = nil,
        startDate: Date,
        endDate: Date,
        status: HolidayStatus = .approved,
        approvedByUserId: String? = nil,
        approvedAt: Date? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.organizationId = organizationId
        self.userId = userId
        self.operativeId = operativeId
        self.startDate = startDate
        self.endDate = endDate
        self.status = status
        self.approvedByUserId = approvedByUserId
        self.approvedAt = approvedAt
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    var isOperativeRequest: Bool { operativeId != nil }
    var isSelfBooked: Bool { userId != nil }
}
