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
    /// RULEBOOK 1.43.0 §8: the older approval field as stored (`approvedAt`), read for `timesheetOwnerCanAddExtras` (the
    /// security rules test it with `managerSignedAt`). Read only; the save writes `approvedAt` from `managerSignedAt`.
    var approvedAt: Date?
    /// Agreed labour / price-work / expenses snapshot written when the timesheet
    /// is fully approved (line-manager counter-sign, or the person's own sign when
    /// they have no line manager). Weekly Report and the web app read this field
    /// from `organizations/{orgId}/settings/timesheet_{userId}_{weekStartUnix}`.
    var weeklyReportOverride: TimesheetWeeklyReportOverride?

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
    /// RULEBOOK 1.46.0 §8: whether the booking had its own overtime line when the line was signed (the live line's
    /// `bookingHasOvertimeLine`), so a later save tests a review against the sheet as signed. Nil on an older line.
    var bookingHadOvertimeLine: Bool? = nil
    /// RULEBOOK 1.46.0 §8: `payrollLineReviewKey` of the review applied when the line was signed ('' for none); a later
    /// save re-applies a review only when it is a different one. Nil on an older line.
    var appliedReviewKey: String? = nil
}

struct TimesheetWeeklyReportMoneyLine: Codable, Hashable, Identifiable {
    var id: String
    var title: String
    var details: String
    var jobNumber: String
    var date: Date
    var amount: Double
    var decision: TimesheetManagerDecision
}
