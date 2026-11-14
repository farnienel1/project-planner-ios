//
//  TimesheetWeeklyReportOverrideBuilder.swift
//  Project Planner
//
//  Builds the agreed weekly-report snapshot stored on a fully approved timesheet.
//  iOS and the web app both read `weeklyReportOverride` from the timesheet settings doc.
//

import Foundation

enum TimesheetWeeklyReportOverrideBuilder {
    static func applyIfFullyApproved(
        to draft: inout TimesheetDraft,
        user: AppUser,
        week: WeekRange,
        bookings: [Booking],
        managerBookings: [ManagerSiteBooking],
        operatives: [Operative],
        projects: [Project],
        smallWorks: [Project],
        history: OperativeDayRateHistoryCollection,
        policy: OrgPayrollTimePolicy,
        organization: Organization?,
        scheduleOptions: MyScheduleOptions,
        viewer: AppUser?,
        relatedUsers: [AppUser] = [],
        writerIsReviewer: Bool? = nil,
        /// RULEBOOK 1.43.0 §8 `timesheetSnapshotReady`: the period's bookings and pay inputs have loaded. An empty
        /// frozen snapshot is rebuilt only then, never from a partial download.
        snapshotInputsReady: Bool = false
    ) {
        // `timesheetOwnerWriteFields`: the owner writes the approved snapshot only when the sheet is self-signed
        // (`CanonicalBusinessEngine.timesheetSelfSigned` through `TimesheetApprovalPolicy`; 1.28.0: Timesheet self-sign on, or the Super Admin). An owner save (writerIsReviewer == false) with a line manager leaves the
        // stored snapshot exactly as the line manager wrote it.
        if writerIsReviewer == false, TimesheetApprovalPolicy.requiresLineManagerCounterSign(for: user) { return }
        guard TimesheetApprovalPolicy.isTimesheetFullyApproved(draft: draft, user: user) else {
            draft.weeklyReportOverride = nil
            return
        }
        if let existing = draft.weeklyReportOverride {
            // RULEBOOK 1.43.0 §8 `timesheetSnapshotNeedsRebuild`: a snapshot frozen with no labour lines (signed before
            // the period's bookings had loaded) is rebuilt from the live bookings when they hold labour lines and nobody
            // has exported the sheet. Signatures and who approved it stay as stored (web `applyWeeklyReportOverride`).
            // A snapshot with any labour line is never rebuilt or re-priced.
            if snapshotInputsReady && existing.lines.isEmpty && draft.exportedAt == nil {
                // Review r318: only bookings that existed when the sheet was approved count (PAYE days left out), so a
                // booking added to the period later never re-prices a sheet signed with price work or expenses only.
                let live = TimesheetPayrollCollector.collect(
                    for: user,
                    week: week,
                    bookings: bookings,
                    managerBookings: managerBookings,
                    operatives: operatives,
                    projects: projects,
                    smallWorks: smallWorks,
                    history: history,
                    policy: policy,
                    organization: organization,
                    scheduleOptions: scheduleOptions,
                    relatedUsers: relatedUsers
                )
                let needsRebuild = CanonicalBusinessEngine.timesheetSnapshotNeedsRebuild(
                    storedOverrideLineCount: existing.lines.count,
                    overrideApprovedAt: existing.approvedAt,
                    exportedAt: draft.exportedAt,
                    managerSignedAt: draft.managerSignedAt,
                    liveLabourLines: TimesheetPayrollCollector.snapshotRebuildLines(live.lineItems)
                )
                if needsRebuild {
                    let fresh = make(
                        user: user,
                        week: week,
                        draft: draft,
                        bookings: bookings,
                        managerBookings: managerBookings,
                        operatives: operatives,
                        projects: projects,
                        smallWorks: smallWorks,
                        history: history,
                        policy: policy,
                        organization: organization,
                        scheduleOptions: scheduleOptions,
                        viewer: viewer,
                        relatedUsers: relatedUsers
                    )
                    draft.weeklyReportOverride = TimesheetWeeklyReportOverride(
                        approvedAt: existing.approvedAt,
                        approvedByUserId: existing.approvedByUserId,
                        approvedByName: existing.approvedByName,
                        selfSigned: existing.selfSigned,
                        lines: fresh.lines,
                        priceWork: fresh.priceWork,
                        expenses: fresh.expenses
                    )
                    return
                }
            }
            // Keep the agreed labour snapshot. Later schedule edits must not undo a
            // counter-sign; only line-manager (or exported-tab) review changes apply.
            draft.weeklyReportOverride = reapplyReviews(
                to: existing,
                draft: draft,
                user: user,
                viewer: viewer
            )
            return
        }
        draft.weeklyReportOverride = make(
            user: user,
            week: week,
            draft: draft,
            bookings: bookings,
            managerBookings: managerBookings,
            operatives: operatives,
            projects: projects,
            smallWorks: smallWorks,
            history: history,
            policy: policy,
            organization: organization,
            scheduleOptions: scheduleOptions,
            viewer: viewer,
            relatedUsers: relatedUsers
        )
    }

