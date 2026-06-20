//
//  MondayFirstCalendarSupport.swift
//  Project Planner
//
//  Shared Mon-first calendar grid helpers for scheduling flows.
//

import Foundation

enum MondayFirstCalendarSupport {
    static let weekdayHeaders = ["M", "T", "W", "T", "F", "S", "S"]

    /// Inclusive date range covering full Mon–Sun weeks that contain `month`.
    static func gridRange(for month: Date, calendar: Calendar = .current) -> (start: Date, end: Date) {
        let monthStart = calendar.date(from: calendar.dateComponents([.year, .month], from: month))!
        let monthEnd = calendar.date(byAdding: DateComponents(month: 1, day: -1), to: monthStart)!
        let weekdayStart = calendar.component(.weekday, from: monthStart)
        let daysFromMonday = (weekdayStart + 5) % 7
        let startDate = calendar.date(byAdding: .day, value: -daysFromMonday, to: monthStart)!
        let weekdayEnd = calendar.component(.weekday, from: monthEnd)
        let daysToSunday = (8 - weekdayEnd) % 7
        let endDate = calendar.date(byAdding: .day, value: daysToSunday, to: monthEnd)!
        return (startDate, endDate)
    }

    static func days(from start: Date, through end: Date, calendar: Calendar = .current) -> [Date] {
        var days: [Date] = []
        var current = start
        while current <= end {
            days.append(current)
            guard let next = calendar.date(byAdding: .day, value: 1, to: current) else { break }
            current = next
        }
        return days
    }
}
