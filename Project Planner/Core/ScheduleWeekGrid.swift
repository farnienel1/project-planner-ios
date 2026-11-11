//
//  ScheduleWeekGrid.swift
//  Project Planner
//
//  Person rows on the project / small-works week overview.
//  Colour and badge follow the account. An admin's operative bookings and
//  manager bookings are one row, keyed by that user id.
//

import Foundation

enum ScheduleWeekTone: String, Equatable {
    case blue
    case green
    case purple
    /// A booked id that names nobody on the roster: a neutral pill, never "Op".
    case grey
}

/// Account role for a week-overview row. Admin and manager share blue.
enum ScheduleWeekAccountRole: String, Equatable {
    case admin
    case manager
    case operative
    case subcontractor
    /// No account or catalogue row matches any booked id in the row (`resolveBookingPerson` found nobody).
    case unknown

    var badge: String {
        switch self {
        case .admin: return "Admin"
        case .manager: return "Mgr"
        case .operative: return "Op"
        case .subcontractor: return "Sub"
        case .unknown: return "?"
        }
    }

    /// Admin and manager are blue, operative green, subcontractor purple.
    var tone: ScheduleWeekTone {
        switch self {
        case .admin, .manager: return .blue
        case .operative: return .green
        case .subcontractor: return .purple
        case .unknown: return .grey
        }
    }

    static func from(account user: AppUser) -> ScheduleWeekAccountRole {
        // RULEBOOK 1.23.0 §11: the person's list (`CanonicalBusinessEngine.rosterListKind`); a `managers` row never decides it.
        switch user.rosterListKind {
        case .admins: return .admin
        case .managers: return .manager
        case .operatives: return .operative
        }
    }
}

struct ScheduleWeekPerson: Equatable, Identifiable {
    var id: String
    var name: String
    var role: ScheduleWeekAccountRole
    var operativeIds: [UUID]
    var userIds: [String]
    var subcontractorId: UUID?
    /// Roster operative bookings go to `bookings`. Admin and manager accounts do not.
    var savesAsOperativeBooking: Bool
    var saveOperativeId: UUID?
    var saveUserId: String?
}

enum ScheduleQuickAddSave: Equatable {
    case operativeBookings(operativeId: UUID)
    case managerSiteBookings(userId: String, locationType: ManagerLocationType)
}

struct ScheduleClockRange: Equatable {
    var start: String
    var end: String

    var label: String { "\(start)–\(end)" }
}

struct ScheduleQuickAddClocks: Equatable {
    var fullDay: ScheduleClockRange
    var morning: ScheduleClockRange
    var afternoon: ScheduleClockRange
}

struct ScheduleQuickAddDraft: Equatable {
    var timeSlot: TimeSlot
    var workStart: String
    var workEnd: String
    var notes: String?

    var managerTimeSlot: ManagerTimeSlot {
        switch timeSlot {
        case .morning: return .morning
        case .afternoon: return .afternoon
        case .fullDay: return .fullDay
        case .customHours: return .customHours
        default: return .customHours
        }
    }
}

enum ScheduleWeekGrid {
    static func staffRows(
        operativeIds: Set<UUID>,
        userIds: Set<String>,
        operatives: [Operative],
        users: [AppUser],
        resolve: StaffEmailIdentity.BookingPersonResolver? = nil
    ) -> [ScheduleWeekPerson] {
        let buckets = StaffEmailIdentity.scheduleBuckets(
            operativeIds: operativeIds,
            userIds: userIds,
            operatives: operatives,
            users: users,
            resolve: resolve
        )
        return buckets.map { bucket in
            person(from: bucket, operatives: operatives, users: users)
        }
        .sorted {
            let order = $0.name.localizedCaseInsensitiveCompare($1.name)
            if order == .orderedSame { return $0.id < $1.id }
            return order == .orderedAscending
        }
    }

    static func subcontractorRows(
        ids: Set<UUID>,
        names: (UUID) -> String
    ) -> [ScheduleWeekPerson] {
        ids.map { id in
            let name = names(id).trimmingCharacters(in: .whitespacesAndNewlines)
            return ScheduleWeekPerson(
                id: "sub-\(id.uuidString)",
                name: name.isEmpty ? "Subcontractor" : name,
                role: .subcontractor,
                operativeIds: [],
                userIds: [],
                subcontractorId: id,
                savesAsOperativeBooking: false,
                saveOperativeId: nil,
                saveUserId: nil
            )
        }
        .sorted {
            let order = $0.name.localizedCaseInsensitiveCompare($1.name)
            if order == .orderedSame { return $0.id < $1.id }
            return order == .orderedAscending
        }
    }

