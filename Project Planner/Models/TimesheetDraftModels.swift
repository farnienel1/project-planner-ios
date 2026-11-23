//
//  TimesheetDraftModels.swift
//  Project Planner
//
//  Shared timesheet draft types used by InvoicingView and manager review UI.
//

import Foundation

enum TimesheetManagerDecision: String, Codable, Hashable {
    case pending
    case approved
    case declined
    case edited
}

struct TimesheetPayrollLineReview: Codable, Hashable {
    var decision: TimesheetManagerDecision = .pending
    var revisedAmount: Double?
    /// RULEBOOK 1.46.0 §8 Edit hours (`revisedPayrollLineAmounts` → `PayrollLineEditReviewFields`), on an `edited` review
    /// only; nil on an older review and on approve / decline. Read and written back on every save so none is dropped
    /// (`TimesheetPayrollLineReview.storedFields`). Optional, so a draft cached before 1.46.0 still decodes.
    var revisedStandardHours: Double? = nil
    var revisedOvertimeHours: Double? = nil
    var revisedOvertimeClockHours: Double? = nil
    var revisedOvertimeMultiplier: Double? = nil
    var revisedStandardAmount: Double? = nil
    var revisedOvertimeAmount: Double? = nil
    /// The booking the review was made against (`overtimeBookingFingerprint`); once the booking changes the review is
    /// stale (`payrollLineReview` with the live line).
    var reviewedBookingFingerprint: String? = nil
}

// RULEBOOK 1.46.0: a review cached before 1.46.0 has only `decision` and `revisedAmount`; every other key decodes when
// present (the synthesized decoder already does this for optionals; written out so it stays so).
extension TimesheetPayrollLineReview {
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        decision = try container.decodeIfPresent(TimesheetManagerDecision.self, forKey: .decision) ?? .pending
        revisedAmount = try container.decodeIfPresent(Double.self, forKey: .revisedAmount)
        revisedStandardHours = try container.decodeIfPresent(Double.self, forKey: .revisedStandardHours)
        revisedOvertimeHours = try container.decodeIfPresent(Double.self, forKey: .revisedOvertimeHours)
        revisedOvertimeClockHours = try container.decodeIfPresent(Double.self, forKey: .revisedOvertimeClockHours)
        revisedOvertimeMultiplier = try container.decodeIfPresent(Double.self, forKey: .revisedOvertimeMultiplier)
        revisedStandardAmount = try container.decodeIfPresent(Double.self, forKey: .revisedStandardAmount)
        revisedOvertimeAmount = try container.decodeIfPresent(Double.self, forKey: .revisedOvertimeAmount)
        reviewedBookingFingerprint = try container.decodeIfPresent(String.self, forKey: .reviewedBookingFingerprint)
    }
}

struct TimesheetExpenseEntry: Codable, Identifiable, Hashable {
    let id: UUID
    var title: String
    var details: String
    var jobNumber: String
    var date: Date
    var amount: Double
    /// Older entries only: the receipt name both apps stored without uploading a file (read-only, RULEBOOK 1.45.0 §8).
    var receiptName: String?
    var managerDecision: TimesheetManagerDecision = .approved
    var managerRevisedAmount: Double?
    /// The entry id as `parseTimesheetEntries` read it (RULEBOOK 1.7.0 §8): the stored id in stored case, or the
    /// deterministic `timesheetEntryId` for an entry stored without one. Written back on save. Nil on a new entry.
    var storedId: String? = nil
    /// RULEBOOK 1.45.0 §8: files, photos and frozen personal site audit copies the owner attached (the PAYE claim
    /// evidence shape). Read through `parseTimesheetEntries`; written back on every save so it is never dropped.
    var evidence: [PayeClaimEvidence] = []
    /// RULEBOOK 1.45.0 §8 (review #322): the stored row's fingerprint as `parseTimesheetEntries` returned it. Passed to
    /// the review rules (`timesheetEntryReviewWriteFields`, `timesheetEntryDecision`); never written back. Nil on a new entry.
    var reviewFingerprint: String? = nil
}

