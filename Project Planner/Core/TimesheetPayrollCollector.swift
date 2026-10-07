//
//  TimesheetPayrollCollector.swift
//  Project Planner
//
//  Shared payroll line-item and summary collection for timesheets, invoicing, and exports.
//

import Foundation

struct TimesheetPayrollLineItem: Identifiable, Hashable {
    let id: String
    let date: Date
    let jobNumber: String
    let projectName: String
    let details: String
    let paidHours: Double
    let payrollBasis: PayrollRateBasis
    let dayRate: Double
    let hourlyRate: Double?
    let amount: Double
    let isPayeDay: Bool
    let isOvertimeLine: Bool
    /// Set on overtime lines so weekly-report labels can say `Hourly OT x1.5`.
    let otMultiplier: Double?

    init(
        id: String,
        date: Date,
        jobNumber: String,
        projectName: String,
        details: String,
        paidHours: Double,
        payrollBasis: PayrollRateBasis,
        dayRate: Double,
        hourlyRate: Double?,
        amount: Double,
        isPayeDay: Bool,
        isOvertimeLine: Bool,
        otMultiplier: Double? = nil
    ) {
        self.id = id
        self.date = date
        self.jobNumber = jobNumber
        self.projectName = projectName
        self.details = details
        self.paidHours = paidHours
        self.payrollBasis = payrollBasis
        self.dayRate = dayRate
        self.hourlyRate = hourlyRate
        self.amount = amount
        self.isPayeDay = isPayeDay
        self.isOvertimeLine = isOvertimeLine
        self.otMultiplier = otMultiplier
    }

    func payrollBreakdown(standardDayHours: Double) -> PayrollPayLineDisplay {
        let rate: Double? = {
            if isPayeDay { return 0 }
            switch payrollBasis {
            case .hourly: return hourlyRate
            case .dayRate: return dayRate
            }
        }()
        return PayrollPayLineFormatter.line(
            basis: payrollBasis,
            paidHours: paidHours,
            standardDayHours: standardDayHours,
            rate: rate,
            pay: amount,
            isOvertime: isOvertimeLine,
            otMultiplier: isOvertimeLine ? otMultiplier : nil,
            isPaye: isPayeDay
        )
    }
}

struct TimesheetPayrollSummary {
    var totalHours: Double
    var overtimeHours: Double
    var shiftCount: Int
    var baseAmount: Double
    var overtimeAmount: Double
    var lineItems: [TimesheetPayrollLineItem]

    var workAmount: Double { baseAmount + overtimeAmount }
}

