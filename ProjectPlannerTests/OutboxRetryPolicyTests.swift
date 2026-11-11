import XCTest
@testable import Project_Planner

/// The offline outbox (queued material order emails among others) is retried on a timer while anything is
/// pending, not only when the network path changes or the app returns to the foreground.
@MainActor
final class OutboxRetryPolicyTests: XCTestCase {
    func testRetriesEveryMinuteWhileSomethingIsPending() {
        XCTAssertEqual(OutboxRetryPolicy.interval, 60)
        XCTAssertTrue(OutboxRetryPolicy.shouldKeepRetrying(pendingCount: 1))
        XCTAssertFalse(OutboxRetryPolicy.shouldKeepRetrying(pendingCount: 0))
    }

    func testTimerPassRetriesOnlyOnlineAndNotWhileSyncing() {
        XCTAssertTrue(OutboxRetryPolicy.shouldRetryNow(pendingCount: 2, isOnline: true, isSyncing: false))
        XCTAssertFalse(OutboxRetryPolicy.shouldRetryNow(pendingCount: 2, isOnline: false, isSyncing: false))
        XCTAssertFalse(OutboxRetryPolicy.shouldRetryNow(pendingCount: 2, isOnline: true, isSyncing: true))
        XCTAssertFalse(OutboxRetryPolicy.shouldRetryNow(pendingCount: 0, isOnline: true, isSyncing: false))
    }
}