struct TimesheetPriceWorkEntry: Codable, Identifiable, Hashable {
    let id: UUID
    var title: String
    var details: String
    var jobNumber: String
    var agreedManagerName: String
    var startDate: Date
    var endDate: Date?
    var amount: Double
    var managerDecision: TimesheetManagerDecision = .approved
    var managerRevisedAmount: Double?
    /// The entry id as `parseTimesheetEntries` read it (stored case, or `timesheetEntryId`). Nil on a new entry.
    var storedId: String? = nil
    /// RULEBOOK 1.45.0 §8: optional evidence (the PAYE claim evidence shape); written back on every save.
    var evidence: [PayeClaimEvidence] = []
    /// RULEBOOK 1.45.0 §8: the stored row's fingerprint from `parseTimesheetEntries`; never written back.
    var reviewFingerprint: String? = nil
}

// RULEBOOK 1.45.0: a draft or loaded copy cached before 1.45.0 has no `evidence` key on its entries. The synthesized
// decoder would refuse the whole draft (losing the "only what this editor changed" baseline), so these decode
// `evidence` (and `reviewFingerprint`) when present and default the rest exactly as the synthesized decoder did.
extension TimesheetExpenseEntry {
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        details = try container.decode(String.self, forKey: .details)
        jobNumber = try container.decode(String.self, forKey: .jobNumber)
        date = try container.decode(Date.self, forKey: .date)
        amount = try container.decode(Double.self, forKey: .amount)
        receiptName = try container.decodeIfPresent(String.self, forKey: .receiptName)
        managerDecision = try container.decodeIfPresent(TimesheetManagerDecision.self, forKey: .managerDecision) ?? .approved
        managerRevisedAmount = try container.decodeIfPresent(Double.self, forKey: .managerRevisedAmount)
        storedId = try container.decodeIfPresent(String.self, forKey: .storedId)
        evidence = try container.decodeIfPresent([PayeClaimEvidence].self, forKey: .evidence) ?? []
        reviewFingerprint = try container.decodeIfPresent(String.self, forKey: .reviewFingerprint)
    }
}

extension TimesheetPriceWorkEntry {
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        details = try container.decode(String.self, forKey: .details)
        jobNumber = try container.decode(String.self, forKey: .jobNumber)
        agreedManagerName = try container.decode(String.self, forKey: .agreedManagerName)
        startDate = try container.decode(Date.self, forKey: .startDate)
        endDate = try container.decodeIfPresent(Date.self, forKey: .endDate)
        amount = try container.decode(Double.self, forKey: .amount)
        managerDecision = try container.decodeIfPresent(TimesheetManagerDecision.self, forKey: .managerDecision) ?? .approved
        managerRevisedAmount = try container.decodeIfPresent(Double.self, forKey: .managerRevisedAmount)
        storedId = try container.decodeIfPresent(String.self, forKey: .storedId)
        evidence = try container.decodeIfPresent([PayeClaimEvidence].self, forKey: .evidence) ?? []
        reviewFingerprint = try container.decodeIfPresent(String.self, forKey: .reviewFingerprint)
    }
}

