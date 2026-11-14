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
    /// `op-{uuid}` / `mgr-{uuid}`: the booking this line comes from (web `bookingId`).
    var bookingId: String? = nil
    /// `overlappingBookingIds`: the booking overlaps another on the same day. Still paid; shown amber
    /// with `OVERLAPPING_BOOKING_NOTE` to the person and their line manager.
    var isOverlapping: Bool = false
    /// RULEBOOK 1.22.0 `TimesheetTotalsLine` (CanonicalBusinessEngine `timesheetTotals`): on the standard line, the
    /// booking's weighted paid hours (`payrollHoursResult.totalPaidHours`) and its overtime clock hours
    /// (`payrollMultipliedHours`); on the overtime line, its multiplier and clock hours.
    var bookingPaidHours: Double? = nil
    var bookingOvertimeHours: Double? = nil
    var otMultiplier: Double? = nil
    var otClockHours: Double? = nil
    /// RULEBOOK 1.43.0 (display only, never stored): the booking's own clock times and break toggle. `details` now shows
    /// only this line's part (`payrollLineClockRanges`), so Edit hours reads the whole booking from these (web
    /// `bookingStartTime` / `bookingEndTime` / `bookingBreakRemoved`).
    var bookingStartTime: String? = nil
    var bookingEndTime: String? = nil
    var bookingBreakRemoved: Bool? = nil
    /// RULEBOOK 1.43.0 (review r318; rebuild check only, never stored): when the line's booking was created
    /// (`timesheetSnapshotNeedsRebuild` counts only bookings that existed when the sheet was approved).
    var bookingCreatedAt: Date? = nil
}

struct TimesheetPayrollSummary {
    var totalHours: Double
    var overtimeHours: Double
    var shiftCount: Int
    var baseAmount: Double
    var overtimeAmount: Double
    var lineItems: [TimesheetPayrollLineItem]
    /// True when a packed-script call (`payrollHoursResult` or `payForHours`) did not answer for some booking: the
    /// hours or pay shown are incomplete. Screens say "could not calculate" and nothing is signed or invoiced from
    /// it (money audit #15).
    var calculationFailed: Bool = false

    var workAmount: Double { baseAmount + overtimeAmount }

