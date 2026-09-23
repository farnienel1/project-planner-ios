//
//  Organization.swift
//  Project Planner
//
//  Company record plus the 1–3 character badge used on site audits and toolbox talks.
//  Kept out of AppModels.swift so this type always compiles even when that file is slow to type-check.
//

import Foundation

/// 1–3 character company mark for site audits, toolbox talks, and organisation badges.
nonisolated enum OrganizationDocumentAbbreviation: Sendable {
    static let maxLength = 3

    nonisolated static func normalizeForTyping(_ raw: String) -> String {
        String(raw.uppercased().filter { $0.isLetter || $0.isNumber })
    }

    nonisolated static func normalized(_ raw: String?) -> String? {
        let cleaned = normalizeForTyping(raw ?? "")
        guard !cleaned.isEmpty else { return nil }
        return String(cleaned.prefix(maxLength))
    }

    nonisolated static func display(abbreviation: String?, organizationName: String?) -> String {
        if let n = normalized(abbreviation) { return n }
        let name = organizationName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !name.isEmpty else { return "PP" }
        let parts = name.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        if parts.count >= 2 {
            let letters = parts.prefix(maxLength).compactMap { $0.first }.map { String($0).uppercased() }
            return letters.joined()
        }
        return String((parts.first ?? name).prefix(maxLength)).uppercased()
    }

    @MainActor static func update(from org: Organization?) {
        currentDisplay = display(abbreviation: org?.documentAbbreviation, organizationName: org?.name)
    }

    /// Cached for PDF/draw paths that are not isolated to the main actor.
    nonisolated(unsafe) static var currentDisplay = "PP"
}

nonisolated struct Organization: Identifiable, Codable, Hashable {
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
    /// 1–3 character abbreviation shown on site audits, toolbox talks, and org badges.
    var documentAbbreviation: String?
    var createdAt: Date
    var updatedAt: Date
    /// Firebase Auth UID of the organization creator. Only this user may be super admin.
    var creatorUserId: String?
    /// Previous payroll rules — used for bookings dated before `payrollTimePolicyEffectiveFrom`.
    var payrollTimePolicyPrior: OrgPayrollTimePolicy?
    /// First calendar day (local) when `settings.payrollTimePolicy` applies.
    var payrollTimePolicyEffectiveFrom: Date?
    /// Queued future working-hours change (replaces any prior pending schedule on save).
    var payrollTimePolicyScheduled: OrgPayrollTimePolicyScheduledChange?

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
        documentAbbreviation: String? = nil,
        creatorUserId: String? = nil,
        payrollTimePolicyPrior: OrgPayrollTimePolicy? = nil,
        payrollTimePolicyEffectiveFrom: Date? = nil,
        payrollTimePolicyScheduled: OrgPayrollTimePolicyScheduledChange? = nil
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
        self.documentAbbreviation = OrganizationDocumentAbbreviation.normalized(documentAbbreviation)
        self.createdAt = Date()
        self.updatedAt = Date()
        self.creatorUserId = creatorUserId
        self.payrollTimePolicyPrior = payrollTimePolicyPrior
        self.payrollTimePolicyEffectiveFrom = payrollTimePolicyEffectiveFrom
        self.payrollTimePolicyScheduled = payrollTimePolicyScheduled
    }

    enum CodingKeys: String, CodingKey {
        case id, firestoreDocumentId, name, settings, officeAddressLine1, officeCity, officePostcode
        case countryCode, defaultLatitude, defaultLongitude, companyLogoURL, documentAbbreviation, createdAt, updatedAt, creatorUserId
        case payrollTimePolicyPrior, payrollTimePolicyEffectiveFrom, payrollTimePolicyScheduled
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
        documentAbbreviation = OrganizationDocumentAbbreviation.normalized(try c.decodeIfPresent(String.self, forKey: .documentAbbreviation))
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt) ?? Date()
        creatorUserId = try c.decodeIfPresent(String.self, forKey: .creatorUserId)
        firestoreDocumentId = try c.decodeIfPresent(String.self, forKey: .firestoreDocumentId) ?? id.uuidString
        payrollTimePolicyPrior = try c.decodeIfPresent(OrgPayrollTimePolicy.self, forKey: .payrollTimePolicyPrior)
        payrollTimePolicyEffectiveFrom = try c.decodeIfPresent(Date.self, forKey: .payrollTimePolicyEffectiveFrom)
        payrollTimePolicyScheduled = try c.decodeIfPresent(OrgPayrollTimePolicyScheduledChange.self, forKey: .payrollTimePolicyScheduled)
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
        try c.encodeIfPresent(documentAbbreviation, forKey: .documentAbbreviation)
        try c.encode(createdAt, forKey: .createdAt)
        try c.encode(updatedAt, forKey: .updatedAt)
        try c.encodeIfPresent(creatorUserId, forKey: .creatorUserId)
        try c.encodeIfPresent(payrollTimePolicyPrior, forKey: .payrollTimePolicyPrior)
        try c.encodeIfPresent(payrollTimePolicyEffectiveFrom, forKey: .payrollTimePolicyEffectiveFrom)
        try c.encodeIfPresent(payrollTimePolicyScheduled, forKey: .payrollTimePolicyScheduled)
    }

    /// Maps an `organizations/{id}` Firestore document without exposing abbreviation plumbing at call sites.
    nonisolated static func make(
        fromFirestoreId orgId: String,
        data: [String: Any],
        settings: OrganizationSettings,
        fallbackName: String = "Organisation"
    ) -> Organization {
        let resolvedName = (data["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return Organization(
            id: UUID(uuidString: orgId) ?? UUID(),
            firestoreDocumentId: orgId,
            name: (resolvedName?.isEmpty == false) ? resolvedName! : fallbackName,
            settings: settings,
            officeAddressLine1: data["officeAddressLine1"] as? String,
            officeCity: data["officeCity"] as? String,
            officePostcode: data["officePostcode"] as? String,
            countryCode: (data["countryCode"] as? String)?.uppercased() ?? "GB",
            defaultLatitude: data["defaultLatitude"] as? Double,
            defaultLongitude: data["defaultLongitude"] as? Double,
            companyLogoURL: data["companyLogoURL"] as? String,
            documentAbbreviation: OrganizationDocumentAbbreviation.normalized(data["documentAbbreviation"] as? String),
            creatorUserId: data["creatorUserId"] as? String
        )
    }
}