    static func make(
        user: AppUser,
        week: WeekRange,
        draft: TimesheetDraft,
        bookings: [Booking],
        managerBookings: [ManagerSiteBooking],
        operatives: [Operative],
        projects: [Project],
        smallWorks: [Project],
        history: OperativeDayRateHistoryCollection,
        policy: OrgPayrollTimePolicy,
        organization: Organization?,
        scheduleOptions: MyScheduleOptions,
        viewer: AppUser?,
        relatedUsers: [AppUser] = []
    ) -> TimesheetWeeklyReportOverride {
        let summary = TimesheetPayrollCollector.collect(
            for: user,
            week: week,
            bookings: bookings,
            managerBookings: managerBookings,
            operatives: operatives,
            projects: projects,
            smallWorks: smallWorks,
            history: history,
            policy: policy,
            organization: organization,
            scheduleOptions: scheduleOptions,
            relatedUsers: relatedUsers
        )
        let managerHasSigned = draft.managerSignedAt != nil
        let applyLiveReview = true
        let selfSigned = !TimesheetApprovalPolicy.requiresLineManagerCounterSign(for: user)
        let approvedByUserId = draft.managerSignedByUserId
            ?? viewer?.id
            ?? user.id
        let approvedByName = draft.managerSignedByName
            ?? draft.operativeSignedByName
            ?? (viewer?.fullName.isEmpty == false ? viewer?.fullName : viewer?.email)
            ?? (user.fullName.isEmpty ? user.email : user.fullName)

        var labour: [TimesheetWeeklyReportLabourLine] = []
        labour.reserveCapacity(summary.lineItems.count)
        // RULEBOOK 1.46.0 (web `weeklyReportOverride.ts`): never two snapshot lines with one id — a part `{booking}-ot`
        // is left out when the booking has its own overtime line, and a line is never pushed twice.
        let liveIds = Set(summary.lineItems.map { $0.id.lowercased() })
        var pushedIds = Set<String>()
        func push(_ row: TimesheetWeeklyReportLabourLine) {
            guard pushedIds.insert(row.id.lowercased()).inserted else { return }
            labour.append(row)
        }
        for line in summary.lineItems {
            let review = TimesheetDraftAdjustments.payrollReview(in: draft, lineId: line.id, live: line)
            let decision = review?.decision ?? .approved
            // RULEBOOK 1.46.0 (web `weeklyReportOverride.ts`): each signed line records the booking's state at signing
            // and the review applied (`payrollLineReviewKey`), so a later save tests a review against the sheet as
            // signed, never against today's bookings.
            func signed(_ row: TimesheetWeeklyReportLabourLine) -> TimesheetWeeklyReportLabourLine {
                var row = row
                row.bookingHadOvertimeLine = line.bookingHasOvertimeLine
                row.appliedReviewKey = CanonicalBusinessEngine.payrollLineReviewKey(review) ?? ""
                return row
            }
            if TimesheetDraftAdjustments.isPayrollLineRemoved(
                line: line,
                draft: draft,
                managerHasSigned: managerHasSigned,
                applyLiveReview: applyLiveReview
            ) {
                push(signed(
                    labourLine(
                        from: line,
                        decision: .declined,
                        amount: 0,
                        days: 0,
                        managerBookings: managerBookings
                    )
                ))
                continue
            }
            let amount = TimesheetDraftAdjustments.effectivePayrollAmount(
                line: line,
                draft: draft,
                managerHasSigned: managerHasSigned,
                applyLiveReview: applyLiveReview
            )
            let linePolicy = organization.map { PayrollTimePolicyCatalog.policy(for: line.date, organization: $0) } ?? policy
            // RULEBOOK 1.46.0 `payrollLineReviewSnapshotParts`: an Edit hours review signs the hours and money of each
            // part it pays — a standard line carrying overtime becomes the standard line plus `{booking}-ot` at the
            // multiplier, never "1 day at the edited total".
            if let parts = CanonicalBusinessEngine.payrollLineReviewSnapshotParts(
                lineId: line.id,
                isOvertimeLine: line.isOvertimeLine,
                review: review
            ) {
                let standard = max(CanonicalBusinessEngine.weekdayPaidHours(linePolicy), 0.01)
                for part in parts {
                    if part.id != line.id && liveIds.contains(part.id.lowercased()) { continue }
                    var row = signed(labourLine(
                        from: line,
                        decision: .edited,
                        amount: part.amount,
                        days: part.paidHours / standard,
                        managerBookings: managerBookings
                    ))
                    row.id = part.id
                    row.paidHours = part.paidHours
                    row.isOvertime = part.isOvertime
                    row.otMultiplier = part.isOvertime ? part.otMultiplier : nil
                    // A part the review added (`{booking}-ot`) records the standard line it came from.
                    if part.id != line.id { row.reviewPartOf = line.id }
                    if part.isOvertime && !line.isOvertimeLine { row.projectName = "\(line.projectName) (Overtime)" }
                    push(row)
                }
                continue
            }
            let days = scaledDays(line: line, originalAmount: line.amount, effectiveAmount: amount, policy: linePolicy)
            push(signed(
                labourLine(
                    from: line,
                    decision: decision == .pending ? .approved : decision,
                    amount: amount,
                    days: days,
                    managerBookings: managerBookings
                )
            ))
        }

        let money = moneyLines(from: draft, managerHasSigned: managerHasSigned, applyLiveReview: applyLiveReview)

        return TimesheetWeeklyReportOverride(
            approvedAt: draft.managerSignedAt ?? draft.operativeSignedAt ?? Date(),
            approvedByUserId: approvedByUserId,
            approvedByName: approvedByName,
            selfSigned: selfSigned,
            lines: labour,
            priceWork: money.priceWork,
            expenses: money.expenses
        )
    }

