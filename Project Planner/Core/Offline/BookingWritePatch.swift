//
//  BookingWritePatch.swift
//  Project Planner
//
//  Which stored booking fields a save changed, and their Firestore values (RULEBOOK §1 "Partial
//  writes only"). A create writes every field; an edit writes only the changed ones, so a queued
//  offline edit never rewrites the whole booking from a stale copy.
//

import Foundation
import FirebaseFirestore

enum BookingWritePatch {
    // MARK: Labour bookings (`organizations/{orgId}/bookings`)

    /// Every stored field an edit can change (not `id`, `createdAt` or write metadata).
    static let labourFieldNames: [String] = [
        "operativeId", "projectId", "date", "timeSlot", "bookedBy", "notes", "status",
        "workStartTime", "workEndTime", "isBreakRemoved", "otMultiplierOverride", "bookingGroupId"
    ]

    /// Firestore values for `booking`. A cleared optional is `FieldValue.delete()` when
    /// `deletesClearedFields`, else left out (a create has nothing to delete).
    static func labourValues(_ booking: Booking, deletesClearedFields: Bool) -> [String: Any] {
        var data: [String: Any] = [
            // A Firebase Auth uid stays a uid (web #189). Writing the in-app UUID would book nobody.
            "operativeId": booking.storedOperativeId,
            // The job id as stored (RULEBOOK 1.7.0 §1); a lower-case or non-UUID job id is never re-spelt.
            "projectId": booking.storedProjectId,
            "date": Timestamp(date: booking.date),
            "timeSlot": booking.timeSlot.rawValue,
            "bookedBy": booking.bookedBy,
            "notes": booking.notes ?? "",
            "status": booking.status.rawValue,
            "isBreakRemoved": booking.isBreakRemoved
        ]
        func optional(_ key: String, _ value: Any?) {
            if let value {
                data[key] = value
            } else if deletesClearedFields {
                data[key] = FieldValue.delete()
            }
        }
        optional("workStartTime", nonEmpty(booking.workStartTime))
        optional("workEndTime", nonEmpty(booking.workEndTime))
        optional("otMultiplierOverride", booking.otMultiplierOverride)
        optional("bookingGroupId", nonEmpty(booking.bookingGroupId))
        // RULEBOOK 1.11.0 §16, §17: `bookingJobCollectionFields` — the job's collection, when the job is loaded.
        for (key, value) in BookingJobCollectionContext.fields(collection: "bookings", jobId: booking.storedProjectId) {
            data[key] = value
        }
        return data
    }

    /// Stored fields that differ between `old` and `new`.
    static func changedLabourFields(from old: Booking, to new: Booking) -> Set<String> {
        var changed = Set<String>()
        if old.storedOperativeId != new.storedOperativeId { changed.insert("operativeId") }
        if old.storedProjectId != new.storedProjectId { changed.insert("projectId") }
        if old.date != new.date { changed.insert("date") }
        if old.timeSlot != new.timeSlot { changed.insert("timeSlot") }
        if old.bookedBy != new.bookedBy { changed.insert("bookedBy") }
        if (old.notes ?? "") != (new.notes ?? "") { changed.insert("notes") }
        if old.status != new.status { changed.insert("status") }
        if nonEmpty(old.workStartTime) != nonEmpty(new.workStartTime) { changed.insert("workStartTime") }
        if nonEmpty(old.workEndTime) != nonEmpty(new.workEndTime) { changed.insert("workEndTime") }
        if old.isBreakRemoved != new.isBreakRemoved { changed.insert("isBreakRemoved") }
        if old.otMultiplierOverride != new.otMultiplierOverride { changed.insert("otMultiplierOverride") }
        if nonEmpty(old.bookingGroupId) != nonEmpty(new.bookingGroupId) { changed.insert("bookingGroupId") }
        return changed
    }

    // MARK: Manager schedule bookings (`organizations/{orgId}/managerSiteBookings`)

    static let managerFieldNames: [String] = [
        "userId", "date", "timeSlot", "locationType", "locationId", "customLocationName",
        "workStartTime", "workEndTime", "isBreakRemoved", "bookingGroupId"
    ]

    static func managerValues(_ booking: ManagerSiteBooking, deletesClearedFields: Bool) -> [String: Any] {
        var data: [String: Any] = [
            "userId": booking.userId,
            "date": Timestamp(date: booking.date),
            "timeSlot": booking.timeSlot.rawValue,
            "locationType": booking.locationType.rawValue,
            "isBreakRemoved": booking.isBreakRemoved
        ]
        func optional(_ key: String, _ value: Any?) {
            if let value {
                data[key] = value
            } else if deletesClearedFields {
                data[key] = FieldValue.delete()
            }
        }
        optional("locationId", booking.storedLocationId)
        optional("customLocationName", nonEmpty(booking.customLocationName))
        optional("workStartTime", nonEmpty(booking.workStartTime))
        optional("workEndTime", nonEmpty(booking.workEndTime))
        optional("bookingGroupId", nonEmpty(booking.bookingGroupId))
        // RULEBOOK 1.11.0: a job-linked manager site booking carries `jobCollection` (from the loaded job, else its
        // `locationType`); office, home, survey and custom never do.
        for (key, value) in BookingJobCollectionContext.fields(
            collection: "managerSiteBookings",
            jobId: booking.storedLocationId,
            locationType: booking.locationType.rawValue
        ) {
            data[key] = value
        }
        return data
    }

    static func changedManagerFields(from old: ManagerSiteBooking, to new: ManagerSiteBooking) -> Set<String> {
        var changed = Set<String>()
        if old.userId != new.userId { changed.insert("userId") }
        if old.date != new.date { changed.insert("date") }
        if old.timeSlot != new.timeSlot { changed.insert("timeSlot") }
        if old.locationType != new.locationType { changed.insert("locationType") }
        if old.storedLocationId != new.storedLocationId { changed.insert("locationId") }
        if nonEmpty(old.customLocationName) != nonEmpty(new.customLocationName) { changed.insert("customLocationName") }
        if nonEmpty(old.workStartTime) != nonEmpty(new.workStartTime) { changed.insert("workStartTime") }
        if nonEmpty(old.workEndTime) != nonEmpty(new.workEndTime) { changed.insert("workEndTime") }
        if old.isBreakRemoved != new.isBreakRemoved { changed.insert("isBreakRemoved") }
        if nonEmpty(old.bookingGroupId) != nonEmpty(new.bookingGroupId) { changed.insert("bookingGroupId") }
        return changed
    }

    // MARK: Helpers

    /// `values` limited to `fields`.
    static func patch(_ values: [String: Any], fields: Set<String>) -> [String: Any] {
        values.filter { fields.contains($0.key) }
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return value
    }

    /// True when `error` is Firestore permission-denied (`bookingReplayRefusedIsFinal`).
    static func isRefusedFinal(_ error: Error) -> Bool {
        let nsError = error as NSError
        guard nsError.domain == "FIRFirestoreErrorDomain" else { return false }
        return CanonicalBusinessEngine.bookingReplayRefusedIsFinal(errorCode: nsError.code)
    }

    /// `bookingReplayRefusedIsFinal({ code, isCreate })` for a Firestore error on a queued booking save.
    static func isRefusedFinal(_ error: Error, isCreate: Bool?) -> Bool {
        let nsError = error as NSError
        guard nsError.domain == "FIRFirestoreErrorDomain" else { return false }
        return CanonicalBusinessEngine.bookingReplayRefusedIsFinal(errorCode: nsError.code, isCreate: isCreate)
    }
}
