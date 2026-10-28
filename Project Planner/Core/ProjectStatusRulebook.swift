//
//  ProjectStatusRulebook.swift
//  Project Planner
//
//  A job's status on a day comes from the rulebook's `workStatusOn` (web uses the same function).
//  Lists read `Project.status` many times per frame, so each answer is kept for the inputs it was
//  asked with; a new day or a changed job asks again.
//

import Foundation

enum ProjectStatusRulebook {
    private struct Key: Hashable {
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
        guard let startKey = CanonicalBusinessEngine.dayKeyInOrganizationZone(start),
              let endKey = CanonicalBusinessEngine.dayKeyInOrganizationZone(end),
              let dayKey = CanonicalBusinessEngine.dayKeyInOrganizationZone(reference),
              let raw = CanonicalBusinessEngine.workStatusOn(
                isLive: isLive,
                startDayKey: startKey,
                endDayKey: endKey,
                dayKey: dayKey
              ),
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
