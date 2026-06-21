//
//  PayrollPolicyBookingRecalibrator.swift
//  Project Planner
//
//  Re-applies org working-hours rules to every booking on the day a policy change takes effect.
//

import Foundation

enum PayrollPolicyBookingRecalibrator {
    /// Updates all active operative + manager bookings on `effectiveDay` to match `newPolicy`.
    static func apply(
        effectiveDay: Date,
        priorPolicy: OrgPayrollTimePolicy,
        newPolicy: OrgPayrollTimePolicy,
        bookingStore: BookingStore,
        managerScheduleStore: ManagerScheduleStore
    ) async {
        let cal = Calendar.current
        let dayStart = cal.startOfDay(for: effectiveDay)
        var operativeUpdates = 0
        var managerUpdates = 0

        for booking in bookingStore.bookings {
            guard cal.isDate(booking.date, inSameDayAs: dayStart) else { continue }
            guard booking.status == .confirmed || booking.status == .tentative else { continue }
            let updated = recalibrateOperativeBooking(booking, priorPolicy: priorPolicy, newPolicy: newPolicy)
            guard updated != booking else { continue }
            await bookingStore.updateBooking(updated)
            operativeUpdates += 1
        }

        for booking in managerScheduleStore.managerSiteBookings {
            guard cal.isDate(booking.date, inSameDayAs: dayStart) else { continue }
            let updated = recalibrateManagerBooking(booking, newPolicy: newPolicy)
            guard updated != booking else { continue }
            await managerScheduleStore.saveBooking(updated)
            managerUpdates += 1
        }

        if operativeUpdates > 0 {
            ScheduleChangeNotifier.postBookingStoreDidChange()
        }
        if managerUpdates > 0 {
            NotificationCenter.default.post(name: Notification.Name("managerScheduleDidChange"), object: nil)
        }
    }

    static func recalibrateOperativeBooking(
        _ booking: Booking,
        priorPolicy: OrgPayrollTimePolicy,
        newPolicy: OrgPayrollTimePolicy
    ) -> Booking {
        var updated = booking
        let choice = recalibratedOperativeChoice(from: booking, newPolicy: newPolicy)
        updated.timeSlot = choice.timeSlot
        updated.workStartTime = choice.workStartTime
        updated.workEndTime = choice.workEndTime
        if PayrollTimePolicyCatalog.isWeekend(booking.date) {
            updated.isBreakRemoved = choice.isBreakRemoved
            updated.otMultiplierOverride = choice.otMultiplierOverride
        } else if let override = updated.otMultiplierOverride,
                  abs(override - priorPolicy.weekdayOutsideStandardMultiplier) < 0.001 {
            updated.otMultiplierOverride = nil
        }
        updated.updatedAt = Date()
        return updated
    }

    static func recalibrateManagerBooking(
        _ booking: ManagerSiteBooking,
        newPolicy: OrgPayrollTimePolicy
    ) -> ManagerSiteBooking {
        var updated = booking
        let choice = recalibratedManagerChoice(from: booking, newPolicy: newPolicy)
        updated.timeSlot = choice.timeSlot
        updated.workStartTime = choice.workStartTime
        updated.workEndTime = choice.workEndTime
        updated.isBreakRemoved = choice.isBreakRemoved
        updated.updatedAt = Date()
        return updated
    }

