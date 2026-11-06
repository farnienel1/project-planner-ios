//
//  Rulebook+OfflineDelete.swift
//  Project Planner
//
//  RULEBOOK 1.33.0 §2 (owner decisions 4 Nov "Cancel is removed as a user action" and "Offline delete on iOS"):
//  bookings are Book / Edit / Delete only (`bookingRemoveAction`); deleting a labour or manager schedule booking works
//  offline (`bookingDeleteOfflineAction` → `booking.delete`), a subcontractor booking stays online only
//  (`booking.delete_subcontractor`). A queued delete carries `bookingDeleteFingerprint` of the booking as last synced
//  and replays through `offlineDeleteReplayDecision` / `offlineDeleteRefusalDecision`. A day on a signed timesheet
//  warns but allows (`bookingDeleteSignedTimesheetWarning`). Every answer is the packed script's; Swift only maps
//  models and Firestore values into its inputs.
//

import Foundation

extension CanonicalBusinessEngine {
    /// `bookingRemoveAction(viewer, booking, job, managers)`: `delete` for exactly the people `canDeleteBooking` allows,
    /// `none` for everyone else. `none` when the script did not answer.
    nonisolated static func bookingRemoveAction(
        _ viewer: JobAccessViewer,
        booking: [String: Any],
        job: [String: Any]?,
        managers: [[String: Any]]
    ) -> String {
        callJSON("bookingRemoveAction", arguments: [viewer.json, booking, job ?? NSNull(), managers]) as? String ?? "none"
    }

    /// `bookingDeleteOfflineAction(collection)`: `booking.delete` for `bookings` / `managerSiteBookings`, else
    /// `booking.delete_subcontractor` (online only).
    nonisolated static func bookingDeleteOfflineAction(collection: String) -> String {
        callJSON("bookingDeleteOfflineAction", arguments: [collection]) as? String ?? "booking.delete_subcontractor"
    }

    /// `bookingDeleteFingerprint(booking, timeZone)`: every field a booking edit can change, as one text. `booking` is a
    /// stored booking as JSON (`FirebaseBackend.firestoreJSON` values) with its `collection`. Empty when no answer.
    nonisolated static func bookingDeleteFingerprint(_ booking: [String: Any], timeZone: String) -> String {
        guard JSONSerialization.isValidJSONObject([booking]) else { return "" }
        return callJSON("bookingDeleteFingerprint", arguments: [booking, timeZone]) as? String ?? ""
    }

    /// `offlineDeleteReplayDecision({ queued, live, tombstoned, mayDelete, timeZone })`: `apply`, `dropLocal`,
    /// `alreadyGone`, `refuseChanged` or `refusePermission`. `refuseChanged` when the script did not answer, so nothing
    /// is deleted on a guess.
    nonisolated static func offlineDeleteReplayDecision(
        bookingId: String,
        collection: String,
        fingerprint: String,
        createdOffline: Bool,
        live: [String: Any]?,
        tombstoned: Bool,
        mayDelete: Bool?,
        timeZone: String
    ) -> String {
        var input: [String: Any] = [
            "queued": [
                "bookingId": bookingId,
                "collection": collection,
                "fingerprint": fingerprint,
                "createdOffline": createdOffline,
            ] as [String: Any],
            "live": live ?? NSNull(),
            "tombstoned": tombstoned,
            "timeZone": timeZone,
        ]
        if let mayDelete { input["mayDelete"] = mayDelete }
        guard JSONSerialization.isValidJSONObject([input]) else { return "refuseChanged" }
        return callJSON("offlineDeleteReplayDecision", arguments: [input]) as? String ?? "refuseChanged"
    }

    /// `offlineDeleteRefusalDecision(code)`: `alreadyGone` (not-found), `refusePermission` (permission-denied) or `retry`.
    nonisolated static func offlineDeleteRefusalDecision(code: Int) -> String {
        callJSON("offlineDeleteRefusalDecision", arguments: [code]) as? String ?? "retry"
    }

    /// `OFFLINE_DELETE_CHANGED_MESSAGE`.
    nonisolated static var offlineDeleteChangedMessage: String {
        constant("OFFLINE_DELETE_CHANGED_MESSAGE", as: String.self) ?? "Changed on another device — not deleted"
    }

    /// `OFFLINE_DELETE_REFUSED_MESSAGE`.
    nonisolated static var offlineDeleteRefusedMessage: String {
        constant("OFFLINE_DELETE_REFUSED_MESSAGE", as: String.self)
            ?? "Not deleted — you can no longer delete this booking, so it is back on the schedule"
    }

    /// `bookingDeleteSignedTimesheetWarning(dayKey, sheets)`: the warning when the day is inside one of the person's
    /// signed or exported timesheets, else nil. `sheets` are `{ startDayKey, endDayKey, ...stored fields }` as JSON.
    nonisolated static func bookingDeleteSignedTimesheetWarning(dayKey: String, sheets: [[String: Any]]) -> String? {
        guard !sheets.isEmpty, JSONSerialization.isValidJSONObject(sheets) else { return nil }
        return callJSON("bookingDeleteSignedTimesheetWarning", arguments: [dayKey, sheets]) as? String
    }
}

extension BookingWritePatch {
    /// `bookingDeleteFingerprint` of a labour booking as this device holds it (its stored field values).
    static func deleteFingerprint(_ booking: Booking) -> String {
        stored(labourValues(booking, deletesClearedFields: false), collection: "bookings")
    }

    /// `bookingDeleteFingerprint` of a manager schedule booking as this device holds it.
    static func deleteFingerprint(_ booking: ManagerSiteBooking) -> String {
        stored(managerValues(booking, deletesClearedFields: false), collection: "managerSiteBookings")
    }

    /// `bookingDeleteFingerprint` of a stored document (the live copy a replay reads).
    nonisolated static func stored(_ data: [String: Any], collection: String) -> String {
        CanonicalBusinessEngine.bookingDeleteFingerprint(
            storedJSON(data, collection: collection),
            timeZone: OrganizationRulebookContext.timeZoneIdentifier
        )
    }

    /// A stored document as the rulebook reads it: Firestore values as JSON, plus its `collection`.
    nonisolated static func storedJSON(_ data: [String: Any], collection: String) -> [String: Any] {
        var json: [String: Any] = [:]
        for (key, value) in data { json[key] = FirebaseBackend.firestoreJSON(value) }
        json["collection"] = collection
        return json
    }

    /// The Firestore error code of `error`, looking through an app error that wraps it (`NSUnderlyingErrorKey`): a
    /// refused write the backend re-wrapped (for example "Only an admin or one of this job's managers…") is still a
    /// permission-denied refusal (1.33.0: the outbox refusal detection fix).
    nonisolated static func firestoreErrorCode(_ error: Error) -> Int? {
        var current: NSError? = error as NSError
        var depth = 0
        while let nsError = current, depth < 4 {
            if nsError.domain == "FIRFirestoreErrorDomain" { return nsError.code }
            current = nsError.userInfo[NSUnderlyingErrorKey] as? NSError
            depth += 1
        }
        return nil
    }
}
