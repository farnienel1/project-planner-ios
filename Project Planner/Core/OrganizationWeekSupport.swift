//
//  OrganizationWeekSupport.swift
//  Project Planner
//
//  RULEBOOK §1 ("The week starts on Monday", "One business time zone per organisation"), §21 ("Both apps bucket the
//  grid's days by the calendar date of each column") and guardrail 2 (owner decision 17 Nov, follow-up FU-4): the
//  Scheduling week grid and the week screens (My Schedule, Daily Overview edit sheet, Quick Add) read the
//  organisation's Monday–Sunday week from the rulebook (`organizationWeekDayKeys`) and work in organisation-zone day
//  keys. Each column is the organisation-zone midnight of its day key; display text is formatted in the organisation
//  zone. Never the phone's `Calendar.current` / `TimeZone.current`: a phone abroad, or near midnight, must show the
//  same days as web.
//

import Foundation

nonisolated enum OrganizationWeekSupport {
    /// Gregorian, Monday-first calendar in `timeZone` (the organisation zone by default).
    static func calendar(timeZone: String = OrganizationRulebookContext.timeZoneIdentifier) -> Calendar {
        guard timeZone != OrganizationRulebookContext.timeZoneIdentifier else { return OrganizationRulebookContext.calendar }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: timeZone) ?? OrganizationRulebookContext.timeZone
        calendar.locale = Locale(identifier: "en_GB")
        calendar.firstWeekday = 2
        calendar.minimumDaysInFirstWeek = 4
        return calendar
    }

    /// `YYYY-MM-DD` of `date` in the organisation zone (the key `dayKeyInOrganizationZone` returns; the parity test
    /// `OrganizationWeekSupportTests` locks the two together). Worked out in Swift because a grid body asks per cell.
    static func dayKey(_ date: Date, timeZone: String = OrganizationRulebookContext.timeZoneIdentifier) -> String {
        let parts = calendar(timeZone: timeZone).dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    /// Organisation-zone midnight of a `YYYY-MM-DD` key (`dateFromDayKeyInZone`).
    static func midnight(dayKey: String, timeZone: String = OrganizationRulebookContext.timeZoneIdentifier) -> Date? {
        let parts = dayKey.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        var components = DateComponents()
        components.year = parts[0]
        components.month = parts[1]
        components.day = parts[2]
        return calendar(timeZone: timeZone).date(from: components)
    }

    nonisolated private static let weekMemo = RulebookAnswerMemo<String, [String]>(limit: 512)

    /// RULEBOOK 1.35.0 `organizationWeekDayKeys(dayKey, timeZone).dayKeys`: the seven day keys, Monday to Sunday, of
    /// the organisation week containing `date`. When the script does not answer, the same week from the
    /// organisation calendar (Monday-first, organisation zone) — never the phone's.
    static func weekDayKeys(containing date: Date, timeZone: String = OrganizationRulebookContext.timeZoneIdentifier) -> [String] {
        let key = dayKey(date, timeZone: timeZone)
        if let keys = weekMemo.value(for: "\(key)|\(timeZone)", compute: {
            guard let week = CanonicalBusinessEngine.callJSON("organizationWeekDayKeys", arguments: [key, timeZone]) as? [String: Any],
                  let keys = week["dayKeys"] as? [String], keys.count == 7 else { return nil }
            return keys
        }) {
            return keys
        }
        let cal = calendar(timeZone: timeZone)
        guard let day = midnight(dayKey: key, timeZone: timeZone) else { return [] }
        let isoWeekday = (cal.component(.weekday, from: day) + 5) % 7 + 1 // Monday 1 … Sunday 7
        guard let monday = cal.date(byAdding: .day, value: -(isoWeekday - 1), to: day) else { return [] }
        return (0..<7).compactMap { cal.date(byAdding: .day, value: $0, to: monday) }.map { dayKey($0, timeZone: timeZone) }
    }

    /// The week's columns: organisation-zone midnight of each day key, Monday to Sunday.
    static func weekDays(containing date: Date, timeZone: String = OrganizationRulebookContext.timeZoneIdentifier) -> [Date] {
        weekDayKeys(containing: date, timeZone: timeZone).compactMap { midnight(dayKey: $0, timeZone: timeZone) }
    }

    /// Organisation-zone midnight of the Monday of the week containing `date`.
    static func weekStart(containing date: Date, timeZone: String = OrganizationRulebookContext.timeZoneIdentifier) -> Date {
        weekDays(containing: date, timeZone: timeZone).first ?? date
    }

    /// The Monday of the week `weeks` weeks before (negative) or after the week containing `date`.
    static func shiftedWeekStart(from date: Date, by weeks: Int, timeZone: String = OrganizationRulebookContext.timeZoneIdentifier) -> Date {
        let start = weekStart(containing: date, timeZone: timeZone)
        let cal = calendar(timeZone: timeZone)
        guard let moved = cal.date(byAdding: .day, value: 7 * weeks, to: start) else { return start }
        return weekStart(containing: moved, timeZone: timeZone)
    }

    /// `date` falls on today's organisation day.
    static func isToday(_ date: Date, now: Date = Date(), timeZone: String = OrganizationRulebookContext.timeZoneIdentifier) -> Bool {
        dayKey(date, timeZone: timeZone) == dayKey(now, timeZone: timeZone)
    }

    /// `date` falls in the organisation week containing `now`.
    static func isThisWeek(_ date: Date, now: Date = Date(), timeZone: String = OrganizationRulebookContext.timeZoneIdentifier) -> Bool {
        weekDayKeys(containing: now, timeZone: timeZone).contains(dayKey(date, timeZone: timeZone))
    }

    /// Whole organisation days from today to `date` (negative once it has passed); 0 on the same organisation day.
    static func daysFromToday(to date: Date, now: Date = Date(), timeZone: String = OrganizationRulebookContext.timeZoneIdentifier) -> Int {
        guard let today = midnight(dayKey: dayKey(now, timeZone: timeZone), timeZone: timeZone),
              let target = midnight(dayKey: dayKey(date, timeZone: timeZone), timeZone: timeZone) else { return 0 }
        return calendar(timeZone: timeZone).dateComponents([.day], from: today, to: target).day ?? 0
    }

    /// The instant showing `minutes` past midnight on the organisation's wall clock on `day`'s organisation day. The
    /// hour and minute are set, never added to midnight as elapsed time, so the clock-change Sundays (23 and 25 hours
    /// long) read right. Minutes of 24:00 or later (an overnight booking's finish, e.g. 22:00–06:00 is 1320–1800) fall on
    /// the next organisation day at that day's wall clock.
    static func wallClock(minutes: Int, on day: Date, timeZone: String = OrganizationRulebookContext.timeZoneIdentifier) -> Date {
        let cal = calendar(timeZone: timeZone)
        let clamped = max(0, minutes)
        var base = cal.startOfDay(for: day)
        let extraDays = clamped / (24 * 60)
        if extraDays > 0, let next = cal.date(byAdding: .day, value: extraDays, to: base) {
            base = cal.startOfDay(for: next)
        }
        let within = clamped % (24 * 60)
        return cal.date(bySettingHour: within / 60, minute: within % 60, second: 0, of: base)
            ?? cal.date(byAdding: .minute, value: clamped, to: cal.startOfDay(for: day))
            ?? base
    }

    private static let formatterLock = NSLock()
    nonisolated(unsafe) private static var formatterCache: [String: DateFormatter] = [:]

    /// A `DateFormatter` that writes `format` in the organisation zone (display only), cached per zone, format and
    /// locale. Shared: callers only read from it (`string(from:)`, thread-safe since iOS 7), never change it.
    static func formatter(_ format: String, timeZone: String = OrganizationRulebookContext.timeZoneIdentifier) -> DateFormatter {
        let locale = Locale.current
        let key = "\(timeZone)|\(format)|\(locale.identifier)"
        formatterLock.lock()
        defer { formatterLock.unlock() }
        if let cached = formatterCache[key] { return cached }
        let f = DateFormatter()
        f.locale = locale
        f.timeZone = TimeZone(identifier: timeZone) ?? OrganizationRulebookContext.timeZone
        f.dateFormat = format
        if formatterCache.count >= 256 { formatterCache.removeAll() }
        formatterCache[key] = f
        return f
    }

    /// `date` written as `format` in the organisation zone (display only).
    static func text(_ date: Date, format: String, timeZone: String = OrganizationRulebookContext.timeZoneIdentifier) -> String {
        formatter(format, timeZone: timeZone).string(from: date)
    }
}
