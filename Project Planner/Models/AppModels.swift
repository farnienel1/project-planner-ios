//
//  AppModels.swift
//  Project Planner
//
//  Created by Assistant on 29/09/2025.
//

import Foundation
import SwiftUI

// MARK: - App Configuration Models

enum ThemePreference: String, CaseIterable, Codable, Sendable {
    case light = "light"
    case dark = "dark"
    case system = "system"
    
    var colorScheme: ColorScheme? {
        switch self {
        case .light: return .light
        case .dark: return .dark
        case .system: return nil
        }
    }
}

enum AppColorScheme: String, CaseIterable, Codable, Sendable {
    case blue = "blue"
    case green = "green"
    case yellow = "yellow"
    case pink = "pink"
    
    var displayName: String {
        switch self {
        case .blue: return "Blue"
        case .green: return "Green"
        case .yellow: return "Yellow"
        case .pink: return "Pink"
        }
    }
    
    var color: Color {
        switch self {
        case .blue:
            return Color(red: 0.051, green: 0.404, blue: 0.929) // #0d67ed
        case .green:
            return Color(red: 0.2, green: 0.7, blue: 0.3) // Green
        case .yellow:
            return Color(red: 1.0, green: 0.8, blue: 0.0) // Yellow
        case .pink:
            return Color(red: 1.0, green: 0.4, blue: 0.7) // Pink
        }
    }
}

enum UserRole: String, CaseIterable, Codable {
    case basic = "basic"
    case admin = "admin"
    case manager = "manager"
    case operative = "operative"
    case viewer = "viewer"
    
    var displayName: String {
        switch self {
        case .basic: return "Basic User"
        case .admin: return "Administrator"
        case .manager: return "Manager"
        case .operative: return "Operative"
        case .viewer: return "Viewer"
        }
    }
    
    var permissions: [Permission] {
        switch self {
        case .basic:
            return [.viewProjects, .viewOperatives, .viewBookings]
        case .manager:
            return [.viewProjects, .editProjects, .viewOperatives, .editOperatives, .viewBookings, .editBookings]
        case .operative:
            return [.viewProjects, .viewBookings]
        case .viewer:
            return [.viewProjects, .viewOperatives, .viewBookings]
        case .admin:
            return Permission.allCases
        }
    }
}

enum Permission: String, CaseIterable {
    case viewProjects = "view_projects"
    case editProjects = "edit_projects"
    case deleteProjects = "delete_projects"
    case viewOperatives = "view_operatives"
    case editOperatives = "edit_operatives"
    case deleteOperatives = "delete_operatives"
    case viewBookings = "view_bookings"
    case editBookings = "edit_bookings"
    case deleteBookings = "delete_bookings"
    case viewManagers = "view_managers"
    case editManagers = "edit_managers"
    case viewReports = "view_reports"
    case manageSettings = "manage_settings"
    
    var displayName: String {
        switch self {
        case .viewProjects: return "View Projects"
        case .editProjects: return "Edit Projects"
        case .deleteProjects: return "Delete Projects"
        case .viewOperatives: return "View Operatives"
        case .editOperatives: return "Edit Operatives"
        case .deleteOperatives: return "Delete Operatives"
        case .viewBookings: return "View Bookings"
        case .editBookings: return "Edit Bookings"
        case .deleteBookings: return "Delete Bookings"
        case .viewManagers: return "View Managers"
        case .editManagers: return "Edit Managers"
        case .viewReports: return "View Reports"
        case .manageSettings: return "Manage Settings"
        }
    }
}

struct UserPermissions: Codable, Hashable {
    var adminAccess: Bool  // Can add/manage users
    var manager: Bool      // Manager - can schedule operatives, create clients, skills, qualifications, view warnings, manage tasks
    var operatives: Bool   // Can see operatives list and details on home screen (Operative Management)
    var skills: Bool       // Can create/alter skills
    var qualifications: Bool // Can create/alter qualifications
    var materials: Bool    // Operative materials visibility/access inside project detail
    var projects: Bool     // Can create and manage projects
    var smallWorks: Bool   // Can create and manage small works
    var operativeMode: Bool // Operative mode - limited view of app
    var annualLeaveSelfBook: Bool // Managers can self-book annual leave without approval
    var weeklyReports: Bool // Managers can access weekly reports
    var subContractors: Bool // Managers can add/manage sub contractors
    var siteAudit: Bool // Operative can access site audits
    
