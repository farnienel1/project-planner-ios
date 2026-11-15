//
//  Rulebook+Release153.swift
//  Project Planner
//
//  RULEBOOK 1.53.0 (calculation sweep, web #331): Home "Up next" (`homeUpNextRows`), Daily Overview's annual leave
//  rows (`dailyOverviewLeaveRows`) and a clash's documents to delete on undo (`clashDocumentsToRemove`). Every answer
//  comes from the packed script through `CanonicalBusinessEngine.callJSON`; Swift only renders it.
//

import Foundation

/// One `homeUpNextRows` row.
nonisolated struct RulebookHomeUpNextRow: Hashable, Sendable {
    let id: String
    /// `labour` or `manager`.
    let kind: String
    let dayKey: String
    let startMinutes: Int
    /// "07:30".
    let startText: String
    /// "07:30–16:00", or '' when the booking has no clock range.
    let timeRange: String
}

/// One booking as `homeUpNextRows` reads it.
nonisolated struct RulebookHomeUpNextBooking: Sendable {
    var id: String
    /// Labour: the stored `operativeId`; manager site booking: the stored `userId`.
    var personId: String
    var dayKey: String
    var status: String?
    var timeSlot: String
    var workStartTime: String?
    var workEndTime: String?

    var json: [String: Any] {
        var row: [String: Any] = [
            "id": id, "personId": personId, "dayKey": dayKey, "timeSlot": timeSlot,
            "workStartTime": workStartTime.map { $0 as Any } ?? NSNull(),
            "workEndTime": workEndTime.map { $0 as Any } ?? NSNull(),
        ]
        if let status { row["status"] = status }
        return row
    }
}

extension CanonicalBusinessEngine {
    /// `homeUpNextRows({ nowMs, timeZone, viewer, roster, operatives, bookings, managerSiteBookings, policy, limit,
    /// minDistinctDays })`: the viewer's bookings from today on (organisation day; today's stay all day, Completed
    /// shows), matched under every id they go by without case, in start order, and the first days. Nil when the
    /// script did not answer.
    nonisolated static func homeUpNextRows(
        now: Date,
        timeZone: String,
        viewer: [String: Any],
        roster: [[String: Any]],
        operatives: [[String: Any]],
        bookings: [RulebookHomeUpNextBooking],
        managerSiteBookings: [RulebookHomeUpNextBooking],
        policy: Any,
        limit: Int = 48,
        minDistinctDays: Int = 2
    ) -> (rows: [RulebookHomeUpNextRow], days: [(dayKey: String, rows: [RulebookHomeUpNextRow])])? {
        let input: [String: Any] = [
            "nowMs": now.timeIntervalSince1970 * 1000,
            "timeZone": timeZone,
            "viewer": viewer,
            "roster": roster,
            "operatives": operatives,
            "bookings": bookings.map(\.json),
            "managerSiteBookings": managerSiteBookings.map(\.json),
            "policy": policy,
            "limit": limit,
            "minDistinctDays": minDistinctDays,
        ]
        guard let result = callJSON("homeUpNextRows", arguments: [input]) as? [String: Any] else { return nil }
        func rows(_ value: Any?) -> [RulebookHomeUpNextRow] {
            ((value as? [Any]) ?? []).compactMap { entry in
                guard let row = CanonicalDocumentRow(entry) else { return nil }
                return RulebookHomeUpNextRow(
                    id: row.id,
                    kind: row.text("kind"),
                    dayKey: row.text("dayKey"),
                    startMinutes: Int(row.number("startMinutes") ?? 0),
                    startText: row.text("startText"),
                    timeRange: row.text("timeRange")
                )
            }
        }
        let days: [(dayKey: String, rows: [RulebookHomeUpNextRow])] = ((result["days"] as? [Any]) ?? []).compactMap { entry in
            guard let day = entry as? [String: Any], let key = day["dayKey"] as? String else { return nil }
            return (dayKey: key, rows: rows(day["rows"]))
        }
        return (rows(result["rows"]), days)
    }

    /// `dailyOverviewLeaveRows(records, dayKey, timeZone, nonWorkingDayKeys)`: the ids of the approved records whose
    /// leave days (`leaveRecordDayKeys`, weekends and the given bank holidays skipped inside a multi-day record)
    /// include `dayKey`. Nil when the script did not answer.
    nonisolated static func dailyOverviewLeaveRecordIds(
        records: [(id: String, startDayKey: String, endDayKey: String, timeSlot: String, status: String)],
        dayKey: String,
        timeZone: String,
        bankHolidayDayKeys: [String]
    ) -> Set<String>? {
        let input = records.map {
            ["id": $0.id, "startDayKey": $0.startDayKey, "endDayKey": $0.endDayKey, "timeSlot": $0.timeSlot, "status": $0.status]
        }
        guard let rows = callJSON("dailyOverviewLeaveRows", arguments: [input, dayKey, timeZone, bankHolidayDayKeys]) as? [Any] else {
            return nil
        }
        return Set(rows.compactMap { ($0 as? [String: Any])?["id"] as? String })
    }

    /// `clashDocumentsToRemove(clash, { acceptedClashes, resolutions })`: every stored document of one clash (matched
    /// ignoring case and the order of the two booking ids) plus the ids the app writes now, in both collections.
    nonisolated static func clashDocumentsToRemove(
        bookingAId: String,
        bookingBId: String,
        resolutionKey: String?,
        acceptedClashes: [(id: String, bookingAId: String?, bookingBId: String?)],
        resolutions: [(id: String, resolutionKey: String?)]
    ) -> (acceptedClash: [String], resolution: [String])? {
        var clash: [String: Any] = ["bookingAId": bookingAId, "bookingBId": bookingBId]
        if let resolutionKey { clash["resolutionKey"] = resolutionKey }
        let docs: [String: Any] = [
            "acceptedClashes": acceptedClashes.map { row -> [String: Any] in
                [
                    "id": row.id,
                    "bookingAId": row.bookingAId.map { $0 as Any } ?? NSNull(),
                    "bookingBId": row.bookingBId.map { $0 as Any } ?? NSNull(),
                ]
            },
            "resolutions": resolutions.map { row -> [String: Any] in
                ["id": row.id, "resolutionKey": row.resolutionKey.map { $0 as Any } ?? NSNull()]
            },
        ]
        guard let result = callJSON("clashDocumentsToRemove", arguments: [clash, docs]) as? [String: Any] else { return nil }
        func strings(_ key: String) -> [String] { ((result[key] as? [Any]) ?? []).compactMap { $0 as? String } }
        return (strings("acceptedClash"), strings("resolution"))
    }
}
