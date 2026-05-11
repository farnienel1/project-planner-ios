import Foundation

enum SubcontractorContactPosition: String, CaseIterable, Codable, Identifiable {
    case finance = "Finance"
    case contractManager = "Contract Manager"
    case projectManager = "Project Manager"
    case siteManager = "Site Manager"
    case supervisor = "Supervisor"
    case installer = "Installer"
    
    var id: String { rawValue }
}

struct SubcontractorContact: Identifiable, Codable, Hashable {
    let id: UUID
    var name: String
    var email: String
    var contactNumber: String
    var position: SubcontractorContactPosition
    var createdAt: Date
    
    init(
        id: UUID = UUID(),
        name: String,
        email: String,
        contactNumber: String,
        position: SubcontractorContactPosition,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.email = email
        self.contactNumber = contactNumber
        self.position = position
        self.createdAt = createdAt
    }
}

struct Subcontractor: Identifiable, Codable, Hashable {
    let id: UUID
    var name: String
    var subcontractorType: String
    var website: String?
    var address: String?
    var contacts: [SubcontractorContact]
    var createdAt: Date
    var updatedAt: Date
    
    init(
        id: UUID = UUID(),
        name: String,
        subcontractorType: String,
        website: String? = nil,
        address: String? = nil,
        contacts: [SubcontractorContact] = [],
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.subcontractorType = subcontractorType
        self.website = website
        self.address = address
        self.contacts = contacts
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

struct SubcontractorBooking: Identifiable, Codable, Hashable {
    let id: UUID
    var subcontractorId: UUID
    var projectId: UUID
    var date: Date
    var timeSlot: TimeSlot
    var bookedBy: String
    var status: BookingStatus
    var createdAt: Date
    var updatedAt: Date
    
    init(
        id: UUID = UUID(),
        subcontractorId: UUID,
        projectId: UUID,
        date: Date,
        timeSlot: TimeSlot,
        bookedBy: String,
        status: BookingStatus = .confirmed,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.subcontractorId = subcontractorId
        self.projectId = projectId
        self.date = date
        self.timeSlot = timeSlot
        self.bookedBy = bookedBy
        self.status = status
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}
