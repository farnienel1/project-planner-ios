import XCTest
import FirebaseFirestore
@testable import Project_Planner

/// iOS 1.33.1 independent-review items 1 and 5 on PR #210. A booking write whose bounded wait timed out
/// (`FirestoreWriteAck.TimedOut`) is already with Firestore, which keeps sending it, so its queued copy is flagged
/// `sentToServer`:
/// - a later offline delete is a real delete with its tombstone (never the local drop RULEBOOK §2 `dropLocal` keeps for
///   a create that never left the phone), replayed through `offlineDeleteReplayDecision` with `createdOffline: false`
///   after this device's pending writes have landed;
/// - a replayed create is skipped when the document is already on the server (never `setData(merge:)` over another
///   device's later edit).
@MainActor
final class Booking1331OutboxReviewTests: XCTestCase {
    override func setUp() async throws {
        OfflineOutboxStore.shared.clearAll()
    }

    override func tearDown() async throws {
        OfflineOutboxStore.shared.clearAll()
    }

    private func onlyEntry() throws -> OfflineOutboxEntry {
        let entries = OfflineOutboxStore.shared.entries
        XCTAssertEqual(entries.count, 1, "\(entries.map(\.operation))")
        return try XCTUnwrap(entries.first)
    }

    // MARK: Item 1: a create handed to Firestore is never dropped locally

    func testADeleteAfterATimedOutCreateQueuesARealDeleteWithItsTombstone() throws {
        let outbox = OfflineOutboxStore.shared
        let booking = LogicFixtures.booking(on: Date())
        outbox.enqueueSaveBooking(booking, changedFields: nil, organizationId: "TEST-ORG", sentToServer: true)

        let result = outbox.enqueueDeleteBooking(booking, fingerprint: BookingWritePatch.deleteFingerprint(booking), organizationId: "TEST-ORG")

        XCTAssertEqual(result, .queued, "it may already be on the server: never a local drop")
        let entry = try onlyEntry()
        XCTAssertEqual(entry.operation, .deleteBooking)
        let payload = try JSONDecoder().decode(OfflineDeleteBookingPayload.self, from: entry.payload)
        XCTAssertEqual(payload.waitsForSentWrite, true, "the replay waits for the create to land first")
        XCTAssertEqual(payload.fingerprint, BookingWritePatch.deleteFingerprint(booking))
        XCTAssertEqual(payload.collection, "bookings")
    }

    func testAManagerScheduleDeleteAfterATimedOutCreateIsQueuedToo() throws {
        let outbox = OfflineOutboxStore.shared
        let booking = ManagerSiteBooking(id: UUID(), userId: "m1", date: Date(), timeSlot: .fullDay, locationType: .office)
        outbox.enqueueSaveManagerSiteBooking(booking, changedFields: nil, organizationId: "TEST-ORG", sentToServer: true)

        let result = outbox.enqueueDeleteManagerSiteBooking(booking, fingerprint: BookingWritePatch.deleteFingerprint(booking), organizationId: "TEST-ORG")

        XCTAssertEqual(result, .queued)
        let payload = try JSONDecoder().decode(OfflineDeleteBookingPayload.self, from: try onlyEntry().payload)
        XCTAssertEqual(payload.waitsForSentWrite, true)
        XCTAssertEqual(payload.collection, "managerSiteBookings")
    }

    func testACreateThatNeverLeftThePhoneIsStillDroppedLocally() {
        let outbox = OfflineOutboxStore.shared
        let booking = LogicFixtures.booking(on: Date())
        outbox.enqueueSaveBooking(booking, changedFields: nil, organizationId: "TEST-ORG")
        XCTAssertEqual(
            outbox.enqueueDeleteBooking(booking, fingerprint: BookingWritePatch.deleteFingerprint(booking), organizationId: "TEST-ORG"),
            .droppedLocal
        )
        XCTAssertTrue(outbox.entries.isEmpty)
    }

    /// An offline edit merged into a timed-out create keeps the flag, and the delete keeps the fingerprint of the copy
    /// Firestore holds (what the server will have), not of the unsent edit.
    func testTheSentFlagSurvivesALaterOfflineEdit() throws {
        let outbox = OfflineOutboxStore.shared
        let sent = LogicFixtures.booking(on: Date())
        outbox.enqueueSaveBooking(sent, changedFields: nil, organizationId: "TEST-ORG", sentToServer: true)
        var edited = sent
        edited.notes = "TEST-offline edit"
        outbox.enqueueSaveBooking(edited, changedFields: ["notes"], organizationId: "TEST-ORG", baselineFingerprint: BookingWritePatch.deleteFingerprint(sent))

        let save = try JSONDecoder().decode(OfflineSaveBookingPayload.self, from: try onlyEntry().payload)
        XCTAssertNil(save.changedFields, "still a create")
        XCTAssertEqual(save.sentToServer, true)
        XCTAssertEqual(save.sentFingerprint, BookingWritePatch.deleteFingerprint(sent))
        XCTAssertEqual(save.booking.notes, "TEST-offline edit")

        XCTAssertEqual(outbox.enqueueDeleteBooking(edited, fingerprint: BookingWritePatch.deleteFingerprint(edited), organizationId: "TEST-ORG"), .queued)
        let delete = try JSONDecoder().decode(OfflineDeleteBookingPayload.self, from: try onlyEntry().payload)
        XCTAssertEqual(delete.fingerprint, BookingWritePatch.deleteFingerprint(sent))
    }

