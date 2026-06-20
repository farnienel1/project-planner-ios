//
//  AnnualLeaveCalendarRules.swift
//  Project Planner
//

import Foundation

enum AnnualLeaveDayBlockReason: Equatable {
    case weekend
    case bankHoliday(name: String)
}

enum AnnualLeaveCalendarRules {
    static func isWeekend(_ date: Date, calendar: Calendar = .current) -> Bool {
        let weekday = calendar.component(.weekday, from: date)
        return weekday == 1 || weekday == 7 // Sunday = 1, Saturday = 7
    }

    static func blockReason(
        for date: Date,
        bankHolidays: [String: BankHolidayDay],
        calendar: Calendar = .current
    ) -> AnnualLeaveDayBlockReason? {
        let day = calendar.startOfDay(for: date)
        if isWeekend(day, calendar: calendar) { return .weekend }
        if let holiday = bankHolidays[BankHolidayDay.dayKey(for: day)] {
            return .bankHoliday(name: holiday.name)
        }
        return nil
    }

    static func bookingContainsWeekend(_ booking: HolidayBooking, calendar: Calendar = .current) -> Bool {
        var day = calendar.startOfDay(for: booking.startDate)
        let end = calendar.startOfDay(for: booking.endDate)
        while day <= end {
            if isWeekend(day, calendar: calendar) { return true }
            guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
            day = next
        }
        return false
    }

    static func bookingContainsBankHoliday(
        _ booking: HolidayBooking,
        bankHolidays: [String: BankHolidayDay],
        calendar: Calendar = .current
    ) -> Bool {
        var day = calendar.startOfDay(for: booking.startDate)
        let end = calendar.startOfDay(for: booking.endDate)
        while day <= end {
            if bankHolidays[BankHolidayDay.dayKey(for: day)] != nil { return true }
            guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
            day = next
        }
        return false
    }
}

enum AnnualLeaveSelfBookPolicy {
    static func canSelfBookAnnualLeave(for user: AppUser) -> Bool {
        if user.permissions.operativeMode { return false }
        if user.hasNoLineManager { return true }
        return user.permissions.annualLeaveSelfBook
    }

    static func usesAnnualLeaveRequestFlow(for user: AppUser) -> Bool {
        if user.permissions.operativeMode { return true }
        if user.hasNoLineManager { return false }
        if user.permissions.manager || user.permissions.adminAccess {
            return !user.permissions.annualLeaveSelfBook
        }
        return false
    }

    static func requiresLineManagerForAnnualLeaveRouting(for user: AppUser) -> Bool {
        if user.permissions.operativeMode { return true }
        if user.hasNoLineManager { return false }
        if user.permissions.manager || user.permissions.adminAccess {
            return !user.permissions.annualLeaveSelfBook
        }
        return false
    }
}
