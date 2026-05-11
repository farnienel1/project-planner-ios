//
//  PeopleModels.swift
//  Project Planner
//
//  Created by Assistant on 29/09/2025.
//

@preconcurrency import Foundation

// MARK: - Qualification Model (declared first for Hashable conformance)

// User-created qualifications model
// All properties are Sendable types. Hashable conformance is in extension with nonisolated methods.
struct Qualification: Identifiable, Codable, Sendable {
    let id: UUID
    var name: String
    var hasEndDate: Bool
    var endDate: Date?
    var createdAt: Date
    var updatedAt: Date
    
    nonisolated init(id: UUID = UUID(), name: String, hasEndDate: Bool = false, endDate: Date? = nil, createdAt: Date = Date(), updatedAt: Date = Date()) {
        self.id = id
        self.name = name
        self.hasEndDate = hasEndDate
        self.endDate = endDate
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
    
    // Codable conformance - make init(from:) nonisolated
    nonisolated init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        hasEndDate = try container.decode(Bool.self, forKey: .hasEndDate)
        endDate = try container.decodeIfPresent(Date.self, forKey: .endDate)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
    }
    
    nonisolated func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(hasEndDate, forKey: .hasEndDate)
        try container.encodeIfPresent(endDate, forKey: .endDate)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(updatedAt, forKey: .updatedAt)
    }
    
    private enum CodingKeys: String, CodingKey {
        case id, name, hasEndDate, endDate, createdAt, updatedAt
    }
}

// Hashable conformance so Set<Qualification> works. Must be before Operative.
extension Qualification: Hashable {
    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
    
    static func == (lhs: Qualification, rhs: Qualification) -> Bool {
        lhs.id == rhs.id
    }
}

// MARK: - Organisation skill catalogue

/// One row in `organizations/{orgId}/skills`. `id` is the Firestore document id and is what we store on `Operative.skills`.
struct OrganizationSkill: Identifiable, Hashable, Codable, Sendable {
    let id: String
    var name: String
    /// Trade grouping for filtering and display (e.g. preset trade label or "General").
    var trade: String
    var createdAt: Date
    var updatedAt: Date

    static let defaultTrade = "General"

    nonisolated init(
        id: String = UUID().uuidString,
        name: String,
        trade: String,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let t = trade.trimmingCharacters(in: .whitespacesAndNewlines)
        self.trade = t.isEmpty ? Self.defaultTrade : t
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    /// Line shown in lists: `Trade · Skill` (trade omitted when `General`).
    var listTitle: String {
        if trade.caseInsensitiveCompare(Self.defaultTrade) == .orderedSame {
            return name
        }
        return "\(trade) · \(name)"
    }

    static func normalizedPair(name: String, trade: String) -> (String, String) {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let t = trade.trimmingCharacters(in: .whitespacesAndNewlines)
        let tout = t.isEmpty ? defaultTrade.lowercased() : t.lowercased()
        return (n, tout)
    }
}

// MARK: - Operative Models

struct Operative: Identifiable, Codable {
    let id: UUID
    var firstName: String
    var lastName: String
    var email: String
    var phone: String?
    var startDate: Date
    var skills: Set<String>
    var qualifications: Set<Qualification>
    var qualificationExpiryDates: [UUID: Date]
    var qualificationCertificateURLs: [UUID: String]
    var isActive: Bool
    var hourlyRate: Double?
    /// Preferred day-rate field (distinct from legacy `hourlyRate` where both exist).
    var dayRate: Double?
    var currencySymbol: String?
    var notes: String?
    /// Stored `StaffTradeType.rawValue`, or "Other" when using `tradeTypeCustom`.
    var tradeTypePreset: String?
    var tradeTypeCustom: String?
    var createdAt: Date
    var updatedAt: Date
    
    // Computed property for backward compatibility
    var name: String {
        "\(firstName) \(lastName)".trimmingCharacters(in: .whitespaces)
    }
    
