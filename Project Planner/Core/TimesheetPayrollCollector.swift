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
        scheduleOptions: MyScheduleOptions = MyScheduleOptions()
    ) -> TimesheetPayrollSummary {
        let cal = Calendar.current
        let standardDayHours = max(policy.standardPaidHours, 0.01)
        let matchedOperatives = operatives.filter {
            $0.email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                == user.email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        }
        let operativeIds = Set(matchedOperatives.map(\.id))
        var lineItems: [TimesheetPayrollLineItem] = []
        var shiftCount = 0
        var totalHours = 0.0
        var overtimeHours = 0.0
        var baseAmount = 0.0
        var overtimeAmount = 0.0

        for booking in bookings where booking.status != .cancelled {
            guard operativeIds.contains(booking.operativeId) else { continue }
            let day = cal.startOfDay(for: booking.date)
            guard day >= range.lowerBound && day <= range.upperBound else { continue }
            shiftCount += 1
            let matchedOperative = matchedOperatives.first(where: { $0.id == booking.operativeId })
            let resolved = PayrollRateResolver.resolveForTimesheetDay(
                user: user,
                operative: matchedOperative,
                on: day,
                history: history,
                standardDayHours: standardDayHours
            )
            let paidHours = booking.paidBookedHours(policy: policy)
            let otHours = booking.overtimeHoursBeyondPaidStandard(policy: policy)
            let normalHours = max(0, paidHours - otHours)
            let otMultiplier = booking.effectiveWeekdayOtMultiplier(policy: policy)
            totalHours += paidHours
            overtimeHours += otHours

            let normalAmount = resolved.payForHours(normalHours, standardDayHours: standardDayHours)
            baseAmount += normalAmount
            let labels = projectLabel(for: booking.projectId, projects: projects, smallWorks: smallWorks)
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
                        details: "OT \(formatHours(otHours))h",
                        paidHours: otHours,
                        payrollBasis: resolved.basis,
                        dayRate: otDisplayRate,
                        hourlyRate: otDisplayHourly,
                        amount: otAmount,
                        isPayeDay: user.employmentType(on: day) == .paye,
                        isOvertimeLine: true
                    )
                )
            }
        }

        for booking in managerBookings where booking.userId == user.id {
            guard scheduleOptions.includesManagerScheduleLocation(booking) else { continue }
            let day = cal.startOfDay(for: booking.date)
            guard day >= range.lowerBound && day <= range.upperBound else { continue }
            shiftCount += 1
            let resolved = PayrollRateResolver.resolveForTimesheetDay(
                user: user,
                operative: matchedOperatives.first,
                on: day,
                history: history,
                standardDayHours: standardDayHours
            )
            let paidHours = booking.paidBookedHours(policy: policy)
            let otHours = booking.overtimeHoursBeyondPaidStandard(policy: policy)
            let normalHours = max(0, paidHours - otHours)
            let otMultiplier = policy.weekdayOutsideStandardMultiplier
            totalHours += paidHours
            overtimeHours += otHours

            let normalAmount = resolved.payForHours(normalHours, standardDayHours: standardDayHours)
            baseAmount += normalAmount
            let labels = managerBookingLabels(for: booking, projects: projects, smallWorks: smallWorks)
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
                        details: "OT \(formatHours(otHours))h",
                        paidHours: otHours,
                        payrollBasis: resolved.basis,
                        dayRate: otDisplayRate,
                        hourlyRate: otDisplayHourly,
                        amount: otAmount,
                        isPayeDay: user.employmentType(on: day) == .paye,
                        isOvertimeLine: true
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
        scheduleOptions: MyScheduleOptions = MyScheduleOptions()
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
            scheduleOptions: scheduleOptions
        )
    }

    static func projectLabel(
        for id: UUID,
        projects: [Project],
        smallWorks: [Project]
    ) -> (jobNumber: String, siteName: String) {
        if let project = projects.first(where: { $0.id == id }) {
            return (project.jobNumber, project.siteName)
        }
        if let project = smallWorks.first(where: { $0.id == id }) {
            return (project.jobNumber, project.siteName)
        }
        return ("—", "Unknown Project")
    }

    static func managerBookingLabels(
        for booking: ManagerSiteBooking,
        projects: [Project],
        smallWorks: [Project]
    ) -> (jobNumber: String, siteName: String) {
        switch booking.locationType {
        case .project, .smallWork:
            if let locationId = booking.locationId {
                return projectLabel(for: locationId, projects: projects, smallWorks: smallWorks)
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

    private static func formatHours(_ value: Double) -> String {
        let rounded = (value * 2).rounded() / 2
        if abs(rounded - rounded.rounded()) < 0.001 {
            return String(format: "%.0f", rounded)
        }
        return String(format: "%.1f", rounded)
    }
}
