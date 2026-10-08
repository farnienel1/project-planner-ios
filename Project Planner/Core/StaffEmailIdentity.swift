//
//  StaffEmailIdentity.swift
//  Project Planner
//
//  One email is one person. Hours, holidays, and rows fold every user id and
//  operative id that share that email.
//

import Foundation

enum StaffEmailIdentity {
    static func emailKey(_ raw: String?) -> String {
        raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
    }

    /// Daily Overview and the week grid use this when an email exists.
    static func personKey(email: String?, fallbackId: String) -> String {
        let key = emailKey(email)
        if key.isEmpty { return fallbackId }
        return "email:\(key)"
    }

    static func userIds(sharing email: String?, in users: [AppUser]) -> Set<String> {
        let key = emailKey(email)
        var ids = Set<String>()
        guard !key.isEmpty else { return ids }
        for user in users where emailKey(user.email) == key {
            let trimmed = user.id.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { ids.insert(trimmed) }
            for alias in user.sameEmailUserIds {
                let trimmedAlias = alias.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmedAlias.isEmpty { ids.insert(trimmedAlias) }
            }
        }
        return ids
    }

    static func account(forUserId id: String, in users: [AppUser]) -> AppUser? {
        let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return users.first { $0.id == trimmed || $0.sameEmailUserIds.contains(trimmed) }
    }

    static func operativeIds(sharing email: String?, in operatives: [Operative]) -> Set<UUID> {
        let key = emailKey(email)
        guard !key.isEmpty else { return [] }
        return Set(operatives.filter { emailKey($0.email) == key }.map(\.id))
    }

    /// Finished, active accounts win. A readable trade wins among those.
    static func preferredUser(_ users: [AppUser]) -> AppUser? {
        guard !users.isEmpty else { return nil }
        return users.min { lhs, rhs in
            let left = accountRank(lhs)
            let right = accountRank(rhs)
            if left != right { return left < right }
            return lhs.id < rhs.id
        }
    }

    static func preferredUser(sharing email: String?, in users: [AppUser]) -> AppUser? {
        let key = emailKey(email)
        guard !key.isEmpty else { return nil }
        return preferredUser(users.filter { emailKey($0.email) == key })
    }

    static func oneAccountPerEmail(_ users: [AppUser]) -> [AppUser] {
        var groups: [String: [AppUser]] = [:]
        var withoutEmail: [AppUser] = []
        for user in users {
            let key = emailKey(user.email)
            if key.isEmpty {
                withoutEmail.append(user)
            } else {
                groups[key, default: []].append(user)
            }
        }
        let picked = groups.values.compactMap { preferredUser($0) }
        return picked + withoutEmail
    }

    static func qualificationWeight(_ operative: Operative) -> Int {
        operative.qualifications.count
            + operative.qualificationCertificateURLs.count
            + operative.qualificationExpiryDates.count
    }

    /// The profile that already holds today's hours, otherwise the highest qualification weight.
    static func preferredOperative(_ operatives: [Operative], paidHours: (UUID) -> Double) -> Operative? {
        guard !operatives.isEmpty else { return nil }
        let withHours = operatives.filter { paidHours($0.id) > 0.001 }
        let pool = withHours.isEmpty ? operatives : withHours
        return pool.max { lhs, rhs in
            let left = qualificationWeight(lhs)
            let right = qualificationWeight(rhs)
            if left != right { return left < right }
            return lhs.id.uuidString > rhs.id.uuidString
        }
    }

    static func isOpaqueCatalogueToken(_ value: String?) -> Bool {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard trimmed.count >= 16 else { return false }
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_-")
        return trimmed.unicodeScalars.allSatisfy { allowed.contains($0) }
    }

    /// A catalogue or skill id is not a trade. Missing and opaque values are General.
    static func reportTrade(preset: String?, custom: String?) -> String {
        if isOpaqueCatalogueToken(preset) || isOpaqueCatalogueToken(custom) { return "General" }
        let label = StaffTradeType.displayLabel(presetRaw: preset, custom: custom)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if label.isEmpty || label == "—" || isOpaqueCatalogueToken(label) { return "General" }
        return label
    }

