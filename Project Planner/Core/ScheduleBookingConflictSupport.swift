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
    /// Every in-app id this person's bookings may carry (`bookingIdsForAccount`), so a booking under an old
    /// catalogue id or invite id still shows as a clash when they are booked again.
    var bookingIds: Set<UUID> = []

    var id: UUID { operativeId }

    func owns(_ booking: Booking) -> Bool {
        booking.operativeId == operativeId || bookingIds.contains(booking.operativeId)
    }
}

enum ScheduleBookablePersonBuilder {
    /// Operative catalogue plus operative user documents that have no matching operative.
    /// `listedCurrentLabourPeople` already drops an anonymised deleted profile. `passwordSet` is not required.
    /// `labourBookingKind` decides who is an operative. A user id that is not a UUID (a Firebase Auth uid)
    /// gets `Booking.internalOperativeId(for:)`, and saves write that uid back (web #189).
    /// This does not write `operativeProfiles`.
    @MainActor
    static func operativesForScheduling(
        operatives sourceOperatives: [Operative],
        users sourceUsers: [AppUser]
    ) -> [Operative] {
        let operatives = CanonicalBusinessEngine.listedCurrentLabourPeople(sourceOperatives) ?? sourceOperatives
        let users = CanonicalBusinessEngine.listedCurrentLabourPeople(sourceUsers) ?? sourceUsers
        var rows = operatives
        var seenEmails = Set(operatives.map { emailKey($0.email) }.filter { !$0.isEmpty })
        var seenIds = Set(operatives.map(\.id))
        for user in users where labourKind(user) == "operative" {
            let email = emailKey(user.email)
            if !email.isEmpty, seenEmails.contains(email) { continue }
            let id = Booking.internalOperativeId(for: user.id)
            guard seenIds.insert(id).inserted else { continue }
            rows.append(operativeRecord(from: user, id: id))
            if !email.isEmpty { seenEmails.insert(email) }
        }
        return rows
    }

    @MainActor
    static func build(
        operatives sourceOperatives: [Operative],
        users sourceUsers: [AppUser],
        projectId: UUID,
        bookings: [Booking]
    ) -> [ScheduleBookablePerson] {
        let operatives = operativesForScheduling(operatives: sourceOperatives, users: sourceUsers)
        let users = CanonicalBusinessEngine.listedCurrentLabourPeople(sourceUsers) ?? sourceUsers
        var rows: [ScheduleBookablePerson] = []
        var seenEmails = Set<String>()

        let pastOperativeIds = Set(
            bookings
                .filter { $0.projectId == projectId && $0.occupiesDay }
                .map(\.operativeId)
        )

        func append(operative: Operative, user: AppUser?, role: String) {
            let email = operative.email.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
            guard seenEmails.insert(email).inserted else { return }
            let bookingIds = (user.map { labourBookingIds(for: $0, operatives: sourceOperatives) } ?? []).union([operative.id])
            rows.append(
                ScheduleBookablePerson(
                    operativeId: operative.id,
                    userId: user?.id,
                    name: operative.name.isEmpty ? operative.email : operative.name,
                    email: operative.email,
                    roleLabel: role,
                    tradeLabel: operative.displayTradeType,
                    hasPastBookingOnProject: !pastOperativeIds.isDisjoint(with: bookingIds),
                    bookingIds: bookingIds
                )
            )
        }

        let activeOps = operatives.filter(\.isActive)
        for op in activeOps.sorted(by: { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }) {
            let email = op.email.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
            let user = users.first { emailKey($0.email) == email && !email.isEmpty }
                ?? users.first { $0.id == Booking.storedOperativeId(for: op.id) }
            let role: String = {
                guard let user else { return "Operative" }
                if user.permissions.adminAccess || user.isSuperAdmin { return "Admin" }
                if user.permissions.manager { return "Manager" }
                return "Operative"
            }()
            append(operative: op, user: user, role: role)
        }

        for user in users where user.passwordSet && labourKind(user) == "manager" {
            let email = user.email.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
            guard seenEmails.contains(email) == false else { continue }
            // A manager with no catalogue row is booked under their user id, like an operative.
            let op = operatives.first(where: {
                $0.email.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) == email
            }) ?? operativeRecord(from: user, id: Booking.internalOperativeId(for: user.id))
            let role = user.permissions.adminAccess || user.isSuperAdmin ? "Admin" : "Manager"
            append(operative: op, user: user, role: role)
        }

