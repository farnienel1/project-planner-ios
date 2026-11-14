//
//  Rulebook+TimesheetSnapshot.swift
//  Project Planner
//
//  RULEBOOK 1.43.0 (owner reports, 14 Nov): typed wrappers for the timesheet fixes — web
//  `lib/canonical/timesheetSnapshot.ts` (when a signed snapshot may be built or rebuilt, when extras may still be added),
//  `payrollHours.ts` (`payrollLineClockRanges`, `timesheetLineClockText`), `payeClaims.ts` (`agreedManagerSuggestions`)
//  and `jobScheduleLeave.ts` (`subcontractorScheduleCell`). Swift maps inputs and shows results; nothing is decided here.
//

import Foundation

/// RULEBOOK 1.43.0 §8 `payrollLineClockRanges(result)` → `{ standard, overtime, standardText, overtimeText }`.
nonisolated struct RulebookPayrollLineClockRanges: Equatable, Hashable, Sendable {
    /// The clock ranges of the standard hours (the working day, or a set-window weekend day's window), earliest first.
    let standard: [String]
    /// The clock ranges paid at the multiplier, earliest first.
    let overtime: [String]
    /// "07:00–16:00" ('' when none).
    let standardText: String
    /// "05:00–07:00 + 16:00–19:00" ('' when none).
    let overtimeText: String

    init?(json: Any?) {
        guard let row = json as? [String: Any] else { return nil }
        self.standard = row["standard"] as? [String] ?? []
        self.overtime = row["overtime"] as? [String] ?? []
        self.standardText = row["standardText"] as? String ?? ""
        self.overtimeText = row["overtimeText"] as? String ?? ""
    }
}

/// RULEBOOK 1.43.0 §8 `timesheetSnapshotReady(input)` → `{ ready, failed, message }`.
nonisolated struct RulebookTimesheetSnapshotReady: Equatable, Hashable, Sendable {
    let ready: Bool
    let failed: Bool
    /// "Loading bookings…", or why the sheet cannot be signed yet; nil when ready.
    let message: String?

    init?(json: Any?) {
        guard let row = json as? [String: Any], let ready = row["ready"] as? Bool else { return nil }
        self.ready = ready
        self.failed = row["failed"] as? Bool ?? false
        self.message = row["message"] as? String
    }
}

/// RULEBOOK 1.43.0 §8 `timesheetOwnerCanAddExtras(sheet, { selfSigned })` → `{ allowed, message }`.
nonisolated struct RulebookTimesheetExtrasPermission: Equatable, Hashable, Sendable {
    let allowed: Bool
    /// `TIMESHEET_SIGNED_OFF_EXTRAS_MESSAGE` when not allowed.
    let message: String?

    init(allowed: Bool, message: String?) {
        self.allowed = allowed
        self.message = message
    }

    init?(json: Any?) {
        guard let row = json as? [String: Any], let allowed = row["allowed"] as? Bool else { return nil }
        self.allowed = allowed
        self.message = row["message"] as? String
    }
}

/// RULEBOOK 1.43.0 §21 `subcontractorScheduleCell` → the scheduling tile of a subcontractor's day: its working window(s)
/// only, never paid hours or a standard / overtime split.
nonisolated struct RulebookSubcontractorScheduleCell: Equatable, Hashable, Sendable {
    /// Each booking's working window, "07:30–16:00", earliest first.
    let times: [String]
    /// `times` joined with " + ".
    let timesText: String
    let bookingCount: Int
    /// "2 bookings" (nil for one booking).
    let countText: String?
    /// "07:30–16:00", or "07:30–16:00 · 2 bookings".
    let headline: String

    init?(json: Any?) {
        guard let row = json as? [String: Any], let headline = row["headline"] as? String else { return nil }
        self.times = row["times"] as? [String] ?? []
        self.timesText = row["timesText"] as? String ?? ""
        self.bookingCount = (row["bookingCount"] as? NSNumber)?.intValue ?? 0
        self.countText = row["countText"] as? String
        self.headline = headline
    }

    /// The tile in the shape the person-day chip draws (`RulebookScheduleDayCell`): the times as its main line, the
    /// count under it, one plain colour, no hours, no Std / OT and no overtime lines. A mapping only.
    var dayCell: RulebookScheduleDayCell {
        RulebookScheduleDayCell(
            cell: RulebookScheduleCellKind(tone: "standard", standardHours: 0, overtimeHours: 0, halfLabel: nil),
            totalHours: 0,
            bookingCount: bookingCount,
            hoursText: timesText.isEmpty ? headline : timesText,
            countText: countText,
            headline: headline,
            caption: nil,
            standardText: nil,
            overtimeText: nil,
            overtimeLines: []
        )
    }
}

