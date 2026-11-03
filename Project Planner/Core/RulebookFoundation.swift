//
//  RulebookFoundation.swift
//  Project Planner
//
//  Shared plumbing for rulebook 1.1.0 (docs/RULEBOOK.md §1, §4.2). Every value here comes from the
//  packed script through CanonicalBusinessEngine; nothing is decided in Swift.
//

import Foundation
import FirebaseFirestore

/// The signed-in organisation's business time zone and currency, cached for code that is not on
/// the main actor. `FirebaseBackend.currentOrganization` updates it on every change.
nonisolated enum OrganizationRulebookContext {
    /// `organizationTimeZone(countryCode)`. Europe/London until an organisation is loaded.
    nonisolated(unsafe) private(set) static var timeZoneIdentifier = "Europe/London"
    /// `resolveOrganizationCurrency`-equivalent input: the saved code, else `defaultCurrencyForCountry`.
    nonisolated(unsafe) private(set) static var currencyCode = "GBP"
    /// The organisation's `annualLeaveDefaults` (§4.4), which `CanonicalBusinessEngine.parseUserDocument` applies to a user document
    /// with no leave fields. Nil until an organisation is loaded (the rulebook default then applies).
    nonisolated(unsafe) private(set) static var annualLeaveDefaults: OrganizationAnnualLeaveDefaults? = nil
    /// The open organisation's document id (trimmed), or nil before one is loaded. Device caches that hold one
    /// company's data (timesheet drafts) put it in their keys so another company never reads them (§1).
    nonisolated(unsafe) private(set) static var organizationId: String? = nil
    /// The open organisation's four stored working-hours fields (`payrollTimePolicy`, `payrollTimePolicyPrior`,
    /// `payrollTimePolicyEffectiveFrom`, `payrollTimePolicyScheduled`) in the raw document shape the script reads
    /// (`CanonicalBusinessEngine.payrollPolicyDocument`), so a
    /// booking picker can ask for the rules in effect on each selected day (web `livePayrollState`). Nil until an
    /// organisation is loaded.
    nonisolated(unsafe) private(set) static var payrollPolicyDocument: [String: Any]? = nil

    @MainActor static func update(from org: Organization?) {
        let country = org?.countryCode ?? "GB"
        timeZoneIdentifier = CanonicalBusinessEngine.callJSON("organizationTimeZone", arguments: [country]) as? String
            ?? "Europe/London"
        var doc: [String: Any] = ["countryCode": country]
        if let code = org?.settings.currencyCode, !code.isEmpty { doc["currencyCode"] = code }
        currencyCode = CanonicalBusinessEngine.callJSON("resolveOrganizationCurrency", arguments: [doc]) as? String
            ?? "GBP"
        annualLeaveDefaults = org?.settings.annualLeaveDefaults
        let orgId = org?.firestoreDocumentId.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        organizationId = orgId.isEmpty ? nil : orgId
        payrollPolicyDocument = org.map { PayrollTimePolicyCatalog.payrollPolicyDocument(for: $0) }
    }

    static var timeZone: TimeZone {
        TimeZone(identifier: timeZoneIdentifier) ?? TimeZone(identifier: "Europe/London") ?? TimeZone(secondsFromGMT: 0)!
    }

    /// Gregorian, Monday-first calendar in the organisation zone (§1: one business time zone, week starts Monday).
    static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        calendar.locale = Locale(identifier: "en_GB")
        calendar.firstWeekday = 2
        calendar.minimumDaysInFirstWeek = 4
        return calendar
    }

    /// `YYYY-MM-DD` for `date` in the organisation zone.
    static func dayKey(_ date: Date) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    /// Organisation-zone midnight for a `YYYY-MM-DD` key.
    static func date(fromDayKey key: String) -> Date? {
        let parts = key.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        var components = DateComponents()
        components.year = parts[0]
        components.month = parts[1]
        components.day = parts[2]
        return calendar.date(from: components)
    }
}

/// `formatMoney(amount, currency)` (§4.2). Every organisation money figure goes through this.
nonisolated enum OrgMoney {
    static func format(_ amount: Double, currencyCode: String? = nil, decimals: Int = 2) -> String {
        let code = currencyCode ?? OrganizationRulebookContext.currencyCode
        if let text = CanonicalBusinessEngine.callJSON(
            "formatMoney", arguments: [amount.isFinite ? amount : 0, code, ["decimals": decimals]]
        ) as? String {
            return text
        }
        return String(format: "%.\(decimals)f", amount)
    }

    /// `currencySymbol(code)`, for input-field prefixes.
    static func symbol(currencyCode: String? = nil) -> String {
        let code = currencyCode ?? OrganizationRulebookContext.currencyCode
        return CanonicalBusinessEngine.callJSON("currencySymbol", arguments: [code]) as? String ?? code
    }

    /// `CURRENCY_OPTIONS`: `{ code, title, symbol }` for the organisation currency picker.
    static var options: [(code: String, title: String, symbol: String)] {
        let rows = CanonicalBusinessEngine.constant("CURRENCY_OPTIONS", as: [[String: String]].self) ?? []
        return rows.compactMap { row in
            guard let code = row["code"] else { return nil }
            return (code, row["title"] ?? code, row["symbol"] ?? code)
        }
    }
}

/// `writeMetadataFields(uid, "ios")` plus the server `updatedAt` (§1 "Writes carry metadata").
/// Merge into every partial update of a shared document.
nonisolated enum WriteMetadata {
    static func fields(userId: String?) -> [String: Any] {
        var fields: [String: Any] = ["updatedAt": FieldValue.serverTimestamp()]
        if let userId,
           let stamp = CanonicalBusinessEngine.callJSON("writeMetadataFields", arguments: [userId, "ios"]) as? [String: Any] {
            for (key, value) in stamp { fields[key] = value }
        }
        return fields
    }

    /// `data` with the metadata merged in (metadata never overrides a key the caller set, except `updatedAt`).
    static func stamped(_ data: [String: Any], userId: String?) -> [String: Any] {
        var out = data
        for (key, value) in fields(userId: userId) where key == "updatedAt" || out[key] == nil {
            out[key] = value
        }
        return out
    }
}
