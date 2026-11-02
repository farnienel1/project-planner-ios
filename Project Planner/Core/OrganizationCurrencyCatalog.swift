//
//  OrganizationCurrencyCatalog.swift
//  Project Planner
//
//  Thin pass-through to the rulebook's money rules (`money.ts`): the list is `CURRENCY_OPTIONS`
//  (`OrgMoney.options`), the default is `defaultCurrencyForCountry`, a lookup is `currencyOption`.
//  There is no Swift currency table.
//

import Foundation

nonisolated struct OrganizationCurrencyOption: Identifiable, Hashable, Codable, Sendable {
    let code: String
    let title: String
    let symbol: String

    var id: String { code }
}

nonisolated enum OrganizationCurrencyCatalog: Sendable {
    /// `defaultCurrencyForCountry` for an unknown country (the script's `DEFAULT_CURRENCY_CODE`).
    nonisolated static var defaultCode: String {
        CanonicalBusinessEngine.defaultCurrencyForCountry("")
    }

    /// `CURRENCY_OPTIONS`, in the script's order.
    static var all: [OrganizationCurrencyOption] {
        OrgMoney.options.map { OrganizationCurrencyOption(code: $0.code, title: $0.title, symbol: $0.symbol) }
    }

    /// `currencyOption(code)`: the supported option, else the first option.
    static func option(for code: String?) -> OrganizationCurrencyOption {
        if let row = CanonicalBusinessEngine.callJSON("currencyOption", arguments: [code ?? ""]) as? [String: Any],
           let resolved = row["code"] as? String {
            return OrganizationCurrencyOption(
                code: resolved,
                title: row["title"] as? String ?? resolved,
                symbol: row["symbol"] as? String ?? resolved
            )
        }
        let normalized = (code ?? "").trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        return OrganizationCurrencyOption(code: normalized, title: normalized, symbol: normalized)
    }

    /// `defaultCurrencyForCountry(countryCode)`: suggested currency when an org has not saved one yet.
    static func defaultCode(forCountryCode countryCode: String) -> String {
        CanonicalBusinessEngine.defaultCurrencyForCountry(countryCode)
    }
}
