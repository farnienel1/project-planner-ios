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
        viewer: AppUser?
    ) {
        guard TimesheetApprovalPolicy.isTimesheetFullyApproved(draft: draft, user: user) else {
            draft.weeklyReportOverride = nil
            return
        }
        if let existing = draft.weeklyReportOverride {
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
            viewer: viewer
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
        viewer: AppUser?
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
            scheduleOptions: scheduleOptions
        )
        let managerHasSigned = draft.managerSignedAt != nil
        let applyLiveReview = true
        let selfSigned = !user.hasLineManager
        let approvedByUserId = draft.managerSignedByUserId
            ?? viewer?.id
            ?? user.id
        let approvedByName = draft.managerSignedByName
            ?? draft.operativeSignedByName
            ?? (viewer?.fullName.isEmpty == false ? viewer?.fullName : viewer?.email)
            ?? (user.fullName.isEmpty ? user.email : user.fullName)

        var labour: [TimesheetWeeklyReportLabourLine] = []
        labour.reserveCapacity(summary.lineItems.count)
        for line in summary.lineItems {
            let decision = TimesheetDraftAdjustments.payrollReview(in: draft, lineId: line.id)?.decision ?? .approved
            if TimesheetDraftAdjustments.isPayrollLineRemoved(
                line: line,
                draft: draft,
                managerHasSigned: managerHasSigned,
                applyLiveReview: applyLiveReview
            ) {
                labour.append(
                    labourLine(
                        from: line,
                        decision: .declined,
                        amount: 0,
                        days: 0,
                        managerBookings: managerBookings
                    )
                )
                continue
            }
            let amount = TimesheetDraftAdjustments.effectivePayrollAmount(
                line: line,
                draft: draft,
                managerHasSigned: managerHasSigned,
                applyLiveReview: applyLiveReview
            )
            let days = scaledDays(line: line, originalAmount: line.amount, effectiveAmount: amount, policy: policy)
            labour.append(
                labourLine(
                    from: line,
                    decision: decision == .pending ? .approved : decision,
                    amount: amount,
                    days: days,
                    managerBookings: managerBookings
                )
            )
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

    private static func reapplyReviews(
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
        let lines = existing.lines.map { line -> TimesheetWeeklyReportLabourLine in
            let review = TimesheetDraftAdjustments.payrollReview(in: draft, lineId: line.id)
            let decision = review?.decision ?? line.decision
            if decision == .declined {
                var declined = line
                declined.amount = 0
                declined.days = 0
                declined.decision = .declined
                return declined
            }
            if decision == .edited, let revised = review?.revisedAmount {
                var edited = line
                if line.amount > 0.0001 {
                    edited.days = line.days * (revised / line.amount)
                }
                edited.amount = revised
                edited.decision = .edited
                return edited
            }
            var kept = line
            kept.decision = decision == .pending ? .approved : decision
            return kept
        }
        return TimesheetWeeklyReportOverride(
            approvedAt: draft.managerSignedAt ?? draft.operativeSignedAt ?? existing.approvedAt,
            approvedByUserId: approvedByUserId,
            approvedByName: approvedByName,
            selfSigned: !user.hasLineManager,
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
        let standard = max(policy.standardPaidHours, 0.01)
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
            bookingId: bookingId(from: line.id)
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
