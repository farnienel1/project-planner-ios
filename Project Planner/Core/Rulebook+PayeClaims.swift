//
//  Rulebook+PayeClaims.swift
//  Project Planner
//
//  RULEBOOK 1.30.0 §26 (PAYE price work, expenses, personal site audits and their reports), §24 (claim evidence and
//  personal audit files): typed wrappers for web `lib/canonical/payeClaims.ts` and `lib/canonical/personalSiteAudits.ts`,
//  called through `CanonicalBusinessEngine.callJSON`. Every validation message, write shape, reader, range, total,
//  permission, report row and evidence rule comes from the packed script; Swift only builds the inputs and reads the
//  answers. Nothing is decided here.
//  RULEBOOK 1.32.0 §26 (`payeClaimReviews.ts`): the review — `canReviewPayeClaims`, `payeClaimFingerprint`,
//  `parsePayeClaimReviewDocument`, `payeClaimReviewState`, `payeClaimReviewWrites`, `payeClaimReviewOutcomeLabel`.
//

import Foundation

// MARK: - Types (the script's shapes)

/// `PayeClaimEvidence`: a file in the person's own claim folder (`payeClaims/{userId}/…`).
nonisolated struct PayeClaimEvidence: Codable, Hashable, Sendable, Identifiable {
    var path: String
    var name: String
    /// `file` | `photo` | `personalSiteAudit`.
    var kind: String
    var contentType: String?
    var auditId: String?

    var id: String { path }

    /// The script argument (missing optional values are JSON null).
    var json: [String: Any] {
        [
            "path": path,
            "name": name,
            "kind": kind,
            "contentType": contentType ?? "",
            "auditId": RulebookJSON.orNull(auditId),
        ]
    }
}

/// `PriceWorkItem` / `ExpenseItem` in one shape: `kind` is `priceWork` or `expense`; the other kind's fields are nil.
nonisolated struct PayeClaimItem: Codable, Hashable, Sendable, Identifiable {
    var id: String
    var kind: String
    var userId: String
    var title: String
    var details: String
    var amount: Double
    var currency: String
    var evidence: [PayeClaimEvidence]
    var createdAtMs: Double?
    var createdBy: String
    // Price work
    var startDate: String?
    var endDate: String?
    var approvedByUserId: String?
    var approvedByName: String?
    // Expense
    var jobNumber: String?
    var date: String?
    /// 1.33.0 (`payeClaimPersonFields`): the person's current users id, written on create; nil when not stored.
    var personUserId: String?
}

/// `TimesheetClaimRow`: a self-employed person's price work or expense entry from their timesheets, read-only.
nonisolated struct TimesheetClaimRow: Codable, Hashable, Sendable, Identifiable {
    var id: String
    var sheetId: String
    var kind: String
    var title: String
    var details: String
    var jobNumber: String
    var amount: Double
    var startDate: String
    var endDate: String
    var approvedByName: String
    var receiptName: String?
    var managerDecision: String
}

/// `PayeClaimReportItem`.
nonisolated struct PayeClaimReportItem: Codable, Hashable, Sendable {
    var id: String
    var title: String
    var details: String
    var jobNumber: String
    var startDate: String
    var endDate: String
    var approvedByName: String
    var amount: Double
    var evidence: [PayeClaimEvidence]
}

/// `parsePayeClaimReportDocument` (a saved report copy, written once).
nonisolated struct PayeClaimReportRecord: Codable, Hashable, Sendable, Identifiable {
    nonisolated struct Totals: Codable, Hashable, Sendable {
        var amount: Double
        var itemCount: Int
        var evidenceCount: Int
    }

    var id: String
    var userId: String
    var userName: String
    var companyName: String
    var kind: String
    var rangeStart: String
    var rangeEnd: String
    var currency: String
    var items: [PayeClaimReportItem]
    var totals: Totals
    var generatedBy: String
    var generatedAtMs: Double?
}

