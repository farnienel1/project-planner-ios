//
//  Rulebook+PayrunSnapshot.swift
//  Project Planner
//
//  RULEBOOK 1.33.0 §7 (owner decision 6 Nov "Payrun Snapshot: build it"): typed wrappers for web
//  `lib/canonical/payrunSnapshot.ts`, called through `CanonicalBusinessEngine.callJSON`. The periods
//  (`payrunSnapshotPeriods`, `payrunSnapshotCustomPeriod`), the timesheet reader (`parsePayrunSnapshotSheet`) and every
//  row, label, tone and link (`payrunSnapshotRows`) come from the packed script; Swift only builds the inputs.
//

import Foundation

/// `PayrunSnapshotPeriod`: `kind` `paye` | `paymentRun` | `custom`, organisation-zone day keys, and its label.
nonisolated struct PayrunSnapshotPeriod: Codable, Hashable, Sendable {
    var kind: String
    var start: String
    var end: String
    var label: String
}

/// `payrunSnapshotPeriods`: the current PAYE payrun and payment run (nil with a message while not set up).
nonisolated struct PayrunSnapshotPeriods: Codable, Hashable, Sendable {
    var paye: PayrunSnapshotPeriod?
    var payeMessage: String?
    var paymentRun: PayrunSnapshotPeriod?
    var paymentRunMessage: String?

    static let none = PayrunSnapshotPeriods(paye: nil, payeMessage: nil, paymentRun: nil, paymentRunMessage: nil)
}

/// `PayrunSnapshotLink`: the page a cell opens (`timesheet` | `overtime` | `expenses` | `priceWork`) for one person and
/// range.
nonisolated struct PayrunSnapshotLink: Codable, Hashable, Sendable {
    var kind: String
    var personId: String
    var start: String
    var end: String
}

/// `PayrunSnapshotCell`: `tone` is `neutral` | `good` | `warn` | `blocked`; red (`blocked`) cells have no link.
nonisolated struct PayrunSnapshotCell: Codable, Hashable, Sendable {
    var state: String
    var label: String
    var tone: String
    var link: PayrunSnapshotLink?
}

/// `PayrunSnapshotRow`: one person.
nonisolated struct PayrunSnapshotRow: Codable, Hashable, Sendable, Identifiable {
    nonisolated struct Cells: Codable, Hashable, Sendable {
        var timesheet: PayrunSnapshotCell
        var overtime: PayrunSnapshotCell
        var expenses: PayrunSnapshotCell
        var priceWork: PayrunSnapshotCell
    }

    var personId: String
    var name: String
    var level: String
    var levelLabel: String
    var employment: String
    var employmentLabel: String
    var employmentNote: String
    var active: Bool
    var cells: Cells

    var id: String { personId }
}

/// Everything the Snapshot reads, loaded once (the period only filters it).
nonisolated struct PayrunSnapshotInputs: @unchecked Sendable {
    /// `parsePayrunSnapshotSheet` answers, as the script gave them.
    var sheets: [[String: Any]] = []
    var overtimeRequests: [OvertimeRequestRecord] = []
    var overtimeReviews: [OvertimeReviewRecord] = []
    var overtimeReports: [OvertimeReportRecord] = []
    var payeClaimReports: [PayeClaimReportRecord] = []
    var priceWork: [PayeClaimItem] = []
    var expenses: [PayeClaimItem] = []
}

extension CanonicalBusinessEngine {
    /// A string constant of `payrunSnapshot.ts` (`PAYRUN_SNAPSHOT_LABEL`, …), or `fallback`.
    nonisolated static func payrunSnapshotText(_ name: String, fallback: String) -> String {
        constant(name, as: String.self) ?? fallback
    }

    /// `PAYRUN_SNAPSHOT_PERIOD_LABELS` (`paye`, `paymentRun`, `custom`).
    nonisolated static var payrunSnapshotPeriodLabels: [String: String] {
        constant("PAYRUN_SNAPSHOT_PERIOD_LABELS", as: [String: String].self) ?? [:]
    }

    /// `PAYRUN_SNAPSHOT_COLUMNS`: Name, User level, Employment type, Timesheet, Overtime, Expenses, Price work.
    nonisolated static var payrunSnapshotColumns: [String] {
        constant("PAYRUN_SNAPSHOT_COLUMNS", as: [String].self) ?? []
    }