    /// Internal (not private) so `Rulebook1460Tests` can check a signed sheet is never re-priced by a stale review.
    static func reapplyReviews(
        to existing: TimesheetWeeklyReportOverride,
        draft: TimesheetDraft,
        user: AppUser,
        viewer: AppUser?
    ) -> TimesheetWeeklyReportOverride {
        let managerHasSigned = draft.managerSignedAt != nil
        let money = moneyLines(from: draft, managerHasSigned: managerHasSigned, applyLiveReview: true)
        let approvedByUserId = draft.managerSignedByUserId
            ?? viewer?.id
            ?? existing.approvedByUserId
        let approvedByName = draft.managerSignedByName
            ?? draft.operativeSignedByName
            ?? (viewer?.fullName.isEmpty == false ? viewer?.fullName : viewer?.email)
            ?? existing.approvedByName
        let existingIds = Set(existing.lines.map { $0.id.lowercased() })
        // RULEBOOK 1.46.0 (web `weeklyReportOverride.ts` `reapplyReviews`): a signed line is never re-priced by an Edit
        // hours review that is stale against the sheet AS SIGNED — the same test as at signing (`payrollLineReview`)
        // with the booking fingerprint the line was signed with (a line signed before 1.46.0 has none, so a
        // fingerprinted review never applies to it) and whether the booking had its own overtime line then
        // (`bookingHadOvertimeLine`). A review that is the one applied at signing (`appliedReviewKey`) changes nothing.
        enum Found { case none, unchanged, review(TimesheetPayrollLineReview) }
        func review(for line: TimesheetWeeklyReportLabourLine) -> Found {
            let live: [String: Any] = [
                "bookingFingerprint": line.bookingFingerprint ?? "",
                "isOvertimeLine": line.isOvertime,
                "bookingHasOvertimeLine": line.bookingHadOvertimeLine == true,
            ]
            guard let review = TimesheetDraftAdjustments.payrollReview(in: draft, lineId: line.id, liveJSON: live) else { return .none }
            if let applied = line.appliedReviewKey, CanonicalBusinessEngine.payrollLineReviewKey(review) == applied { return .unchanged }
            return .review(review)
        }
        // `payrollLineReviewSnapshotParts`: the parts an Edit hours review signs, applied to the snapshot line of that
        // id — including a `{booking}-ot` line added for a standard line's overtime. When two reviews give a part of one
        // id, the line's own review wins, else the first line in snapshot order.
        var partsFrom: [String: [TimesheetWeeklyReportLabourLine]] = [:]
        var partById: [String: (row: TimesheetWeeklyReportLabourLine, own: Bool)] = [:]
        for line in existing.lines {
            guard case .review(let stored) = review(for: line), stored.decision != .declined,
                  let parts = CanonicalBusinessEngine.payrollLineReviewSnapshotParts(
                    lineId: line.id, isOvertimeLine: line.isOvertime, review: stored
                  ) else { continue }
            let standardDay: Double? = line.days > 0.0001 && line.paidHours > 0 ? line.paidHours / line.days : nil
            let appliedKey = CanonicalBusinessEngine.payrollLineReviewKey(stored) ?? ""
            let rows = parts.map { part -> TimesheetWeeklyReportLabourLine in
                var row = line
                row.id = part.id
                row.paidHours = part.paidHours
                row.days = standardDay.map { part.paidHours / $0 } ?? line.days
                row.amount = part.amount
                row.isOvertime = part.isOvertime
                row.otMultiplier = part.isOvertime ? part.otMultiplier : nil
                row.decision = .edited
                row.appliedReviewKey = appliedKey
                if part.id.lowercased() != line.id.lowercased() {
                    row.reviewPartOf = line.id
                    if part.isOvertime && !line.isOvertime { row.projectName = "\(line.projectName) (Overtime)" }
                }
                return row
            }
            partsFrom[line.id.lowercased()] = rows
            for row in rows {
                let key = row.id.lowercased()
                let own = key == line.id.lowercased()
                if let held = partById[key], held.own || !own { continue }
                partById[key] = (row, own)
            }
        }
        let byId = Dictionary(existing.lines.map { ($0.id.lowercased(), $0) }, uniquingKeysWith: { first, _ in first })
        let lines = existing.lines.flatMap { line -> [TimesheetWeeklyReportLabourLine] in
            // RULEBOOK 1.46.0 (web fourth review): a `{booking}-ot` line an Edit hours review added follows its standard
            // line's current review — recomputed with it, 0 when that review is declined or no longer pays overtime,
            // unchanged when that review is unchanged, stale, an approval or an amount-only edit. A booking's own
            // overtime line keeps its own review.
            if let partOf = line.reviewPartOf {
                guard let source = byId[partOf.lowercased()], case .review(let sourceReview) = review(for: source) else {
                    return [line]
                }
                let key = CanonicalBusinessEngine.payrollLineReviewKey(sourceReview) ?? ""
                if sourceReview.decision == .declined {
                    var declined = line
                    declined.amount = 0
                    declined.days = 0
                    declined.decision = .declined
                    declined.appliedReviewKey = key
                    return [declined]
                }
                if let recomputed = (partsFrom[source.id.lowercased()] ?? []).first(where: { $0.id.lowercased() == line.id.lowercased() }) {
                    // Web fifth review: the part keeps its own label and overtime flag; only its figures follow.
                    var row = line
                    row.paidHours = recomputed.paidHours
                    row.days = recomputed.days
                    row.amount = recomputed.amount
                    row.isOvertime = true
                    row.otMultiplier = recomputed.otMultiplier
                    row.decision = .edited
                    row.appliedReviewKey = recomputed.appliedReviewKey
                    return [row]
                }
                if sourceReview.decision == .edited, sourceReview.revisedStandardHours != nil {
                    var none = line
                    none.amount = 0
                    none.paidHours = 0
                    none.days = 0
                    none.decision = .edited
                    none.appliedReviewKey = key
                    return [none]
                }
                return [line]
            }
            let found = review(for: line)
            if case .unchanged = found { return [line] }
            let stored: TimesheetPayrollLineReview?
            if case .review(let value) = found { stored = value } else { stored = nil }
            let decision = stored?.decision ?? line.decision
            if decision == .declined {
                var declined = line
                declined.amount = 0
                declined.days = 0
                declined.decision = .declined
                declined.appliedReviewKey = CanonicalBusinessEngine.payrollLineReviewKey(stored) ?? ""
                return [declined]
            }
            let added = (partsFrom[line.id.lowercased()] ?? []).filter { !existingIds.contains($0.id.lowercased()) }
            if let part = partById[line.id.lowercased()] {
                var row = part.row
                row.bookingFingerprint = line.bookingFingerprint
                row.bookingHadOvertimeLine = line.bookingHadOvertimeLine
                return [row] + added
            }
            if decision == .edited, let stored, let revised = stored.revisedAmount {
                var edited = line
                if line.amount > 0.0001 {
                    edited.days = line.days * (revised / line.amount)
                }
                edited.amount = revised
                edited.decision = .edited
                edited.appliedReviewKey = CanonicalBusinessEngine.payrollLineReviewKey(stored) ?? ""
                return [edited]
            }
            var kept = line
            kept.decision = decision == .pending ? .approved : decision
            return [kept] + added
        }
        return TimesheetWeeklyReportOverride(
            approvedAt: draft.managerSignedAt ?? draft.operativeSignedAt ?? existing.approvedAt,
            approvedByUserId: approvedByUserId,
            approvedByName: approvedByName,
            selfSigned: !TimesheetApprovalPolicy.requiresLineManagerCounterSign(for: user),
            lines: lines,
            priceWork: money.priceWork,
            expenses: money.expenses
        )
    }