    static func reportTrade(for user: AppUser?) -> String {
        guard let user else { return "General" }
        return reportTrade(preset: user.tradeTypePreset, custom: user.tradeTypeCustom)
    }

    /// An hourly user account is not priced from the operative profile's day rate.
    static func operativeUsedForPay(user: AppUser?, operative: Operative?) -> Operative? {
        guard let user else { return operative }
        if user.hourlyRate != nil && user.dayRate == nil { return nil }
        return operative
    }

    static func holidayCovers(
        day: Date,
        userIds: Set<String>,
        operativeIds: Set<UUID>,
        holidays: [HolidayBooking],
        calendar: Calendar = .current
    ) -> Bool {
        let dayStart = calendar.startOfDay(for: day)
        return holidays.contains { holiday in
            guard holiday.status == .approved else { return false }
            let start = calendar.startOfDay(for: holiday.startDate)
            let end = calendar.startOfDay(for: holiday.endDate)
            guard dayStart >= start && dayStart <= end else { return false }
            if let userId = holiday.userId, userIds.contains(userId) { return true }
            if let operativeId = holiday.operativeId, operativeIds.contains(operativeId) { return true }
            return false
        }
    }

    static func paidHours(
        email: String?,
        users: [AppUser],
        operatives: [Operative],
        operativeBookings: [Booking],
        managerBookings: [ManagerSiteBooking],
        day: Date,
        policy: OrgPayrollTimePolicy,
        calendar: Calendar = .current
    ) -> Double {
        let key = emailKey(email)
        var total = 0.0
        let operativeIds = key.isEmpty ? Set<UUID>() : self.operativeIds(sharing: key, in: operatives)
        for booking in operativeBookings where operativeIds.contains(booking.operativeId) {
            guard calendar.isDate(booking.date, inSameDayAs: day) else { continue }
            guard booking.status == .confirmed || booking.status == .tentative else { continue }
            total += booking.paidBookedHours(policy: policy)
        }
        let ids = key.isEmpty ? Set<String>() : userIds(sharing: key, in: users)
        for id in ids {
            let sameDay = managerBookings.filter { booking in
                booking.userId == id && calendar.isDate(booking.date, inSameDayAs: day)
            }
            total += ManagerScheduleInterval.combinedPaidBookedHours(for: sameDay, policy: policy)
        }
        return total
    }

    static func distinctPersonKeys(
        operativeIds: [UUID],
        userIds: [String],
        subcontractorIds: [UUID] = [],
        operatives: [Operative],
        users: [AppUser]
    ) -> Set<String> {
        var keys = Set<String>()
        for id in operativeIds {
            let email = operatives.first { $0.id == id }?.email
            keys.insert(personKey(email: email, fallbackId: "op:\(id.uuidString)"))
        }
        for id in userIds {
            let email = users.first { $0.id == id }?.email
            keys.insert(personKey(email: email, fallbackId: "u:\(id)"))
        }
        for id in subcontractorIds {
            keys.insert("sub:\(id.uuidString)")
        }
        return keys
    }

    struct SchedulePersonBucket: Equatable {
        var key: String
        var operativeIds: [UUID]
        var userIds: [String]
    }

    static func scheduleBuckets(
        operativeIds: Set<UUID>,
        userIds: Set<String>,
        operatives: [Operative],
        users: [AppUser]
    ) -> [SchedulePersonBucket] {
        var operativeByKey: [String: [UUID]] = [:]
        var userByKey: [String: [String]] = [:]
        for id in operativeIds {
            let email = operatives.first { $0.id == id }?.email
            let key = personKey(email: email, fallbackId: "op:\(id.uuidString)")
            operativeByKey[key, default: []].append(id)
        }
        for id in userIds {
            let email = users.first { $0.id == id }?.email
            let key = personKey(email: email, fallbackId: "u:\(id)")
            userByKey[key, default: []].append(id)
        }
        let keys = Set(operativeByKey.keys).union(userByKey.keys)
        return keys.map { key in
            SchedulePersonBucket(
                key: key,
                operativeIds: operativeByKey[key] ?? [],
                userIds: userByKey[key] ?? []
            )
        }
    }

