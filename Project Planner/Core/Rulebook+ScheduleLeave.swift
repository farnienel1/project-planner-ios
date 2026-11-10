//
//  Rulebook+ScheduleLeave.swift
//  Project Planner
//
//  RULEBOOK 1.37.0 §21 (owner decisions 10 Nov; web `lib/canonical/jobScheduleLeave.ts`): annual leave on a job's
//  Scheduling week. Who is on leave on which visible day, and its label ("AL", "AL AM", "AL PM", pending "AL?"), is
//  `jobScheduleLeaveMarks` in the packed script through `CanonicalBusinessEngine.callJSON`, memoised by its exact
//  input. Swift maps the stores into plain rows and draws the answer; no leave day, id match or label is worked out
//  here. The grid still lists only people booked on the job — leave never adds a row.
//

import Foundation

/// One day's answer of `jobScheduleLeaveMarks` for one person.
nonisolated struct RulebookScheduleLeaveMark: Hashable, Sendable {
    let dayKey: String
    /// `leaveDayKind`: approvedFull, approvedHalf, pendingFull, pendingHalf.
    let kind: String
    let pending: Bool
    /// "FULL DAY", "AM" or "PM".
    let slot: String
    /// "AL", "AL AM", "AL PM", "AL?", "AL? AM", "AL? PM".
    let label: String
    /// "Annual leave · Full day", "Annual leave requested · AM 06:30–10:30".
    let title: String

    var isHalfDay: Bool { slot == "AM" || slot == "PM" }
}

extension CanonicalBusinessEngine {
    nonisolated private static let scheduleLeaveMemo = RulebookAnswerMemo<String, [String: [RulebookScheduleLeaveMark?]]>(limit: 256)

    /// RULEBOOK 1.37.0 `jobScheduleLeaveMarks(input)`: per person key, the mark for each day key in `input.dayKeys`
    /// (nil when not on leave that day). Nil when the script did not answer.
    nonisolated static func jobScheduleLeaveMarks(_ input: [String: Any]) -> [String: [RulebookScheduleLeaveMark?]]? {
        guard let key = rulebookMemoKey(input) else { return nil }
        return scheduleLeaveMemo.value(for: key) {
            guard let rows = callJSON("jobScheduleLeaveMarks", arguments: [input]) as? [[String: Any]] else { return nil }
            return parseJobScheduleLeaveMarks(rows)
        }
    }

    /// Reads the script's answer. A data mapping, not a rule.
    nonisolated static func parseJobScheduleLeaveMarks(_ rows: [[String: Any]]) -> [String: [RulebookScheduleLeaveMark?]] {
        var out: [String: [RulebookScheduleLeaveMark?]] = [:]
        for row in rows {
            guard let key = row["key"] as? String else { continue }
            let days = (row["days"] as? [[String: Any]] ?? []).map { day -> RulebookScheduleLeaveMark? in
                guard day["onLeave"] as? Bool == true else { return nil }
                return RulebookScheduleLeaveMark(
                    dayKey: day["dayKey"] as? String ?? "",
                    kind: day["kind"] as? String ?? "",
                    pending: day["pending"] as? Bool ?? false,
                    slot: day["slot"] as? String ?? "FULL DAY",
                    label: day["label"] as? String ?? "",
                    title: day["title"] as? String ?? ""
                )
            }
            out[key] = days
        }
        return out
    }
}

/// Maps the app's stores into `jobScheduleLeaveMarks`' input. Plain data mapping only.
enum ScheduleLeaveMarksInput {
    /// One grid person: their row key and every id their bookings are filed under (stored spelling).
    struct Person {
        let key: String
        let operativeIds: [UUID]
        let userIds: [String]
    }

    static func build(
        people: [Person],
        days: [Date],
        holidays: [HolidayBooking],
        users: [AppUser],
        operatives: [Operative]
    ) -> [String: Any] {
        let roster: [[String: Any]] =
            users.map { user in
                [
                    "id": user.id,
                    "email": user.email,
                    "formerUserIds": user.formerUserIds,
                    "sameEmailUserIds": user.sameEmailUserIds,
                ] as [String: Any]
            } + operatives.map { operative in
                ["id": operative.documentId, "email": operative.email] as [String: Any]
            }
        let dayKeys = days.map { OrganizationRulebookContext.dayKey($0) }
        // Only records whose stored range touches the visible days are sent (a smaller memo key); which of those days
        // are leave days is still the script's answer.
        let first = dayKeys.min() ?? ""
        let last = dayKeys.max() ?? ""
        let records = holidays.map(\.rulebookLeaveRecord).filter { record in
            first.isEmpty || (record.startDayKey <= last && max(record.endDayKey, record.startDayKey) >= first)
        }
        return [
            "people": people.map { person -> [String: Any] in
                [
                    "key": person.key,
                    "ids": person.operativeIds.map { Booking.storedOperativeId(for: $0) } + person.userIds,
                ]
            },
            "holidays": records.map(\.json),
            "dayKeys": dayKeys,
            "timeZone": OrganizationRulebookContext.timeZoneIdentifier,
            "nonWorkingDayKeys": OrganizationBankHolidays.dayKeys,
            "roster": roster,
            "day": CanonicalBusinessEngine.openOrganizationPayrollPolicyState.map { $0 as Any } ?? NSNull(),
        ]
    }
}
