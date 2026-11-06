import XCTest
import FirebaseFirestore
@testable import Project_Planner

/// RULEBOOK 1.33.0 §2 on iOS through `CanonicalBusinessEngine` (owner decisions 4 Nov "Cancel is removed as a user
/// action" and "Offline delete on iOS"): the one remove control (`bookingRemoveAction`), the delete fingerprint
/// (`bookingDeleteFingerprint`), the replay and refusal decisions (`offlineDeleteReplayDecision`,
/// `offlineDeleteRefusalDecision`), the signed-timesheet warning (`bookingDeleteSignedTimesheetWarning`) and the outbox:
/// created-and-deleted offline sends nothing, a queued edit keeps the synced copy's fingerprint, older queued items still
/// decode. Expected values were checked in node against the packed `canonical-business.js` 1.33.0.
@MainActor
final class Rulebook1330OfflineDeleteTests: XCTestCase {
    private typealias Role = CanonicalBusinessEngine.CanonicalStaffAccountRole

    override func setUp() async throws {
        OfflineOutboxStore.shared.clearAll()
    }

    override func tearDown() async throws {
        OfflineOutboxStore.shared.clearAll()
    }

    private func viewer(_ role: Role) -> JobAccessViewer {
        JobAccessViewer(role: role, projectsToggle: false, smallWorksToggle: false, uid: "m1", ids: ["m1"], email: "m1@x.t")
    }

    // MARK: Remove control

    func testTheOnlyRemoveControlIsDeleteForThoseWhoMayDelete() {
        let labour: [String: Any] = ["collection": "bookings", "projectId": "j"]
        let admin = viewer(Role(isSuperAdmin: false, isAdmin: true, isManager: false, isOperativeMode: false))
        let manager = viewer(Role(isSuperAdmin: false, isAdmin: false, isManager: true, isOperativeMode: false))
        let operative = viewer(Role(isSuperAdmin: false, isAdmin: false, isManager: false, isOperativeMode: true))
        XCTAssertEqual(CanonicalBusinessEngine.bookingRemoveAction(admin, booking: labour, job: ["managerUserIds": ["zz"]], managers: []), "delete")
        XCTAssertEqual(CanonicalBusinessEngine.bookingRemoveAction(manager, booking: labour, job: ["managerUserIds": ["m1"]], managers: []), "delete")
        XCTAssertEqual(CanonicalBusinessEngine.bookingRemoveAction(manager, booking: labour, job: ["managerUserIds": ["zz"]], managers: []), "none")
        XCTAssertEqual(CanonicalBusinessEngine.bookingRemoveAction(operative, booking: labour, job: ["managerUserIds": ["m1"]], managers: []), "none")
        let office: [String: Any] = ["collection": "managerSiteBookings", "userId": "m1", "locationType": "office"]
        XCTAssertEqual(CanonicalBusinessEngine.bookingRemoveAction(manager, booking: office, job: nil, managers: []), "delete")
    }

    // MARK: Fingerprint and replay

    func testTheDeviceCopyAndTheStoredDocumentHaveTheSameFingerprint() throws {
        let day = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-11-04T00:00:00Z"))
        var booking = LogicFixtures.booking(on: day)
        let fingerprint = BookingWritePatch.deleteFingerprint(booking)
        XCTAssertTrue(fingerprint.hasPrefix("bookings|"))
        let stored: [String: Any] = [
            "operativeId": booking.storedOperativeId,
            "projectId": booking.storedProjectId,
            "date": Timestamp(date: booking.date),
            "timeSlot": "FULL_DAY",
            "status": "Confirmed",
            "notes": "",
            "isBreakRemoved": false,
        ]
        XCTAssertEqual(BookingWritePatch.stored(stored, collection: "bookings"), fingerprint, "the other spelling of the slot is the same booking")
        booking.notes = "TEST-changed"
        XCTAssertNotEqual(BookingWritePatch.deleteFingerprint(booking), fingerprint)
    }

    func testReplayDecisions() {
        let live: [String: Any] = [
            "operativeId": "OP-1", "projectId": "job-1", "date": Timestamp(seconds: 1_793_750_400, nanoseconds: 0),
            "timeSlot": "Full Day", "status": "Confirmed", "notes": "", "isBreakRemoved": false,
        ]
        let fingerprint = BookingWritePatch.stored(live, collection: "bookings")
        XCTAssertEqual(fingerprint, "bookings|op-1|job-1|||2026-11-04|FULL DAY|||||Confirmed|")
        func decide(_ queued: String?, live: [String: Any]?, tombstoned: Bool = false, mayDelete: Bool? = nil) -> String {
            FirebaseBackend.offlineDeleteDecision(
                documentId: "B1", collection: "bookings", fingerprint: queued,
                live: live, tombstoned: tombstoned, mayDelete: mayDelete, timeZone: "Europe/London"
            )
        }
        XCTAssertEqual(decide(fingerprint, live: live), "apply")
        XCTAssertEqual(decide(fingerprint, live: nil), "alreadyGone")
        XCTAssertEqual(decide(fingerprint, live: live, tombstoned: true), "alreadyGone")
        XCTAssertEqual(decide("changed", live: live), "refuseChanged", "changed on another device — not deleted")
        XCTAssertEqual(decide(fingerprint, live: live, mayDelete: false), "refusePermission")
        XCTAssertEqual(decide(nil, live: live), "apply", "an item queued by an older build has no fingerprint")
        XCTAssertEqual(CanonicalBusinessEngine.offlineDeleteRefusalDecision(code: 5), "alreadyGone")
        XCTAssertEqual(CanonicalBusinessEngine.offlineDeleteRefusalDecision(code: 7), "refusePermission")
        XCTAssertEqual(CanonicalBusinessEngine.offlineDeleteRefusalDecision(code: 14), "retry")
        XCTAssertEqual(CanonicalBusinessEngine.offlineDeleteChangedMessage, "Changed on another device — not deleted")
        XCTAssertFalse(CanonicalBusinessEngine.offlineDeleteRefusedMessage.isEmpty)
    }