struct TimesheetDraft: Codable {
    var expenseEntries: [TimesheetExpenseEntry] = []
    var priceWorkEntries: [TimesheetPriceWorkEntry] = []
    var payrollLineReviews: [String: TimesheetPayrollLineReview] = [:]
    var managerNote: String = ""
    var operativeSignedAt: Date?
    var operativeSignedByName: String?
    var operativeSignatureImageBase64: String?
    var managerSignedAt: Date?
    var managerSignedByName: String?
    var managerSignedByUserId: String?
    var managerSignatureImageBase64: String?
    var exportedAt: Date?
    /// RULEBOOK 1.47.0 §8 / `resolveTimesheetExportedAtMs`: when web generated the invoice, as stored. Read only — an
    /// `exportedAt` within the leftover window of it is not an export. Passed to `parseTimesheetStatusFields` and
    /// `signedTimesheetBookingChanges`; never written by iOS.
    var invoiceGeneratedAt: Date? = nil
    /// RULEBOOK 1.43.0 §8: the older approval field as stored (`approvedAt`), read for `timesheetOwnerCanAddExtras` (the
    /// security rules test it with `managerSignedAt`). Read only; the save writes `approvedAt` from `managerSignedAt`.
    var approvedAt: Date?
    /// Agreed labour / price-work / expenses snapshot written when the timesheet
    /// is fully approved (line-manager counter-sign, or the person's own sign when
    /// they have no line manager). Weekly Report and the web app read this field
    /// from `organizations/{orgId}/settings/timesheet_{userId}_{weekStartUnix}`.
    var weeklyReportOverride: TimesheetWeeklyReportOverride?
    /// RULEBOOK 1.47.0 §8 (owner fields): what the person signed — one row per booking of the live lines
    /// (`signedTimesheetBookingRecord`), written with every operative signature. Nil on sheets signed before 1.47.0.
    /// Read and kept on every save; never written for someone else's sheet.
    var operativeSignedBookings: [TimesheetSignedBookingRow]? = nil
    /// The `operativeSignedAt` the record belongs to (the same value, written together).
    var operativeSignedBookingsSignedAt: Date? = nil
    /// When the record was written — server time (`FieldValue.serverTimestamp()`), read back from the server.
    var operativeSignedBookingsAt: Date? = nil
    /// Local only (never stored): the record was just written and its server time is pending, so the next save sends
    /// `operativeSignedBookingsAt = FieldValue.serverTimestamp()` once.
    var operativeSignedBookingsAtPending: Bool? = nil
    /// RULEBOOK 1.54.0 §8: price work and expenses the person added after the line manager signed (`lateExtras`, until
    /// exported). Read with `parseTimesheetLateExtras`; nil when the stored sheet has no `lateExtras` array, so a sheet
    /// without them keeps its stored shape. Kept on every save (never dropped).
    var lateExtras: [TimesheetLateExtra]? = nil
    /// RULEBOOK 1.54.0 §8: the stored review map (`extraEntryReviews`) as plain JSON text, read only — a late extra pays
    /// only by a review there (`timesheetLateExtraDecision`). Never written back by this field (reviews are written as
    /// dotted `extraEntryReviews.{id}` fields by `timesheetEntryReviewWriteFields`).
    var extraEntryReviewsJSON: String? = nil
    /// RULEBOOK 1.74.0 §8: the reviewer's own booking edits from this sheet's review (`reviewerBookingEdits` as stored,
    /// instants as epoch ms) as plain JSON text, read only — passed to `signedTimesheetBookingChanges` so a booking still
    /// exactly as the reviewer left it does not send the sheet back. Never written from a draft save (reviewer-only field,
    /// written only in the booking write's batch, `FirebaseBackend.applyTimesheetReviewBookingUpdate`).
    var reviewerBookingEditsJSON: String? = nil
    /// RULEBOOK 1.54.0 (review of #337): the stored `exportedAt` is set as the security rules test it
    /// (`timesheetExportedFieldSet`). Read only, never written.
    var exportedAtStored: Bool? = nil
    /// RULEBOOK 1.55.0 §8: the document this draft was read from — the original `timesheet_{uid}_{unix}` or a revision
    /// `…_rev{N}` (the read's `__documentId`). Read only, never written as a field. A save goes to this document only.
    var versionDocumentId: String? = nil
    /// RULEBOOK 1.55.0 §8: 0 for the original, N for REV N (`parseTimesheetRevisionDocId`). Read only, never written.
    var revision: Int? = nil
    /// RULEBOOK 1.55.0 §8: the previous version's exported total (`timesheetExportedTotal`), read from that frozen
    /// document when this draft is a revision — the base of the difference shown ("+£44.12"). Never stored.
    var previousVersionExportedTotal: Double? = nil
    /// RULEBOOK 1.55.0 §8: the previous version was read with this one (its total may still be unknown).
    var previousVersionKnown: Bool? = nil
    /// RULEBOOK 1.55.0 §8: the ORIGINAL's stored `userId` (the invoice number's person). Read only, never written.
    var originalStoredUserId: String? = nil
}

/// RULEBOOK 1.54.0 §8: one late extra — a price work or expense entry added after the line manager signed. Its own
/// fields and `kind` are stored (`lateExtraStoredRow`), never a decision. The decision in effect comes only from the
/// review map (`timesheetLateExtraDecision`, read into `lateState` / `lateReason` when the sheet was read); a reviewer's
/// on-screen decision (`managerDecision`, `managerRevisedAmount`) is local until their save writes the review.
struct TimesheetLateExtra: Codable, Identifiable, Hashable {
    /// The id as stored (stored case). A new late extra gets an upper-case UUID string.
    var id: String
    /// `priceWork` | `expense`.
    var kind: String
    var title: String
    var details: String
    var jobNumber: String
    /// Price work only.
    var agreedManagerName: String = ""
    /// Expense: the date; price work: the start date.
    var date: Date
    /// Price work only.
    var endDate: Date? = nil
    var amount: Double
    var receiptName: String? = nil
    var evidence: [PayeClaimEvidence] = []
    /// The stored row's fingerprint (`parseTimesheetLateExtras`); never written back. Nil on a new late extra.
    var reviewFingerprint: String? = nil
    /// `timesheetLateExtraDecision(...).state` when read: `approved` | `declined` | `pending` | `ignored`. Nil on a new one.
    var lateState: String? = nil
    /// `timesheetLateExtraDecision(...).reason` when read (`id-taken`, `id-unusable`, …).
    var lateReason: String? = nil
    /// The reviewer's decision on screen (local only; seeded from the late decision).
    var managerDecision: TimesheetManagerDecision = .pending
    var managerRevisedAmount: Double? = nil

