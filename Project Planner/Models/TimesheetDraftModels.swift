//
//  TimesheetDraftModels.swift
//  Project Planner
//
//  Shared timesheet draft types used by InvoicingView and manager review UI.
//

import Foundation

nonisolated enum TimesheetManagerDecision: String, Codable, Hashable {
    case pending
    case approved
    case declined
    case edited
}

nonisolated struct TimesheetPayrollLineReview: Codable, Hashable {
    var decision: TimesheetManagerDecision = .pending
    var revisedAmount: Double?
}

nonisolated struct TimesheetExpenseEntry: Codable, Identifiable, Hashable {
    let id: UUID
    var title: String
    var details: String
    var jobNumber: String
    var date: Date
    var amount: Double
    var receiptName: String?
    var managerDecision: TimesheetManagerDecision = .approved
    var managerRevisedAmount: Double?
}

nonisolated struct TimesheetPriceWorkEntry: Codable, Identifiable, Hashable {
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
}

nonisolated struct TimesheetDraft: Codable {
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
    /// Agreed labour / price-work / expenses snapshot written when the timesheet
    /// is fully approved (line-manager counter-sign, or the person's own sign when
    /// they have no line manager). Weekly Report and the web app read this field
    /// from `organizations/{orgId}/settings/timesheet_{userId}_{weekStartUnix}`.
    var weeklyReportOverride: TimesheetWeeklyReportOverride?

    var additionalTotal: Double {
        expenseEntries.reduce(0) { $0 + $1.amount } + priceWorkEntries.reduce(0) { $0 + $1.amount }
    }
}

/// Shared iOS + web contract. Field names match Firestore `weeklyReportOverride`.
nonisolated struct TimesheetWeeklyReportOverride: Codable, Hashable {
    var approvedAt: Date
    var approvedByUserId: String
    var approvedByName: String
    var selfSigned: Bool
    var lines: [TimesheetWeeklyReportLabourLine]
    var priceWork: [TimesheetWeeklyReportMoneyLine]
    var expenses: [TimesheetWeeklyReportMoneyLine]
}

nonisolated struct TimesheetWeeklyReportLabourLine: Codable, Hashable, Identifiable {
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

nonisolated struct TimesheetWeeklyReportMoneyLine: Codable, Hashable, Identifiable {
    var id: String
    var title: String
    var details: String
    var jobNumber: String
    var date: Date
    var amount: Double
    var decision: TimesheetManagerDecision
}