    func testAWrappedRefusalIsStillSeenAsPermissionDenied() {
        let firestore = NSError(domain: "FIRFirestoreErrorDomain", code: 7)
        let wrapped = NSError(domain: "FirebaseBackend", code: 403, userInfo: [NSUnderlyingErrorKey: firestore])
        XCTAssertEqual(BookingWritePatch.firestoreErrorCode(wrapped), 7, "the outbox refusal detection fix")
        XCTAssertTrue(BookingWritePatch.isRefusedFinal(wrapped, isCreate: false))
        XCTAssertNil(BookingWritePatch.firestoreErrorCode(NSError(domain: "NSURLErrorDomain", code: -1009)))
    }

    func testASignedTimesheetDayWarnsButAnUnsignedOneDoesNot() {
        let signed: [String: Any] = [
            "startDayKey": "2026-11-02", "endDayKey": "2026-11-08",
            "operativeSignedAt": ["seconds": 1_794_000_000, "nanoseconds": 0], "operativeSignedByName": "TEST-Op",
        ]
        XCTAssertEqual(
            CanonicalBusinessEngine.bookingDeleteSignedTimesheetWarning(dayKey: "2026-11-04", sheets: [signed]),
            "This day is on a signed timesheet. Deleting the booking does not change the signed timesheet."
        )
        XCTAssertNil(CanonicalBusinessEngine.bookingDeleteSignedTimesheetWarning(dayKey: "2026-11-10", sheets: [signed]))
        XCTAssertNil(CanonicalBusinessEngine.bookingDeleteSignedTimesheetWarning(
            dayKey: "2026-11-04", sheets: [["startDayKey": "2026-11-02", "endDayKey": "2026-11-08"]]
        ))
    }

    // MARK: Outbox

    func testCreatedAndDeletedOfflineSendsNothing() {
        let outbox = OfflineOutboxStore.shared
        let booking = LogicFixtures.booking(on: Date())
        outbox.enqueueSaveBooking(booking, changedFields: nil, organizationId: "TEST-ORG")
        let result = outbox.enqueueDeleteBooking(booking, fingerprint: BookingWritePatch.deleteFingerprint(booking), organizationId: "TEST-ORG")
        XCTAssertEqual(result, .droppedLocal)
        XCTAssertTrue(outbox.entries.isEmpty)
    }

    func testAQueuedEditKeepsTheSyncedCopysFingerprint() throws {
        let outbox = OfflineOutboxStore.shared
        let synced = LogicFixtures.booking(on: Date())
        var edited = synced
        edited.notes = "TEST-offline edit"
        let baseline = BookingWritePatch.deleteFingerprint(synced)
        outbox.enqueueSaveBooking(edited, changedFields: ["notes"], organizationId: "TEST-ORG", baselineFingerprint: baseline)
        let result = outbox.enqueueDeleteBooking(edited, fingerprint: BookingWritePatch.deleteFingerprint(edited), organizationId: "TEST-ORG")
        XCTAssertEqual(result, .queued)
        XCTAssertEqual(outbox.entries.count, 1, "the queued edit is replaced by the delete")
        let entry = try XCTUnwrap(outbox.entries.first)
        XCTAssertEqual(entry.operation, .deleteBooking)
        let payload = try JSONDecoder().decode(OfflineDeleteBookingPayload.self, from: entry.payload)
        XCTAssertEqual(payload.fingerprint, baseline)
        XCTAssertEqual(payload.collection, "bookings")
        XCTAssertEqual(payload.labourBooking?.id, synced.id)
        XCTAssertEqual(outbox.pendingDeletedBookingIds(collection: "bookings", organizationId: "TEST-ORG"), [synced.id])
    }

    func testAManagerScheduleDeleteKeepsTheStoredLowerCaseId() throws {
        let outbox = OfflineOutboxStore.shared
        var booking = ManagerSiteBooking(id: UUID(), userId: "m1", date: Date(), timeSlot: .morning, locationType: .office)
        booking.documentId = booking.id.uuidString.lowercased()
        outbox.enqueueDeleteManagerSiteBooking(booking, fingerprint: BookingWritePatch.deleteFingerprint(booking), organizationId: "TEST-ORG")
        let entry = try XCTUnwrap(outbox.entries.first)
        let payload = try JSONDecoder().decode(OfflineDeleteBookingPayload.self, from: entry.payload)
        XCTAssertEqual(payload.documentId, booking.id.uuidString.lowercased())
        XCTAssertEqual(payload.collection, "managerSiteBookings")
    }

    func testAnOlderQueuedDeleteStillDecodes() throws {
        let id = UUID()
        let old = try XCTUnwrap("{\"bookingId\":\"\(id.uuidString)\"}".data(using: .utf8))
        let payload = try JSONDecoder().decode(OfflineDeleteBookingPayload.self, from: old)
        XCTAssertEqual(payload.bookingId, id)
        XCTAssertNil(payload.fingerprint)
        XCTAssertNil(payload.collection)
    }
}