/// `payeClaimReportRows`: the summary page. 1.33.0 (laid out like the invoice report): the header (`documentTitle`,
/// `companyName`, `personName`, `period`, `generated` from `reportGeneratedText`), `columns`, each row's columns,
/// `totalLabel` / `totalAmount`, `itemCount` / `evidenceCount` and `footer`.
nonisolated struct PayeClaimReportRows: Codable, Hashable, Sendable {
    nonisolated struct Row: Codable, Hashable, Sendable {
        var heading: String
        var figure: String
        var lines: [String]
        var itemId: String
        /// `formatPaymentRunDay` of the day, or "from – to" for price work over several days.
        var date: String
        /// Price work: `priceWorkJobNumberText` ("—" before 1.30.1). Expense: as stored.
        var jobNumber: String
        var name: String
        /// Price work only.
        var approvedBy: String
        /// `formatMoney` in the report's currency.
        var amount: String
        var description: String
        /// "Evidence: 2 (a.jpg, b.pdf)", or "".
        var evidenceNote: String
    }

    var title: String
    var subtitle: String
    var rows: [Row]
    var total: String
    var empty: String
    var documentTitle: String
    var companyName: String
    var personName: String
    var period: String
    var generatedAt: String
    var generatedBy: String
    var generated: String
    var columns: [String]
    var totalLabel: String
    var totalAmount: String
    var itemCount: Int
    var evidenceCount: Int
    var footer: String
}

/// One `payeClaimEvidencePages` entry: an evidence page after the summary, headed by its item (1.33.0 fields).
nonisolated struct PayeClaimEvidencePage: Codable, Hashable, Sendable {
    var itemId: String
    var heading: String
    var details: [String]
    var path: String
    var name: String
    var contentType: String
    /// `image` | `pdf` | `listed`.
    var drawAs: String
    var itemName: String
    var date: String
    var jobNumber: String
    /// Price work only.
    var approvedBy: String
    var amount: String
    /// "Evidence 2 of 3: receipt.jpg".
    var evidenceTitle: String
    /// The item's description, when it has one.
    var notes: [String]
}

/// `payeClaimListRow`.
nonisolated struct PayeClaimListRow: Codable, Hashable, Sendable {
    var title: String
    var figure: String
    var subtitle: String
}

/// `priceWorkApproverCandidates` row (`LineManagerCandidate`).
nonisolated struct PriceWorkApproverCandidate: Codable, Hashable, Sendable, Identifiable {
    var id: String
    var name: String
    var level: String
}

/// `PersonalSiteAuditItem`.
nonisolated struct PersonalSiteAuditItem: Codable, Hashable, Sendable, Identifiable {
    var id: String
    var title: String
    var location: String
    var comments: String
    var assignee: String
    var annotations: String
    var imagePath: String
    var takenAtMs: Double?
}

/// `parsePersonalSiteAuditDocument` (owner only).
nonisolated struct PersonalSiteAudit: Codable, Hashable, Sendable, Identifiable {
    var id: String
    var ownerUserId: String
    var jobNumber: String
    var jobName: String
    var type: String
    var customTitle: String
    var date: String
    var authorName: String
    var items: [PersonalSiteAuditItem]
    var createdAtMs: Double?
}

/// `personalSiteAuditPdfRows`: the frozen copy's text.
nonisolated struct PersonalSiteAuditPdfRows: Codable, Hashable, Sendable {
    nonisolated struct Item: Codable, Hashable, Sendable {
        var heading: String
        var lines: [String]
        var imagePath: String
    }

    var title: String
    var lines: [String]
    var items: [Item]
}

/// `parsePayeClaimReviewDocument` (1.32.0): one review per item, `payeClaimReviews/{kind}_{itemId}`.
nonisolated struct PayeClaimReviewRecord: Codable, Hashable, Sendable, Identifiable {
    var id: String
    var userId: String
    var itemId: String
    /// `priceWork` | `expense`.
    var kind: String
    /// `approved` | `rejected`.
    var decision: String
    var fingerprint: String
    var reviewedBy: String?
    var reviewedAtMs: Double?
    /// 1.33.0: the person's current users id, stored only when the item is filed under another of their ids.
    var personUserId: String?
}

/// `payeClaimReviewState(item, reviews)`: `needsReview` | `approved` | `rejected`, its label, and the review it came from.
nonisolated struct PayeClaimReviewStateResult: Codable, Hashable, Sendable {
    var state: String
    var label: String
    var review: PayeClaimReviewRecord?
}

/// One `payeClaimReviewWrites` write: the document id and the rulebook's fields (the app adds `reviewedAt` and metadata).
nonisolated struct PayeClaimReviewWrite: @unchecked Sendable {
    var docId: String
    var fields: [String: Any]
}

/// `payeClaimReviewWrites(...)`: the writes, the per-item outcome (`applied` | `undecided` | `foreign` | `unchanged`;
/// 1.33.0 no `needsAdmin`), the counts and the `reviewApprovalMessage`.
nonisolated struct PayeClaimReviewPlan: @unchecked Sendable {
    var writes: [PayeClaimReviewWrite]
    var outcomes: [String: String]
    var approved: Int
    var rejected: Int
    var message: String
}

