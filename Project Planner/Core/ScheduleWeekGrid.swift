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
}

/// Account role for a week-overview row. Admin and manager share blue.
enum ScheduleWeekAccountRole: String, Equatable {
    case admin
    case manager
    case operative
    case subcontractor

    var badge: String {
        switch self {
        case .admin: return "Admin"
        case .manager: return "Mgr"
        case .operative: return "Op"
        case .subcontractor: return "Sub"
        }
    }

    /// Admin and manager are blue, operative green, subcontractor purple.
    var tone: ScheduleWeekTone {
        switch self {
        case .admin, .manager: return .blue
        case .operative: return .green
        case .subcontractor: return .purple
        }
    }

    static func from(account user: AppUser) -> ScheduleWeekAccountRole {
        if user.isRosterAdmin { return .admin }
        if user.permissions.manager || user.role == .manager || user.placedByManagersRecord {
            return .manager
        }
        return .operative
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
        users: [AppUser]
    ) -> [ScheduleWeekPerson] {
        let buckets = StaffEmailIdentity.scheduleBuckets(
            operativeIds: operativeIds,
            userIds: userIds,
            operatives: operatives,
            users: users
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
        if person.role == .subcontractor { return nil }
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
        calendar: Calendar = .current
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
        calendar: Calendar = .current
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
            && booking.status != .cancelled
            && booking.status != .completed
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
        let role = leading?.role ?? .operative
        let operativeIds = linkedOperativeIds(accounts: accounts, bucket: bucket, operatives: operatives)
        let userIds = linkedUserIds(accounts: accounts, bucket: bucket, users: users)
        let saveOperativeId: UUID? = {
            guard role == .operative else { return nil }
            let matches = operativeIds.compactMap { id in operatives.first { $0.id == id } }
            return StaffEmailIdentity.preferredOperative(matches) { _ in 0 }?.id
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
            savesAsOperativeBooking: role == .operative && saveOperativeId != nil,
            saveOperativeId: saveOperativeId,
            saveUserId: leading?.user.id
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
        let managers = users.filter {
            $0.permissions.manager || $0.role == .manager || $0.placedByManagersRecord
        }
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
        var ids = Set(bucket.userIds)
        for operativeId in bucket.operativeIds {
            let email = operatives.first { $0.id == operativeId }?.email
            ids.formUnion(StaffEmailIdentity.userIds(sharing: email, in: users))
        }
        for userId in bucket.userIds {
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
