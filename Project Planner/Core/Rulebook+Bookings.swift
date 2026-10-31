//
//  Rulebook+Bookings.swift
//  Project Planner
//
//  Typed wrappers for the booking tombstone and offline-replay rules (docs/RULEBOOK.md §2, §16).
//  Every answer comes from the packed script (web lib/canonical/bookingTombstones.ts).
//

import Foundation

extension CanonicalBusinessEngine {
    /// `bookingTombstonePath(organizationId, bookingId)`: `organizations/{orgId}/deletedBookings/{bookingId}`.
    /// Nil when either id is blank or contains a slash, or the script did not answer.
    nonisolated static func bookingTombstonePath(organizationId: String, bookingId: String) -> String? {
        callJSON("bookingTombstonePath", arguments: [organizationId, bookingId]) as? String
    }

    /// `bookingTombstoneWriteFields({ bookingId, collection, deletedBy, deletedFrom })`:
    /// `bookingId`, `collection`, `deletedBy`, `deletedFrom`. The caller adds `deletedAt` as the SDK
    /// server timestamp. Nil when any input is unusable (blank uid, unknown collection).
    nonisolated static func bookingTombstoneWriteFields(
        bookingId: String,
        collection: String,
        deletedBy: String,
        deletedFrom: String = "ios"
    ) -> [String: Any]? {
        let input: [String: Any] = [
            "bookingId": bookingId,
            "collection": collection,
            "deletedBy": deletedBy,
            "deletedFrom": deletedFrom
        ]
        return callJSON("bookingTombstoneWriteFields", arguments: [input]) as? [String: Any]
    }

    /// `bookingReplayRefusedIsFinal(errorCode)`: true for permission-denied (`7` on iOS).
    nonisolated static func bookingReplayRefusedIsFinal(errorCode: Int) -> Bool {
        callJSON("bookingReplayRefusedIsFinal", arguments: [errorCode]) as? Bool ?? false
    }

    /// `BOOKING_REPLAY_REFUSED_MESSAGE`.
    nonisolated static var bookingReplayRefusedMessage: String {
        constant("BOOKING_REPLAY_REFUSED_MESSAGE", as: String.self)
            ?? "This booking was cancelled or deleted on another device."
    }
}
