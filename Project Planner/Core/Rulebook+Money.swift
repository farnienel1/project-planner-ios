//
//  Rulebook+Money.swift
//  Project Planner
//
//  RULEBOOK 1.22.0 "Money" (§6–§9, §22; web `lib/canonical/timesheetTotals.ts`, `leaveReport.ts`,
//  `weeklyReportTimesheetFeed.ts`, `variationNumbers.ts`, `managerCoverage.ts`). Every figure here comes from the
//  packed script through `CanonicalBusinessEngine.callJSON` and is memoised by its exact input, so a list body never
//  runs the script twice for the same row. Swift only maps its models into the script's plain inputs and maps the
//  answer back.
//

import Foundation

// MARK: - Memo key (CanonicalBusinessEngine input)

extension CanonicalBusinessEngine {
    /// The exact JSON text of a `CanonicalBusinessEngine` input (sorted keys), used as a memo key. Nil when the value
    /// is not plain JSON (the call would fail anyway).
    nonisolated static func rulebookMemoKey(_ value: Any) -> String? {
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    nonisolated fileprivate static func number(_ value: Any?) -> Double {
        (value as? NSNumber)?.doubleValue ?? 0
    }
}

// MARK: - Timesheet totals (§8, `timesheetTotals`)

/// `timesheetTotals(input)`: the totals of one sheet. The money is the sum of its invoice rows
/// (`timesheetInvoiceRows`), so `total` is the invoice total for the same inputs.
nonisolated struct RulebookTimesheetTotals: Hashable, Sendable {
    /// Weighted paid hours (overtime at its multiplier): the figure the list shows as Hours.
    let hours: Double
    let standardHours: Double
    /// Overtime clock hours.
    let overtimeHours: Double
    let labour: Double
    let standardLabour: Double
    let overtimeLabour: Double
    let priceWork: Double
    let expenses: Double
    let extras: Double
    let total: Double
    let submittedPriceWork: Double
    let submittedExpenses: Double
    let submittedExtras: Double
    let pendingEntries: Int
    /// `override` when the signed snapshot produced the money, else `live`.
    let source: String
    let invoiceRowCount: Int

    init?(json: Any?) {
        guard let row = json as? [String: Any], row["total"] is NSNumber else { return nil }
        func n(_ key: String) -> Double { CanonicalBusinessEngine.number(row[key]) }
        hours = n("hours")
        standardHours = n("standardHours")
        overtimeHours = n("overtimeHours")
        labour = n("labour")
        standardLabour = n("standardLabour")
        overtimeLabour = n("overtimeLabour")
        priceWork = n("priceWork")
        expenses = n("expenses")
        extras = n("extras")
        total = n("total")
        submittedPriceWork = n("submittedPriceWork")
        submittedExpenses = n("submittedExpenses")
        submittedExtras = n("submittedExtras")
        pendingEntries = Int(n("pendingEntries"))
        source = row["source"] as? String ?? "live"
        invoiceRowCount = Int(n("invoiceRowCount"))
    }
}

extension CanonicalBusinessEngine {
    nonisolated private static let timesheetTotalsMemo = RulebookAnswerMemo<String, RulebookTimesheetTotals>(limit: 1024)

    /// RULEBOOK 1.22.0 `timesheetTotals({ sheet, payrollLines, extrasMode, timesheetDays?, timeZone?,
    /// applyLabourReviews? })` — the same input as `timesheetInvoiceRows`. Memoised by the exact input. Nil when the
    /// script did not answer (screens then show no figure rather than a Swift sum).
    nonisolated static func timesheetTotals(_ input: [String: Any]) -> RulebookTimesheetTotals? {
        guard let key = rulebookMemoKey(input) else { return nil }
        return timesheetTotalsMemo.value(for: key) {
            RulebookTimesheetTotals(json: callJSON("timesheetTotals", arguments: [input]))
        }
    }