    init(
        adminAccess: Bool = false,
        manager: Bool = false,
        operatives: Bool = false,
        skills: Bool = false,
        qualifications: Bool = false,
        materials: Bool = false,
        projects: Bool = false,
        smallWorks: Bool = false,
        operativeMode: Bool = false,
        annualLeaveSelfBook: Bool = false,
        weeklyReports: Bool = false,
        subContractors: Bool = false,
        siteAudit: Bool = true
    ) {
        self.adminAccess = adminAccess
        self.manager = manager
        self.operatives = operatives
        self.skills = skills
        self.qualifications = qualifications
        self.materials = materials
        self.projects = projects
        self.smallWorks = smallWorks
        self.operativeMode = operativeMode
        self.annualLeaveSelfBook = annualLeaveSelfBook
        self.weeklyReports = weeklyReports
        self.subContractors = subContractors
        self.siteAudit = siteAudit
    }
}

struct OperativeDayRateHistoryEntry: Identifiable, Codable, Hashable {
    let id: UUID
    var userId: String
    var dayRate: Double
    var effectiveAt: Date
    var createdAt: Date
}

/// Simulates app navigation and permission checks for another role while signed in as yourself.
/// Firebase rules still use your real user document.
enum RoleTestingPreset: String, CaseIterable, Identifiable {
    case superAdmin
    case admin
    case manager
    case operative
    
    var id: String { rawValue }
    
    var title: String {
        switch self {
        case .superAdmin: return "Super Admin"
        case .admin: return "Admin"
        case .manager: return "Manager"
        case .operative: return "Operative"
        }
    }
    
    var detail: String {
        switch self {
        case .superAdmin:
            return "Org creator–level UI: full access including ownership actions where your real account allows."
        case .admin:
            return "Administrator UI without super-admin-only controls."
        case .manager:
            return "Typical manager: scheduling, clients, skills, no user administration."
        case .operative:
            return "Limited operative home, projects/small works, schedule, holiday — no admin areas."
        }
    }
}

// MARK: - User roster segments (Manage Users, Managers, Operatives)

/// Active = verified and not deactivated; Inactive = verified but deactivated; Pending = invitation not completed (`passwordSet` false).
enum UserRosterSegment: Int, CaseIterable, Identifiable, Hashable {
    case active = 0
    case inactive = 1
    case pending = 2
    
    var id: Int { rawValue }
    
    var title: String {
        switch self {
        case .active: return "Active"
        case .inactive: return "Inactive"
        case .pending: return "Pending"
        }
    }
    
    func matches(_ user: AppUser) -> Bool {
        switch self {
        case .active:
            return user.passwordSet && user.isActive
        case .inactive:
            return user.passwordSet && !user.isActive
        case .pending:
            return !user.passwordSet
        }
    }
}

// MARK: - App User Model

struct AppUser: Identifiable, Codable, Hashable {
    var id: String
    var email: String
    var organizationId: String
    var role: UserRole
    var createdAt: Date
    var firstName: String
    var surname: String
    var mobileNumber: String?
    var isActive: Bool
    var passwordSet: Bool
    var permissions: UserPermissions
    var isSuperAdmin: Bool
    var policyAccepted: Bool // GDPR privacy policy acceptance
    var policyAcceptedAt: Date? // When policy was accepted
    /// For operative accounts: Firebase Auth UID of their line manager (holiday requests route here).
    var assignedManagerUserId: String?
    /// Default day rate for this operative (optional; copied to roster when the operative profile is created).
    var dayRate: Double?
    
    init(
        id: String,
        email: String,
        organizationId: String,
        role: UserRole,
        createdAt: Date = Date(),
        firstName: String = "",
        surname: String = "",
        mobileNumber: String? = nil,
        isActive: Bool = true,
        passwordSet: Bool = false,
        permissions: UserPermissions = UserPermissions(),
        isSuperAdmin: Bool = false,
        policyAccepted: Bool = false,
        policyAcceptedAt: Date? = nil,
        assignedManagerUserId: String? = nil,
        dayRate: Double? = nil
    ) {
        self.id = id
        self.email = email
        self.organizationId = organizationId
        self.role = role
        self.createdAt = createdAt
        self.firstName = firstName
        self.surname = surname
        self.mobileNumber = mobileNumber
        self.isActive = isActive
        self.passwordSet = passwordSet
        self.permissions = permissions
        self.isSuperAdmin = isSuperAdmin
        self.policyAccepted = policyAccepted
        self.policyAcceptedAt = policyAcceptedAt
        self.assignedManagerUserId = assignedManagerUserId
        self.dayRate = dayRate
    }
    
