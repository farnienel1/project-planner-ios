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
    /// RULEBOOK 1.48.0 (owner decision 3): whole numbers except Metre, so "12.5m" survives. Decodes an older cached Int.
    var quantity: Double
    /// The pre-1.48.0 unit (older builds read it). Written by the rulebook writer from the order unit; never offered.
    var unit: MaterialUnit
    /// RULEBOOK 1.48.0 `MATERIAL_ORDER_UNITS` (Each, Box, Pack, Drum, Reel, Coil, Pallet, Length, Metre), as the rulebook
    /// reader returned it. Nil on a line made or cached before 1.48.0 (read from the old fields, `effectiveQuantityModel`).
    var orderUnit: String? = nil
    /// What is in one (50 m on a drum, 3 m per length); nil when not given.
    var contentAmount: Double? = nil
    /// `m`, `mm` or `pcs`.
    var contentMeasure: String? = nil
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
        quantity: Double,
        unit: MaterialUnit,
        orderUnit: String? = nil,
        contentAmount: Double? = nil,
        contentMeasure: String? = nil,
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
        self.orderUnit = orderUnit
        self.contentAmount = contentAmount
        self.contentMeasure = contentMeasure
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
        // RULEBOOK 1.48.0: the length is part of the quantity text (`materialLineText`); Size is `materialSizeText`.
        let sizePart = CanonicalBusinessEngine.materialSizeText(size).trimmingCharacters(in: .whitespacesAndNewlines)
        let categoryPart = category?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        var parts: [String] = []
        if !brandPart.isEmpty { parts.append(brandPart) }
        if !codePart.isEmpty { parts.append(codePart) }
        if !sizePart.isEmpty { parts.append("Size: \(sizePart)") }
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
        let model = effectiveQuantityModel
        return MaterialSendLineSnapshot(
            materialId: id,
            name: material,
            quantity: quantity,
            unit: unit,
            brand: brand,
            productCode: productCode,
            lengthDisplay: lengthDisplay.isEmpty ? nil : lengthDisplay,
            orderUnit: model.orderUnit,
            contentAmount: model.contentAmount,
            contentMeasure: model.contentMeasure,
            // RULEBOOK 1.48.0: the text the line is sent with (`materialLineText`), kept on the record.
            quantityText: quantityText
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
    /// The pre-1.48.0 default unit (older builds read it); written by the rulebook writer from the order unit.
    var defaultUnit: MaterialUnit
    /// RULEBOOK 1.48.0: the default order unit and what is in one, as the rulebook reader returned them. Nil on an item
    /// cached before 1.48.0 (`effectiveQuantityModel` reads the old fields).
    var orderUnit: String? = nil
    var contentAmount: Double? = nil
    var contentMeasure: String? = nil
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
        orderUnit: String? = nil,
        contentAmount: Double? = nil,
        contentMeasure: String? = nil,
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
        self.orderUnit = orderUnit
        self.contentAmount = contentAmount
        self.contentMeasure = contentMeasure
        self.size = size
        self.length = length ?? sizeOrLength
        self.lengthUnit = lengthUnit
        self.category = category
        self.createdAt = createdAt
        self.createdByUserId = createdByUserId
        self.createdByName = createdByName
    }

    /// RULEBOOK 1.48.0: "Drum · 50m in one", with "Size: x" (`materialSizeText`) when there is one. The length is part
    /// of what is in one, never a separate "Length:".
    var sizeOrLengthLabel: String? {
        let sizeTrimmed = sizeDisplay.trimmingCharacters(in: .whitespacesAndNewlines)
        let unitLine = orderUnitSummary
        if !sizeTrimmed.isEmpty { return "\(unitLine) · Size: \(sizeTrimmed)" }
        return unitLine.isEmpty ? nil : unitLine
    }

    var formattedLengthSpecification: String {
        MaterialLengthSpecification.format(value: length, unit: lengthUnit)
    }
}

extension MaterialCatalogItem {
    var canonicalSearchRecord: CanonicalBusinessEngine.CanonicalMaterialRecord {
        CanonicalBusinessEngine.CanonicalMaterialRecord(
            name: name,
            brand: brand,
            productCode: productCode ?? "",
            category: category ?? "",
            size: size ?? "",
            length: length ?? sizeOrLength ?? ""
        )
    }

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
}

// MARK: - Material quantity type (was “Unit” in the UI)

enum MaterialUnit: String, CaseIterable, Codable {
    case number = "Number"
    case box = "Box"
    case length = "Length"
    case drum = "Drum"
    case pallet = "Pallet"

    var displayName: String { rawValue }

    // RULEBOOK 1.48.0: the old stored unit only. Pickers offer `MATERIAL_ORDER_UNITS`; every quantity is printed with
    // `materialLineText` (the old "2 Drums" wording is gone; past send records keep their text, `materialSendLineText`).
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
    /// RULEBOOK 1.48.0: a Metre line may be 12.5. Decodes an older cached Int.
    var quantity: Double
    var unit: MaterialUnit
    var brand: String?
    var productCode: String?
    var lengthDisplay: String?
    /// RULEBOOK 1.48.0: the order unit and what is in one (sent to the email function, stored on new records).
    var orderUnit: String? = nil
    var contentAmount: Double? = nil
    var contentMeasure: String? = nil
    /// RULEBOOK 1.48.0: the text the line was sent with (`materialLineText`); nil on records sent before 1.48.0.
    var quantityText: String? = nil
}

