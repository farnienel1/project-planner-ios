//
//  Rulebook+WeeklyReport.swift
//  Project Planner
//
//  RULEBOOK 1.51.0 §7 (owner decisions 15 Nov, Q1–Q4; web `lib/canonical/weeklyReportPay.ts`): the weekly report's Pay
//  Summary (`weeklyReportPayRows` — rows per person, rate period and kind of hours, each person's total and invoice
//  check line, the grand total with `reportPayForViewer` inside, and every booking's paid hours and days), the Annual
//  Leave rows (`weeklyReportLeaveRows`), a clash row's Detail (`weeklyReportClashDetail`), a sub contractor's day value
//  (`subcontractorDayValue` with the hours worked), and §4.3 Working hours history (`payrollPolicyHistoryRows`). Every
//  answer comes from the packed script through `CanonicalBusinessEngine.callJSON`; Swift only renders it.
//

import Foundation

/// One Pay Summary row (`WeeklyReportPayRow`).
nonisolated struct RulebookWeeklyReportPayRow: Hashable, Sendable {
    let kind: String
    let dates: String
    let line: String
    let hours: Double
    let days: Double
    /// 1.53.0: the unrounded days (`daysExact`), for `weeklyReportDaysText`.
    var daysExact: Double? = nil
    let rateText: String
    let pay: Double
    /// `PAY_HIDDEN_CELL_LABEL` ("—") when the viewer may not see this person's pay.
    let payLabel: String?
    /// `live`, `signed` or `claim` (price work / expenses: no hours or days).
    let source: String
}

/// A person's invoice check line (`WeeklyReportCheckLine`).
nonisolated struct RulebookWeeklyReportCheckLine: Hashable, Sendable {
    let label: String
    /// `good`, `warn` (amber) or `neutral`.
    let tone: String
}

/// One person of the Pay Summary (`WeeklyReportPayPersonRow`).
nonisolated struct RulebookWeeklyReportPayPerson: Hashable, Sendable {
    let personId: String
    let person: String
    let role: String
    let lines: [RulebookWeeklyReportPayRow]
    let personTotal: Double
    let personTotalLabel: String?
    let check: RulebookWeeklyReportCheckLine?
}

/// One booking's or signed line's paid hours and days (`WeeklyReportPaidDay`), for the Project Breakdown and Additional
/// Schedule (Q4a).
nonisolated struct RulebookWeeklyReportPaidDay: Hashable, Sendable {
    let personId: String?
    let bookingPersonId: String
    let dayKey: String
    let jobId: String?
    let jobNumber: String
    let jobName: String
    let locationKind: String
    let hours: Double
    let days: Double
    let source: String
    let bookingId: String
    let time: String
}

/// `weeklyReportPayRows(input)`.
nonisolated struct RulebookWeeklyReportPay: Hashable, Sendable {
    let people: [RulebookWeeklyReportPayPerson]
    let grandTotal: Double
    let hiddenPeople: Int
    let paidDays: [RulebookWeeklyReportPaidDay]
    let unmatchedBookingIds: [String]
}

/// One Annual Leave row (`WeeklyReportLeaveRow`).
nonisolated struct RulebookWeeklyReportLeaveRow: Hashable, Sendable {
    let personId: String?
    let person: String
    let role: String
    let days: Double
    let type: String
    let found: Bool
}

/// One Working hours history row (`PayrollPolicyHistoryRow`).
nonisolated struct RulebookPayrollPolicyHistoryRow: Hashable, Sendable, Identifiable {
    let effectiveFrom: String
    let dates: String
    let weekday: String
    let overtime: String
    let saturday: String
    let sunday: String
    let inEffectToday: Bool
    let scheduled: Bool

    var id: String { "\(effectiveFrom)|\(scheduled)" }
}

extension CanonicalBusinessEngine {
    nonisolated private static func wrNumber(_ value: Any?) -> Double {
        (value as? NSNumber)?.doubleValue ?? 0
    }

    nonisolated private static func wrText(_ value: Any?) -> String {
        value as? String ?? ""
    }

    // MARK: Pay Summary

