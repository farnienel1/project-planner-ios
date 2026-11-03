//
//  ProjectStatusRulebook.swift
//  Project Planner
//
//  A job's status on a day comes from the rulebook's `jobWorkStatus` in the organisation zone (RULEBOOK §21).
//  Lists read `Project.status` many times per frame, so each answer is kept for the inputs it was
//  asked with; a new day or a changed job asks again.
//

import Foundation

enum ProjectStatusRulebook {
    private struct Key: Hashable {
        let zone: String
        let isLive: Bool
        let start: TimeInterval
        let end: TimeInterval
        let day: TimeInterval
    }

    private static let lock = NSLock()
    private static var answers: [Key: ProjectStatus] = [:]

    /// Nil when the script did not answer; the caller keeps its previous calculation then.
    static func status(isLive: Bool, start: Date, end: Date, on reference: Date) -> ProjectStatus? {
        let calendar = CanonicalBusinessEngine.businessCalendar
        let key = Key(
            zone: OrganizationRulebookContext.timeZoneIdentifier,
            isLive: isLive,
            start: calendar.startOfDay(for: start).timeIntervalSince1970,
            end: calendar.startOfDay(for: end).timeIntervalSince1970,
            day: calendar.startOfDay(for: reference).timeIntervalSince1970
        )
        lock.lock()
        if let known = answers[key] {
            lock.unlock()
            return known
        }
        lock.unlock()
        // RULEBOOK 1.21.0 §21 `jobWorkStatus(job, now, timeZone)`: the organisation zone is passed every time; the day
        // never comes from the device calendar or a London default.
        let zone = OrganizationRulebookContext.timeZoneIdentifier
        let job: [String: Any] = [
            "isLive": isLive,
            "startDayKey": OrganizationRulebookContext.dayKey(start),
            "endDayKey": OrganizationRulebookContext.dayKey(end),
        ]
        guard let raw = CanonicalBusinessEngine.callJSON(
                "jobWorkStatus",
                arguments: [job, OrganizationRulebookContext.dayKey(reference), zone]
              ) as? String,
              let status = status(fromRulebook: raw) else {
            return nil
        }
        lock.lock()
        if answers.count > 4000 { answers.removeAll() }
        answers[key] = status
        lock.unlock()
        return status
    }

    static func status(fromRulebook raw: String) -> ProjectStatus? {
        switch raw {
        case "active": return .active
        case "upcoming": return .upcoming
        case "completed": return .completed
        case "inactive": return .inactive
        default: return nil
        }
    }
}