    /// Roster operative → `bookings`. Everyone else with an account → `managerSiteBookings`.
    static func saveTarget(for person: ScheduleWeekPerson, jobType: JobType) -> ScheduleQuickAddSave? {
        // Nobody to book: an unresolved id is never booked again from the grid.
        if person.role == .subcontractor || person.role == .unknown { return nil }
        if person.savesAsOperativeBooking, let operativeId = person.saveOperativeId {
            return .operativeBookings(operativeId: operativeId)
        }
        if let userId = person.saveUserId {
            let location: ManagerLocationType = jobType == .smallWorks ? .smallWork : .project
            return .managerSiteBookings(userId: userId, locationType: location)
        }
        if let operativeId = person.operativeIds.first {
            return .operativeBookings(operativeId: operativeId)
        }
        return nil
    }

    /// Full day, AM, and PM clocks from the shared weekday halves.
    static func slotClocks(policy: OrgPayrollTimePolicy) -> ScheduleQuickAddClocks? {
        guard let windows = CanonicalBusinessEngine.halfDayWindows(CanonicalStandardDayInput(policy: policy)) else {
            return nil
        }
        return ScheduleQuickAddClocks(
            fullDay: range(windows.day),
            morning: range(windows.am),
            afternoon: range(windows.pm)
        )
    }

    static func clockText(_ minutes: Int) -> String {
        if minutes >= 24 * 60 { return "24:00" }
        return ManagerScheduleInterval.formatMinutes(minutes)
    }

    static func paidHours(
        operativeIds: [UUID],
        userIds: [String],
        day: Date,
        operativeBookings: [Booking],
        managerBookings: [ManagerSiteBooking],
        policy: OrgPayrollTimePolicy,
        calendar: Calendar = OrganizationRulebookContext.calendar
    ) -> Double {
        let operativeSet = Set(operativeIds)
        let userSet = Set(userIds)
        var total = 0.0
        for booking in operativeBookings where operativeSet.contains(booking.operativeId) && counts(booking, on: day, calendar: calendar) {
            total += booking.paidBookedHours(policy: policy)
        }
        for booking in managerBookings where userSet.contains(booking.userId) && calendar.isDate(booking.date, inSameDayAs: day) {
            total += booking.paidBookedHours(policy: policy)
        }
        return total
    }

    /// RULEBOOK 1.39.0 `bookingShortfall`: the person's bookings that day (labour and manager site) as the coverage rule
    /// reads them — the same bookings `paidHours` sums. A mapping only.
    static func coverageRows(
        operativeIds: [UUID],
        userIds: [String],
        day: Date,
        operativeBookings: [Booking],
        managerBookings: [ManagerSiteBooking],
        calendar: Calendar = OrganizationRulebookContext.calendar
    ) -> [[String: Any]] {
        let operativeSet = Set(operativeIds)
        let userSet = Set(userIds)
        var rows: [[String: Any]] = []
        for booking in operativeBookings where operativeSet.contains(booking.operativeId) && counts(booking, on: day, calendar: calendar) {
            rows.append(CanonicalBusinessEngine.shortfallRow(booking))
        }
        for booking in managerBookings where userSet.contains(booking.userId) && calendar.isDate(booking.date, inSameDayAs: day) {
            rows.append(CanonicalBusinessEngine.shortfallRow(booking.operativePayrollProbe()))
        }
        return rows
    }

    static func overlapMessage(
        operativeIds: [UUID],
        userIds: [String],
        day: Date,
        timeSlot: TimeSlot,
        workStart: String,
        workEnd: String,
        operativeBookings: [Booking],
        managerBookings: [ManagerSiteBooking],
        policy: OrgPayrollTimePolicy,
        calendar: Calendar = OrganizationRulebookContext.calendar
    ) -> String? {
        let probe = Booking(
            operativeId: operativeIds.first ?? UUID(),
            projectId: UUID(),
            date: day,
            timeSlot: timeSlot,
            bookedBy: "",
            workStartTime: workStart,
            workEndTime: workEnd
        )
        let operativeSet = Set(operativeIds)
        let userSet = Set(userIds)
        let operativeHit = operativeBookings.contains { booking in
            operativeSet.contains(booking.operativeId)
                && counts(booking, on: day, calendar: calendar)
                && OperativeBookingInterval.bookingsOverlap(probe, booking, policy: policy)
        }
        let managerHit = managerBookings.contains { booking in
            userSet.contains(booking.userId)
                && calendar.isDate(booking.date, inSameDayAs: day)
                && OperativeBookingInterval.bookingsOverlap(probe, booking.operativePayrollProbe(), policy: policy)
        }
        if operativeHit || managerHit {
            return "This booking overlaps another in time on that day."
        }
        return nil
    }

