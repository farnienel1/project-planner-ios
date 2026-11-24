import XCTest
import FirebaseFirestore
@testable import Project_Planner

/// RULEBOOK 1.86.0 §2 / §5 on iOS through `CanonicalBusinessEngine` (owner decision 24 Nov, "Replace works offline, is
/// queued, and is applied when signal returns"): the replay and refusal decisions (`offlineReplaceReplayDecision`,
/// `offlineReplaceRefusalDecision`) and the outbox item (`OfflineOutboxStore.enqueueReplaceBooking`): one queued item,
/// "Pending sync" on the new booking, the replaced ones hidden, a queued edit's baseline kept, a booking created offline
/// never sent, an edit of the new booking kept inside the item, deleting it before it is sent drops the whole item, undo.
/// Expected values follow the web tests in `lib/canonical/canonical.test.ts` ("1.86.0 offlineReplaceReplayDecision").
@MainActor
final class Rulebook1860OfflineReplaceTests: XCTestCase {
    override func setUp() async throws {
        OfflineOutboxStore.shared.clearAll()
    }

    override func tearDown() async throws {
        OfflineOutboxStore.shared.clearAll()
    }

    private let zone = "Europe/London"

    private let oldLive: [String: Any] = [
        "operativeId": "OP-1", "projectId": "job-1", "date": Timestamp(seconds: 1_793_750_400, nanoseconds: 0),
        "timeSlot": "Full Day", "status": "Confirmed", "notes": "", "isBreakRemoved": false,
    ]

    private func decide(
        fingerprint: String? = nil,
        live: [String: Any]?? = nil,
        tombstoned: Bool = false,
        mayDelete: Bool? = true,
        createdOffline: Bool = false,
        newBookingDeleted: Bool = false,
        newExists: Bool = false
    ) -> RulebookOfflineReplaceResult {
        let liveCopy: [String: Any]? = live ?? oldLive
        let queued = RulebookQueuedReplaceTarget(
            collection: "bookings",
            bookingId: "OLD-1",
            fingerprint: fingerprint ?? BookingWritePatch.stored(oldLive, collection: "bookings"),
            createdOffline: createdOffline
        )
        return CanonicalBusinessEngine.offlineReplaceReplayDecision(
            bookingCollection: "bookings",
            bookingId: "NEW-1",
            queuedReplaced: [queued],
            newBookingDeleted: newBookingDeleted,
            newBookingExists: newExists,
            newBookingTombstoned: false,
            replaced: [RulebookOfflineReplaceLive(collection: "bookings", bookingId: "OLD-1", live: liveCopy, tombstoned: tombstoned, mayDelete: mayDelete)],
            timeZone: zone
        )
    }

    // MARK: Replay decisions

    func testReplayDecisions() {
        XCTAssertEqual(decide().decision, "apply")
        XCTAssertEqual(decide().deletes, [RulebookBookingReplaceRef(collection: "bookings", bookingId: "OLD-1")])
        XCTAssertEqual(decide(mayDelete: nil).decision, "apply", "the rules decide when this device cannot")

        var changed = oldLive
        changed["notes"] = "TEST-moved"
        let refused = decide(live: .some(changed))
        XCTAssertEqual(refused.decision, "refuseChanged", "the whole replace is refused")
        XCTAssertTrue(refused.deletes.isEmpty)
        XCTAssertEqual(refused.message, "Changed on another device — not replaced")
        XCTAssertEqual(decide(fingerprint: "").decision, "refuseChanged", "a blank fingerprint never counts as unchanged")

        XCTAssertEqual(decide(live: .some(nil)).decision, "createOnly", "already gone: create the new booking only")
        XCTAssertEqual(decide(tombstoned: true).decision, "createOnly")
        XCTAssertEqual(decide(mayDelete: false).decision, "refusePermission")
        XCTAssertEqual(decide(newBookingDeleted: true).decision, "dropLocal")
        XCTAssertEqual(decide(newExists: true).decision, "alreadyApplied", "an earlier attempt committed")
        XCTAssertEqual(decide(createdOffline: true).decision, "createOnly", "a replaced booking created offline is never sent")

        XCTAssertEqual(CanonicalBusinessEngine.offlineReplaceRefusalDecision(code: 5), "alreadyGone")
        XCTAssertEqual(CanonicalBusinessEngine.offlineReplaceRefusalDecision(code: 7), "refusePermission")
        XCTAssertEqual(CanonicalBusinessEngine.offlineReplaceRefusalDecision(code: 14), "retry")
        XCTAssertFalse(CanonicalBusinessEngine.offlineReplaceRefusedMessage.isEmpty)
    }

