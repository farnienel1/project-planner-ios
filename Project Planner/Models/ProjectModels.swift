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
    var managerIds: [UUID] // Supports assigning multiple managers
    var isLive: Bool
    var description: String?
    var notes: String?
    var createdAt: Date
    var updatedAt: Date
    /// Managers hidden from this project/small works by admin.
    var hiddenManagerUserIds: Set<String>
    /// Operatives hidden from this project/small works by admin.
    var hiddenOperativeUserIds: Set<String>
    /// When true, primary site location is the map pin; address lines are optional (e.g. from "Set address").
    var usesMapPinForLocation: Bool
    /// WGS84 latitude when using map pin (mutually exclusive with address-only mode in the UI).
    var latitude: Double?
    /// WGS84 longitude when using map pin.
    var longitude: Double?
    /// `projects/{id}` / `smallWorks/{id}` as stored (RULEBOOK 1.7.0 §1: stored case, a non-UUID id is kept).
    /// Nil on a job made in this app before it was saved: its id is `id.uuidString`. Use `documentId`.
    var firestoreDocumentId: String? = nil
    /// `managerIds` exactly as `parseJobDocument` read them, so a save writes a stored id back unchanged.
    var storedManagerIds: [String] = []
    /// RULEBOOK 1.10.0 §16, §17: `managerUserIds` as stored (the account ids of the job's managers, `jobManagerUserIds`).
    /// The security rules match a manager against it; a save writes the recomputed list beside `managerIds`.
    var storedManagerUserIds: [String] = []

    /// The Firestore document id every write, delete and lookup addresses.
    var documentId: String {
        let stored = firestoreDocumentId?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return stored.isEmpty ? WorkDocumentKeys.storedId(for: id) : stored
    }

    /// The stored id of an assigned manager: the id this job was read with, else the remembered stored id.
    func storedManagerId(for managerId: UUID) -> String {
        let key = storedManagerIds.first { Manager.stableId(forFirestoreDocumentId: $0) == managerId }
        return WorkDocumentKeys.storedId(for: managerId, key: key)
    }

    var allAssignedManagerIds: [UUID] {
        var seen = Set<UUID>()
        var output: [UUID] = []
        if let managerId, seen.insert(managerId).inserted {
            output.append(managerId)
        }
        for id in managerIds where seen.insert(id).inserted {
            output.append(id)
        }
        return output
    }

    // Legacy support - computed property for backward compatibility
    var siteAddress: String {
        var parts: [String] = []
        if !addressLine1.isEmpty { parts.append(addressLine1) }
        if let line2 = addressLine2, !line2.isEmpty { parts.append(line2) }
        if !townCity.isEmpty { parts.append(townCity) }
        if !postcode.isEmpty { parts.append(postcode) }
        if !parts.isEmpty {
            return parts.joined(separator: ", ")
        }
        if usesMapPinForLocation, let la = latitude, let lo = longitude {
            return String(format: "%.5f, %.5f", la, lo)
        }
        return ""
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
        managerIds: [UUID] = [],
        isLive: Bool = true,
        description: String? = nil,
        notes: String? = nil,
        hiddenManagerUserIds: Set<String> = [],
        hiddenOperativeUserIds: Set<String> = [],
        usesMapPinForLocation: Bool = false,
        latitude: Double? = nil,
        longitude: Double? = nil
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
        self.managerIds = managerIds
        self.isLive = isLive
        self.description = description
        self.notes = notes
        self.createdAt = Date()
        self.updatedAt = Date()
        self.hiddenManagerUserIds = hiddenManagerUserIds
        self.hiddenOperativeUserIds = hiddenOperativeUserIds
        self.usesMapPinForLocation = usesMapPinForLocation
        self.latitude = latitude
        self.longitude = longitude
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
        self.managerIds = []
        self.isLive = isLive
        self.description = description
        self.notes = notes
        self.createdAt = Date()
        self.updatedAt = Date()
        self.hiddenManagerUserIds = hiddenManagerUserIds
        self.hiddenOperativeUserIds = hiddenOperativeUserIds
        self.usesMapPinForLocation = false
        self.latitude = nil
        self.longitude = nil
    }
    
    var duration: Int {
        Calendar.current.dateComponents([.day], from: startDate, to: endDate).day ?? 0
    }
    
    var isActive: Bool {
        status == .active
    }
    
    /// Calendar-day status. A job whose end date is today stays Active until tomorrow —
    /// matching web (`completes today` is still live work).
    /// `workStatusOn` today in the organisation's zone (web uses the same function).
    var status: ProjectStatus {
        // RULEBOOK 1.21.0 §21: `jobWorkStatus` on the organisation-zone day; no device-calendar fallback. When the
        // script did not answer (it has not loaded), an inactive job is still inactive and any other reads active.
        if let canonical = ProjectStatusRulebook.status(isLive: isLive, start: startDate, end: endDate, on: Date()) {
            return canonical
        }
        return isLive ? .active : .inactive
    }
    
    enum CodingKeys: String, CodingKey {
        case id, jobNumber, siteName, addressLine1, addressLine2, townCity, postcode
        case client, startDate, endDate, jobType, customJobType, manager, managerId
        case managerIds
        case isLive, description, notes, createdAt, updatedAt
        case hiddenManagerUserIds, hiddenOperativeUserIds
        case usesMapPinForLocation, latitude, longitude
        case firestoreDocumentId, storedManagerIds, storedManagerUserIds
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
        managerIds = try c.decodeIfPresent([UUID].self, forKey: .managerIds) ?? (managerId.map { [$0] } ?? [])
        isLive = try c.decodeIfPresent(Bool.self, forKey: .isLive) ?? true
        description = try c.decodeIfPresent(String.self, forKey: .description)
        notes = try c.decodeIfPresent(String.self, forKey: .notes)
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt) ?? Date()
        hiddenManagerUserIds = try c.decodeIfPresent(Set<String>.self, forKey: .hiddenManagerUserIds) ?? []
        hiddenOperativeUserIds = try c.decodeIfPresent(Set<String>.self, forKey: .hiddenOperativeUserIds) ?? []
        usesMapPinForLocation = try c.decodeIfPresent(Bool.self, forKey: .usesMapPinForLocation) ?? false
        latitude = try c.decodeIfPresent(Double.self, forKey: .latitude)
        longitude = try c.decodeIfPresent(Double.self, forKey: .longitude)
        firestoreDocumentId = try c.decodeIfPresent(String.self, forKey: .firestoreDocumentId)
        storedManagerIds = try c.decodeIfPresent([String].self, forKey: .storedManagerIds) ?? []
        storedManagerUserIds = try c.decodeIfPresent([String].self, forKey: .storedManagerUserIds) ?? []
        // A saved copy read before the server answers: remember stored spellings so writes keep them.
        if let firestoreDocumentId { _ = WorkDocumentKeys.inAppId(for: firestoreDocumentId) }
        for managerId in storedManagerIds { _ = WorkDocumentKeys.inAppId(for: managerId) }
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
        try c.encode(managerIds, forKey: .managerIds)
        try c.encode(isLive, forKey: .isLive)
        try c.encodeIfPresent(description, forKey: .description)
        try c.encodeIfPresent(notes, forKey: .notes)
        try c.encode(createdAt, forKey: .createdAt)
        try c.encode(updatedAt, forKey: .updatedAt)
        try c.encode(hiddenManagerUserIds, forKey: .hiddenManagerUserIds)
        try c.encode(hiddenOperativeUserIds, forKey: .hiddenOperativeUserIds)
        try c.encode(usesMapPinForLocation, forKey: .usesMapPinForLocation)
        try c.encodeIfPresent(latitude, forKey: .latitude)
        try c.encodeIfPresent(longitude, forKey: .longitude)
        try c.encodeIfPresent(firestoreDocumentId, forKey: .firestoreDocumentId)
        try c.encode(storedManagerIds, forKey: .storedManagerIds)
        try c.encode(storedManagerUserIds, forKey: .storedManagerUserIds)
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
    /// `organizations/{org}/clients/{id}` as stored (RULEBOOK 1.6.0 §1: stored case, a non-UUID id is kept).
    /// Nil on a client made in this app before it was saved: its id is `id.uuidString`. Use `documentId`.
    var firestoreDocumentId: String? = nil

    /// The Firestore document id every write, delete and lookup addresses.
    var documentId: String {
        let stored = firestoreDocumentId?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return stored.isEmpty ? id.uuidString : stored
    }
    
    init(
        id: UUID = UUID(),
        name: String,
        contactPerson: String? = nil,
        email: String? = nil,
        phone: String? = nil,
        address: String? = nil,
        firestoreDocumentId: String? = nil
    ) {
        self.id = id
        self.name = name
        self.contactPerson = contactPerson
        self.email = email
        self.phone = phone
        self.address = address
        self.createdAt = Date()
        self.updatedAt = Date()
        self.firestoreDocumentId = firestoreDocumentId
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
