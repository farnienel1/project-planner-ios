//
//  Rulebook+SiteMapLeave.swift
//  Project Planner
//
//  RULEBOOK 1.82.0 §21 (owner answer 24 Nov, item 1): the site map's "On annual leave" is the whole company's approved
//  leave on the day shown — leave is not tied to a job — worked out by the packed script (`siteMapLeaveSummary`: the
//  Daily Overview leave days, one per person). Swift only maps records and people in and the result out.
//

import Foundation

extension CanonicalBusinessEngine {
    struct SiteMapLeavePerson: Equatable {
        var key: String
        var name: String?
        var recordIds: [String]
    }

    /// `siteMapLeaveSummary`. `records`: `{ id, userId, operativeId, startDayKey, endDayKey, timeSlot, status }`;
    /// `roster`: `{ id, email, name, formerUserIds, sameEmailUserIds }`; `operatives`: `{ id, email, name }`. Nil when the
    /// script did not answer (callers then show no figure, never a count of their own).
    nonisolated static func siteMapLeaveSummary(
        records: [[String: Any]],
        dayKey: String,
        timeZone: String,
        nonWorkingDayKeys: [String],
        roster: [[String: Any]],
        operatives: [[String: Any]]
    ) -> (onAnnualLeave: Int, people: [SiteMapLeavePerson])? {
        guard let row = callJSON("siteMapLeaveSummary", arguments: [[
            "records": records, "dayKey": dayKey, "timeZone": timeZone, "nonWorkingDayKeys": nonWorkingDayKeys,
            "roster": roster, "operatives": operatives,
        ]]) as? [String: Any], let count = (row["onAnnualLeave"] as? NSNumber)?.intValue else { return nil }
        let people = (row["people"] as? [[String: Any]] ?? []).map { person in
            SiteMapLeavePerson(
                key: (person["key"] as? String) ?? "",
                name: person["name"] as? String,
                recordIds: (person["recordIds"] as? [Any] ?? []).compactMap { $0 as? String }
            )
        }
        return (count, people)
    }
}
