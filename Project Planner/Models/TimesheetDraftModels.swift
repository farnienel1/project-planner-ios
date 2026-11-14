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
