//
//  BookingDay.swift
//  Project Planner
//
//  RULEBOOK §1 "One business time zone": a booking's `date` is organisation-zone midnight of its day — the instant
//  every reader turns back into the same day key (`dayKeyInOrganizationZone`). A picker built on the phone's calendar
//  hands over the phone's midnight, which in a zone ahead of the organisation's is the day before there (launch data
//  audit #1). Uses `CanonicalBusinessEngine.organizationDayStart` (`organizationDayStartMs(dayKey, timeZone)`).
//

import Foundation

nonisolated enum BookingDay {
    /// Organisation-zone midnight for the day `date` was picked on:
    /// - already organisation-zone midnight: kept;
    /// - the phone's midnight (a picker on the phone calendar): that phone day, at organisation midnight;
    /// - any other instant: its day in the organisation zone.
    static func organizationMidnight(for date: Date, phoneCalendar: Calendar = .current) -> Date {
        let org = OrganizationRulebookContext.calendar
        if org.startOfDay(for: date) == date { return date }
        let key: String
        if phoneCalendar.startOfDay(for: date) == date {
            let parts = phoneCalendar.dateComponents([.year, .month, .day], from: date)
            key = String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
        } else {
            key = OrganizationRulebookContext.dayKey(date)
        }
        return CanonicalBusinessEngine.organizationDayStart(key)
            ?? OrganizationRulebookContext.date(fromDayKey: key)
            ?? org.startOfDay(for: date)
    }
}