struct MaterialSendRecord: Identifiable, Codable, Hashable {
    let id: UUID
    var projectId: UUID
    var requestType: MaterialOrderRequest.RequestType
    var sentAt: Date
    /// Calendar day the materials were scheduled for (matches materials list day strip). Not the required delivery.
    var materialsDate: Date?
    /// Orders only. The instant the wholesaler must deliver. Quotes leave this empty.
    var deliveryRequiredAt: Date?
    var sentBy: String
    var recipients: [MaterialSendRecipientSnapshot]
    var lines: [MaterialSendLineSnapshot]

    init(
        id: UUID = UUID(),
        projectId: UUID,
        requestType: MaterialOrderRequest.RequestType,
        sentAt: Date = Date(),
        materialsDate: Date? = nil,
        deliveryRequiredAt: Date? = nil,
        sentBy: String,
        recipients: [MaterialSendRecipientSnapshot],
        lines: [MaterialSendLineSnapshot]
    ) {
        self.id = id
        self.projectId = projectId
        self.requestType = requestType
        self.sentAt = sentAt
        self.materialsDate = materialsDate
        self.deliveryRequiredAt = deliveryRequiredAt
        self.sentBy = sentBy
        self.recipients = recipients
        self.lines = lines
    }

    /// "Required Monday 12 October at 08:00" for an order that stored an instant. Quotes stay empty.
    var requiredDeliverySummary: String? {
        guard let label = CanonicalBusinessEngine.orderDeliveryRequiredLabel(
            requestType: requestType.rawValue,
            at: deliveryRequiredAt
        ) else { return nil }
        return "Required \(label)"
    }

    /// Day used for per-day history. This is the materials-list day, not `deliveryRequiredAt`.
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
    /// Mobile for WhatsApp. Web writes `phone` on the contact row; a save must keep it.
    var phone: String?

    init(
        id: UUID = UUID(),
        name: String,
        email: String,
        isPrimary: Bool = false,
        createdAt: Date = Date(),
        phone: String? = nil
    ) {
        self.id = id
        self.name = name
        self.email = email
        self.isPrimary = isPrimary
        self.createdAt = createdAt
        self.phone = phone
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
    /// When true, email body is plain text (same facts as the HTML template).
    var sendAsPlainText: Bool
    /// Required on orders: the delivery instant from the canonical script. Quotes leave it empty.
    var requiredDeliveryDate: Date?
    /// Idempotency key for the `sendEmail` function (`requestId`, web functions/email/requestDedupe.js): set once
    /// when the user presses Send (the send record's id) and kept in the offline outbox, so a replay after a crash or
    /// a timeout is answered from the first send instead of emailing the wholesaler again. Nil on requests queued by
    /// builds before it; the replay then uses the outbox entry's id.
    var requestId: String?
    
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
        companyLogoURL: String? = nil,
        sendAsPlainText: Bool = false,
        requiredDeliveryDate: Date? = nil,
        requestId: String? = nil
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
        self.sendAsPlainText = sendAsPlainText
        self.requiredDeliveryDate = requiredDeliveryDate
        self.requestId = requestId
    }

    enum CodingKeys: String, CodingKey {
        case projectId, projectNumber, projectName, siteAddress, materials, requestType
        case sentBy, sentAt, recipientContacts, senderName, senderEmail, senderPhone
        case senderCompany, companyLogoURL, sendAsPlainText, requiredDeliveryDate, requestId
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        projectId = try c.decode(UUID.self, forKey: .projectId)
        projectNumber = try c.decode(String.self, forKey: .projectNumber)
        projectName = try c.decode(String.self, forKey: .projectName)
        siteAddress = try c.decode(String.self, forKey: .siteAddress)
        materials = try c.decode([MaterialItem].self, forKey: .materials)
        requestType = try c.decode(RequestType.self, forKey: .requestType)
        sentBy = try c.decode(String.self, forKey: .sentBy)
        sentAt = try c.decode(Date.self, forKey: .sentAt)
        recipientContacts = try c.decode([WholesalerContact].self, forKey: .recipientContacts)
        senderName = try c.decode(String.self, forKey: .senderName)
        senderEmail = try c.decode(String.self, forKey: .senderEmail)
        senderPhone = try c.decodeIfPresent(String.self, forKey: .senderPhone)
        senderCompany = try c.decodeIfPresent(String.self, forKey: .senderCompany) ?? ""
        companyLogoURL = try c.decodeIfPresent(String.self, forKey: .companyLogoURL)
        sendAsPlainText = try c.decodeIfPresent(Bool.self, forKey: .sendAsPlainText) ?? false
        requiredDeliveryDate = try c.decodeIfPresent(Date.self, forKey: .requiredDeliveryDate)
        requestId = try c.decodeIfPresent(String.self, forKey: .requestId)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(projectId, forKey: .projectId)
        try c.encode(projectNumber, forKey: .projectNumber)
        try c.encode(projectName, forKey: .projectName)
        try c.encode(siteAddress, forKey: .siteAddress)
        try c.encode(materials, forKey: .materials)
        try c.encode(requestType, forKey: .requestType)
        try c.encode(sentBy, forKey: .sentBy)
        try c.encode(sentAt, forKey: .sentAt)
        try c.encode(recipientContacts, forKey: .recipientContacts)
        try c.encode(senderName, forKey: .senderName)
        try c.encode(senderEmail, forKey: .senderEmail)
        try c.encodeIfPresent(senderPhone, forKey: .senderPhone)
        try c.encode(senderCompany, forKey: .senderCompany)
        try c.encodeIfPresent(companyLogoURL, forKey: .companyLogoURL)
        try c.encode(sendAsPlainText, forKey: .sendAsPlainText)
        try c.encodeIfPresent(requiredDeliveryDate, forKey: .requiredDeliveryDate)
        try c.encodeIfPresent(requestId, forKey: .requestId)
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