    /// `timesheetEntryReviewWriteFields` then `timesheetEntryReviewsAfterWrite`: the review map a reviewer's screen
    /// will hold once their on-screen decisions are saved (web `timesheetSheetFields({ reviewerPreview })`).
    nonisolated static func timesheetEntryReviewsPreview(stored: Any, entries: [[String: Any]]) -> Any? {
        let input: [String: Any] = ["stored": stored, "entries": entries, "reviewedByUserId": "", "reviewedAtMs": 0]
        guard let written = callJSON("timesheetEntryReviewWriteFields", arguments: [input]) as? [String: Any] else { return nil }
        return callJSON("timesheetEntryReviewsAfterWrite", arguments: [stored, written])
    }
}

extension TimesheetPayrollLineItem {
    /// This line as a `TimesheetTotalsLine` / `InvoiceLineInput` (CanonicalBusinessEngine `timesheetTotals`,
    /// `timesheetInvoiceRows`): id, amount, PAYE flag, organisation-zone day, hours and the booking's figures.
    var rulebookTotalsJSON: [String: Any] {
        var row: [String: Any] = [
            "id": id,
            "amount": amount,
            "isPayeDay": isPayeDay,
            "dayKey": OrganizationRulebookContext.dayKey(date),
            "paidHours": paidHours,
            "isOvertimeLine": isOvertimeLine,
        ]
        if let otMultiplier { row["otMultiplier"] = otMultiplier }
        if let otClockHours { row["otClockHours"] = otClockHours }
        if let bookingPaidHours { row["bookingPaidHours"] = bookingPaidHours }
        if let bookingOvertimeHours { row["bookingOvertimeHours"] = bookingOvertimeHours }
        return row
    }
}

/// The sheet and lines one timesheet screen passes to CanonicalBusinessEngine `timesheetTotals` (web
/// `draftTimesheetTotals`). `decided`: review decisions apply here (the line manager has signed, the viewer is
/// reviewing it, or this is a list row / export). `reviewing`: a reviewer before they sign — their labour reviews and
/// their on-screen entry decisions apply.
enum TimesheetTotalsSource {
    static func sheetJSON(_ draft: TimesheetDraft, reviewing: Bool) -> [String: Any] {
        var sheet = FirebaseBackend.firestoreJSON(TimesheetDraftStore.asFirestoreMap(draft)) as? [String: Any] ?? [:]
        if reviewing {
            func entry(storedId: String?, id: UUID, amount: Double, decision: TimesheetManagerDecision, revised: Double?, fingerprint: String?) -> [String: Any] {
                var row: [String: Any] = [
                    "id": storedId ?? WorkDocumentKeys.storedId(for: id),
                    "amount": amount,
                    "managerDecision": decision.rawValue,
                    "managerRevisedAmount": revised.map { $0 as Any } ?? NSNull(),
                ]
                // RULEBOOK 1.45.0 §8: the stored row's fingerprint, so the previewed review carries it.
                if let fingerprint, !fingerprint.isEmpty { row["reviewFingerprint"] = fingerprint }
                return row
            }
            let entries: [[String: Any]] =
                draft.priceWorkEntries.map {
                    entry(storedId: $0.storedId, id: $0.id, amount: $0.amount, decision: $0.managerDecision, revised: $0.managerRevisedAmount, fingerprint: $0.reviewFingerprint)
                } + draft.expenseEntries.map {
                    entry(storedId: $0.storedId, id: $0.id, amount: $0.amount, decision: $0.managerDecision, revised: $0.managerRevisedAmount, fingerprint: $0.reviewFingerprint)
                }
            if let reviews = CanonicalBusinessEngine.timesheetEntryReviewsPreview(stored: NSNull(), entries: entries),
               !(reviews is NSNull) {
                sheet["extraEntryReviews"] = reviews
            }
        }
        return sheet
    }

