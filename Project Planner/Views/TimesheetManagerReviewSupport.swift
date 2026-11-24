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

    #if DEBUG
    /// Tests only: `payrollReviewLookup` answers `.failed`, as when the packed script does not answer.
    static var simulateScriptFailureForTesting = false
    #endif

    /// The answer of `payrollLineReview`: a review, no review (none stored, or stale), or the script did not answer.
    enum PayrollReviewLookup {
        case review(TimesheetPayrollLineReview)
        case none
        case failed
    }

    /// `payrollLineReview(sheet, lineId, live)` with the live booking as the script reads it (a signed snapshot line passes
    /// the values it was signed with: `bookingFingerprint`, `isOvertimeLine`, `bookingHadOvertimeLine`).
    static func payrollReviewLookup(in draft: TimesheetDraft, lineId: String, liveJSON: [String: Any]?) -> PayrollReviewLookup {
        guard !draft.payrollLineReviews.isEmpty else { return .none }
        #if DEBUG
        if simulateScriptFailureForTesting { return .failed }
        #endif
        let reviews: [String: Any] = draft.payrollLineReviews.mapValues { $0.storedFields }
        var arguments: [Any] = [["payrollLineReviews": reviews], lineId]
        if let liveJSON { arguments.append(liveJSON) }
        guard let answer = CanonicalBusinessEngine.callJSON("payrollLineReview", arguments: arguments) else { return .failed }
        guard let row = answer as? [String: Any] else { return .none }
        return .review(TimesheetPayrollLineReview(stored: row, defaultDecision: .approved))
    }

    /// The review, or nil. RULEBOOK 1.46.0 (review of #233): with a live line the stale check cannot be skipped, so when
    /// the script did not answer this fails closed — no review (the line at its live amount), never the raw stored
    /// review, which could re-price a signed sheet. Save and sign refuse in that case (`payrollReviewLookup` .failed in
    /// `TimesheetWeeklyReportOverrideBuilder`). Without a live line the stored review is the answer, as before.
    static func payrollReview(in draft: TimesheetDraft, lineId: String, liveJSON: [String: Any]?) -> TimesheetPayrollLineReview? {
        switch payrollReviewLookup(in: draft, lineId: lineId, liveJSON: liveJSON) {
        case .review(let review): return review
        case .none: return nil
        case .failed:
            guard liveJSON == nil else {
                NSLog("PAYROLL_LINE_REVIEW_UNAVAILABLE line=%@ — canonical script did not answer; review not applied", lineId)
                return nil
            }
            return draft.payrollLineReviews[lineId]
        }
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
            // RULEBOOK 1.54.0 (web `extrasPendingReview`): a late extra waiting for the line manager's decision (an
            // ignored one — its id is a signed entry's — never waits).
            || (draft.lateExtras ?? []).contains { $0.managerDecision == .pending && $0.lateState != "ignored" }
    }

    // RULEBOOK 1.22.0 §8: sheet totals (labour, price work, expenses, total) are `CanonicalBusinessEngine.timesheetTotals`
    // (`TimesheetTotalsSource.totals`), the sum of the invoice rows. The Swift sums that were here are deleted.

    /// RULEBOOK 1.46.0: the line manager's current payroll adjustments — each live line's review through
    /// `payrollLineReview(sheet, lineId, live)`, so a review made against a booking that has changed since (stale) is
    /// never shown as current. A review with no live line pays nothing and is not listed.
    static func currentPayrollAdjustments(
        draft: TimesheetDraft,
        lines: [TimesheetPayrollLineItem]
    ) -> [(line: TimesheetPayrollLineItem, review: TimesheetPayrollLineReview)] {
        guard !draft.payrollLineReviews.isEmpty else { return [] }
        return lines.compactMap { line in
            guard let review = payrollReview(in: draft, lineId: line.id, live: line),
                  review.decision == .declined || review.decision == .edited else { return nil }
            return (line, review)
        }
    }

    static func managerAdjustmentCount(draft: TimesheetDraft, lines: [TimesheetPayrollLineItem]) -> Int {
        let payroll = currentPayrollAdjustments(draft: draft, lines: lines).count
        let expenses = draft.expenseEntries.filter { $0.managerDecision == .declined || $0.managerDecision == .edited }.count
        let priceWork = draft.priceWorkEntries.filter { $0.managerDecision == .declined || $0.managerDecision == .edited }.count
        return payroll + expenses + priceWork
    }
}

