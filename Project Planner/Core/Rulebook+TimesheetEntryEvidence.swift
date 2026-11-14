//
//  Rulebook+TimesheetEntryEvidence.swift
//  Project Planner
//
//  RULEBOOK 1.45.0 §8 / §24 / §26 (owner decisions 14 Nov): evidence on timesheet price work and expense entries, edit
//  and delete of those entries and of PAYE items, "Amount inc VAT", and the attach-control wording. Typed wrappers for
//  web `lib/canonical/claimEvidence.ts`, `timesheetEntryEvidence.ts` and the 1.45.0 additions to `payeClaims.ts`, called
//  through `CanonicalBusinessEngine.callJSON`. Swift builds the inputs and reads the answers; nothing is decided here.
//

import Foundation

/// `{ set, remove }`: the changed fields of an edit, for `updateData` (RULEBOOK 1.45.0 §26 `PayeClaimUpdateWrite`).
nonisolated struct PayeClaimUpdateWrite: @unchecked Sendable {
    let set: [String: Any]
    let remove: [String]

    var isEmpty: Bool { self.set.isEmpty && self.remove.isEmpty }
}

extension CanonicalBusinessEngine {
    // MARK: Wording (claimEvidence.ts, payeClaims.ts, timesheetEntryEvidence.ts)

    nonisolated static var claimEvidenceTakePhotoLabel: String { payeClaimText("CLAIM_EVIDENCE_TAKE_PHOTO_LABEL", fallback: "Take photo") }
    nonisolated static var claimEvidenceChoosePhotoLabel: String { payeClaimText("CLAIM_EVIDENCE_CHOOSE_PHOTO_LABEL", fallback: "Choose photo") }
    nonisolated static var claimEvidenceAddSiteAuditLabel: String { payeClaimText("CLAIM_EVIDENCE_ADD_SITE_AUDIT_LABEL", fallback: "Add site audit") }
    nonisolated static var claimEvidenceAddFileLabel: String { payeClaimText("CLAIM_EVIDENCE_ADD_FILE_LABEL", fallback: "Add file") }
    nonisolated static var claimEvidenceHeading: String { payeClaimText("CLAIM_EVIDENCE_HEADING", fallback: "Evidence") }
    nonisolated static var claimEvidenceNoneText: String { payeClaimText("CLAIM_EVIDENCE_NONE_TEXT", fallback: "No evidence") }
    nonisolated static var claimEvidenceHelpText: String { payeClaimText("CLAIM_EVIDENCE_HELP_TEXT", fallback: "Photos and PDFs up to 10MB.") }
    nonisolated static var claimEvidenceSiteAuditNote: String {
        payeClaimText(
            "CLAIM_EVIDENCE_SITE_AUDIT_NOTE",
            fallback: "A frozen copy (PDF) is attached; your line managers and admins see the copy, never your list."
        )
    }
    nonisolated static var claimEvidenceLegacyReceiptNote: String {
        payeClaimText("CLAIM_EVIDENCE_LEGACY_RECEIPT_NOTE", fallback: "Receipt noted before files were stored — no file to open")
    }
    nonisolated static var expenseEvidenceRequiredMessage: String {
        payeClaimText("EXPENSE_EVIDENCE_REQUIRED_MESSAGE", fallback: "Add at least one piece of evidence (a file, photo or personal site audit).")
    }

    /// `EXPENSE_AMOUNT_LABEL` ("Amount inc VAT") for an expense, `PRICE_WORK_AMOUNT_LABEL` ("Amount") for price work.
    nonisolated static func claimAmountLabel(isExpense: Bool) -> String {
        isExpense
            ? payeClaimText("EXPENSE_AMOUNT_LABEL", fallback: "Amount inc VAT")
            : payeClaimText("PRICE_WORK_AMOUNT_LABEL", fallback: "Amount")
    }

    nonisolated static var payeClaimEditLabel: String { payeClaimText("PAYE_CLAIM_EDIT_LABEL", fallback: "Edit") }
    nonisolated static var payeClaimDeleteLabel: String { payeClaimText("PAYE_CLAIM_DELETE_LABEL", fallback: "Delete") }
    nonisolated static var payeClaimSaveChangesLabel: String { payeClaimText("PAYE_CLAIM_SAVE_CHANGES_LABEL", fallback: "Save changes") }
    nonisolated static var payeClaimDeleteConfirmMessage: String {
        payeClaimText(
            "PAYE_CLAIM_DELETE_CONFIRM_MESSAGE",
            fallback: "Delete this item? Its evidence is kept for recovery unless you added it in the last few minutes."
        )
    }
    nonisolated static var payeClaimEditReviewNote: String {
        payeClaimText("PAYE_CLAIM_EDIT_REVIEW_NOTE", fallback: "Saving changes sends it back to Needs review.")
    }