    static func bucketDisplayName(
        _ bucket: SchedulePersonBucket,
        operatives: [Operative],
        users: [AppUser]
    ) -> String {
        let emails = bucket.userIds.compactMap { id in users.first { $0.id == id }?.email }
            + bucket.operativeIds.compactMap { id in operatives.first { $0.id == id }?.email }
        if let preferred = emails.compactMap({ preferredUser(sharing: $0, in: users) }).first ?? preferredUser(users.filter { bucket.userIds.contains($0.id) }) {
            let name = preferred.fullName.trimmingCharacters(in: .whitespacesAndNewlines)
            if !name.isEmpty { return name }
            let email = preferred.email.trimmingCharacters(in: .whitespacesAndNewlines)
            if !email.isEmpty { return email }
        }
        for id in bucket.operativeIds {
            let name = rosterNameForLabourBooking(operativeId: id, operatives: operatives, users: users)
            if name != "Not on the roster" { return name }
        }
        return bucket.userIds.isEmpty ? "Not on the roster" : "Manager"
    }

    private static func accountRank(_ user: AppUser) -> Int {
        let finished = user.passwordSet && user.isActive
        let trade = readableTrade(user)
        if finished && trade { return 0 }
        if finished { return 1 }
        if user.passwordSet && trade { return 2 }
        if user.passwordSet { return 3 }
        if trade { return 4 }
        return 5
    }

    private static func readableTrade(_ user: AppUser) -> Bool {
        if isOpaqueCatalogueToken(user.tradeTypePreset) || isOpaqueCatalogueToken(user.tradeTypeCustom) {
            return false
        }
        let label = StaffTradeType.displayLabel(presetRaw: user.tradeTypePreset, custom: user.tradeTypeCustom)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return !label.isEmpty && label != "—" && !isOpaqueCatalogueToken(label)
    }
}

enum BookLabourCandidateSelection {
    struct Choice: Equatable {
        var userId: String
        var operativeId: UUID?
        var usesOperativeProjectBookings: Bool
    }

    static func choices(
        day: Date,
        users: [AppUser],
        operatives: [Operative],
        operativeBookings: [Booking],
        managerBookings: [ManagerSiteBooking],
        holidays: [HolidayBooking],
        policy: OrgPayrollTimePolicy,
        focusedIds: Set<String>,
        includeThisDay: Bool,
        calendar: Calendar = .current
    ) -> [Choice] {
        guard includeThisDay else { return [] }
        let required = max(policy.standardPaidHours, 0)

        func focused(_ user: AppUser, operative: Operative?) -> Bool {
            if focusedIds.contains(user.id) { return true }
            if let operative, focusedIds.contains(operative.id.uuidString) { return true }
            let key = StaffEmailIdentity.emailKey(user.email)
            guard !key.isEmpty, !focusedIds.isEmpty else { return false }
            if users.contains(where: { StaffEmailIdentity.emailKey($0.email) == key && focusedIds.contains($0.id) }) {
                return true
            }
            return operatives.contains {
                StaffEmailIdentity.emailKey($0.email) == key && focusedIds.contains($0.id.uuidString)
            }
        }

        func bookable(_ user: AppUser) -> Bool {
            user.passwordSet || focusedIds.contains(user.id) || focused(user, operative: nil)
        }

        let operativeOnly = StaffEmailIdentity.oneAccountPerEmail(
            users.filter { user in
                user.isActive && bookable(user) && user.permissions.operativeMode
                    && !user.permissions.manager && !user.permissions.adminAccess
                    && !user.isSuperAdmin && user.role != .admin
            }
        )
        let managers = StaffEmailIdentity.oneAccountPerEmail(
            users.filter { user in
                user.isActive && bookable(user)
                    && (user.permissions.manager || user.permissions.adminAccess || user.isSuperAdmin || user.role == .admin)
            }
        )

        var seenEmails = Set<String>()
        var out: [(choice: Choice, name: String, focused: Bool)] = []

        func consider(_ user: AppUser, requiresOperative: Bool) {
            let email = StaffEmailIdentity.emailKey(user.email)
            if !email.isEmpty, seenEmails.contains(email) { return }
            let matches = email.isEmpty
                ? []
                : operatives.filter { StaffEmailIdentity.emailKey($0.email) == email }
            let linked = StaffEmailIdentity.preferredOperative(matches) { operativeId in
                operativeBookings.reduce(0) { partial, booking in
                    guard booking.operativeId == operativeId,
                          calendar.isDate(booking.date, inSameDayAs: day),
                          booking.status == .confirmed || booking.status == .tentative else { return partial }
                    return partial + booking.paidBookedHours(policy: policy)
                }
            }
            if requiresOperative && linked == nil { return }
            let userIds = StaffEmailIdentity.userIds(sharing: user.email, in: users).union([user.id])
            let operativeIds = StaffEmailIdentity.operativeIds(sharing: user.email, in: operatives)
            if StaffEmailIdentity.holidayCovers(
                day: day,
                userIds: userIds,
                operativeIds: operativeIds,
                holidays: holidays,
                calendar: calendar
            ) { return }
            let paid = StaffEmailIdentity.paidHours(
                email: user.email,
                users: users,
                operatives: operatives,
                operativeBookings: operativeBookings,
                managerBookings: managerBookings,
                day: day,
                policy: policy,
                calendar: calendar
            )
            let isFocused = focused(user, operative: linked)
            if !isFocused, paid + 0.08 >= required { return }
            if !email.isEmpty { seenEmails.insert(email) }
            let name = user.fullName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? user.email : user.fullName
            out.append((
                Choice(
                    userId: user.id,
                    operativeId: linked?.id,
                    usesOperativeProjectBookings: requiresOperative
                ),
                name,
                isFocused
            ))
        }

        for user in operativeOnly { consider(user, requiresOperative: true) }
        for user in managers { consider(user, requiresOperative: false) }

        return out.sorted { lhs, rhs in
            if lhs.focused != rhs.focused { return lhs.focused && !rhs.focused }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }.map(\.choice)
    }
}

