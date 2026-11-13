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
    /// The record that decided the mark (for a mixed day, the approved half's).
    var recordId: String? = nil
    /// How each half of the day is shaded: "approved", "pending" or nil (not leave). A full day has both alike.
    var am: String? = nil
    var pm: String? = nil

    /// Whether the two halves look different (a half day, or one approved half and one pending half).
    var isHalfDay: Bool { am != pm }
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
                    title: day["title"] as? String ?? "",
                    recordId: day["recordId"] as? String,
                    am: day["am"] as? String,
                    pm: day["pm"] as? String
                )
            }
            out[key] = days
        }
        return out
    }
}

/// RULEBOOK 1.37.0 §21: a multi-day leave record skips the region's bank holidays, so no leave is marked on the grid
/// until the bank-holiday list has loaded (as web) — otherwise a bank holiday, or the wrong region's, would show "AL"
/// for a moment. Not a rule: it only decides whether to ask the script yet.
enum ScheduleLeaveMarksGate {
    static func marks(
        bankHolidaysReady: Bool,
        compute: () -> [String: [RulebookScheduleLeaveMark?]]?
    ) -> [String: [RulebookScheduleLeaveMark?]] {
        guard bankHolidaysReady else { return [:] }
        return compute() ?? [:]
    }
    /// The grid's own wait for the bank holidays (offline a fetch can take 20 s a year): after this the marks show
    /// with the bank holidays already cached and are worked out again when the load finishes.
    static let bankHolidayWaitCapSeconds: Double = 10

    /// For each visible week: not ready until that week's load finishes or the cap passes, whichever is first. A week
    /// left before then (the task is cancelled) never marks the next one ready.
    @MainActor
    static func waitForBankHolidays(
        capSeconds: Double = bankHolidayWaitCapSeconds,
        setReady: @escaping @MainActor (Bool) -> Void,
        load: @MainActor () async -> Void
    ) async {
        setReady(false)
        let cap = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(max(0, capSeconds) * 1_000_000_000))
            guard !Task.isCancelled else { return }
            setReady(true)
        }
        await withTaskCancellationHandler {
            await load()
        } onCancel: {
            cap.cancel()
        }
        cap.cancel()
        guard !Task.isCancelled else { return }
        setReady(true)
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

// MARK: - Tile colour (RULEBOOK 1.37.0 §21, `scheduleCellKind`)

/// The answer of `scheduleCellKind`: which of the five legend looks a booking chip takes, and its hours.
nonisolated struct RulebookScheduleCellKind: Hashable, Sendable {
    /// standard, split, otOnly or halfDay.
    let tone: String
    let standardHours: Double
    let overtimeHours: Double
    let halfLabel: String?
}

extension CanonicalBusinessEngine {
    nonisolated private static let scheduleCellMemo = RulebookAnswerMemo<String, RulebookScheduleCellKind>(limit: 512)

    /// RULEBOOK 1.37.0 `scheduleCellKind({ paidHours, overtimeHours, timeSlot })`: the chip colour both apps use (a 0h
    /// booking is a Standard 0h chip, never hidden). Nil when the script did not answer.
    nonisolated static func scheduleCellKind(paidHours: Double, overtimeHours: Double, timeSlot: String?) -> RulebookScheduleCellKind? {
        let input: [String: Any] = [
            "paidHours": paidHours.isFinite ? paidHours : 0,
            "overtimeHours": overtimeHours.isFinite ? overtimeHours : 0,
            "timeSlot": timeSlot.map { $0 as Any } ?? NSNull(),
        ]
        guard let key = rulebookMemoKey(input) else { return nil }
        return scheduleCellMemo.value(for: key) {
            guard let row = callJSON("scheduleCellKind", arguments: [input]) as? [String: Any],
                  let tone = row["tone"] as? String else { return nil }
            return RulebookScheduleCellKind(
                tone: tone,
                standardHours: (row["standardHours"] as? NSNumber)?.doubleValue ?? 0,
                overtimeHours: (row["overtimeHours"] as? NSNumber)?.doubleValue ?? 0,
                halfLabel: row["halfLabel"] as? String
            )
        }
    }
}

// MARK: - Tile hours (RULEBOOK 1.37.0 §21, `scheduleCellHours`)

/// The `payrollHoursResult` fields `scheduleCellHours` reads: the total and each segment's kind and paid hours.
nonisolated struct RulebookScheduleCellHoursInput: Hashable, Sendable {
    nonisolated struct Segment: Hashable, Sendable {
        let kind: String
        let paidHours: Double
    }

    let totalPaidHours: Double
    let segments: [Segment]
}

/// The answer of `scheduleCellHours`: the booking's paid hours and the paid hours of its multiplied segments.
nonisolated struct RulebookScheduleCellHours: Hashable, Sendable {
    let paidHours: Double
    let overtimeHours: Double
}

extension CanonicalBusinessEngine {
    nonisolated private static let scheduleCellHoursMemo = RulebookAnswerMemo<RulebookScheduleCellHoursInput, RulebookScheduleCellHours>(limit: 512)

