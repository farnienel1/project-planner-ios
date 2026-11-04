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
    /// `canSelfBookAnnualLeave(user, roster)` (§9, RULEBOOK 1.28.0): own leave is booked approved with Annual Leave
    /// Management (`annualLeaveSelfBook`) outside operative mode, or as the organisation's Super Admin. Having no line
    /// manager does not self-book anyone. Everyone else sends a pending request to `leaveApproverIds`.
    /// `users` is the organisation roster (`UserStore.organizationUsers`).
    static func canSelfBookAnnualLeave(for user: AppUser, users: [AppUser]) -> Bool {
        CanonicalBusinessEngine.canSelfBookAnnualLeave(
            user: RulebookPeople.person(user),
            roster: RulebookPeople.roster(users)
        ) ?? false
    }

    /// Own leave is a pending request: the opposite of self-booking.
    static func usesAnnualLeaveRequestFlow(for user: AppUser, users: [AppUser]) -> Bool {
        !canSelfBookAnnualLeave(for: user, users: users)
    }
}
