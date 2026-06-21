//
//  OrganizationCurrencyCatalog.swift
//  Project Planner
//

import Foundation

struct OrganizationCurrencyOption: Identifiable, Hashable, Codable, Sendable {
    let code: String
    let title: String
    let symbol: String

    var id: String { code }
}

enum OrganizationCurrencyCatalog {
    static let defaultCode = "GBP"

    static let all: [OrganizationCurrencyOption] = [
        OrganizationCurrencyOption(code: "GBP", title: "British pound", symbol: "£"),
        OrganizationCurrencyOption(code: "EUR", title: "Euro", symbol: "€"),
        OrganizationCurrencyOption(code: "USD", title: "US dollar", symbol: "$"),
        OrganizationCurrencyOption(code: "CAD", title: "Canadian dollar", symbol: "CA$"),
        OrganizationCurrencyOption(code: "AUD", title: "Australian dollar", symbol: "A$"),
        OrganizationCurrencyOption(code: "NZD", title: "New Zealand dollar", symbol: "NZ$"),
        OrganizationCurrencyOption(code: "SEK", title: "Swedish krona", symbol: "kr"),
        OrganizationCurrencyOption(code: "NOK", title: "Norwegian krone", symbol: "kr"),
        OrganizationCurrencyOption(code: "DKK", title: "Danish krone", symbol: "kr"),
        OrganizationCurrencyOption(code: "PLN", title: "Polish złoty", symbol: "zł"),
        OrganizationCurrencyOption(code: "AED", title: "UAE dirham", symbol: "د.إ"),
    ]

    static func option(for code: String?) -> OrganizationCurrencyOption {
        let normalized = (code ?? "").trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        return all.first { $0.code == normalized } ?? all[0]
    }

    /// Suggested currency when an org has not saved one yet.
    static func defaultCode(forCountryCode countryCode: String) -> String {
        switch countryCode.uppercased() {
        case "GB": return "GBP"
        case "IE", "FR", "DE", "ES", "IT", "NL": return "EUR"
        case "US": return "USD"
        case "CA": return "CAD"
        case "AU": return "AUD"
        case "NZ": return "NZD"
        case "SE": return "SEK"
        case "NO": return "NOK"
        case "DK": return "DKK"
        case "PL": return "PLN"
        case "AE": return "AED"
        default: return defaultCode
        }
    }
}