/// The two claim kinds (`PAYE_CLAIM_KINDS`); the raw value is the script's.
nonisolated enum PayeClaimKind: String, CaseIterable, Hashable, Sendable {
    case priceWork
    case expense

    /// `PRICE_WORK_ITEMS_COLLECTION` / `EXPENSE_ITEMS_COLLECTION`.
    var collection: String {
        switch self {
        case .priceWork: return CanonicalBusinessEngine.payeClaimText("PRICE_WORK_ITEMS_COLLECTION", fallback: "priceWorkItems")
        case .expense: return CanonicalBusinessEngine.payeClaimText("EXPENSE_ITEMS_COLLECTION", fallback: "expenseItems")
        }
    }

    var sectionTitle: String { self == .priceWork ? "Price work" : "Expenses" }

    var addLabel: String {
        self == .priceWork
            ? CanonicalBusinessEngine.payeClaimText("PRICE_WORK_ADD_LABEL", fallback: "Add Price Work")
            : CanonicalBusinessEngine.payeClaimText("EXPENSE_ADD_LABEL", fallback: "Add Expense")
    }

    var generateReportLabel: String {
        self == .priceWork
            ? CanonicalBusinessEngine.payeClaimText("PRICE_WORK_GENERATE_REPORT_LABEL", fallback: "Generate price work report")
            : CanonicalBusinessEngine.payeClaimText("EXPENSES_GENERATE_REPORT_LABEL", fallback: "Generate expenses report")
    }

    var emptyMessage: String {
        self == .priceWork
            ? CanonicalBusinessEngine.payeClaimText("PRICE_WORK_EMPTY_MESSAGE", fallback: "No price work in this range.")
            : CanonicalBusinessEngine.payeClaimText("EXPENSES_EMPTY_MESSAGE", fallback: "No expenses in this range.")
    }
}

// MARK: - Wrappers

extension CanonicalBusinessEngine {
    /// A string constant of `payeClaims.ts` / `personalSiteAudits.ts`, or `fallback` when the script did not answer.
    nonisolated static func payeClaimText(_ name: String, fallback: String) -> String {
        constant(name, as: String.self) ?? fallback
    }

    /// `PAYE_CLAIM_EVIDENCE_MAX` (20).
    nonisolated static var payeClaimEvidenceMax: Int {
        constant("PAYE_CLAIM_EVIDENCE_MAX", as: Int.self) ?? 20
    }

    /// `PERSONAL_SITE_AUDIT_PRIVACY_NOTICE`: the privacy policy sentence (legal pack version unchanged).
    nonisolated static var personalSiteAuditPrivacyNotice: String {
        payeClaimText(
            "PERSONAL_SITE_AUDIT_PRIVACY_NOTICE",
            fallback: "Personal site audits are private to the person who created them. A copy attached to an expense or price work item is visible to that person’s line managers and admins, and is kept for recovery if the item is later removed."
        )
    }

    // MARK: Price work job number (1.30.1, `priceWorkJobNumber.ts`)

    /// `PRICE_WORK_JOB_NUMBER_MAX` (60).
    nonisolated static var priceWorkJobNumberMax: Int {
        constant("PRICE_WORK_JOB_NUMBER_MAX", as: Int.self) ?? 60
    }

    /// `priceWorkJobNumberError(value)`: nil when the job number is usable (trimmed, 1–60), else the message.
    nonisolated static func priceWorkJobNumberError(_ value: String) -> String? {
        let answer = callJSON("priceWorkJobNumberError", arguments: [value])
        if let message = answer as? String { return message }
        return answer == nil ? "The rulebook did not answer. Try again." : nil
    }