    var isPriceWork: Bool { kind == "priceWork" }
}

/// Shared iOS + web contract. Field names match Firestore `weeklyReportOverride`.
struct TimesheetWeeklyReportOverride: Codable, Hashable {
    var approvedAt: Date
    var approvedByUserId: String
    var approvedByName: String
    var selfSigned: Bool
    var lines: [TimesheetWeeklyReportLabourLine]
    var priceWork: [TimesheetWeeklyReportMoneyLine]
    var expenses: [TimesheetWeeklyReportMoneyLine]
}

struct TimesheetWeeklyReportLabourLine: Codable, Hashable, Identifiable {
    var id: String
    var date: Date
    var jobNumber: String
    var projectName: String
    /// `project` | `small_work` | `office` | `working_from_home` | `site_survey` | `custom`
    var locationKind: String
    var details: String
    var paidHours: Double
    var days: Double
    var amount: Double
    var isOvertime: Bool
    var decision: TimesheetManagerDecision
    var bookingId: String?
    /// RULEBOOK 1.44.0 §8: the pay basis stored on the signed line (`day` | `hourly`, web `payBasis`); nil on a line
    /// signed before it was stored. The signed line reads with it, never the live rate.
    var payBasis: String? = nil
    /// RULEBOOK 1.46.0 §8: the booking as it was when the line was signed (`overtimeBookingFingerprint`, web
    /// `bookingFingerprint`). An Edit hours review made against another version of the booking is never applied to it.
    var bookingFingerprint: String? = nil
    /// The overtime multiplier of an overtime line (web `otMultiplier`); nil on a standard line or one signed without it.
    var otMultiplier: Double? = nil
    /// RULEBOOK 1.61.0 §8 (web `otBaseDayRate`, `otDayRateHours`): on a day-rate overtime line, the person's own day rate
    /// (never multiplied) and the line's day-rate divisor at signing, so the signed line reads in hours without working a
    /// rate out from its amount (`signedDayRateOvertimeText`). Nil on a line signed before 1.61.0 (older wording).
    var otBaseDayRate: Double? = nil
    var otDayRateHours: Double? = nil
    /// RULEBOOK 1.46.0 §8: whether the booking had its own overtime line when the line was signed (the live line's
    /// `bookingHasOvertimeLine`), so a later save tests a review against the sheet as signed. Nil on an older line.
    var bookingHadOvertimeLine: Bool? = nil
    /// RULEBOOK 1.46.0 §8: `payrollLineReviewKey` of the review applied when the line was signed ('' for none); a later
    /// save re-applies a review only when it is a different one. Nil on an older line.
    var appliedReviewKey: String? = nil
    /// RULEBOOK 1.46.0 §8: on a `{booking}-ot` line a standard line's Edit hours review added, that standard line's id;
    /// the part follows its standard line's current review when reviews are re-applied. Nil otherwise.
    var reviewPartOf: String? = nil
    /// RULEBOOK 1.46.0 §8: the signed line's own PAYE and annual-leave flags (web `isPayeDay`, `isLeave`). A signed
    /// sheet's invoice rows are left out only by their own stored data (`timesheetInvoiceRows`), so every line iOS
    /// writes carries them. Nil on a line signed before they were stored (kept as stored).
    var isPayeDay: Bool? = nil
    var isLeave: Bool? = nil
}

struct TimesheetWeeklyReportMoneyLine: Codable, Hashable, Identifiable {
    var id: String
    var title: String
    var details: String
    var jobNumber: String
    var date: Date
    var amount: Double
    var decision: TimesheetManagerDecision
    /// RULEBOOK 1.54.0 §8: an approved late extra's row (`timesheetLateExtrasSnapshotRows`); nil on every other row.
    var lateExtra: Bool? = nil
    /// RULEBOOK 1.54.0 §8: the late extra's fingerprint when it was approved.
    var entryFingerprint: String? = nil
}
