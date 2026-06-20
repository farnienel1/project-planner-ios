//
//  ScheduleDateSelectionPolicy.swift
//  Project Planner
//
//  Weekday/weekend separation, quick-select skipping weekends, and Sat/Sun batch rules.
//

import Foundation

enum ScheduleDateSelectionPolicy {
    static let weekdayWeekendMixMessage =
        "Weekends cannot be booked alongside Weekdays. Make your weekday booking first then weekend separately."

    static let saturdaySundayMismatchMessage =
        "Book Saturday and Sunday separately, or align them in Organisation settings → Working hours."

    /// Toggle a date in `selected`. Returns a user-facing alert when the new day cannot be added.
    @discardableResult
    static func toggle(
        date: Date,
        selected: inout Set<Date>,
        policy: OrgPayrollTimePolicy,
        calendar: Calendar = .current
    ) -> String? {
        let normalized = calendar.startOfDay(for: date)
        if selected.contains(normalized) {
            selected.remove(normalized)
            return nil
        }

        let addingWeekend = PayrollTimePolicyCatalog.isWeekend(normalized, calendar: calendar)
        let hasWeekday = selected.contains { PayrollTimePolicyCatalog.isWeekday($0, calendar: calendar) }
        let hasWeekend = selected.contains { PayrollTimePolicyCatalog.isWeekend($0, calendar: calendar) }

        if addingWeekend && hasWeekday {
            return weekdayWeekendMixMessage
        }
        if !addingWeekend && hasWeekend {
            return weekdayWeekendMixMessage
        }
        if addingWeekend && !canAddWeekendDay(normalized, to: selected, policy: policy, calendar: calendar) {
            return saturdaySundayMismatchMessage
        }

        selected.insert(normalized)
        return nil
    }

    /// Quick-select N days, skipping Saturdays and Sundays.
    static func quickSelect(
        count: Int,
        into selected: inout Set<Date>,
        startingFrom anchor: Date = Date(),
        calendar: Calendar = .current
    ) {
        selected.removeAll()
        var cursor = calendar.startOfDay(for: anchor)
        while selected.count < count {
            if PayrollTimePolicyCatalog.isWeekday(cursor, calendar: calendar) {
                selected.insert(cursor)
            }
            guard let next = calendar.date(byAdding: .day, value: 1, to: cursor) else { break }
            cursor = next
        }
    }

    /// Returns `false` when Sat+Sun are both selected but org rules do not match.
    static func saturdaySundaySelectionAllowed(
        selected: Set<Date>,
        policy: OrgPayrollTimePolicy,
        calendar: Calendar = .current
    ) -> Bool {
        let hasSat = selected.contains { calendar.component(.weekday, from: $0) == 7 }
        let hasSun = selected.contains { calendar.component(.weekday, from: $0) == 1 }
        guard hasSat && hasSun else { return true }
        return PayrollTimePolicyCatalog.saturdayAndSundayMatch(in: policy)
    }

    /// Block adding a weekend day when the other weekend day is already selected and rules differ.
    static func canAddWeekendDay(
        _ date: Date,
        to selected: Set<Date>,
        policy: OrgPayrollTimePolicy,
        calendar: Calendar = .current
    ) -> Bool {
        guard PayrollTimePolicyCatalog.isWeekend(date, calendar: calendar) else { return true }
        let wd = calendar.component(.weekday, from: date)
        let otherSelected: Bool
        if wd == 7 {
            otherSelected = selected.contains { calendar.component(.weekday, from: $0) == 1 }
        } else {
            otherSelected = selected.contains { calendar.component(.weekday, from: $0) == 7 }
        }
        guard otherSelected else { return true }
        return PayrollTimePolicyCatalog.saturdayAndSundayMatch(in: policy)
    }
}
