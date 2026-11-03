//
//  Rulebook+OrganisationSettings.swift
//  Project Planner
//
//  Typed wrappers for the organisation-settings rules (RULEBOOK §1, §4): working hours over time,
//  payment runs, currency, company details and My Schedule locations. Every answer comes from the
//  packed script through `CanonicalBusinessEngine.callJSON`; nothing here decides a rule.
//

import Foundation

extension CanonicalBusinessEngine {
    // MARK: - Organisation zone (for a document that is not `currentOrganization` yet)

    /// `organizationTimeZone(countryCode)`.
    nonisolated static func organizationTimeZoneIdentifier(countryCode: String?) -> String {
        let country = countryCode?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return callJSON("organizationTimeZone", arguments: [country.isEmpty ? "GB" : country]) as? String
            ?? "Europe/London"
    }

    /// Gregorian, Monday-first calendar in `timeZoneIdentifier`.
    nonisolated static func organizationCalendar(timeZoneIdentifier: String) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: timeZoneIdentifier) ?? OrganizationRulebookContext.timeZone
        calendar.locale = Locale(identifier: "en_GB")
        calendar.firstWeekday = 2
        calendar.minimumDaysInFirstWeek = 4
        return calendar
    }

    /// `YYYY-MM-DD` of `date` in `timeZoneIdentifier`.
    nonisolated static func organizationDayKey(_ date: Date, timeZoneIdentifier: String) -> String {
        let parts = organizationCalendar(timeZoneIdentifier: timeZoneIdentifier).dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    /// Midnight of a `YYYY-MM-DD` key in `timeZoneIdentifier`.
    nonisolated static func organizationDate(fromDayKey key: String, timeZoneIdentifier: String) -> Date? {
        let parts = key.trimmingCharacters(in: .whitespacesAndNewlines).prefix(10).split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        var components = DateComponents()
        components.year = parts[0]
        components.month = parts[1]
        components.day = parts[2]
        return organizationCalendar(timeZoneIdentifier: timeZoneIdentifier).date(from: components)
    }

    // MARK: - Working hours over time (payrollPolicySchedule.ts)

    /// The script's own policy shape (`parsePayrollPolicy`) for a Swift policy.
    nonisolated static func payrollPolicyJSON(_ policy: OrgPayrollTimePolicy) -> [String: Any]? {
        callJSON("parsePayrollPolicy", arguments: [policy.asFirestoreDictionary()]) as? [String: Any]
    }

    /// A policy the script returned (its own shape or the stored one) as the Swift model.
    nonisolated static func payrollPolicy(fromJSON value: Any?) -> OrgPayrollTimePolicy? {
        guard let map = value as? [String: Any] else { return nil }
        return OrgPayrollTimePolicy.fromFirestore(map)
    }

    /// The four stored payroll fields of an organisation, as the raw document shape the script reads.
    nonisolated static func payrollPolicyDocument(
        current: OrgPayrollTimePolicy,
        prior: OrgPayrollTimePolicy?,
        effectiveFromDayKey: String?,
        scheduledPolicy: OrgPayrollTimePolicy?,
        scheduledEffectiveFromDayKey: String?
    ) -> [String: Any] {
        var doc: [String: Any] = ["payrollTimePolicy": current.asFirestoreDictionary()]
        doc["payrollTimePolicyPrior"] = prior?.asFirestoreDictionary() ?? NSNull()
        doc["payrollTimePolicyEffectiveFrom"] = effectiveFromDayKey ?? NSNull()
        if let scheduledPolicy, let scheduledEffectiveFromDayKey {
            doc["payrollTimePolicyScheduled"] = [
                "policy": scheduledPolicy.asFirestoreDictionary(),
                "effectiveFrom": scheduledEffectiveFromDayKey,
            ]
        } else {
            doc["payrollTimePolicyScheduled"] = NSNull()
        }
        return doc
    }

    /// `effectivePayrollTimePolicy(orgDoc, dayKey, timeZone)`: the rules in force on `dayKey`.
    nonisolated static func effectivePayrollTimePolicy(
        orgDocument: [String: Any],
        dayKey: String,
        timeZone: String = OrganizationRulebookContext.timeZoneIdentifier
    ) -> OrgPayrollTimePolicy? {
        payrollPolicy(fromJSON: callJSON("effectivePayrollTimePolicy", arguments: [orgDocument, dayKey, timeZone]))
    }

    /// `payrollTimePolicyTimeline(orgDoc, todayKey, timeZone)`, as Swift values.
    nonisolated struct PayrollTimePolicyTimelineState {
        var current: OrgPayrollTimePolicy
        var prior: OrgPayrollTimePolicy?
        var effectiveFromDayKey: String?
        var scheduledPolicy: OrgPayrollTimePolicy?
        var scheduledEffectiveFromDayKey: String?
    }

    nonisolated static func payrollTimePolicyTimeline(
        orgDocument: [String: Any],
        todayKey: String,
        timeZone: String = OrganizationRulebookContext.timeZoneIdentifier
    ) -> PayrollTimePolicyTimelineState? {
        guard let state = callJSON("payrollTimePolicyTimeline", arguments: [orgDocument, todayKey, timeZone]) as? [String: Any],
              let current = payrollPolicy(fromJSON: state["current"]) else { return nil }
        let scheduled = state["scheduled"] as? [String: Any]
        let scheduledPolicy = payrollPolicy(fromJSON: scheduled?["policy"])
        let scheduledDay = scheduled?["effectiveFrom"] as? String
        return PayrollTimePolicyTimelineState(
            current: current,
            prior: payrollPolicy(fromJSON: state["prior"]),
            effectiveFromDayKey: state["effectiveFrom"] as? String,
            scheduledPolicy: scheduledDay == nil ? nil : scheduledPolicy,
            scheduledEffectiveFromDayKey: scheduledPolicy == nil ? nil : scheduledDay
        )
    }

    /// `payrollTimePolicyApplyNowWriteFields`: "Apply from today". Nil when the script did not answer.
    nonisolated static func payrollTimePolicyApplyNowWriteFields(
        orgDocument: [String: Any],
        policy: OrgPayrollTimePolicy,
        todayKey: String,
        timeZone: String = OrganizationRulebookContext.timeZoneIdentifier
    ) -> [String: Any]? {
        guard let policyJSON = payrollPolicyJSON(policy) else { return nil }
        let input: [String: Any] = ["orgDoc": orgDocument, "policy": policyJSON, "todayKey": todayKey, "timeZone": timeZone]
        return callJSON("payrollTimePolicyApplyNowWriteFields", arguments: [input]) as? [String: Any]
    }

    /// `payrollTimePolicyScheduleWriteFields`: "Schedule from a date". Nil when the date is refused or the script did not answer.
    nonisolated static func payrollTimePolicyScheduleWriteFields(
        orgDocument: [String: Any],
        policy: OrgPayrollTimePolicy,
        effectiveFrom: String,
        todayKey: String,
        timeZone: String = OrganizationRulebookContext.timeZoneIdentifier
    ) -> [String: Any]? {
        guard let policyJSON = payrollPolicyJSON(policy) else { return nil }
        let input: [String: Any] = [
            "orgDoc": orgDocument, "policy": policyJSON, "effectiveFrom": effectiveFrom,
            "todayKey": todayKey, "timeZone": timeZone,
        ]
        return callJSON("payrollTimePolicyScheduleWriteFields", arguments: [input]) as? [String: Any]
    }

    /// `payrollTimePolicyCancelScheduleWriteFields`: cancel a pending change (promotes a due one first).
    nonisolated static func payrollTimePolicyCancelScheduleWriteFields(
        orgDocument: [String: Any],
        todayKey: String,
        timeZone: String = OrganizationRulebookContext.timeZoneIdentifier
    ) -> [String: Any]? {
        let input: [String: Any] = ["orgDoc": orgDocument, "todayKey": todayKey, "timeZone": timeZone]
        return callJSON("payrollTimePolicyCancelScheduleWriteFields", arguments: [input]) as? [String: Any]
    }

    /// `payrollTimePolicyScheduleDateError`. Nil when the date is accepted.
    nonisolated static func payrollTimePolicyScheduleDateError(effectiveFrom: String, todayKey: String) -> String? {
        guard let value = callJSON("payrollTimePolicyScheduleDateError", arguments: [effectiveFrom, todayKey]) else {
            return "Could not check this date."
        }
        return value as? String
    }

    /// `validatePayrollTimePolicy`. Nil when the policy can be saved.
    nonisolated static func validatePayrollTimePolicy(_ policy: OrgPayrollTimePolicy) -> String? {
        guard let policyJSON = payrollPolicyJSON(policy),
              let value = callJSON("validatePayrollTimePolicy", arguments: [policyJSON]) else {
            return "Could not check these working hours."
        }
        return value as? String
    }

    nonisolated struct PayrollPolicyLimit: Decodable, Sendable {
        let min: Double
        let max: Double
    }

    nonisolated struct PayrollPolicyLimits: Decodable, Sendable {
        let paidHours: PayrollPolicyLimit
        let breakMinutes: PayrollPolicyLimit
        let multiplier: PayrollPolicyLimit
    }

    /// `PAYROLL_POLICY_LIMITS`.
    nonisolated static var payrollPolicyLimits: PayrollPolicyLimits? {
        constant("PAYROLL_POLICY_LIMITS", as: PayrollPolicyLimits.self)
    }

    // MARK: - Payment runs (paymentRuns.ts, engine.ts)

    /// The invoicing map in the shape the script reads.
    nonisolated static func invoicingJSON(_ settings: OrganizationInvoicingSettings) -> [String: Any]? {
        guard let data = try? JSONEncoder().encode(settings.canonicalInvoicingSettings()),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return object
    }

    nonisolated struct ActivePaymentRun: Equatable, Sendable {
        let startDayKey: String
        let endDayKey: String
        let payDayKey: String?
        let label: String
    }

    /// `activePaymentRunSummary(invoicing, now, timeZone)`. Nil when not configured or the script did not answer.
    nonisolated static func activePaymentRunSummary(
        _ settings: OrganizationInvoicingSettings,
        now: Date = Date(),
        timeZone: String = OrganizationRulebookContext.timeZoneIdentifier
    ) -> ActivePaymentRun? {
        guard let invoicing = invoicingJSON(settings),
              let row = callJSON("activePaymentRunSummary", arguments: [invoicing, isoString(from: now), timeZone]) as? [String: Any],
              (row["notConfigured"] as? Bool) == false,
              let start = row["start"] as? String,
              let end = row["end"] as? String else { return nil }
        return ActivePaymentRun(
            startDayKey: start,
            endDayKey: end,
            payDayKey: row["payDate"] as? String,
            label: row["label"] as? String ?? ""
        )
    }

    /// `invoicingPeriod`: the payment-run segment containing `reference` in the organisation zone.
    nonisolated static func invoicingPeriod(
        _ settings: OrganizationInvoicingSettings,
        reference: Date,
        timeZone: String = OrganizationRulebookContext.timeZoneIdentifier
    ) -> CanonicalDayWindow? {
        let input: [String: Any] = [
            "referenceIso": isoString(from: reference),
            "timeZone": timeZone,
            "paymentRunMode": settings.paymentRunMode.rawValue,
            "ranges": settings.paymentRunDateRanges.map { ["startDay": $0.startDay, "endDay": $0.endDay] },
            "recurringRunStartDay": settings.recurringRunStartDay.rawValue,
            "recurringRunEndDay": settings.recurringRunEndDay.rawValue,
        ]
        guard let row = callJSON("invoicingPeriod", arguments: [input]) as? [String: Any],
              let start = row["startDayKey"] as? String, !start.isEmpty,
              let end = row["endDayKey"] as? String, !end.isEmpty else { return nil }
        return CanonicalDayWindow(startDayKey: start, endDayKey: end)
    }

    /// `paymentRunPayDate(invoicing, period, timeZone)`: the pay day key, or nil when no payment day is set.
    nonisolated static func paymentRunPayDate(
        _ settings: OrganizationInvoicingSettings,
        period: CanonicalDayWindow,
        timeZone: String = OrganizationRulebookContext.timeZoneIdentifier
    ) -> String? {
        guard let invoicing = invoicingJSON(settings) else { return nil }
        let window: [String: Any] = ["startDayKey": period.startDayKey, "endDayKey": period.endDayKey]
        return callJSON("paymentRunPayDate", arguments: [invoicing, window, timeZone]) as? String
    }

    /// `formatPaymentRunDay`: `2026-11-06` → `Fri 6 Nov`.
    nonisolated static func formatPaymentRunDay(_ dayKey: String) -> String {
        callJSON("formatPaymentRunDay", arguments: [dayKey]) as? String ?? dayKey
    }

    // MARK: - Currency (money.ts)

    /// `resolveOrganizationCurrency(orgDoc)` on the raw document (honours the legacy literal key).
    nonisolated static func resolveOrganizationCurrency(orgDocument: [String: Any]) -> String? {
        callJSON("resolveOrganizationCurrency", arguments: [orgDocument]) as? String
    }

    /// `defaultCurrencyForCountry(countryCode)`.
    nonisolated static func defaultCurrencyForCountry(_ countryCode: String?) -> String {
        callJSON("defaultCurrencyForCountry", arguments: [countryCode ?? ""]) as? String ?? "GBP"
    }

    /// `normalizeCurrencyCode`: a supported code in upper case, or nil.
    nonisolated static func normalizeCurrencyCode(_ code: String) -> String? {
        callJSON("normalizeCurrencyCode", arguments: [code]) as? String
    }

    /// `organizationCurrencyWriteFields(code)`: dotted partial update. Nil for an unsupported code.
    nonisolated static func organizationCurrencyWriteFields(_ code: String) -> [String: Any]? {
        callJSON("organizationCurrencyWriteFields", arguments: [code]) as? [String: Any]
    }

    // MARK: - Company details (companyDetails.ts)

    /// `parseCompanyDetails(orgDoc)` (flat fields, legacy nested `officeAddress` fallback).
    nonisolated static func parseCompanyDetails(orgDocument: [String: Any]) -> [String: Any]? {
        callJSON("parseCompanyDetails", arguments: [orgDocument]) as? [String: Any]
    }

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
        defaultLongitude: Double?
    ) -> [String: Any] {
        var input: [String: Any] = [
            "name": name,
            "hasOfficeAddress": hasOfficeAddress,
            "officeAddressLine1": officeAddressLine1 ?? "",
            "officeAddressLine2": officeAddressLine2 ?? "",
            "officeCity": officeCity ?? "",
            "officeCounty": officeCounty ?? "",
            "officePostcode": officePostcode ?? "",
            "countryCode": countryCode,
            "documentAbbreviation": documentAbbreviation ?? "",
        ]
        if let defaultLatitude, let defaultLongitude, defaultLatitude.isFinite, defaultLongitude.isFinite {
            input["defaultLatitude"] = defaultLatitude
            input["defaultLongitude"] = defaultLongitude
        }
        return input
    }

    /// `companyDetailsValidationError(input)`. Nil when the details can be saved.
    nonisolated static func companyDetailsValidationError(_ input: [String: Any]) -> String? {
        guard let value = callJSON("companyDetailsValidationError", arguments: [input]) else {
            return "Could not check these company details."
        }
        return value as? String
    }

    /// `companyDetailsWriteFields(input)` → `{ set, remove }`.
    nonisolated static func companyDetailsWriteFields(_ input: [String: Any]) -> (set: [String: Any], remove: [String])? {
        guard let row = callJSON("companyDetailsWriteFields", arguments: [input]) as? [String: Any],
              let set = row["set"] as? [String: Any] else { return nil }
        return (set, row["remove"] as? [String] ?? [])
    }

    // MARK: - My Schedule locations (scheduleOptions.ts)

    nonisolated static func scheduleOptionsJSON(_ options: MyScheduleOptions) -> [String: Any] {
        [
            "showOffice": options.showOffice,
            "showWorkingFromHome": options.showWorkingFromHome,
            "showSiteSurvey": options.showSiteSurvey,
            "customItems": options.customItems,
            "customItemEnabled": options.customItemEnabled,
        ]
    }

    /// `enabledScheduleLocations(options)`: `{ id, title, locationType, customLocationName? }` rows.
    nonisolated static func enabledScheduleLocations(_ options: MyScheduleOptions) -> [[String: Any]]? {
        callJSON("enabledScheduleLocations", arguments: [scheduleOptionsJSON(options)]) as? [[String: Any]]
    }

    /// `scheduleOptionsWriteFields(options)`: the `settings.myScheduleOptions` map to write.
    nonisolated static func scheduleOptionsWriteFields(_ options: MyScheduleOptions) -> [String: Any]? {
        callJSON("scheduleOptionsWriteFields", arguments: [scheduleOptionsJSON(options)]) as? [String: Any]
    }
}

// MARK: - Launch countries (RULEBOOK 1.13.0 §4.1, owner decision Q6)

/// One `launchCountryOptions` row.
nonisolated struct RulebookCountryOption: Hashable, Sendable {
    var code: String
    var title: String
}

extension CanonicalBusinessEngine {
    /// `launchCountryOptions(storedCountryCode)`: `LAUNCH_COUNTRY_CODES` (GB, IE), plus a stored other country so it
    /// is kept and shown. Nil when the script did not answer.
    nonisolated static func launchCountryOptions(storedCountryCode: String?) -> [RulebookCountryOption]? {
        guard let rows = callJSON("launchCountryOptions", arguments: [storedCountryCode ?? NSNull()]) as? [[String: Any]] else {
            return nil
        }
        return rows.compactMap { row in
            guard let code = row["code"] as? String else { return nil }
            return RulebookCountryOption(code: code, title: row["title"] as? String ?? code)
        }
    }
}