        return rows
    }

    /// `labourBookingKind` for a profile: "operative", "manager", or nil (not bookable labour).
    static func labourKind(_ user: AppUser) -> String? {
        CanonicalBusinessEngine.labourBookingKind(CanonicalLabourKindPerson(
            isActive: user.isActive,
            isOperativeMode: user.permissions.operativeMode || user.role == .operative,
            isManager: user.permissions.manager || user.role == .manager,
            isAdmin: user.permissions.adminAccess || user.role == .admin,
            isSuperAdmin: user.isSuperAdmin
        ))
    }

    private static func emailKey(_ value: String) -> String {
        value.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
    }

    @MainActor
    private static func operativeRecord(from user: AppUser, id: UUID) -> Operative {
        Operative(
            id: id,
            firstName: user.firstName,
            lastName: user.surname,
            email: user.email,
            phone: user.mobileNumber,
            startDate: user.createdAt,
            isActive: user.isActive,
            hourlyRate: user.hourlyRate,
            dayRate: user.dayRate,
            tradeTypePreset: user.tradeTypePreset,
            tradeTypeCustom: user.tradeTypeCustom,
            createdAt: user.createdAt,
            updatedAt: user.createdAt
        )
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
    /// The line under the person and day in the shared conflict row (`BookingConflictRowView`): "Annual leave booked ·
    /// AM" for leave (`bookingLeaveConflicts`), "Already booked · time · job" for a double booking.
    var conflictDetail: String? = nil

    static func rowId(operativeId: UUID, date: Date, kind: ScheduleConflictKind, suffix: String = "") -> String {
        let day = OrganizationRulebookContext.calendar.startOfDay(for: date).timeIntervalSince1970
        return "\(operativeId.uuidString)|\(Int(day))|\(kind)|\(suffix)"
    }

    /// The day at the front of a row title ("7 Nov 2026"), in the organisation zone (RULEBOOK §1), never the device's.
    static func dayTitle(_ day: Date) -> String {
        day.formatted(Date.FormatStyle(date: .abbreviated, time: .omitted, timeZone: OrganizationRulebookContext.timeZone))
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

    /// RULEBOOK 1.16.0 §5, §9 `bookingLeaveConflicts`: approved and pending leave on the selected days whose window
    /// overlaps this booking's slot, as purple rows the booker ticks (keep) or drops. Replaces the old app-side
    /// holiday match (device calendar, any slot, approved days dropped without asking).
    static func leaveConflictRows(
        person: ScheduleBookablePerson,
        sortedDates: [Date],
        choice: OperativeDayBookingChoice,
        holidays: [HolidayBooking],
        policy: OrgPayrollTimePolicy
    ) -> [ScheduleConflictRow] {
        let stored = Booking.storedOperativeId(for: person.operativeId)
        let others = person.bookingIds
            .map { Booking.storedOperativeId(for: $0) }
            .filter { $0 != stored }
            .sorted()
        let leavePerson = BookingLeaveConflictInputs.Person(
            id: stored,
            userId: person.userId,
            operativeIds: others,
            email: person.email
        )
        let conflicts = BookingLeaveConflictInputs.conflicts(
            people: [leavePerson],
            dates: sortedDates,
            holidays: holidays,
            users: RulebookRosterSnapshot.users,
            policy: policy,
            timeSlot: choice.timeSlot.rawValue,
            workStartTime: choice.workStartTime,
            workEndTime: choice.workEndTime
        )
        var dateByKey: [String: Date] = [:]
        for date in sortedDates { dateByKey[OrganizationRulebookContext.dayKey(date)] = date }
        // Days and their labels are organisation-zone days (RULEBOOK §1), never the device calendar.
        let calendar = OrganizationRulebookContext.calendar
        return conflicts.compactMap { conflict in
            guard let date = dateByKey[conflict.dayKey] else { return nil }
            let day = calendar.startOfDay(for: date)
            let kind: ScheduleConflictKind = conflict.isPending ? .pendingAnnualLeave : .approvedAnnualLeave
            return ScheduleConflictRow(
                id: ScheduleConflictRow.rowId(operativeId: person.operativeId, date: day, kind: kind, suffix: conflict.leaveId),
                operativeId: person.operativeId,
                date: day,
                kind: kind,
                title: "\(ScheduleConflictRow.dayTitle(day)) — \(conflict.detail)",
                detail: "Tick to book anyway, or ✕ to drop this day.",
                requiresAcknowledgement: true,
                conflictDetail: conflict.detail
            )
        }
    }

    /// What `buildConflictRows` depends on. The stores enter by revision, so a list redraw (a tap, a tick) reuses the
    /// rows instead of re-running the leave check (`bookingLeaveConflicts`) and the overlap scan for every person.
    private struct ConflictRowsKey: Hashable {
        let person: ScheduleBookablePerson
        let dates: [Date]
        let choice: OperativeDayBookingChoice
        let projectId: UUID
        let policy: OrgPayrollTimePolicy
        let excludingBookingIds: Set<UUID>
        let bookings: Int
        let managerBookings: Int
        let holidays: Int
        let projects: Int
        let roster: Int
        let timeZone: String
    }

    private static var conflictRowsCache: [ConflictRowsKey: [ScheduleConflictRow]] = [:]

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
        let key = ConflictRowsKey(
            person: person,
            dates: selectedDates.sorted(),
            choice: choice,
            projectId: projectId,
            policy: policy,
            excludingBookingIds: excludingBookingIds,
            bookings: bookingStore.revision,
            managerBookings: managerScheduleStore.revision,
            holidays: holidayStore.revision,
            projects: projectStore.revision,
            roster: RulebookRosterSnapshot.revision,
            timeZone: OrganizationRulebookContext.timeZoneIdentifier
        )
        if let cached = conflictRowsCache[key] { return cached }
        let rows = computeConflictRows(
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
        if conflictRowsCache.count > 400 { conflictRowsCache.removeAll() }
        conflictRowsCache[key] = rows
        return rows
    }

    private static func computeConflictRows(
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
        let calendar = OrganizationRulebookContext.calendar

        let probeBooker = "Schedule"
        let leaveRows = leaveConflictRows(
            person: person,
            sortedDates: sortedDates,
            choice: choice,
            holidays: holidayStore.bookings,
            policy: policy
        )
        for date in sortedDates {
            let day = calendar.startOfDay(for: date)
            let probe = choice.bookingProbe(
                operativeId: person.operativeId,
                projectId: projectId,
                date: day,
                bookedBy: probeBooker
            )

            rows.append(contentsOf: leaveRows.filter { calendar.isDate($0.date, inSameDayAs: day) })

            // RULEBOOK 1.23.0 §5 `CanonicalBusinessEngine.bookingRequestClashIds`: the person's bookings that day (and an
            // overnight one from the day before) whose slot overlaps this one, both under the booked day's working
            // hours (`day` = the policy state), never today's.
            let previousDay = calendar.date(byAdding: .day, value: -1, to: day) ?? day
            let candidateProjectBookings = bookingStore.bookings.filter { booking in
                person.owns(booking) &&
                    (calendar.isDate(booking.date, inSameDayAs: day) || calendar.isDate(booking.date, inSameDayAs: previousDay)) &&
                    booking.occupiesDay &&
                    !excludingBookingIds.contains(booking.id)
            }
            let candidateManagerBookings: [ManagerSiteBooking] = person.userId.map { uid in
                managerScheduleStore.managerSiteBookings.filter { booking in
                    booking.userId == uid &&
                        (calendar.isDate(booking.date, inSameDayAs: day) || calendar.isDate(booking.date, inSameDayAs: previousDay))
                }
            } ?? []
            let clashIds = Set((CanonicalBusinessEngine.bookingRequestClashIds(
                request: probe.rulebookClashBooking,
                existing: candidateProjectBookings.map(\.rulebookClashBooking)
                    + candidateManagerBookings.map(\.rulebookClashBooking),
                day: CanonicalBusinessEngine.bookingDayInput(policy: policy)
            ) ?? (candidateProjectBookings.map(\.id.uuidString) + candidateManagerBookings.map(\.id.uuidString))).map { $0.lowercased() })
            for existing in candidateProjectBookings {
                guard clashIds.contains(existing.id.uuidString.lowercased()) else { continue }
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
                        title: "\(ScheduleConflictRow.dayTitle(day)) — \(timeLabel)",
                        detail: jobLabel,
                        requiresAcknowledgement: true,
                        conflictDetail: "Already booked · \(timeLabel) · \(jobLabel)"
                    )
                )
            }

            do {
                for msb in candidateManagerBookings {
                    guard clashIds.contains(msb.id.uuidString.lowercased()) else { continue }
                    let location = myScheduleLocationLabel(msb, projectStore: projectStore)
                    let timeLabel = msb.workStartTime.flatMap { s in
                        msb.workEndTime.map { e in "\(s)–\(e)" }
                    } ?? msb.timeSlot.displayName
                    rows.append(
                        ScheduleConflictRow(
                            id: ScheduleConflictRow.rowId(operativeId: person.operativeId, date: day, kind: .myScheduleItem, suffix: msb.id.uuidString),
                            operativeId: person.operativeId,
                            date: day,
                            kind: .myScheduleItem,
                            title: "\(ScheduleConflictRow.dayTitle(day)) — \(timeLabel)",
                            detail: location,
                            requiresAcknowledgement: true,
                            conflictDetail: "Already booked · \(timeLabel) · \(location)"
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
        // RULEBOOK 1.16.0: approved leave is no longer dropped without asking; it is a row to tick or drop like the rest.
        let approvedDates: Set<Date> = []
        let calendar = OrganizationRulebookContext.calendar
        let autoExcluded = manuallyExcludedDays
        let struckDates = Set(
            rows.filter { struckRowIds.contains($0.id) }.map { calendar.startOfDay(for: $0.date) }
        )
        let effective = selectedDates
            .map { calendar.startOfDay(for: $0) }
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
