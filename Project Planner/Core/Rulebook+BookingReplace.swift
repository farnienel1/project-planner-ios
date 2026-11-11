//
//  Rulebook+BookingReplace.swift
//  Project Planner
//
//  RULEBOOK 1.41.0 §5 (owner decision 11 Nov, "Replace existing booking"; web `lib/canonical/bookingReplace.ts`).
//  An orange double-booking row offers Replace beside ✓ and ✕ only when the viewer may delete every overlapping
//  booking on it (`bookingReplaceOffer`, `canDeleteBooking` through `JobAccessContext.bookingRemoveAction`); the save is
//  ONE Firestore batch — the new booking and each replaced booking's delete with its tombstone
//  (`bookingReplaceWrites`). Online only (`booking.replace`, `OfflineAction.replaceBooking`). Swift only maps inputs and
//  writes the batch; every decision is the script's.
//

import Foundation

/// A booking Replace removes: its collection (`bookings` / `managerSiteBookings`) and stored document id.
nonisolated struct RulebookBookingReplaceRef: Hashable, Codable, Sendable {
    let collection: String
    let bookingId: String
}

/// One delete of `bookingReplaceWrites`: the booking path, its tombstone path and the tombstone fields (the app adds
/// `deletedAt` as the server timestamp).
nonisolated struct RulebookBookingReplaceDelete: @unchecked Sendable {
    let collection: String
    let bookingId: String
    let path: String
    let tombstonePath: String
    let tombstone: [String: Any]
}

nonisolated struct RulebookBookingReplacePlan: @unchecked Sendable {
    let bookingPath: String
    let deletes: [RulebookBookingReplaceDelete]
}

extension CanonicalBusinessEngine {
    /// `BOOKING_REPLACE_LABEL` ("Replace").
    nonisolated static var bookingReplaceLabel: String {
        constant("BOOKING_REPLACE_LABEL", as: String.self) ?? "Replace"
    }

    /// `BOOKING_REPLACE_HELP` ("Replace the existing booking with this one").
    nonisolated static var bookingReplaceHelp: String {
        constant("BOOKING_REPLACE_HELP", as: String.self) ?? "Replace the existing booking with this one"
    }

    /// `BOOKING_REPLACE_CHOSEN_TEXT` ("replaces the existing booking").
    nonisolated static var bookingReplaceChosenText: String {
        constant("BOOKING_REPLACE_CHOSEN_TEXT", as: String.self) ?? "replaces the existing booking"
    }

    /// RULEBOOK 1.41.0 `bookingReplaceOffer({ clashing })`: the bookings Replace would remove, or nil when Replace is not
    /// offered (any overlapping booking the viewer may not delete, or not a labour / manager schedule booking). Nil when
    /// the script did not answer — no Replace then.
    nonisolated static func bookingReplaceOffer(
        clashing: [(bookingId: String, collection: String, mayDelete: Bool)]
    ) -> [RulebookBookingReplaceRef]? {
        let input: [String: Any] = [
            "clashing": clashing.map { ["bookingId": $0.bookingId, "collection": $0.collection, "mayDelete": $0.mayDelete] },
        ]
        guard let row = callJSON("bookingReplaceOffer", arguments: [input]) as? [String: Any],
              row["offered"] as? Bool == true,
              let bookings = row["bookings"] as? [[String: Any]] else { return nil }
        let refs = bookings.compactMap { entry -> RulebookBookingReplaceRef? in
            guard let collection = entry["collection"] as? String, let id = entry["bookingId"] as? String else { return nil }
            return RulebookBookingReplaceRef(collection: collection, bookingId: id)
        }
        return refs.isEmpty ? nil : refs
    }

    /// RULEBOOK 1.41.0 `bookingReplaceWrites({ organizationId, booking, replaced, deletedBy, deletedFrom: 'ios' })`. Nil —
    /// write nothing — when the script refuses the plan (a replaced booking is the booking itself, an unusable id).
    nonisolated static func bookingReplaceWrites(
        organizationId: String,
        bookingCollection: String,
        bookingId: String,
        replaced: [RulebookBookingReplaceRef],
        deletedBy: String
    ) -> RulebookBookingReplacePlan? {
        let input: [String: Any] = [
            "organizationId": organizationId,
            "booking": ["collection": bookingCollection, "bookingId": bookingId],
            "replaced": replaced.map { ["collection": $0.collection, "bookingId": $0.bookingId] },
            "deletedBy": deletedBy,
            "deletedFrom": "ios",
        ]
        guard let row = callJSON("bookingReplaceWrites", arguments: [input]) as? [String: Any],
              let bookingPath = row["bookingPath"] as? String,
              let deletes = row["deletes"] as? [[String: Any]] else { return nil }
        let parsed = deletes.compactMap { entry -> RulebookBookingReplaceDelete? in
            guard let collection = entry["collection"] as? String,
                  let id = entry["bookingId"] as? String,
                  let path = entry["path"] as? String,
                  let tombstonePath = entry["tombstonePath"] as? String,
                  let tombstone = entry["tombstone"] as? [String: Any] else { return nil }
            return RulebookBookingReplaceDelete(collection: collection, bookingId: id, path: path, tombstonePath: tombstonePath, tombstone: tombstone)
        }
        guard parsed.count == deletes.count, !parsed.isEmpty else { return nil }
        return RulebookBookingReplacePlan(bookingPath: bookingPath, deletes: parsed)
    }
}

extension CanonicalBusinessEngine {
    /// `bookingReplaceOffer` for a row's overlapping bookings, each with `mayDelete` = `bookingRemoveAction == "delete"`
    /// (`canDeleteBooking` for the signed-in viewer on the booking's job). Swift only maps the bookings.
    @MainActor
    static func bookingReplaceOffer(labour: [Booking], manager: [ManagerSiteBooking]) -> [RulebookBookingReplaceRef]? {
        guard !(labour.isEmpty && manager.isEmpty) else { return nil }
        // Before the profile has loaded `bookingRemoveAction` reads "delete" (the rules still decide); Replace waits for
        // a known viewer.
        guard JobAccessContext.readViewer != nil else { return nil }
        let clashing: [(bookingId: String, collection: String, mayDelete: Bool)] =
            labour.map { booking in
                (
                    booking.documentKey,
                    "bookings",
                    JobAccessContext.bookingRemoveAction(collection: "bookings", projectId: booking.storedProjectId) == "delete"
                )
            } + manager.map { booking in
                let jobLocation = booking.locationType == .project || booking.locationType == .smallWork
                return (
                    booking.documentKey,
                    "managerSiteBookings",
                    JobAccessContext.bookingRemoveAction(
                        collection: "managerSiteBookings",
                        userId: booking.userId,
                        locationType: booking.locationType.rawValue,
                        locationId: jobLocation ? booking.storedLocationId : nil
                    ) == "delete"
                )
            }
        return bookingReplaceOffer(clashing: clashing)
    }
}