// MARK: - Review action bar

/// RULEBOOK 1.72.0 §8: a reviewer's ✕ waiting for its confirm — the booking delete (with its tombstone) or, on an
/// overtime line, the trim to the standard part.
struct TimesheetReviewRemoval: Identifiable {
    enum Action {
        case delete(RulebookTimesheetReviewBookingDelete)
        case trim(collection: String, bookingId: String, set: [String: Any], remove: [String])
    }

    let id = UUID()
    let warning: RulebookTimesheetReviewDeleteWarning
    let action: Action
    /// RULEBOOK 1.74.0: what the confirmed write records on the sheet in the same batch (`timesheetReviewerBookingEditRecord`,
    /// built from the booking read fresh); nil when nothing can be recorded (the 1.47.0 rule then applies).
    var sheetRecord: TimesheetReviewerEditSheetRecord? = nil

    /// The confirm's text: what is changed, the rulebook's message, the overtime note, and (for a delete) the undo note.
    var messageText: String {
        var parts = [warning.summary, warning.message]
        if let note = warning.overtimeNote { parts.append(note) }
        if case .delete = action { parts.append(warning.undoNote) }
        return parts.filter { !$0.isEmpty }.joined(separator: "\n\n")
    }
}

struct TimesheetManagerReviewActionBar: View {
    let decision: TimesheetManagerDecision
    let canEdit: Bool
    /// RULEBOOK 1.72.0: ✕ on a labour line removes its booking, offered only when the line names one
    /// (`timesheetLabourLineReviewActions`). Price work, expenses and late extras keep it.
    var canDecline: Bool = true
    /// RULEBOOK 1.76.0: ✓ is hidden while only booking edits are open ("Make changes" on a signed-off sheet before its
    /// first change, or an open revision the person has not signed yet).
    var canApprove: Bool = true
    let onApprove: () -> Void
    let onDecline: () -> Void
    let onEdit: () -> Void

    private var selection: TimesheetManagerDecision { decision.reviewSelection }

