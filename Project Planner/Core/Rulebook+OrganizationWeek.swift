//
//  Rulebook+OrganizationWeek.swift
//  Project Planner
//
//  RULEBOOK 1.35.0 §12 `organizationWeekDayKeys(dayKey, timeZone)`: the Monday–Sunday week containing a day, in the
//  organisation's business time zone (never the phone's calendar, guardrail 2).
//

import Foundation

extension CanonicalBusinessEngine {
    /// The organisation-zone Monday (day key) of the week containing `date`. Nil when the script did not answer.
    nonisolated static func organizationWeekStartDayKey(
        containing date: Date,
        timeZone: String = OrganizationRulebookContext.timeZoneIdentifier
    ) -> String? {
        guard let dayKey = dayKeyInOrganizationZone(date, timeZone: timeZone),
              let week = callJSON("organizationWeekDayKeys", arguments: [dayKey, timeZone]) as? [String: Any],
              let start = week["startDayKey"] as? String,
              !start.isEmpty else { return nil }
        return start
    }
}