    private static func counts(_ booking: Booking, on day: Date, calendar: Calendar) -> Bool {
        calendar.isDate(booking.date, inSameDayAs: day)
            // RULEBOOK `bookingOccupiesDay` (as `bookingRequestClashIds`: cancelled never, Completed still fills the day).
            && booking.status.occupiesDay
    }

    private static func range(_ interval: CanonicalMinuteInterval) -> ScheduleClockRange {
        ScheduleClockRange(
            start: ManagerScheduleInterval.formatMinutes(interval.start),
            end: ManagerScheduleInterval.formatMinutes(interval.end)
        )
    }

    private static func person(
        from bucket: StaffEmailIdentity.SchedulePersonBucket,
        operatives: [Operative],
        users: [AppUser]
    ) -> ScheduleWeekPerson {
        let accounts = accounts(for: bucket, operatives: operatives, users: users)
        let leading = leadingAccount(accounts)
        // A catalogue row with no account is an operative; an id that names nobody is unknown, never "Op".
        let role: ScheduleWeekAccountRole = leading?.role ?? (bucket.unresolved ? .unknown : .operative)
        let isOperative = role == .operative
        let operativeIds = linkedOperativeIds(accounts: accounts, bucket: bucket, operatives: operatives)
        let userIds = linkedUserIds(accounts: accounts, bucket: bucket, users: users)
        let saveOperativeId: UUID? = {
            guard isOperative else { return nil }
            let matches = operativeIds.compactMap { id in operatives.first { $0.id == id } }
            if let preferred = StaffEmailIdentity.preferredOperative(matches) { _ in 0 }?.id { return preferred }
            // An operative-level account with a login but no Operatives-list row is booked under its users id, as web
            // Book labour does (#262), only when `bookingIdsForAccount` counts it — never as a manager site booking.
            return leading.flatMap { AccountLabourBooking.bookingOperativeId(for: $0.user, operatives: operatives) }
        }()
        return ScheduleWeekPerson(
            id: leading?.user.id
                ?? operativeIds.first?.uuidString
                ?? bucket.key,
            name: displayName(account: leading?.user, bucket: bucket, operatives: operatives, users: users),
            role: role,
            operativeIds: operativeIds,
            userIds: userIds,
            subcontractorId: nil,
            savesAsOperativeBooking: isOperative && saveOperativeId != nil,
            saveOperativeId: saveOperativeId,
            // An operative with no id to book under has no manager-site save either (`saveTarget` then has only a
            // catalogue id, or nothing), so a script that did not answer never files them as a manager site booking.
            saveUserId: isOperative && saveOperativeId == nil ? nil : leading?.user.id
        )
    }

    private static func displayName(
        account: AppUser?,
        bucket: StaffEmailIdentity.SchedulePersonBucket,
        operatives: [Operative],
        users: [AppUser]
    ) -> String {
        if let account {
            let name = account.fullName.trimmingCharacters(in: .whitespacesAndNewlines)
            if !name.isEmpty { return name }
        }
        return StaffEmailIdentity.bucketDisplayName(bucket, operatives: operatives, users: users)
    }

    /// Admin wins, then manager, then the preferred remaining account.
    private static func leadingAccount(_ users: [AppUser]) -> (role: ScheduleWeekAccountRole, user: AppUser)? {
        let admins = users.filter(\.isRosterAdmin)
        if let user = StaffEmailIdentity.preferredUser(admins) {
            return (.admin, user)
        }
        // `CanonicalBusinessEngine.rosterListKind`: the Managers list by level, never a `managers` row.
        let managers = users.filter { $0.rosterListKind == .managers }
        if let user = StaffEmailIdentity.preferredUser(managers) {
            return (.manager, user)
        }
        if let user = StaffEmailIdentity.preferredUser(users) {
            return (.operative, user)
        }
        return nil
    }