extension CanonicalBusinessEngine {
    /// `TIMESHEET_SIGNED_OFF_EXTRAS_MESSAGE` ("This timesheet is signed off — add it to your next timesheet.").
    nonisolated static var timesheetSignedOffExtrasMessage: String {
        constant("TIMESHEET_SIGNED_OFF_EXTRAS_MESSAGE", as: String.self)
            ?? "This timesheet is signed off — add it to your next timesheet."
    }

    // MARK: Line times (1.43.0 §8)

    /// RULEBOOK 1.43.0 §8 `payrollLineClockRanges(payrollHoursResult)`: the clock times of a booking's standard and
    /// overtime parts, from the pay rule's own segments. Nil when the script did not answer.
    nonisolated static func payrollLineClockRanges(_ hours: CanonicalPayrollHours) -> RulebookPayrollLineClockRanges? {
        let segments: [[String: Any]] = hours.segments.map { segment in
            [
                "kind": segment.kind,
                "clockStart": segment.clockStart.map { $0 as Any } ?? NSNull(),
                "clockEnd": segment.clockEnd.map { $0 as Any } ?? NSNull(),
                "baseHours": segment.baseHours,
                "multiplier": segment.multiplier,
                "paidHours": segment.paidHours,
            ]
        }
        return RulebookPayrollLineClockRanges(json: memoCallJSON("payrollLineClockRanges", arguments: [["segments": segments]]))
    }