    /// RULEBOOK 1.11.0 §8 `CanonicalBusinessEngine.timesheetDaysForPerson(user, period, timeZone)`: the organisation-zone
    /// days of the period on which the person is self-employed (web `timesheetDayKeysForPeriod`), passed as
    /// `timesheetDays` so totals and invoices leave out a PAYE day's rows. Memoised by person and period.
    static func timesheetDays(for user: AppUser, period: ClosedRange<Date>) -> [String]? {
        let person = CanonicalBusinessEngine.timesheetPerson(user)
        let start = OrganizationRulebookContext.dayKey(period.lowerBound)
        let end = OrganizationRulebookContext.dayKey(period.upperBound)
        let zone = OrganizationRulebookContext.timeZoneIdentifier
        guard let key = CanonicalBusinessEngine.rulebookMemoKey([person, start, end, zone] as [Any]) else { return nil }
        return daysMemo.value(for: key) {
            CanonicalBusinessEngine.timesheetDaysForPerson(person: person, startDayKey: start, endDayKey: end, timeZone: zone)
        }
    }

    private static let daysMemo = RulebookAnswerMemo<String, [String]>(limit: 256)

    static func totals(
        lines: [TimesheetPayrollLineItem],
        draft: TimesheetDraft,
        decided: Bool,
        reviewing: Bool = false,
        subject: AppUser? = nil,
        period: ClosedRange<Date>? = nil
    ) -> RulebookTimesheetTotals? {
        var input: [String: Any] = [
            "sheet": sheetJSON(draft, reviewing: reviewing),
            "payrollLines": lines.map(\.rulebookTotalsJSON),
            "extrasMode": decided ? "decided" : "raw",
            "timeZone": OrganizationRulebookContext.timeZoneIdentifier,
        ]
        input["applyLabourReviews"] = reviewing ? (true as Any) : (NSNull() as Any)
        // RULEBOOK 1.45.0 §8: the loaded copy's stored-row fingerprints, handed over explicitly (`entryFingerprints`).
        let fingerprints = TimesheetDraftStore.entryFingerprints(draft)
        if !fingerprints.isEmpty { input["entryFingerprints"] = fingerprints }
        if let subject, let period, let days = timesheetDays(for: subject, period: period) {
            input["timesheetDays"] = days
        }
        return CanonicalBusinessEngine.timesheetTotals(input)
    }
}

// MARK: - Holiday Report (§9, `leaveReportRows` / `leaveReportYears`)

nonisolated struct RulebookLeaveReportRow: Hashable, Sendable {
    let id: String
    let startDayKey: String
    let endDayKey: String
    let timeSlot: String
    let status: String
    /// Days this record takes inside the leave year (0.5 steps).
    let days: Double
}

nonisolated struct RulebookLeaveYear: Hashable, Sendable {
    let startDayKey: String
    let endDayKey: String
    let yearKey: String
}

nonisolated struct RulebookLeaveReport: Hashable, Sendable {
    let year: RulebookLeaveYear
    let rows: [RulebookLeaveReportRow]
    let totalDays: Double
}

/// One `holidayBookings` record as `leaveReportRows` reads it (`parseHolidayDocument` fields).
nonisolated struct RulebookLeaveReportRecord: Hashable, Sendable {
    var id: String
    var userId: String?
    var operativeId: String?
    var startDayKey: String
    var endDayKey: String
    var timeSlot: String
    var status: String

    var json: [String: Any] {
        [
            "id": id, "userId": userId.map { $0 as Any } ?? NSNull(), "operativeId": operativeId.map { $0 as Any } ?? NSNull(),
            "startDayKey": startDayKey, "endDayKey": endDayKey, "timeSlot": timeSlot, "status": status,
        ]
    }
}

extension CanonicalBusinessEngine {
    nonisolated private static let leaveReportMemo = RulebookAnswerMemo<String, RulebookLeaveReport>(limit: 128)
    nonisolated private static let leaveYearsMemo = RulebookAnswerMemo<String, [RulebookLeaveYear]>(limit: 128)

    nonisolated private static func leaveYear(_ value: Any?) -> RulebookLeaveYear? {
        guard let row = value as? [String: Any], let start = row["startDayKey"] as? String,
              let end = row["endDayKey"] as? String else { return nil }
        return RulebookLeaveYear(startDayKey: start, endDayKey: end, yearKey: row["yearKey"] as? String ?? start)
    }

