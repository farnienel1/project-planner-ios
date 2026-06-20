//
//  ScheduleBookingConflictSupport.swift
//  Project Planner
//
//  Annual leave, project/small-works, and My Schedule clash detection for scheduling flows.
//

import Foundation

// MARK: - Bookable people

struct ScheduleBookablePerson: Identifiable, Hashable {
    let operativeId: UUID
    let userId: String?
    let name: String
    let email: String
    let roleLabel: String
    let tradeLabel: String
    let hasPastBookingOnProject: Bool

    var id: UUID { operativeId }
}

enum ScheduleBookablePersonBuilder {
    static func build(
        operatives: [Operative],
        users: [AppUser],
        projectId: UUID,
        bookings: [Booking]
    ) -> [ScheduleBookablePerson] {
        var rows: [ScheduleBookablePerson] = []
        var seenEmails = Set<String>()

        let pastOperativeIds = Set(
            bookings
                .filter { $0.projectId == projectId && ($0.status == .confirmed || $0.status == .tentative) }
                .map(\.operativeId)
        )

        func append(operative: Operative, user: AppUser?, role: String) {
            let email = operative.email.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
            guard seenEmails.insert(email).inserted else { return }
            rows.append(
                ScheduleBookablePerson(
                    operativeId: operative.id,
                    userId: user?.id,
                    name: operative.name.isEmpty ? operative.email : operative.name,
                    email: operative.email,
                    roleLabel: role,
                    tradeLabel: operative.displayTradeType,
                    hasPastBookingOnProject: pastOperativeIds.contains(operative.id)
                )
            )
        }

        let activeOps = operatives.filter(\.isActive)
        for op in activeOps.sorted(by: { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }) {
            let email = op.email.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
            let user = users.first { $0.email.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) == email }
            let role: String = {
                guard let user else { return "Operative" }
                if user.permissions.adminAccess || user.isSuperAdmin { return "Admin" }
                if user.permissions.manager { return "Manager" }
                return "Operative"
            }()
            append(operative: op, user: user, role: role)
        }

        for user in users where user.isActive && user.passwordSet && !user.permissions.operativeMode {
            guard user.permissions.manager || user.permissions.adminAccess || user.isSuperAdmin else { continue }
            let email = user.email.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
            guard seenEmails.contains(email) == false else { continue }
            guard let op = operatives.first(where: {
                $0.email.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) == email
            }) else { continue }
            let role = user.permissions.adminAccess || user.isSuperAdmin ? "Admin" : "Manager"
            append(operative: op, user: user, role: role)
        }

        return rows
    }
}

// MARK: - Conflict rows

enum ScheduleConflictKind: Equatable {
    case approvedAnnualLeave
    case pendingAnnualLeave
    case projectBooking
    case smallWorksBooking
    case myScheduleItem
}

struct ScheduleConflictRow: Identifiable, Hashable {
    let id: String
    let operativeId: UUID
    let date: Date
    let kind: ScheduleConflictKind
    let title: String
    let detail: String
    /// Approved AL and auto-excluded days do not require acknowledgement.
    let requiresAcknowledgement: Bool

    static func rowId(operativeId: UUID, date: Date, kind: ScheduleConflictKind, suffix: String = "") -> String {
        let day = Calendar.current.startOfDay(for: date).timeIntervalSince1970
        return "\(operativeId.uuidString)|\(Int(day))|\(kind)|\(suffix)"
    }
}

enum ScheduleWarningTriangleColor {
    case none
    case orange
    case red
}

struct SchedulePersonConflictSummary {
    let operativeId: UUID
    let rows: [ScheduleConflictRow]
    let triangle: ScheduleWarningTriangleColor
    let hasUnactionedRows: Bool
    let effectiveSelectedDates: [Date]
    let droppedApprovedLeaveDates: [Date]
}

// MARK: - Engine