    // MARK: Outbox

    private func target(_ booking: Booking, fingerprint: String? = nil) -> BookingReplaceTarget {
        BookingReplaceTarget(
            ref: RulebookBookingReplaceRef(collection: "bookings", bookingId: booking.documentKey, fingerprint: fingerprint),
            fingerprint: fingerprint ?? BookingWritePatch.deleteFingerprint(booking),
            labour: booking,
            manager: nil
        )
    }

    func testOneQueuedItemShowsTheNewBookingAndHidesTheReplacedOne() throws {
        let outbox = OfflineOutboxStore.shared
        let old = LogicFixtures.booking(on: Date())
        let new = LogicFixtures.booking(on: Date(), slot: .customHours, start: "07:00", end: "12:00", operativeId: old.operativeId)
        XCTAssertNil(outbox.enqueueReplaceBooking(labour: new, replacing: [target(old)], organizationId: "TEST-ORG"))
        XCTAssertEqual(outbox.entries.count, 1)
        let entry = try XCTUnwrap(outbox.entries.first)
        XCTAssertEqual(entry.operation, .replaceBooking)
        XCTAssertEqual(entry.entityId, new.id.uuidString)
        XCTAssertTrue(outbox.hasPendingSync(bookingId: new.id), "Pending sync on the new booking")
        let pending = outbox.pendingLabourBookings(organizationId: "TEST-ORG")
        XCTAssertEqual(pending.saves.map(\.id), [new.id])
        XCTAssertEqual(pending.deletedIds, [old.id])
        XCTAssertEqual(outbox.pendingDeletedBookingIds(collection: "bookings", organizationId: "TEST-ORG"), [old.id])
        let payload = try JSONDecoder().decode(OfflineReplaceBookingPayload.self, from: entry.payload)
        XCTAssertEqual(payload.replaced.first?.fingerprint, BookingWritePatch.deleteFingerprint(old))
        XCTAssertEqual(payload.collection, "bookings")
    }

    func testAQueuedEditOfTheReplacedBookingKeepsItsBaseline() throws {
        let outbox = OfflineOutboxStore.shared
        let synced = LogicFixtures.booking(on: Date())
        var edited = synced
        edited.notes = "TEST-offline edit"
        let baseline = BookingWritePatch.deleteFingerprint(synced)
        outbox.enqueueSaveBooking(edited, changedFields: ["notes"], organizationId: "TEST-ORG", baselineFingerprint: baseline)
        let new = LogicFixtures.booking(on: Date(), operativeId: synced.operativeId)
        XCTAssertNil(outbox.enqueueReplaceBooking(labour: new, replacing: [target(edited)], organizationId: "TEST-ORG"))
        XCTAssertEqual(outbox.entries.count, 1, "the queued edit is taken into the replace")
        let payload = try JSONDecoder().decode(OfflineReplaceBookingPayload.self, from: try XCTUnwrap(outbox.entries.first).payload)
        XCTAssertEqual(payload.replaced.first?.fingerprint, baseline)
        XCTAssertEqual(payload.replaced.first?.createdOffline, false)
        XCTAssertEqual(payload.replaced.first?.queuedEditFields, ["notes"])

        // Undo puts the edit back with its baseline, so it still syncs.
        OfflineSyncCoordinator.undoReplace(entryId: try XCTUnwrap(outbox.entries.first).id)
        let back = try XCTUnwrap(outbox.entries.first)
        XCTAssertEqual(back.operation, .saveBooking)
        let restored = try JSONDecoder().decode(OfflineSaveBookingPayload.self, from: back.payload)
        XCTAssertEqual(restored.changedFields, ["notes"])
        XCTAssertEqual(restored.baselineFingerprint, baseline)
    }

