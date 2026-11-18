//
//  Rulebook+MultiPersonBooking.swift
//  Project Planner
//
//  RULEBOOK 1.60.0 §5 (owner request 17 Nov 2026; web `lib/canonical/multiPersonBooking.ts`). A booking for MORE THAN
//  ONE person never books someone who already has any booking on a selected day: the flow names the person and the
//  day with `MULTI_PERSON_ALREADY_BOOKED_MESSAGE` and cannot save until they are removed from the selection. One person
//  keeps the orange ✓ / ✕ / Replace rows. Swift only maps inputs; the script decides.
//

import Foundation

/// One person the script says must be removed from a multi-person booking.
nonisolated struct RulebookMultiPersonBlock: Hashable, Sendable, Identifiable {
    var id: String { personKey }
    let personKey: String
    let name: String
    let dayKeys: [String]
    let message: String
}

/// A person in the selection: the app's key, the name, and every id their bookings may be filed under.
nonisolated struct RulebookMultiPersonSelection: Hashable, Sendable {
    let personKey: String
    let name: String
    let ids: [String]
}

/// An existing booking: person id as stored, organisation day key, status (nil for a manager site booking).
nonisolated struct RulebookMultiPersonBooking: Hashable, Sendable {
    let id: String
    let personId: String
    let dayKey: String
    let status: String?
}

extension CanonicalBusinessEngine {
    /// RULEBOOK 1.60.0 `leaveCoverBookingWindow(row, day)`: the custom hours to prefill for a "Half-day leave not
    /// covered" row — the first uncovered stretch, joined across the lunch window, never across a booking. `day` is the
    /// working-hours input the row was built with (the policy state, or the standard day). Nil for a leave_clash row,
    /// or when the script did not answer.
    nonisolated static func leaveCoverBookingWindow(
        _ row: CanonicalLeaveCoverageRow,
        day: Any?
    ) -> (start: String, end: String)? {
        guard let data = try? JSONEncoder().encode(row),
              let object = try? JSONSerialization.jsonObject(with: data) else { return nil }
        guard let answer = callJSON("leaveCoverBookingWindow", arguments: [object, day ?? NSNull()]) as? [String: Any],
              let start = answer["start"] as? String, let end = answer["end"] as? String else { return nil }
        return (start, end)
    }

    /// `MULTI_PERSON_ALREADY_BOOKED_MESSAGE`.
    nonisolated static var multiPersonAlreadyBookedMessage: String {
        constant("MULTI_PERSON_ALREADY_BOOKED_MESSAGE", as: String.self)
            ?? "This user already has hours booked for this day. Remove this user from the selection to continue with the booking. The user will have to be booked separately."
    }

    /// `MULTI_PERSON_ALREADY_BOOKED_REMOVE_LABEL` ("Remove").
    nonisolated static var multiPersonAlreadyBookedRemoveLabel: String {
        constant("MULTI_PERSON_ALREADY_BOOKED_REMOVE_LABEL", as: String.self) ?? "Remove"
    }

    /// RULEBOOK 1.60.0 `multiPersonBookingBlocks({ people, dayKeys, bookings, ignoreBookingIds })`. Empty for one person.
    /// Nil when the script did not answer — the caller then refuses the multi-person save (never books blind).
    nonisolated static func multiPersonBookingBlocks(
        people: [RulebookMultiPersonSelection],
        dayKeys: [String],
        bookings: [RulebookMultiPersonBooking],
        ignoreBookingIds: [String] = []
    ) -> [RulebookMultiPersonBlock]? {
        if people.count <= 1 { return [] }
        let input: [String: Any] = [
            "people": people.map { ["personKey": $0.personKey, "name": $0.name, "ids": $0.ids] },
            "dayKeys": dayKeys,
            "bookings": bookings.map { booking -> [String: Any] in
                var row: [String: Any] = ["id": booking.id, "personId": booking.personId, "dayKey": booking.dayKey]
                row["status"] = booking.status ?? NSNull()
                return row
            },
            "ignoreBookingIds": ignoreBookingIds,
        ]
        guard let rows = callJSON("multiPersonBookingBlocks", arguments: [input]) as? [[String: Any]] else { return nil }
        return rows.compactMap { row in
            guard let key = row["personKey"] as? String else { return nil }
            return RulebookMultiPersonBlock(
                personKey: key,
                name: row["name"] as? String ?? "",
                dayKeys: row["dayKeys"] as? [String] ?? [],
                message: row["message"] as? String ?? multiPersonAlreadyBookedMessage
            )
        }
    }
}