    /// RULEBOOK 1.22.0 `leaveReportRows({ records, personIds, onDayKey, startMonth, timeZone, nonWorkingDayKeys,
    /// statuses })`: one person's leave in one leave year — weekends and bank holidays out of multi-day records, half
    /// days 0.5, ids without case — the rule `annualLeaveBalance` counts with. Nil when the script did not answer.
    nonisolated static func leaveReportRows(
        records: [RulebookLeaveReportRecord],
        personIds: [String],
        onDayKey: String,
        startMonth: Int?,
        timeZone: String = OrganizationRulebookContext.timeZoneIdentifier,
        nonWorkingDayKeys: [String],
        statuses: [String]? = nil
    ) -> RulebookLeaveReport? {
        var input: [String: Any] = [
            "records": records.map(\.json),
            "personIds": personIds,
            "onDayKey": onDayKey,
            "startMonth": startMonth.map { $0 as Any } ?? NSNull(),
            "timeZone": timeZone,
            "nonWorkingDayKeys": nonWorkingDayKeys,
        ]
        if let statuses { input["statuses"] = statuses }
        guard let key = rulebookMemoKey(input) else { return nil }
        return leaveReportMemo.value(for: key) {
            guard let row = callJSON("leaveReportRows", arguments: [input]) as? [String: Any],
                  let year = leaveYear(row) else { return nil }
            let rows: [RulebookLeaveReportRow] = (row["rows"] as? [[String: Any]] ?? []).map {
                RulebookLeaveReportRow(
                    id: $0["id"] as? String ?? "",
                    startDayKey: $0["startDayKey"] as? String ?? "",
                    endDayKey: $0["endDayKey"] as? String ?? "",
                    timeSlot: $0["timeSlot"] as? String ?? "",
                    status: $0["status"] as? String ?? "",
                    days: number($0["days"])
                )
            }
            return RulebookLeaveReport(year: year, rows: rows, totalDays: number(row["totalDays"]))
        }
    }

    /// RULEBOOK 1.22.0 `leaveReportYears({ firstDayKey, todayDayKey, startMonth })`: the leave years a Holiday Report
    /// offers, newest first. Nil when the script did not answer.
    nonisolated static func leaveReportYears(firstDayKey: String?, todayDayKey: String, startMonth: Int?) -> [RulebookLeaveYear]? {
        let input: [String: Any] = [
            "firstDayKey": firstDayKey.map { $0 as Any } ?? NSNull(),
            "todayDayKey": todayDayKey,
            "startMonth": startMonth.map { $0 as Any } ?? NSNull(),
        ]
        guard let key = rulebookMemoKey(input) else { return nil }
        return leaveYearsMemo.value(for: key) {
            (callJSON("leaveReportYears", arguments: [input]) as? [Any])?.compactMap(leaveYear)
        }
    }

    /// RULEBOOK 1.22.0 `leaveReportDayCount(record, range, timeZone, nonWorkingDayKeys)`. Nil when the script did not
    /// answer.
    nonisolated static func leaveReportDayCount(
        startDayKey: String,
        endDayKey: String,
        timeSlot: String,
        range: RulebookLeaveYear,
        timeZone: String = OrganizationRulebookContext.timeZoneIdentifier,
        nonWorkingDayKeys: [String] = []
    ) -> Double? {
        let record: [String: Any] = ["startDayKey": startDayKey, "endDayKey": endDayKey, "timeSlot": timeSlot]
        let span: [String: Any] = ["startDayKey": range.startDayKey, "endDayKey": range.endDayKey]
        return (callJSON("leaveReportDayCount", arguments: [record, span, timeZone, nonWorkingDayKeys]) as? NSNumber)?.doubleValue
    }
}

// MARK: - Variation numbers (§22, `variationNumbers.ts`)

extension CanonicalBusinessEngine {
    nonisolated private static let variationNumberMemo = RulebookAnswerMemo<String, String>(limit: 256)