enum ScheduleBookingConflictEngine {
    static func linkedUserId(for operative: Operative, users: [AppUser]) -> String? {
        let email = operative.email.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        return users.first {
            $0.email.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) == email
        }?.id
    }

    static func holidayForPerson(
        operativeId: UUID,
        userId: String?,
        on date: Date,
        in holidays: [HolidayBooking]
    ) -> HolidayBooking? {
        let cal = Calendar.current
        let day = cal.startOfDay(for: date)
        return holidays.first { booking in
            let start = cal.startOfDay(for: booking.startDate)
            let end = cal.startOfDay(for: booking.endDate)
            guard day >= start && day <= end else { return false }
            if booking.operativeId == operativeId { return true }
            if let userId, booking.userId == userId { return true }
            return false
        }
    }

    static func buildConflictRows(
        person: ScheduleBookablePerson,
        selectedDates: Set<Date>,
        choice: OperativeDayBookingChoice,
        projectId: UUID,
        projectStore: ProjectStore,
        bookingStore: BookingStore,
        managerScheduleStore: ManagerScheduleStore,
        holidayStore: HolidayStore,
        policy: OrgPayrollTimePolicy,
        excludingBookingIds: Set<UUID>
    ) -> [ScheduleConflictRow] {
        guard !selectedDates.isEmpty else { return [] }
        let sortedDates = selectedDates.sorted()
        var rows: [ScheduleConflictRow] = []

        let probeBooker = "Schedule"
        for date in sortedDates {
            let day = Calendar.current.startOfDay(for: date)
            let probe = choice.bookingProbe(
                operativeId: person.operativeId,
                projectId: projectId,
                date: day,
                bookedBy: probeBooker
            )

            if let holiday = holidayForPerson(
                operativeId: person.operativeId,
                userId: person.userId,
                on: day,
                in: holidayStore.bookings
            ) {
                let formatted = day.formatted(date: .abbreviated, time: .omitted)
                if holiday.status == .approved {
                    rows.append(
                        ScheduleConflictRow(
                            id: ScheduleConflictRow.rowId(operativeId: person.operativeId, date: day, kind: .approvedAnnualLeave),
                            operativeId: person.operativeId,
                            date: day,
                            kind: .approvedAnnualLeave,
                            title: "\(formatted) — Annual leave (Approved)",
                            detail: "This day will be dropped from the booking.",
                            requiresAcknowledgement: false
                        )
                    )
                } else if holiday.status == .pending || holiday.cancellationRequestedAt != nil {
                    rows.append(
                        ScheduleConflictRow(
                            id: ScheduleConflictRow.rowId(operativeId: person.operativeId, date: day, kind: .pendingAnnualLeave, suffix: holiday.id.uuidString),
                            operativeId: person.operativeId,
                            date: day,
                            kind: .pendingAnnualLeave,
                            title: "\(formatted) — Annual leave (Pending)",
                            detail: "Acknowledge to include this day, or remove it from the booking.",
                            requiresAcknowledgement: true
                        )
                    )
                }
            }

            let existingProjectBookings = bookingStore.bookings.filter { booking in
                booking.operativeId == person.operativeId &&
                    Calendar.current.isDate(booking.date, inSameDayAs: day) &&
                    (booking.status == .confirmed || booking.status == .tentative) &&
                    !excludingBookingIds.contains(booking.id)
            }
            for existing in existingProjectBookings {
                guard OperativeBookingInterval.bookingsOverlap(probe, existing, policy: policy) else { continue }
                let existingProject = projectStore.projects.first(where: { $0.id == existing.projectId })
                    ?? projectStore.smallWorks.first(where: { $0.id == existing.projectId })
                let jobLabel: String = {
                    guard let p = existingProject else { return "Another booking" }
                    return "\(p.jobNumber) \(p.siteName)"
                }()
                let kind: ScheduleConflictKind = {
                    if let p = existingProject, p.jobType == .smallWorks { return .smallWorksBooking }
                    return .projectBooking
                }()
                let timeLabel = existing.scheduleLabel(policy: policy)
                rows.append(
                    ScheduleConflictRow(
                        id: ScheduleConflictRow.rowId(operativeId: person.operativeId, date: day, kind: kind, suffix: existing.id.uuidString),
                        operativeId: person.operativeId,
                        date: day,
                        kind: kind,
                        title: "\(day.formatted(date: .abbreviated, time: .omitted)) — \(timeLabel)",
                        detail: jobLabel,
                        requiresAcknowledgement: true
                    )
                )
            }

            if let uid = person.userId {
                let managerBookings = managerScheduleStore.managerSiteBookings.filter { booking in
                    booking.userId == uid &&
                        Calendar.current.isDate(booking.date, inSameDayAs: day)
                }
                for msb in managerBookings {
                    guard managerProbeOverlapsOperativeProbe(msb: msb, probe: probe, policy: policy) else { continue }
                    let location = myScheduleLocationLabel(msb, projectStore: projectStore)
                    let timeLabel = msb.workStartTime.flatMap { s in
                        msb.workEndTime.map { e in "\(s)–\($0)" }
                    } ?? msb.timeSlot.displayName
                    rows.append(
                        ScheduleConflictRow(
                            id: ScheduleConflictRow.rowId(operativeId: person.operativeId, date: day, kind: .myScheduleItem, suffix: msb.id.uuidString),
                            operativeId: person.operativeId,
                            date: day,
                            kind: .myScheduleItem,
                            title: "\(day.formatted(date: .abbreviated, time: .omitted)) — \(timeLabel)",
                            detail: location,
                            requiresAcknowledgement: true
                        )
                    )
                }
            }
        }
        return rows
    }

    static func summarizePerson(
        person: ScheduleBookablePerson,
        selectedDates: Set<Date>,
        isSelected: Bool,
        choice: OperativeDayBookingChoice,
        projectId: UUID,
        projectStore: ProjectStore,
        bookingStore: BookingStore,
        managerScheduleStore: ManagerScheduleStore,
        holidayStore: HolidayStore,
        policy: OrgPayrollTimePolicy,
        excludingBookingIds: Set<UUID>,
        manuallyExcludedDays: Set<Date>,
        acknowledgedRowIds: Set<String>,
        struckRowIds: Set<String>
    ) -> SchedulePersonConflictSummary? {
        guard isSelected else { return nil }
        let rows = buildConflictRows(
            person: person,
            selectedDates: selectedDates,
            choice: choice,
            projectId: projectId,
            projectStore: projectStore,
            bookingStore: bookingStore,
            managerScheduleStore: managerScheduleStore,
            holidayStore: holidayStore,
            policy: policy,
            excludingBookingIds: excludingBookingIds
        )
        let approvedDates = Set(rows.filter { $0.kind == .approvedAnnualLeave }.map { Calendar.current.startOfDay(for: $0.date) })
        let autoExcluded = approvedDates.union(manuallyExcludedDays)
        let struckDates = Set(
            rows.filter { struckRowIds.contains($0.id) }.map { Calendar.current.startOfDay(for: $0.date) }
        )
        let effective = selectedDates
            .map { Calendar.current.startOfDay(for: $0) }
            .filter { !autoExcluded.contains($0) && !struckDates.contains($0) }
            .sorted()

        let unactioned = rows.filter { row in
            guard row.requiresAcknowledgement else { return false }
            return !acknowledgedRowIds.contains(row.id) && !struckRowIds.contains(row.id)
        }
        let hasBookingClash = rows.contains { $0.kind != .approvedAnnualLeave && $0.kind != .pendingAnnualLeave }
            || rows.contains { $0.kind == .pendingAnnualLeave }
        let hasOnlyAL = !rows.isEmpty && rows.allSatisfy {
            $0.kind == .approvedAnnualLeave || $0.kind == .pendingAnnualLeave
        }
        let triangle: ScheduleWarningTriangleColor = {
            if unactioned.isEmpty && rows.isEmpty { return .none }
            if unactioned.contains(where: { $0.kind != .approvedAnnualLeave && $0.kind != .pendingAnnualLeave }) { return .red }
            if unactioned.contains(where: { $0.kind == .pendingAnnualLeave }) && hasBookingClash { return .red }
            if !unactioned.isEmpty { return .orange }
            if !rows.isEmpty && hasOnlyAL { return .orange }
            return .none
        }()

        return SchedulePersonConflictSummary(
            operativeId: person.operativeId,
            rows: rows,
            triangle: triangle,
            hasUnactionedRows: !unactioned.isEmpty,
            effectiveSelectedDates: effective,
            droppedApprovedLeaveDates: approvedDates.sorted()
        )
    }

    static func allActionableRowsResolved(
        people: [ScheduleBookablePerson],
        selectedOperativeIds: Set<UUID>,
        selectedDates: Set<Date>,
        choice: OperativeDayBookingChoice,
        projectId: UUID,
        projectStore: ProjectStore,
        bookingStore: BookingStore,
        managerScheduleStore: ManagerScheduleStore,
        holidayStore: HolidayStore,
        policy: OrgPayrollTimePolicy,
        excludingBookingIds: Set<UUID>,
        manuallyExcludedDaysByOperative: [UUID: Set<Date>],
        acknowledgedRowIds: Set<String>,
        struckRowIds: Set<String>
    ) -> Bool {
        for person in people where selectedOperativeIds.contains(person.operativeId) {
            let summary = summarizePerson(
                person: person,
                selectedDates: selectedDates,
                isSelected: true,
                choice: choice,
                projectId: projectId,
                projectStore: projectStore,
                bookingStore: bookingStore,
                managerScheduleStore: managerScheduleStore,
                holidayStore: holidayStore,
                policy: policy,
                excludingBookingIds: excludingBookingIds,
                manuallyExcludedDays: manuallyExcludedDaysByOperative[person.operativeId] ?? [],
                acknowledgedRowIds: acknowledgedRowIds,
                struckRowIds: struckRowIds
            )
            if summary?.hasUnactionedRows == true { return false }
            if summary?.effectiveSelectedDates.isEmpty == true { return false }
        }
        return !selectedOperativeIds.isEmpty
    }

    private static func managerProbeOverlapsOperativeProbe(
        msb: ManagerSiteBooking,
        probe: Booking,
        policy: OrgPayrollTimePolicy
    ) -> Bool {
        guard let probeIv = OperativeBookingInterval.clashInterval(for: probe, policy: policy),
              let msbIv = ManagerScheduleInterval.clashInterval(for: msb, policy: policy) else {
            return true
        }
        return OperativeBookingInterval.closedIntervalsOverlap(probeIv, msbIv)
    }

    private static func myScheduleLocationLabel(_ booking: ManagerSiteBooking, projectStore: ProjectStore) -> String {
        switch booking.locationType {
        case .office:
            return "My Schedule · Office"
        case .workingFromHome:
            return "My Schedule · Working from home"
        case .siteSurvey:
            return "My Schedule · Site survey"
        case .custom:
            let name = booking.customLocationName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return name.isEmpty ? "My Schedule · Custom" : "My Schedule · \(name)"
        case .project:
            if let id = booking.locationId,
               let p = projectStore.projects.first(where: { $0.id == id }) {
                return "My Schedule · \(p.jobNumber) \(p.siteName)"
            }
            return "My Schedule · Project"
        case .smallWork:
            if let id = booking.locationId,
               let sw = projectStore.smallWorks.first(where: { $0.id == id }) {
                return "My Schedule · \(sw.jobNumber) \(sw.siteName)"
            }
            return "My Schedule · Small works"
        }
    }
}
