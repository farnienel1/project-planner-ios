//
//  Rulebook+TimesheetLateExtras.swift
//  Project Planner
//
//  RULEBOOK 1.54.0 §8 (owner decision 16 Nov, "allow adding after sign-off so they can re-issue"; web
//  `lib/canonical/timesheetLateExtras.ts`): price work and expenses the person adds after the line manager has signed
//  — **late extras** (`lateExtras`, until the sheet is exported). The signed entries stay closed. A late extra pays only
//  once the line manager (or an admin) approves it in `extraEntryReviews` with `lateExtra: true` and the entry's
//  fingerprint. Every answer here is the packed script's (`CanonicalBusinessEngine.callJSON`); Swift only maps the draft
//  into the script's plain rows and reads the answer back. No decision is made in Swift.
//
//  Also RULEBOOK 1.54.0 §9: `annualLeaveReportYearMonths` (the Annual leave report counts the balance's leave year).
//

import Foundation
@preconcurrency import FirebaseFirestore

/// `timesheetLateExtrasSummary(sheet, options)` → where a sheet's late extras stand.
nonisolated struct RulebookLateExtrasSummary: Equatable, Hashable, Sendable {
    let pending: Int
    let approved: Int
    let declined: Int
    let snapshotInStep: Bool
    let exported: Bool
    /// Not exported, and a late extra waits or the snapshot's late rows are out of step.
    let waitingForLineManager: Bool

    init?(json: Any?) {
        guard let row = json as? [String: Any], let waiting = row["waitingForLineManager"] as? Bool else { return nil }
        pending = (row["pending"] as? NSNumber)?.intValue ?? 0
        approved = (row["approved"] as? NSNumber)?.intValue ?? 0
        declined = (row["declined"] as? NSNumber)?.intValue ?? 0
        snapshotInStep = row["snapshotInStep"] as? Bool ?? true
        exported = row["exported"] as? Bool ?? false
        waitingForLineManager = waiting
    }

    /// The `late` argument of `timesheetChangesWithLateExtras`.
    var json: [String: Any] {
        [
            "pending": pending, "approved": approved, "declined": declined, "snapshotInStep": snapshotInStep,
            "exported": exported, "waitingForLineManager": waitingForLineManager,
        ]
    }
}

extension CanonicalBusinessEngine {
    // MARK: Texts (read from the script, never retyped as the rule; the fallback is only for a script that did not run)

    private nonisolated static func lateExtrasText(_ name: String, fallback: String) -> String {
        constant(name, as: String.self) ?? fallback
    }

    /// `TIMESHEET_LATE_EXTRA_ADD_CONFIRM_MESSAGE` — the confirm before the person adds a late extra.
    nonisolated static var timesheetLateExtraAddConfirmMessage: String {
        lateExtrasText(
            "TIMESHEET_LATE_EXTRA_ADD_CONFIRM_MESSAGE",
            fallback: "Your timesheet is already signed off. This will be sent to your line manager to approve; it is paid only once they approve it."
        )
    }

    /// `TIMESHEET_LATE_EXTRAS_REVIEWER_MESSAGE` — the reviewer's prompt while late extras wait.
    nonisolated static var timesheetLateExtrasReviewerMessage: String {
        lateExtrasText(
            "TIMESHEET_LATE_EXTRAS_REVIEWER_MESSAGE",
            fallback: "Price work or expenses were added after this timesheet was signed. Approve or decline each one — only what you approve is paid."
        )
    }

    /// `TIMESHEET_LATE_EXTRAS_EXPORT_SKIPPED_MESSAGE` — why Export left a sheet out.
    nonisolated static var timesheetLateExtrasExportSkippedMessage: String {
        lateExtrasText(
            "TIMESHEET_LATE_EXTRAS_EXPORT_SKIPPED_MESSAGE",
            fallback: "Not exported — price work or expenses added after sign-off are waiting for the line manager."
        )
    }