enum TimesheetPayrollCollector {
    static func collect(
        for user: AppUser,
        in range: ClosedRange<Date>,
        bookings: [Booking],
        managerBookings: [ManagerSiteBooking],
        operatives: [Operative],
        projects: [Project],
        smallWorks: [Project],
        history: OperativeDayRateHistoryCollection,
        policy: OrgPayrollTimePolicy,
        organization: Organization? = nil,
        scheduleOptions: MyScheduleOptions = MyScheduleOptions(),
        payrollUserIds: [String] = [],
        livePrefersHourly: Bool = false,
        preferredHourlyRate: Double? = nil
    ) -> TimesheetPayrollSummary {
        let cal = Calendar.current
        let rangeStart = cal.startOfDay(for: range.lowerBound)
        let rangeEnd = cal.startOfDay(for: range.upperBound)
        func dayPolicy(for day: Date) -> OrgPayrollTimePolicy {
            if let organization {
                return PayrollTimePolicyCatalog.policy(for: day, organization: organization)
            }
            return policy
        }
        var lineItems: [TimesheetPayrollLineItem] = []
        var shiftCount = 0
        var totalHours = 0.0
        var overtimeHours = 0.0
        var baseAmount = 0.0
        var overtimeAmount = 0.0
        let matchedOperatives = operatives.filter {
            $0.email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                == user.email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        }
        let operativeIds = Set(matchedOperatives.map(\.id))

        let projectsById = Dictionary(projects.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let smallWorksById = Dictionary(smallWorks.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let eligibleBookings = bookings.filter { booking in
            guard booking.status != .cancelled, operativeIds.contains(booking.operativeId) else { return false }
            let day = cal.startOfDay(for: booking.date)
            guard day >= rangeStart && day <= rangeEnd else { return false }
            return TimesheetPayrollPolicy.isBillableSelfEmployedDay(user, on: day, calendar: cal)
        }
        let bookingsByDay = Dictionary(grouping: eligibleBookings) {
            "\($0.operativeId.uuidString)-\(cal.startOfDay(for: $0.date).timeIntervalSince1970)"
        }
        for group in bookingsByDay.values {
            guard let first = group.first else { continue }
            let day = cal.startOfDay(for: first.date)
            let policy = dayPolicy(for: day)
            for cluster in OperativeBookingInterval.payClusters(on: group, policy: policy) {
            let booking = cluster.payable
            let standardDayHours = max(policy.standardPaidHours, 0.01)
            shiftCount += 1
            let matchedOperative = matchedOperatives.first(where: { $0.id == booking.operativeId })
            let resolved = PayrollRateResolver.resolveForTimesheetDay(
                user: user,
                operative: matchedOperative,
                on: day,
                history: history,
                standardDayHours: standardDayHours,
                userIds: payrollUserIds,
                livePrefersHourly: livePrefersHourly,
                preferredHourlyRate: preferredHourlyRate
            )
            let paidHours = booking.paidBookedHours(policy: policy)
            let otHours = booking.overtimeHoursBeyondPaidStandard(policy: policy)
            let otMultiplier = booking.effectiveWeekdayOtMultiplier(policy: policy)
            let overtimePaidHours = otHours * otMultiplier
            let normalHours = max(0, paidHours - overtimePaidHours)
            totalHours += paidHours
            overtimeHours += otHours

            let normalAmount = resolved.payForHours(normalHours, standardDayHours: standardDayHours)
            baseAmount += normalAmount
            let labels = projectLabel(for: booking.projectId, projectsById: projectsById, smallWorksById: smallWorksById)
            lineItems.append(
                TimesheetPayrollLineItem(
                    id: "op-\(booking.id.uuidString)-normal",
                    date: day,
                    jobNumber: labels.jobNumber,
                    projectName: labels.siteName,
                    details: booking.scheduleLabel(policy: policy),
                    paidHours: normalHours,
                    payrollBasis: resolved.basis,
                    dayRate: resolved.dayRate ?? 0,
                    hourlyRate: resolved.hourlyRate,
                    amount: normalAmount,
                    isPayeDay: user.employmentType(on: day) == .paye,
                    isOvertimeLine: false
                )
            )

            if otHours > 0.05 {
                let otAmount = resolved.payForHours(otHours, standardDayHours: standardDayHours, otMultiplier: otMultiplier)
                overtimeAmount += otAmount
                let (otDisplayRate, otDisplayHourly) = overtimeDisplayRates(resolved: resolved, otMultiplier: otMultiplier)
                lineItems.append(
                    TimesheetPayrollLineItem(
                        id: "op-\(booking.id.uuidString)-ot",
                        date: day,
                        jobNumber: labels.jobNumber,
                        projectName: "\(labels.siteName) (Overtime)",
                        details: "OT \(ScheduleCoverageFormat.overtimeEquation(rawHours: otHours, multiplier: otMultiplier))",
                        paidHours: otHours,
                        payrollBasis: resolved.basis,
                        dayRate: otDisplayRate,
                        hourlyRate: otDisplayHourly,
                        amount: otAmount,
                        isPayeDay: user.employmentType(on: day) == .paye,
                        isOvertimeLine: true,
                        otMultiplier: otMultiplier
                    )
                )
            }
            }
        }

        for booking in managerBookings where booking.userId == user.id {
            guard scheduleOptions.includesManagerScheduleLocation(booking) else { continue }
            let day = cal.startOfDay(for: booking.date)
            guard day >= rangeStart && day <= rangeEnd else { continue }
            guard TimesheetPayrollPolicy.isBillableSelfEmployedDay(user, on: day, calendar: cal) else { continue }
            let policy = dayPolicy(for: day)
            let standardDayHours = max(policy.standardPaidHours, 0.01)
            shiftCount += 1
            let resolved = PayrollRateResolver.resolveForTimesheetDay(
                user: user,
                operative: matchedOperatives.first,
                on: day,
                history: history,
                standardDayHours: standardDayHours,
                userIds: payrollUserIds,
                livePrefersHourly: livePrefersHourly,
                preferredHourlyRate: preferredHourlyRate
            )
            let paidHours = booking.paidBookedHours(policy: policy)
            let otHours = booking.overtimeHoursBeyondPaidStandard(policy: policy)
            let otMultiplier = booking.effectiveWeekdayOtMultiplier(policy: policy)
            let overtimePaidHours = otHours * otMultiplier
            let normalHours = max(0, paidHours - overtimePaidHours)
            totalHours += paidHours
            overtimeHours += otHours

            let normalAmount = resolved.payForHours(normalHours, standardDayHours: standardDayHours)
            baseAmount += normalAmount
            let labels = managerBookingLabels(for: booking, projectsById: projectsById, smallWorksById: smallWorksById)
            lineItems.append(
                TimesheetPayrollLineItem(
                    id: "mgr-\(booking.id.uuidString)-normal",
                    date: day,
                    jobNumber: labels.jobNumber,
                    projectName: labels.siteName,
                    details: booking.scheduleLabel(policy: policy),
                    paidHours: normalHours,
                    payrollBasis: resolved.basis,
                    dayRate: resolved.dayRate ?? 0,
                    hourlyRate: resolved.hourlyRate,
                    amount: normalAmount,
                    isPayeDay: user.employmentType(on: day) == .paye,
                    isOvertimeLine: false
                )
            )

            if otHours > 0.05 {
                let otAmount = resolved.payForHours(otHours, standardDayHours: standardDayHours, otMultiplier: otMultiplier)
                overtimeAmount += otAmount
                let (otDisplayRate, otDisplayHourly) = overtimeDisplayRates(resolved: resolved, otMultiplier: otMultiplier)
                lineItems.append(
                    TimesheetPayrollLineItem(
                        id: "mgr-\(booking.id.uuidString)-ot",
                        date: day,
                        jobNumber: labels.jobNumber,
                        projectName: "\(labels.siteName) (Overtime)",
                        details: "OT \(ScheduleCoverageFormat.overtimeEquation(rawHours: otHours, multiplier: otMultiplier))",
                        paidHours: otHours,
                        payrollBasis: resolved.basis,
                        dayRate: otDisplayRate,
                        hourlyRate: otDisplayHourly,
                        amount: otAmount,
                        isPayeDay: user.employmentType(on: day) == .paye,
                        isOvertimeLine: true,
                        otMultiplier: otMultiplier
                    )
                )
            }
        }

        let sortedItems = lineItems.sorted {
            if $0.date == $1.date {
                if $0.isOvertimeLine == $1.isOvertimeLine {
                    return $0.jobNumber < $1.jobNumber
                }
                return !$0.isOvertimeLine && $1.isOvertimeLine
            }
            return $0.date < $1.date
        }

        return TimesheetPayrollSummary(
            totalHours: totalHours,
            overtimeHours: overtimeHours,
            shiftCount: shiftCount,
            baseAmount: baseAmount,
            overtimeAmount: overtimeAmount,
            lineItems: sortedItems
        )
    }

    static func collect(
        for user: AppUser,
        week: WeekRange,
        bookings: [Booking],
        managerBookings: [ManagerSiteBooking],
        operatives: [Operative],
        projects: [Project],
        smallWorks: [Project],
        history: OperativeDayRateHistoryCollection,
        policy: OrgPayrollTimePolicy,
        organization: Organization? = nil,
        scheduleOptions: MyScheduleOptions = MyScheduleOptions(),
        payrollUserIds: [String] = [],
        livePrefersHourly: Bool = false,
        preferredHourlyRate: Double? = nil
    ) -> TimesheetPayrollSummary {
        collect(
            for: user,
            in: week.start...week.end,
            bookings: bookings,
            managerBookings: managerBookings,
            operatives: operatives,
            projects: projects,
            smallWorks: smallWorks,
            history: history,
            policy: policy,
            organization: organization,
            scheduleOptions: scheduleOptions,
            payrollUserIds: payrollUserIds,
            livePrefersHourly: livePrefersHourly,
            preferredHourlyRate: preferredHourlyRate
        )
    }

    static func projectLabel(
        for id: UUID,
        projects: [Project],
        smallWorks: [Project]
    ) -> (jobNumber: String, siteName: String) {
        projectLabel(
            for: id,
            projectsById: Dictionary(projects.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }),
            smallWorksById: Dictionary(smallWorks.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        )
    }

    static func projectLabel(
        for id: UUID,
        projectsById: [UUID: Project],
        smallWorksById: [UUID: Project]
    ) -> (jobNumber: String, siteName: String) {
        if let project = projectsById[id] {
            return (project.jobNumber, project.siteName)
        }
        if let project = smallWorksById[id] {
            return (project.jobNumber, project.siteName)
        }
        return ("—", "Unknown Project")
    }

    static func managerBookingLabels(
        for booking: ManagerSiteBooking,
        projects: [Project],
        smallWorks: [Project]
    ) -> (jobNumber: String, siteName: String) {
        managerBookingLabels(
            for: booking,
            projectsById: Dictionary(projects.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }),
            smallWorksById: Dictionary(smallWorks.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        )
    }

    static func managerBookingLabels(
        for booking: ManagerSiteBooking,
        projectsById: [UUID: Project],
        smallWorksById: [UUID: Project]
    ) -> (jobNumber: String, siteName: String) {
        switch booking.locationType {
        case .project, .smallWork:
            if let locationId = booking.locationId {
                return projectLabel(for: locationId, projectsById: projectsById, smallWorksById: smallWorksById)
            }
            return ("—", "Site")
        case .office:
            return ("—", "Office")
        case .workingFromHome:
            return ("—", "Working from home")
        case .siteSurvey:
            return ("—", "Site survey")
        case .custom:
            let name = booking.customLocationName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return ("—", name.isEmpty ? "Custom location" : name)
        }
    }

    private static func overtimeDisplayRates(
        resolved: ResolvedPayrollRate,
        otMultiplier: Double
    ) -> (dayRate: Double, hourlyRate: Double?) {
        switch resolved.basis {
        case .dayRate:
            return ((resolved.dayRate ?? 0) * otMultiplier, resolved.hourlyRate)
        case .hourly:
            return (0, (resolved.hourlyRate ?? 0) * otMultiplier)
        }
    }

}
