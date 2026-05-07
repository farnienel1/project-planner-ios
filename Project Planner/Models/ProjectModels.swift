//
//  ProjectModels.swift
//  Project Planner
//
//  Created by Assistant on 29/09/2025.
//

import Foundation

// MARK: - Core Project Models

struct Project: Identifiable, Codable, Hashable {
    let id: UUID
    var jobNumber: String
    var siteName: String
    var addressLine1: String
    var addressLine2: String?
    var townCity: String
    var postcode: String
    var client: Client
    var startDate: Date
    var endDate: Date
    var jobType: JobType // Used only for determining collection (smallWorks vs projects)
    var customJobType: String? // Optional custom job type for display (e.g., "CAT A", "CAT B", "Small Works", etc.)
    var manager: ManagerLegacy
    var managerId: UUID? // Reference to actual Manager object
    var isLive: Bool
    var description: String?
    var notes: String?
    var createdAt: Date
    var updatedAt: Date
    /// Managers hidden from this project/small works by admin.
    var hiddenManagerUserIds: Set<String>
    /// Operatives hidden from this project/small works by admin.
    var hiddenOperativeUserIds: Set<String>
    
    // Legacy support - computed property for backward compatibility
    var siteAddress: String {
        var parts: [String] = []
        if !addressLine1.isEmpty { parts.append(addressLine1) }
        if let line2 = addressLine2, !line2.isEmpty { parts.append(line2) }
        if !townCity.isEmpty { parts.append(townCity) }
        if !postcode.isEmpty { parts.append(postcode) }
        return parts.joined(separator: ", ")
    }
    
    init(
        id: UUID = UUID(),
        jobNumber: String,
        siteName: String,
        addressLine1: String,
        addressLine2: String? = nil,
        townCity: String,
        postcode: String,
        client: Client,
        startDate: Date,
        endDate: Date,
        jobType: JobType,
        customJobType: String? = nil,
        manager: ManagerLegacy,
        managerId: UUID? = nil,
        isLive: Bool = true,
        description: String? = nil,
        notes: String? = nil,
        hiddenManagerUserIds: Set<String> = [],
        hiddenOperativeUserIds: Set<String> = []
    ) {
        self.id = id
        self.jobNumber = jobNumber
        self.siteName = siteName
        self.addressLine1 = addressLine1
        self.addressLine2 = addressLine2
        self.townCity = townCity
        self.postcode = postcode
        self.client = client
        self.startDate = startDate
        self.endDate = endDate
        self.jobType = jobType
        self.customJobType = customJobType
        self.manager = manager
        self.managerId = managerId
        self.isLive = isLive
        self.description = description
        self.notes = notes
        self.createdAt = Date()
        self.updatedAt = Date()
        self.hiddenManagerUserIds = hiddenManagerUserIds
        self.hiddenOperativeUserIds = hiddenOperativeUserIds
    }
    
    // Legacy initializer for backward compatibility
    init(
        id: UUID = UUID(),
        jobNumber: String,
        siteName: String,
        siteAddress: String,
        client: Client,
        startDate: Date,
        endDate: Date,
        jobType: JobType,
        manager: ManagerLegacy,
        isLive: Bool = true,
        description: String? = nil,
        notes: String? = nil,
        hiddenManagerUserIds: Set<String> = [],
        hiddenOperativeUserIds: Set<String> = []
    ) {
        self.id = id
        self.jobNumber = jobNumber
        self.siteName = siteName
        
        // Parse old siteAddress format into new fields
        let parts = siteAddress.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        if parts.count > 0 {
            self.addressLine1 = String(parts[0])
        } else {
            self.addressLine1 = siteAddress
        }
        
        if parts.count > 1 {
            self.addressLine2 = String(parts[1])
        } else {
            self.addressLine2 = nil
        }
        
        if parts.count > 2 {
            self.townCity = String(parts[parts.count - 2])
        } else {
            self.townCity = ""
        }
        
        if parts.count > 3 {
            self.postcode = String(parts[parts.count - 1])
        } else if parts.count == 3 {
            self.postcode = String(parts[2])
        } else {
            self.postcode = ""
        }
        
        self.client = client
        self.startDate = startDate
        self.endDate = endDate
        self.jobType = jobType
        self.customJobType = nil // Legacy projects don't have customJobType
        self.manager = manager
        self.managerId = nil // Legacy projects don't have managerId
        self.isLive = isLive
        self.description = description
        self.notes = notes
        self.createdAt = Date()
        self.updatedAt = Date()
        self.hiddenManagerUserIds = hiddenManagerUserIds
        self.hiddenOperativeUserIds = hiddenOperativeUserIds
    }
    
    var duration: Int {
        Calendar.current.dateComponents([.day], from: startDate, to: endDate).day ?? 0
    }
    
    var isActive: Bool {
        let now = Date()
        return isLive && startDate <= now && endDate >= now
    }
    
    var status: ProjectStatus {
        let now = Date()
        if !isLive { return .inactive }
        if now < startDate { return .upcoming }
        if now > endDate { return .completed }
        return .active
    }
    
