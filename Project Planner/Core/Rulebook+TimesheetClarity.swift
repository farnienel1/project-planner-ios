//
//  Rulebook+TimesheetClarity.swift
//  Project Planner
//
//  RULEBOOK 1.77.0 §8 (owner decisions 23 Nov, points 1, 2, 3, 5; web `lib/canonical/timesheetClarity.ts`). What a
//  timesheet says about itself: the "whose turn" line (`timesheetNextStep`), the "Changed since you signed" card
//  (`signedTimesheetChangeDetails`) and the one "Correct this timesheet" entry (`timesheetCorrectionOption`). Swift only
//  builds the script's inputs and reads its answers — no comparison, wording or decision lives here (AGENTS.md Rule 0).
//

import Foundation

/// `timesheetNextStep` → one line at the top of the timesheet.
nonisolated struct RulebookTimesheetNextStep: Equatable, Sendable {
    /// `person` | `lineManager` | `admin` | `nobody`.
    let whoseTurn: String
    let viewerActs: Bool
    let text: String
    /// `action` | `waiting` | `done`.
    let tone: String
    /// Point 5: the person's signed-off sheet — show Generate Invoice beside the line.
    let generateInvoice: Bool

    init?(json: Any?) {
        guard let row = json as? [String: Any], let text = row["text"] as? String, !text.isEmpty else { return nil }
        self.whoseTurn = row["whoseTurn"] as? String ?? "nobody"
        self.viewerActs = row["viewerActs"] as? Bool ?? false
        self.text = text
        self.tone = row["tone"] as? String ?? "waiting"
        self.generateInvoice = row["generateInvoice"] as? Bool ?? false
    }
}

/// One row of `signedTimesheetChangeDetails(...).rows`.
nonisolated struct RulebookTimesheetChangeRow: Identifiable, Equatable, Sendable {
    let id: String
    /// `booking` | `entry`.
    let type: String
    /// `added` | `removed` | `changed`.
    let kind: String
    let chipLabel: String
    /// `green` | `red` | `amber`.
    let tone: String
    let dayLabel: String
    let title: String
    let beforeText: String?
    let afterText: String?
    let accessibilityLabel: String

    init?(json: Any?) {
        guard let row = json as? [String: Any], let key = row["key"] as? String else { return nil }
        self.id = key
        self.type = row["type"] as? String ?? "booking"
        self.kind = row["kind"] as? String ?? "changed"
        self.chipLabel = row["chipLabel"] as? String ?? ""
        self.tone = row["tone"] as? String ?? "amber"
        self.dayLabel = row["dayLabel"] as? String ?? ""
        self.title = row["title"] as? String ?? ""
        self.beforeText = row["beforeText"] as? String
        self.afterText = row["afterText"] as? String
        self.accessibilityLabel = row["accessibilityLabel"] as? String ?? ""
    }
}

/// `signedTimesheetChangeDetails` → the "Changed since you signed" card.
nonisolated struct RulebookTimesheetChangeDetails: Equatable, Sendable {
    let rows: [RulebookTimesheetChangeRow]
    let bookingRows: Int
    let firstDayLabel: String
    let heading: String
    let summary: String
    let collapsedCount: Int
    let showAllLabel: String?

    static let empty = RulebookTimesheetChangeDetails(
        rows: [], bookingRows: 0, firstDayLabel: "", heading: "", summary: "", collapsedCount: 0, showAllLabel: nil
    )

    init(rows: [RulebookTimesheetChangeRow], bookingRows: Int, firstDayLabel: String, heading: String, summary: String, collapsedCount: Int, showAllLabel: String?) {
        self.rows = rows
        self.bookingRows = bookingRows
        self.firstDayLabel = firstDayLabel
        self.heading = heading
        self.summary = summary
        self.collapsedCount = collapsedCount
        self.showAllLabel = showAllLabel
    }

    init?(json: Any?) {
        guard let row = json as? [String: Any], let rows = row["rows"] as? [Any] else { return nil }
        self.rows = rows.compactMap(RulebookTimesheetChangeRow.init(json:))
        self.bookingRows = (row["bookingRows"] as? NSNumber)?.intValue ?? 0
        self.firstDayLabel = row["firstDayLabel"] as? String ?? ""
        self.heading = row["heading"] as? String ?? ""
        self.summary = row["summary"] as? String ?? ""
        self.collapsedCount = (row["collapsedCount"] as? NSNumber)?.intValue ?? 3
        self.showAllLabel = row["showAllLabel"] as? String
    }
}