    /// `TIMESHEET_EXPORTED_EXTRAS_MESSAGE` — shown instead of the late-extras add controls once exported.
    nonisolated static var timesheetExportedExtrasMessage: String {
        lateExtrasText(
            "TIMESHEET_EXPORTED_EXTRAS_MESSAGE",
            fallback: "This timesheet has been exported — add it to your next timesheet."
        )
    }

    /// `TIMESHEET_LATE_EXTRA_WAITING_LABEL` — a late extra still waiting for a decision.
    nonisolated static var timesheetLateExtraWaitingLabel: String {
        lateExtrasText("TIMESHEET_LATE_EXTRA_WAITING_LABEL", fallback: "Added after sign-off — waiting for your line manager")
    }

    // MARK: Rules

    /// RULEBOOK 1.54.0 `timesheetExportedFieldSet(value)`: a stored `exportedAt` the security rules count as set.
    /// `value` is the stored Firestore value (a Timestamp is passed as `{ seconds, nanoseconds }`).
    nonisolated static func timesheetExportedFieldSet(_ value: Any?) -> Bool {
        let argument = value.map { FirebaseBackend.firestoreJSON($0) } ?? NSNull()
        return callJSON("timesheetExportedFieldSet", arguments: [argument]) as? Bool ?? (value != nil && !(value is NSNull))
    }

    /// RULEBOOK 1.54.0 §8 `timesheetOwnerCanAddLateExtras(sheet, { selfSigned })`: only once the line manager has signed
    /// and until the stored `exportedAt` is set (`TIMESHEET_EXPORTED_EXTRAS_MESSAGE`); never on a self-signed sheet.
    /// When the script did not answer, nothing is offered.
    nonisolated static func timesheetOwnerCanAddLateExtras(
        managerSignedAt: Date?,
        approvedAt: Date?,
        exportedAt: Date?,
        exportedAtStored: Bool?,
        selfSigned: Bool
    ) -> RulebookTimesheetExtrasPermission {
        func ms(_ date: Date?) -> Any { date.map { $0.timeIntervalSince1970 * 1000 as Any } ?? NSNull() }
        var sheet: [String: Any] = [
            "managerSignedAt": ms(managerSignedAt),
            "approvedAt": ms(approvedAt),
            "exportedAt": ms(exportedAt),
        ]
        if let exportedAtStored { sheet["exportedAtStored"] = exportedAtStored }
        return RulebookTimesheetExtrasPermission(
            json: callJSON("timesheetOwnerCanAddLateExtras", arguments: [sheet, ["selfSigned": selfSigned]])
        ) ?? RulebookTimesheetExtrasPermission(allowed: false, message: nil)
    }

    /// RULEBOOK 1.54.0 §8 `parseTimesheetLateExtras(sheetDocId, sheet, { timeZone, organizationId, ownerUserIds })`:
    /// each late extra in stored order with its kind and late decision (`lateDecision`), the reader's ids, evidence and
    /// fingerprint. Nil when the script did not answer.
    nonisolated static func parseTimesheetLateExtras(
        sheetDocumentId: String,
        sheet: [String: Any],
        timeZone: String = OrganizationRulebookContext.timeZoneIdentifier,
        organizationId: String? = OrganizationRulebookContext.organizationId,
        ownerUserIds: [String] = []
    ) -> [CanonicalDocumentRow]? {
        var options: [String: Any] = ["timeZone": timeZone, "ownerUserIds": ownerUserIds]
        if let organizationId, !organizationId.isEmpty { options["organizationId"] = organizationId }
        guard let rows = callJSON(
            "parseTimesheetLateExtras",
            arguments: [sheetDocumentId, peopleDocumentJSON(sheet), options]
        ) as? [Any] else { return nil }
        return rows.compactMap { CanonicalDocumentRow($0) }
    }

