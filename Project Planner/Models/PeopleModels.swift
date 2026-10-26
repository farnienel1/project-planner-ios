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
    /// Firestore document id. Library rows use the stable code (`EL-ECS-IE`). Custom templates use an uppercase UUID.
    let id: String
    var name: String
    var hasEndDate: Bool
    var endDate: Date?
    var createdAt: Date
    var updatedAt: Date
    var code: String?
    var section: String?
    var subsection: String?
    var awardingBody: String?
    var level: Int?
    var renewYears: Double?
    var renewalType: String?
    var status: String?
    var notes: String?

    nonisolated init(
        id: String = UUID().uuidString,
        name: String,
        hasEndDate: Bool = false,
        endDate: Date? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        code: String? = nil,
        section: String? = nil,
        subsection: String? = nil,
        awardingBody: String? = nil,
        level: Int? = nil,
        renewYears: Double? = nil,
        renewalType: String? = nil,
        status: String? = nil,
        notes: String? = nil
    ) {
        self.id = id
        self.name = name
        self.hasEndDate = hasEndDate
        self.endDate = endDate
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.code = code
        self.section = section
        self.subsection = subsection
        self.awardingBody = awardingBody
        self.level = level
        self.renewYears = renewYears
        self.renewalType = renewalType
        self.status = status
        self.notes = notes
    }

    nonisolated init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        hasEndDate = try container.decode(Bool.self, forKey: .hasEndDate)
        endDate = try container.decodeIfPresent(Date.self, forKey: .endDate)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
        code = try container.decodeIfPresent(String.self, forKey: .code)
        section = try container.decodeIfPresent(String.self, forKey: .section)
        subsection = try container.decodeIfPresent(String.self, forKey: .subsection)
        awardingBody = try container.decodeIfPresent(String.self, forKey: .awardingBody)
        level = try container.decodeIfPresent(Int.self, forKey: .level)
        renewYears = try container.decodeIfPresent(Double.self, forKey: .renewYears)
        renewalType = try container.decodeIfPresent(String.self, forKey: .renewalType)
        status = try container.decodeIfPresent(String.self, forKey: .status)
        notes = try container.decodeIfPresent(String.self, forKey: .notes)
    }

    nonisolated func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(hasEndDate, forKey: .hasEndDate)
        try container.encodeIfPresent(endDate, forKey: .endDate)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(updatedAt, forKey: .updatedAt)
        try container.encodeIfPresent(code, forKey: .code)
        try container.encodeIfPresent(section, forKey: .section)
        try container.encodeIfPresent(subsection, forKey: .subsection)
        try container.encodeIfPresent(awardingBody, forKey: .awardingBody)
        try container.encodeIfPresent(level, forKey: .level)
        try container.encodeIfPresent(renewYears, forKey: .renewYears)
        try container.encodeIfPresent(renewalType, forKey: .renewalType)
        try container.encodeIfPresent(status, forKey: .status)
        try container.encodeIfPresent(notes, forKey: .notes)
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, hasEndDate, endDate, createdAt, updatedAt
        case code, section, subsection, awardingBody, level, renewYears, renewalType, status, notes
    }

    /// Library line under the name: awarding body and code, when the template has them.
    var librarySubtitle: String? {
        let parts = [awardingBody, code].compactMap { value -> String? in
            let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return trimmed.isEmpty ? nil : trimmed
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

// Hashable conformance so Set<Qualification> works. Must be before Operative.
extension Qualification: Hashable {
    nonisolated func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
    
    nonisolated static func == (lhs: Qualification, rhs: Qualification) -> Bool {
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

    nonisolated static let defaultTrade = "General"

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
    var qualificationExpiryDates: [String: Date]
    var qualificationCertificateURLs: [String: String]
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
        qualificationExpiryDates: [String: Date] = [:],
        qualificationCertificateURLs: [String: String] = [:],
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
        var qualDict: [String: Qualification] = [:]
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
        qualificationExpiryDates: [String: Date] = [:],
        qualificationCertificateURLs: [String: String] = [:],
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
        var qualDict: [String: Qualification] = [:]
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

/// Name for a labour booking. Bookings store an operative id, not a user account.
/// When that id is not on the roster, the row is leftover data, not a person called Operative.
/// Shown for a booked person no catalogue row or account matches. The booking row is never hidden.
nonisolated let unknownLabourPersonName = "Unknown person"

/// The account a labour booking names: its stored id, or the account that replaced that id (`formerIdAliases`).
func accountForLabourBooking(operativeId: UUID, users: [AppUser]) -> AppUser? {
    let storedId = Booking.storedOperativeId(for: operativeId)
    let aliases = CanonicalBusinessEngine.formerIdAliases(
        users.map { CanonicalFormerIdPerson(id: $0.id, formerIds: $0.formerUserIds) }
    ) ?? [:]
    let currentId = aliases[storedId] ?? storedId
    return users.first(where: { $0.id == currentId })
}

/// Email for a labour booking: the catalogue row's, else the account's. Nil when neither matches.
func emailForLabourBooking(operativeId: UUID, operatives: [Operative], users: [AppUser]) -> String? {
    if let email = operatives.first(where: { $0.id == operativeId })?.email, !email.isEmpty { return email }
    return accountForLabourBooking(operativeId: operativeId, users: users)?.email
}

func rosterNameForLabourBooking(operativeId: UUID, operatives: [Operative], users: [AppUser]) -> String {
    if let operative = operatives.first(where: { $0.id == operativeId }) {
        let trimmed = operative.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
    }
    // The stored id may be a Firebase Auth uid, or an invite placeholder id the account replaced (web #189).
    if let user = accountForLabourBooking(operativeId: operativeId, users: users) {
        let trimmed = user.fullName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        let email = user.email.trimmingCharacters(in: .whitespacesAndNewlines)
        if !email.isEmpty { return email }
    }
    return unknownLabourPersonName
}

/// The roster as the rulebook's `resolveBookingPerson` and `bookingIdsForAccount` take it: one account per
/// users document with its former invite ids and same-email ids, and every catalogue row with its email.
func bookingPersonInput(operatives: [Operative], users: [AppUser]) -> CanonicalBusinessEngine.CanonicalBookingPersonInput {
    CanonicalBusinessEngine.CanonicalBookingPersonInput(
        accounts: users.map {
            CanonicalBusinessEngine.CanonicalBookingPersonAccount(
                id: $0.id, email: $0.email, formerIds: $0.formerUserIds, aliasIds: $0.sameEmailUserIds
            )
        },
        operatives: operatives.map {
            CanonicalBusinessEngine.CanonicalBookingPersonOperative(id: $0.id.uuidString, email: $0.email)
        }
    )
}

/// The account and catalogue row behind a labour booking.
struct LabourBookingPerson: Equatable {
    var user: AppUser?
    var operative: Operative?
}

/// Answers "whose booking is this" with the rulebook's `resolveBookingPerson`, the function web's weekly report,
/// payroll and timesheets call. A booking stored under a uid, a former invite id or a same-email id finds its person
/// even with no catalogue row. Build one per screen pass: each distinct id asks the script once.
final class LabourBookingPeople {
    private let operatives: [Operative]
    private let users: [AppUser]
    private lazy var input = bookingPersonInput(operatives: operatives, users: users)
    private var cache: [UUID: LabourBookingPerson] = [:]

    init(operatives: [Operative], users: [AppUser]) {
        self.operatives = operatives
        self.users = users
    }

    func person(for operativeId: UUID) -> LabourBookingPerson {
        if let hit = cache[operativeId] { return hit }
        let found: LabourBookingPerson
        if let resolved = CanonicalBusinessEngine.resolveBookingPerson(Booking.storedOperativeId(for: operativeId), input) {
            found = LabourBookingPerson(
                user: resolved.accountId.flatMap { id in users.first { $0.id == id } },
                operative: resolved.operativeId.flatMap { id in
                    operatives.first { $0.id.uuidString.caseInsensitiveCompare(id) == .orderedSame }
                }
            )
        } else {
            // The script did not answer: keep the catalogue id and former-id lookups this app had before.
            found = LabourBookingPerson(
                user: accountForLabourBooking(operativeId: operativeId, users: users),
                operative: operatives.first { $0.id == operativeId }
            )
        }
        cache[operativeId] = found
        return found
    }
}

/// In-app ids of every booking this account owns, from the rulebook's `bookingIdsForAccount`: its own id, its former
/// invite ids, its same-email account ids and the catalogue rows on its email. Timesheets and job visibility use it so a
/// deleted and re-added person keeps the days booked under any of those ids.
func labourBookingIds(for user: AppUser, operatives: [Operative]) -> Set<UUID> {
    let account = CanonicalBusinessEngine.CanonicalBookingPersonAccount(
        id: user.id, email: user.email, formerIds: user.formerUserIds, aliasIds: user.sameEmailUserIds
    )
    let ids = CanonicalBusinessEngine.bookingIdsForAccount(
        account,
        operatives: operatives.map { CanonicalBusinessEngine.CanonicalBookingPersonOperative(id: $0.id.uuidString, email: $0.email) }
    ) ?? {
        // The script did not answer: the account's own ids and the catalogue rows on its email.
        let key = StaffEmailIdentity.emailKey(user.email)
        let catalogue = key.isEmpty ? [] : operatives.filter { StaffEmailIdentity.emailKey($0.email) == key }.map(\.id.uuidString)
        return [user.id] + user.formerUserIds + user.sameEmailUserIds + catalogue
    }()
    return Set(ids.map { Booking.internalOperativeId(for: $0) })
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
    /// `organizations/{org}/managers/{id}`. Kept when that id is not a UUID so a save updates the same document.
    var firestoreDocumentId: String

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
        tradeTypeCustom: String? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        firestoreDocumentId: String? = nil
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
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        let stored = firestoreDocumentId?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        self.firestoreDocumentId = stored.isEmpty ? id.uuidString : stored
    }

    /// Same document id always maps to the same in-memory id. A Firebase user id is not a UUID.
    static func stableId(forFirestoreDocumentId documentId: String) -> UUID {
        let trimmed = documentId.trimmingCharacters(in: .whitespacesAndNewlines)
        if let parsed = UUID(uuidString: trimmed) { return parsed }
        var h1: UInt64 = 14_695_981_039_346_656_037
        var h2: UInt64 = 1_099_511_628_211
        for byte in trimmed.utf8 {
            h1 ^= UInt64(byte)
            h1 &*= 1_099_511_628_211
            h2 ^= UInt64(byte)
            h2 &*= 14_695_981_039_346_656_037
        }
        var bytes = [UInt8](repeating: 0, count: 16)
        for index in 0..<8 {
            bytes[index] = UInt8((h1 >> (8 * index)) & 0xff)
            bytes[index + 8] = UInt8((h2 >> (8 * index)) & 0xff)
        }
        bytes[6] = (bytes[6] & 0x0F) | 0x50
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }

    enum CodingKeys: String, CodingKey {
        case id, firstName, lastName, email, mobileNumber, department, isActive, notes
        case tradeTypePreset, tradeTypeCustom, createdAt, updatedAt, firestoreDocumentId
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let id = try container.decode(UUID.self, forKey: .id)
        self.id = id
        firstName = try container.decode(String.self, forKey: .firstName)
        lastName = try container.decode(String.self, forKey: .lastName)
        email = try container.decode(String.self, forKey: .email)
        mobileNumber = try container.decodeIfPresent(String.self, forKey: .mobileNumber) ?? ""
        department = try container.decodeIfPresent(String.self, forKey: .department)
        isActive = try container.decodeIfPresent(Bool.self, forKey: .isActive) ?? true
        notes = try container.decodeIfPresent(String.self, forKey: .notes)
        tradeTypePreset = try container.decodeIfPresent(String.self, forKey: .tradeTypePreset)
        tradeTypeCustom = try container.decodeIfPresent(String.self, forKey: .tradeTypeCustom)
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? Date()
        let stored = try container.decodeIfPresent(String.self, forKey: .firestoreDocumentId)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        firestoreDocumentId = stored.isEmpty ? id.uuidString : stored
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(firstName, forKey: .firstName)
        try container.encode(lastName, forKey: .lastName)
        try container.encode(email, forKey: .email)
        try container.encode(mobileNumber, forKey: .mobileNumber)
        try container.encodeIfPresent(department, forKey: .department)
        try container.encode(isActive, forKey: .isActive)
        try container.encodeIfPresent(notes, forKey: .notes)
        try container.encodeIfPresent(tradeTypePreset, forKey: .tradeTypePreset)
        try container.encodeIfPresent(tradeTypeCustom, forKey: .tradeTypeCustom)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(updatedAt, forKey: .updatedAt)
        try container.encode(firestoreDocumentId, forKey: .firestoreDocumentId)
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
