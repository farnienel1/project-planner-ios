//
//  TimesheetManagerReviewSupport.swift
//  Project Planner
//
//  Line-manager approve / decline / edit workflow for timesheet extras and day lines.
//

import SwiftUI

extension TimesheetManagerDecision {
    /// Default review UI treats pending as approved (green tick selected).
    var reviewSelection: TimesheetManagerDecision {
        self == .pending ? .approved : self
    }

    var isReviewApproved: Bool {
        switch reviewSelection {
        case .approved, .edited: return true
        case .pending, .declined: return false
        }
    }

    var label: String {
        switch self {
        case .pending: return "Awaiting review"
        case .approved: return "Approved"
        case .declined: return "Declined"
        case .edited: return "Edited"
        }
    }

    var tint: Color {
        switch self {
        case .pending: return .orange
        case .approved: return .green
        case .declined: return .red
        case .edited: return .blue
        }
    }
}

enum TimesheetDraftAdjustments {
    static func payrollReview(in draft: TimesheetDraft, lineId: String) -> TimesheetPayrollLineReview? {
        draft.payrollLineReviews[lineId]
    }

    static func expenseDecision(_ entry: TimesheetExpenseEntry) -> TimesheetManagerDecision {
        entry.managerDecision
    }

    static func priceWorkDecision(_ entry: TimesheetPriceWorkEntry) -> TimesheetManagerDecision {
        entry.managerDecision
    }

    static func effectivePayrollAmount(
        line: TimesheetPayrollLineItem,
        draft: TimesheetDraft,
        managerHasSigned: Bool,
        applyLiveReview: Bool = false
    ) -> Double {
        let applyDecisions = managerHasSigned || applyLiveReview
        guard applyDecisions, let review = draft.payrollLineReviews[line.id] else {
            return line.amount
        }
        switch review.decision {
        case .declined: return 0
        case .approved: return line.amount
        case .edited: return review.revisedAmount ?? line.amount
        case .pending: return line.amount
        }
    }

    static func isPayrollLineRemoved(
        line: TimesheetPayrollLineItem,
        draft: TimesheetDraft,
        managerHasSigned: Bool,
        applyLiveReview: Bool = false
    ) -> Bool {
        let applyDecisions = managerHasSigned || applyLiveReview
        guard applyDecisions, let review = draft.payrollLineReviews[line.id] else { return false }
        return review.decision == .declined
    }

    static func effectiveExpenseAmount(
        _ entry: TimesheetExpenseEntry,
        managerHasSigned: Bool,
        applyLiveReview: Bool = false
    ) -> Double {
        let applyDecisions = managerHasSigned || applyLiveReview
        guard applyDecisions else { return entry.amount }
        switch entry.managerDecision {
        case .declined: return 0
        case .approved: return entry.amount
        case .edited: return entry.managerRevisedAmount ?? entry.amount
        case .pending: return entry.amount
        }
    }

    static func effectivePriceWorkAmount(
        _ entry: TimesheetPriceWorkEntry,
        managerHasSigned: Bool,
        applyLiveReview: Bool = false
    ) -> Double {
        let applyDecisions = managerHasSigned || applyLiveReview
        guard applyDecisions else { return entry.amount }
        switch entry.managerDecision {
        case .declined: return 0
        case .approved: return entry.amount
        case .edited: return entry.managerRevisedAmount ?? entry.amount
        case .pending: return entry.amount
        }
    }

    static func extrasPendingReview(in draft: TimesheetDraft) -> Bool {
        draft.expenseEntries.contains { $0.managerDecision == .pending }
            || draft.priceWorkEntries.contains { $0.managerDecision == .pending }
    }

    static func payrollTotal(
        lines: [TimesheetPayrollLineItem],
        draft: TimesheetDraft,
        managerHasSigned: Bool,
        applyLiveReview: Bool = false
    ) -> Double {
        lines.reduce(0) { partial, line in
            partial + effectivePayrollAmount(
                line: line,
                draft: draft,
                managerHasSigned: managerHasSigned,
                applyLiveReview: applyLiveReview
            )
        }
    }

