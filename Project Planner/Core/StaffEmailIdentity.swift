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
        // Own id, a same-email document folded into it, or a former invite id (`bookingIdsForAccount`).
        // Ids compare without case, as `resolveBookingPerson` does.
        if let exact = users.first(where: { $0.id == trimmed }) { return exact }
        let key = trimmed.lowercased()
        return users.first { user in
            user.id.lowercased() == key
                || user.sameEmailUserIds.contains { $0.lowercased() == key }
                || user.formerUserIds.contains { $0.lowercased() == key }
        }
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

    static func distinctPersonKeys(
        operativeIds: [UUID],
        userIds: [String],
        subcontractorIds: [UUID] = [],
        operatives: [Operative],
        users: [AppUser]
    ) -> Set<String> {
        var keys = Set<String>()
        for id in operativeIds {
            let email = operativeBookingEmail(id, operatives: operatives, users: users)
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

    /// The email of the person a labour booking's `operativeId` names: the catalogue row's, else — a booking saved
    /// under a users id (an account with no Operatives-list row, web Book labour #262) — that account's, so the
    /// booking sits in the account's row, never a separate `op:` row. Display grouping only; who the booking counts for
    /// is still `bookingIdsForAccount`.
    static func operativeBookingEmail(_ id: UUID, operatives: [Operative], users: [AppUser]) -> String? {
        if let row = operatives.first(where: { $0.id == id }) { return row.email }
        return AccountLabourBooking.account(forOperativeId: id, users: users)?.email
    }

    struct SchedulePersonBucket: Equatable {
        var key: String
        var operativeIds: [UUID]
        var userIds: [String]
        /// The accounts the rulebook's `resolveBookingPerson` found for the booked ids — a former invite id, a
        /// same-email document, a catalogue row on the account's email, any letter case.
        var resolvedAccountIds: [String] = []
        /// True when no booked id in the row names any account or catalogue row (`resolveBookingPerson` found nobody).
        var unresolved: Bool = false
    }

    typealias BookingPersonResolver = (String, CanonicalBusinessEngine.CanonicalBookingPersonInput) -> CanonicalBusinessEngine.CanonicalResolvedBookingPerson?

    private struct ResolvedPersonKey: Hashable {
        var roster: Int
        var storedId: String
    }

    /// One answer per booked id per roster: the grid re-renders often and the roster rarely changes.
    nonisolated private static let resolvedPersonMemo = RulebookAnswerMemo<ResolvedPersonKey, CanonicalBusinessEngine.CanonicalResolvedBookingPerson>(limit: 2048)

    /// `resolveBookingPerson`, memoised on the roster (`rosterHash`, the input's hash taken once per pass) and the id.
    static func memoisedBookingPerson(
        _ storedId: String,
        _ input: CanonicalBusinessEngine.CanonicalBookingPersonInput,
        rosterHash: Int
    ) -> CanonicalBusinessEngine.CanonicalResolvedBookingPerson? {
        resolvedPersonMemo.value(for: ResolvedPersonKey(roster: rosterHash, storedId: storedId)) {
            CanonicalBusinessEngine.resolveBookingPerson(storedId, input)
        }
    }

    /// The row key for one answer of `resolveBookingPerson`: the person's email as web keys rows
    /// (`ProjectScheduleWeekOverview.tsx`), else the rulebook's `bookingPersonKey` form (`account:` / `operative:` /
    /// `id:`, ids lower-cased), read off the same answer instead of asking the script a second time.
    static func scheduleRowKey(storedId: String, person: CanonicalBusinessEngine.CanonicalResolvedBookingPerson) -> String {
        let email = emailKey(person.email)
        if !email.isEmpty { return "email:\(email)" }
        func lower(_ id: String) -> String { id.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
        if let account = person.accountId { return "account:\(lower(account))" }
        if let operative = person.operativeId { return "operative:\(lower(operative))" }
        return "id:\(lower(storedId))"
    }

    /// One row per person on the project / small-works week grid. Each booked id (a labour booking's `operativeId`, a
    /// manager site booking's `userId`) is resolved once with the rulebook's `resolveBookingPerson` (web
    /// `findUserByAnyId` with the roster's `userIdAliases`, `ProjectScheduleWeekOverview.tsx`), and rows are keyed by
    /// the person's email as web keys them, else the `bookingPersonKey` form. Before 1.37.3 iOS matched the stored id
    /// exactly (own id and same-email ids, never `formerUserIds`), so a booking under a former invite id read
    /// "Unknown person". `resolve` is the rulebook call (replaced only in tests to stand for a script that did not
    /// answer).
    static func scheduleBuckets(
        operativeIds: Set<UUID>,
        userIds: Set<String>,
        operatives: [Operative],
        users: [AppUser],
        resolve: BookingPersonResolver? = nil
    ) -> [SchedulePersonBucket] {
        let input = bookingPersonInput(operatives: operatives, users: users)
        let rosterHash = input.hashValue
        let resolve: BookingPersonResolver = resolve ?? { memoisedBookingPerson($0, $1, rosterHash: rosterHash) }
        var byKey: [String: SchedulePersonBucket] = [:]
        func place(_ storedId: String, legacy: () -> (email: String?, known: Bool), legacyKey: String, add: (inout SchedulePersonBucket) -> Void) {
            let key: String
            var accountId: String?
            let found: Bool
            if let person = resolve(storedId, input) {
                accountId = person.accountId
                found = person.accountId != nil || person.operativeId != nil
                key = scheduleRowKey(storedId: storedId, person: person)
            } else {
                // The script did not answer: the email grouping this app had before (no Swift copy of the rule). A
                // catalogue row or account the id names exactly — a ghost or a row with no email included — keeps
                // its row, pill and quick add as before; only an id that names nothing is unknown.
                let old = legacy()
                key = personKey(email: old.email, fallbackId: legacyKey)
                found = old.known
            }
            if !found {
                // Diagnostic (owner report 13 Nov): which stored id names nobody, and what the lookup had to search.
                NSLog(
                    "SCHEDULE_PERSON_UNRESOLVED id=%@ scriptAnswered=%@ accounts=%ld operatives=%ld",
                    storedId,
                    resolve(storedId, input) == nil ? "no" : "yes",
                    input.accounts.count,
                    input.operatives.count
                )
            }
            var bucket = byKey[key] ?? SchedulePersonBucket(key: key, operativeIds: [], userIds: [], resolvedAccountIds: [], unresolved: true)
            add(&bucket)
            if let accountId, !bucket.resolvedAccountIds.contains(accountId) { bucket.resolvedAccountIds.append(accountId) }
            if found { bucket.unresolved = false }
            byKey[key] = bucket
        }
        for id in operativeIds.sorted(by: { $0.uuidString < $1.uuidString }) {
            place(
                Booking.storedOperativeId(for: id),
                legacy: {
                    let known = operatives.contains { $0.id == id } || AccountLabourBooking.account(forOperativeId: id, users: users) != nil
                    return (operativeBookingEmail(id, operatives: operatives, users: users), known)
                },
                legacyKey: "op:\(id.uuidString)"
            ) { $0.operativeIds.append(id) }
        }
        for id in userIds.sorted() {
            place(
                id,
                legacy: {
                    let account = users.first { $0.id == id }
                    return (account?.email, account != nil)
                },
                legacyKey: "u:\(id)"
            ) { $0.userIds.append(id) }
        }
        return Array(byKey.values)
    }

    static func bucketDisplayName(
        _ bucket: SchedulePersonBucket,
        operatives: [Operative],
        users: [AppUser]
    ) -> String {
        let emails = bucket.userIds.compactMap { id in users.first { $0.id == id }?.email }
            + bucket.operativeIds.compactMap { id in operatives.first { $0.id == id }?.email }
        let named = users.filter { bucket.userIds.contains($0.id) || bucket.resolvedAccountIds.contains($0.id) }
        if let preferred = emails.compactMap({ preferredUser(sharing: $0, in: users) }).first ?? preferredUser(named) {
            let name = preferred.fullName.trimmingCharacters(in: .whitespacesAndNewlines)
            if !name.isEmpty { return name }
            let email = preferred.email.trimmingCharacters(in: .whitespacesAndNewlines)
            if !email.isEmpty { return email }
        }
        for id in bucket.operativeIds {
            let name = rosterNameForLabourBooking(operativeId: id, operatives: operatives, users: users)
            if name != unknownLabourPersonName { return name }
        }
        return bucket.unresolved || bucket.userIds.isEmpty ? unknownLabourPersonName : "Manager"
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