    /// RULEBOOK 1.22.0 `variationNumberValue(voNumber)`: the trailing digits only ("V2-003" → 3). Nil when the script
    /// did not answer.
    nonisolated static func variationNumberValue(_ voNumber: String) -> Int? {
        (callJSON("variationNumberValue", arguments: [voNumber]) as? NSNumber)?.intValue
    }

    /// RULEBOOK 1.22.0 `formatVariationNumber(sequence, prefix, padding)`.
    nonisolated static func formatVariationNumber(_ sequence: Int, prefix: String, padding: Int) -> String? {
        callJSON("formatVariationNumber", arguments: [sequence, prefix, padding]) as? String
    }

    /// RULEBOOK 1.22.0 `nextVariationNumber(existingNumbers, prefix, padding)`: highest trailing number + 1. Deleted
    /// and closed numbers are passed too, so they are never reused. Nil when the script did not answer.
    nonisolated static func nextVariationNumber(existingNumbers: [String], prefix: String, padding: Int) -> String? {
        let arguments: [Any] = [existingNumbers, prefix, padding]
        guard let key = rulebookMemoKey(arguments) else { return nil }
        return variationNumberMemo.value(for: key) {
            callJSON("nextVariationNumber", arguments: arguments) as? String
        }
    }

    /// RULEBOOK 1.22.0 `variationNumberTaken(existing, voNumber, exceptId)`: a deleted variation still holds its
    /// number; ids and numbers compare without case. Nil when the script did not answer.
    nonisolated static func variationNumberTaken(
        existing: [(id: String, voNumber: String, isDeleted: Bool)],
        voNumber: String,
        exceptId: String?
    ) -> Bool? {
        let rows: [[String: Any]] = existing.map { ["id": $0.id, "voNumber": $0.voNumber, "isDeleted": $0.isDeleted] }
        return (callJSON("variationNumberTaken", arguments: [rows, voNumber, exceptId.map { $0 as Any } ?? NSNull()]) as? NSNumber)?.boolValue
    }
}

// MARK: - Booked cover for one person and day (§6, `managerCoverageHours`)

nonisolated struct RulebookCoverageBooking: Hashable, Sendable {
    var timeSlot: String
    var workStartTime: String?
    var workEndTime: String?
    var isBreakRemoved: Bool

    var json: [String: Any] {
        [
            "timeSlot": timeSlot,
            "workStartTime": workStartTime.map { $0 as Any } ?? NSNull(),
            "workEndTime": workEndTime.map { $0 as Any } ?? NSNull(),
            "isBreakRemoved": isBreakRemoved,
        ]
    }
}

nonisolated struct RulebookManagerCoverage: Hashable, Sendable {
    /// The weekday paid day (`weekdayPaidHours`).
    let paidDayHours: Double
    /// Hours worked across the merged bookings, the unpaid break taken off once by the pay rule.
    let paidHours: Double
    let requiredHours: Double
    let coveredHours: Double
    let missingHours: Double
    /// `standardDayCoverage`: every minute of the standard day (lunch window excepted) is booked.
    let covered: Bool
}

extension CanonicalBusinessEngine {
    nonisolated private struct CoverageKey: Hashable, Sendable {
        let bookings: [RulebookCoverageBooking]
        let dayKey: String
        let policy: OrgPayrollTimePolicy
        let timeZone: String
    }

    nonisolated private static let coverageMemo = RulebookAnswerMemo<CoverageKey, RulebookManagerCoverage>(limit: 2048)

