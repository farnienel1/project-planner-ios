import Foundation

// RULEBOOK 1.94.0–1.95.0 §23 "How a deadline reads": `deadlineDisplay(item, nowMs, timeZone)`, `deadlineTabCounts`,
// `deadlineSummaryLine`, `deadlineMovedNote`, `deadlineDayText`, `DEADLINE_TABS`, `DEADLINE_GROUPS`. Display only:
// nothing here is stored. Every day is the organisation-zone day (`OrganizationRulebookContext`), never the phone's.

/// One deadline as the rulebook reads it (`deadlineDisplay`).
nonisolated struct RulebookDeadlineDisplay: Hashable, Sendable {
    /// `met`, `late`, `overdue`, `blocked`, `behindPace`, `onTrack`.
    var status: String
    var statusLabel: String
    /// `red`, `amber`, `primary`, `green`, `grey`.
    var tone: String
    /// `overdue`, `thisWeek`, `nextWeek`, `later`, `completed`.
    var group: String
    /// Tab keys this deadline is listed under (`all`, `overdue`, `thisWeek`, `behindPace`, `completed`).
    var tabs: [String]
    var daysRemaining: Int?
    var dueText: String
    var pill: String
    var progressPercent: Int
    var expectedPercent: Int?
    var paceText: String?

    var isCompleted: Bool { group == "completed" }
}

/// One `{ key, label }` row of `DEADLINE_TABS` / `DEADLINE_GROUPS`.
nonisolated private struct RulebookDeadlineKeyLabel: Decodable, Sendable {
    let key: String
    let label: String
}

/// The script input for one deadline: the fields `deadlineDisplay` reads, as epoch milliseconds.
nonisolated struct RulebookDeadlineDisplayInput: Hashable, Sendable {
    var status: String
    var progress: Double
    var due: Date
    var start: Date?
    var createdAt: Date?
    var completedAt: Date?
    var title: String = ""

    private static func ms(_ date: Date?) -> Any { date.map { ($0.timeIntervalSince1970 * 1000).rounded() as Any } ?? NSNull() }

    func scriptArgument() -> [String: Any] {
        [
            "status": status,
            "progress": progress,
            "due": Self.ms(due),
            "start": Self.ms(start),
            "createdAt": Self.ms(createdAt),
            "completedAt": Self.ms(completedAt),
            "title": title,
        ]
    }

    var memoKey: String {
        func k(_ date: Date?) -> String { date.map { String(Int64(($0.timeIntervalSince1970 * 1000).rounded())) } ?? "-" }
        return "\(status)|\(progress)|\(k(due))|\(k(start))|\(k(createdAt))|\(k(completedAt))"
    }
}

extension CanonicalBusinessEngine {
    nonisolated private static let deadlineDisplayMemo = RulebookAnswerMemo<String, RulebookDeadlineDisplay>(limit: 1024)

    nonisolated private static func nowMs(_ now: Date) -> Double { (now.timeIntervalSince1970 * 1000).rounded() }

    /// RULEBOOK 1.94.0 §23 `deadlineDisplay(item, nowMs, timeZone)`. Memoised per input and organisation day. Nil when
    /// the script did not answer.
    nonisolated static func deadlineDisplay(
        _ input: RulebookDeadlineDisplayInput,
        now: Date = Date(),
        timeZone: String = OrganizationRulebookContext.timeZoneIdentifier
    ) -> RulebookDeadlineDisplay? {
        let key = "\(input.memoKey)|\(OrganizationRulebookContext.dayKey(now))|\(timeZone)"
        return deadlineDisplayMemo.value(for: key) {
            guard let row = callJSON("deadlineDisplay", arguments: [input.scriptArgument(), nowMs(now), timeZone]) as? [String: Any],
                  let status = row["status"] as? String,
                  let group = row["group"] as? String else { return nil }
            return RulebookDeadlineDisplay(
                status: status,
                statusLabel: row["statusLabel"] as? String ?? "",
                tone: row["tone"] as? String ?? "grey",
                group: group,
                tabs: (row["tabs"] as? [Any])?.compactMap { $0 as? String } ?? ["all"],
                daysRemaining: (row["daysRemaining"] as? NSNumber)?.intValue,
                dueText: row["dueText"] as? String ?? "",
                pill: row["pill"] as? String ?? "",
                progressPercent: (row["progressPercent"] as? NSNumber)?.intValue ?? 0,
                expectedPercent: (row["expectedPercent"] as? NSNumber)?.intValue,
                paceText: row["paceText"] as? String
            )
        }
    }

    /// RULEBOOK 1.94.0 §23 `deadlineTabCounts(items, nowMs, timeZone)` → count per tab key. Nil when the script did not
    /// answer.
    nonisolated static func deadlineTabCounts(
        _ items: [RulebookDeadlineDisplayInput],
        now: Date = Date(),
        timeZone: String = OrganizationRulebookContext.timeZoneIdentifier
    ) -> [String: Int]? {
        guard let row = callJSON("deadlineTabCounts", arguments: [items.map { $0.scriptArgument() }, nowMs(now), timeZone]) as? [String: Any] else {
            return nil
        }
        return row.compactMapValues { ($0 as? NSNumber)?.intValue }
    }