    static func expensesTotal(draft: TimesheetDraft, managerHasSigned: Bool, applyLiveReview: Bool = false) -> Double {
        draft.expenseEntries.reduce(0) {
            $0 + effectiveExpenseAmount($1, managerHasSigned: managerHasSigned, applyLiveReview: applyLiveReview)
        }
    }

    static func priceWorkTotal(draft: TimesheetDraft, managerHasSigned: Bool, applyLiveReview: Bool = false) -> Double {
        draft.priceWorkEntries.reduce(0) {
            $0 + effectivePriceWorkAmount($1, managerHasSigned: managerHasSigned, applyLiveReview: applyLiveReview)
        }
    }

    static func grandTotal(
        lines: [TimesheetPayrollLineItem],
        draft: TimesheetDraft,
        managerHasSigned: Bool,
        applyLiveReview: Bool = false
    ) -> Double {
        payrollTotal(lines: lines, draft: draft, managerHasSigned: managerHasSigned, applyLiveReview: applyLiveReview)
            + expensesTotal(draft: draft, managerHasSigned: managerHasSigned, applyLiveReview: applyLiveReview)
            + priceWorkTotal(draft: draft, managerHasSigned: managerHasSigned, applyLiveReview: applyLiveReview)
    }

    static func managerAdjustmentCount(draft: TimesheetDraft) -> Int {
        let payroll = draft.payrollLineReviews.values.filter { $0.decision == .declined || $0.decision == .edited }.count
        let expenses = draft.expenseEntries.filter { $0.managerDecision == .declined || $0.managerDecision == .edited }.count
        let priceWork = draft.priceWorkEntries.filter { $0.managerDecision == .declined || $0.managerDecision == .edited }.count
        return payroll + expenses + priceWork
    }
}

extension TimesheetDraft {
    func effectiveAdditionalTotal(managerHasSigned: Bool) -> Double {
        TimesheetDraftAdjustments.expensesTotal(draft: self, managerHasSigned: managerHasSigned)
            + TimesheetDraftAdjustments.priceWorkTotal(draft: self, managerHasSigned: managerHasSigned)
    }
}

// MARK: - Review action bar

struct TimesheetManagerReviewActionBar: View {
    let decision: TimesheetManagerDecision
    let canEdit: Bool
    let onApprove: () -> Void
    let onDecline: () -> Void
    let onEdit: () -> Void

    private var selection: TimesheetManagerDecision { decision.reviewSelection }

    var body: some View {
        HStack(spacing: 8) {
            reviewButton(
                systemName: "checkmark",
                activeTint: .green,
                selected: selection.isReviewApproved,
                inactive: selection == .declined,
                action: onApprove
            )
            reviewButton(
                systemName: "xmark",
                activeTint: .red,
                selected: selection == .declined,
                inactive: selection.isReviewApproved,
                action: onDecline
            )
            if canEdit {
                Button(action: onEdit) {
                    Image(systemName: "gearshape.fill")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(.blue)
                        .frame(width: 34, height: 34)
                        .background(Color.blue.opacity(0.12))
                        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 9, style: .continuous)
                                .stroke(Color.blue.opacity(0.25), lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Edit")
            }
        }
    }

    private func reviewButton(
        systemName: String,
        activeTint: Color,
        selected: Bool,
        inactive: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(selected ? .white : (inactive ? Color(.systemGray3) : activeTint))
                .frame(width: 34, height: 34)
                .background(
                    selected
                        ? activeTint
                        : (inactive ? Color(.systemGray5) : activeTint.opacity(0.14))
                )
                .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .stroke(
                            selected ? activeTint : (inactive ? Color(.systemGray4) : activeTint.opacity(0.25)),
                            lineWidth: selected ? 0 : 1
                        )
                )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(systemName)
    }
}

enum TimesheetPayrollLineBookingLookup {
    static func bookingId(from lineId: String) -> UUID? {
        let parts = lineId.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count >= 3 else { return nil }
        return UUID(uuidString: String(parts[1]))
    }

