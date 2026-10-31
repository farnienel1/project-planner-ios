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
    static func isWeekend(_ date: Date, calendar: Calendar = OrganizationRulebookContext.calendar) -> Bool {
        let weekday = calendar.component(.weekday, from: date)
        return weekday == 1 || weekday == 7 // Sunday = 1, Saturday = 7
    }

    static func blockReason(
        for date: Date,
        bankHolidays: [String: BankHolidayDay],
        calendar: Calendar = OrganizationRulebookContext.calendar
    ) -> AnnualLeaveDayBlockReason? {
        let day = calendar.startOfDay(for: date)
        if let holiday = bankHolidays[BankHolidayDay.dayKey(for: day, calendar: calendar)] {
            return .bankHoliday(name: holiday.name)
        }
        if isWeekend(day, calendar: calendar) { return .weekend }
        return nil
    }

    static func bookingContainsWeekend(_ booking: HolidayBooking, calendar: Calendar = OrganizationRulebookContext.calendar) -> Bool {
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
        calendar: Calendar = OrganizationRulebookContext.calendar
    ) -> Bool {
        var day = calendar.startOfDay(for: booking.startDate)
        let end = calendar.startOfDay(for: booking.endDate)
        while day <= end {
            if bankHolidays[BankHolidayDay.dayKey(for: day, calendar: calendar)] != nil { return true }
            guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
            day = next
        }
        return false
    }
}

enum AnnualLeaveSelfBookPolicy {
    /// User decision D5: own leave is booked approved only with the `annualLeaveSelfBook` permission and
    /// not in operative mode. Everyone else sends a pending request to `leaveApproverIds` (line managers,
    /// else the company admins). RULEBOOK-GAP(canSelfBookAnnualLeave): replace with the canonical export
    /// when web ships it.
    static func canSelfBookAnnualLeave(for user: AppUser) -> Bool {
        if user.permissions.operativeMode { return false }
        return user.permissions.annualLeaveSelfBook
    }

    /// Own leave is a pending request (D5): the opposite of self-booking.
    static func usesAnnualLeaveRequestFlow(for user: AppUser) -> Bool {
        !canSelfBookAnnualLeave(for: user)
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