    /// RULEBOOK 1.54.0 `timesheetLateExtraFingerprintMap(entries)`: late extras' trusted fingerprints under their own
    /// keys (`late:` + the id without case), never mixed with the signed entries'.
    nonisolated static func timesheetLateExtraFingerprintMap(_ entries: [[String: Any]]) -> [String: Any] {
        callJSON("timesheetLateExtraFingerprintMap", arguments: [entries]) as? [String: Any] ?? [:]
    }

    /// RULEBOOK 1.54.0 `timesheetLateExtrasSummary(sheet, { entryFingerprints, exportedAtStored, sheetDocId })`. Nil
    /// when the script did not answer.
    nonisolated static func timesheetLateExtrasSummary(
        sheet: [String: Any],
        entryFingerprints: [String: Any],
        exportedAtStored: Bool?,
        sheetDocId: String? = nil
    ) -> RulebookLateExtrasSummary? {
        var options: [String: Any] = ["entryFingerprints": entryFingerprints]
        if let exportedAtStored { options["exportedAtStored"] = exportedAtStored }
        if let sheetDocId, !sheetDocId.isEmpty { options["sheetDocId"] = sheetDocId }
        return RulebookLateExtrasSummary(json: callJSON("timesheetLateExtrasSummary", arguments: [sheet, options]))
    }

    /// RULEBOOK 1.54.0 `timesheetChangesWithLateExtras(bookingChange, late)`: the 1.47.0 booking change as it was and —
    /// when no booking change reopened the sheet — a sheet whose late extras wait reads reopened, waiting for the line
    /// manager. `bookingChange` is the raw script answer of `signedTimesheetBookingChanges` (or nil).
    nonisolated static func timesheetChangesWithLateExtras(
        bookingChange: Any?,
        late: RulebookLateExtrasSummary?
    ) -> RulebookSignedTimesheetChange? {
        let change: Any = bookingChange ?? NSNull()
        let summary: Any = late.map { $0.json as Any } ?? NSNull()
        return RulebookSignedTimesheetChange(json: callJSON("timesheetChangesWithLateExtras", arguments: [change, summary]))
    }

    /// RULEBOOK 1.54.0 `timesheetLateExtraLabel({ state, reason })`: the person's and reviewer's label for one late extra.
    nonisolated static func timesheetLateExtraLabel(state: String, reason: String?) -> String? {
        let decision: [String: Any] = ["state": state, "reason": RulebookJSON.orNull(reason)]
        return callJSON("timesheetLateExtraLabel", arguments: [decision]) as? String
    }

    /// RULEBOOK 1.54.0 `timesheetLateExtraReviewable(decision, { exported })`: never an ignored late extra, never once
    /// exported. False when the script did not answer (nothing is offered).
    nonisolated static func timesheetLateExtraReviewable(state: String?, exported: Bool) -> Bool {
        let decision: Any = state.map { ["state": $0] as Any } ?? NSNull()
        return callJSON("timesheetLateExtraReviewable", arguments: [decision, ["exported": exported]]) as? Bool ?? false
    }

    /// RULEBOOK 1.54.0 `timesheetLateExtrasSnapshotRows(sheet, { entryFingerprints, sheetDocId })`: the signed
    /// snapshot's money rows for the approved late extras (marked `lateExtra: true`). Nil when the script did not answer.
    nonisolated static func timesheetLateExtrasSnapshotRows(
        sheet: [String: Any],
        entryFingerprints: [String: Any],
        sheetDocId: String? = nil
    ) -> (priceWork: [[String: Any]], expenses: [[String: Any]])? {
        var options: [String: Any] = ["entryFingerprints": entryFingerprints]
        if let sheetDocId, !sheetDocId.isEmpty { options["sheetDocId"] = sheetDocId }
        guard let row = callJSON("timesheetLateExtrasSnapshotRows", arguments: [sheet, options]) as? [String: Any] else { return nil }
        return (row["priceWork"] as? [[String: Any]] ?? [], row["expenses"] as? [[String: Any]] ?? [])
    }

