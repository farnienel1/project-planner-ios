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

// MARK: - Review 1.41: the bookings a Replace removes, as this phone shows them

/// A booking Replace removes, with the copy this phone showed (`BookingWritePatch.deleteFingerprint`) so the save can
/// refuse when it changed on another device in between (review 1.41 #3).
struct BookingReplaceTarget {
    let ref: RulebookBookingReplaceRef
    let fingerprint: String
    let labour: Booking?
    let manager: ManagerSiteBooking?

    /// Each ref resolved against the bookings on this phone. Nil — replace nothing — when any of them is no longer here
    /// (deleted or not loaded): Replace never removes a booking the person was not shown.
    static func resolve(
        _ refs: [RulebookBookingReplaceRef],
        bookings: [Booking],
        managerBookings: [ManagerSiteBooking]
    ) -> [BookingReplaceTarget]? {
        guard !refs.isEmpty else { return nil }
        var targets: [BookingReplaceTarget] = []
        for ref in refs {
            let key = ref.bookingId.lowercased()
            if ref.collection == "bookings",
               let booking = bookings.first(where: { $0.documentKey.lowercased() == key }) {
                targets.append(BookingReplaceTarget(ref: ref, fingerprint: BookingWritePatch.deleteFingerprint(booking), labour: booking, manager: nil))
            } else if ref.collection == "managerSiteBookings",
                      let booking = managerBookings.first(where: { $0.documentKey.lowercased() == key }) {
                targets.append(BookingReplaceTarget(ref: ref, fingerprint: BookingWritePatch.deleteFingerprint(booking), labour: nil, manager: booking))
            } else {
                return nil
            }
        }
        return targets
    }
}

/// What a Replace that saved nothing tells the person (review 1.41 #3, #4; the same words as web).
enum BookingReplaceMessages {
    static let changed = "Changed on another device — not replaced."
    static let alreadyGone = "The existing booking was already removed on another device — not replaced."
    static let refused = "Not replaced — you can no longer remove the existing booking."
    static let notConfirmed = "Not saved — check connection. If the connection comes back, the schedule shows whether the change went through."
    static let notSaved = "This booking could not replace the existing one. Nothing was saved."
    static let notOnThisPhone = "The existing booking is no longer on this phone — refresh and try again. Nothing was saved."
}

extension CanonicalBusinessEngine {
    /// RULEBOOK 1.23.0 `bookingRequestClashIds` for a Replace (review 1.41 #8, #9): the person's labour and manager
    /// schedule bookings the booking being made overlaps on its day — the day before's overnight booking included,
    /// which the rule reaches into this morning. Labour bookings that no longer occupy a day never count. Fails closed:
    /// when the script does not answer nothing is offered, never an interval guessed in Swift.
    @MainActor
    static func bookingReplaceCandidates(
        request: RulebookClashBooking,
        labour: [Booking],
        manager: [ManagerSiteBooking],
        policy: OrgPayrollTimePolicy
    ) -> (labour: [Booking], manager: [ManagerSiteBooking]) {
        let liveLabour = labour.filter(\.occupiesDay)
        guard !(liveLabour.isEmpty && manager.isEmpty) else { return ([], []) }
        var existing: [RulebookClashBooking] = []
        for booking in liveLabour {
            var row = booking.rulebookClashBooking
            row.id = "o:" + booking.id.uuidString
            existing.append(row)
        }
        for booking in manager {
            var row = booking.rulebookClashBooking
            row.id = "m:" + booking.id.uuidString
            existing.append(row)
        }
        guard let ids = bookingRequestClashIds(request: request, existing: existing, day: bookingDayInput(policy: policy)) else {
            return ([], [])
        }
        let hit = Set(ids)
        return (
            liveLabour.filter { hit.contains("o:" + $0.id.uuidString) },
            manager.filter { hit.contains("m:" + $0.id.uuidString) }
        )
    }
}

/// The follow-ups a normal delete sends, for each booking a Replace removes (review 1.41 #1, #2).
enum BookingReplaceNotices {
    /// `CanonicalBusinessEngine.bookingDeleteSignedTimesheetWarning` before the Replace is written: a replaced booking
    /// on one of the person's signed or exported timesheets shows the delete's warning (the replace still goes ahead,
    /// as a delete does; the signed sheet never changes).
    @MainActor
    static func warnIfOnSignedTimesheet(_ targets: [BookingReplaceTarget], organizationId: String, firebaseBackend: FirebaseBackend) async {
        for target in targets {
            let userId: String?
            let day: Date
            if let booking = target.labour {
                userId = accountForLabourBooking(operativeId: booking.operativeId, users: RulebookRosterSnapshot.users)?.id
                day = booking.date
            } else if let booking = target.manager {
                userId = booking.userId
                day = booking.date
            } else {
                continue
            }
            guard let userId, !userId.isEmpty else { continue }
            let sheets = await firebaseBackend.signedTimesheetCandidates(organizationId: organizationId, userId: userId)
            if let warning = CanonicalBusinessEngine.bookingDeleteSignedTimesheetWarning(
                dayKey: OrganizationRulebookContext.dayKey(day),
                sheets: sheets
            ) {
                OfflineOutboxStore.shared.lastNoticeMessage = warning
                return
            }
        }
    }

    /// RULEBOOK 1.33.0 §25 reopen: each replaced booking's PAYE overtime line, as after a normal delete.
    @MainActor
    static func reopenOvertime(_ targets: [BookingReplaceTarget], organizationId: String) {
        for target in targets {
            if let booking = target.labour {
                OvertimeReopenNotice.labour(before: booking, after: nil, organizationId: organizationId)
            } else if let booking = target.manager {
                OvertimeReopenNotice.managerSite(before: booking, after: nil, organizationId: organizationId)
            }
        }
    }
}