    private static func moneyLines(
        from draft: TimesheetDraft,
        managerHasSigned: Bool,
        applyLiveReview: Bool
    ) -> (priceWork: [TimesheetWeeklyReportMoneyLine], expenses: [TimesheetWeeklyReportMoneyLine]) {
        let priceWork: [TimesheetWeeklyReportMoneyLine] = draft.priceWorkEntries.map { entry in
            let decision = entry.managerDecision == .pending ? .approved : entry.managerDecision
            let amount = TimesheetDraftAdjustments.effectivePriceWorkAmount(
                entry,
                managerHasSigned: managerHasSigned,
                applyLiveReview: applyLiveReview
            )
            return TimesheetWeeklyReportMoneyLine(
                id: entry.id.uuidString,
                title: entry.title,
                details: entry.details,
                jobNumber: entry.jobNumber,
                date: entry.startDate,
                amount: amount,
                decision: decision
            )
        }
        let expenses: [TimesheetWeeklyReportMoneyLine] = draft.expenseEntries.map { entry in
            let decision = entry.managerDecision == .pending ? .approved : entry.managerDecision
            let amount = TimesheetDraftAdjustments.effectiveExpenseAmount(
                entry,
                managerHasSigned: managerHasSigned,
                applyLiveReview: applyLiveReview
            )
            return TimesheetWeeklyReportMoneyLine(
                id: entry.id.uuidString,
                title: entry.title,
                details: entry.details,
                jobNumber: entry.jobNumber,
                date: entry.date,
                amount: amount,
                decision: decision
            )
        }
        return (priceWork, expenses)
    }

