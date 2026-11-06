//
//  OvertimeReopenNotice.swift
//  Project Planner
//
//  RULEBOOK 1.33.0 §25 (owner 6 Nov, reopen), the iOS counterpart of web `lib/overtime/overtimeReopenNotice.ts` and its
//  callers in `bookingStore.ts` / `managerScheduleStore.ts`: after a labour or manager site booking is changed or deleted
//  on this phone, the PAYE overtime line it carried reopens and the person (and their line manager when the line had been
//  returned) is told. The rules are `overtimeLineReopened`, `overtimeReopenedRecipients` and `overtimeReopenedMessage`
//  (`NotificationService.notifyOvertimeLineReopened`); this file only turns the store rows into the rulebook's booking
//  inputs and sends the notice after the write. Best effort: it never blocks or undoes the booking edit.
//

import Foundation

@MainActor
enum OvertimeReopenNotice {
    /// The app's notification service (set by `NotificationService.setUserStore`).
    static weak var service: NotificationService?

    /// A labour booking changed (`after`) or deleted (`after` nil) on this phone.
    static func labour(before: Booking, after: Booking?) {
        send(before: OvertimeBookingInputs.labour(before), after: after.map { OvertimeBookingInputs.labour($0) })
    }

    /// A manager site booking changed (`after`) or deleted (`after` nil) on this phone.
    static func managerSite(before: ManagerSiteBooking, after: ManagerSiteBooking?) {
        send(before: OvertimeBookingInputs.managerSite(before), after: after.map { OvertimeBookingInputs.managerSite($0) })
    }

    private static func send(before: OvertimeBookingInput, after: OvertimeBookingInput?) {
        guard let service else { return }
        Task { @MainActor in
            await service.notifyOvertimeLineReopened(before: before, after: after)
        }
    }
}