    @MainActor init(
        id: UUID = UUID(),
        firstName: String,
        lastName: String,
        email: String,
        phone: String? = nil,
        startDate: Date,
        skills: Set<String> = [],
        qualifications: [Qualification] = [],
        qualificationExpiryDates: [UUID: Date] = [:],
        qualificationCertificateURLs: [UUID: String] = [:],
        isActive: Bool = true,
        hourlyRate: Double? = nil,
        dayRate: Double? = nil,
        currencySymbol: String? = nil,
        notes: String? = nil,
        tradeTypePreset: String? = nil,
        tradeTypeCustom: String? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.firstName = firstName
        self.lastName = lastName
        self.email = email
        self.phone = phone
        self.startDate = startDate
        self.skills = skills
        var qualDict: [UUID: Qualification] = [:]
        for qual in qualifications {
            qualDict[qual.id] = qual
        }
        self.qualifications = Set(qualDict.values)
        self.qualificationExpiryDates = qualificationExpiryDates
        self.qualificationCertificateURLs = qualificationCertificateURLs
        self.isActive = isActive
        self.hourlyRate = hourlyRate
        self.dayRate = dayRate
        self.currencySymbol = currencySymbol
        self.notes = notes
        self.tradeTypePreset = tradeTypePreset
        self.tradeTypeCustom = tradeTypeCustom
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
    
    // Legacy initializer for backward compatibility
    @MainActor init(
        id: UUID = UUID(),
        name: String,
        email: String,
        phone: String? = nil,
        startDate: Date,
        skills: Set<String> = [],
        qualifications: [Qualification] = [],
        qualificationExpiryDates: [UUID: Date] = [:],
        qualificationCertificateURLs: [UUID: String] = [:],
        isActive: Bool = true,
        hourlyRate: Double? = nil,
        dayRate: Double? = nil,
        currencySymbol: String? = nil,
        notes: String? = nil,
        tradeTypePreset: String? = nil,
        tradeTypeCustom: String? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        let nameParts = name.trimmingCharacters(in: .whitespaces).split(separator: " ", maxSplits: 1)
        self.firstName = nameParts.count > 0 ? String(nameParts[0]) : name
        self.lastName = nameParts.count > 1 ? String(nameParts[1]) : ""
        self.email = email
        self.phone = phone
        self.startDate = startDate
        self.skills = skills
        var qualDict: [UUID: Qualification] = [:]
        for qual in qualifications {
            qualDict[qual.id] = qual
        }
        self.qualifications = Set(qualDict.values)
        self.qualificationExpiryDates = qualificationExpiryDates
        self.qualificationCertificateURLs = qualificationCertificateURLs
        self.isActive = isActive
        self.hourlyRate = hourlyRate
        self.dayRate = dayRate
        self.currencySymbol = currencySymbol
        self.notes = notes
        self.tradeTypePreset = tradeTypePreset
        self.tradeTypeCustom = tradeTypeCustom
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
    
    var experienceYears: Int {
        Calendar.current.dateComponents([.year], from: startDate, to: Date()).year ?? 0
    }
    
    var displaySkills: String {
        skills.joined(separator: ", ")
    }
    
    var displayQualifications: String {
        qualifications.map { $0.name }.joined(separator: ", ")
    }
}

// Explicit Hashable conformance for Operative with nonisolated methods
extension Operative: Hashable {
    nonisolated func hash(into hasher: inout Hasher) {
        hasher.combine(id)
        hasher.combine(email)
    }
    
    nonisolated static func == (lhs: Operative, rhs: Operative) -> Bool {
        lhs.id == rhs.id
    }
}

enum TradeSkill: String, CaseIterable, Identifiable, Codable, Hashable {
    case secondFix = "2nd Fix"
    case accessControl = "Access Control"
    case bms = "BMS"
    case cablePulling = "Cable Pulling"
    case containment = "Containment"
    case data = "Data"
    case distribution = "Distribution"
    case entryphone = "Entryphone"
    case fireAlarm = "Fire Alarm"
    case lightingControl = "Lighting Control"
    case security = "Security"
    case cctv = "CCTV"
    case testing = "Testing"
    case commissioning = "Commissioning"
    
    var id: String { rawValue }
    
    var category: SkillCategory {
        switch self {
        case .secondFix, .containment, .cablePulling:
            return .installation
        case .data, .accessControl, .bms, .lightingControl, .security, .cctv:
            return .systems
        case .fireAlarm, .entryphone:
            return .safety
        case .distribution:
            return .electrical
        case .testing, .commissioning:
            return .testing
        }
    }
}

enum SkillCategory: String, CaseIterable {
    case installation = "Installation"
    case systems = "Systems"
    case safety = "Safety"
    case electrical = "Electrical"
    case testing = "Testing"
}

// Legacy SkillBadge enum - keeping for backward compatibility
enum SkillBadge: String, CaseIterable, Identifiable, Codable, Hashable {
    case am2 = "AM2"
    case apprentice = "Apprentice"
    case blackCard = "Black Card"
    case goldCard = "Gold Card"
    case labourerCard = "Labourer Card"
    case testing = "Testing"
    case jib = "JIB"
    case ecs = "ECS"
    
    var id: String { rawValue }
    
    var level: BadgeLevel {
        switch self {
        case .apprentice, .labourerCard:
            return .entry
        case .am2, .blackCard, .ecs:
            return .qualified
        case .goldCard, .jib, .testing:
            return .advanced
        }
    }
}

enum BadgeLevel: String, CaseIterable {
    case entry = "Entry Level"
    case qualified = "Qualified"
    case advanced = "Advanced"
}

// MARK: - Manager Models

struct Manager: Identifiable, Codable, Hashable {
    let id: UUID
    var firstName: String
    var lastName: String
    var email: String
    var mobileNumber: String
    var department: String?
    var isActive: Bool
    var notes: String?
    var tradeTypePreset: String?
    var tradeTypeCustom: String?
    var createdAt: Date
    var updatedAt: Date
    
    init(
        id: UUID = UUID(),
        firstName: String,
        lastName: String,
        email: String,
        mobileNumber: String,
        department: String? = nil,
        isActive: Bool = true,
        notes: String? = nil,
        tradeTypePreset: String? = nil,
        tradeTypeCustom: String? = nil
    ) {
        self.id = id
        self.firstName = firstName
        self.lastName = lastName
        self.email = email
        self.mobileNumber = mobileNumber
        self.department = department
        self.isActive = isActive
        self.notes = notes
        self.tradeTypePreset = tradeTypePreset
        self.tradeTypeCustom = tradeTypeCustom
        self.createdAt = Date()
        self.updatedAt = Date()
    }
    
    var fullName: String {
        "\(firstName) \(lastName)"
    }
    
    var displayName: String {
        "\(firstName) \(lastName.last ?? Character(""))"
    }
}

// Default managers removed - now managed through Firebase

// Legacy enum for backward compatibility - now with N/A as default
enum ManagerLegacy: String, CaseIterable, Identifiable, Codable {
    case na = "N/A"
    case adam = "Adam"
    case billey = "Billey"
    case charley = "Charley"
    case farnie = "Farnie"
    case fin = "Fin"
    case greg = "Greg"
    case morgan = "Morgan"
    case ross = "Ross"
    case custom = "Custom"
    
    var id: String { rawValue }
    
    var displayName: String {
        switch self {
        case .na: return "N/A"
        case .adam: return "A. Mulley"
        case .billey: return "B. Brown"
        case .charley: return "C. Bramley"
        case .farnie: return "F. Nel"
        case .fin: return "F. Donovan"
        case .greg: return "G. Bliss"
        case .morgan: return "M. Elliott"
        case .ross: return "R. Mulley"
        case .custom: return "Custom Manager"
        }
    }
}
