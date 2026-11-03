//
//  Rulebook+BookingSlots.swift
//  Project Planner
//
//  Typed wrappers for the booking slot rules of rulebook 1.13.0 / 1.13.1 (docs/RULEBOOK.md §4.3, §5, §8; web
//  `lib/canonical/bookingSlots.ts`): Saturday and Sunday are custom hours only (`allowedTimeSlotsOnDay`,
//  `timeSlotAllowedOnDay`), the editor's weekend prefill (`weekendCustomHoursDefault`), the weekend note
//  (`weekendBookingNote`), the weekday + weekend mix refusal (`bookingDaysMixWeekdayAndWeekend`,
//  `WEEKEND_WEEKDAY_MIX_MESSAGE`) and the custom-hours lunch confirm (`customHoursBreakWarning`,
//  `CUSTOM_HOURS_BREAK_WARNING`). Every answer comes from the packed script; this file only maps Swift values to its
//  inputs (a `Date` to an organisation-zone day key, `OrgPayrollTimePolicy` to the script's field names).
//
//  Overnight bookings (1.13.0 Q5): `slotInterval`, the clash groups and `overlappingBookingIds` carry a booking whose
//  finish is before its start into the next morning (`overnightCarryInterval`). Swift passes the stored clock times
//  unchanged to those functions and never reorders or clamps them.
//

import Foundation
import SwiftUI

/// A slot a booking picker can offer: the rulebook's `BookingSlotChoice` names.
nonisolated enum RulebookBookingSlot: String, CaseIterable, Sendable {
    case fullDay = "FULL DAY"
    case am = "AM"
    case pm = "PM"
    case custom = "CUSTOM"
}

extension CanonicalBusinessEngine {
    // The policy JSON is `payrollPolicyJSON` (Rulebook+OrganisationSettings.swift, `parsePayrollPolicy`).

    /// The booking day as an organisation-zone `YYYY-MM-DD` key.
    nonisolated static func bookingDayKey(_ date: Date) -> String {
        OrganizationRulebookContext.dayKey(date)
    }

    /// `allowedTimeSlotsOnDay(dayKey, policy, timeZone)`: FULL DAY, AM, PM and CUSTOM on a weekday; CUSTOM only on
    /// Saturday and Sunday. When the script does not answer every slot is offered (the rules still check the save).
    nonisolated static func allowedTimeSlotsOnDay(_ dayKey: String, timeZone: String = OrganizationRulebookContext.timeZoneIdentifier) -> [RulebookBookingSlot] {
        guard let rows = callJSON("allowedTimeSlotsOnDay", arguments: [dayKey, NSNull(), timeZone]) as? [String] else {
            return RulebookBookingSlot.allCases
        }
        return rows.compactMap(RulebookBookingSlot.init(rawValue:))
    }

    /// `allowedTimeSlotsOnDay` for a booking date.
    nonisolated static func allowedTimeSlots(on date: Date) -> [RulebookBookingSlot] {
        allowedTimeSlotsOnDay(bookingDayKey(date))
    }

    /// Whether a picker offers `slot` on `date`: `allowedTimeSlotsOnDay`, or the slot the booking already stores (a
    /// stored weekend FULL DAY / AM / PM displays and edits as stored, never rewritten).
    nonisolated static func slotOffered(_ slot: RulebookBookingSlot, on date: Date, storedTimeSlot: String? = nil) -> Bool {
        if let storedTimeSlot, slot == rulebookSlot(storedTimeSlot) { return true }
        return allowedTimeSlots(on: date).contains(slot)
    }

    /// The picker slot a stored `timeSlot` reads as (`namedSlotKind`). Nil for evening / overtime / unknown.
    nonisolated static func rulebookSlot(_ storedTimeSlot: String) -> RulebookBookingSlot? {
        switch namedSlotKind(storedTimeSlot) {
        case "FULL_DAY": return .fullDay
        case "AM": return .am
        case "PM": return .pm
        case "CUSTOM": return .custom
        default: return nil
        }
    }