    /// RULEBOOK 1.37.0 §21 `scheduleCellHours(payrollHoursResult)` → `{ paidHours, overtimeHours }`: the hours a
    /// scheduling tile shows — the pay rule's total and the paid hours of its segments at a multiplier (outside the
    /// window, or every hour at N×; Sunday 07:30–14:00 every hour ×2 → 13; a weekday 06:30–16:30 → 3). The figures
    /// `scheduleCellKind` colours. Nil when the script did not answer. Replaces the Swift copy
    /// `PayrollHoursResult.paidOvertimeHours`.
    nonisolated static func scheduleCellHours(_ input: RulebookScheduleCellHoursInput) -> RulebookScheduleCellHours? {
        scheduleCellHoursMemo.value(for: input) {
            let result: [String: Any] = [
                "totalPaidHours": input.totalPaidHours.isFinite ? input.totalPaidHours : 0,
                "segments": input.segments.map { ["kind": $0.kind, "paidHours": $0.paidHours.isFinite ? $0.paidHours : 0] },
            ]
            guard let row = callJSON("scheduleCellHours", arguments: [result]) as? [String: Any],
                  let paid = (row["paidHours"] as? NSNumber)?.doubleValue,
                  let overtime = (row["overtimeHours"] as? NSNumber)?.doubleValue else { return nil }
            return RulebookScheduleCellHours(paidHours: paid, overtimeHours: overtime)
        }
    }
}

// MARK: - One tile per person-day (RULEBOOK 1.41.0 §21, `scheduleDayCell`)

/// One booking of a person's day as `scheduleDayCell` adds it up: the pay rule's paid hours, the paid hours at a
/// multiplier, the stored slot and the clock overtime (`payrollMultipliedHours`).
nonisolated struct RulebookScheduleDayBooking: Hashable, Sendable {
    let paidHours: Double
    let overtimeHours: Double
    let timeSlot: String?
    var overtimeClockHours: Double = 0
    var overtimeMultiplier: Double = 1
    var overtimeBreakHours: Double = 0
}

/// The answer of `scheduleDayCell`: the colour of the summed hours and the tile's text.
nonisolated struct RulebookScheduleDayCell: Hashable, Sendable {
    let cell: RulebookScheduleCellKind
    let totalHours: Double
    let bookingCount: Int
    /// "26h".
    let hoursText: String
    /// "2 bookings" (nil for one booking).
    let countText: String?
    /// "26h · 2 bookings", or "8h".
    let headline: String
    /// "Std", "OT", "AM" / "PM"; nil on a split tile and, for Std / OT, under the leave band.
    let caption: String?
    /// "18h Std" ("18h" under the leave band); nil with no standard hours.
    let standardText: String?
    /// "8h OT" ("8h" under the leave band); nil with no overtime.
    let overtimeText: String?
    let overtimeLines: [String]
}

extension CanonicalBusinessEngine {
    nonisolated private static let scheduleDayCellMemo = RulebookAnswerMemo<String, RulebookScheduleDayCell>(limit: 512)

    /// RULEBOOK 1.41.0 `scheduleDayCell({ bookings, onLeave })`: one tile per person-day — "26h · 2 bookings" with the
    /// standard and overtime hours underneath; the Std / OT words dropped on a leave day. Nil with no booking or when
    /// the script did not answer.
    nonisolated static func scheduleDayCell(bookings: [RulebookScheduleDayBooking], onLeave: Bool) -> RulebookScheduleDayCell? {
        guard !bookings.isEmpty else { return nil }
        let input: [String: Any] = [
            "onLeave": onLeave,
            "bookings": bookings.map { booking -> [String: Any] in
                var row: [String: Any] = [
                    "paidHours": booking.paidHours.isFinite ? booking.paidHours : 0,
                    "overtimeHours": booking.overtimeHours.isFinite ? booking.overtimeHours : 0,
                    "timeSlot": booking.timeSlot.map { $0 as Any } ?? NSNull(),
                ]
                if booking.overtimeClockHours > 0 {
                    row["overtime"] = [
                        "clockHours": booking.overtimeClockHours,
                        "multiplier": booking.overtimeMultiplier,
                        "breakHours": booking.overtimeBreakHours,
                    ]
                }
                return row
            },
        ]
        guard let key = rulebookMemoKey(input) else { return nil }
        return scheduleDayCellMemo.value(for: key) {
            guard let row = callJSON("scheduleDayCell", arguments: [input]) as? [String: Any],
                  let tone = row["tone"] as? String,
                  let hoursText = row["hoursText"] as? String,
                  let headline = row["headline"] as? String else { return nil }
            func number(_ name: String) -> Double { (row[name] as? NSNumber)?.doubleValue ?? 0 }
            return RulebookScheduleDayCell(
                cell: RulebookScheduleCellKind(
                    tone: tone,
                    standardHours: number("standardHours"),
                    overtimeHours: number("overtimeHours"),
                    halfLabel: row["halfLabel"] as? String
                ),
                totalHours: number("totalHours"),
                bookingCount: (row["bookingCount"] as? NSNumber)?.intValue ?? bookings.count,
                hoursText: hoursText,
                countText: row["countText"] as? String,
                headline: headline,
                caption: row["caption"] as? String,
                standardText: row["standardText"] as? String,
                overtimeText: row["overtimeText"] as? String,
                overtimeLines: row["overtimeLines"] as? [String] ?? []
            )
        }
    }
}

extension RulebookScheduleDayBooking {
    /// A labour or manager schedule booking's figures for `scheduleDayCell` (`payrollHoursResult` under the day's
    /// working hours). A mapping only.
    @MainActor static func from(_ result: PayrollHoursResult, timeSlot: String?) -> RulebookScheduleDayBooking {
        let multiplied = result.multipliedHours
        return RulebookScheduleDayBooking(
            paidHours: result.totalPaidHours,
            overtimeHours: CanonicalBusinessEngine.scheduleCellHours(result.scheduleCellHoursInput)?.overtimeHours ?? 0,
            timeSlot: timeSlot,
            overtimeClockHours: multiplied?.clockHours ?? 0,
            overtimeMultiplier: multiplied?.multiplier ?? 1,
            overtimeBreakHours: multiplied?.breakHours ?? 0
        )
    }
}