    enum CodingKeys: String, CodingKey {
        case id, jobNumber, siteName, addressLine1, addressLine2, townCity, postcode
        case client, startDate, endDate, jobType, customJobType, manager, managerId
        case isLive, description, notes, createdAt, updatedAt
        case hiddenManagerUserIds, hiddenOperativeUserIds
    }
    
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        jobNumber = try c.decode(String.self, forKey: .jobNumber)
        siteName = try c.decode(String.self, forKey: .siteName)
        addressLine1 = try c.decodeIfPresent(String.self, forKey: .addressLine1) ?? ""
        addressLine2 = try c.decodeIfPresent(String.self, forKey: .addressLine2)
        townCity = try c.decodeIfPresent(String.self, forKey: .townCity) ?? ""
        postcode = try c.decodeIfPresent(String.self, forKey: .postcode) ?? ""
        client = try c.decode(Client.self, forKey: .client)
        startDate = try c.decode(Date.self, forKey: .startDate)
        endDate = try c.decode(Date.self, forKey: .endDate)
        jobType = try c.decode(JobType.self, forKey: .jobType)
        customJobType = try c.decodeIfPresent(String.self, forKey: .customJobType)
        manager = try c.decode(ManagerLegacy.self, forKey: .manager)
        managerId = try c.decodeIfPresent(UUID.self, forKey: .managerId)
        isLive = try c.decodeIfPresent(Bool.self, forKey: .isLive) ?? true
        description = try c.decodeIfPresent(String.self, forKey: .description)
        notes = try c.decodeIfPresent(String.self, forKey: .notes)
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt) ?? Date()
        hiddenManagerUserIds = try c.decodeIfPresent(Set<String>.self, forKey: .hiddenManagerUserIds) ?? []
        hiddenOperativeUserIds = try c.decodeIfPresent(Set<String>.self, forKey: .hiddenOperativeUserIds) ?? []
    }
    
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(jobNumber, forKey: .jobNumber)
        try c.encode(siteName, forKey: .siteName)
        try c.encode(addressLine1, forKey: .addressLine1)
        try c.encodeIfPresent(addressLine2, forKey: .addressLine2)
        try c.encode(townCity, forKey: .townCity)
        try c.encode(postcode, forKey: .postcode)
        try c.encode(client, forKey: .client)
        try c.encode(startDate, forKey: .startDate)
        try c.encode(endDate, forKey: .endDate)
        try c.encode(jobType, forKey: .jobType)
        try c.encodeIfPresent(customJobType, forKey: .customJobType)
        try c.encode(manager, forKey: .manager)
        try c.encodeIfPresent(managerId, forKey: .managerId)
        try c.encode(isLive, forKey: .isLive)
        try c.encodeIfPresent(description, forKey: .description)
        try c.encodeIfPresent(notes, forKey: .notes)
        try c.encode(createdAt, forKey: .createdAt)
        try c.encode(updatedAt, forKey: .updatedAt)
        try c.encode(hiddenManagerUserIds, forKey: .hiddenManagerUserIds)
        try c.encode(hiddenOperativeUserIds, forKey: .hiddenOperativeUserIds)
    }
}

enum ProjectStatus: String, CaseIterable, Codable {
    case upcoming = "Upcoming"
    case active = "Active"
    case completed = "Completed"
    case inactive = "Inactive"
    
    var color: String {
        switch self {
        case .upcoming: return "blue"
        case .active: return "green"
        case .completed: return "gray"
        case .inactive: return "red"
        }
    }
}

enum JobType: String, CaseIterable, Identifiable, Codable {
    case catA = "CAT A"
    case catB = "CAT B"
    case smallWorks = "Small Works"
    case maintenance = "Maintenance"
    
    var id: String { rawValue }
    
    var description: String {
        switch self {
        case .catA: return "Category A fit-out"
        case .catB: return "Category B fit-out"
        case .smallWorks: return "Small works and repairs"
        case .maintenance: return "Ongoing maintenance"
        }
    }
}

// MARK: - Client Models

struct Client: Identifiable, Codable, Hashable {
    let id: UUID
    var name: String
    var contactPerson: String?
    var email: String?
    var phone: String?
    var address: String?
    var createdAt: Date
    var updatedAt: Date
    
    init(
        id: UUID = UUID(),
        name: String,
        contactPerson: String? = nil,
        email: String? = nil,
        phone: String? = nil,
        address: String? = nil
    ) {
        self.id = id
        self.name = name
        self.contactPerson = contactPerson
        self.email = email
        self.phone = phone
        self.address = address
        self.createdAt = Date()
        self.updatedAt = Date()
    }
}

extension Client {
    static let defaultClients: [Client] = [
        Client(name: "CBC", contactPerson: "Project Manager", email: "projects@cbc.com"),
        Client(name: "Claremont", contactPerson: "Site Manager", email: "site@claremont.com"),
        Client(name: "GMS", contactPerson: "Operations", email: "ops@gms.com"),
        Client(name: "Kempton Smith", contactPerson: "Director", email: "director@kemptonsmith.com"),
        Client(name: "Nicholas Stephens", contactPerson: "Project Lead", email: "projects@nicholasstephens.com"),
        Client(name: "Pryer Construction", contactPerson: "Site Supervisor", email: "supervisor@pryer.com"),
        Client(name: "RCDC", contactPerson: "Manager", email: "manager@rcdc.com"),
        Client(name: "RED Construction", contactPerson: "Project Manager", email: "pm@redconstruction.com"),
        Client(name: "Roots", contactPerson: "Operations Manager", email: "ops@roots.com")
    ]
}
