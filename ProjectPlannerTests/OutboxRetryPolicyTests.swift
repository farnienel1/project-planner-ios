import XCTest
@testable import Project_Planner

/// Queued changes (material order emails among them) are retried on a backing-off timer while something can still
/// retry on its own, and two sync passes never send the same queued item twice.
@MainActor
private final class SendCounter {
    var value = 0
}

@MainActor
final class OutboxRetryPolicyTests: XCTestCase {
    override func tearDown() async throws {
        for id in OfflineOutboxStore.shared.claimedEntryIds {
            OfflineOutboxStore.shared.releaseEntryClaim(id: id)
        }
    }

    func testTimerBacksOffOneTwoFiveThenTenMinutes() {
        XCTAssertEqual(OutboxRetryPolicy.delay(beforePass: 0), 60)
        XCTAssertEqual(OutboxRetryPolicy.delay(beforePass: 1), 120)
        XCTAssertEqual(OutboxRetryPolicy.delay(beforePass: 2), 300)
        XCTAssertEqual(OutboxRetryPolicy.delay(beforePass: 3), 600)
        XCTAssertEqual(OutboxRetryPolicy.delay(beforePass: 40), 600)
    }

    func testTimerRunsOnlyWhileSomethingCanStillRetry() {
        XCTAssertTrue(OutboxRetryPolicy.shouldKeepRetrying(retryableOutboxCount: 1, pendingSiteAudits: 0))
        XCTAssertTrue(OutboxRetryPolicy.shouldKeepRetrying(retryableOutboxCount: 0, pendingSiteAudits: 1))
        // Only stuck entries (at the attempt limit, or another account's) left: 0 retryable, timer stops.
        XCTAssertFalse(OutboxRetryPolicy.shouldKeepRetrying(retryableOutboxCount: 0, pendingSiteAudits: 0))
    }

    func testTimerPassRetriesOnlyOnlineAndNotWhileSyncing() {
        XCTAssertTrue(OutboxRetryPolicy.shouldRetryNow(retryableOutboxCount: 2, pendingSiteAudits: 0, isOnline: true, isSyncing: false))
        XCTAssertFalse(OutboxRetryPolicy.shouldRetryNow(retryableOutboxCount: 2, pendingSiteAudits: 0, isOnline: false, isSyncing: false))
        XCTAssertFalse(OutboxRetryPolicy.shouldRetryNow(retryableOutboxCount: 2, pendingSiteAudits: 0, isOnline: true, isSyncing: true))
        XCTAssertFalse(OutboxRetryPolicy.shouldRetryNow(retryableOutboxCount: 0, pendingSiteAudits: 0, isOnline: true, isSyncing: false))
    }

    /// Two sync triggers at once (e.g. the timer and Retry now): the second waits for the first; one send.
    func testTwoConcurrentSyncCallsRunOnePass() async {
        let flight = SingleFlight()
        let sends = SendCounter()
        let pass: @MainActor () async -> Void = {
            sends.value += 1
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        let first = Task { await flight.run(pass) }
        let second = Task { await flight.run(pass) }
        await first.value
        await second.value
        XCTAssertEqual(sends.value, 1)
        XCTAssertFalse(flight.isRunning)
    }

    /// Two outbox passes over the same queued material email (e.g. sign-out's own pass beside the background sync):
    /// only the pass that claims the entry sends it.
    func testTwoConcurrentOutboxPassesSendAQueuedEmailOnce() async {
        let outbox = OfflineOutboxStore.shared
        let queuedEmail = UUID()
        let sends = SendCounter()
        let outboxPass: @MainActor () async -> Void = {
            guard outbox.claimEntryForReplay(id: queuedEmail) else { return }
            defer { outbox.releaseEntryClaim(id: queuedEmail) }
            try? await Task.sleep(nanoseconds: 50_000_000)
            sends.value += 1
        }
        let a = Task { await outboxPass() }
        let b = Task { await outboxPass() }
        await a.value
        await b.value
        XCTAssertEqual(sends.value, 1)
        XCTAssertTrue(outbox.claimEntryForReplay(id: queuedEmail), "released after the pass")
        outbox.releaseEntryClaim(id: queuedEmail)
    }
}