    var fullName: String {
        if firstName.isEmpty && surname.isEmpty {
            return email
        }
        return "\(firstName) \(surname)".trimmingCharacters(in: .whitespaces)
    }
}

// MARK: - Organization Models

struct Organization: Identifiable, Codable, Hashable {
    let id: UUID
    /// Exact `organizations/{firestoreDocumentId}` in Firestore. Always use this for Firebase paths — `id.uuidString` can differ in letter casing from what is stored in `users.organizationId`.
    let firestoreDocumentId: String
    var name: String
    var settings: OrganizationSettings
    var officeAddressLine1: String?
    var officeCity: String?
    var officePostcode: String?
    var countryCode: String
    var defaultLatitude: Double?
    var defaultLongitude: Double?
    var companyLogoURL: String?
    var createdAt: Date
    var updatedAt: Date
    /// Firebase Auth UID of the organization creator. Only this user may be super admin.
    var creatorUserId: String?
    
    init(
        id: UUID = UUID(),
        firestoreDocumentId: String? = nil,
        name: String,
        settings: OrganizationSettings = OrganizationSettings(),
        officeAddressLine1: String? = nil,
        officeCity: String? = nil,
        officePostcode: String? = nil,
        countryCode: String = "GB",
        defaultLatitude: Double? = nil,
        defaultLongitude: Double? = nil,
        companyLogoURL: String? = nil,
        creatorUserId: String? = nil
    ) {
        self.id = id
        if let fid = firestoreDocumentId, !fid.isEmpty {
            self.firestoreDocumentId = fid
        } else {
            self.firestoreDocumentId = id.uuidString
        }
        self.name = name
        self.settings = settings
        self.officeAddressLine1 = officeAddressLine1
        self.officeCity = officeCity
        self.officePostcode = officePostcode
        self.countryCode = countryCode
        self.defaultLatitude = defaultLatitude
        self.defaultLongitude = defaultLongitude
        self.companyLogoURL = companyLogoURL
        self.createdAt = Date()
        self.updatedAt = Date()
        self.creatorUserId = creatorUserId
    }

    enum CodingKeys: String, CodingKey {
        case id, firestoreDocumentId, name, settings, officeAddressLine1, officeCity, officePostcode
        case countryCode, defaultLatitude, defaultLongitude, companyLogoURL, createdAt, updatedAt, creatorUserId
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        settings = try c.decode(OrganizationSettings.self, forKey: .settings)
        officeAddressLine1 = try c.decodeIfPresent(String.self, forKey: .officeAddressLine1)
        officeCity = try c.decodeIfPresent(String.self, forKey: .officeCity)
        officePostcode = try c.decodeIfPresent(String.self, forKey: .officePostcode)
        countryCode = try c.decodeIfPresent(String.self, forKey: .countryCode) ?? "GB"
        defaultLatitude = try c.decodeIfPresent(Double.self, forKey: .defaultLatitude)
        defaultLongitude = try c.decodeIfPresent(Double.self, forKey: .defaultLongitude)
        companyLogoURL = try c.decodeIfPresent(String.self, forKey: .companyLogoURL)
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt) ?? Date()
        creatorUserId = try c.decodeIfPresent(String.self, forKey: .creatorUserId)
        firestoreDocumentId = try c.decodeIfPresent(String.self, forKey: .firestoreDocumentId) ?? id.uuidString
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(firestoreDocumentId, forKey: .firestoreDocumentId)
        try c.encode(name, forKey: .name)
        try c.encode(settings, forKey: .settings)
        try c.encodeIfPresent(officeAddressLine1, forKey: .officeAddressLine1)
        try c.encodeIfPresent(officeCity, forKey: .officeCity)
        try c.encodeIfPresent(officePostcode, forKey: .officePostcode)
        try c.encode(countryCode, forKey: .countryCode)
        try c.encodeIfPresent(defaultLatitude, forKey: .defaultLatitude)
        try c.encodeIfPresent(defaultLongitude, forKey: .defaultLongitude)
        try c.encodeIfPresent(companyLogoURL, forKey: .companyLogoURL)
        try c.encode(createdAt, forKey: .createdAt)
        try c.encode(updatedAt, forKey: .updatedAt)
        try c.encodeIfPresent(creatorUserId, forKey: .creatorUserId)
    }
}

