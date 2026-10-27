//
//  WarningsDataCompleteness.swift
//  Project Planner
//
//  Whether the booking data on this device is complete enough to scan. A failed read is not
//  "nobody is booked": the scan is skipped and the reason shown, so no false unbooked warning appears.
//

import Foundation

nonisolated enum WarningsDataCompleteness {
    /// Nil when the scan may run; otherwise the message the Warnings screen shows.
    static func blockingReason(
        bookingsLoadFailed: Bool,
        managerBookingsLoadFailed: Bool,
        bookingDecode: BookingDecodeReport?
    ) -> String? {
        if bookingDecode?.scriptFailed == true {
            return "Bookings could not be read on this device, so warnings were not checked. Pull to refresh."
        }
        if bookingsLoadFailed {
            return "Bookings could not be loaded, so warnings were not checked. Check your connection and pull to refresh."
        }
        if managerBookingsLoadFailed {
            return "Manager schedules could not be loaded, so warnings were not checked. Check your connection and pull to refresh."
        }
        return nil
    }
}