    /// RULEBOOK 1.51.0 §7 `weeklyReportPayRows(input)`. `input` is the plain `WeeklyReportPayInput` (people, bookings,
    /// timesheetWeeks, sheets, roster, organization, payRateHistory, range, timeZone, viewer, currency). The app never
    /// passes `showAllPay`: with no viewer every figure is hidden. Nil when the script did not answer.
    nonisolated static func weeklyReportPayRows(_ input: [String: Any]) -> RulebookWeeklyReportPay? {
        var argument = input
        argument.removeValue(forKey: "showAllPay")
        guard let raw = callJSON("weeklyReportPayRows", arguments: [argument]) as? [String: Any],
              let people = raw["people"] as? [[String: Any]] else { return nil }
        return RulebookWeeklyReportPay(
            people: people.map { row in
                let check = row["check"] as? [String: Any]
                return RulebookWeeklyReportPayPerson(
                    personId: wrText(row["personId"]),
                    person: wrText(row["person"]),
                    role: wrText(row["role"]),
                    lines: (row["lines"] as? [[String: Any]] ?? []).map { line in
                        RulebookWeeklyReportPayRow(
                            kind: wrText(line["kind"]),
                            dates: wrText(line["dates"]),
                            line: wrText(line["line"]),
                            hours: wrNumber(line["hours"]),
                            days: wrNumber(line["days"]),
                            daysExact: (line["daysExact"] as? NSNumber)?.doubleValue,
                            rateText: wrText(line["rateText"]),
                            pay: wrNumber(line["pay"]),
                            payLabel: line["payLabel"] as? String,
                            source: wrText(line["source"])
                        )
                    },
                    personTotal: wrNumber(row["personTotal"]),
                    personTotalLabel: row["personTotalLabel"] as? String,
                    check: check.map { RulebookWeeklyReportCheckLine(label: wrText($0["label"]), tone: wrText($0["tone"])) }
                )
            },
            grandTotal: wrNumber(raw["grandTotal"]),
            hiddenPeople: Int(wrNumber(raw["hiddenPeople"])),
            paidDays: (raw["paidDays"] as? [[String: Any]] ?? []).map { row in
                RulebookWeeklyReportPaidDay(
                    personId: row["personId"] as? String,
                    bookingPersonId: wrText(row["bookingPersonId"]),
                    dayKey: wrText(row["dayKey"]),
                    jobId: row["jobId"] as? String,
                    jobNumber: wrText(row["jobNumber"]),
                    jobName: wrText(row["jobName"]),
                    locationKind: wrText(row["locationKind"]),
                    hours: wrNumber(row["hours"]),
                    days: wrNumber(row["days"]),
                    source: wrText(row["source"]),
                    bookingId: wrText(row["bookingId"]),
                    time: wrText(row["time"])
                )
            },
            unmatchedBookingIds: raw["unmatchedBookingIds"] as? [String] ?? []
        )
    }

    /// `WEEKLY_REPORT_PAY_COLUMNS` (Person | Role | Dates | Line | Hours | Days | Rate | Pay).
    nonisolated static var weeklyReportPayColumns: [String] {
        constant("WEEKLY_REPORT_PAY_COLUMNS", as: [String].self)
            ?? ["Person", "Role", "Dates", "Line", "Hours", "Days", "Rate", "Pay"]
    }

    /// `WEEKLY_REPORT_WARNING_OPEN` ("Open"): the one status word for every open warning on the weekly report.
    nonisolated static var weeklyReportWarningOpen: String {
        constant("WEEKLY_REPORT_WARNING_OPEN", as: String.self) ?? "Open"
    }

    /// RULEBOOK 1.51.0 §7 `weeklyReportDayText(dayKey)` ("14 Nov").
    nonisolated static func weeklyReportDayText(_ dayKey: String) -> String {
        callJSON("weeklyReportDayText", arguments: [dayKey]) as? String ?? dayKey
    }

    // MARK: Annual leave (Q4b)

    /// RULEBOOK 1.51.0 §7 `weeklyReportLeaveRows({ records, people, range, timeZone, nonWorkingDayKeys })`: approved
    /// leave in the range per person, matched under every id and email; nobody → "Person not found (id …)".
    /// 1.70.0: `formerPeople` (from `parseFormerPersonDocument`) names a deleted person's leave "Former: Jane Smith".
    nonisolated static func weeklyReportLeaveRows(
        records: [[String: Any]],
        people: [[String: Any]],
        startDayKey: String,
        endDayKey: String,
        nonWorkingDayKeys: [String],
        formerPeople: [[String: Any]] = [],
        timeZone: String = OrganizationRulebookContext.timeZoneIdentifier
    ) -> (rows: [RulebookWeeklyReportLeaveRow], total: Double)? {
        let input: [String: Any] = [
            "records": records,
            "people": people,
            "formerPeople": formerPeople,
            "range": ["start": startDayKey, "end": endDayKey],
            "timeZone": timeZone,
            "nonWorkingDayKeys": nonWorkingDayKeys,
        ]
        guard let raw = callJSON("weeklyReportLeaveRows", arguments: [input]) as? [String: Any],
              let rows = raw["rows"] as? [[String: Any]] else { return nil }
        return (
            rows.map { row in
                RulebookWeeklyReportLeaveRow(
                    personId: row["personId"] as? String,
                    person: wrText(row["person"]),
                    role: wrText(row["role"]),
                    days: wrNumber(row["days"]),
                    type: wrText(row["type"]),
                    found: row["found"] as? Bool ?? false
                )
            },
            wrNumber(raw["total"])
        )
    }

    /// RULEBOOK 1.59.0 §11 `parseFormerPersonDocument(docId, data)`: one `deletedPeople` record (`data` JSON-safe, an
    /// instant as epoch milliseconds). Nil when the record has no id or the script did not answer.
    nonisolated static func parseFormerPersonDocument(docId: String, data: [String: Any]) -> [String: Any]? {
        callJSON("parseFormerPersonDocument", arguments: [docId, data]) as? [String: Any]
    }

