//
//  WeeklyReportTimesheetFeed.swift
//  Project Planner
//
//  Loads fully approved timesheet `weeklyReportOverride` snapshots and tells
//  Weekly Report which live bookings to replace.
//

import Foundation
import FirebaseFirestore

struct WeeklyReportTimesheetFeed {
    struct ApprovedWeek {
        var userId: String
        var personName: String
        var role: String
        var tradeDisplay: String
        var tradeSortKey: String
        var weekStart: Date
        var weekEnd: Date
        var override: TimesheetWeeklyReportOverride
    }

    var weeks: [ApprovedWeek]

    static let empty = WeeklyReportTimesheetFeed(weeks: [])

    func covers(userId: String?, day: Date, calendar: Calendar = .current) -> Bool {
        guard let userId, !userId.isEmpty else { return false }
        let dayStart = calendar.startOfDay(for: day)
        return weeks.contains { week in
            week.userId == userId
                && dayStart >= calendar.startOfDay(for: week.weekStart)
                && dayStart <= calendar.startOfDay(for: week.weekEnd)
        }
    }

    func labourLines(in range: ClosedRange<Date>, calendar: Calendar = .current) -> [(week: ApprovedWeek, line: TimesheetWeeklyReportLabourLine)] {
        let start = calendar.startOfDay(for: range.lowerBound)
        let end = calendar.startOfDay(for: range.upperBound)
        var out: [(ApprovedWeek, TimesheetWeeklyReportLabourLine)] = []
        for week in weeks {
            for line in week.override.lines where line.decision != .declined {
                let day = calendar.startOfDay(for: line.date)
                guard day >= start && day <= end else { continue }
                out.append((week, line))
            }
        }
        return out
    }

    func moneyLines(
        _ keyPath: KeyPath<TimesheetWeeklyReportOverride, [TimesheetWeeklyReportMoneyLine]>,
        in range: ClosedRange<Date>,
        calendar: Calendar = .current
    ) -> [(week: ApprovedWeek, line: TimesheetWeeklyReportMoneyLine)] {
        let start = calendar.startOfDay(for: range.lowerBound)
        let end = calendar.startOfDay(for: range.upperBound)
        var out: [(ApprovedWeek, TimesheetWeeklyReportMoneyLine)] = []
        for week in weeks {
            for line in week.override[keyPath: keyPath] where line.decision != .declined && line.amount > 0.0001 {
                let day = calendar.startOfDay(for: line.date)
                guard day >= start && day <= end else { continue }
                out.append((week, line))
            }
        }
        return out
    }

    @MainActor
    static func load(
        users: [AppUser],
        range: ClosedRange<Date>,
        settings: OrganizationInvoicingSettings,
        firebaseBackend: FirebaseBackend,
        bookingStore: BookingStore,
        managerScheduleStore: ManagerScheduleStore,
        operativeStore: OperativeStore,
        projectStore: ProjectStore,
        dayRateHistory: OperativeDayRateHistoryCollection,
        payrollPolicy: OrgPayrollTimePolicy,
        scheduleOptions: MyScheduleOptions
    ) async -> WeeklyReportTimesheetFeed {
        let periods = TimesheetPayrollPolicy.payPeriodsOverlapping(range: range, settings: settings)
        let orgId = firebaseBackend.currentOrganization?.firestoreDocumentId
        var weeks: [ApprovedWeek] = []

        for user in users {
            guard user.participatesInTimesheets() else { continue }
            var listedFromCloud = false
            if let orgId {
                if let rows = try? await firebaseBackend.listTimesheetStates(
                    organizationId: orgId,
                    userId: user.id,
                    limit: 80
                ) {
                    listedFromCloud = true
                    for row in rows {
                        if let weekStart = (row["weekStart"] as? Timestamp)?.dateValue(),
                           let decoded = TimesheetDraftStore.decodeFirestoreMap(row) {
                            let day = Calendar.current.startOfDay(for: weekStart)
                            TimesheetDraftStore.save(decoded, userId: user.id, weekStart: day)
                        }
                    }
                }
            }

            let name = user.fullName.isEmpty ? user.email : user.fullName
            let role: String = {
                let adminLike = user.isSuperAdmin || user.permissions.adminAccess || user.role == .admin || user.role == .manager || user.permissions.manager
                return adminLike ? "Admin User" : "Operative"
            }()
            let tradeDisplay = user.displayTradeType
            let tradeSortKey = StaffTradeType.sortKey(presetRaw: user.tradeTypePreset, custom: user.tradeTypeCustom)

            for period in periods {
                var draft = TimesheetDraftStore.load(userId: user.id, weekStart: period.start)
                if !listedFromCloud, let orgId {
                    if let remote = await TimesheetDraftStore.refreshFromCloud(
                        userId: user.id,
                        weekStart: period.start,
                        firebaseBackend: firebaseBackend,
                        organizationId: orgId
                    ) {
                        draft = remote
                    }
                }
                guard TimesheetApprovalPolicy.isTimesheetFullyApproved(draft: draft, user: user) else { continue }

                var working = draft
                if working.weeklyReportOverride == nil {
                    TimesheetWeeklyReportOverrideBuilder.applyIfFullyApproved(
                        to: &working,
                        user: user,
                        week: period,
                        bookings: bookingStore.bookings,
                        managerBookings: managerScheduleStore.managerSiteBookings,
                        operatives: operativeStore.allOperatives,
                        projects: projectStore.projects,
                        smallWorks: projectStore.smallWorks,
                        history: dayRateHistory,
                        policy: payrollPolicy,
                        organization: firebaseBackend.currentOrganization,
                        scheduleOptions: scheduleOptions,
                        viewer: nil
                    )
                    if working.weeklyReportOverride != nil {
                        TimesheetDraftStore.save(working, userId: user.id, weekStart: period.start)
                        if let orgId {
                            await TimesheetDraftStore.saveToCloud(
                                working,
                                userId: user.id,
                                weekStart: period.start,
                                firebaseBackend: firebaseBackend,
                                organizationId: orgId
                            )
                        }
                    }
                }
                guard let override = working.weeklyReportOverride else { continue }
                weeks.append(
                    ApprovedWeek(
                        userId: user.id,
                        personName: name,
                        role: role,
                        tradeDisplay: tradeDisplay,
                        tradeSortKey: tradeSortKey,
                        weekStart: period.start,
                        weekEnd: period.end,
                        override: override
                    )
                )
            }
        }

        return WeeklyReportTimesheetFeed(weeks: weeks)
    }
}