    private static func scaledDays(
        line: TimesheetPayrollLineItem,
        originalAmount: Double,
        effectiveAmount: Double,
        policy: OrgPayrollTimePolicy
    ) -> Double {
        let standard = max(CanonicalBusinessEngine.weekdayPaidHours(policy), 0.01)
        let baseDays = max(0, line.paidHours) / standard
        guard originalAmount > 0.0001 else { return baseDays }
        return baseDays * (effectiveAmount / originalAmount)
    }

    private static func labourLine(
        from line: TimesheetPayrollLineItem,
        decision: TimesheetManagerDecision,
        amount: Double,
        days: Double,
        managerBookings: [ManagerSiteBooking]
    ) -> TimesheetWeeklyReportLabourLine {
        TimesheetWeeklyReportLabourLine(
            id: line.id,
            date: line.date,
            jobNumber: line.jobNumber,
            projectName: line.projectName,
            locationKind: locationKind(lineId: line.id, projectName: line.projectName, jobNumber: line.jobNumber, managerBookings: managerBookings),
            details: line.details,
            paidHours: line.paidHours,
            days: days,
            amount: amount,
            isOvertime: line.isOvertimeLine,
            decision: decision,
            bookingId: bookingId(from: line.id),
            // RULEBOOK 1.44.0 §8: stored with the signed line (web `payBasis`).
            payBasis: line.payrollBasis == .hourly ? "hourly" : "day",
            // RULEBOOK 1.46.0 §8: the booking as signed, so a later Edit hours review of another version never
            // re-prices the line; and an overtime line's multiplier (web `otMultiplier`).
            bookingFingerprint: line.bookingFingerprint,
            otMultiplier: line.isOvertimeLine ? line.otMultiplier : nil,
            // RULEBOOK 1.46.0 §8: the line's own PAYE flag and that it is not a leave line (payroll lines never are),
            // so the signed copy alone decides the invoice (`timesheetInvoiceRows`).
            isPayeDay: line.isPayeDay,
            isLeave: false
        )
    }

