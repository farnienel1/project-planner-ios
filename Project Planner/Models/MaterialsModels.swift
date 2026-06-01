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
    var size: String?
    var length: String?
    var lengthUnit: MaterialLengthUnit?
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
        size: String? = nil,
        length: String? = nil,
        lengthUnit: MaterialLengthUnit? = nil,
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
        self.size = size
        self.length = length ?? sizeOrLength
        self.lengthUnit = lengthUnit
        self.category = category
        self.websiteURL = websiteURL
        self.notes = notes
        self.lastSentAt = lastSentAt
        self.lastSentRequestType = lastSentRequestType
    }

    var subtitleLine: String {
        let brandPart = brand?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let codePart = productCode?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let sizePart = size?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let lengthPart = formattedLengthSpecification
        let categoryPart = category?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        var parts: [String] = []
        if !brandPart.isEmpty { parts.append(brandPart) }
        if !codePart.isEmpty { parts.append(codePart) }
        if !sizePart.isEmpty { parts.append("Size: \(sizePart)") }
        if !lengthPart.isEmpty { parts.append("Length: \(lengthPart)") }
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

    /// Combined length value + unit for lists, emails, and catalogue hints (e.g. `3 m`, `150 mm`).
    var formattedLengthSpecification: String {
        MaterialLengthSpecification.format(value: length, unit: lengthUnit)
    }

    var sendLineSnapshot: MaterialSendLineSnapshot {
        let lengthDisplay = formattedLengthSpecification
        return MaterialSendLineSnapshot(
            materialId: id,
            name: material,
            quantity: quantity,
            unit: unit,
            brand: brand,
            productCode: productCode,
            lengthDisplay: lengthDisplay.isEmpty ? nil : lengthDisplay
        )
    }
}

extension MaterialItem {
    /// Backward compatibility for older call sites and persisted data migrations.
    var sizeOrLength: String? {
        get {
            let trimmedLength = length?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !trimmedLength.isEmpty { return trimmedLength }
            let trimmedSize = size?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return trimmedSize.isEmpty ? nil : trimmedSize
        }
        set {
            let trimmed = newValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            length = trimmed.isEmpty ? nil : trimmed
        }
    }
}

// MARK: - Organisation material catalogue

struct MaterialCatalogItem: Identifiable, Codable, Hashable {
    let id: UUID
    var name: String
    var brand: String
    var productCode: String?
    var defaultUnit: MaterialUnit
    var size: String?
    var length: String?
    var lengthUnit: MaterialLengthUnit?
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
        size: String? = nil,
        length: String? = nil,
        lengthUnit: MaterialLengthUnit? = nil,
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
        self.size = size
        self.length = length ?? sizeOrLength
        self.lengthUnit = lengthUnit
        self.category = category
        self.createdAt = createdAt
        self.createdByUserId = createdByUserId
        self.createdByName = createdByName
    }

    var sizeOrLengthLabel: String? {
        let sizeTrimmed = size?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let lengthTrimmed = formattedLengthSpecification
        if !sizeTrimmed.isEmpty && !lengthTrimmed.isEmpty {
            return "Size: \(sizeTrimmed) · Length: \(lengthTrimmed)"
        }
        if !sizeTrimmed.isEmpty { return "Size: \(sizeTrimmed)" }
        if !lengthTrimmed.isEmpty { return "Length: \(lengthTrimmed)" }
        return nil
    }

    var formattedLengthSpecification: String {
        MaterialLengthSpecification.format(value: length, unit: lengthUnit)
    }
}

extension MaterialCatalogItem {
    /// Backward compatibility for older call sites and persisted data migrations.
    var sizeOrLength: String? {
        get {
            let trimmedLength = length?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !trimmedLength.isEmpty { return trimmedLength }
            let trimmedSize = size?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return trimmedSize.isEmpty ? nil : trimmedSize
        }
        set {
            let trimmed = newValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            length = trimmed.isEmpty ? nil : trimmed
        }
    }
}