/// `timesheetCorrectionOption` → the one "Correct this timesheet" entry.
nonisolated struct RulebookTimesheetCorrectionOption: Equatable, Sendable {
    /// `makeChanges` | `createRevision` | `addLateExtras` | `reviewAndSignAgain` | `askLineManager`; nil = no entry.
    let action: String?
    let label: String
    let help: String?
    let hasButton: Bool

    static let none = RulebookTimesheetCorrectionOption(action: nil, label: "Correct this timesheet", help: nil, hasButton: false)

    init(action: String?, label: String, help: String?, hasButton: Bool) {
        self.action = action
        self.label = label
        self.help = help
        self.hasButton = hasButton
    }

    init?(json: Any?) {
        guard let row = json as? [String: Any] else { return nil }
        self.action = row["action"] as? String
        self.label = row["label"] as? String ?? "Correct this timesheet"
        self.help = row["help"] as? String
        self.hasButton = row["hasButton"] as? Bool ?? false
    }
}

extension CanonicalBusinessEngine {
    /// `TIMESHEET_GENERATE_INVOICE_PROMPT` ("Next: generate your invoice").
    nonisolated static var timesheetGenerateInvoicePrompt: String {
        constant("TIMESHEET_GENERATE_INVOICE_PROMPT", as: String.self) ?? "Next: generate your invoice"
    }

    /// RULEBOOK 1.77.0 `timesheetNextStep(input)`. `sheet` is the status payload (signatures, `exportedAt`,
    /// `invoiceGeneratedAt`); `change` the folded change's `scriptJSON`. Nil when the script did not answer (no line).
    nonisolated static func timesheetNextStep(
        sheet: [String: Any],
        viewerRole: String,
        selfSigned: Bool,
        change: [String: Any]?,
        revisionDue: Bool,
        revisionDueLabel: String?,
        revisionLabel: String?,
        personName: String?,
        lineManagerName: String?,
        changedDayLabel: String?,
        changedBookingCount: Int,
        hasInvoiceDays: Bool,
        hasLineManager: Bool = true
    ) -> RulebookTimesheetNextStep? {
        let input: [String: Any] = [
            "sheet": sheet,
            "viewerRole": viewerRole,
            "selfSigned": selfSigned,
            "change": change.map { $0 as Any } ?? NSNull(),
            "revision": ["due": revisionDue, "label": RulebookJSON.orNull(revisionDueLabel)] as [String: Any],
            "revisionLabel": RulebookJSON.orNull(revisionLabel),
            "personName": RulebookJSON.orNull(personName),
            "lineManagerName": RulebookJSON.orNull(lineManagerName),
            "changedDayLabel": RulebookJSON.orNull(changedDayLabel),
            "changedBookingCount": changedBookingCount,
            "hasInvoiceDays": hasInvoiceDays,
            // Review of 1.77.0 (fix 4): no active line manager reads "Waiting for an admin to sign off".
            "hasLineManager": hasLineManager,
        ]
        return RulebookTimesheetNextStep(json: callJSON("timesheetNextStep", arguments: [input]))
    }