struct OrganizationSettings: Codable, Hashable {
    var allowSelfRegistration: Bool
    var requireEmailVerification: Bool
    var defaultUserRole: UserRole
    var workingHours: WorkingHours
    var holidayCalendar: HolidayCalendar
    
    init(
        allowSelfRegistration: Bool = true,
        requireEmailVerification: Bool = true,
        defaultUserRole: UserRole = .basic,
        workingHours: WorkingHours = WorkingHours(),
        holidayCalendar: HolidayCalendar = HolidayCalendar()
    ) {
        self.allowSelfRegistration = allowSelfRegistration
        self.requireEmailVerification = requireEmailVerification
        self.defaultUserRole = defaultUserRole
        self.workingHours = workingHours
        self.holidayCalendar = holidayCalendar
    }
}

struct WorkingHours: Codable, Hashable {
    var startTime: String // "08:00"
    var endTime: String   // "17:00"
    var lunchBreak: Int   // minutes
    var workingDays: Set<Weekday>
    
    init(
        startTime: String = "08:00",
        endTime: String = "17:00",
        lunchBreak: Int = 60,
        workingDays: Set<Weekday> = [.monday, .tuesday, .wednesday, .thursday, .friday]
    ) {
        self.startTime = startTime
        self.endTime = endTime
        self.lunchBreak = lunchBreak
        self.workingDays = workingDays
    }
}

enum Weekday: String, CaseIterable, Codable, Hashable {
    case monday = "Monday"
    case tuesday = "Tuesday"
    case wednesday = "Wednesday"
    case thursday = "Thursday"
    case friday = "Friday"
    case saturday = "Saturday"
    case sunday = "Sunday"
    
    var shortName: String {
        switch self {
        case .monday: return "Mon"
        case .tuesday: return "Tue"
        case .wednesday: return "Wed"
        case .thursday: return "Thu"
        case .friday: return "Fri"
        case .saturday: return "Sat"
        case .sunday: return "Sun"
        }
    }
}

struct HolidayCalendar: Codable, Hashable {
    var holidays: [Holiday]
    var bankHolidays: Set<Date>
    
    init(holidays: [Holiday] = [], bankHolidays: Set<Date> = []) {
        self.holidays = holidays
        self.bankHolidays = bankHolidays
    }
}

struct Holiday: Identifiable, Codable, Hashable {
    let id: UUID
    var name: String
    var date: Date
    var isRecurring: Bool
    
    init(id: UUID = UUID(), name: String, date: Date, isRecurring: Bool = false) {
        self.id = id
        self.name = name
        self.date = date
        self.isRecurring = isRecurring
    }
}

// MARK: - Verification Models

struct VerificationCode: Identifiable, Codable, Hashable {
    let id: UUID
    var code: String
    var email: String
    var expiresAt: Date
    var isUsed: Bool
    var createdAt: Date
    var remainingAttempts: Int
    
    init(
        id: UUID = UUID(),
        code: String,
        email: String,
        expiresAt: Date,
        isUsed: Bool = false,
        createdAt: Date = Date(),
        remainingAttempts: Int = 3
    ) {
        self.id = id
        self.code = code
        self.email = email
        self.expiresAt = expiresAt
        self.isUsed = isUsed
        self.createdAt = createdAt
        self.remainingAttempts = remainingAttempts
    }
    
    var isExpired: Bool {
        return Date() > expiresAt
    }
    
    var isValid: Bool {
        return !isExpired && !isUsed && remainingAttempts > 0
    }
}

// MARK: - App State Models

struct AppSettings: Codable, Sendable {
    var theme: ThemePreference
    var colorScheme: AppColorScheme
    var organizationId: UUID?
    var lastSyncDate: Date?
    var autoSync: Bool
    var notifications: NotificationSettings
    var myScheduleOptions: MyScheduleOptions
    
