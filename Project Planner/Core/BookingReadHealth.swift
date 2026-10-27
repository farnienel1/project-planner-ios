//
//  BookingReadHealth.swift
//  Project Planner
//
//  How complete the last booking read was, and the listener-failure signal. The warning scan uses
//  these to show an error instead of treating missing bookings as unbooked (`WarningsDataCompleteness`).
//

import Foundation

/// What the last booking read did with each document. `refused > 0` means some stored bookings are
/// not on screen, so coverage results from that read are incomplete.
nonisolated struct BookingDecodeReport: Equatable, Sendable {
    let total: Int
    let refused: Int
    let repaired: Int
    /// The canonical script did not run, so nothing was read.
    let scriptFailed: Bool
}

extension Notification.Name {
    /// The live bookings listener reported an error; on-screen bookings may be stale.
    static let bookingsListenerFailed = Notification.Name("bookingsListenerFailed")
}
