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
    /// `officeAddressLine2` (optional; removed from the document when blank).
    var officeAddressLine2: String?
    var officeCity: String?
    /// `officeCounty` (optional; removed from the document when blank).
    var officeCounty: String?
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
    /// RULEBOOK 1.19.0 §1/§4.3: JSON text of the organisation's stored working-hours fields exactly as read
    /// (`payrollTimePolicy`, `payrollTimePolicyPrior`, `payrollTimePolicyEffectiveFrom`, `payrollTimePolicyScheduled`,
    /// `payrollTimePolicyHistory`, `payrollTimePolicyRevision`), Firestore values made JSON (`FirebaseBackend.firestoreJSON`).
    /// This is the policy STATE every pricing call passes to the script (`PayrollTimePolicyCatalog.payrollPolicyDocument`),
    /// so each day is read under its own history entry, and the base document of the two-admin save guard
    /// (`payrollTimePolicySaveConflict`). Nil before a document was read (the typed fields above are used then).
    var payrollPolicyStateJSON: String? = nil
    /// JSON text of `organizations/{id}.billing`, or nil when that nested map is absent.
    var billingJSON: String?
    /// JSON text of `organizations/{id}.deletion` (RULEBOOK 1.15.0 §20), or nil when the organisation is not being
    /// deleted. Read with `organizationDeletionState`.
    var deletionJSON: String? = nil
    /// True after an organisation document has been read. A stub company is still unresolved.
    var billingResolved: Bool

    init(
        id: UUID = UUID(),
        firestoreDocumentId: String? = nil,
        name: String,
        settings: OrganizationSettings = OrganizationSettings(),
        officeAddressLine1: String? = nil,
        officeAddressLine2: String? = nil,
        officeCity: String? = nil,
        officeCounty: String? = nil,
        officePostcode: String? = nil,
        countryCode: String = "GB",
        defaultLatitude: Double? = nil,
        defaultLongitude: Double? = nil,
        companyLogoURL: String? = nil,
        documentAbbreviation: String? = nil,
        creatorUserId: String? = nil,
        payrollTimePolicyPrior: OrgPayrollTimePolicy? = nil,
        payrollTimePolicyEffectiveFrom: Date? = nil,
        payrollTimePolicyScheduled: OrgPayrollTimePolicyScheduledChange? = nil,
        billingJSON: String? = nil,
        billingResolved: Bool = false,
        deletionJSON: String? = nil,
        payrollPolicyStateJSON: String? = nil
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
        self.officeAddressLine2 = officeAddressLine2
        self.officeCity = officeCity
        self.officeCounty = officeCounty
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
        self.billingJSON = billingJSON
        self.billingResolved = billingResolved
        self.deletionJSON = deletionJSON
        self.payrollPolicyStateJSON = payrollPolicyStateJSON
    }

    enum CodingKeys: String, CodingKey {
        case id, firestoreDocumentId, name, settings, officeAddressLine1, officeAddressLine2, officeCity, officeCounty, officePostcode
        case countryCode, defaultLatitude, defaultLongitude, companyLogoURL, documentAbbreviation, createdAt, updatedAt, creatorUserId
        case payrollTimePolicyPrior, payrollTimePolicyEffectiveFrom, payrollTimePolicyScheduled
        case billingJSON, billingResolved, deletionJSON, payrollPolicyStateJSON
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        settings = try c.decode(OrganizationSettings.self, forKey: .settings)
        officeAddressLine1 = try c.decodeIfPresent(String.self, forKey: .officeAddressLine1)
        officeAddressLine2 = try c.decodeIfPresent(String.self, forKey: .officeAddressLine2)
        officeCity = try c.decodeIfPresent(String.self, forKey: .officeCity)
        officeCounty = try c.decodeIfPresent(String.self, forKey: .officeCounty)
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
        billingJSON = try c.decodeIfPresent(String.self, forKey: .billingJSON)
        billingResolved = try c.decodeIfPresent(Bool.self, forKey: .billingResolved) ?? false
        deletionJSON = try c.decodeIfPresent(String.self, forKey: .deletionJSON)
        payrollPolicyStateJSON = try c.decodeIfPresent(String.self, forKey: .payrollPolicyStateJSON)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(firestoreDocumentId, forKey: .firestoreDocumentId)
        try c.encode(name, forKey: .name)
        try c.encode(settings, forKey: .settings)
        try c.encodeIfPresent(officeAddressLine1, forKey: .officeAddressLine1)
        try c.encodeIfPresent(officeAddressLine2, forKey: .officeAddressLine2)
        try c.encodeIfPresent(officeCity, forKey: .officeCity)
        try c.encodeIfPresent(officeCounty, forKey: .officeCounty)
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
        try c.encodeIfPresent(billingJSON, forKey: .billingJSON)
        try c.encode(billingResolved, forKey: .billingResolved)
        try c.encodeIfPresent(deletionJSON, forKey: .deletionJSON)
        try c.encodeIfPresent(payrollPolicyStateJSON, forKey: .payrollPolicyStateJSON)
    }

    /// Script result for this company's nested billing map. A missing map stays open. A script failure stays open.
    var subscriptionHasAccess: Bool {
        CanonicalBusinessEngine.hasAccess(billing: OrganizationBillingMap.dictionary(json: billingJSON)) ?? true
    }

    /// Maps an `organizations/{id}` Firestore document without exposing abbreviation plumbing at call sites.
    /// `fallbackName` is unused. An empty script result is a missing name; a nil script result stays empty.
    /// Company details come from `parseCompanyDetails` (flat fields, legacy nested `officeAddress` fallback).
    nonisolated static func make(
        fromFirestoreId orgId: String,
        data: [String: Any],
        settings: OrganizationSettings,
        fallbackName: String = "Organisation"
    ) -> Organization {
        _ = fallbackName
        let name = CanonicalBusinessEngine.parseOrganizationName(nameParsePayload(from: data)) ?? ""
        let raw = FirebaseBackend.firestoreJSON(data) as? [String: Any] ?? [:]
        let details = CanonicalBusinessEngine.parseCompanyDetails(orgDocument: raw)
        func detail(_ key: String) -> String? {
            if let details {
                let value = (details[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                return value.isEmpty ? nil : value
            }
            let value = (data[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return value.isEmpty ? nil : value
        }
        func number(_ key: String) -> Double? {
            if let details { return (details[key] as? NSNumber)?.doubleValue }
            return (data[key] as? NSNumber)?.doubleValue
        }
        let organization = Organization(
            id: Manager.stableId(forFirestoreDocumentId: orgId),
            firestoreDocumentId: orgId,
            name: name,
            settings: settings,
            officeAddressLine1: detail("officeAddressLine1"),
            officeAddressLine2: detail("officeAddressLine2"),
            officeCity: detail("officeCity"),
            officeCounty: detail("officeCounty"),
            officePostcode: detail("officePostcode"),
            countryCode: detail("countryCode")?.uppercased() ?? "GB",
            defaultLatitude: number("defaultLatitude"),
            defaultLongitude: number("defaultLongitude"),
            companyLogoURL: detail("companyLogoURL"),
            documentAbbreviation: OrganizationDocumentAbbreviation.normalized(detail("documentAbbreviation")),
            creatorUserId: data["creatorUserId"] as? String,
            billingJSON: OrganizationBillingMap.storedJSON(from: data),
            billingResolved: true,
            deletionJSON: OrganizationBillingMap.storedJSON(field: "deletion", from: data)
        )
        return organization
    }

    /// String fields `parseOrganizationName` reads. Firestore timestamps are left out so the script can run.
    nonisolated static func nameParsePayload(from data: [String: Any]) -> [String: Any] {
        var payload: [String: Any] = [:]
        for key in ["name", "organizationName", "organisationName", "companyName"] {
            if let value = data[key] as? String {
                payload[key] = value
            }
        }
        if let settings = data["settings"] as? [String: Any] {
            var nested: [String: Any] = [:]
            for key in ["name", "organizationName", "organisationName", "companyName"] {
                if let value = settings[key] as? String {
                    nested[key] = value
                }
            }
            if !nested.isEmpty {
                payload["settings"] = nested
            }
        }
        return payload
    }
}
