import XCTest
@testable import Project_Planner

@MainActor
final class OfflineOutboxReplayTests: XCTestCase {
    private func entry(attempts: Int) -> OfflineOutboxEntry {
        OfflineOutboxEntry(
            organizationId: "TEST-org",
            operation: .saveBooking,
            entityId: "TEST-booking",
            payload: Data(),
            attemptCount: attempts
        )
    }

    func testAnEntryAtTheAttemptLimitWaitsForRetryOrDiscard() {
        XCTAssertFalse(OfflineSyncCoordinator.reachedAttemptLimit(entry(attempts: OfflineSyncCoordinator.maxAttempts - 1)))
        XCTAssertTrue(OfflineSyncCoordinator.reachedAttemptLimit(entry(attempts: OfflineSyncCoordinator.maxAttempts)))
    }

    func testAnEntryReplaysOnlyForTheAccountThatQueuedIt() {
        var queued = entry(attempts: 0)
        queued.userId = "TEST-uid-a"
        XCTAssertTrue(queued.mayReplay(signedInUserId: "TEST-uid-a"))
        XCTAssertFalse(queued.mayReplay(signedInUserId: "TEST-uid-b"), "another account never replays it")
        XCTAssertFalse(queued.mayReplay(signedInUserId: nil), "nobody signed in replays nothing")
    }

    func testAnOlderPartialUpdateEntryFallsBackToItsPayloadUser() throws {
        let payload = try JSONEncoder().encode(OfflinePartialUpdatePayload(
            documentPath: "users/TEST-uid-a",
            fields: [:],
            isCreate: false,
            userId: "TEST-uid-a"
        ))
        let older = OfflineOutboxEntry(
            organizationId: "TEST-org",
            operation: .saveOwnProfileFields,
            entityId: "profile_TEST-uid-a",
            payload: payload
        )
        XCTAssertEqual(older.queuedByUserId, "TEST-uid-a")
        XCTAssertFalse(older.mayReplay(signedInUserId: "TEST-uid-b"))
    }
}