    /// RULEBOOK 1.54.0 `timesheetSnapshotMoneyRowsCurrent(sheet, rows, options)`: the indexes of the snapshot money rows
    /// a report may count (a row marked `lateExtra` only while that late extra is still approved at the same pennies).
    /// Nil when the script did not answer.
    nonisolated static func timesheetSnapshotMoneyRowsCurrent(
        sheet: [String: Any],
        rows: [[String: Any]],
        entryFingerprints: [String: Any],
        exportedAtStored: Bool?,
        sheetDocId: String? = nil
    ) -> [Int]? {
        let tagged: [[String: Any]] = rows.enumerated().map { index, row in
            var out = row
            out["__index"] = index
            return out
        }
        var options: [String: Any] = ["entryFingerprints": entryFingerprints]
        if let exportedAtStored { options["exportedAtStored"] = exportedAtStored }
        if let sheetDocId, !sheetDocId.isEmpty { options["sheetDocId"] = sheetDocId }
        guard let kept = callJSON("timesheetSnapshotMoneyRowsCurrent", arguments: [sheet, tagged, options]) as? [[String: Any]] else {
            return nil
        }
        return kept.compactMap { ($0["__index"] as? NSNumber)?.intValue }
    }

    /// RULEBOOK 1.54.0 §8 (fourth review of #337) `timesheetEntryReviewWriteFields` for the reviewer's save: the signed
    /// entries' and the late extras' decisions, with `exported` (an exported sheet's late extras are frozen) and the
    /// stored sheet (`sheet`, `sheetDocId`) so a late review is never written under a signed entry's key. Dotted
    /// `extraEntryReviews.{id}` fields; empty when nothing changed; nil when the script did not answer.
    nonisolated static func timesheetEntryReviewWriteFields(
        storedSheet: [String: Any]?,
        entryRows: [[String: Any]],
        reviewedByUserId: String,
        reviewedAtMs: Double,
        exported: Bool,
        sheetDocId: String?
    ) -> [String: Any]? {
        var stored: Any = NSNull()
        var signedSheet: Any = NSNull()
        if let storedSheet, let sheetJSON = timesheetJSONSafe(storedSheet) {
            guard let parsed = callJSON("parseTimesheetEntryReviews", arguments: [sheetJSON]) else { return nil }
            stored = parsed
            // RULEBOOK 1.54.0 (final check and verification of #337): the stored sheet itself, with its `lateExtras` and
            // signed entries — the writer works out the signed ids and judges each late entry on its stored row.
            signedSheet = sheetJSON
        }
        var input: [String: Any] = [
            "stored": stored,
            "entries": entryRows,
            "reviewedByUserId": reviewedByUserId,
            "reviewedAtMs": reviewedAtMs,
            "exported": exported,
            "sheet": signedSheet,
        ]
        if let sheetDocId, !sheetDocId.isEmpty { input["sheetDocId"] = sheetDocId }
        return callJSON("timesheetEntryReviewWriteFields", arguments: [input]) as? [String: Any]
    }

    /// RULEBOOK 1.54.0: `timesheetEntryReviewWriteFields` then `timesheetEntryReviewsAfterWrite` over the stored reviews
    /// (web `timesheetSheetFields({ reviewerPreview })`): the review map the reviewer's screen holds once their on-screen
    /// late decisions are saved. Nil when the script did not answer.
    nonisolated static func timesheetLateExtraReviewsPreview(
        storedReviews: Any,
        lateRows: [[String: Any]],
        signedSheet: [String: Any],
        exported: Bool
    ) -> Any? {
        // The stored map as the writer reads it (`parseTimesheetEntryReviews`: `lateExtra` false when missing).
        let parsed: Any = storedReviews is NSNull
            ? NSNull()
            : (callJSON("parseTimesheetEntryReviews", arguments: [["extraEntryReviews": storedReviews]]) ?? NSNull())
        let input: [String: Any] = [
            "stored": parsed, "entries": lateRows, "reviewedByUserId": "", "reviewedAtMs": 0,
            "exported": exported, "sheet": signedSheet,
        ]
        guard let written = callJSON("timesheetEntryReviewWriteFields", arguments: [input]) as? [String: Any] else { return nil }
        return callJSON("timesheetEntryReviewsAfterWrite", arguments: [parsed, written])
    }

