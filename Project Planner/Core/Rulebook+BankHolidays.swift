//
//  Rulebook+BankHolidays.swift
//  Project Planner
//
//  Rulebook 1.4.0 (docs/RULEBOOK.md §4.1, §4.4): the one bank-holiday region list both apps offer
//  (`BANK_HOLIDAY_REGIONS`, web `lib/canonical/bankHolidayRegions.ts`) and the Company details region prompt
//  (`companyDetailsRegionPrompt`). Every answer comes from the packed script through
//  `CanonicalBusinessEngine.callJSON` / `constant`; nothing is decided here.
//

import Foundation

/// One `BANK_HOLIDAY_REGIONS` row, decoded. `countryCode` is the Nager.Date country; `countyCodes` are the Nager
/// subdivision codes whose holidays apply (`subdivisionCodes`), nil for every national holiday.
nonisolated struct BankHolidayRegion: Identifiable, Hashable, Codable, Sendable {
    let id: String
    let title: String
    let countryCode: String
    let countyCodes: [String]?

    nonisolated enum CodingKeys: String, CodingKey {
        case id
        case title
        case countryCode
        case countyCodes = "subdivisionCodes"
    }

    /// A script row (`{ id, title, countryCode, subdivisionCodes? }`), or nil when it is not that shape.
    static func fromScript(_ value: Any?) -> BankHolidayRegion? {
        guard let row = value as? [String: Any],
              let id = row["id"] as? String, !id.isEmpty,
              let title = row["title"] as? String,
              let countryCode = row["countryCode"] as? String else { return nil }
        let codes = (row["subdivisionCodes"] as? [String]).flatMap { $0.isEmpty ? nil : $0 }
        return BankHolidayRegion(id: id, title: title, countryCode: countryCode, countyCodes: codes)
    }
}

/// One `bankHolidayCountries()` row: a country with at least one listed region.
nonisolated struct BankHolidayCountry: Hashable, Sendable {
    let code: String
    let title: String
}

/// `companyDetailsRegionPrompt(previous, next)`: whether a country change must choose the region again.
nonisolated struct CompanyDetailsRegionPrompt: Equatable, Sendable {
    let required: Bool
    let choices: [BankHolidayRegion]
    let defaultRegionId: String?
    let message: String

    static let notRequired = CompanyDetailsRegionPrompt(required: false, choices: [], defaultRegionId: nil, message: "")

    /// True when the prompt is required and `regionId` is not one of its choices (Save stays off).
    func blocksSave(regionId: String?) -> Bool {
        guard required else { return false }
        guard let normalized = CanonicalBusinessEngine.normalizeBankHolidayRegionId(regionId) else { return true }
        return !choices.contains { $0.id == normalized }
    }
}

extension CanonicalBusinessEngine {
    /// `DEFAULT_BANK_HOLIDAY_REGION_ID` ("GB-ENG-WLS").
    nonisolated static var defaultBankHolidayRegionId: String {
        constant("DEFAULT_BANK_HOLIDAY_REGION_ID", as: String.self) ?? "GB-ENG-WLS"
    }

    /// `BANK_HOLIDAY_REGIONS`, in script order. Empty when the script did not answer.
    nonisolated static func bankHolidayRegions() -> [BankHolidayRegion] {
        constant("BANK_HOLIDAY_REGIONS", as: [BankHolidayRegion].self) ?? []
    }

    /// `bankHolidayRegionsForCountry(countryCode)`: the regions a picker offers for a company in that country.
    nonisolated static func bankHolidayRegionsForCountry(_ countryCode: String?) -> [BankHolidayRegion] {
        let rows = callJSON("bankHolidayRegionsForCountry", arguments: [countryCode ?? ""]) as? [Any] ?? []
        return rows.compactMap { BankHolidayRegion.fromScript($0) }
    }

    /// `defaultBankHolidayRegionForCountry(countryCode)`: GB → `GB-ENG-WLS`; a one-region country → that region;
    /// otherwise nil.
    nonisolated static func defaultBankHolidayRegionForCountry(_ countryCode: String?) -> String? {
        callJSON("defaultBankHolidayRegionForCountry", arguments: [countryCode ?? ""]) as? String
    }

    /// `normalizeBankHolidayRegionId(value)`: a listed id (aliases resolved, upper case), or nil.
    nonisolated static func normalizeBankHolidayRegionId(_ value: String?) -> String? {
        guard let value else { return nil }
        return callJSON("normalizeBankHolidayRegionId", arguments: [value]) as? String
    }

