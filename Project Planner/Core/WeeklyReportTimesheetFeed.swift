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
        /// User ids whose live bookings this week already includes. A freshly built
        /// snapshot covers every account on the email. A stored snapshot covers only
        /// the account that approved it, until another approved week is merged in.
        var coveredUserIds: Set<String> = []
    }

    var weeks: [ApprovedWeek]

    static let empty = WeeklyReportTimesheetFeed(weeks: [])

    func covers(userId: String?, day: Date, calendar: Calendar = .current) -> Bool {
        guard let userId, !userId.isEmpty else { return false }
        let dayStart = calendar.startOfDay(for: day)
        return weeks.contains { week in
            let ids = week.coveredUserIds.isEmpty ? [week.userId] : week.coveredUserIds
            return ids.contains(userId)
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
            let reportingUser = StaffEmailIdentity.preferredUser(sharing: user.email, in: users) ?? user
            let tradeDisplay = StaffEmailIdentity.reportTrade(for: reportingUser)
            let tradeSortKey = StaffTradeType.sortKey(presetRaw: reportingUser.tradeTypePreset, custom: reportingUser.tradeTypeCustom)

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

                let storedAlready = draft.weeklyReportOverride != nil
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
                        viewer: nil,
                        relatedUsers: users
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
                let aliases = StaffEmailIdentity.userIds(sharing: user.email, in: users)
                weeks.append(
                    ApprovedWeek(
                        userId: user.id,
                        personName: name,
                        role: role,
                        tradeDisplay: tradeDisplay,
                        tradeSortKey: tradeSortKey,
                        weekStart: period.start,
                        weekEnd: period.end,
                        override: override,
                        coveredUserIds: storedAlready ? [user.id] : (aliases.isEmpty ? [user.id] : aliases)
                    )
                )
            }
        }

        return WeeklyReportTimesheetFeed(weeks: mergeApprovedWeeks(weeks, users: users))
    }

    /// One approved week per email. Shared booking ids count once. A booking that exists on only one draft stays.
    static func mergeApprovedWeeks(_ weeks: [ApprovedWeek], users: [AppUser], calendar: Calendar = .current) -> [ApprovedWeek] {
        var groups: [String: [ApprovedWeek]] = [:]
        for week in weeks {
            let email = StaffEmailIdentity.emailKey(users.first { $0.id == week.userId }?.email)
            let day = calendar.startOfDay(for: week.weekStart).timeIntervalSince1970
            let key = email.isEmpty ? "id:\(week.userId)|\(day)" : "email:\(email)|\(day)"
            groups[key, default: []].append(week)
        }
        return groups.values.map { @MainActor group in
            guard group.count > 1, let first = group.first else { return group[0] }
            let groupUsers = group.compactMap { week in users.first { $0.id == week.userId } }
            let preferredId = StaffEmailIdentity.preferredUser(groupUsers)?.id
            let display = group.first { $0.userId == preferredId } ?? first
            var merged = display
            merged.coveredUserIds = Set(group.flatMap { week -> [String] in
                week.coveredUserIds.isEmpty ? [week.userId] : Array(week.coveredUserIds)
            })
            merged.override.lines = unionLines(group.map { $0.override.lines }, identity: labourIdentity)
            merged.override.priceWork = unionLines(group.map { $0.override.priceWork }, identity: moneyIdentity)
            merged.override.expenses = unionLines(group.map { $0.override.expenses }, identity: moneyIdentity)
            return merged
        }
    }

    private static func unionLines<Line>(_ groups: [[Line]], identity: @MainActor (Line) -> String) -> [Line] {
        var bestCount: [String: Int] = [:]
        var sample: [String: Line] = [:]
        for lines in groups {
            var local: [String: Int] = [:]
            for line in lines {
                let key = identity(line)
                local[key, default: 0] += 1
                if sample[key] == nil { sample[key] = line }
            }
            for (key, count) in local {
                bestCount[key] = max(bestCount[key] ?? 0, count)
            }
        }
        var out: [Line] = []
        for (key, count) in bestCount {
            guard let line = sample[key] else { continue }
            for _ in 0..<count { out.append(line) }
        }
        return out
    }

    private static func labourIdentity(_ line: TimesheetWeeklyReportLabourLine) -> String {
        let bookingId = line.bookingId?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !bookingId.isEmpty {
            return "booking:\(bookingId)|\(line.isOvertime)"
        }
        let day = Calendar.current.startOfDay(for: line.date).timeIntervalSince1970
        return [
            "content",
            String(day),
            line.jobNumber,
            line.projectName,
            line.locationKind,
            line.details,
            String(format: "%.4f", line.paidHours),
            String(format: "%.4f", line.days),
            String(format: "%.2f", line.amount),
            line.isOvertime ? "ot" : "std",
            line.decision.rawValue
        ].joined(separator: "|")
    }

    private static func moneyIdentity(_ line: TimesheetWeeklyReportMoneyLine) -> String {
        let day = Calendar.current.startOfDay(for: line.date).timeIntervalSince1970
        return [
            line.title,
            line.jobNumber,
            line.details,
            String(day),
            String(format: "%.2f", line.amount),
            line.decision.rawValue
        ].joined(separator: "|")
    }
}