    /// RULEBOOK 1.22.0 `managerCoverageHours({ bookings, dayKey, policy, timeZone })`: a person's booked cover on one
    /// day (every labour and manager site booking they have that day). `covered` is `standardDayCoverage`, the Daily
    /// Overview rule. Nil when the script did not answer.
    nonisolated static func managerCoverageHours(
        bookings: [RulebookCoverageBooking],
        dayKey: String,
        policy: OrgPayrollTimePolicy,
        timeZone: String = OrganizationRulebookContext.timeZoneIdentifier
    ) -> RulebookManagerCoverage? {
        coverageMemo.value(for: CoverageKey(bookings: bookings, dayKey: dayKey, policy: policy, timeZone: timeZone)) {
            guard let policyJSON = payrollPolicyJSON(policy) else { return nil }
            let input: [String: Any] = [
                "bookings": bookings.map(\.json), "dayKey": dayKey, "policy": policyJSON, "timeZone": timeZone,
            ]
            guard let row = callJSON("managerCoverageHours", arguments: [input]) as? [String: Any],
                  let covered = row["covered"] as? Bool else { return nil }
            return RulebookManagerCoverage(
                paidDayHours: number(row["paidDayHours"]),
                paidHours: number(row["paidHours"]),
                requiredHours: number(row["requiredHours"]),
                coveredHours: number(row["coveredHours"]),
                missingHours: number(row["missingHours"]),
                covered: covered
            )
        }
    }
}

extension Booking {
    /// This booking as a `CoverageBooking` (CanonicalBusinessEngine `managerCoverageHours`).
    var rulebookCoverageBooking: RulebookCoverageBooking {
        RulebookCoverageBooking(timeSlot: timeSlot.rawValue, workStartTime: workStartTime, workEndTime: workEndTime, isBreakRemoved: isBreakRemoved)
    }
}

extension ManagerSiteBooking {
    /// This booking as a `CoverageBooking` (CanonicalBusinessEngine `managerCoverageHours`).
    var rulebookCoverageBooking: RulebookCoverageBooking {
        RulebookCoverageBooking(timeSlot: timeSlot.rawValue, workStartTime: workStartTime, workEndTime: workEndTime, isBreakRemoved: isBreakRemoved)
    }
}

// MARK: - Weekly Report approved-timesheet feed (§7, `weeklyReportTimesheetFeed.ts`)

extension CanonicalBusinessEngine {
    /// RULEBOOK 1.22.0 `mergeTimesheetFeedWeeks(weeks, people, timeZone)`: one approved week per person and week start
    /// (input order decides the primary week). Nil when the script did not answer.
    nonisolated static func mergeTimesheetFeedWeeks(weeks: [[String: Any]], people: [[String: Any]], timeZone: String) -> [[String: Any]]? {
        callJSON("mergeTimesheetFeedWeeks", arguments: [weeks, people, timeZone]) as? [[String: Any]]
    }

    /// RULEBOOK 1.22.0 `timesheetFeedCovers(weeks, userIds, day, timeZone)`. Nil when the script did not answer.
    nonisolated static func timesheetFeedCovers(weeks: [[String: Any]], userIds: [String], dayKey: String, timeZone: String) -> Bool? {
        (callJSON("timesheetFeedCovers", arguments: [weeks, userIds, dayKey, timeZone]) as? NSNumber)?.boolValue
    }

    /// RULEBOOK 1.22.0 `timesheetFeedLabourLines(weeks, range, timeZone)` → `[{ weekIndex, line }]`.
    nonisolated static func timesheetFeedLabourLines(weeks: [[String: Any]], startDayKey: String, endDayKey: String, timeZone: String) -> [[String: Any]]? {
        callJSON("timesheetFeedLabourLines", arguments: [weeks, ["start": startDayKey, "end": endDayKey], timeZone]) as? [[String: Any]]
    }

    /// RULEBOOK 1.22.0 `timesheetFeedMoneyLines(weeks, kind, range, timeZone)` → `[{ weekIndex, line }]`.
    nonisolated static func timesheetFeedMoneyLines(weeks: [[String: Any]], kind: String, startDayKey: String, endDayKey: String, timeZone: String) -> [[String: Any]]? {
        callJSON("timesheetFeedMoneyLines", arguments: [weeks, kind, ["start": startDayKey, "end": endDayKey], timeZone]) as? [[String: Any]]
    }
}