    static func initialChoice(
        for row: TimesheetPayrollLineItem,
        operativeBooking: Booking?,
        managerBooking: ManagerSiteBooking?,
        policy: OrgPayrollTimePolicy
    ) -> OperativeDayBookingChoice? {
        if let booking = operativeBooking {
            return OperativeDayBookingChoice(from: booking)
        }
        if let booking = managerBooking {
            return OperativeDayBookingChoice(
                timeSlot: .customHours,
                workStartTime: booking.workStartTime,
                workEndTime: booking.workEndTime,
                isBreakRemoved: booking.isBreakRemoved,
                otMultiplierOverride: nil
            )
        }
        if row.details.contains(":") {
            return OperativeDayBookingChoice(
                timeSlot: .customHours,
                workStartTime: policy.standardDayStart,
                workEndTime: policy.standardDayEnd,
                isBreakRemoved: false,
                otMultiplierOverride: nil
            )
        }
        return nil
    }

    static func revisedAmount(
        for row: TimesheetPayrollLineItem,
        startTime: String,
        endTime: String,
        breakRemoved: Bool,
        otMultiplier: Double?,
        policy: OrgPayrollTimePolicy
    ) -> Double {
        let probe = Booking(
            operativeId: UUID(),
            projectId: UUID(),
            date: row.date,
            timeSlot: .customHours,
            bookedBy: "",
            workStartTime: startTime,
            workEndTime: endTime,
            isBreakRemoved: breakRemoved,
            otMultiplierOverride: otMultiplier
        )
        let paid = probe.paidBookedHours(policy: policy)
        let ot = probe.overtimeHoursBeyondPaidStandard(policy: policy)
        let relevantHours: Double
        if row.isOvertimeLine {
            relevantHours = ot
        } else {
            relevantHours = max(0, paid - ot)
        }
        guard row.paidHours > 0.01 else { return row.amount }
        return row.amount * (relevantHours / row.paidHours)
    }
}

struct TimesheetPayrollLineEditHoursSheet: View {
    let row: TimesheetPayrollLineItem
    let policy: OrgPayrollTimePolicy
    let initialChoice: OperativeDayBookingChoice?
    let onSave: (Double) -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        OperativeCustomHoursSheet(
            policy: policy,
            title: "Edit Hours",
            subtitle: "\(row.date.formatted(date: .abbreviated, time: .omitted)) · \(row.jobNumber) \(row.projectName)",
            allowsOtMultiplierOverride: row.isOvertimeLine,
            showsBreakControls: !row.isOvertimeLine,
            showsBreakdown: true,
            showsFooterNote: false,
            initialChoice: initialChoice,
            onSave: { start, end, breakRemoved, otMult in
                let amount = TimesheetPayrollLineBookingLookup.revisedAmount(
                    for: row,
                    startTime: start,
                    endTime: end,
                    breakRemoved: breakRemoved,
                    otMultiplier: otMult,
                    policy: policy
                )
                onSave(amount)
                dismiss()
            },
            onCancel: { dismiss() }
        )
    }
}

struct TimesheetAdjustedAmountText: View {
    let original: Double
    let effective: Double
    let decision: TimesheetManagerDecision
    let managerHasSigned: Bool
    var applyLiveReview: Bool = false

    private var showsAdjustment: Bool {
        (managerHasSigned || applyLiveReview)
            && decision != .approved
            && decision != .pending
            && (original != effective || decision == .declined)
    }

    var body: some View {
        if showsAdjustment {
            VStack(alignment: .trailing, spacing: 2) {
                Text(String(format: "£%.2f", original))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .strikethrough(decision == .declined || decision == .edited, color: .secondary)
                Text(String(format: "£%.2f", effective))
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(decision.tint)
            }
        } else {
            Text(String(format: "£%.2f", original))
                .font(.subheadline.weight(.bold))
        }
    }
}

struct TimesheetManagerAdjustmentSummaryCard: View {
    let draft: TimesheetDraft
    let managerName: String