    func testAReplayThatTimesOutMarksTheEntrySent() throws {
        let outbox = OfflineOutboxStore.shared
        let booking = LogicFixtures.booking(on: Date())
        outbox.enqueueSaveBooking(booking, changedFields: nil, organizationId: "TEST-ORG")
        let before = try onlyEntry()

        outbox.markSentToServer(entryId: before.id)

        let after = try onlyEntry()
        XCTAssertEqual(after.id, before.id)
        XCTAssertEqual(after.createdAt, before.createdAt)
        let payload = try JSONDecoder().decode(OfflineSaveBookingPayload.self, from: after.payload)
        XCTAssertEqual(payload.sentToServer, true)
        XCTAssertEqual(payload.sentFingerprint, BookingWritePatch.deleteFingerprint(booking))
        XCTAssertEqual(
            outbox.enqueueDeleteBooking(booking, fingerprint: BookingWritePatch.deleteFingerprint(booking), organizationId: "TEST-ORG"),
            .queued
        )
    }

    func testDeleteAfterQueuedSaveDecisions() {
        typealias Store = OfflineOutboxStore
        XCTAssertEqual(
            Store.deleteAfterQueuedSave(isCreate: true, sentToServer: false, baselineFingerprint: nil, sentFingerprint: nil, fingerprint: "F"),
            .dropLocal
        )
        XCTAssertEqual(
            Store.deleteAfterQueuedSave(isCreate: true, sentToServer: true, baselineFingerprint: nil, sentFingerprint: "S", fingerprint: "F"),
            .queue(fingerprint: "S", waitsForSentWrite: true)
        )
        XCTAssertEqual(
            Store.deleteAfterQueuedSave(isCreate: true, sentToServer: true, baselineFingerprint: nil, sentFingerprint: nil, fingerprint: "F"),
            .queue(fingerprint: "F", waitsForSentWrite: true)
        )
        XCTAssertEqual(
            Store.deleteAfterQueuedSave(isCreate: false, sentToServer: false, baselineFingerprint: "B", sentFingerprint: nil, fingerprint: "F"),
            .queue(fingerprint: "B", waitsForSentWrite: false),
            "an unsent edit keeps the synced copy's fingerprint (1.33.0)"
        )
        XCTAssertEqual(
            Store.deleteAfterQueuedSave(isCreate: false, sentToServer: true, baselineFingerprint: "B", sentFingerprint: "S", fingerprint: "F"),
            .queue(fingerprint: "S", waitsForSentWrite: true)
        )
    }

    /// The replay asks the rulebook with `createdOffline: false`: once the create has landed the delete is applied
    /// (with its tombstone); if it never landed there is nothing to delete.
    func testTheReplayOfThatDeleteIsDecidedByTheRulebook() throws {
        let booking = LogicFixtures.booking(on: try XCTUnwrap(CanonicalBusinessEngine.date(fromDayKey: "2026-11-04")))
        let fingerprint = BookingWritePatch.deleteFingerprint(booking)
        let live = BookingWritePatch.labourValues(booking, deletesClearedFields: false)
        func decide(_ live: [String: Any]?) -> String {
            FirebaseBackend.offlineDeleteDecision(
                documentId: booking.documentKey, collection: "bookings", fingerprint: fingerprint,
                live: live, tombstoned: false, mayDelete: nil, timeZone: "Europe/London"
            )
        }
        XCTAssertEqual(decide(live), "apply")
        XCTAssertEqual(decide(nil), "alreadyGone")
    }

    func testAnOlderQueuedSaveStillDecodesAsNeverSent() throws {
        let booking = LogicFixtures.booking(on: Date())
        let encoded = try JSONEncoder().encode(OfflineSaveBookingPayload(booking: booking))
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        json.removeValue(forKey: "sentToServer")
        json.removeValue(forKey: "sentFingerprint")
        let old = try JSONSerialization.data(withJSONObject: json)
        let payload = try JSONDecoder().decode(OfflineSaveBookingPayload.self, from: old)
        XCTAssertNil(payload.sentToServer)
        XCTAssertNil(payload.sentFingerprint)

        let id = UUID()
        let oldDelete = try XCTUnwrap("{\"bookingId\":\"\(id.uuidString)\"}".data(using: .utf8))
        XCTAssertNil(try JSONDecoder().decode(OfflineDeleteBookingPayload.self, from: oldDelete).waitsForSentWrite)
    }

    // MARK: Item 5: a replayed create never rewrites a booking that is already on the server

    func testAReplayedCreateIsSkippedWhenAlreadyOnTheServer() {
        typealias Replay = OfflineSyncCoordinator.QueuedCreateReplay
        XCTAssertEqual(Replay.decide(isCreate: true, sentToServer: false, existsOnServer: nil), .write, "never left the phone")
        XCTAssertEqual(Replay.decide(isCreate: false, sentToServer: true, existsOnServer: nil), .write, "edits replay their fields")
        XCTAssertEqual(Replay.decide(isCreate: true, sentToServer: true, existsOnServer: nil), .checkServer)
        XCTAssertEqual(Replay.decide(isCreate: true, sentToServer: true, existsOnServer: true), .skipAlreadyOnServer)
        XCTAssertEqual(Replay.decide(isCreate: true, sentToServer: true, existsOnServer: false), .write, "it never landed")
    }
}