    nonisolated init(
        theme: ThemePreference = .light, // Default to light mode always
        colorScheme: AppColorScheme = .blue, // Default to blue
        organizationId: UUID? = nil,
        lastSyncDate: Date? = nil,
        autoSync: Bool = true,
        notifications: NotificationSettings = NotificationSettings(),
        myScheduleOptions: MyScheduleOptions = MyScheduleOptions()
    ) {
        self.theme = theme
        self.colorScheme = colorScheme
        self.organizationId = organizationId
        self.lastSyncDate = lastSyncDate
        self.autoSync = autoSync
        self.notifications = notifications
        self.myScheduleOptions = myScheduleOptions
    }
    
    nonisolated enum CodingKeys: String, CodingKey {
        case theme, colorScheme, organizationId, lastSyncDate, autoSync, notifications, myScheduleOptions
    }
    
    nonisolated init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        theme = try container.decode(ThemePreference.self, forKey: .theme)
        // Default to blue if colorScheme is missing (for backward compatibility)
        colorScheme = try container.decodeIfPresent(AppColorScheme.self, forKey: .colorScheme) ?? .blue
        organizationId = try container.decodeIfPresent(UUID.self, forKey: .organizationId)
        lastSyncDate = try container.decodeIfPresent(Date.self, forKey: .lastSyncDate)
        autoSync = try container.decode(Bool.self, forKey: .autoSync)
        notifications = try container.decode(NotificationSettings.self, forKey: .notifications)
        myScheduleOptions = try container.decodeIfPresent(MyScheduleOptions.self, forKey: .myScheduleOptions) ?? MyScheduleOptions()
    }
    
    nonisolated func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(theme, forKey: .theme)
        try container.encode(colorScheme, forKey: .colorScheme)
        try container.encodeIfPresent(organizationId, forKey: .organizationId)
        try container.encodeIfPresent(lastSyncDate, forKey: .lastSyncDate)
        try container.encode(autoSync, forKey: .autoSync)
        try container.encode(notifications, forKey: .notifications)
        try container.encode(myScheduleOptions, forKey: .myScheduleOptions)
    }
}

struct MyScheduleOptions: Codable, Sendable, Hashable {
    var showOffice: Bool
    var showWorkingFromHome: Bool
    var showSiteSurvey: Bool
    var customItems: [String]
    
    nonisolated init(
        showOffice: Bool = true,
        showWorkingFromHome: Bool = true,
        showSiteSurvey: Bool = true,
        customItems: [String] = []
    ) {
        self.showOffice = showOffice
        self.showWorkingFromHome = showWorkingFromHome
        self.showSiteSurvey = showSiteSurvey
        self.customItems = customItems
    }
}

struct NotificationSettings: Codable, Sendable {
    var bookingConflicts: Bool
    var projectDeadlines: Bool
    var operativeAvailability: Bool
    var dailyReports: Bool
    var materialOrderCutOff: Bool
    
    nonisolated init(
        bookingConflicts: Bool = true,
        projectDeadlines: Bool = true,
        operativeAvailability: Bool = false,
        dailyReports: Bool = false,
        materialOrderCutOff: Bool = true
    ) {
        self.bookingConflicts = bookingConflicts
        self.projectDeadlines = projectDeadlines
        self.operativeAvailability = operativeAvailability
        self.dailyReports = dailyReports
        self.materialOrderCutOff = materialOrderCutOff
    }
    
    nonisolated enum CodingKeys: String, CodingKey {
        case bookingConflicts, projectDeadlines, operativeAvailability, dailyReports, materialOrderCutOff
    }
    
    nonisolated init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        bookingConflicts = try container.decodeIfPresent(Bool.self, forKey: .bookingConflicts) ?? true
        projectDeadlines = try container.decodeIfPresent(Bool.self, forKey: .projectDeadlines) ?? true
        operativeAvailability = try container.decodeIfPresent(Bool.self, forKey: .operativeAvailability) ?? false
        dailyReports = try container.decodeIfPresent(Bool.self, forKey: .dailyReports) ?? false
        materialOrderCutOff = try container.decodeIfPresent(Bool.self, forKey: .materialOrderCutOff) ?? true
    }
    
    nonisolated func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(bookingConflicts, forKey: .bookingConflicts)
        try container.encode(projectDeadlines, forKey: .projectDeadlines)
        try container.encode(operativeAvailability, forKey: .operativeAvailability)
        try container.encode(dailyReports, forKey: .dailyReports)
        try container.encode(materialOrderCutOff, forKey: .materialOrderCutOff)
    }
}