    private static func accounts(
        for bucket: StaffEmailIdentity.SchedulePersonBucket,
        operatives: [Operative],
        users: [AppUser]
    ) -> [AppUser] {
        var ids = Set(bucket.userIds).union(bucket.resolvedAccountIds)
        for operativeId in bucket.operativeIds {
            let email = operatives.first { $0.id == operativeId }?.email
            ids.formUnion(StaffEmailIdentity.userIds(sharing: email, in: users))
        }
        for userId in bucket.userIds + bucket.resolvedAccountIds {
            let email = StaffEmailIdentity.account(forUserId: userId, in: users)?.email
            ids.formUnion(StaffEmailIdentity.userIds(sharing: email, in: users))
        }
        var seen = Set<String>()
        return users.filter { user in
            let linked = ids.contains(user.id) || user.sameEmailUserIds.contains { ids.contains($0) }
            guard linked, seen.insert(user.id).inserted else { return false }
            return true
        }
    }

    private static func linkedOperativeIds(
        accounts: [AppUser],
        bucket: StaffEmailIdentity.SchedulePersonBucket,
        operatives: [Operative]
    ) -> [UUID] {
        var ids = Set(bucket.operativeIds)
        for user in accounts {
            ids.formUnion(StaffEmailIdentity.operativeIds(sharing: user.email, in: operatives))
        }
        for operativeId in bucket.operativeIds {
            let email = operatives.first { $0.id == operativeId }?.email
            ids.formUnion(StaffEmailIdentity.operativeIds(sharing: email, in: operatives))
        }
        return ids.sorted { $0.uuidString < $1.uuidString }
    }

    private static func linkedUserIds(
        accounts: [AppUser],
        bucket: StaffEmailIdentity.SchedulePersonBucket,
        users: [AppUser]
    ) -> [String] {
        var ids = Set(bucket.userIds)
        for user in accounts {
            ids.insert(user.id)
            ids.formUnion(user.sameEmailUserIds)
            ids.formUnion(StaffEmailIdentity.userIds(sharing: user.email, in: users))
        }
        return ids.sorted()
    }
}

/// Labour bookings for an operative-level account that has no Operatives-list row (owner decision 4 Nov, "Judgement
/// call in #262", owner to confirm): the booking's `operativeId` is the users id, mapped in-app by
/// `Booking.internalOperativeId(for:)`. The in-memory row is never written to `operatives`.
/// Owner kept it on 6 Nov (checklist 1.42): iOS books such an account under its users id only when the rulebook's
/// `bookingIdsForAccount` counts a booking under that id as this account's — the same function every reader (My
/// Schedule, timesheets, payroll, job access) uses to find the booking again.
enum AccountLabourBooking {
    static func operativeId(for user: AppUser) -> UUID {
        Booking.internalOperativeId(for: user.id)
    }

    /// The in-app id a labour booking for `user` is written under when they have no Operatives-list row: their users
    /// id (stored exactly as web stores it), but only when `bookingIdsForAccount(account, operatives)` lists it. Nil
    /// when the id is blank, the rulebook does not count it, or the script did not answer (fail closed: no Swift
    /// copy of the rule, AGENTS.md Rule 0). Callers pick a catalogue row first.
    static func bookingOperativeId(for user: AppUser, operatives: [Operative]) -> UUID? {
        let stored = user.id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !stored.isEmpty else { return nil }
        let account = CanonicalBusinessEngine.CanonicalBookingPersonAccount(
            id: user.id, email: user.email, formerIds: user.formerUserIds, aliasIds: user.sameEmailUserIds
        )
        let counted = CanonicalBusinessEngine.bookingIdsForAccount(
            account,
            operatives: operatives.map {
                CanonicalBusinessEngine.CanonicalBookingPersonOperative(id: $0.documentId, email: $0.email)
            }
        ) ?? []
        guard counted.contains(where: { $0.trimmingCharacters(in: .whitespacesAndNewlines).caseInsensitiveCompare(stored) == .orderedSame }) else {
            return nil
        }
        return operativeId(for: user)
    }

    /// The in-memory labour row for `user` under `bookingOperativeId(for:operatives:)`, else nil.
    static func bookingOperative(for user: AppUser, operatives: [Operative]) -> Operative? {
        bookingOperativeId(for: user, operatives: operatives).map { _ in operative(for: user) }
    }

    static func operative(for user: AppUser) -> Operative {
        Operative(
            id: operativeId(for: user),
            firstName: user.firstName,
            lastName: user.surname,
            email: user.email,
            startDate: user.createdAt,
            tradeTypePreset: user.tradeTypePreset,
            tradeTypeCustom: user.tradeTypeCustom
        )
    }