    static func bookingId(from lineId: String) -> String? {
        if lineId.hasPrefix("op-"), lineId.hasSuffix("-normal") {
            return String(lineId.dropFirst(3).dropLast(7))
        }
        if lineId.hasPrefix("op-"), lineId.hasSuffix("-ot") {
            return String(lineId.dropFirst(3).dropLast(3))
        }
        if lineId.hasPrefix("mgr-"), lineId.hasSuffix("-normal") {
            return String(lineId.dropFirst(4).dropLast(7))
        }
        if lineId.hasPrefix("mgr-"), lineId.hasSuffix("-ot") {
            return String(lineId.dropFirst(4).dropLast(3))
        }
        return nil
    }

    private static func locationKind(
        lineId: String,
        projectName: String,
        jobNumber: String,
        managerBookings: [ManagerSiteBooking]
    ) -> String {
        if lineId.hasPrefix("op-") {
            return ManagerLocationType.project.rawValue
        }
        if let idString = bookingId(from: lineId),
           let uuid = UUID(uuidString: idString),
           let booking = managerBookings.first(where: { $0.id == uuid }) {
            return booking.locationType.rawValue
        }
        let lower = projectName.lowercased()
        if lower.contains("office") { return ManagerLocationType.office.rawValue }
        if lower.contains("working from home") { return ManagerLocationType.workingFromHome.rawValue }
        if lower.contains("site survey") { return ManagerLocationType.siteSurvey.rawValue }
        if jobNumber == "—" { return ManagerLocationType.custom.rawValue }
        return ManagerLocationType.project.rawValue
    }
}