// MARK: - Material length unit (metres / millimetres)

enum MaterialLengthUnit: String, CaseIterable, Codable {
    case metres = "M"
    case millimetres = "MM"

    var displayName: String { rawValue }

    var emailSuffix: String {
        switch self {
        case .metres: return "m"
        case .millimetres: return "mm"
        }
    }
}

enum MaterialLengthSpecification {
    static func format(value: String?, unit: MaterialLengthUnit?) -> String {
        let trimmedValue = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmedValue.isEmpty else { return "" }
        guard let unit else { return trimmedValue }
        return "\(trimmedValue) \(unit.emailSuffix)"
    }

    static func parseUnit(from raw: String?) -> MaterialLengthUnit? {
        switch raw?.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() {
        case "M", "METRE", "METRES", "METER", "METERS": return .metres
        case "MM", "MILLIMETRE", "MILLIMETRES", "MILLIMETER", "MILLIMETERS": return .millimetres
        default: return nil
        }
    }
}

// MARK: - Material quantity type (was “Unit” in the UI)

enum MaterialUnit: String, CaseIterable, Codable {
    case number = "Number"
    case box = "Box"
    case length = "Length"
    case drum = "Drum"
    case pallet = "Pallet"

    var displayName: String { rawValue }

    /// Label for quantity pickers (renamed from Unit → Type in the materials UI).
    static let typePickerTitle = "Type"

    func quantityLabel(for quantity: Int) -> String {
        switch self {
        case .number:
            return quantity == 1 ? "Number" : "Numbers"
        case .box:
            return quantity == 1 ? "Box" : "Boxes"
        case .length:
            return quantity == 1 ? "Length" : "Lengths"
        case .drum:
            return quantity == 1 ? "Drum" : "Drums"
        case .pallet:
            return quantity == 1 ? "Pallet" : "Pallets"
        }
    }
}

// MARK: - Material send history (quote / order batches)

struct MaterialSendRecipientSnapshot: Codable, Hashable {
    var name: String
    var email: String
    var wholesalerName: String?
}

struct MaterialSendLineSnapshot: Codable, Hashable {
    var materialId: UUID
    var name: String
    var quantity: Int
    var unit: MaterialUnit
    var brand: String?
    var productCode: String?
    var lengthDisplay: String?
}

struct MaterialSendRecord: Identifiable, Codable, Hashable {
    let id: UUID
    var projectId: UUID
    var requestType: MaterialOrderRequest.RequestType
    var sentAt: Date
    /// Calendar day the materials were scheduled for (matches materials list day strip).
    var materialsDate: Date?
    var sentBy: String
    var recipients: [MaterialSendRecipientSnapshot]
    var lines: [MaterialSendLineSnapshot]

    init(
        id: UUID = UUID(),
        projectId: UUID,
        requestType: MaterialOrderRequest.RequestType,
        sentAt: Date = Date(),
        materialsDate: Date? = nil,
        sentBy: String,
        recipients: [MaterialSendRecipientSnapshot],
        lines: [MaterialSendLineSnapshot]
    ) {
        self.id = id
        self.projectId = projectId
        self.requestType = requestType
        self.sentAt = sentAt
        self.materialsDate = materialsDate
        self.sentBy = sentBy
        self.recipients = recipients
        self.lines = lines
    }

    /// Day used for per-day history (materials delivery day, not necessarily send timestamp).
    func historyDay(calendar: Calendar = .current) -> Date {
        let raw = materialsDate ?? sentAt
        return calendar.startOfDay(for: raw)
    }