    /// RULEBOOK 1.43.0 §8 `timesheetLineClockText(details)`: the clock part of a timesheet line's details
    /// ("16:00–19:00 · OT 6.5h × 2 − 0.5h break = 12.5h" → "16:00–19:00"), so the multiplied text is not printed twice.
    /// The details as stored (trimmed) when the script did not answer.
    nonisolated static func timesheetLineClockText(_ details: String?) -> String {
        if let text = memoCallJSON("timesheetLineClockText", arguments: [details ?? ""]) as? String { return text }
        return (details ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: Snapshot gates (1.43.0 §8)

    /// RULEBOOK 1.43.0 §8 `timesheetSnapshotReady({ bookingsLoaded, bookingsFailed, payProfileLoaded, rateHistoryLoaded })`:
    /// whether a timesheet may be signed, counter-signed or invoiced now. Nil when the script did not answer.
    nonisolated static func timesheetSnapshotReady(
        bookingsLoaded: Bool,
        bookingsFailed: Bool,
        payProfileLoaded: Bool = true,
        rateHistoryLoaded: Bool = true
    ) -> RulebookTimesheetSnapshotReady? {
        RulebookTimesheetSnapshotReady(json: callJSON("timesheetSnapshotReady", arguments: [[
            "bookingsLoaded": bookingsLoaded,
            "bookingsFailed": bookingsFailed,
            "payProfileLoaded": payProfileLoaded,
            "rateHistoryLoaded": rateHistoryLoaded,
        ]]))
    }

    /// An instant as the 1.43.0 snapshot rules read it (`present`): epoch milliseconds, or JSON null.
    nonisolated private static func instantArgument(_ date: Date?) -> Any {
        guard let date else { return NSNull() }
        return date.timeIntervalSince1970 * 1000
    }

    /// RULEBOOK 1.43.0 §8 `timesheetSnapshotNeedsRebuild(sheet, liveLabourLines)` (review r318): the stored signed snapshot
    /// was frozen with no labour lines by the loading bug — nobody exported it, and the period has a live labour line
    /// (PAYE days left out) whose booking was created on or before the sheet's approval (the snapshot's `approvedAt`,
    /// else `managerSignedAt`). A booking added later, or one whose creation time is unknown, never re-prices a signed
    /// sheet. False for no snapshot, a snapshot with any labour line, an exported sheet, or no answer.
    nonisolated static func timesheetSnapshotNeedsRebuild(
        storedOverrideLineCount: Int?,
        overrideApprovedAt: Date?,
        exportedAt: Date?,
        managerSignedAt: Date?,
        liveLabourLines: [(isPayeDay: Bool, bookingCreatedAt: Date?)]
    ) -> Bool {
        var sheet: [String: Any] = [
            "exportedAt": instantArgument(exportedAt),
            "managerSignedAt": instantArgument(managerSignedAt),
        ]
        if let count = storedOverrideLineCount {
            sheet["weeklyReportOverride"] = [
                "lines": Array(repeating: [String: Any](), count: max(0, count)),
                "approvedAt": instantArgument(overrideApprovedAt),
            ] as [String: Any]
        } else {
            sheet["weeklyReportOverride"] = NSNull()
        }
        let lines: [[String: Any]] = liveLabourLines.map { line in
            ["isPayeDay": line.isPayeDay, "bookingCreatedAt": instantArgument(line.bookingCreatedAt)]
        }
        return callJSON("timesheetSnapshotNeedsRebuild", arguments: [sheet, lines]) as? Bool ?? false
    }

    /// RULEBOOK 1.43.0 §8 `timesheetOwnerCanAddExtras(sheet, { selfSigned })`: the person adds price work or expenses
    /// only until their line manager signs (`managerSignedAt`, or the older `approvedAt`); a self-signed sheet stays
    /// open. When the script did not answer, nothing is offered (the security rules refuse the write anyway).
    nonisolated static func timesheetOwnerCanAddExtras(
        managerSignedAt: Date?,
        approvedAt: Date?,
        selfSigned: Bool
    ) -> RulebookTimesheetExtrasPermission {
        let sheet: [String: Any] = [
            "managerSignedAt": instantArgument(managerSignedAt),
            "approvedAt": instantArgument(approvedAt),
        ]
        return RulebookTimesheetExtrasPermission(
            json: callJSON("timesheetOwnerCanAddExtras", arguments: [sheet, ["selfSigned": selfSigned]])
        ) ?? RulebookTimesheetExtrasPermission(allowed: false, message: "The rulebook did not answer. Try again.")
    }

    // MARK: Agreed-manager suggestions (1.43.0 §8)

    /// RULEBOOK 1.43.0 §8 `agreedManagerSuggestions(query, person, roster, { organizationId })`: the names offered for
    /// "Manager who agreed this" as the person types — the price work approvers' rule (`priceWorkApproverCandidates`),
    /// name containing the text, at most 6. Empty for an empty query or no answer.
    nonisolated static func agreedManagerSuggestions(
        query: String,
        person: [String: Any],
        roster: [[String: Any]],
        organizationId: String?
    ) -> [String] {
        callJSON(
            "agreedManagerSuggestions",
            arguments: [query, person, roster, ["organizationId": RulebookJSON.orNull(organizationId)]]
        ) as? [String] ?? []
    }

    // MARK: Subcontractor tiles (1.43.0 §21)

    /// RULEBOOK 1.43.0 §21 `subcontractorScheduleCell({ bookings, day, dayKey })`: a subcontractor's scheduling day shows
    /// only its working window(s), start to finish, and the number of bookings when more than one. `policy` is the
    /// working hours in effect that day (for a named slot's window). Nil with no booking or no answer.
    nonisolated static func subcontractorScheduleCell(
        bookings: [(timeSlot: String?, workStartTime: String?, workEndTime: String?)],
        policy: OrgPayrollTimePolicy?,
        dayKey: String
    ) -> RulebookSubcontractorScheduleCell? {
        guard !bookings.isEmpty else { return nil }
        let rows: [[String: Any]] = bookings.map { booking in
            [
                "timeSlot": booking.timeSlot.map { $0 as Any } ?? NSNull(),
                "workStartTime": booking.workStartTime.map { $0 as Any } ?? NSNull(),
                "workEndTime": booking.workEndTime.map { $0 as Any } ?? NSNull(),
            ]
        }
        var day: Any = NSNull()
        if let policy, let policyJSON = payrollPolicyJSON(policy) { day = policyJSON }
        let input: [String: Any] = ["bookings": rows, "day": day, "dayKey": dayKey]
        return RulebookSubcontractorScheduleCell(json: memoCallJSON("subcontractorScheduleCell", arguments: [input]))
    }
}