    var body: some View {
        HStack(spacing: 8) {
            if canApprove {
                reviewButton(
                    systemName: "checkmark",
                    activeTint: .green,
                    selected: selection.isReviewApproved,
                    inactive: selection == .declined,
                    action: onApprove
                )
            }
            if canDecline {
                reviewButton(
                    systemName: "xmark",
                    activeTint: .red,
                    selected: selection == .declined,
                    inactive: selection.isReviewApproved,
                    action: onDecline
                )
            }
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
    /// The booking UUID of a line id `op-{uuid}-normal` / `mgr-{uuid}-ot` (the collector's ids). The UUID itself holds
    /// hyphens, so the prefix and the suffix are taken off rather than splitting on "-" (before 1.72.0 the split read
    /// only the UUID's first group and never matched, so the editor fell back to the line's own times).
    static func bookingId(from lineId: String) -> UUID? {
        var bare = lineId
        for prefix in ["op-", "mgr-"] where bare.hasPrefix(prefix) { bare = String(bare.dropFirst(prefix.count)) }
        for suffix in ["-normal", "-ot"] where bare.hasSuffix(suffix) { bare = String(bare.dropLast(suffix.count)) }
        return UUID(uuidString: bare)
    }

    /// RULEBOOK 1.72.0: the collection of the booking a line comes from (the line's own, else `mgr-` = manager site).
    static func reviewBookingCollection(_ row: TimesheetPayrollLineItem) -> String {
        if let collection = row.bookingCollection, !collection.isEmpty { return collection }
        return (row.bookingId ?? row.id).hasPrefix("mgr-") ? "managerSiteBookings" : "bookings"
    }

    /// RULEBOOK 1.72.0: the document ids to read the line's booking under, stored case first (`documentKey` from the
    /// store), then the UUID upper and lower case. Empty when the line names no booking.
    static func reviewBookingDocumentIds(
        _ row: TimesheetPayrollLineItem,
        bookings: [Booking],
        managerBookings: [ManagerSiteBooking]
    ) -> [String] {
        guard let uuid = bookingId(from: row.bookingId ?? row.id) else { return [] }
        var ids: [String] = []
        if reviewBookingCollection(row) == "managerSiteBookings" {
            if let stored = managerBookings.first(where: { $0.id == uuid }) { ids.append(stored.documentKey) }
        } else if let stored = bookings.first(where: { $0.id == uuid }) {
            ids.append(stored.documentKey)
        }
        ids.append(uuid.uuidString)
        ids.append(uuid.uuidString.lowercased())
        return ids
    }

    /// "Mon 23 Nov · J-1042 · Station Road · 07:00–16:00" for the review confirm (organisation-zone day; the title and
    /// times from `timesheetLineDisplay`).
    static func reviewLineDayAndTitle(_ row: TimesheetPayrollLineItem) -> String {
        let display = CanonicalBusinessEngine.timesheetLineDisplay(
            jobNumber: row.jobNumber,
            projectName: row.projectName,
            details: row.details,
            date: row.date
        )
        return [reviewDayText(row.date), display?.title ?? "\(row.jobNumber) \(row.projectName)"]
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
    }

    /// "Mon 23 Nov" in the organisation zone.
    static func reviewDayText(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_GB")
        formatter.timeZone = OrganizationRulebookContext.timeZone
        formatter.dateFormat = "EEE d MMM"
        return formatter.string(from: date)
    }

    static func reviewBookingSummary(_ row: TimesheetPayrollLineItem) -> String {
        let display = CanonicalBusinessEngine.timesheetLineDisplay(
            jobNumber: row.jobNumber,
            projectName: row.projectName,
            details: row.details,
            date: row.date
        )
        let title = display?.title ?? "\(row.jobNumber) \(row.projectName)"
        let times = display?.times ?? ""
        return [reviewDayText(row.date), title, times].filter { !$0.isEmpty }.joined(separator: " · ")
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
                // RULEBOOK 1.72.0: the editor opens on the booking's own rate, so a rate nobody changed is never written.
                otMultiplierOverride: booking.otMultiplierOverride
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
    /// Nil (review of #233, fail closed) when a line's current review could not be checked by the rulebook: the edit is
    /// refused (`TimesheetWeeklyReportOverrideBuilder.rulebookCheckFailedMessage`), never saved unchecked — a declined
    /// line would otherwise become approved, or the booking's other line be skipped.
    ///
    /// RULEBOOK 1.72.0 (decision A): the app no longer writes these reviews — ⚙ writes the booking
    /// (`timesheetReviewBookingEditWrites`). Kept to build the stored shape older sheets hold, which are still read
    /// exactly as before (guardrail 3), in the 1.46.0 tests.
    static func reviewsAfterEdit(
        _ edit: Edit,
        editedLineId: String,
        draft: TimesheetDraft
    ) -> [String: TimesheetPayrollLineReview]? {
        var reviews = draft.payrollLineReviews
        for line in [edit.standardLine, edit.overtimeLine].compactMap({ $0 }) {
            guard let fields = edit.reviewFieldsByLineId[line.id] else { continue }
            let existing: TimesheetPayrollLineReview?
            switch TimesheetDraftAdjustments.payrollReviewLookup(in: draft, lineId: line.id, liveJSON: line.rulebookLiveBookingJSON) {
            case .review(let found): existing = found
            case .none: existing = nil
            case .failed: return nil
            }
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

/// What a reviewer's ⚙ saved, for the booking write (RULEBOOK 1.72.0 `timesheetReviewBookingEditWrites`).
struct TimesheetReviewBookingEditInput {
    let startTime: String
    let endTime: String
    /// The sheet's "No unpaid break" state (an overtime line shows no break controls: the caller keeps the stored one).
    let breakRemoved: Bool
    /// The rate box on save (nil = the organisation's rate) and what it showed when the editor opened.
    let typedRate: Double?
    let openedRate: Double?
    /// The times the editor opened with (`slotWindow`): an unchanged Full day writes nothing.
    let openingTimes: (start: String, end: String)
}

struct TimesheetPayrollLineEditHoursSheet: View {
    let row: TimesheetPayrollLineItem
    /// Every payroll line of the sheet (to find the booking's other line).
    let lines: [TimesheetPayrollLineItem]
    let policy: OrgPayrollTimePolicy
    let initialChoice: OperativeDayBookingChoice?
    /// The person's employment fields (`CanonicalBusinessEngine.timesheetPerson`): a PAYE day pays 0.
    let employment: [String: Any]?
    /// RULEBOOK 1.72.0 §8 (decision A): saves the edit to the BOOKING. Returns a refusal message (nothing saved; the
    /// sheet stays open and shows it), or nil once saved.
    let onSaveBooking: (TimesheetReviewBookingEditInput) async -> String?

    @Environment(\.dismiss) private var dismiss
    @State private var refusal: String?
    @State private var saving = false

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
                guard !saving else { return }
                // RULEBOOK 1.46.0: blank times or a start equal to the finish are never priced (the preview's rule).
                let result = edit(start, end, breakRemoved, otMult)
                if let error = result.error ?? (result.amounts == nil ? CanonicalBusinessEngine.payrollLineEditTimesMessage : nil) {
                    refusal = error
                    return
                }
                let input = TimesheetReviewBookingEditInput(
                    startTime: start,
                    endTime: end,
                    breakRemoved: breakRemoved,
                    typedRate: otMult,
                    openedRate: initialChoice?.otMultiplierOverride,
                    openingTimes: OperativeCustomHoursSheet.openingTimes(
                        policy: policy,
                        referenceDay: row.date,
                        initialChoice: initialChoice
                    )
                )
                saving = true
                Task { @MainActor in
                    let message = await onSaveBooking(input)
                    saving = false
                    if let message {
                        refusal = message
                    } else {
                        dismiss()
                    }
                }
            },
            onCancel: { dismiss() }
        )
        .withAmountPreview(allowsOvernight: true) { start, end, breakRemoved, otMult in
            edit(start, end, breakRemoved, otMult).amounts.map { OrgMoney.format($0.total) }
        }
        // RULEBOOK 1.72.0 §8: "Save to booking" and `TIMESHEET_REVIEW_EDIT_BOOKING_NOTE`.
        .withSaveToBooking(title: "Save to booking", note: CanonicalBusinessEngine.timesheetReviewEditBookingNote)
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
    /// The sheet's live payroll lines: each review is checked against its line (RULEBOOK 1.46.0 `payrollLineReview`).
    let lines: [TimesheetPayrollLineItem]
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
        // RULEBOOK 1.46.0: only reviews that still apply to the live line (a stale edit is not shown as current); the
        // amount is what the review pays (`timesheetEntryEffectiveAmount`, pennies).
        for (line, review) in TimesheetDraftAdjustments.currentPayrollAdjustments(draft: draft, lines: lines) {
            let label = review.decision == .declined ? "Day removed" : "Day adjusted"
            let detail: String? = review.decision == .edited
                ? "\(OrgMoney.format(line.amount)) → \(OrgMoney.format(TimesheetDraftAdjustments.effectivePayrollAmount(line: line, draft: draft, managerHasSigned: true)))"
                : nil
            // RULEBOOK 1.72.0 (issue 21): name the day (organisation zone) and the job (`timesheetLineDisplay` title),
            // never the line id: "Day adjusted · Mon 23 Nov · J-1042 · Station Road".
            rows.append(("\(label) · \(TimesheetPayrollLineBookingLookup.reviewLineDayAndTitle(line))", review.decision, detail))
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