    /// `bankHolidayRegion(id)`: the listed region, or nil.
    nonisolated static func bankHolidayRegion(id: String?) -> BankHolidayRegion? {
        guard let id else { return nil }
        return BankHolidayRegion.fromScript(callJSON("bankHolidayRegion", arguments: [id]))
    }

    /// `bankHolidayRegionLabel(id)`: the region's title, or the raw value when it is not listed.
    nonisolated static func bankHolidayRegionLabel(_ id: String?) -> String {
        callJSON("bankHolidayRegionLabel", arguments: [id ?? ""]) as? String ?? (id ?? "")
    }

    /// `bankHolidayCountries()`: countries with at least one region, with their display name.
    nonisolated static func bankHolidayCountries() -> [BankHolidayCountry] {
        let rows = callJSON("bankHolidayCountries", arguments: []) as? [[String: Any]] ?? []
        return rows.compactMap { row in
            guard let code = row["code"] as? String, let title = row["title"] as? String else { return nil }
            return BankHolidayCountry(code: code, title: title)
        }
    }

    /// `bankHolidayCountryTitle(countryCode)`.
    nonisolated static func bankHolidayCountryTitle(_ countryCode: String?) -> String {
        callJSON("bankHolidayCountryTitle", arguments: [countryCode ?? ""]) as? String ?? (countryCode ?? "")
    }

    /// `companyDetailsRegionPrompt(previous, { countryCode })`. Not required when the script did not answer;
    /// `companyDetailsValidationError` (with `previous`) still refuses the save.
    nonisolated static func companyDetailsRegionPrompt(
        previousCountryCode: String?,
        previousBankHolidayRegionId: String?,
        countryCode: String
    ) -> CompanyDetailsRegionPrompt {
        let previous: [String: Any] = [
            "countryCode": previousCountryCode ?? NSNull(),
            "bankHolidayRegionId": previousBankHolidayRegionId ?? NSNull(),
        ]
        guard let row = callJSON(
            "companyDetailsRegionPrompt",
            arguments: [previous, ["countryCode": countryCode]]
        ) as? [String: Any],
            row["required"] as? Bool == true else {
            return .notRequired
        }
        let choices = (row["choices"] as? [Any] ?? []).compactMap { BankHolidayRegion.fromScript($0) }
        return CompanyDetailsRegionPrompt(
            required: true,
            choices: choices,
            defaultRegionId: row["defaultRegionId"] as? String,
            message: row["message"] as? String ?? ""
        )
    }

    /// `companyDetailsInput` plus the region and the saved country / region before this edit (`previous`), so
    /// `companyDetailsValidationError` asks for a region after a country change and `companyDetailsWriteFields`
    /// writes country and region in one partial update.
    nonisolated static func companyDetailsInput(
        name: String,
        hasOfficeAddress: Bool,
        officeAddressLine1: String?,
        officeAddressLine2: String?,
        officeCity: String?,
        officeCounty: String?,
        officePostcode: String?,
        countryCode: String,
        documentAbbreviation: String?,
        defaultLatitude: Double?,
        defaultLongitude: Double?,
        bankHolidayRegionId: String?,
        previousCountryCode: String?,
        previousBankHolidayRegionId: String?
    ) -> [String: Any] {
        var input = companyDetailsInput(
            name: name,
            hasOfficeAddress: hasOfficeAddress,
            officeAddressLine1: officeAddressLine1,
            officeAddressLine2: officeAddressLine2,
            officeCity: officeCity,
            officeCounty: officeCounty,
            officePostcode: officePostcode,
            countryCode: countryCode,
            documentAbbreviation: documentAbbreviation,
            defaultLatitude: defaultLatitude,
            defaultLongitude: defaultLongitude
        )
        let region = bankHolidayRegionId?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !region.isEmpty {
            input["bankHolidayRegionId"] = region
        }
        input["previous"] = [
            "countryCode": previousCountryCode ?? NSNull(),
            "bankHolidayRegionId": previousBankHolidayRegionId ?? NSNull(),
        ] as [String: Any]
        return input
    }

    /// The region whose holidays annual leave and scheduling use: the saved region (already
    /// `parseCompanyDetails`, so a company with none reads its country's default), else the country's default,
    /// else `DEFAULT_BANK_HOLIDAY_REGION_ID`.
    nonisolated static func resolvedBankHolidayRegion(for organization: Organization?) -> BankHolidayRegion? {
        if let saved = bankHolidayRegion(id: organization?.settings.bankHolidayRegionId) {
            return saved
        }
        if let countryDefault = defaultBankHolidayRegionForCountry(organization?.countryCode ?? "GB"),
           let region = bankHolidayRegion(id: countryDefault) {
            return region
        }
        return bankHolidayRegion(id: defaultBankHolidayRegionId)
    }
}
