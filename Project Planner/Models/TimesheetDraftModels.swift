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
    var receiptName: String?
    var managerDecision: TimesheetManagerDecision = .approved
    var managerRevisedAmount: Double?
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
    var managerSignatureImageBase64: String?
    var exportedAt: Date?

    var additionalTotal: Double {
        expenseEntries.reduce(0) { $0 + $1.amount } + priceWorkEntries.reduce(0) { $0 + $1.amount }
    }
}