    /// `timeSlotAllowedOnDay(timeSlot, dayKey, timeZone)`: false for a new weekend FULL DAY / AM / PM. True when the
    /// script did not answer.
    nonisolated static func timeSlotAllowedOnDay(_ timeSlot: String, dayKey: String, timeZone: String = OrganizationRulebookContext.timeZoneIdentifier) -> Bool {
        callJSON("timeSlotAllowedOnDay", arguments: [timeSlot, dayKey, timeZone]) as? Bool ?? true
    }

    /// `weekendCustomHoursDefault(policy, dayKey, timeZone)`: a set-window Saturday or Sunday's window as the custom
    /// hours prefill (`start`, `end` "HH:mm"). Nil on a weekday, an all-hours weekend day, or no answer.
    nonisolated static func weekendCustomHoursDefault(policy: OrgPayrollTimePolicy, dayKey: String, timeZone: String = OrganizationRulebookContext.timeZoneIdentifier) -> (start: String, end: String)? {
        guard let policyJSON = payrollPolicyJSON(policy),
              let row = callJSON("weekendCustomHoursDefault", arguments: [policyJSON, dayKey, timeZone]) as? [String: Any],
              let start = row["start"] as? String, let end = row["end"] as? String else { return nil }
        return (start, end)
    }

    /// The custom-hours editor's starting times for `date` (web `customHoursPrefillForDate`): the weekend window from
    /// `weekendCustomHoursDefault`, else the organisation's standard day. A prefill only.
    nonisolated static func customHoursPrefill(on date: Date, policy: OrgPayrollTimePolicy) -> (start: String, end: String) {
        weekendCustomHoursDefault(policy: policy, dayKey: bookingDayKey(date))
            ?? (policy.standardDayStart, policy.standardDayEnd)
    }

    /// `weekendBookingNote(policy, dayKey, timeZone)`: how a Saturday or Sunday is paid. Nil on a weekday or no answer.
    nonisolated static func weekendBookingNote(policy: OrgPayrollTimePolicy, dayKey: String, timeZone: String = OrganizationRulebookContext.timeZoneIdentifier) -> String? {
        guard let policyJSON = payrollPolicyJSON(policy) else { return nil }
        return callJSON("weekendBookingNote", arguments: [policyJSON, dayKey, timeZone]) as? String
    }

    /// `weekendBookingNote` for a booking date.
    nonisolated static func weekendBookingNote(on date: Date, policy: OrgPayrollTimePolicy) -> String? {
        weekendBookingNote(policy: policy, dayKey: bookingDayKey(date))
    }

    /// `WEEKEND_WEEKDAY_MIX_MESSAGE` (the iOS wording web adopted).
    nonisolated static var weekendWeekdayMixMessage: String {
        constant("WEEKEND_WEEKDAY_MIX_MESSAGE", as: String.self)
            ?? "Weekends cannot be booked alongside Weekdays. Make your weekday booking first then weekend separately."
    }

    /// `bookingDaysMixWeekdayAndWeekend(dayKeys, timeZone)`: one request never mixes weekdays and weekend days.
    /// False when the script did not answer.
    nonisolated static func bookingDaysMixWeekdayAndWeekend(_ dayKeys: [String], timeZone: String = OrganizationRulebookContext.timeZoneIdentifier) -> Bool {
        callJSON("bookingDaysMixWeekdayAndWeekend", arguments: [dayKeys, timeZone]) as? Bool ?? false
    }

    /// `WEEKEND_WEEKDAY_MIX_MESSAGE` when `dates` mix weekdays and weekend days, else nil.
    nonisolated static func weekendWeekdayMixRefusal(for dates: [Date], calendar: Calendar = OrganizationRulebookContext.calendar) -> String? {
        let keys = dates.map { dayKey(for: $0, calendar: calendar) }
        return bookingDaysMixWeekdayAndWeekend(keys) ? weekendWeekdayMixMessage : nil
    }

