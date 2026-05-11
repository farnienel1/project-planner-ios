//
//  ManagerScheduleModels.swift
//  Project Planner
//
//  Where admins/managers book themselves (site or office) by day – AM, PM, Full Day.
//

import Foundation

/// One booking of an admin/manager to a site (project/small work) or office for a given day and slot.
struct ManagerSiteBooking: Identifiable, Codable, Hashable {
    let id: UUID
    /// Firebase Auth UID of the admin/manager
    var userId: String
    var date: Date
    var timeSlot: ManagerTimeSlot
    var locationType: ManagerLocationType
    /// Project or small work ID when locationType is .project or .smallWork; nil for .office
    var locationId: UUID?
    /// Optional display name when `locationType == .custom`
    var customLocationName: String?
    var createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        userId: String,
        date: Date,
        timeSlot: ManagerTimeSlot,
        locationType: ManagerLocationType,
        locationId: UUID? = nil,
        customLocationName: String? = nil,
        createdAt: Date? = nil,
        updatedAt: Date? = nil
    ) {
        self.id = id
        self.userId = userId
        self.date = date
        self.timeSlot = timeSlot
        self.locationType = locationType
        self.locationId = locationId
        self.customLocationName = customLocationName
        self.createdAt = createdAt ?? Date()
        self.updatedAt = updatedAt ?? Date()
    }
}

enum ManagerTimeSlot: String, CaseIterable, Identifiable, Codable {
    case morning = "AM"
    case afternoon = "PM"
    case fullDay = "FULL_DAY"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .morning: return "AM"
        case .afternoon: return "PM"
        case .fullDay: return "Full Day"
        }
    }
}

enum ManagerLocationType: String, CaseIterable, Identifiable, Codable {
    case project = "project"
    case smallWork = "small_work"
    case office = "office"
    case workingFromHome = "working_from_home"
    case siteSurvey = "site_survey"
    case custom = "custom"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .project: return "Project"
        case .smallWork: return "Small Work"
        case .office: return "Office"
        case .workingFromHome: return "Working From Home"
        case .siteSurvey: return "Site Survey"
        case .custom: return "Custom"
        }
    }
}
