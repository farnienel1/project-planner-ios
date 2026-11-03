//
//  Rulebook+BookingLeaveConflicts.swift
//  Project Planner
//
//  Rulebook 1.16.0 (docs/RULEBOOK.md §5, §9): annual leave on the days being booked. The rule is the packed
//  script's `bookingLeaveConflicts` (approved and pending leave whose window overlaps the booking slot, one row per
//  person-day); the labels are `ANNUAL_LEAVE_BOOKED_LABEL`, `ANNUAL_LEAVE_REQUESTED_LABEL` and the list heading
//  `BOOKING_CONFLICTS_HEADING`. Swift only maps the stores onto the inputs (leave as the reader returned it, the
//  organisation's standard day, the roster) and shows the result; every booking flow asks the booker to tick or drop
//  each row before it saves.
//

import Foundation

/// One `bookingLeaveConflicts` row.
nonisolated struct BookingLeaveConflict: Hashable, Sendable {
    /// The person id as given in `people` (the booking's stored `operativeId`, or a manager's users id).
    let personId: String
    let dayKey: String
    let leaveId: String
    /// `FULL DAY`, `AM` or `PM`.
    let leaveSlot: String
    /// `approved` or `pending`.
    let status: String
    let label: String

    var isPending: Bool { status == "pending" }

    /// "Annual leave booked · AM" / "Annual leave requested · Full day" (web `leaveConflictDetail`).
    var detail: String {
        let slot = leaveSlot == "FULL DAY" ? "Full day" : leaveSlot
        return "\(label) · \(slot)"
    }
}

extension CanonicalBusinessEngine {
    /// `bookingLeaveConflicts(input)`. Nil when the script did not answer.
    nonisolated static func bookingLeaveConflicts(_ input: [String: Any]) -> [BookingLeaveConflict]? {
        guard let rows = callJSON("bookingLeaveConflicts", arguments: [input]) as? [Any] else { return nil }
        return rows.compactMap { item in
            guard let row = item as? [String: Any],
                  let personId = row["personId"] as? String,
                  let dayKey = row["dayKey"] as? String else { return nil }
            return BookingLeaveConflict(
                personId: personId,
                dayKey: dayKey,
                leaveId: row["leaveId"] as? String ?? "",
                leaveSlot: row["leaveSlot"] as? String ?? "FULL DAY",
                status: row["status"] as? String ?? "approved",
                label: row["label"] as? String ?? ""
            )
        }
    }

    /// `BOOKING_CONFLICTS_HEADING`.
    nonisolated static var bookingConflictsHeading: String {
        constant("BOOKING_CONFLICTS_HEADING", as: String.self)
            ?? "Some selected days clash. Tick to confirm, or ✕ to drop that day."
    }
}

/// The inputs `bookingLeaveConflicts` reads, built from the app's stores. No rule is decided here.
enum BookingLeaveConflictInputs {
    /// One person being booked: `id` is the id the flow books under (stored `operativeId`, or a users id for a
    /// manager booking); `userId` / `operativeIds` / `email` are the other ids leave may be stored under.
    struct Person: Hashable {
        var id: String
        var userId: String?
        var operativeIds: [String] = []
        var email: String?

        var payload: [String: Any] {
            var row: [String: Any] = ["id": id, "operativeIds": operativeIds]
            if let userId, !userId.isEmpty { row["userId"] = userId }
            if let email, !email.isEmpty { row["email"] = email }
            return row
        }
    }

    /// The person behind an in-app operative id: its stored id, the linked account and that account's email.
    static func person(operativeId: UUID, operatives: [Operative], users: [AppUser]) -> Person {
        let stored = Booking.storedOperativeId(for: operativeId)
        let operative = operatives.first { $0.id == operativeId }
        let email = (operative?.email ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let user = users.first { !email.isEmpty && $0.email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == email }
            ?? users.first { $0.id == stored }
        var operativeIds: [String] = []
        if let documentId = operative?.documentId, documentId != stored { operativeIds.append(documentId) }
        return Person(
            id: stored,
            userId: operative?.linkedUserId ?? user?.id,
            operativeIds: operativeIds,
            email: email.isEmpty ? user?.email : email
        )
    }

    /// A manager / admin booked under their users id (manager site bookings, My Schedule).
    static func person(user: AppUser) -> Person {
        Person(id: user.id, userId: user.id, operativeIds: [], email: user.email)
    }

    /// One leave record as the reader returned it (`labourHolidayInput`: stored ids, organisation-zone day keys),
    /// with its slot and status.
    static func holiday(_ holiday: HolidayBooking) -> [String: Any] {
        var row: [String: Any] = [
            "id": holiday.documentId,
            "startDayKey": holiday.startDayKey,
            "endDayKey": holiday.endDayKey,
            "timeSlot": holiday.timeSlot.rawValue,
            "status": holiday.status.rawValue,
        ]
        if let userId = holiday.userId, !userId.isEmpty { row["userId"] = userId }
        if let operativeId = holiday.operativeIdRaw, !operativeId.isEmpty { row["operativeId"] = operativeId }
        return row
    }

    /// Leave rows for `people` on `dates` for a booking with this slot. Empty when there is nothing to check or the
    /// script did not answer (the save then goes ahead as before; the warnings still pick the leave up).
    static func conflicts(
        people: [Person],
        dates: [Date],
        holidays: [HolidayBooking],
        users: [AppUser],
        policy: OrgPayrollTimePolicy,
        timeSlot: String?,
        workStartTime: String? = nil,
        workEndTime: String? = nil
    ) -> [BookingLeaveConflict] {
        guard !people.isEmpty, !dates.isEmpty, !holidays.isEmpty else { return [] }
        let day = CanonicalStandardDayInput(policy: policy)
        var input: [String: Any] = [
            "people": people.map(\.payload),
            "dayKeys": Array(Set(dates.map { OrganizationRulebookContext.dayKey($0) })).sorted(),
            "holidays": holidays.map(holiday),
            "timeZone": OrganizationRulebookContext.timeZoneIdentifier,
            "roster": RulebookPeople.roster(users),
        ]
        var dayInput: [String: Any] = [:]
        if let value = day.standardDayStart { dayInput["standardDayStart"] = value }
        if let value = day.standardDayEnd { dayInput["standardDayEnd"] = value }
        if let value = day.breakWindowStart { dayInput["breakWindowStart"] = value }
        if let value = day.breakWindowEnd { dayInput["breakWindowEnd"] = value }
        input["day"] = dayInput
        if let timeSlot { input["timeSlot"] = timeSlot }
        if let workStartTime { input["workStartTime"] = workStartTime }
        if let workEndTime { input["workEndTime"] = workEndTime }
        return CanonicalBusinessEngine.bookingLeaveConflicts(input) ?? []
    }
}