    static func recalibratedOperativeChoice(
        from booking: Booking,
        newPolicy: OrgPayrollTimePolicy
    ) -> OperativeDayBookingChoice {
        let day = booking.date
        if PayrollTimePolicyCatalog.isWeekend(day) {
            return PayrollTimePolicyCatalog.defaultWeekendBookingChoice(policy: newPolicy, day: day)
        }
        let timeline = PayrollTimePolicyCatalog.timelinePolicy(for: day, policy: newPolicy)
        let start = timeline.standardWindowStart ?? newPolicy.standardDayStart
        let end = timeline.standardWindowEnd ?? newPolicy.standardDayEnd
        guard let sMin = ManagerScheduleInterval.parseMinutes(start),
              let eMin = ManagerScheduleInterval.parseMinutes(end),
              eMin > sMin else {
            return OperativeDayBookingChoice(
                timeSlot: .customHours,
                workStartTime: start,
                workEndTime: end,
                isBreakRemoved: booking.isBreakRemoved,
                otMultiplierOverride: booking.otMultiplierOverride
            )
        }
        let breakRemoved = booking.isBreakRemoved && !newPolicy.breakPaid
        switch booking.timeSlot {
        case .fullDay, .customHours:
            return OperativeDayBookingChoice(
                timeSlot: .customHours,
                workStartTime: start,
                workEndTime: end,
                isBreakRemoved: breakRemoved,
                otMultiplierOverride: nil
            )
        case .morning:
            let mid = sMin + (eMin - sMin) / 2
            return OperativeDayBookingChoice(
                timeSlot: .morning,
                workStartTime: PayrollHoursEngine.formatMinutes(sMin),
                workEndTime: PayrollHoursEngine.formatMinutes(mid),
                isBreakRemoved: breakRemoved,
                otMultiplierOverride: nil
            )
        case .afternoon:
            let mid = sMin + (eMin - sMin) / 2
            return OperativeDayBookingChoice(
                timeSlot: .afternoon,
                workStartTime: PayrollHoursEngine.formatMinutes(mid),
                workEndTime: PayrollHoursEngine.formatMinutes(eMin),
                isBreakRemoved: breakRemoved,
                otMultiplierOverride: nil
            )
        case .evening:
            let endEvening = min(eMin + 240, 24 * 60)
            guard endEvening > eMin else {
                return OperativeDayBookingChoice(timeSlot: .evening, workStartTime: start, workEndTime: end, isBreakRemoved: breakRemoved, otMultiplierOverride: nil)
            }
            return OperativeDayBookingChoice(
                timeSlot: .evening,
                workStartTime: PayrollHoursEngine.formatMinutes(eMin),
                workEndTime: PayrollHoursEngine.formatMinutes(endEvening),
                isBreakRemoved: breakRemoved,
                otMultiplierOverride: nil
            )
        case .overtime:
            let startOT = min(eMin + 240, 24 * 60)
            let endOT = min(eMin + 360, 24 * 60)
            guard endOT > startOT else {
                return OperativeDayBookingChoice(timeSlot: .overtime, workStartTime: start, workEndTime: end, isBreakRemoved: breakRemoved, otMultiplierOverride: nil)
            }
            return OperativeDayBookingChoice(
                timeSlot: .overtime,
                workStartTime: PayrollHoursEngine.formatMinutes(startOT),
                workEndTime: PayrollHoursEngine.formatMinutes(endOT),
                isBreakRemoved: breakRemoved,
                otMultiplierOverride: nil
            )
        }
    }

    static func recalibratedManagerChoice(
        from booking: ManagerSiteBooking,
        newPolicy: OrgPayrollTimePolicy
    ) -> (timeSlot: ManagerTimeSlot, workStartTime: String?, workEndTime: String?, isBreakRemoved: Bool) {
        let day = booking.date
        if PayrollTimePolicyCatalog.isWeekend(day) {
            let weekend = PayrollTimePolicyCatalog.weekendSettings(for: day, policy: newPolicy)
            if weekend.allHoursAtMultiplierMode {
                return (
                    .customHours,
                    newPolicy.standardDayStart,
                    newPolicy.standardDayEnd,
                    true
                )
            }
            let start = weekend.customStandardStart ?? "07:30"
            let end = weekend.customStandardEnd ?? "13:00"
            return (.customHours, start, end, true)
        }
        let start = newPolicy.standardDayStart
        let end = newPolicy.standardDayEnd
        guard let sMin = ManagerScheduleInterval.parseMinutes(start),
              let eMin = ManagerScheduleInterval.parseMinutes(end),
              eMin > sMin else {
            return (.customHours, start, end, booking.isBreakRemoved)
        }
        let breakRemoved = booking.isBreakRemoved && !newPolicy.breakPaid
        switch booking.timeSlot {
        case .fullDay, .customHours:
            return (.customHours, start, end, breakRemoved)
        case .morning:
            let mid = sMin + (eMin - sMin) / 2
            return (.morning, PayrollHoursEngine.formatMinutes(sMin), PayrollHoursEngine.formatMinutes(mid), breakRemoved)
        case .afternoon:
            let mid = sMin + (eMin - sMin) / 2
            return (.afternoon, PayrollHoursEngine.formatMinutes(mid), PayrollHoursEngine.formatMinutes(eMin), breakRemoved)
        }
    }
}
