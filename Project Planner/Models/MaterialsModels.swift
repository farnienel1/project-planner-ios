//
//  MaterialsModels.swift
//  Project Planner
//
//  Created by Assistant on 2025.
//

import Foundation

// MARK: - Material Item

struct MaterialItem: Identifiable, Codable, Hashable {
    let id: UUID
    var quantity: Int
    var unit: MaterialUnit
    var material: String // Description
    var addedBy: String // User who added it
    var addedAt: Date
    var editedBy: String? // User who last edited it (nil if never edited)
    var editedAt: Date? // Date when last edited (nil if never edited)
    var projectId: UUID
    var date: Date // The date this material is needed/for
    
    init(
        id: UUID = UUID(),
        quantity: Int,
        unit: MaterialUnit,
        material: String,
        addedBy: String,
        addedAt: Date = Date(),
        editedBy: String? = nil,
        editedAt: Date? = nil,
        projectId: UUID,
        date: Date
    ) {
        self.id = id
        self.quantity = quantity
        self.unit = unit
        self.material = material
        self.addedBy = addedBy
        self.addedAt = addedAt
        self.editedBy = editedBy
        self.editedAt = editedAt
        self.projectId = projectId
        self.date = date
    }
}

// MARK: - Material Unit

enum MaterialUnit: String, CaseIterable, Codable {
    case number = "Number"
    case box = "Box"
    case length = "Length"
    
    var displayName: String {
        rawValue
    }
}

// MARK: - Wholesaler

struct Wholesaler: Identifiable, Codable, Hashable {
    let id: UUID
    var name: String
    var address: String?
    var contacts: [WholesalerContact]
    var createdAt: Date
    var updatedAt: Date
    
    init(
        id: UUID = UUID(),
        name: String,
        address: String? = nil,
        contacts: [WholesalerContact] = [],
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.address = address
        self.contacts = contacts
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

// MARK: - Wholesaler Contact

struct WholesalerContact: Identifiable, Codable, Hashable {
    let id: UUID
    var name: String
    var email: String
    var createdAt: Date
    
    init(
        id: UUID = UUID(),
        name: String,
        email: String,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.email = email
        self.createdAt = createdAt
    }
}

// MARK: - Material Order/Quote Request

struct MaterialOrderRequest: Codable {
    var projectNumber: String
    var projectName: String
    var siteAddress: String
    var materials: [MaterialItem]
    var requestType: RequestType // Quote or Order
    var sentBy: String
    var sentAt: Date
    var recipientContacts: [WholesalerContact]
    
    enum RequestType: String, Codable {
        case quote = "Quote"
        case order = "Order"
    }
    
    init(
        projectNumber: String,
        projectName: String,
        siteAddress: String,
        materials: [MaterialItem],
        requestType: RequestType,
        sentBy: String,
        sentAt: Date = Date(),
        recipientContacts: [WholesalerContact]
    ) {
        self.projectNumber = projectNumber
        self.projectName = projectName
        self.siteAddress = siteAddress
        self.materials = materials
        self.requestType = requestType
        self.sentBy = sentBy
        self.sentAt = sentAt
        self.recipientContacts = recipientContacts
    }
}

