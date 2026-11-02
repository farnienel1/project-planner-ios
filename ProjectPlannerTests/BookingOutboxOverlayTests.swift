import XCTest
@testable import Project_Planner

/// RULEBOOK §2: a booking created or edited offline stays visible ("Pending sync") when a server snapshot
/// arrives before the outbox replays; a queued delete stays gone.
@MainActor
final class BookingOutboxOverlayTests: XCTestCase {
    private func booking(_ slot: TimeSlot = .fullDay) -> Booking {
        Booking(operativeId: UUID(), projectId: UUID(), date: Date(), timeSlot: slot, bookedBy: "TEST-admin")
    }

    func testQueuedCreateIsAddedToServerSnapshot() {
        let stored = booking()
        let queued = booking()
        let rows = BookingStore.overlayingPendingOutbox([stored], pendingSaves: [queued], pendingDeletes: [])
        XCTAssertEqual(Set(rows.map(\.id)), [stored.id, queued.id])
    }

    func testQueuedEditReplacesServerCopy() {
        let stored = booking(.fullDay)
        var edited = stored
        edited.timeSlot = .morning
        let rows = BookingStore.overlayingPendingOutbox([stored], pendingSaves: [edited], pendingDeletes: [])
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.timeSlot, .morning)
    }

    func testQueuedDeleteStaysHidden() {
        let stored = booking()
        let other = booking()
        let rows = BookingStore.overlayingPendingOutbox([stored, other], pendingSaves: [], pendingDeletes: [stored.id])
        XCTAssertEqual(rows.map(\.id), [other.id])
    }

    func testNothingQueuedKeepsServerRows() {
        let stored = [booking(), booking()]
        XCTAssertEqual(BookingStore.overlayingPendingOutbox(stored, pendingSaves: [], pendingDeletes: []), stored)
    }
}
