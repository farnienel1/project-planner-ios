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
    /// Clock times for hour-based bookings (`timeSlot == .customHours`), `"HH:mm"` (e.g. `07:30`). Legacy AM/PM/full day omit these.
    var workStartTime: String?
    var workEndTime: String?
    /// When true, payroll can treat the org unpaid break as not applying to this booking (policy-dependent).
    var isBreakRemoved: Bool
    /// Optional stable id when several docs were created as one group action (dissolve-on-diverge is future UI).
    var bookingGroupId: String?
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
        workStartTime: String? = nil,
        workEndTime: String? = nil,
        isBreakRemoved: Bool = false,
        bookingGroupId: String? = nil,
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
        self.workStartTime = workStartTime
        self.workEndTime = workEndTime
        self.isBreakRemoved = isBreakRemoved
        self.bookingGroupId = bookingGroupId
        self.createdAt = createdAt ?? Date()
        self.updatedAt = updatedAt ?? Date()
    }
}

enum ManagerTimeSlot: String, CaseIterable, Identifiable, Codable {
    case morning = "AM"
    case afternoon = "PM"
    case fullDay = "FULL_DAY"
    /// Clock-window booking; use `workStartTime` / `workEndTime` when persisting hours.
    case customHours = "CUSTOM_HOURS"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .morning: return "AM"
        case .afternoon: return "PM"
        case .fullDay: return "Full Day"
        case .customHours: return "Hours"
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

extension ManagerSiteBooking {
    /// Maps a persisted manager booking into the hours editor (always opens as a clock window).
    func hoursEditChoice(policy: OrgPayrollTimePolicy) -> OperativeDayBookingChoice {
        if timeSlot == .customHours,
           let s = workStartTime, let e = workEndTime,
           !s.isEmpty, !e.isEmpty {
            return OperativeDayBookingChoice(
                timeSlot: .customHours,
                workStartTime: s,
                workEndTime: e,
                isBreakRemoved: isBreakRemoved
            )
        }
        return OperativeDayBookingChoice(
            timeSlot: .customHours,
            workStartTime: policy.standardDayStart,
            workEndTime: policy.standardDayEnd,
            isBreakRemoved: isBreakRemoved
        )
    }
}