    func testAReplacedBookingCreatedOfflineIsNeverSentAndComesBackOnUndo() throws {
        let outbox = OfflineOutboxStore.shared
        let local = LogicFixtures.booking(on: Date())
        outbox.enqueueSaveBooking(local, changedFields: nil, organizationId: "TEST-ORG")
        let new = LogicFixtures.booking(on: Date(), operativeId: local.operativeId)
        XCTAssertNil(outbox.enqueueReplaceBooking(labour: new, replacing: [target(local)], organizationId: "TEST-ORG"))
        let entry = try XCTUnwrap(outbox.entries.first)
        XCTAssertEqual(outbox.entries.count, 1)
        let payload = try JSONDecoder().decode(OfflineReplaceBookingPayload.self, from: entry.payload)
        XCTAssertEqual(payload.replaced.first?.createdOffline, true)

        OfflineSyncCoordinator.undoReplace(entryId: entry.id)
        XCTAssertEqual(outbox.entries.count, 1, "its create is queued again")
        XCTAssertEqual(outbox.entries.first?.operation, .saveBooking)
        XCTAssertEqual(outbox.entries.first?.entityId, local.id.uuidString)
        XCTAssertFalse(outbox.hasPendingSync(bookingId: new.id))
    }

    func testAnEditOfTheNewBookingStaysInsideTheItem() throws {
        let outbox = OfflineOutboxStore.shared
        let old = LogicFixtures.booking(on: Date())
        var new = LogicFixtures.booking(on: Date(), operativeId: old.operativeId)
        XCTAssertNil(outbox.enqueueReplaceBooking(labour: new, replacing: [target(old)], organizationId: "TEST-ORG"))
        new.notes = "TEST-changed before sync"
        outbox.enqueueSaveBooking(new, changedFields: ["notes"], organizationId: "TEST-ORG")
        XCTAssertEqual(outbox.entries.count, 1)
        let payload = try JSONDecoder().decode(OfflineReplaceBookingPayload.self, from: try XCTUnwrap(outbox.entries.first).payload)
        XCTAssertEqual(payload.labourBooking?.notes, "TEST-changed before sync")
    }

    func testDeletingTheNewBookingBeforeItIsSentDropsTheWholeItem() {
        let outbox = OfflineOutboxStore.shared
        let old = LogicFixtures.booking(on: Date())
        let new = LogicFixtures.booking(on: Date(), operativeId: old.operativeId)
        XCTAssertNil(outbox.enqueueReplaceBooking(labour: new, replacing: [target(old)], organizationId: "TEST-ORG"))
        let result = outbox.enqueueDeleteBooking(new, fingerprint: BookingWritePatch.deleteFingerprint(new), organizationId: "TEST-ORG")
        XCTAssertEqual(result, .droppedLocal)
        XCTAssertTrue(outbox.entries.isEmpty, "nothing is sent")
        XCTAssertTrue(outbox.pendingDeletedBookingIds(collection: "bookings", organizationId: "TEST-ORG").isEmpty)
    }

    func testABookingStillWaitingFromAnEarlierReplaceIsNotReplacedOffline() {
        let outbox = OfflineOutboxStore.shared
        let old = LogicFixtures.booking(on: Date())
        let first = LogicFixtures.booking(on: Date(), operativeId: old.operativeId)
        XCTAssertNil(outbox.enqueueReplaceBooking(labour: first, replacing: [target(old)], organizationId: "TEST-ORG"))
        let second = LogicFixtures.booking(on: Date(), operativeId: old.operativeId)
        XCTAssertEqual(
            outbox.enqueueReplaceBooking(labour: second, replacing: [target(first)], organizationId: "TEST-ORG"),
            OfflineOutboxStore.replaceOfUnsentReplaceMessage
        )
        XCTAssertEqual(outbox.entries.count, 1)
    }

    func testUndoRemovesTheItem() throws {
        let outbox = OfflineOutboxStore.shared
        let old = LogicFixtures.booking(on: Date())
        let new = LogicFixtures.booking(on: Date(), operativeId: old.operativeId)
        XCTAssertNil(outbox.enqueueReplaceBooking(labour: new, replacing: [target(old)], organizationId: "TEST-ORG"))
        let entry = try XCTUnwrap(outbox.queuedReplace(newBookingId: new.id)).entry
        OfflineSyncCoordinator.undoReplace(entryId: entry.id)
        XCTAssertTrue(outbox.entries.isEmpty)
        XCTAssertTrue(outbox.pendingDeletedBookingIds(collection: "bookings", organizationId: "TEST-ORG").isEmpty)
    }
}