    /// `payrunSnapshotPeriods({ organization, todayKey, timeZone })`.
    nonisolated static func payrunSnapshotPeriods(organization: [String: Any], todayKey: String) -> PayrunSnapshotPeriods {
        let input: [String: Any] = ["organization": organization, "todayKey": todayKey, "timeZone": OrganizationRulebookContext.timeZoneIdentifier]
        return RulebookJSON.decode(PayrunSnapshotPeriods.self, from: callJSON("payrunSnapshotPeriods", arguments: [input])) ?? .none
    }

    /// `payrunSnapshotCustomPeriod(start, end)`: the two days in order, or nil.
    nonisolated static func payrunSnapshotCustomPeriod(start: String, end: String) -> PayrunSnapshotPeriod? {
        RulebookJSON.decode(PayrunSnapshotPeriod.self, from: callJSON("payrunSnapshotCustomPeriod", arguments: [start, end]))
    }

    /// `parsePayrunSnapshotSheet(docId, data, timeZone)`: a `settings/timesheet_*` document as the Snapshot reads it, or
    /// nil for anything else. `data` is Firestore values made JSON.
    nonisolated static func parsePayrunSnapshotSheet(docId: String, data: [String: Any]) -> [String: Any]? {
        callJSON("parsePayrunSnapshotSheet", arguments: [docId, data, OrganizationRulebookContext.timeZoneIdentifier]) as? [String: Any]
    }

    /// `payrunSnapshotRows(input)`: one row per person for `period`, sorted by name. `bookings` (every booking as overtime
    /// inputs), `overtimeReviews` and `operatives` let a saved overtime report's out-of-date check run, as web.
    nonisolated static func payrunSnapshotRows(
        roster: [[String: Any]],
        organization: [String: Any],
        period: PayrunSnapshotPeriod,
        inputs: PayrunSnapshotInputs,
        bookings: [OvertimeBookingInput],
        operatives: [[String: Any]]
    ) -> [PayrunSnapshotRow] {
        let input: [String: Any] = [
            "roster": roster,
            "organization": organization,
            "period": ["start": period.start, "end": period.end],
            "timeZone": OrganizationRulebookContext.timeZoneIdentifier,
            "sheets": inputs.sheets,
            "overtimeRequests": inputs.overtimeRequests.map(\.raw),
            "overtimeReviews": inputs.overtimeReviews.map(\.raw),
            "overtimeReports": inputs.overtimeReports.map(\.raw),
            "payeClaimReports": RulebookJSON.object(inputs.payeClaimReports) ?? [Any](),
            "priceWork": RulebookJSON.object(inputs.priceWork) ?? [Any](),
            "expenses": RulebookJSON.object(inputs.expenses) ?? [Any](),
            "bookings": bookings.map(\.json),
            "operatives": operatives,
        ]
        return RulebookJSON.decode([PayrunSnapshotRow].self, from: callJSON("payrunSnapshotRows", arguments: [input])) ?? []
    }
}

/// App rows → the Snapshot's inputs (no rule).
@MainActor
enum PayrunSnapshotPeople {
    /// `PayrunSnapshotPerson` (web `payrunSnapshotPerson`): the rulebook person plus the name and the effective-dated
    /// employment fields `weeklyReportPayeDay` reads.
    static func person(_ user: AppUser) -> [String: Any] {
        var row = RulebookPeople.person(user)
        row["firstName"] = user.firstName
        row["surname"] = user.surname
        for (key, value) in user.overtimeEmploymentPayload { row[key] = value }
        return row
    }

    static func roster(_ users: [AppUser]) -> [[String: Any]] {
        users.map { person($0) }
    }

    /// The organisation document the Snapshot reads: the PAYE payday fields and the payment-run settings under
    /// `invoicing`, plus the working hours (for the overtime reports' out-of-date check).
    static func organization(_ org: Organization?) -> [String: Any] {
        var doc = OvertimeOrganizationDocument.document(org)
        var invoicing = org.flatMap { CanonicalBusinessEngine.invoicingJSON($0.settings.invoicing) } ?? [:]
        for (key, value) in doc["invoicing"] as? [String: Any] ?? [:] { invoicing[key] = value }
        doc["invoicing"] = invoicing
        return doc
    }
}
