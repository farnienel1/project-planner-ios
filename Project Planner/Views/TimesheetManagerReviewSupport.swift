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
    /// RULEBOOK 1.10.0 §8 `payrollLineReview(sheet, lineId, live)`: the line id as stored, then without case (iOS keys
    /// reviews by `UUID.uuidString`, web by the stored line id). 1.46.0: given the live line, a review made against a
    /// booking that has changed since (`reviewedBookingFingerprint` ≠ the line's `bookingFingerprint`), or a
    /// standard-line review carrying overtime once the booking has its own overtime line, is stale (nil: pending at the
    /// live amount). Falls back to the exact key when the script did not answer.
    static func payrollReview(in draft: TimesheetDraft, lineId: String, live: TimesheetPayrollLineItem? = nil) -> TimesheetPayrollLineReview? {
        payrollReview(in: draft, lineId: lineId, liveJSON: live?.rulebookLiveBookingJSON)
    }

    /// `payrollLineReview(sheet, lineId, live)` with the live booking as the script reads it (a signed snapshot line passes
    /// the values it was signed with: `bookingFingerprint`, `isOvertimeLine`, `bookingHadOvertimeLine`).
    static func payrollReview(in draft: TimesheetDraft, lineId: String, liveJSON: [String: Any]?) -> TimesheetPayrollLineReview? {
        guard !draft.payrollLineReviews.isEmpty else { return nil }
        let reviews: [String: Any] = draft.payrollLineReviews.mapValues { $0.storedFields }
        var arguments: [Any] = [["payrollLineReviews": reviews], lineId]
        if let liveJSON { arguments.append(liveJSON) }
        guard let answer = CanonicalBusinessEngine.callJSON("payrollLineReview", arguments: arguments) else {
            return draft.payrollLineReviews[lineId]
        }
        guard let row = answer as? [String: Any] else { return nil }
        return TimesheetPayrollLineReview(stored: row, defaultDecision: .approved)
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
        guard applyDecisions, let review = payrollReview(in: draft, lineId: line.id, live: line) else {
            return line.amount
        }
        // RULEBOOK 1.46.0 `timesheetEntryEffectiveAmount`: a revised amount counts in pennies.
        return CanonicalBusinessEngine.timesheetEntryEffectiveAmount(
            decision: review.decision.rawValue,
            revisedAmount: review.revisedAmount,
            amount: line.amount
        ) ?? line.amount
    }

    static func isPayrollLineRemoved(
        line: TimesheetPayrollLineItem,
        draft: TimesheetDraft,
        managerHasSigned: Bool,
        applyLiveReview: Bool = false
    ) -> Bool {
        let applyDecisions = managerHasSigned || applyLiveReview
        guard applyDecisions, let review = payrollReview(in: draft, lineId: line.id, live: line) else { return false }
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

    // RULEBOOK 1.22.0 §8: sheet totals (labour, price work, expenses, total) are `CanonicalBusinessEngine.timesheetTotals`
    // (`TimesheetTotalsSource.totals`), the sum of the invoice rows. The Swift sums that were here are deleted.

    static func managerAdjustmentCount(draft: TimesheetDraft) -> Int {
        let payroll = draft.payrollLineReviews.values.filter { $0.decision == .declined || $0.decision == .edited }.count
        let expenses = draft.expenseEntries.filter { $0.managerDecision == .declined || $0.managerDecision == .edited }.count
        let priceWork = draft.priceWorkEntries.filter { $0.managerDecision == .declined || $0.managerDecision == .edited }.count
        return payroll + expenses + priceWork
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
                .accessibilityIdentifier("timesheets.edit")
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
        .accessibilityIdentifier("timesheets.review")
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
        // RULEBOOK 1.43.0: a line's details show only its own part (standard or overtime times), so the booking's whole
        // times come from the line's booking fields (web `initialHoursChoice`); older lines fall back as before.
        if let start = row.bookingStartTime, let end = row.bookingEndTime, !start.isEmpty, !end.isEmpty {
            return OperativeDayBookingChoice(
                timeSlot: .customHours,
                workStartTime: start,
                workEndTime: end,
                isBreakRemoved: row.bookingBreakRemoved ?? false,
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

    /// RULEBOOK 1.46.0 §8 (web `payrollLineBookingLookup.ts` `payrollLineEdit`): a line manager's Edit hours re-prices the
    /// whole booking through `CanonicalBusinessEngine.revisedPayrollLineAmounts` (`payrollHoursResult` under the policy
    /// in effect that day, the booking's own overtime rate, `payForHours`, pennies) — never the old hours ratio. Returns
    /// the review fields for each line of that booking on the sheet (its standard line and, when it has one, its overtime
    /// line). The rate is the standard line's (an overtime line shows the rate × multiplier for display).
    struct Edit {
        /// `revisedPayrollLineTimesError` when the times cannot be priced (Save is refused); else nil.
        let error: String?
        let amounts: RulebookRevisedPayrollLineAmounts?
        let reviewFieldsByLineId: [String: RulebookPayrollLineEditReviewFields]
        let standardLine: TimesheetPayrollLineItem?
        let overtimeLine: TimesheetPayrollLineItem?
    }

    static func payrollLineEdit(
        row: TimesheetPayrollLineItem,
        lines: [TimesheetPayrollLineItem],
        startTime: String,
        endTime: String,
        breakRemoved: Bool,
        typedOvertimeRate: Double?,
        policy: OrgPayrollTimePolicy,
        employment: [String: Any]?
    ) -> Edit {
        let base = Self.bookingKey(row)
        let sameBooking: (TimesheetPayrollLineItem) -> Bool = { Self.bookingKey($0) == base }
        let standardLine = row.isOvertimeLine ? lines.first(where: { !$0.isOvertimeLine && sameBooking($0) }) : row
        let overtimeLine = row.isOvertimeLine ? row : lines.first(where: { $0.isOvertimeLine && sameBooking($0) })
        let rateLine = standardLine ?? row
        let multiplier = row.isOvertimeLine ? (row.otMultiplier.flatMap { $0 > 0 ? $0 : nil } ?? 1) : 1
        let dayRate = standardLine != nil ? rateLine.dayRate : row.dayRate / multiplier
        let hourlyRate = standardLine != nil ? rateLine.hourlyRate : row.hourlyRate.map { $0 / multiplier }
        // The overtime rate typed on an overtime line (1–3), else the booking's own (web `typedOvertimeRate`).
        let typed = row.isOvertimeLine ? typedOvertimeRate.flatMap { (1...3).contains($0) ? $0 : nil } : nil
        if let timesError = CanonicalBusinessEngine.revisedPayrollLineTimesError(startTime: startTime, endTime: endTime) {
            return Edit(error: timesError, amounts: nil, reviewFieldsByLineId: [:], standardLine: standardLine, overtimeLine: overtimeLine)
        }
        let amounts = CanonicalBusinessEngine.revisedPayrollLineAmounts(
            dayKey: OrganizationRulebookContext.dayKey(row.date),
            policy: policy,
            startTime: startTime,
            endTime: endTime,
            isBreakRemoved: breakRemoved,
            otMultiplierOverride: typed ?? rateLine.bookingOtMultiplierOverride,
            payBasis: rateLine.payrollBasis == .hourly ? "hourly" : "day",
            dayRate: dayRate,
            hourlyRate: hourlyRate,
            employment: employment,
            bookingHasOvertimeLine: overtimeLine != nil,
            bookingFingerprint: rateLine.bookingFingerprint ?? row.bookingFingerprint
        )
        var fields: [String: RulebookPayrollLineEditReviewFields] = [:]
        if let amounts, let standardLine { fields[standardLine.id] = amounts.standardFields }
        if let amounts, let overtimeLine, let overtime = amounts.overtimeFields { fields[overtimeLine.id] = overtime }
        return Edit(
            error: amounts == nil ? CanonicalBusinessEngine.payrollLineEditTimesMessage : nil,
            amounts: amounts,
            reviewFieldsByLineId: fields,
            standardLine: standardLine,
            overtimeLine: overtimeLine
        )
    }

    /// The booking a line comes from: the rulebook's `payrollLineBookingKey` (collection and `bookingId`, else the line
    /// id without its `-normal` / `-ot` suffix). The line's own id when the script did not answer (it then groups alone).
    private static func bookingKey(_ line: TimesheetPayrollLineItem) -> String {
        CanonicalBusinessEngine.payrollLineBookingKey(
            lineId: line.id,
            bookingId: line.bookingId,
            bookingCollection: line.bookingCollection
        ) ?? "line|\(line.id)"
    }

    /// RULEBOOK 1.46.0: the reviews after an Edit hours save (web `TimesheetPeriodPage` save + `managerReviewSave.ts`):
    /// the edited line always, and the booking's other line only when its amount changes or it already has an `edited`
    /// review. Each review is `{ decision, revisedAmount }` (a declined line becomes approved; an unchanged amount is
    /// approved) with the Edit hours fields on an `edited` one; revised amounts in pennies (`roundPennies`).
    static func reviewsAfterEdit(
        _ edit: Edit,
        editedLineId: String,
        draft: TimesheetDraft
    ) -> [String: TimesheetPayrollLineReview] {
        var reviews = draft.payrollLineReviews
        for line in [edit.standardLine, edit.overtimeLine].compactMap({ $0 }) {
            guard let fields = edit.reviewFieldsByLineId[line.id] else { continue }
            let existing = TimesheetDraftAdjustments.payrollReview(in: draft, lineId: line.id, live: line)
            let unchanged = abs(fields.revisedAmount - line.amount) < 0.01
            if line.id != editedLineId && unchanged && existing?.decision != .edited { continue }
            let decision: TimesheetManagerDecision = (existing?.decision == .declined || unchanged) ? .approved : .edited
            if decision == .edited {
                var review = fields.editedReview
                review.revisedAmount = CanonicalBusinessEngine.roundPennies(fields.revisedAmount)
                reviews[line.id] = review
            } else {
                reviews[line.id] = TimesheetPayrollLineReview(
                    decision: .approved,
                    revisedAmount: unchanged ? nil : CanonicalBusinessEngine.roundPennies(fields.revisedAmount)
                )
            }
        }
        return reviews
    }
}

struct TimesheetPayrollLineEditHoursSheet: View {
    let row: TimesheetPayrollLineItem
    /// Every payroll line of the sheet (to find the booking's other line).
    let lines: [TimesheetPayrollLineItem]
    let policy: OrgPayrollTimePolicy
    let initialChoice: OperativeDayBookingChoice?
    /// The person's employment fields (`CanonicalBusinessEngine.timesheetPerson`): a PAYE day pays 0.
    let employment: [String: Any]?
    let onSave: (TimesheetPayrollLineBookingLookup.Edit) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var refusal: String?

    private func edit(_ start: String, _ end: String, _ breakRemoved: Bool, _ otMult: Double?) -> TimesheetPayrollLineBookingLookup.Edit {
        TimesheetPayrollLineBookingLookup.payrollLineEdit(
            row: row,
            lines: lines,
            startTime: start,
            endTime: end,
            breakRemoved: breakRemoved,
            typedOvertimeRate: otMult,
            policy: policy,
            employment: employment
        )
    }

    var body: some View {
        OperativeCustomHoursSheet(
            policy: policy,
            // RULEBOOK 1.19.0: the working hours in effect on the line's day (was today's).
            referenceDay: row.date,
            title: "Edit Hours",
            subtitle: "\(row.date.formatted(date: .abbreviated, time: .omitted)) · \(row.jobNumber) \(row.projectName)",
            allowsOtMultiplierOverride: row.isOvertimeLine,
            showsBreakControls: !row.isOvertimeLine,
            showsBreakdown: true,
            showsFooterNote: false,
            initialChoice: initialChoice,
            onSave: { start, end, breakRemoved, otMult in
                let result = edit(start, end, breakRemoved, otMult)
                // RULEBOOK 1.46.0: blank times or a start equal to the finish are never priced.
                if let error = result.error ?? (result.amounts == nil ? CanonicalBusinessEngine.payrollLineEditTimesMessage : nil) {
                    refusal = error
                    return
                }
                onSave(result)
                dismiss()
            },
            onCancel: { dismiss() }
        )
        .withAmountPreview { start, end, breakRemoved, otMult in
            edit(start, end, breakRemoved, otMult).amounts.map { OrgMoney.format($0.total) }
        }
        .alert("Cannot save these hours", isPresented: Binding(get: { refusal != nil }, set: { if !$0 { refusal = nil } })) {
            Button("OK", role: .cancel) { refusal = nil }
        } message: {
            Text(refusal ?? "")
        }
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
                Text(OrgMoney.format(original))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .strikethrough(decision == .declined || decision == .edited, color: .secondary)
                Text(OrgMoney.format(effective))
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(decision.tint)
            }
        } else {
            Text(OrgMoney.format(original))
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
                ? "\(OrgMoney.format(entry.amount)) → \(OrgMoney.format(entry.managerRevisedAmount ?? entry.amount))"
                : nil
            rows.append(("Expense: \(entry.title)", entry.managerDecision, detail))
        }
        for entry in draft.priceWorkEntries where entry.managerDecision != .approved && entry.managerDecision != .pending {
            let detail: String? = entry.managerDecision == .edited
                ? "\(OrgMoney.format(entry.amount)) → \(OrgMoney.format(entry.managerRevisedAmount ?? entry.amount))"
                : nil
            rows.append(("Price work: \(entry.title)", entry.managerDecision, detail))
        }
        for (lineId, review) in draft.payrollLineReviews where review.decision == .declined || review.decision == .edited {
            let label = review.decision == .declined ? "Day removed" : "Day adjusted"
            let detail: String? = review.decision == .edited
                ? "New amount \(OrgMoney.format(review.revisedAmount ?? 0))"
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
                        Text(OrgMoney.symbol())
                        TextField("Amount", text: $amountText)
                            .accessibilityIdentifier("timesheetManagerAmountEdit.amount")
                            .keyboardType(.decimalPad)
                    }
                    Text("Original: \(OrgMoney.format(originalAmount))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if allowsDelete, let onDelete {
                    Section {
                        Button("Delete this day from timesheet", role: .destructive) {
                            onDelete()
                            dismiss()
                        }
                            .accessibilityIdentifier("timesheetManagerAmountEdit.deleteThisDayFromTimesheet")
                    }
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .accessibilityIdentifier("timesheetManagerAmountEdit.cancel")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        let cleaned = amountText.replacingOccurrences(of: OrgMoney.symbol(), with: "").trimmingCharacters(in: .whitespaces)
                        if let value = Double(cleaned), value >= 0 {
                            onSave(value)
                            dismiss()
                        }
                    }
                        .accessibilityIdentifier("timesheetManagerAmountEdit.save")
                }
            }
        }
        .presentationDetents([.medium])
    }
}