    /// RULEBOOK 1.77.0 `signedTimesheetChangeDetails(input)`: the same inputs as `signedTimesheetBookingChanges`, plus the
    /// jobs, the entry options and the currency. Empty when the script did not answer.
    nonisolated static func signedTimesheetChangeDetails(
        sheet: [String: Any],
        liveLines: [[String: Any]],
        liveBookings: [[String: Any]]?,
        personIds: [String]?,
        liveLoaded: Bool,
        selfSigned: Bool,
        jobs: [[String: Any]],
        timeZone: String,
        entryFingerprints: [String: Any],
        exportedAtStored: Bool,
        currency: String,
        viewerIsReviewer: Bool
    ) -> RulebookTimesheetChangeDetails {
        var input: [String: Any] = [
            "sheet": sheet,
            "liveLines": liveLines,
            "liveLoaded": liveLoaded,
            "selfSigned": selfSigned,
            "jobs": jobs,
            "timeZone": timeZone,
            "entryOptions": ["entryFingerprints": entryFingerprints, "exportedAtStored": exportedAtStored] as [String: Any],
            "currency": currency,
            "viewerIsReviewer": viewerIsReviewer,
        ]
        input["liveBookings"] = liveBookings.map { $0 as Any } ?? NSNull()
        input["personIds"] = personIds.map { $0 as Any } ?? NSNull()
        return RulebookTimesheetChangeDetails(json: callJSON("signedTimesheetChangeDetails", arguments: [input])) ?? .empty
    }

    /// RULEBOOK 1.77.0 `timesheetCorrectionOption(input)`. `.none` when the script did not answer (no entry; fail closed).
    nonisolated static func timesheetCorrectionOption(
        sheet: [String: Any],
        viewerIsSubject: Bool,
        viewerIsReviewer: Bool,
        selfSigned: Bool,
        reopened: Bool,
        revisionAllowed: Bool,
        nextRevisionLabel: String?,
        revisionDue: Bool,
        lateExtrasAllowed: Bool,
        personName: String?,
        lineManagerName: String?,
        hasLineManager: Bool = true
    ) -> RulebookTimesheetCorrectionOption {
        let input: [String: Any] = [
            "sheet": sheet,
            "viewerIsSubject": viewerIsSubject,
            "viewerIsReviewer": viewerIsReviewer,
            "selfSigned": selfSigned,
            "change": ["reopened": reopened],
            "revisionAllowed": revisionAllowed,
            "nextRevisionLabel": RulebookJSON.orNull(nextRevisionLabel),
            "revisionDue": revisionDue,
            "lateExtrasAllowed": lateExtrasAllowed,
            "personName": RulebookJSON.orNull(personName),
            "lineManagerName": RulebookJSON.orNull(lineManagerName),
            "hasLineManager": hasLineManager,
        ]
        return RulebookTimesheetCorrectionOption(json: callJSON("timesheetCorrectionOption", arguments: [input])) ?? .none
    }
}

