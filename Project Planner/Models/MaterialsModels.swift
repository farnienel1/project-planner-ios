//
//  MaterialsModels.swift
//  Project Planner
//
//  Created by Assistant on 2025.
//

import Foundation
import FirebaseAuth

// MARK: - Material workflow status (project list lines)

enum MaterialWorkflowStatus: String, Codable, CaseIterable {
    case draft
    case sentForQuote
    case ordered

    var displayLabel: String {
        switch self {
        case .draft: return "Draft"
        case .sentForQuote: return "Sent for quote"
        case .ordered: return "Ordered"
        }
    }

    var isSent: Bool {
        self != .draft
    }
}

// MARK: - Material Item

struct MaterialItem: Identifiable, Codable, Hashable {
    let id: UUID
    var quantity: Int
    var unit: MaterialUnit
    var material: String // Description / name
    var addedBy: String // User who added it
    var addedByUserId: String? // Stable auth UID for ownership checks
    var addedAt: Date
    var editedBy: String? // User who last edited it (nil if never edited)
    var editedByUserId: String? // Stable auth UID for audit
    var editedAt: Date? // Date when last edited (nil if never edited)
    var projectId: UUID
    var date: Date // The date this material is needed/for
    var status: MaterialWorkflowStatus
    var catalogueItemId: UUID?
    var brand: String?
    var productCode: String?
    var sizeOrLength: String?
    var category: String?
    var websiteURL: String?
    var notes: String?
    var lastSentAt: Date?
    var lastSentRequestType: MaterialOrderRequest.RequestType?

    init(
        id: UUID = UUID(),
        quantity: Int,
        unit: MaterialUnit,
        material: String,
        addedBy: String,
        addedByUserId: String? = nil,
        addedAt: Date = Date(),
        editedBy: String? = nil,
        editedByUserId: String? = nil,
        editedAt: Date? = nil,
        projectId: UUID,
        date: Date,
        status: MaterialWorkflowStatus = .draft,
        catalogueItemId: UUID? = nil,
        brand: String? = nil,
        productCode: String? = nil,
        sizeOrLength: String? = nil,
        category: String? = nil,
        websiteURL: String? = nil,
        notes: String? = nil,
        lastSentAt: Date? = nil,
        lastSentRequestType: MaterialOrderRequest.RequestType? = nil
    ) {
        self.id = id
        self.quantity = quantity
        self.unit = unit
        self.material = material
        self.addedBy = addedBy
        self.addedByUserId = addedByUserId
        self.addedAt = addedAt
        self.editedBy = editedBy
        self.editedByUserId = editedByUserId
        self.editedAt = editedAt
        self.projectId = projectId
        self.date = date
        self.status = status
        self.catalogueItemId = catalogueItemId
        self.brand = brand
        self.productCode = productCode
        self.sizeOrLength = sizeOrLength
        self.category = category
        self.websiteURL = websiteURL
        self.notes = notes
        self.lastSentAt = lastSentAt
        self.lastSentRequestType = lastSentRequestType
    }

    var subtitleLine: String {
        let brandPart = brand?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let codePart = productCode?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let sizePart = sizeOrLength?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let categoryPart = category?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        var parts: [String] = []
        if !brandPart.isEmpty { parts.append(brandPart) }
        if !codePart.isEmpty { parts.append(codePart) }
        if !sizePart.isEmpty { parts.append(sizePart) }
        if !categoryPart.isEmpty { parts.append(categoryPart) }
        if !parts.isEmpty {
            return parts.joined(separator: " · ")
        }
        if let websiteURL, !websiteURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "Product link attached"
        }
        if catalogueItemId == nil {
            return "Custom item · no catalogue match"
        }
        return ""
    }
}

// MARK: - Organisation material catalogue

struct MaterialCatalogItem: Identifiable, Codable, Hashable {
    let id: UUID
    var name: String
    var brand: String
    var productCode: String?
    var defaultUnit: MaterialUnit
    var sizeOrLength: String?
    var category: String?
    var createdAt: Date
    var createdByUserId: String
    var createdByName: String

    init(
        id: UUID = UUID(),
        name: String,
        brand: String,
        productCode: String? = nil,
        defaultUnit: MaterialUnit,
        sizeOrLength: String? = nil,
        category: String? = nil,
        createdAt: Date = Date(),
        createdByUserId: String,
        createdByName: String
    ) {
        self.id = id
        self.name = name
        self.brand = brand
        self.productCode = productCode
        self.defaultUnit = defaultUnit
        self.sizeOrLength = sizeOrLength
        self.category = category
        self.createdAt = createdAt
        self.createdByUserId = createdByUserId
        self.createdByName = createdByName
    }

    var sizeOrLengthLabel: String? {
        let trimmed = sizeOrLength?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
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

    func quantityLabel(for quantity: Int) -> String {
        switch self {
        case .number:
            return quantity == 1 ? "Number" : "Numbers"
        case .box:
            return quantity == 1 ? "Box" : "Boxes"
        case .length:
            return quantity == 1 ? "Length" : "Lengths"
        }
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

// MARK: - Operative line ownership

func materialCanBeManagedByCurrentUser(
    _ material: MaterialItem,
    userStore: UserStore,
    firebaseBackend: FirebaseBackend
) -> Bool {
    guard let authUser = firebaseBackend.currentUser else { return false }
    if !userStore.isOperativeMode() {
        return true
    }
    if let ownerUserId = material.addedByUserId?.trimmingCharacters(in: .whitespacesAndNewlines),
       !ownerUserId.isEmpty {
        return ownerUserId == authUser.uid
    }

    let normalizedAddedBy = material.addedBy.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    if normalizedAddedBy.isEmpty {
        return false
    }

    let fullName = (userStore.currentUser?.fullName ?? "")
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .lowercased()
    let appEmail = (userStore.currentUser?.email ?? "")
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .lowercased()
    let authDisplayName = (authUser.displayName ?? "")
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .lowercased()
    let authEmail = (authUser.email ?? "")
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .lowercased()

    return normalizedAddedBy == fullName ||
        normalizedAddedBy == appEmail ||
        normalizedAddedBy == authDisplayName ||
        normalizedAddedBy == authEmail
}