    nonisolated static var timesheetEntryEditLabel: String { payeClaimText("TIMESHEET_ENTRY_EDIT_LABEL", fallback: "Edit") }
    nonisolated static var timesheetEntryDeleteLabel: String { payeClaimText("TIMESHEET_ENTRY_DELETE_LABEL", fallback: "Delete") }
    nonisolated static var timesheetEntrySaveChangesLabel: String { payeClaimText("TIMESHEET_ENTRY_SAVE_CHANGES_LABEL", fallback: "Save changes") }
    nonisolated static var timesheetEntryDeleteConfirmMessage: String {
        payeClaimText(
            "TIMESHEET_ENTRY_DELETE_CONFIRM_MESSAGE",
            fallback: "Delete this entry from your timesheet? Its evidence is kept for recovery unless you added it in the last few minutes."
        )
    }
    /// `TIMESHEET_ENTRY_EDIT_PRICE_WORK_TITLE` / `TIMESHEET_ENTRY_EDIT_EXPENSE_TITLE`.
    nonisolated static func timesheetEntryEditTitle(isExpense: Bool) -> String {
        isExpense
            ? payeClaimText("TIMESHEET_ENTRY_EDIT_EXPENSE_TITLE", fallback: "Edit Expense")
            : payeClaimText("TIMESHEET_ENTRY_EDIT_PRICE_WORK_TITLE", fallback: "Edit Price Work")
    }

    /// `EXPENSES_REPORT_COLUMNS` (Date, Job number, Name, Amount inc VAT).
    nonisolated static var expensesReportColumns: [String] {
        constant("EXPENSES_REPORT_COLUMNS", as: [String].self) ?? ["Date", "Job number", "Name", "Amount inc VAT"]
    }

    /// `claimEvidenceCountText(count)`: "1 piece of evidence" / "3 pieces of evidence"; '' for none.
    nonisolated static func claimEvidenceCountText(_ count: Int) -> String {
        if let text = callJSON("claimEvidenceCountText", arguments: [count]) as? String { return text }
        if count <= 0 { return "" }
        return count == 1 ? "1 piece of evidence" : "\(count) pieces of evidence"
    }

    /// `claimEvidenceRemoved(before, after)`: the entries of `before` no longer in `after` (by path).
    nonisolated static func claimEvidenceRemoved(_ before: [PayeClaimEvidence], after: [PayeClaimEvidence]) -> [PayeClaimEvidence] {
        RulebookJSON.decode(
            [PayeClaimEvidence].self,
            from: callJSON("claimEvidenceRemoved", arguments: [before.map(\.json), after.map(\.json)])
        ) ?? []
    }

    // MARK: Timesheet entries (timesheetEntryEvidence.ts)

    /// `timesheetEntryEvidenceWriteFields(evidence)`: the stored evidence list of one entry. Nil when the script did
    /// not answer.
    nonisolated static func timesheetEntryEvidenceWriteFields(_ evidence: [PayeClaimEvidence]) -> [[String: Any]]? {
        callJSON("timesheetEntryEvidenceWriteFields", arguments: [evidence.map(\.json)]) as? [[String: Any]]
    }

    /// `timesheetEvidenceOwnerIds(sheetDocId, { userId }, extra)`: whose claim folder the sheet's evidence may come from.
    nonisolated static func timesheetEvidenceOwnerIds(sheetDocumentId: String, userId: String?, extra: [String]) -> [String] {
        let sheet: [String: Any] = ["userId": RulebookJSON.orNull(userId)]
        if let ids = callJSON("timesheetEvidenceOwnerIds", arguments: [sheetDocumentId, sheet, extra]) as? [String] { return ids }
        return ([userId].compactMap { $0 } + extra).filter { !$0.isEmpty }
    }

    /// `timesheetOwnerEntriesError({ previous, next, organizationId, ownerUserIds })`: nil when the owner's save may go
    /// ahead, else the first message (price work job number, an expense's evidence, the evidence folder). Entries are the
    /// stored shape. Only the entries the owner added or changed are checked.
    nonisolated static func timesheetOwnerEntriesError(
        previous: (priceWork: [Any], expenses: [Any])?,
        next: (priceWork: [Any], expenses: [Any]),
        organizationId: String?,
        ownerUserIds: [String]
    ) -> String? {
        var input: [String: Any] = [
            "next": [
                "priceWorkEntries": FirebaseBackend.firestoreJSON(next.priceWork),
                "expenseEntries": FirebaseBackend.firestoreJSON(next.expenses),
            ] as [String: Any],
            "organizationId": RulebookJSON.orNull(organizationId),
            "ownerUserIds": ownerUserIds,
        ]
        if let previous {
            input["previous"] = [
                "priceWorkEntries": FirebaseBackend.firestoreJSON(previous.priceWork),
                "expenseEntries": FirebaseBackend.firestoreJSON(previous.expenses),
            ] as [String: Any]
        } else {
            input["previous"] = NSNull()
        }
        let answer = callJSON("timesheetOwnerEntriesError", arguments: [input])
        if let message = answer as? String { return message }
        return answer == nil ? "The rulebook did not answer. Try again." : nil
    }