    private var adjustments: [(String, TimesheetManagerDecision, String?)] {
        var rows: [(String, TimesheetManagerDecision, String?)] = []
        for entry in draft.expenseEntries where entry.managerDecision != .approved && entry.managerDecision != .pending {
            let detail: String? = entry.managerDecision == .edited
                ? "£\(String(format: "%.2f", entry.amount)) → £\(String(format: "%.2f", entry.managerRevisedAmount ?? entry.amount))"
                : nil
            rows.append(("Expense: \(entry.title)", entry.managerDecision, detail))
        }
        for entry in draft.priceWorkEntries where entry.managerDecision != .approved && entry.managerDecision != .pending {
            let detail: String? = entry.managerDecision == .edited
                ? "£\(String(format: "%.2f", entry.amount)) → £\(String(format: "%.2f", entry.managerRevisedAmount ?? entry.amount))"
                : nil
            rows.append(("Price work: \(entry.title)", entry.managerDecision, detail))
        }
        for (lineId, review) in draft.payrollLineReviews where review.decision == .declined || review.decision == .edited {
            let label = review.decision == .declined ? "Day removed" : "Day adjusted"
            let detail: String? = review.decision == .edited
                ? "New amount £\(String(format: "%.2f", review.revisedAmount ?? 0))"
                : nil
            rows.append(("\(label) (\(lineId.prefix(8))…)", review.decision, detail))
        }
        return rows
    }

    var body: some View {
        if !adjustments.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Image(systemName: "person.badge.shield.checkmark.fill")
                        .foregroundStyle(.blue)
                    Text("Line manager adjustments")
                        .font(.headline)
                }
                Text("\(managerName) reviewed your timesheet. Struck-through amounts are what you submitted; coloured amounts are what will be paid.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ForEach(Array(adjustments.enumerated()), id: \.offset) { _, row in
                    HStack(alignment: .top) {
                        Text(row.1.label)
                            .font(.caption2.weight(.bold))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(row.1.tint.opacity(0.14))
                            .foregroundStyle(row.1.tint)
                            .clipShape(Capsule())
                        VStack(alignment: .leading, spacing: 2) {
                            Text(row.0)
                                .font(.subheadline.weight(.semibold))
                            if let detail = row.2 {
                                Text(detail)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                    }
                }
            }
            .padding(14)
            .background(Color.blue.opacity(0.06))
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(Color.blue.opacity(0.18), lineWidth: 1)
            )
        }
    }
}

struct TimesheetManagerAmountEditSheet: View {
    let title: String
    let subtitle: String
    let originalAmount: Double
    var allowsDelete: Bool = false
    let onSave: (Double) -> Void
    let onDelete: (() -> Void)?

    @Environment(\.dismiss) private var dismiss
    @State private var amountText: String

    init(
        title: String,
        subtitle: String,
        originalAmount: Double,
        allowsDelete: Bool = false,
        onSave: @escaping (Double) -> Void,
        onDelete: (() -> Void)? = nil
    ) {
        self.title = title
        self.subtitle = subtitle
        self.originalAmount = originalAmount
        self.allowsDelete = allowsDelete
        self.onSave = onSave
        self.onDelete = onDelete
        _amountText = State(initialValue: String(format: "%.2f", originalAmount))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(subtitle)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    HStack {
                        Text("£")
                        TextField("Amount", text: $amountText)
                            .keyboardType(.decimalPad)
                    }
                    Text("Original: £\(String(format: "%.2f", originalAmount))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if allowsDelete, let onDelete {
                    Section {
                        Button("Delete this day from timesheet", role: .destructive) {
                            onDelete()
                            dismiss()
                        }
                    }
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        let cleaned = amountText.replacingOccurrences(of: "£", with: "").trimmingCharacters(in: .whitespaces)
                        if let value = Double(cleaned), value >= 0 {
                            onSave(value)
                            dismiss()
                        }
                    }
                }
            }
        }
        .presentationDetents([.medium])
    }
}