    // MARK: Annual leave report (§9)

    /// RULEBOOK 1.54.0 §9 `annualLeaveReportYearMonths({ annualLeaveEnabled, startMonth, endMonth, orgStartMonth,
    /// orgEndMonth, onDayKey, timeZone, employment })`: the leave-year months the Annual leave report counts — the
    /// person's own leave year while they have an allowance on `onDayKey`, else the organisation's (exactly the year
    /// `annualLeaveBalance` uses). Nil when the script did not answer.
    nonisolated static func annualLeaveReportYearMonths(
        annualLeaveEnabled: Bool?,
        startMonth: Int?,
        endMonth: Int?,
        orgStartMonth: Int?,
        orgEndMonth: Int?,
        onDayKey: String,
        employment: AnnualLeaveEmployment?,
        timeZone: String = OrganizationRulebookContext.timeZoneIdentifier
    ) -> (startMonth: Int, endMonth: Int)? {
        var input: [String: Any] = ["onDayKey": onDayKey, "timeZone": timeZone]
        if let annualLeaveEnabled { input["annualLeaveEnabled"] = annualLeaveEnabled }
        if let startMonth { input["startMonth"] = startMonth }
        if let endMonth { input["endMonth"] = endMonth }
        if let orgStartMonth { input["orgStartMonth"] = orgStartMonth }
        if let orgEndMonth { input["orgEndMonth"] = orgEndMonth }
        if let employment { input["employment"] = employment.json }
        guard let row = callJSON("annualLeaveReportYearMonths", arguments: [input]) as? [String: Any],
              let start = (row["startMonth"] as? NSNumber)?.intValue,
              let end = (row["endMonth"] as? NSNumber)?.intValue else { return nil }
        return (start, end)
    }
}

/// RULEBOOK 1.54.0 §8: the draft ↔ script mapping for late extras (web `lateExtraToFirestore`, `draftEntryFingerprints`,
/// `draftReviewEntries`, `timesheetSheetFields`, `draftWithCurrentLateRows`). A mapping only — every decision is the
/// script's.
enum TimesheetLateExtrasSupport {
    /// The stored shape of one late extra (web `lateExtraToFirestore`): its own fields and `kind`, never a decision.
    static func storedRow(_ late: TimesheetLateExtra) -> [String: Any] {
        var row: [String: Any] = [
            "kind": late.isPriceWork ? "priceWork" : "expense",
            "id": late.id,
            "title": late.title,
            "details": late.details,
            "jobNumber": late.jobNumber,
            "amount": late.amount,
        ]
        if late.isPriceWork {
            row["agreedManagerName"] = late.agreedManagerName
            row["startDate"] = Timestamp(date: late.date)
            row["endDate"] = late.endDate.map(Timestamp.init(date:)) as Any
        } else {
            row["date"] = Timestamp(date: late.date)
        }
        if let evidence = TimesheetDraftStore.evidenceWriteFields(late.evidence) { row["evidence"] = evidence }
        return row
    }

