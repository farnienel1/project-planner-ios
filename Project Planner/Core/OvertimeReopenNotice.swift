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

    /// A labour booking changed (`after`) or deleted (`after` nil) on this phone. `organizationId` is the company the
    /// write went to (an outbox replay passes its entry's); nil means the open one (an online edit on screen).
    static func labour(before: Booking, after: Booking?, organizationId: String? = nil) {
        send(
            before: OvertimeBookingInputs.labour(before),
            after: after.map { OvertimeBookingInputs.labour($0) },
            organizationId: organizationId
        )
    }

    /// A manager site booking changed (`after`) or deleted (`after` nil) on this phone. `organizationId` as `labour`.
    static func managerSite(before: ManagerSiteBooking, after: ManagerSiteBooking?, organizationId: String? = nil) {
        send(
            before: OvertimeBookingInputs.managerSite(before),
            after: after.map { OvertimeBookingInputs.managerSite($0) },
            organizationId: organizationId
        )
    }

    /// Whether a notice about a write to `writtenOrganizationId` may be judged and sent now. The notice reads the open
    /// company's roster, jobs, organisation document and overtime records, so a write to another company (an outbox
    /// entry queued in company A replayed while company B is open) is never judged with B's data: it is skipped. Nil
    /// means the write went to the open company. Ids compare trimmed and without case (`organizationIdsMatch`).
    static func noticeMayBeSent(writtenOrganizationId: String?, openOrganizationId: String?) -> Bool {
        guard let writtenOrganizationId else { return true }
        return organizationIdsMatch(writtenOrganizationId, openOrganizationId)
    }

    private static func send(before: OvertimeBookingInput, after: OvertimeBookingInput?, organizationId: String?) {
        guard let service else { return }
        Task { @MainActor in
            await service.notifyOvertimeLineReopened(before: before, after: after, organizationId: organizationId)
        }
    }
}