/// App-side wiring: each person's ids (`bookingIdsForAccount`, `personIdSet`) and the day's bookings from the stores.
enum MultiPersonBookingCheck {
    /// Every id an account's bookings may be filed under, from the rulebook only (as web `multiPersonBookingIds`):
    /// `personIdSet` over the roster (own id, former and same-email ids, same-email users documents) plus
    /// `bookingIdsForAccount` (every `operatives` row on the email).
    @MainActor
    static func ids(forUserId userId: String, users: [AppUser], operatives: [Operative]) -> [String] {
        guard let account = users.first(where: { $0.id == userId }) else { return [userId] }
        let people = RulebookPeople.ownerIds(for: account, users: users)
        let rows = CanonicalBusinessEngine.bookingIdsForAccount(
            .init(id: userId, email: account.email, formerIds: account.formerUserIds, aliasIds: people),
            operatives: operatives.map { .init(id: $0.documentId, email: $0.email) }
        ) ?? []
        return Array(Set((people + rows + [userId]).filter { !$0.isEmpty }))
    }

    /// The ids of a catalogue operative: its stored ids, and — when an account is on its email (the rulebook's
    /// `resolveBookingPerson`) — every id that person goes by.
    @MainActor
    static func ids(forOperative operative: Operative, users: [AppUser], operatives: [Operative]) -> [String] {
        var ids = [Booking.operativeMatchKey(for: operative.id), operative.documentId]
        if let resolved = CanonicalBusinessEngine.resolveBookingPerson(
            operative.documentId,
            bookingPersonInput(operatives: operatives, users: users)
        ), let accountId = resolved.accountId {
            ids += Self.ids(forUserId: accountId, users: users, operatives: operatives)
        }
        return Array(Set(ids.filter { !$0.isEmpty }))
    }

    /// The labour and manager site bookings on `dayKeys` (status passed through; the script decides what occupies a day).
    @MainActor
    static func bookings(
        operativeBookings: [Booking],
        managerBookings: [ManagerSiteBooking],
        dayKeys: Set<String>
    ) -> [RulebookMultiPersonBooking] {
        let calendar = CanonicalBusinessEngine.businessCalendar
        var rows: [RulebookMultiPersonBooking] = []
        for booking in operativeBookings {
            let key = CanonicalBusinessEngine.dayKey(for: booking.date, calendar: calendar)
            guard dayKeys.contains(key) else { continue }
            rows.append(.init(
                id: booking.id.uuidString,
                personId: Booking.operativeMatchKey(for: booking.operativeId),
                dayKey: key,
                status: booking.status.rawValue
            ))
        }
        for booking in managerBookings {
            let key = CanonicalBusinessEngine.dayKey(for: booking.date, calendar: calendar)
            guard dayKeys.contains(key) else { continue }
            rows.append(.init(id: booking.id.uuidString, personId: booking.userId, dayKey: key, status: nil))
        }
        return rows
    }

    /// "Mon 23 Nov" for each day key, in the organisation zone.
    static func daysText(_ dayKeys: [String]) -> String {
        let calendar = CanonicalBusinessEngine.businessCalendar
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_GB")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "EEE d MMM"
        return dayKeys.compactMap { CanonicalBusinessEngine.date(fromDayKey: $0, calendar: calendar) }
            .map { formatter.string(from: $0) }
            .joined(separator: ", ")
    }
}

extension MultiPersonBookingCheck {
    /// The Schedule wizard / Select Operatives: the selected people (more than one) already booked on a selected day.
    /// Each person's ids are their users id's (`bookingIdsForAccount`) plus every in-app id their bookings may carry
    /// (`ScheduleBookablePerson.bookingIds`). The bookings being edited (`excludingBookingIds`) never count.
    /// Nil when the script did not answer (the caller refuses the save).
    @MainActor
    static func scheduleBlocks(
        people: [ScheduleBookablePerson],
        selected: Set<UUID>,
        dates: Set<Date>,
        operativeBookings: [Booking],
        managerBookings: [ManagerSiteBooking],
        users: [AppUser],
        operatives: [Operative],
        excludingBookingIds: Set<UUID>
    ) -> [RulebookMultiPersonBlock]? {
        let chosen = people.filter { selected.contains($0.operativeId) }
        guard chosen.count > 1, !dates.isEmpty else { return [] }
        let dayKeys = Set(dates.map { CanonicalBusinessEngine.bookingDayKey($0) })
        return CanonicalBusinessEngine.multiPersonBookingBlocks(
            people: chosen.map { person in
                var ids = [Booking.operativeMatchKey(for: person.operativeId)]
                    + person.bookingIds.map { Booking.operativeMatchKey(for: $0) }
                if let userId = person.userId, !userId.isEmpty {
                    ids += Self.ids(forUserId: userId, users: users, operatives: operatives)
                }
                return RulebookMultiPersonSelection(
                    personKey: person.operativeId.uuidString,
                    name: person.name,
                    ids: Array(Set(ids))
                )
            },
            dayKeys: dayKeys.sorted(),
            bookings: bookings(operativeBookings: operativeBookings, managerBookings: managerBookings, dayKeys: dayKeys),
            ignoreBookingIds: excludingBookingIds.map(\.uuidString)
        )
    }
}