extension SignedTimesheetChanges {
    /// RULEBOOK 1.77.0 §8 (point 3): `signedTimesheetChangeDetails` for one draft — the inputs `change(...)` passes, the
    /// signed copy's lines with their stored day, job and words (what "before" shows on an older sheet), the price work /
    /// expense fields (`TimesheetLateExtrasSupport.rulebookSheet`) and the jobs to name.
    static func changeDetails(
        draft: TimesheetDraft,
        user: AppUser,
        period: WeekRange,
        inputs: Inputs,
        lines: [TimesheetPayrollLineItem]? = nil,
        currency: String,
        viewerIsReviewer: Bool
    ) -> RulebookTimesheetChangeDetails {
        guard isSigned(draft) else { return .empty }
        let keys = SignedTimesheetChangeInputs.documentKeys(bookings: inputs.bookings, managerBookings: inputs.managerBookings)
        let live = lines ?? liveLines(user: user, period: period, inputs: inputs)
        let documents = SignedTimesheetChangeInputs.bookingDocuments(
            bookings: inputs.bookings,
            managerBookings: inputs.managerBookings,
            range: period.start...period.end,
            alsoIds: SignedTimesheetChangeInputs.signedIds(draft, keys: keys)
        )
        var sheet = TimesheetLateExtrasSupport.rulebookSheet(draft)
        let signed = SignedTimesheetChangeInputs.sheet(draft, keys: keys)
        for (key, value) in signed where key != "weeklyReportOverride" { sheet[key] = value }
        if sheet["extraEntryReviews"] == nil {
            let reviews = TimesheetLateExtrasSupport.storedReviews(draft)
            if !(reviews is NSNull) { sheet["extraEntryReviews"] = reviews }
        }
        if let override = draft.weeklyReportOverride {
            var stored = sheet["weeklyReportOverride"] as? [String: Any] ?? [:]
            let signedLines = (signed["weeklyReportOverride"] as? [String: Any])?["lines"] as? [[String: Any]] ?? []
            stored["approvedAt"] = (signed["weeklyReportOverride"] as? [String: Any])?["approvedAt"] ?? NSNull()
            stored["lines"] = zip(signedLines, override.lines).map { pair -> [String: Any] in
                var row = pair.0
                row["date"] = Int64(pair.1.date.timeIntervalSince1970 * 1000)
                row["jobNumber"] = pair.1.jobNumber
                row["projectName"] = pair.1.projectName
                row["locationKind"] = pair.1.locationKind
                row["details"] = pair.1.details
                return row
            }
            sheet["weeklyReportOverride"] = stored
        }
        let jobs: [[String: Any]] = (inputs.projects + inputs.smallWorks).map { job in
            ["id": WorkDocumentKeys.storedId(for: job.id), "jobNumber": job.jobNumber, "name": job.siteName]
        }
        return CanonicalBusinessEngine.signedTimesheetChangeDetails(
            sheet: sheet,
            liveLines: SignedTimesheetChangeInputs.liveLines(live, keys: keys),
            liveBookings: documents,
            personIds: SignedTimesheetChangeInputs.personIds(user: user, operatives: inputs.operatives, users: inputs.users),
            liveLoaded: inputs.liveLoaded,
            selfSigned: !TimesheetApprovalPolicy.requiresLineManagerCounterSign(for: user),
            jobs: jobs,
            timeZone: OrganizationRulebookContext.timeZone.identifier,
            entryFingerprints: TimesheetLateExtrasSupport.fingerprints(draft),
            exportedAtStored: TimesheetLateExtrasSupport.exportedStored(draft),
            currency: currency,
            viewerIsReviewer: viewerIsReviewer
        )
    }
}

/// RULEBOOK 1.77.0 §8: the names the whose-turn line and the correction help use, from the roster
/// (`lineManagerSummary`): the line manager by name only when the person has exactly one known one (web the same).
/// Pass every users document of the organisation (`UserStore.unfoldedOrganizationUsers`, 24 Nov): the email-folded
/// roster cannot name a line manager stored under a folded-away document (web `soleLineManagerName`).
@MainActor
enum TimesheetClarityNames {
    static func lineManagerName(for person: AppUser, roster: [AppUser]) -> String? {
        guard let summary = CanonicalBusinessEngine.callJSON(
            "lineManagerSummary",
            arguments: [LineManagerRulebook.row(person), LineManagerRulebook.roster(roster)]
        ) as? [String: Any],
            let ids = summary["ids"] as? [[String: Any]], ids.count == 1,
            ids[0]["resolved"] as? Bool == true,
            let name = (ids[0]["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
            !name.isEmpty else { return nil }
        return name
    }

    /// Review of 1.77.0 (fix 4): `hasActiveLineManager(person, roster)` — false: the other admins sign off, and the
    /// whose-turn line and correction help name "an admin" (web passes the same, `userHasLineManager`).
    static func hasLineManager(_ person: AppUser, roster: [AppUser]) -> Bool {
        CanonicalBusinessEngine.overtimeHasActiveLineManager(person: RulebookPeople.person(person), roster: RulebookPeople.roster(roster))
    }

    /// Review of 1.77.0 (nit a): `hasInvoiceDays` — the person has self-employed days in this pay run
    /// (`timesheetDaysForPerson`, web `sheetDays`); true when the script did not answer (as web with no days known).
    static func hasInvoiceDays(_ person: AppUser, period: ClosedRange<Date>) -> Bool {
        guard let days = TimesheetTotalsSource.timesheetDays(for: person, period: period) else { return true }
        return !days.isEmpty
    }

    static func personName(_ person: AppUser) -> String? {
        let name = person.fullName.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : name
    }
}