    /// `canEditTimesheetEntry(sheet, { viewerIsOwner, selfSigned })`: only the owner, and only while they may add one.
    nonisolated static func canEditTimesheetEntry(
        managerSignedAt: Date?,
        approvedAt: Date?,
        viewerIsOwner: Bool,
        selfSigned: Bool
    ) -> RulebookTimesheetExtrasPermission {
        let sheet: [String: Any] = [
            "managerSignedAt": managerSignedAt.map { $0.timeIntervalSince1970 * 1000 as Any } ?? NSNull(),
            "approvedAt": approvedAt.map { $0.timeIntervalSince1970 * 1000 as Any } ?? NSNull(),
        ]
        return RulebookTimesheetExtrasPermission(
            json: callJSON("canEditTimesheetEntry", arguments: [sheet, ["viewerIsOwner": viewerIsOwner, "selfSigned": selfSigned]])
        ) ?? RulebookTimesheetExtrasPermission(allowed: false, message: nil)
    }

    /// `timesheetEntryEvidenceToDelete({ before, after, organizationId, viewerUserId, nowMs })`: the files a save removed
    /// that are deleted (the viewer's own, inside the §24 undo window); every other file is kept for recovery.
    nonisolated static func timesheetEntryEvidenceToDelete(
        before: [PayeClaimEvidence],
        after: [PayeClaimEvidence],
        organizationId: String,
        viewerUserId: String,
        nowMs: Double = Date().timeIntervalSince1970 * 1000
    ) -> [String] {
        // One flat list per side is the same input as the entry arrays (the rule unions every entry's evidence).
        let input: [String: Any] = [
            "before": ["priceWorkEntries": [["evidence": before.map(\.json)]], "expenseEntries": []] as [String: Any],
            "after": ["priceWorkEntries": [["evidence": after.map(\.json)]], "expenseEntries": []] as [String: Any],
            "organizationId": organizationId,
            "viewerUserId": viewerUserId,
            "nowMs": nowMs,
        ]
        return callJSON("timesheetEntryEvidenceToDelete", arguments: [input]) as? [String] ?? []
    }

    /// `timesheetEvidencePages({ rows, entries, currency })`: one page per piece of evidence on the invoice's price work
    /// and expense rows, in invoice order. `rows` are `timesheetInvoiceRows` rows (`kind`, `id`, `amount`, `jobNumber`);
    /// `entries` is the `parseTimesheetEntries` answer.
    nonisolated static func timesheetEvidencePages(
        rows: [[String: Any]],
        entries: [String: Any],
        currency: String
    ) -> [PayeClaimEvidencePage] {
        let input: [String: Any] = ["rows": rows, "entries": entries, "currency": currency]
        return RulebookJSON.decode([PayeClaimEvidencePage].self, from: callJSON("timesheetEvidencePages", arguments: [input])) ?? []
    }

    // MARK: PAYE items (payeClaims.ts 1.45.0)

    /// `canEditPayeClaim(viewerId, item)`: only the person edits or deletes their own item.
    nonisolated static func canEditPayeClaim(viewerId: String, item: PayeClaimItem) -> Bool {
        guard let json = RulebookJSON.object(item) else { return false }
        return callJSON("canEditPayeClaim", arguments: [viewerId, json]) as? Bool ?? false
    }

    /// `payeClaimEditDraft(item)`: the draft a saved item opens with (the Add sheet's shape).
    nonisolated static func payeClaimEditDraft(_ item: PayeClaimItem) -> [String: Any]? {
        guard let json = RulebookJSON.object(item) else { return nil }
        return callJSON("payeClaimEditDraft", arguments: [json]) as? [String: Any]
    }

    /// `priceWorkUpdateWriteFields({ item, userId, draft, person, roster, organizationId })`: the changed fields of an
    /// edit, or nil when refused.
    nonisolated static func priceWorkUpdateWriteFields(
        item: PayeClaimItem,
        userId: String,
        draft: [String: Any],
        person: [String: Any],
        roster: [[String: Any]],
        organizationId: String
    ) -> PayeClaimUpdateWrite? {
        guard let json = RulebookJSON.object(item) else { return nil }
        let input: [String: Any] = [
            "item": json, "userId": userId, "draft": draft, "person": person, "roster": roster, "organizationId": organizationId,
        ]
        return updateWrite(callJSON("priceWorkUpdateWriteFields", arguments: [input]))
    }

    /// `expenseUpdateWriteFields({ item, userId, draft, organizationId })`: the changed fields of an edit, or nil.
    nonisolated static func expenseUpdateWriteFields(
        item: PayeClaimItem,
        userId: String,
        draft: [String: Any],
        organizationId: String
    ) -> PayeClaimUpdateWrite? {
        guard let json = RulebookJSON.object(item) else { return nil }
        let input: [String: Any] = ["item": json, "userId": userId, "draft": draft, "organizationId": organizationId]
        return updateWrite(callJSON("expenseUpdateWriteFields", arguments: [input]))
    }

    nonisolated private static func updateWrite(_ value: Any?) -> PayeClaimUpdateWrite? {
        guard let object = value as? [String: Any] else { return nil }
        return PayeClaimUpdateWrite(
            set: object["set"] as? [String: Any] ?? [:],
            remove: object["remove"] as? [String] ?? []
        )
    }
}
