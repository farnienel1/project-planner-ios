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
}