    /// The account a labour booking's `operativeId` names when it is a users id, else nil. Callers look for an
    /// Operatives-list row first. A users id that is itself a UUID (an invite placeholder) is matched too, without case.
    static func account(forOperativeId id: UUID, users: [AppUser]) -> AppUser? {
        let stored = Booking.storedOperativeId(for: id)
        return users.first {
            $0.id.caseInsensitiveCompare(stored) == .orderedSame
                || $0.sameEmailUserIds.contains { $0.caseInsensitiveCompare(stored) == .orderedSame }
        }
    }
}

/// What a tap on the project / small-works week grid may do for the signed-in account, from the rulebook's
/// `canWriteBooking` (RULEBOOK 1.10.0 §2, §16; web `ProjectScheduleWeekOverview.tsx` `canQuickAdd`): admins every
/// booking, managers bookings on the jobs they manage (and their own manager site booking at a job they manage),
/// operatives never. Every manager sees every job (1.33.0 §17), so a manager also sees jobs they may not book on: there
/// a tap does nothing, instead of opening an editor whose Save is then refused ("a save is never refused after the
/// fact", §2). An unknown viewer (profile not loaded) may do nothing. Delete inside the editor stays
/// `bookingRemoveAction` (`BookingStore.canDeleteBooking`, `ManagerScheduleStore.canDeleteBooking`).
enum ScheduleGridTapGate {
    enum Tapped: Equatable {
        /// A labour booking (`bookings`) on this job.
        case labourBooking
        /// A manager site booking (`managerSiteBookings`) of `userId` at this job.
        case managerBooking(userId: String, locationType: String)
        /// A subcontractor booking (`subcontractorBookings`) on this job.
        case subcontractorBooking
        /// An empty day on a person's row: quick add saves to `saveTarget` (nil: nobody to book).
        case emptyDay(saveTarget: ScheduleQuickAddSave?)
        /// Any other day (a leave day, a subcontractor row's empty day): the job's scheduler.
        case scheduleDay(subcontractor: Bool)
    }

    enum Action: Equatable {
        case edit
        case quickAdd
        case openScheduler
        case none
    }

    /// The write a tap would lead to.
    enum Write: Equatable {
        case booking(collection: String)
        case managerSiteBooking(userId: String, locationType: String)
    }

    static func action(
        _ tapped: Tapped,
        viewer: JobAccessViewer?,
        job: Project,
        managers: [[String: Any]]
    ) -> Action {
        guard let viewer else { return .none }
        // The same helpers every booking screen calls (`UserStore.canWriteBooking(collection:on:)`,
        // `canWriteManagerSiteBooking`), in their answer-or-nil form.
        return action(tapped, viewer: viewer) { write in
            switch write {
            case .booking(let collection):
                return UserStore.bookingWriteAnswer(viewer: viewer, collection: collection, on: job, managers: managers)
            case .managerSiteBooking(let userId, let locationType):
                return UserStore.managerSiteBookingWriteAnswer(
                    viewer: viewer, userId: userId, locationType: locationType, job: job, managers: managers
                )
            }
        }
    }

    /// `answer` is `canWriteBooking` for one write, nil when the script did not answer.
    static func action(_ tapped: Tapped, viewer: JobAccessViewer, answer: (Write) -> Bool?) -> Action {
        func may(_ write: Write) -> Bool {
            if let allowed = answer(write) { return allowed }
            // The script did not answer: never silently lock an admin out of their own grid. Admins and super admins
            // outside operative mode write every booking (RULEBOOK §16, the admin branch of `canWriteBooking`);
            // everyone else waits for an answer. The store and the security rules still decide the save.
            return (viewer.role.isAdmin || viewer.role.isSuperAdmin) && !viewer.role.isOperativeMode
        }
        switch tapped {
        case .labourBooking:
            return may(.booking(collection: "bookings")) ? .edit : .none
        case .managerBooking(let userId, let locationType):
            return may(.managerSiteBooking(userId: userId, locationType: locationType)) ? .edit : .none
        case .subcontractorBooking:
            return may(.booking(collection: "subcontractorBookings")) ? .edit : .none
        case .emptyDay(let target):
            switch target {
            case .operativeBookings:
                return may(.booking(collection: "bookings")) ? .quickAdd : .none
            case .managerSiteBookings(let userId, let locationType):
                return may(.managerSiteBooking(userId: userId, locationType: locationType.rawValue)) ? .quickAdd : .none
            case nil:
                return .none
            }
        case .scheduleDay(let subcontractor):
            return may(.booking(collection: subcontractor ? "subcontractorBookings" : "bookings")) ? .openScheduler : .none
        }
    }
}