    /// RULEBOOK 1.94.0 §23 `deadlineSummaryLine(items, nowMs, timeZone)`: "2 of 3 complete · 1 on time · Next: …".
    nonisolated static func deadlineSummaryLine(
        _ items: [RulebookDeadlineDisplayInput],
        now: Date = Date(),
        timeZone: String = OrganizationRulebookContext.timeZoneIdentifier
    ) -> String? {
        callJSON("deadlineSummaryLine", arguments: [items.map { $0.scriptArgument() }, nowMs(now), timeZone]) as? String
    }

    /// RULEBOOK 1.94.0 §23 `deadlineMovedNote(from, to, timeZone)`: "Moved 1 day from 27 Nov"; "" when unchanged.
    nonisolated static func deadlineMovedNote(
        from: Date?,
        to: Date,
        timeZone: String = OrganizationRulebookContext.timeZoneIdentifier
    ) -> String? {
        guard let from else { return "" }
        return callJSON("deadlineMovedNote", arguments: [nowMs(from), nowMs(to), timeZone]) as? String
    }

    /// RULEBOOK 1.94.0 §23 `deadlineDayText(dayKey, withYear)`: "Fri 27 Nov" of the organisation day of `date`.
    nonisolated static func deadlineDayText(_ date: Date, withYear: Bool = false) -> String? {
        callJSON("deadlineDayText", arguments: [OrganizationRulebookContext.dayKey(date), withYear]) as? String
    }

    /// RULEBOOK 1.94.0 §23 `DEADLINE_TABS` / `DEADLINE_GROUPS` as `(key, label)` in order. Nil when the script did not load.
    nonisolated static func deadlineTabs() -> [(key: String, label: String)]? { keyLabelList("DEADLINE_TABS") }
    nonisolated static func deadlineGroups() -> [(key: String, label: String)]? { keyLabelList("DEADLINE_GROUPS") }

    nonisolated private static func keyLabelList(_ name: String) -> [(key: String, label: String)]? {
        guard let rows = constant(name, as: [RulebookDeadlineKeyLabel].self) else { return nil }
        return rows.map { ($0.key, $0.label) }
    }

    // MARK: RULEBOOK 1.95.0 §23 Reopen and reschedule reasons

    /// RULEBOOK 1.95.0 `DEADLINE_REOPEN_LABEL` ("Reopen").
    nonisolated static func deadlineReopenLabel() -> String {
        constant("DEADLINE_REOPEN_LABEL", as: String.self) ?? "Reopen"
    }

    /// RULEBOOK 1.95.0 `deadlineReopenFields(history)` → progress (0–100), status and the history note
    /// ("Reopened at 50%"). `history` is oldest first (`DLStore` keeps it newest first; pass it reversed). Nil when the
    /// script did not answer.
    nonisolated static func deadlineReopenFields(
        history: [(type: String, progress: Int?)]
    ) -> (progressPercent: Int, status: DLStatus, note: String)? {
        let rows: [[String: Any]] = history.map { row in
            var map: [String: Any] = ["type": row.type]
            if let progress = row.progress { map["progress"] = progress }
            return map
        }
        guard let result = callJSON("deadlineReopenFields", arguments: [rows]) as? [String: Any],
              let percent = (result["progressPercent"] as? NSNumber)?.intValue,
              let statusKey = result["status"] as? String,
              let status = DLStatus(rawValue: statusKey),
              let note = result["note"] as? String else { return nil }
        return (percent, status, note)
    }

    /// RULEBOOK 1.95.0 `DEADLINE_RESCHEDULE_REASONS`, in order (ends with "Other"). Nil when the script did not load.
    nonisolated static func deadlineRescheduleReasons() -> [String]? {
        constant("DEADLINE_RESCHEDULE_REASONS", as: [String].self)
    }

    /// RULEBOOK 1.95.0 `deadlineRescheduleReasonError(reason, note)`: why the reschedule can't be saved yet, or nil.
    /// When the script did not answer, a blocking message so nothing is saved unchecked.
    nonisolated static func deadlineRescheduleReasonError(reason: String?, note: String) -> String? {
        let value = callJSON("deadlineRescheduleReasonError", arguments: [reason ?? NSNull(), note])
        if value is NSNull { return nil }
        return (value as? String) ?? "Couldn't check the reason — try again."
    }

    /// RULEBOOK 1.95.0 `deadlineRescheduleReasonText(reason, note)`: "Weather" or "Weather — road closed".
    nonisolated static func deadlineRescheduleReasonText(reason: String, note: String) -> String? {
        callJSON("deadlineRescheduleReasonText", arguments: [reason, note]) as? String
    }
}