    static let calculationFailedMessage = "Pay could not be calculated for some bookings. Try again; nothing can be signed or invoiced until it is."
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
        relatedUsers: [AppUser] = []
    ) -> TimesheetPayrollSummary {
        // Pay periods and booking days are organisation-zone days (§1).
        let cal = OrganizationRulebookContext.calendar
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
        var calculationFailed = false
        /// Every paid booking, for `overlappingBookingIds` (web collector `paidBookings`).
        var paidBookings: [CanonicalOverlapBookingInput] = []
        let matchedOperatives = operatives.filter {
            $0.email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                == user.email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        }
        // Bookings under the person's uid, a former invite id, a same-email account or a catalogue row on their
        // email (`bookingIdsForAccount`), so a deleted and re-added person is paid for every booked day.
        let operativeIds = labourBookingIds(for: user, operatives: operatives).union(matchedOperatives.map(\.id))
        let personOperativeIds = PayrollRateResolver.personOperativeIds(user: user, operative: nil, operatives: operatives)

        let projectsById = Dictionary(projects.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let smallWorksById = Dictionary(smallWorks.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        /// One booking's lines (web `pushBooking`). PAYE days stay as lines with no pay
        /// (`employmentTypeOnDay`; the rate resolver returns no amount on a PAYE day).
        func pushBooking(
            idPrefix: String,
            bookingId: UUID,
            probe: Booking,
            day: Date,
            details: String,
            labels: (jobNumber: String, siteName: String),
            operative: Operative?,
            createdAt: Date?
        ) {
            let policy = dayPolicy(for: day)
            let standardDayHours = max(CanonicalBusinessEngine.weekdayPaidHours(policy), 0.01)
            shiftCount += 1
            let resolved = PayrollRateResolver.resolveForTimesheetDay(
                user: user,
                operative: operative,
                on: day,
                history: history,
                standardDayHours: standardDayHours,
                // RULEBOOK 1.36.0 §8: history under every operatives row of the person counts.
                personOperativeIds: personOperativeIds
            )
            // One rulebook result (`payrollHoursResult`): the same fields web's collector reads.
            let hours = PayrollHoursEngine.canonicalResult(booking: probe, day: probe.date, policy: policy)
            if hours == nil { calculationFailed = true }
            let paidHours = hours?.totalPaidHours ?? 0
            let otHours = hours?.outsideHours ?? 0
            let otMultiplier = hours?.outsideMultiplier ?? 1
            let normalHours = max(0, hours?.standardHours ?? 0)
            // RULEBOOK 1.20.3 / 1.20.4: hours at the multiplier as clock hours, with any unpaid break as plain hours
            // (`CanonicalBusinessEngine.payrollMultipliedHours`). Display only; pay below stays `otHours × otMultiplier`.
            let multiplied = PayrollHoursEngine.compute(booking: probe, day: probe.date, policy: policy).multipliedHours
            totalHours += paidHours
            overtimeHours += multiplied?.clockHours ?? otHours
            let isPaye = user.employmentType(on: day) == .paye
            let lineBookingId = "\(idPrefix)-\(bookingId.uuidString)"
            paidBookings.append(
                CanonicalOverlapBookingInput(
                    id: lineBookingId,
                    dayKey: OrganizationRulebookContext.dayKey(day),
                    timeSlot: probe.timeSlot.rawValue,
                    workStartTime: probe.workStartTime,
                    workEndTime: probe.workEndTime
                )
            )

            // RULEBOOK 1.43.0 §8 (owner rule, `payrollLineClockRanges`): a booking with clock times shows the
            // standard-window times on its standard line and the overtime times on its overtime line. Wording only; a
            // booking with no standard part keeps its own times, and a named slot (FULL DAY, AM, PM) keeps its name.
            let bookingStart = probe.workStartTime?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let bookingEnd = probe.workEndTime?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let hasClockTimes = !bookingStart.isEmpty && !bookingEnd.isEmpty
            let clockRanges = hasClockTimes ? hours.flatMap { CanonicalBusinessEngine.payrollLineClockRanges($0) } : nil
            let lineDetails = Self.standardLineDetails(
                clockRanges: clockRanges, isBreakRemoved: probe.isBreakRemoved, fallback: details
            )
            let otLineDetails = Self.overtimeLineDetails(clockRanges: clockRanges, multiplied: multiplied, otHours: otHours)

            let normalPay = resolved.payForHoursIfCalculated(normalHours, standardDayHours: standardDayHours)
            if normalPay == nil { calculationFailed = true }
            let normalAmount = normalPay ?? 0
            baseAmount += normalAmount
            lineItems.append(
                TimesheetPayrollLineItem(
                    id: "\(lineBookingId)-normal",
                    date: day,
                    jobNumber: labels.jobNumber,
                    projectName: labels.siteName,
                    details: lineDetails,
                    paidHours: normalHours,
                    payrollBasis: resolved.basis,
                    dayRate: resolved.dayRate ?? 0,
                    hourlyRate: resolved.hourlyRate,
                    amount: normalAmount,
                    isPayeDay: isPaye,
                    isOvertimeLine: false,
                    bookingId: lineBookingId,
                    bookingPaidHours: paidHours,
                    bookingOvertimeHours: multiplied?.clockHours ?? otHours,
                    bookingStartTime: hasClockTimes ? bookingStart : nil,
                    bookingEndTime: hasClockTimes ? bookingEnd : nil,
                    bookingBreakRemoved: hasClockTimes ? probe.isBreakRemoved : nil,
                    bookingCreatedAt: createdAt
                )
            )

            if otHours > 0.05 {
                let otPay = resolved.payForHoursIfCalculated(otHours, standardDayHours: standardDayHours, otMultiplier: otMultiplier)
                if otPay == nil { calculationFailed = true }
                let otAmount = otPay ?? 0
                overtimeAmount += otAmount
                let (otDisplayRate, otDisplayHourly) = overtimeDisplayRates(resolved: resolved, otMultiplier: otMultiplier)
                lineItems.append(
                    TimesheetPayrollLineItem(
                        id: "\(lineBookingId)-ot",
                        date: day,
                        jobNumber: labels.jobNumber,
                        projectName: "\(labels.siteName) (Overtime)",
                        // RULEBOOK 1.43.0: the overtime clock times (`payrollLineClockRanges`), with " · OT 6.5h × 2 − 0.5h
                        // break = 12.5h" only when a break came off the multiplied hours; no clock times → as before.
                        details: otLineDetails,
                        paidHours: otHours,
                        payrollBasis: resolved.basis,
                        dayRate: otDisplayRate,
                        hourlyRate: otDisplayHourly,
                        amount: otAmount,
                        isPayeDay: isPaye,
                        isOvertimeLine: true,
                        bookingId: lineBookingId,
                        otMultiplier: otMultiplier,
                        otClockHours: multiplied?.clockHours ?? otHours,
                        bookingStartTime: hasClockTimes ? bookingStart : nil,
                        bookingEndTime: hasClockTimes ? bookingEnd : nil,
                        bookingBreakRemoved: hasClockTimes ? probe.isBreakRemoved : nil,
                        bookingCreatedAt: createdAt
                    )
                )
            }
        }

        // Every booking is paid on its own; overlapping ones are flagged below, never merged.
        for booking in bookings {
            guard booking.occupiesDay, operativeIds.contains(booking.operativeId) else { continue }
            let day = cal.startOfDay(for: booking.date)
            guard day >= rangeStart && day <= rangeEnd else { continue }
            let policy = dayPolicy(for: day)
            let matchedOperative = matchedOperatives.first(where: { $0.id == booking.operativeId }) ?? matchedOperatives.first
            pushBooking(
                idPrefix: "op",
                bookingId: booking.id,
                probe: booking,
                day: day,
                details: booking.scheduleLabel(policy: policy),
                labels: projectLabel(for: booking.projectId, projectsById: projectsById, smallWorksById: smallWorksById),
                operative: matchedOperative,
                createdAt: booking.createdAt
            )
        }

        let managerIds = StaffEmailIdentity.userIds(sharing: user.email, in: relatedUsers + [user])
            .union(WorkAccess.managerBookingUserIds(for: user))
        for booking in managerBookings where managerIds.contains(booking.userId) {
            guard scheduleOptions.includesManagerScheduleLocation(booking) else { continue }
            let day = cal.startOfDay(for: booking.date)
            guard day >= rangeStart && day <= rangeEnd else { continue }
            let policy = dayPolicy(for: day)
            pushBooking(
                idPrefix: "mgr",
                bookingId: booking.id,
                probe: booking.operativePayrollProbe(),
                day: day,
                details: booking.scheduleLabel(policy: policy),
                labels: managerBookingLabels(for: booking, projectsById: projectsById, smallWorksById: smallWorksById),
                operative: matchedOperatives.first,
                createdAt: booking.createdAt
            )
        }

        // `overlappingBookingIds` over every paid booking (operative and manager), with the
        // organisation's standard day, as web's collector does. Touching times do not overlap.
        let overlapping = CanonicalBusinessEngine.overlappingBookingIds(
            paidBookings,
            day: CanonicalStandardDayInput(policy: policy),
            // RULEBOOK 1.23.0 §8: the organisation's working-hours state (each day's own hours), as pay reads them.
            dayState: organization == nil ? nil : CanonicalBusinessEngine.openOrganizationPayrollPolicyState
        )
        if !overlapping.isEmpty {
            for index in lineItems.indices {
                if let id = lineItems[index].bookingId, overlapping.contains(id) {
                    lineItems[index].isOverlapping = true
                }
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
            lineItems: sortedItems,
            calculationFailed: calculationFailed
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
        relatedUsers: [AppUser] = []
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
            relatedUsers: relatedUsers
        )
    }

    /// RULEBOOK 1.43.0 §8: a standard line's details — the standard-window times (`payrollLineClockRanges.standardText`,
    /// " · no break" when the booking removes the break), else `fallback` (the booking's own label: its times, or a named
    /// slot's name). Web `timesheetPayrollCollector` `standardDetails`.
    static func standardLineDetails(clockRanges: RulebookPayrollLineClockRanges?, isBreakRemoved: Bool, fallback: String) -> String {
        guard let text = clockRanges?.standardText, !text.isEmpty else { return fallback }
        return isBreakRemoved ? "\(text) · no break" : text
    }

    /// RULEBOOK 1.43.0 §8: an overtime line's details — the overtime times (`payrollLineClockRanges.overtimeText`), with
    /// " · OT <multipliedHoursText>" only when an unpaid break came off the multiplied hours; with no overtime times the
    /// 1.20.4 text (`overtimeDetails`). Web `timesheetPayrollCollector` `overtimeDetails`.
    static func overtimeLineDetails(
        clockRanges: RulebookPayrollLineClockRanges?,
        multiplied: RulebookMultipliedHours?,
        otHours: Double
    ) -> String {
        let multipliedText: String? = {
            guard let multiplied, multiplied.breakHours > 0 else { return nil }
            return "OT \(multiplied.text)"
        }()
        guard let text = clockRanges?.overtimeText, !text.isEmpty else {
            return overtimeDetails(multiplied: multiplied, otHours: otHours)
        }
        return multipliedText.map { "\(text) · \($0)" } ?? text
    }

    /// RULEBOOK 1.43.0 §8 (review r318): the live lines as `timesheetSnapshotNeedsRebuild` reads them — PAYE flag and
    /// the booking's creation time. A mapping only.
    static func snapshotRebuildLines(_ lines: [TimesheetPayrollLineItem]) -> [(isPayeDay: Bool, bookingCreatedAt: Date?)] {
        lines.map { (isPayeDay: $0.isPayeDay, bookingCreatedAt: $0.bookingCreatedAt) }
    }

    /// RULEBOOK 1.43.0 §8: what a timesheet line shows beside its rate line — `timesheetLineClockText(details)`, the clock
    /// part only, so the multiplied text (which the rate line shows) is never printed twice. Nil when nothing is left, or
    /// when the details are only the multiplied text (an older line stored as "OT 6.5h × 2 − 0.5h break = 12.5h").
    nonisolated static func lineClockLabel(_ details: String) -> String? {
        let clock = CanonicalBusinessEngine.timesheetLineClockText(details)
        guard !clock.isEmpty, CanonicalBusinessEngine.parseMultipliedHoursText(clock) == nil else { return nil }
        return clock
    }

    /// RULEBOOK 1.20.4: an overtime line's text — `multipliedHoursText` when an unpaid break came off the multiplied
    /// hours (`CanonicalBusinessEngine.multipliedHoursText`), else the clock hours at the multiplier. Never "6.25h".
    static func overtimeDetails(multiplied: RulebookMultipliedHours?, otHours: Double) -> String {
        if let multiplied, multiplied.breakHours > 0 { return "OT \(multiplied.text)" }
        return "OT \(ScheduleCoverageFormat.hours(multiplied?.clockHours ?? otHours))h"
    }

    /// Approved annual leave inside the period (`timesheetLeaveLines`): information rows with no hours,
    /// no pay and no edit control, for the person and their line manager. Never on an invoice.
    /// Records are this account's (`bookingIdsForAccount`: uid, former and same-email ids, and
    /// catalogue rows on the email), matched on the holiday's user id or operative id, as web does.
    static func leaveLines(
        for user: AppUser,
        in range: ClosedRange<Date>,
        holidays: [HolidayBooking],
        operatives: [Operative],
        organization: Organization? = nil
    ) -> [CanonicalTimesheetLeaveLine] {
        let account = CanonicalBusinessEngine.CanonicalBookingPersonAccount(
            id: user.id, email: user.email, formerIds: user.formerUserIds, aliasIds: user.sameEmailUserIds
        )
        let ids = CanonicalBusinessEngine.bookingIdsForAccount(
            account,
            operatives: operatives.map { CanonicalBusinessEngine.CanonicalBookingPersonOperative(id: $0.documentId, email: $0.email) }
        ) ?? [user.id]
        let idKeys = Set(ids.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }.filter { !$0.isEmpty })
        let records: [CanonicalTimesheetLeaveRecord] = holidays.compactMap { holiday in
            let userKey = (holiday.userId ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let operativeKey = (holiday.operativeIdRaw ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard (!userKey.isEmpty && idKeys.contains(userKey)) || (!operativeKey.isEmpty && idKeys.contains(operativeKey)) else {
                return nil
            }
            return CanonicalTimesheetLeaveRecord(
                id: holiday.documentId,
                startDayKey: holiday.startDayKey,
                endDayKey: holiday.endDayKey,
                timeSlot: holiday.timeSlot.rawValue,
                status: holiday.status.rawValue
            )
        }
        guard !records.isEmpty else { return [] }
        let lines = CanonicalBusinessEngine.timesheetLeaveLines(
            records,
            startDayKey: OrganizationRulebookContext.dayKey(range.lowerBound),
            endDayKey: OrganizationRulebookContext.dayKey(range.upperBound),
            nonWorkingDayKeys: OrganizationBankHolidays.dayKeys
        )
        // RULEBOOK 1.20.0 §8/§9 (`timeRange`): each line's clock range under the working day in effect that day.
        guard let organization else { return lines }
        return lines.map { line in
            guard let day = OrganizationRulebookContext.date(fromDayKey: line.dayKey) else { return line }
            return line.withLeaveTimeRange(policy: PayrollTimePolicyCatalog.policy(for: day, organization: organization))
        }
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

    private static func formatHours(_ value: Double) -> String {
        let rounded = (value * 2).rounded() / 2
        if abs(rounded - rounded.rounded()) < 0.001 {
            return String(format: "%.0f", rounded)
        }
        return String(format: "%.1f", rounded)
    }
}
