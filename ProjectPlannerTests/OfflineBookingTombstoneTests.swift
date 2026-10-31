import XCTest
@testable import Project_Planner

/// RULEBOOK §2 offline rules and booking tombstones, through the packed rulebook
/// (`bookingTombstonePath`, `bookingTombstoneWriteFields`, `bookingReplayRefusedIsFinal`).
@MainActor
final class OfflineBookingTombstoneTests: XCTestCase {
    func testTombstonePathAndFieldsComeFromTheRulebook() {
        XCTAssertEqual(
            CanonicalBusinessEngine.bookingTombstonePath(organizationId: "TEST-org", bookingId: "ABC-1"),
            "organizations/TEST-org/deletedBookings/ABC-1"
        )
        XCTAssertNil(CanonicalBusinessEngine.bookingTombstonePath(organizationId: "TEST-org", bookingId: "a/b"))

        let fields = CanonicalBusinessEngine.bookingTombstoneWriteFields(
            bookingId: "ABC-1", collection: "bookings", deletedBy: "uid-1", deletedFrom: "ios"
        )
        XCTAssertEqual(fields?["bookingId"] as? String, "ABC-1")
        XCTAssertEqual(fields?["collection"] as? String, "bookings")
        XCTAssertEqual(fields?["deletedBy"] as? String, "uid-1")
        XCTAssertEqual(fields?["deletedFrom"] as? String, "ios")
        // Only the tombstone's own keys: no write metadata (the rule refuses anything else).
        XCTAssertEqual(Set(fields?.keys.map { $0 } ?? []), ["bookingId", "collection", "deletedBy", "deletedFrom"])
        XCTAssertNil(CanonicalBusinessEngine.bookingTombstoneWriteFields(
            bookingId: "ABC-1", collection: "holidayBookings", deletedBy: "uid-1"
        ))
    }

    func testPermissionDeniedReplayIsFinal() {
        XCTAssertTrue(CanonicalBusinessEngine.bookingReplayRefusedIsFinal(errorCode: 7))
        XCTAssertFalse(CanonicalBusinessEngine.bookingReplayRefusedIsFinal(errorCode: 14))
        XCTAssertEqual(
            CanonicalBusinessEngine.bookingReplayRefusedMessage,
            "This booking was cancelled or deleted on another device."
        )
        let denied = NSError(domain: "FIRFirestoreErrorDomain", code: 7)
        XCTAssertTrue(BookingWritePatch.isRefusedFinal(denied))
        // Code 7 from another domain is not a Firestore refusal.
        XCTAssertFalse(BookingWritePatch.isRefusedFinal(NSError(domain: NSURLErrorDomain, code: 7)))
    }

    func testEditWritesOnlyChangedFields() {
        let old = Booking(
            operativeId: UUID(),
            projectId: UUID(),
            date: Date(timeIntervalSince1970: 1_800_000_000),
            timeSlot: .fullDay,
            bookedBy: "TEST-manager"
        )
        var edited = old
        edited.status = .cancelled
        edited.notes = "TEST-note"
        XCTAssertEqual(BookingWritePatch.changedLabourFields(from: old, to: edited), ["status", "notes"])
        let patch = BookingWritePatch.patch(
            BookingWritePatch.labourValues(edited, deletesClearedFields: true),
            fields: ["status", "notes"]
        )
        XCTAssertEqual(Set(patch.keys), ["status", "notes"])
        XCTAssertEqual(patch["status"] as? String, BookingStatus.cancelled.rawValue)
    }

    func testOfflinePolicyTableCoversEveryAction() {
        XCTAssertEqual(OfflinePolicy.availability(.createBooking), .allowedOffline)
        XCTAssertEqual(OfflinePolicy.availability(.annualLeaveRequest), .allowedOffline)
        XCTAssertEqual(OfflinePolicy.availability(.ownNotificationToggles), .allowedOffline)
        XCTAssertEqual(OfflinePolicy.availability(.currency), .onlineOnly)
        XCTAssertEqual(OfflinePolicy.availability(.userInvites), .onlineOnly)
        XCTAssertEqual(OfflinePolicy.availability(.clashApproval), .onlineOnly)
        XCTAssertEqual(OfflinePolicy.availability(.switchOrganization), .onlineOnly)
        XCTAssertEqual(OfflinePolicy.availability(.weeklyReport), .readOnlyOffline)
        XCTAssertFalse(OfflinePolicy.isEnabled(.paymentRuns, isOnline: false))
        XCTAssertTrue(OfflinePolicy.isEnabled(.paymentRuns, isOnline: true))
        XCTAssertEqual(
            OfflinePolicy.offlineMessage(.warningSettings, isOnline: false, lastSyncedAt: nil),
            "Connect to the internet to change this"
        )
        XCTAssertNil(OfflinePolicy.offlineMessage(.editBooking, isOnline: false, lastSyncedAt: nil))
        XCTAssertTrue(
            OfflinePolicy.lastUpdatedMessage(Date(timeIntervalSince1970: 0))?.hasPrefix("Last updated ") == true
        )
        // Every action has a row (the switch is exhaustive); the raw ids are unique for the Android port.
        XCTAssertEqual(Set(OfflineAction.allCases.map(\.rawValue)).count, OfflineAction.allCases.count)
    }
}
