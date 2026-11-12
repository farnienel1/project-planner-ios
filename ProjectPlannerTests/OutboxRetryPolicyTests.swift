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
        OfflineSyncCoordinator.replayTestSeam = nil
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

    func testANewlyQueuedItemRestartsTheBackoff() {
        XCTAssertTrue(OutboxRetryPolicy.restartsBackoff(previousRetryable: 1, retryable: 2))
        XCTAssertFalse(OutboxRetryPolicy.restartsBackoff(previousRetryable: 2, retryable: 2))
        XCTAssertFalse(OutboxRetryPolicy.restartsBackoff(previousRetryable: 2, retryable: 1))
    }

    /// A trigger that arrives while a pass runs is not dropped: one trailing pass runs after it (callers that arrive
    /// together share it), and every caller returns only after that.
    func testTriggersDuringAPassCoalesceIntoOneTrailingPass() async {
        let flight = SingleFlight()
        let passes = SendCounter()
        let pass: @MainActor () async -> Void = {
            passes.value += 1
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        let first = Task { await flight.run(pass) }
        await Task.yield()
        let second = Task { await flight.run(pass) }
        let third = Task { await flight.run(pass) }
        await first.value
        await second.value
        await third.value
        XCTAssertEqual(passes.value, 2, "the running pass plus one trailing pass")
        XCTAssertFalse(flight.isRunning)
    }

    /// Two real outbox passes at once (e.g. sign-out's "Sync now" beside the background sync) over one queued
    /// material email: it is sent once and leaves the queue.
    func testTwoConcurrentOutboxPassesSendAQueuedEmailOnce() async {
        let outbox = OfflineOutboxStore.shared
        outbox.clearAll()
        defer {
            OfflineSyncCoordinator.replayTestSeam = nil
            outbox.clearAll()
        }
        let request = MaterialOrderRequest(
            projectId: UUID(),
            projectNumber: "C646",
            projectName: "Test site",
            siteAddress: "",
            materials: [],
            requestType: .order,
            sentBy: "Tester",
            recipientContacts: [],
            senderName: "Tester",
            senderEmail: "tester@example.com"
        )
        outbox.enqueueSendMaterialRequest(request, sendRecord: nil, organizationId: "TEST-ORG")
        XCTAssertEqual(outbox.entries.count, 1)

        let sends = SendCounter()
        OfflineSyncCoordinator.replayTestSeam = .init(signedInUserId: "tester-uid") { _, _ in
            try? await Task.sleep(nanoseconds: 80_000_000)
            sends.value += 1
        }
        let backend = FirebaseBackend()
        Self.retained.append(backend)
        let a = Task { await OfflineSyncCoordinator.processOutbox(firebaseBackend: backend, outbox: outbox) }
        let b = Task { await OfflineSyncCoordinator.processOutbox(firebaseBackend: backend, outbox: outbox) }
        let first = await a.value
        let second = await b.value
        XCTAssertEqual(sends.value, 1, "the email is sent once")
        XCTAssertEqual(first.synced + second.synced, 1)
        XCTAssertTrue(outbox.entries.isEmpty)
        XCTAssertTrue(outbox.claimedEntryIds.isEmpty)
    }

    /// Stores are kept alive for the rest of the run (as in WarningInputsReadinessTests).
    private static var retained: [AnyObject] = []
}
