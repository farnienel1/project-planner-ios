//
//  BankHolidayRegionDirectory.swift
//  Project Planner
//
//  Annual leave / bank holiday regions for Nager.Date public holiday data.
//

import Foundation

struct BankHolidayRegion: Identifiable, Hashable, Codable, Sendable {
    let id: String
    let title: String
    /// ISO 3166-1 alpha-2 country code for Nager.Date.
    let countryCode: String
    /// When set, only holidays whose `counties` intersect these codes apply (UK subdivisions).
    let countyCodes: [String]?

    var groupTitle: String {
        BankHolidayRegionDirectory.groupTitle(for: countryCode)
    }
}

enum BankHolidayRegionDirectory {
    static let defaultRegionId = "GB-ENG-WLS"

    /// Curated regions — UK subdivisions plus countries aligned with org company settings.
    static let all: [BankHolidayRegion] = [
        BankHolidayRegion(id: "GB-ENG-WLS", title: "England & Wales", countryCode: "GB", countyCodes: ["GB-ENG", "GB-WLS"]),
        BankHolidayRegion(id: "GB-SCT", title: "Scotland", countryCode: "GB", countyCodes: ["GB-SCT"]),
        BankHolidayRegion(id: "GB-NIR", title: "Northern Ireland", countryCode: "GB", countyCodes: ["GB-NIR"]),
        BankHolidayRegion(id: "GB", title: "United Kingdom (all nations)", countryCode: "GB", countyCodes: nil),
        BankHolidayRegion(id: "IE", title: "Ireland", countryCode: "IE", countyCodes: nil),
        BankHolidayRegion(id: "US", title: "United States", countryCode: "US", countyCodes: nil),
        BankHolidayRegion(id: "CA", title: "Canada", countryCode: "CA", countyCodes: nil),
        BankHolidayRegion(id: "AU", title: "Australia", countryCode: "AU", countyCodes: nil),
        BankHolidayRegion(id: "NZ", title: "New Zealand", countryCode: "NZ", countyCodes: nil),
        BankHolidayRegion(id: "FR", title: "France", countryCode: "FR", countyCodes: nil),
        BankHolidayRegion(id: "DE", title: "Germany", countryCode: "DE", countyCodes: nil),
        BankHolidayRegion(id: "ES", title: "Spain", countryCode: "ES", countyCodes: nil),
        BankHolidayRegion(id: "IT", title: "Italy", countryCode: "IT", countyCodes: nil),
        BankHolidayRegion(id: "NL", title: "Netherlands", countryCode: "NL", countyCodes: nil),
        BankHolidayRegion(id: "SE", title: "Sweden", countryCode: "SE", countyCodes: nil),
        BankHolidayRegion(id: "NO", title: "Norway", countryCode: "NO", countyCodes: nil),
        BankHolidayRegion(id: "DK", title: "Denmark", countryCode: "DK", countyCodes: nil),
        BankHolidayRegion(id: "PL", title: "Poland", countryCode: "PL", countyCodes: nil),
        BankHolidayRegion(id: "AE", title: "United Arab Emirates", countryCode: "AE", countyCodes: nil),
    ]

    static func region(id: String?) -> BankHolidayRegion? {
        guard let id, !id.isEmpty else { return nil }
        return all.first { $0.id == id }
    }

    static func region(id: String?, fallbackCountryCode: String) -> BankHolidayRegion {
        if let match = region(id: id) { return match }
        return defaultRegion(forCountryCode: fallbackCountryCode)
    }

    /// Bank holidays for annual leave calendars — uses the saved annual-leave region, not company country.
    static func resolvedRegion(for organization: Organization?) -> BankHolidayRegion {
        if let id = organization?.settings.bankHolidayRegionId,
           let match = region(id: id) {
            return match
        }
        return defaultRegion(forCountryCode: organization?.countryCode ?? "GB")
    }

    /// Sensible default when no annual-leave bank-holiday region has been saved yet.
    static func defaultRegion(forCountryCode countryCode: String) -> BankHolidayRegion {
        switch countryCode.uppercased() {
        case "GB":
            return region(id: defaultRegionId) ?? all[0]
        case "IE": return region(id: "IE") ?? all.first { $0.id == "IE" }!
        case "US": return region(id: "US") ?? all.first { $0.id == "US" }!
        case "CA": return region(id: "CA") ?? all.first { $0.id == "CA" }!
        case "AU": return region(id: "AU") ?? all.first { $0.id == "AU" }!
        case "NZ": return region(id: "NZ") ?? all.first { $0.id == "NZ" }!
        case "FR": return region(id: "FR") ?? all.first { $0.id == "FR" }!
        case "DE": return region(id: "DE") ?? all.first { $0.id == "DE" }!
        case "ES": return region(id: "ES") ?? all.first { $0.id == "ES" }!
        case "IT": return region(id: "IT") ?? all.first { $0.id == "IT" }!
        case "NL": return region(id: "NL") ?? all.first { $0.id == "NL" }!
        case "SE": return region(id: "SE") ?? all.first { $0.id == "SE" }!
        case "NO": return region(id: "NO") ?? all.first { $0.id == "NO" }!
        case "DK": return region(id: "DK") ?? all.first { $0.id == "DK" }!
        case "PL": return region(id: "PL") ?? all.first { $0.id == "PL" }!
        case "AE": return region(id: "AE") ?? all.first { $0.id == "AE" }!
        default:
            if let countryMatch = all.first(where: { $0.countryCode == countryCode.uppercased() && $0.countyCodes == nil }) {
                return countryMatch
            }
            return region(id: defaultRegionId) ?? all[0]
        }
    }

    static func groupedRegions() -> [(group: String, regions: [BankHolidayRegion])] {
        let grouped = Dictionary(grouping: all, by: \.groupTitle)
        return grouped.keys.sorted().map { key in
            (key, grouped[key]!.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending })
        }
    }

    static func groupTitle(for countryCode: String) -> String {
        switch countryCode.uppercased() {
        case "GB": return "United Kingdom"
        case "IE": return "Ireland"
        case "US": return "Americas"
        case "CA": return "Americas"
        case "AU", "NZ": return "Oceania"
        case "AE": return "Middle East"
        default: return "Europe & other"
        }
    }
}