    /// Whether this send is tied to a wholesaler (name on recipient or contact email match).
    func involves(wholesaler: Wholesaler) -> Bool {
        let wholesalerEmails = Set(
            wholesaler.contacts
                .map { $0.email.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        )
        return recipients.contains { recipient in
            if let name = recipient.wholesalerName?.trimmingCharacters(in: .whitespacesAndNewlines),
               !name.isEmpty,
               name.caseInsensitiveCompare(wholesaler.name) == .orderedSame {
                return true
            }
            let email = recipient.email.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
            return wholesalerEmails.contains(email)
        }
    }

    var requestTypeLabel: String {
        requestType == .quote ? "Quote" : "Order"
    }

    var itemCountLabel: String {
        let n = lines.count
        return n == 1 ? "1 item" : "\(n) items"
    }
}

// MARK: - Wholesaler

struct Wholesaler: Identifiable, Codable, Hashable {
    let id: UUID
    var name: String
    var address: String?
    var trade: String?
    var accountNumber: String?
    var primaryContactId: UUID?
    var contacts: [WholesalerContact]
    var createdAt: Date
    var updatedAt: Date
    
    init(
        id: UUID = UUID(),
        name: String,
        address: String? = nil,
        trade: String? = nil,
        accountNumber: String? = nil,
        primaryContactId: UUID? = nil,
        contacts: [WholesalerContact] = [],
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.address = address
        self.trade = trade
        self.accountNumber = accountNumber
        self.primaryContactId = primaryContactId
        self.contacts = contacts
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    var primaryContact: WholesalerContact? {
        if let primaryContactId,
           let match = contacts.first(where: { $0.id == primaryContactId }) {
            return match
        }
        return contacts.first
    }

    var cityFromAddress: String? {
        WholesalerFormatting.city(from: address)
    }
}

enum WholesalerFormatting {
    static func city(from address: String?) -> String? {
        let trimmed = address?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty else { return nil }
        let parts = trimmed.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        if parts.count >= 2, let city = parts.dropLast().last, !city.isEmpty {
            return city
        }
        if let first = parts.first { return String(first) }
        return nil
    }

    static func monogram(for name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "?" }
        let words = trimmed.split(separator: " ")
        if words.count >= 2 {
            return "\(words[0].prefix(1))\(words[1].prefix(1))".uppercased()
        }
        return String(trimmed.prefix(2)).uppercased()
    }
}

// MARK: - Wholesaler Contact

struct WholesalerContact: Identifiable, Codable, Hashable {
    let id: UUID
    var name: String
    var email: String
    var isPrimary: Bool
    var createdAt: Date
    
    init(
        id: UUID = UUID(),
        name: String,
        email: String,
        isPrimary: Bool = false,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.email = email
        self.isPrimary = isPrimary
        self.createdAt = createdAt
    }
}

// MARK: - Material Order/Quote Request

struct MaterialOrderRequest: Codable {
    var projectId: UUID
    var projectNumber: String
    var projectName: String
    var siteAddress: String
    var materials: [MaterialItem]
    var requestType: RequestType // Quote or Order
    var sentBy: String
    var sentAt: Date
    var recipientContacts: [WholesalerContact]
    var senderName: String
    var senderEmail: String
    var senderPhone: String?
    var senderCompany: String
    var companyLogoURL: String?
    
    enum RequestType: String, Codable {
        case quote = "Quote"
        case order = "Order"
    }
    
    init(
        projectId: UUID,
        projectNumber: String,
        projectName: String,
        siteAddress: String,
        materials: [MaterialItem],
        requestType: RequestType,
        sentBy: String,
        sentAt: Date = Date(),
        recipientContacts: [WholesalerContact],
        senderName: String,
        senderEmail: String,
        senderPhone: String? = nil,
        senderCompany: String = "",
        companyLogoURL: String? = nil
    ) {
        self.projectId = projectId
        self.projectNumber = projectNumber
        self.projectName = projectName
        self.siteAddress = siteAddress
        self.materials = materials
        self.requestType = requestType
        self.sentBy = sentBy
        self.sentAt = sentAt
        self.recipientContacts = recipientContacts
        self.senderName = senderName
        self.senderEmail = senderEmail
        self.senderPhone = senderPhone
        self.senderCompany = senderCompany
        self.companyLogoURL = companyLogoURL
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