    /// `customHoursBreakWarning(policy, dayKey, booking, timeZone)`: `CUSTOM_HOURS_BREAK_WARNING` when custom hours
    /// cover the unpaid break while the booking's Unpaid break is on, else nil. A confirm step only; pay is unchanged.
    nonisolated static func customHoursBreakWarning(
        policy: OrgPayrollTimePolicy,
        dayKey: String,
        workStartTime: String,
        workEndTime: String,
        isBreakRemoved: Bool,
        timeZone: String = OrganizationRulebookContext.timeZoneIdentifier
    ) -> String? {
        guard let policyJSON = payrollPolicyJSON(policy) else { return nil }
        let booking: [String: Any] = [
            "timeSlot": "CUSTOM_HOURS",
            "workStartTime": workStartTime,
            "workEndTime": workEndTime,
            "isBreakRemoved": isBreakRemoved,
        ]
        return callJSON("customHoursBreakWarning", arguments: [policyJSON, dayKey, booking, timeZone]) as? String
    }

    /// `customHoursBreakWarning` for a booking date.
    nonisolated static func customHoursBreakWarning(
        on date: Date,
        policy: OrgPayrollTimePolicy,
        workStartTime: String,
        workEndTime: String,
        isBreakRemoved: Bool
    ) -> String? {
        customHoursBreakWarning(
            policy: policy,
            dayKey: bookingDayKey(date),
            workStartTime: workStartTime,
            workEndTime: workEndTime,
            isBreakRemoved: isBreakRemoved
        )
    }
}

extension OperativeDayBookingChoice {
    /// RULEBOOK 1.13.1 §4.3: a new Saturday or Sunday booking is custom hours, prefilled with that day's window
    /// (`weekendCustomHoursDefault`), else the standard day. The break flag is what the weekend editor always started
    /// with on iOS (removed); pay comes from `payrollHoursResult` at the weekend rule either way.
    static func weekendCustomHours(on day: Date, policy: OrgPayrollTimePolicy) -> OperativeDayBookingChoice {
        let prefill = CanonicalBusinessEngine.customHoursPrefill(on: day, policy: policy)
        return OperativeDayBookingChoice(
            timeSlot: .customHours,
            workStartTime: prefill.start,
            workEndTime: prefill.end,
            isBreakRemoved: true,
            otMultiplierOverride: nil
        )
    }
}

/// The weekend note under a booking picker (`weekendBookingNote`). Nothing on a weekday.
struct WeekendBookingNoteView: View {
    let day: Date
    let policy: OrgPayrollTimePolicy

    var body: some View {
        if let note = CanonicalBusinessEngine.weekendBookingNote(on: day, policy: policy) {
            Label(note, systemImage: "calendar.badge.clock")
                .font(.system(size: 11))
                .foregroundStyle(ProjectWorksRevampColors.muted)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityIdentifier("booking.weekendNote")
        }
    }
}

extension ManagerTimeSlot {
    /// The rulebook slot name of this picker slot.
    var rulebookSlot: RulebookBookingSlot {
        switch self {
        case .fullDay: return .fullDay
        case .morning: return .am
        case .afternoon: return .pm
        case .customHours: return .custom
        }
    }

    /// `allowedTimeSlotsOnDay` on every one of `days`: what a picker for those days offers (custom only once a
    /// Saturday or Sunday is in the request).
    static func offered(on days: [Date]) -> [ManagerTimeSlot] {
        allCases.filter { slot in
            days.allSatisfy { CanonicalBusinessEngine.allowedTimeSlots(on: $0).contains(slot.rulebookSlot) }
        }
    }
}

extension TimeSlot {
    /// The slot a new booking on `date` starts on: FULL DAY on a weekday, custom hours on Saturday and Sunday
    /// (`allowedTimeSlotsOnDay`).
    static func defaultPickerSlot(on date: Date) -> TimeSlot {
        CanonicalBusinessEngine.allowedTimeSlots(on: date).contains(.fullDay) ? .fullDay : .customHours
    }

    /// The rulebook slot name of this picker slot; nil for evening / overtime.
    var rulebookSlot: RulebookBookingSlot? {
        switch self {
        case .fullDay: return .fullDay
        case .morning: return .am
        case .afternoon: return .pm
        case .customHours: return .custom
        case .evening, .overtime: return nil
        }
    }
}