    /// Reads `lateExtras` from a stored sheet (Firestore values) through `parseTimesheetLateExtras`. Nil when the sheet
    /// has no `lateExtras` array (nothing to keep); an empty list when the script did not answer would lose rows, so the
    /// caller gets nil and keeps none — the caller decides (see `TimesheetDraftStore.fromFirestoreMap`).
    static func read(sheetDocumentId: String, sheet: [String: Any], ownerUserIds: [String]) -> [TimesheetLateExtra]? {
        guard sheet["lateExtras"] is [Any] else { return nil }
        guard let rows = CanonicalBusinessEngine.parseTimesheetLateExtras(
            sheetDocumentId: sheetDocumentId,
            sheet: sheet,
            ownerUserIds: ownerUserIds
        ) else { return nil }
        return rows.map { row in
            let isPriceWork = row.text("kind") == "priceWork"
            let decision = row.map("lateDecision")
            let state = (decision["state"] as? String) ?? "pending"
            let seeded = TimesheetManagerDecision(rawValue: (decision["decision"] as? String) ?? "") ?? .pending
            return TimesheetLateExtra(
                id: row.id,
                kind: isPriceWork ? "priceWork" : "expense",
                title: row.text("title"),
                details: row.raw["details"] as? String ?? "",
                jobNumber: row.text("jobNumber"),
                agreedManagerName: row.optionalText("agreedManagerName") ?? "",
                date: (isPriceWork ? row.date("startMs") : row.date("dateMs")) ?? Date(),
                endDate: isPriceWork ? row.date("endMs") : nil,
                amount: row.number("amount") ?? 0,
                receiptName: row.optionalText("receiptName"),
                evidence: TimesheetDraftStore.entryEvidence(row),
                reviewFingerprint: row.optionalText("reviewFingerprint"),
                lateState: state,
                lateReason: decision["reason"] as? String,
                managerDecision: seeded,
                managerRevisedAmount: (decision["revisedAmount"] as? NSNumber)?.doubleValue
            )
        }
    }

    /// The stored review map as plain JSON (`extraEntryReviews`), read only.
    static func storedReviews(_ draft: TimesheetDraft) -> Any {
        guard let text = draft.extraEntryReviewsJSON, let data = text.data(using: .utf8),
              let value = try? JSONSerialization.jsonObject(with: data) else { return NSNull() }
        return value
    }