    /// RULEBOOK 1.59.0 §11 `formerPersonForId(personId, formerPeople)`: the former-person record (from
    /// `parseFormerPersonDocument`) whose id or `personIds` name `personId` (without case; the latest deleted wins). Nil
    /// when none does or the script did not answer.
    nonisolated static func formerPersonForId(_ personId: String, formerPeople: [[String: Any]]) -> [String: Any]? {
        guard !formerPeople.isEmpty else { return nil }
        return callJSON("formerPersonForId", arguments: [personId, formerPeople]) as? [String: Any]
    }

    /// RULEBOOK 1.59.0 §11 `formerPersonLabel(name)`: "Former: Jane Smith" ("Former: Deleted user" for an anonymised
    /// record). Nil when the script did not answer.
    nonisolated static func formerPersonLabel(_ name: String) -> String? {
        let text = callJSON("formerPersonLabel", arguments: [name]) as? String
        return text?.isEmpty == false ? text : nil
    }

    /// RULEBOOK 1.59.0 §11 `FORMER_PERSON_CHIP` ("Former person").
    nonisolated static var formerPersonChip: String {
        constant("FORMER_PERSON_CHIP", as: String.self) ?? "Former person"
    }

    // MARK: Warnings (Q4d)

    /// RULEBOOK 1.51.0 §7 `weeklyReportClashDetail({ dayText, places })`: "Booked in two places on 10 Nov 2026:
    /// 1 Carnaby Street 07:00–16:00; Office 09:00–17:00." Facts only, never an app instruction.
    nonisolated static func weeklyReportClashDetail(dayText: String, places: [(label: String, time: String)]) -> String? {
        let input: [String: Any] = [
            "dayText": dayText,
            "places": places.map { ["label": $0.label, "time": $0.time] },
        ]
        return callJSON("weeklyReportClashDetail", arguments: [input]) as? String
    }

    // MARK: Sub contractors (Q4c)

    /// RULEBOOK 1.51.0 §7 `subcontractorDayValue(timeSlot, { hours, standardDayHours })`: Full day 1, AM / PM 0.5, custom
    /// hours = hours worked ÷ the paid day (07:00–20:00 = 1.47). Nil when the script did not answer.
    nonisolated static func subcontractorDayValue(_ timeSlot: String, workedHours: Double?, standardDayHours: Double?) -> Double? {
        var options: [String: Any] = [:]
        if let workedHours { options["hours"] = ["workedHours": workedHours] }
        if let standardDayHours { options["standardDayHours"] = standardDayHours }
        return (callJSON("subcontractorDayValue", arguments: [timeSlot, options]) as? NSNumber)?.doubleValue
    }

    // MARK: Working hours history (§4.3)

    /// RULEBOOK 1.51.0 §4.3 `payrollPolicyHistoryRows({ state, todayKey })`: the read-only Working hours history, newest
    /// first. Empty when the script did not answer.
    nonisolated static func payrollPolicyHistoryRows(state: [String: Any], todayKey: String) -> [RulebookPayrollPolicyHistoryRow] {
        let input: [String: Any] = ["state": state, "todayKey": todayKey]
        guard let rows = callJSON("payrollPolicyHistoryRows", arguments: [input]) as? [[String: Any]] else { return [] }
        return rows.map { row in
            RulebookPayrollPolicyHistoryRow(
                effectiveFrom: wrText(row["effectiveFrom"]),
                dates: wrText(row["dates"]),
                weekday: wrText(row["weekday"]),
                overtime: wrText(row["overtime"]),
                saturday: wrText(row["saturday"]),
                sunday: wrText(row["sunday"]),
                inEffectToday: row["inEffectToday"] as? Bool ?? false,
                scheduled: row["scheduled"] as? Bool ?? false
            )
        }
    }

    // MARK: - 1.53.0

    /// `weeklyReportDaysText(days, kind)`: the Days cell (`WEEKLY_REPORT_DAYS_DISPLAY`).
    nonisolated static func weeklyReportDaysText(_ days: Double, kind: String) -> String {
        (callJSON("weeklyReportDaysText", arguments: [days.isFinite ? days : 0, kind]) as? String) ?? String(format: "%.2f", days)
    }

    /// `weeklyReportPaySummaryNote(rows)`: "Days are rounded; Pay is worked out from the exact hours." while any labour
    /// row is shown, '' otherwise.
    nonisolated static func weeklyReportPaySummaryNote(_ rows: [RulebookWeeklyReportPayRow]) -> String {
        let input = rows.map { ["source": $0.source] }
        return (callJSON("weeklyReportPaySummaryNote", arguments: [input]) as? String) ?? ""
    }

    /// `userLevelLabel(person)`: Admin / Manager / Operative, the Super Admin "Admin (Super Admin)".
    nonisolated static func userLevelLabel(_ person: [String: Any]) -> String? {
        callJSON("userLevelLabel", arguments: [person]) as? String
    }

    /// `bookingJobLabel(projectName)`: the live job name, or `ORPHAN_BOOKING_LABEL` ("Deleted job").
    nonisolated static func bookingJobLabel(_ projectName: String?) -> String {
        (callJSON("bookingJobLabel", arguments: [projectName.map { $0 as Any } ?? NSNull()]) as? String) ?? (projectName ?? "")
    }
}