enum LabourDayCoverage {
    static func unbookedLines(
        day: Date,
        users: [AppUser],
        operatives: [Operative],
        operativeBookings: [Booking],
        managerBookings: [ManagerSiteBooking],
        holidays: [HolidayBooking],
        policy: OrgPayrollTimePolicy,
        calendar: Calendar = .current
    ) -> [String] {
        let required = max(policy.standardPaidHours, 0)
        let operativeOnly = StaffEmailIdentity.oneAccountPerEmail(
            users.filter {
                $0.isActive && $0.passwordSet && $0.permissions.operativeMode
                    && !$0.permissions.manager && !$0.permissions.adminAccess
                    && !$0.isSuperAdmin && $0.role != .admin
            }
        )
        let managers = StaffEmailIdentity.oneAccountPerEmail(
            users.filter {
                $0.isActive && $0.passwordSet
                    && ($0.permissions.manager || $0.permissions.adminAccess || $0.isSuperAdmin || $0.role == .admin)
            }
        )
        var seen = Set<String>()
        var lines: [String] = []
        func append(_ user: AppUser) {
            let email = StaffEmailIdentity.emailKey(user.email)
            let seenKey = email.isEmpty ? user.id : email
            guard seen.insert(seenKey).inserted else { return }
            let userIds = StaffEmailIdentity.userIds(sharing: user.email, in: users).union([user.id])
            let operativeIds = StaffEmailIdentity.operativeIds(sharing: user.email, in: operatives)
            if StaffEmailIdentity.holidayCovers(
                day: day,
                userIds: userIds,
                operativeIds: operativeIds,
                holidays: holidays,
                calendar: calendar
            ) { return }
            let paid = StaffEmailIdentity.paidHours(
                email: user.email,
                users: users,
                operatives: operatives,
                operativeBookings: operativeBookings,
                managerBookings: managerBookings,
                day: day,
                policy: policy,
                calendar: calendar
            )
            let missing = max(0, required - paid)
            guard missing > 0.08 else { return }
            let name = user.fullName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? user.email : user.fullName
            lines.append("\(name) (missing \(ScheduleCoverageFormat.hours(missing))h)")
        }
        operativeOnly.forEach(append)
        managers.forEach(append)
        return lines.sorted()
    }
}