    /// `priceWorkJobNumberText(value)`: the stored job number, or "—" for price work stored before 1.30.1.
    nonisolated static func priceWorkJobNumberText(_ value: String?) -> String {
        if let text = callJSON("priceWorkJobNumberText", arguments: [RulebookJSON.orNull(value)]) as? String { return text }
        let trimmed = (value ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "—" : trimmed
    }

    /// `timesheetPriceWorkJobNumberError(previous, next)`: the owner's added or edited timesheet price work entries need
    /// a job number; untouched entries never block. Entries are the stored shape (JSON: dates as ms or ISO). Nil when
    /// the save may go ahead, and also when the script did not answer (an older script never blocks a save).
    nonisolated static func timesheetPriceWorkJobNumberError(previous: [Any], next: [Any]) -> String? {
        let before = FirebaseBackend.firestoreJSON(previous)
        let after = FirebaseBackend.firestoreJSON(next)
        return callJSON("timesheetPriceWorkJobNumberError", arguments: [before, after]) as? String
    }

    // MARK: Evidence

    /// `payeClaimEvidencePath({ organizationId, userId, unixMs, extension })`. Nil when an id is unusable.
    nonisolated static func payeClaimEvidencePath(organizationId: String, userId: String, unixMs: Int64, fileExtension: String) -> String? {
        let input: [String: Any] = ["organizationId": organizationId, "userId": userId, "unixMs": unixMs, "extension": fileExtension]
        return callJSON("payeClaimEvidencePath", arguments: [input]) as? String
    }

    /// `payeClaimEvidencePathBelongsTo(path, organizationId, userId)`.
    nonisolated static func payeClaimEvidencePathBelongsTo(_ path: String, organizationId: String, userId: String) -> Bool {
        callJSON("payeClaimEvidencePathBelongsTo", arguments: [path, organizationId, userId]) as? Bool ?? false
    }

    /// `parsePayeClaimEvidence(value, owner)`: only the owner's own claim files when `owner` is given.
    nonisolated static func parsePayeClaimEvidence(_ value: Any, ownerUserId: String?, organizationId: String?) -> [PayeClaimEvidence] {
        var arguments: [Any] = [FirebaseBackend.firestoreJSON(value)]
        if let ownerUserId {
            arguments.append(["userId": ownerUserId, "organizationId": RulebookJSON.orNull(organizationId)] as [String: Any])
        }
        return RulebookJSON.decode([PayeClaimEvidence].self, from: callJSON("parsePayeClaimEvidence", arguments: arguments)) ?? []
    }

    /// `payeClaimEvidenceDrawAs(entry)` → `image` | `pdf` | `listed`.
    nonisolated static func payeClaimEvidenceDrawAs(_ entry: PayeClaimEvidence) -> String {
        callJSON("payeClaimEvidenceDrawAs", arguments: [entry.json]) as? String ?? "listed"
    }

    /// `payeClaimEvidenceToDelete(evidence, { organizationId, viewerUserId, nowMs })`: the just-uploaded files (inside the
    /// §24 undo window) that are deleted; every other file is kept for recovery.
    nonisolated static func payeClaimEvidenceToDelete(
        _ evidence: [PayeClaimEvidence],
        organizationId: String,
        viewerUserId: String,
        nowMs: Double = Date().timeIntervalSince1970 * 1000
    ) -> [String] {
        let input: [String: Any] = ["organizationId": organizationId, "viewerUserId": viewerUserId, "nowMs": nowMs]
        return callJSON("payeClaimEvidenceToDelete", arguments: [evidence.map(\.json), input]) as? [String] ?? []
    }

    // MARK: Approvers, validation and write fields

    /// `priceWorkApproverCandidates(person, roster, { organizationId })`: the active admins and managers of this
    /// organisation, never an operative or the person. Empty when the script did not answer.
    nonisolated static func priceWorkApproverCandidates(
        person: [String: Any],
        roster: [[String: Any]],
        organizationId: String
    ) -> [PriceWorkApproverCandidate] {
        RulebookJSON.decode(
            [PriceWorkApproverCandidate].self,
            from: callJSON("priceWorkApproverCandidates", arguments: [person, roster, ["organizationId": organizationId]])
        ) ?? []
    }

    /// `priceWorkValidationError(draft, { person, roster, organizationId })`. Nil when the draft can be added.
    nonisolated static func priceWorkValidationError(
        draft: [String: Any],
        person: [String: Any],
        roster: [[String: Any]],
        organizationId: String?
    ) -> String? {
        let context: [String: Any] = ["person": person, "roster": roster, "organizationId": RulebookJSON.orNull(organizationId)]
        let answer = callJSON("priceWorkValidationError", arguments: [draft, context])
        if let message = answer as? String { return message }
        return answer == nil ? "The rulebook did not answer. Try again." : nil
    }

    /// `expenseValidationError(draft, { organizationId, userId })`. Nil when the draft can be added.
    nonisolated static func expenseValidationError(draft: [String: Any], organizationId: String?, userId: String?) -> String? {
        var arguments: [Any] = [draft]
        if organizationId != nil || userId != nil {
            arguments.append(["organizationId": RulebookJSON.orNull(organizationId), "userId": RulebookJSON.orNull(userId)] as [String: Any])
        }
        let answer = callJSON("expenseValidationError", arguments: arguments)
        if let message = answer as? String { return message }
        return answer == nil ? "The rulebook did not answer. Try again." : nil
    }

    /// `priceWorkWriteFields({ userId, draft, person, roster, currency, organizationId })`: the create fields, or nil when
    /// refused. The app adds `createdAt` and the write metadata.
    nonisolated static func priceWorkWriteFields(
        userId: String,
        draft: [String: Any],
        person: [String: Any],
        roster: [[String: Any]],
        currency: String,
        organizationId: String
    ) -> [String: Any]? {
        let input: [String: Any] = [
            "userId": userId, "draft": draft, "person": person, "roster": roster,
            "currency": currency, "organizationId": organizationId,
        ]
        return callJSON("priceWorkWriteFields", arguments: [input]) as? [String: Any]
    }

    /// `expenseWriteFields({ userId, draft, currency, organizationId })`: the create fields, or nil when refused.
    nonisolated static func expenseWriteFields(userId: String, draft: [String: Any], currency: String, organizationId: String) -> [String: Any]? {
        let input: [String: Any] = ["userId": userId, "draft": draft, "currency": currency, "organizationId": organizationId]
        return callJSON("expenseWriteFields", arguments: [input]) as? [String: Any]
    }

    // MARK: Readers

    /// `parsePriceWorkDocument(docId, data, { timeZone, organizationId })` / `parseExpenseDocument(...)`.
    nonisolated static func parsePayeClaimDocument(
        kind: PayeClaimKind,
        docId: String,
        data: [String: Any],
        organizationId: String?,
        timeZone: String = OrganizationRulebookContext.timeZoneIdentifier
    ) -> PayeClaimItem? {
        let function = kind == .priceWork ? "parsePriceWorkDocument" : "parseExpenseDocument"
        let options: [String: Any] = ["timeZone": timeZone, "organizationId": RulebookJSON.orNull(organizationId)]
        let json = FirebaseBackend.firestoreJSON(data) as? [String: Any] ?? [:]
        return RulebookJSON.decode(PayeClaimItem.self, from: callJSON(function, arguments: [docId, json, options]))
    }

    /// `parsePayeClaimReportDocument(docId, data)`.
    nonisolated static func parsePayeClaimReportDocument(docId: String, data: [String: Any]) -> PayeClaimReportRecord? {
        let json = FirebaseBackend.firestoreJSON(data) as? [String: Any] ?? [:]
        return RulebookJSON.decode(PayeClaimReportRecord.self, from: callJSON("parsePayeClaimReportDocument", arguments: [docId, json]))
    }

    // MARK: Ranges, totals, rows

    /// `payeClaimsInRange(items, range)`: oldest first; expenses by date, price work by overlap.
    nonisolated static func payeClaimsInRange(_ items: [PayeClaimItem], start: String, end: String) -> [PayeClaimItem] {
        guard let list = RulebookJSON.object(items) else { return [] }
        return RulebookJSON.decode(
            [PayeClaimItem].self,
            from: callJSON("payeClaimsInRange", arguments: [list, ["start": start, "end": end]])
        ) ?? []
    }

    /// `payeClaimsTotal(items)`: the amounts summed to the penny.
    nonisolated static func payeClaimsTotal(amounts: [Double]) -> Double {
        let rows = amounts.map { ["amount": $0] }
        return (callJSON("payeClaimsTotal", arguments: [rows]) as? NSNumber)?.doubleValue ?? 0
    }

    /// `payeClaimReportReady(items)`: Generate report is enabled (green) once one item is in the range.
    nonisolated static func payeClaimReportReady(itemCount: Int) -> Bool {
        let rows = Array(repeating: [String: Any](), count: max(0, itemCount))
        return callJSON("payeClaimReportReady", arguments: [rows]) as? Bool ?? false
    }

    /// `payeClaimListRow(item, currency)`.
    nonisolated static func payeClaimListRow(_ item: PayeClaimItem, currency: String) -> PayeClaimListRow? {
        guard let json = RulebookJSON.object(item) else { return nil }
        return RulebookJSON.decode(PayeClaimListRow.self, from: callJSON("payeClaimListRow", arguments: [json, currency]))
    }

    // MARK: Who sees what

    /// `canViewPayeClaims(viewer, subject, roster)`: the person, their active line managers and active admins.
    nonisolated static func canViewPayeClaims(viewer: [String: Any], subject: [String: Any], roster: [[String: Any]]) -> Bool {
        callJSON("canViewPayeClaims", arguments: [viewer, subject, roster]) as? Bool ?? false
    }

    /// `canWritePayeClaim(viewerId, item)`: only the person writes their own items.
    nonisolated static func canWritePayeClaim(viewerId: String, itemUserId: String) -> Bool {
        callJSON("canWritePayeClaim", arguments: [viewerId, ["userId": itemUserId]]) as? Bool ?? false
    }

    // MARK: Review (1.32.0, `payeClaimReviews.ts`)

    /// `PAYE_CLAIM_REVIEWS_COLLECTION`.
    nonisolated static var payeClaimReviewsCollection: String {
        payeClaimText("PAYE_CLAIM_REVIEWS_COLLECTION", fallback: "payeClaimReviews")
    }

    /// `canReviewPayeClaims(viewer, subject, roster)`: the person's active line managers and active admins outside
    /// operative mode, never the person under any of their ids.
    nonisolated static func canReviewPayeClaims(viewer: [String: Any], subject: [String: Any], roster: [[String: Any]]) -> Bool {
        callJSON("canReviewPayeClaims", arguments: [viewer, subject, roster]) as? Bool ?? false
    }

    /// `payeClaimFingerprint(item)`: kind, name, job number, dates, figure, currency and evidence count. Empty when the
    /// script did not answer.
    nonisolated static func payeClaimFingerprint(_ item: PayeClaimItem) -> String {
        guard let json = RulebookJSON.object(item) else { return "" }
        return callJSON("payeClaimFingerprint", arguments: [json]) as? String ?? ""
    }

    /// `parsePayeClaimReviewDocument(docId, data)`: never refuses a document (an unknown decision reads as rejected).
    nonisolated static func parsePayeClaimReviewDocument(docId: String, data: [String: Any]) -> PayeClaimReviewRecord? {
        let json = FirebaseBackend.firestoreJSON(data) as? [String: Any] ?? [:]
        return RulebookJSON.decode(PayeClaimReviewRecord.self, from: callJSON("parsePayeClaimReviewDocument", arguments: [docId, json]))
    }

    /// `payeClaimReviewState(item, reviews)`: the review at the item's current fingerprint, else Needs review.
    nonisolated static func payeClaimReviewState(_ item: PayeClaimItem, reviews: [PayeClaimReviewRecord]) -> PayeClaimReviewStateResult? {
        guard let json = RulebookJSON.object(item), let list = RulebookJSON.object(reviews) else { return nil }
        return RulebookJSON.decode(PayeClaimReviewStateResult.self, from: callJSON("payeClaimReviewState", arguments: [json, list]))
    }

    /// `payeClaimReviewWrites({ items, decisions, reviews, subjectUserId, personIds, reviewerId })`: Approve's review
    /// writes (one per decided item) and the "Approved X of Y" message. 1.33.0: a line manager and an admin write the
    /// same reviews (no `reviewerIsAdmin`, no "Needs an admin"); an item filed under another of the person's ids gets
    /// `personUserId: subjectUserId` in its review fields. `decisions` maps an item id to `approved` | `rejected`. Nil
    /// when the script did not answer.
    nonisolated static func payeClaimReviewWrites(
        items: [PayeClaimItem],
        decisions: [String: String],
        reviews: [PayeClaimReviewRecord],
        subjectUserId: String,
        personIds: [String],
        reviewerId: String
    ) -> PayeClaimReviewPlan? {
        guard let itemList = RulebookJSON.object(items), let reviewList = RulebookJSON.object(reviews) else { return nil }
        let input: [String: Any] = [
            "items": itemList, "decisions": decisions, "reviews": reviewList, "subjectUserId": subjectUserId,
            "personIds": personIds, "reviewerId": reviewerId,
        ]
        guard let answer = callJSON("payeClaimReviewWrites", arguments: [input]) as? [String: Any] else { return nil }
        let writes = (answer["writes"] as? [[String: Any]] ?? []).compactMap { row -> PayeClaimReviewWrite? in
            guard let docId = row["docId"] as? String, let fields = row["fields"] as? [String: Any] else { return nil }
            return PayeClaimReviewWrite(docId: docId, fields: fields)
        }
        return PayeClaimReviewPlan(
            writes: writes,
            outcomes: answer["outcomes"] as? [String: String] ?? [:],
            approved: (answer["approved"] as? NSNumber)?.intValue ?? 0,
            rejected: (answer["rejected"] as? NSNumber)?.intValue ?? 0,
            message: answer["message"] as? String ?? ""
        )
    }

    /// `payeClaimReviewOutcomeLabel(outcome)`: "Not theirs — left out.", else nil (1.33.0: no "Needs an admin").
    nonisolated static func payeClaimReviewOutcomeLabel(_ outcome: String?) -> String? {
        callJSON("payeClaimReviewOutcomeLabel", arguments: [RulebookJSON.orNull(outcome)]) as? String
    }

    /// `timesheetClaimRows(sheets, kind, range)`: `sheets` are `{ id, entries }` with `entries` from
    /// `parseTimesheetEntries`.
    nonisolated static func timesheetClaimRows(sheets: [[String: Any]], kind: PayeClaimKind, start: String, end: String) -> [TimesheetClaimRow] {
        RulebookJSON.decode(
            [TimesheetClaimRow].self,
            from: callJSON("timesheetClaimRows", arguments: [sheets, kind.rawValue, ["start": start, "end": end]])
        ) ?? []
    }

    // MARK: Reports

    /// `payeClaimReportSnapshot({ kind, userId, userName, companyName, currency, rangeStart, rangeEnd, items, generatedBy })`:
    /// the copy saved to `payeClaimReports/{id}`. The app adds `generatedAt`.
    nonisolated static func payeClaimReportSnapshot(
        kind: PayeClaimKind,
        userId: String,
        userName: String,
        companyName: String,
        currency: String,
        rangeStart: String,
        rangeEnd: String,
        items: [PayeClaimItem],
        generatedBy: String
    ) -> [String: Any]? {
        guard let list = RulebookJSON.object(items) else { return nil }
        let input: [String: Any] = [
            "kind": kind.rawValue, "userId": userId, "userName": userName, "companyName": companyName,
            "currency": currency, "rangeStart": rangeStart, "rangeEnd": rangeEnd, "items": list, "generatedBy": generatedBy,
        ]
        return callJSON("payeClaimReportSnapshot", arguments: [input]) as? [String: Any]
    }

    /// `payeClaimReportRows(snapshot, { timeZone, generatedByName, nowMs })` (1.33.0: header, columns, rows, totals,
    /// footer; generated by / at in the organisation zone).
    nonisolated static func payeClaimReportRows(
        _ report: PayeClaimReportRecord,
        generatedByName: String? = nil,
        now: Date = Date()
    ) -> PayeClaimReportRows? {
        guard let json = RulebookJSON.object(report) else { return nil }
        let options: [String: Any] = [
            "timeZone": OrganizationRulebookContext.timeZoneIdentifier,
            "generatedByName": RulebookJSON.orNull(generatedByName),
            "nowMs": now.timeIntervalSince1970 * 1000,
        ]
        return RulebookJSON.decode(PayeClaimReportRows.self, from: callJSON("payeClaimReportRows", arguments: [json, options]))
    }

    /// `payeClaimEvidencePages(snapshot)`: one page per piece of evidence, in item order.
    nonisolated static func payeClaimEvidencePages(_ report: PayeClaimReportRecord) -> [PayeClaimEvidencePage] {
        guard let json = RulebookJSON.object(report) else { return [] }
        return RulebookJSON.decode([PayeClaimEvidencePage].self, from: callJSON("payeClaimEvidencePages", arguments: [json])) ?? []
    }

    /// `payeClaimReportsOfKind(reports, kind)`: newest first.
    nonisolated static func payeClaimReportsOfKind(_ reports: [PayeClaimReportRecord], kind: PayeClaimKind) -> [PayeClaimReportRecord] {
        guard let list = RulebookJSON.object(reports) else { return [] }
        return RulebookJSON.decode(
            [PayeClaimReportRecord].self,
            from: callJSON("payeClaimReportsOfKind", arguments: [list, kind.rawValue])
        ) ?? []
    }

    // MARK: Personal site audits

    /// `personalSiteAuditImagePath({ organizationId, ownerUserId, auditId, unixMs, extension })`.
    nonisolated static func personalSiteAuditImagePath(
        organizationId: String,
        ownerUserId: String,
        auditId: String,
        unixMs: Int64,
        fileExtension: String
    ) -> String? {
        let input: [String: Any] = [
            "organizationId": organizationId, "ownerUserId": ownerUserId, "auditId": auditId,
            "unixMs": unixMs, "extension": fileExtension,
        ]
        return callJSON("personalSiteAuditImagePath", arguments: [input]) as? String
    }

    /// `canViewPersonalSiteAudit(viewerUserId, audit)`: the owner only.
    nonisolated static func canViewPersonalSiteAudit(viewerUserId: String, ownerUserId: String) -> Bool {
        callJSON("canViewPersonalSiteAudit", arguments: [viewerUserId, ["ownerUserId": ownerUserId]]) as? Bool ?? false
    }

    /// `personalSiteAuditValidationError(draft, { organizationId, ownerUserId })`. Nil when the audit can be saved.
    nonisolated static func personalSiteAuditValidationError(draft: [String: Any], organizationId: String?, ownerUserId: String?) -> String? {
        var arguments: [Any] = [draft]
        if organizationId != nil || ownerUserId != nil {
            arguments.append(["organizationId": RulebookJSON.orNull(organizationId), "ownerUserId": RulebookJSON.orNull(ownerUserId)] as [String: Any])
        }
        let answer = callJSON("personalSiteAuditValidationError", arguments: arguments)
        if let message = answer as? String { return message }
        return answer == nil ? "The rulebook did not answer. Try again." : nil
    }

    /// `personalSiteAuditWriteFields({ ownerUserId, draft, organizationId })`: the create fields, or nil when refused.
    nonisolated static func personalSiteAuditWriteFields(ownerUserId: String, draft: [String: Any], organizationId: String) -> [String: Any]? {
        let input: [String: Any] = ["ownerUserId": ownerUserId, "draft": draft, "organizationId": organizationId]
        return callJSON("personalSiteAuditWriteFields", arguments: [input]) as? [String: Any]
    }

    /// `parsePersonalSiteAuditDocument(docId, data, { timeZone })`.
    nonisolated static func parsePersonalSiteAuditDocument(
        docId: String,
        data: [String: Any],
        timeZone: String = OrganizationRulebookContext.timeZoneIdentifier
    ) -> PersonalSiteAudit? {
        let json = FirebaseBackend.firestoreJSON(data) as? [String: Any] ?? [:]
        return RulebookJSON.decode(
            PersonalSiteAudit.self,
            from: callJSON("parsePersonalSiteAuditDocument", arguments: [docId, json, ["timeZone": timeZone]])
        )
    }

    /// `personalSiteAuditTitle(audit)`: "Site audit (General) · J-1042 Riverside Flats · 4 Nov".
    nonisolated static func personalSiteAuditTitle(_ audit: PersonalSiteAudit) -> String {
        guard let json = RulebookJSON.object(audit) else { return audit.jobName }
        return callJSON("personalSiteAuditTitle", arguments: [json]) as? String ?? audit.jobName
    }

    /// `personalSiteAuditPdfRows(audit, { timeZone })`: the frozen copy's text.
    nonisolated static func personalSiteAuditPdfRows(
        _ audit: PersonalSiteAudit,
        timeZone: String = OrganizationRulebookContext.timeZoneIdentifier
    ) -> PersonalSiteAuditPdfRows? {
        guard let json = RulebookJSON.object(audit) else { return nil }
        return RulebookJSON.decode(
            PersonalSiteAuditPdfRows.self,
            from: callJSON("personalSiteAuditPdfRows", arguments: [json, ["timeZone": timeZone]])
        )
    }

    /// `personalSiteAuditEvidence(audit, path)`: the evidence entry of a frozen copy uploaded at `path`.
    nonisolated static func personalSiteAuditEvidence(_ audit: PersonalSiteAudit, path: String) -> PayeClaimEvidence? {
        guard let json = RulebookJSON.object(audit) else { return nil }
        return RulebookJSON.decode(PayeClaimEvidence.self, from: callJSON("personalSiteAuditEvidence", arguments: [json, path]))
    }

    /// `personalSiteAuditsFor(audits, viewerUserId)`: the owner's audits, newest first.
    nonisolated static func personalSiteAuditsFor(_ audits: [PersonalSiteAudit], viewerUserId: String) -> [PersonalSiteAudit] {
        guard let list = RulebookJSON.object(audits) else { return [] }
        return RulebookJSON.decode(
            [PersonalSiteAudit].self,
            from: callJSON("personalSiteAuditsFor", arguments: [list, viewerUserId])
        ) ?? []
    }
}