    /// `extraEntryReviews` of a stored sheet as JSON text for `TimesheetDraft.extraEntryReviewsJSON`.
    static func reviewsJSONText(fromStoredSheet sheet: [String: Any]) -> String? {
        guard let map = sheet["extraEntryReviews"] as? [String: Any] else { return nil }
        let json = FirebaseBackend.firestoreJSON(map)
        guard JSONSerialization.isValidJSONObject(json), let data = try? JSONSerialization.data(withJSONObject: json) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Whether the stored `exportedAt` is set (as the rules test it), else this device's own stamp.
    static func exportedStored(_ draft: TimesheetDraft) -> Bool {
        draft.exportedAtStored == true || draft.exportedAt != nil
    }

    /// The late extras' trusted fingerprints (`timesheetLateExtraFingerprintMap`), under their own `late:` keys.
    static func fingerprints(_ draft: TimesheetDraft) -> [String: Any] {
        let rows: [[String: Any]] = (draft.lateExtras ?? []).compactMap { late in
            late.reviewFingerprint.map { ["id": late.id, "reviewFingerprint": $0] }
        }
        guard !rows.isEmpty else { return [:] }
        return CanonicalBusinessEngine.timesheetLateExtraFingerprintMap(rows)
    }

    /// The late extras a reviewer's save decides (web `draftReviewEntries`): never an ignored one; each with its own
    /// fields, its on-screen decision, its fingerprint and `lateExtra: true`.
    static func reviewEntryRows(_ draft: TimesheetDraft) -> [[String: Any]] {
        (draft.lateExtras ?? []).filter { $0.lateState != "ignored" }.map { late in
            var row = FirebaseBackend.firestoreJSON(storedRow(late)) as? [String: Any] ?? [:]
            row["managerDecision"] = late.managerDecision.rawValue
            row["managerRevisedAmount"] = late.managerRevisedAmount.map { $0 as Any } ?? NSNull()
            row["lateExtra"] = true
            if let fingerprint = late.reviewFingerprint, !fingerprint.isEmpty { row["reviewFingerprint"] = fingerprint }
            return row
        }
    }

    /// The sheet the late-extras rules read (web `timesheetSheetFields`): the draft as stored, its late extras, and —
    /// only when it has late extras, so a sheet without them is read exactly as before 1.54.0 — the stored review map.
    /// `reviewerPreview`: the reviewer's on-screen late decisions laid over the stored reviews as their save writes them.
    static func rulebookSheet(_ draft: TimesheetDraft, reviewerPreview: Bool = false) -> [String: Any] {
        var sheet = FirebaseBackend.firestoreJSON(TimesheetDraftStore.asFirestoreMap(draft)) as? [String: Any] ?? [:]
        guard let late = draft.lateExtras, !late.isEmpty else { return sheet }
        var reviews = storedReviews(draft)
        if reviewerPreview {
            // RULEBOOK 1.54.0 (verification of #337): the writer is given the sheet with its stored `lateExtras` and the
            // signed entries, so it judges each late entry on its stored row (each entry carries its title too).
            if let previewed = CanonicalBusinessEngine.timesheetLateExtraReviewsPreview(
                storedReviews: reviews,
                lateRows: reviewEntryRows(draft),
                signedSheet: sheet,
                exported: exportedStored(draft)
            ) {
                reviews = previewed
            }
        }
        if !(reviews is NSNull) { sheet["extraEntryReviews"] = reviews }
        return sheet
    }

    /// `timesheetLateExtrasSummary` for the draft (nil when it has no late extras and no late snapshot row, or the
    /// script did not answer).
    static func summary(_ draft: TimesheetDraft, sheetDocId: String? = nil) -> RulebookLateExtrasSummary? {
        let hasLateRows = (draft.weeklyReportOverride.map { ($0.priceWork + $0.expenses).contains { $0.lateExtra == true } }) ?? false
        guard !(draft.lateExtras ?? []).isEmpty || hasLateRows else { return nil }
        return CanonicalBusinessEngine.timesheetLateExtrasSummary(
            sheet: rulebookSheet(draft),
            entryFingerprints: fingerprints(draft),
            exportedAtStored: exportedStored(draft),
            sheetDocId: sheetDocId
        )
    }

    /// `timesheetLateExtrasSnapshotRows` with the reviewer's on-screen decisions (web `moneyLines` in
    /// `weeklyReportOverride.ts`) as snapshot money lines marked `lateExtra`. Empty without late extras; nil when the
    /// script did not answer (the caller then does not write a snapshot).
    static func snapshotMoneyLines(_ draft: TimesheetDraft) -> (priceWork: [TimesheetWeeklyReportMoneyLine], expenses: [TimesheetWeeklyReportMoneyLine])? {
        guard let late = draft.lateExtras, !late.isEmpty else { return ([], []) }
        guard let rows = CanonicalBusinessEngine.timesheetLateExtrasSnapshotRows(
            sheet: rulebookSheet(draft, reviewerPreview: true),
            entryFingerprints: fingerprints(draft)
        ) else { return nil }
        func line(_ row: [String: Any]) -> TimesheetWeeklyReportMoneyLine? {
            guard let id = row["id"] as? String else { return nil }
            return TimesheetWeeklyReportMoneyLine(
                id: id,
                title: row["title"] as? String ?? "",
                details: row["details"] as? String ?? "",
                jobNumber: row["jobNumber"] as? String ?? "",
                date: firestoreDate(row["date"]) ?? Date(),
                amount: (row["amount"] as? NSNumber)?.doubleValue ?? 0,
                decision: TimesheetManagerDecision(rawValue: row["decision"] as? String ?? "") ?? .approved,
                lateExtra: true,
                entryFingerprint: (row["entryFingerprint"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            )
        }
        return (rows.priceWork.compactMap(line), rows.expenses.compactMap(line))
    }

    /// Web `draftWithCurrentLateRows`: the draft with its signed snapshot's late-extra money rows only while each late
    /// extra is still approved at that amount (`timesheetSnapshotMoneyRowsCurrent`). Exported sheets stay as signed.
    static func draftWithCurrentLateRows(_ draft: TimesheetDraft) -> TimesheetDraft {
        guard let signed = draft.weeklyReportOverride,
              (signed.priceWork + signed.expenses).contains(where: { $0.lateExtra == true }) else { return draft }
        let sheet = rulebookSheet(draft)
        let prints = fingerprints(draft)
        func current(_ lines: [TimesheetWeeklyReportMoneyLine]) -> [TimesheetWeeklyReportMoneyLine] {
            let rows: [[String: Any]] = lines.map { line in
                var row: [String: Any] = ["id": line.id, "amount": line.amount]
                if line.lateExtra == true { row["lateExtra"] = true }
                return row
            }
            // The script did not answer: a late row is not counted (never pay an unchecked late extra).
            guard let kept = CanonicalBusinessEngine.timesheetSnapshotMoneyRowsCurrent(
                sheet: sheet, rows: rows, entryFingerprints: prints, exportedAtStored: exportedStored(draft)
            ) else { return lines.filter { $0.lateExtra != true } }
            let keep = Set(kept)
            return lines.enumerated().filter { keep.contains($0.offset) }.map(\.element)
        }
        let priceWork = current(signed.priceWork)
        let expenses = current(signed.expenses)
        if priceWork.count == signed.priceWork.count && expenses.count == signed.expenses.count { return draft }
        var out = draft
        out.weeklyReportOverride?.priceWork = priceWork
        out.weeklyReportOverride?.expenses = expenses
        return out
    }

    /// The late extras as the owner-entry rule reads them (`timesheetOwnerEntriesError`), split by kind (stored shape).
    static func entriesByKind(_ late: [TimesheetLateExtra]?) -> (priceWork: [Any], expenses: [Any]) {
        let rows = (late ?? [])
        return (
            rows.filter(\.isPriceWork).map { storedRow($0) as Any },
            rows.filter { !$0.isPriceWork }.map { storedRow($0) as Any }
        )
    }

    /// A late extra from the Add / Edit Price Work sheet (keeps `id` when editing).
    static func lateExtra(from entry: TimesheetPriceWorkEntry, id: String) -> TimesheetLateExtra {
        TimesheetLateExtra(
            id: id,
            kind: "priceWork",
            title: entry.title,
            details: entry.details,
            jobNumber: entry.jobNumber,
            agreedManagerName: entry.agreedManagerName,
            date: entry.startDate,
            endDate: entry.endDate,
            amount: entry.amount,
            evidence: entry.evidence
        )
    }

    /// A late extra from the Add / Edit Expense sheet (keeps `id` when editing).
    static func lateExtra(from entry: TimesheetExpenseEntry, id: String) -> TimesheetLateExtra {
        TimesheetLateExtra(
            id: id,
            kind: "expense",
            title: entry.title,
            details: entry.details,
            jobNumber: entry.jobNumber,
            date: entry.date,
            amount: entry.amount,
            receiptName: entry.receiptName,
            evidence: entry.evidence
        )
    }

    /// The Add / Edit Price Work sheet's editing copy of a late extra.
    static func priceWorkEntry(_ late: TimesheetLateExtra) -> TimesheetPriceWorkEntry {
        TimesheetPriceWorkEntry(
            id: UUID(),
            title: late.title,
            details: late.details,
            jobNumber: late.jobNumber,
            agreedManagerName: late.agreedManagerName,
            startDate: late.date,
            endDate: late.endDate,
            amount: late.amount,
            evidence: late.evidence
        )
    }

    /// The Add / Edit Expense sheet's editing copy of a late extra.
    static func expenseEntry(_ late: TimesheetLateExtra) -> TimesheetExpenseEntry {
        TimesheetExpenseEntry(
            id: UUID(),
            title: late.title,
            details: late.details,
            jobNumber: late.jobNumber,
            date: late.date,
            amount: late.amount,
            receiptName: late.receiptName,
            evidence: late.evidence
        )
    }
}
