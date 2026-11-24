//
//  Rulebook+OfflineReplace.swift
//  Project Planner
//
//  RULEBOOK 1.86.0 §2 / §5 (owner decision 24 Nov, "Replace works offline, is queued, and is applied when signal
//  returns"; web `lib/canonical/offlineReplace.ts`). Replace on an orange double-booking row is `allowedOffline`
//  (`booking.replace`): the new booking and each replaced booking's delete with its tombstone are queued as ONE outbox
//  item, and the replay asks `offlineReplaceReplayDecision` (in a transaction) and reads a server refusal with
//  `offlineReplaceRefusalDecision`. Swift only maps inputs and carries out the script's answer.
//

import Foundation

/// The script's answer for a queued Replace: the overall decision, the replaced bookings to delete (stored spelling),
/// and the message for a refusal.
nonisolated struct RulebookOfflineReplaceResult: Equatable, Sendable {
    let decision: String
    let deletes: [RulebookBookingReplaceRef]
    let message: String?

    /// Fail closed: nothing is written when the script did not answer, and the item stays queued (retried), never
    /// removed with a refusal message (review of #293).
    static let unanswered = RulebookOfflineReplaceResult(decision: "unanswered", deletes: [], message: nil)
}

/// One replaced booking as the device queued it (`OfflineReplacedBooking`, plain values for the script).
nonisolated struct RulebookQueuedReplaceTarget: Equatable, Sendable {
    let collection: String
    /// The stored document id.
    let bookingId: String
    let fingerprint: String
    let createdOffline: Bool
}

/// What the replay read for one replaced booking.
nonisolated struct RulebookOfflineReplaceLive: @unchecked Sendable {
    let collection: String
    let bookingId: String
    /// The live document as stored (Firestore values), nil when missing.
    let live: [String: Any]?
    let tombstoned: Bool
    /// `canDeleteBooking` on the live booking; nil when this device cannot judge it (the rules decide).
    let mayDelete: Bool?
}

extension CanonicalBusinessEngine {
    /// `OFFLINE_REPLACE_CHANGED_MESSAGE`.
    nonisolated static var offlineReplaceChangedMessage: String {
        constant("OFFLINE_REPLACE_CHANGED_MESSAGE", as: String.self) ?? "Changed on another device — not replaced"
    }

    /// `OFFLINE_REPLACE_REFUSED_MESSAGE`.
    nonisolated static var offlineReplaceRefusedMessage: String {
        constant("OFFLINE_REPLACE_REFUSED_MESSAGE", as: String.self)
            ?? "Not replaced — you can no longer remove the existing booking, so both bookings are as they were"
    }

    /// RULEBOOK 1.86.0 `offlineReplaceReplayDecision({ queued, newBooking, replaced, mayCreate, timeZone })`.
    /// `.unanswered` (nothing written) when the script did not answer.
    nonisolated static func offlineReplaceReplayDecision(
        bookingCollection: String,
        bookingId: String,
        queuedReplaced: [RulebookQueuedReplaceTarget],
        newBookingDeleted: Bool,
        newBookingExists: Bool,
        newBookingTombstoned: Bool,
        replaced: [RulebookOfflineReplaceLive],
        timeZone: String
    ) -> RulebookOfflineReplaceResult {
        let input: [String: Any] = [
            "queued": [
                "booking": ["bookingId": bookingId, "collection": bookingCollection],
                "replaced": queuedReplaced.map {
                    [
                        "bookingId": $0.bookingId,
                        "collection": $0.collection,
                        "fingerprint": $0.fingerprint,
                        "createdOffline": $0.createdOffline,
                    ] as [String: Any]
                },
                "newBookingDeleted": newBookingDeleted,
            ] as [String: Any],
            "newBooking": ["exists": newBookingExists, "tombstoned": newBookingTombstoned],
            "replaced": replaced.map { row -> [String: Any] in
                var entry: [String: Any] = [
                    "bookingId": row.bookingId,
                    "collection": row.collection,
                    "live": row.live.map { BookingWritePatch.storedJSON($0, collection: row.collection) } ?? NSNull(),
                    "tombstoned": row.tombstoned,
                ]
                if let mayDelete = row.mayDelete { entry["mayDelete"] = mayDelete }
                return entry
            },
            "timeZone": timeZone,
        ]
        guard JSONSerialization.isValidJSONObject([input]),
              let row = callJSON("offlineReplaceReplayDecision", arguments: [input]) as? [String: Any],
              let decision = row["decision"] as? String else { return .unanswered }
        let deletes = (row["deletes"] as? [[String: Any]] ?? []).compactMap { entry -> RulebookBookingReplaceRef? in
            guard let collection = entry["collection"] as? String, let id = entry["bookingId"] as? String else { return nil }
            return RulebookBookingReplaceRef(collection: collection, bookingId: id)
        }
        return RulebookOfflineReplaceResult(decision: decision, deletes: deletes, message: row["message"] as? String)
    }

    /// `offlineReplaceRefusalDecision(code)`: `alreadyGone` (not-found), `refusePermission` (permission-denied) or `retry`.
    nonisolated static func offlineReplaceRefusalDecision(code: Int) -> String {
        callJSON("offlineReplaceRefusalDecision", arguments: [code]) as? String ?? "retry"
    }
}
