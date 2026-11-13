import XCTest
@testable import Project_Planner

/// Queued changes (material order emails among them) are retried on a backing-off timer while something can still
/// retry on its own, and two sync passes never send the same queued item twice.
@MainActor
private final class SendCounter {
    var value = 0
}

@MainActor
private final class RequestIdLog {
    var ids: [String?] = []
}

@MainActor
private final class TaskBox {
    var task: Task<Void, Never>?
}

@MainActor
final class OutboxRetryPolicyTests: XCTestCase {
    override func tearDown() async throws {
        OfflineSyncCoordinator.replayTestSeam = nil
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

    /// A trigger that arrives in the last moment of a pass runs (as the trailing pass); once the pass is over
    /// nothing is left queued and the guard is free for the next caller.
    func testATriggerAsAPassEndsIsNeverLostOrRunLate() async {
        let flight = SingleFlight()
        let passes = SendCounter()
        let late = TaskBox()
        let pass: @MainActor () async -> Void = {
            passes.value += 1
            if passes.value == 1 {
                // Arrives while the first pass is finishing.
                late.task = Task { await flight.run { passes.value += 1 } }
                await Task.yield()
            }
        }
        await flight.run(pass)
        await late.task?.value
        XCTAssertEqual(passes.value, 2, "the late trigger ran")
        XCTAssertFalse(flight.isRunning)
        XCTAssertFalse(flight.hasTrailingPass, "nothing stale left to run later")

        await flight.run { passes.value += 1 }
        XCTAssertEqual(passes.value, 3, "the next caller starts a new pass")
    }

    func testRunWithTimeLimitReturnsWhileASlowPassContinues() async {
        let flight = SingleFlight()
        let passes = SendCounter()
        let finished = await flight.run(timeoutSeconds: 0.3) {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            passes.value += 1
        }
        XCTAssertFalse(finished, "returned at the time limit")
        XCTAssertTrue(flight.isRunning, "the pass keeps going")
        let idleSoon = await flight.waitUntilIdle(timeoutSeconds: 0.2)
        XCTAssertFalse(idleSoon)
        let idleLater = await flight.waitUntilIdle(timeoutSeconds: 5)
        XCTAssertTrue(idleLater)
        XCTAssertEqual(passes.value, 1)
    }

    /// Two real outbox passes at once (e.g. sign-out's "Sync now" beside the background sync) over one queued
    /// material email: it is sent once and leaves the queue.
    func testTwoConcurrentOutboxPassesSendAQueuedEmailOnce() async {
        // An isolated store: the device's own queue is never touched.
        let storageKey = "offline_outbox_test_\(UUID().uuidString)"
        let outbox = OfflineOutboxStore(isolatedStorageKey: storageKey)
        Self.retained.append(outbox)
        defer {
            OfflineSyncCoordinator.replayTestSeam = nil
            UserDefaults.standard.removeObject(forKey: storageKey)
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

    /// A queued material email carries one `sendEmail` request id, fixed when it is queued (the send record's id when
    /// there is one) and sent unchanged on replay, so the function never emails it twice.
    func testAQueuedMaterialEmailKeepsOneRequestIdForEveryReplay() async throws {
        let storageKey = "offline_outbox_test_\(UUID().uuidString)"
        let outbox = OfflineOutboxStore(isolatedStorageKey: storageKey)
        Self.retained.append(outbox)
        defer {
            OfflineSyncCoordinator.replayTestSeam = nil
            UserDefaults.standard.removeObject(forKey: storageKey)
        }
        let request = MaterialOrderRequest(
            projectId: UUID(),
            projectNumber: "C647",
            projectName: "Test site",
            siteAddress: "",
            materials: [],
            requestType: .quote,
            sentBy: "Tester",
            recipientContacts: [],
            senderName: "Tester",
            senderEmail: "tester@example.com"
        )

        // With a send record: the request id is the record's id, as the Send sheet sets it.
        let record = MaterialSendRecord(projectId: request.projectId, requestType: .quote, sentBy: "Tester", recipients: [], lines: [])
        outbox.enqueueSendMaterialRequest(request, sendRecord: record, organizationId: "TEST-ORG")
        let withRecord = try XCTUnwrap(outbox.entries.first)
        let payload = try JSONDecoder().decode(OfflineSendMaterialRequestPayload.self, from: withRecord.payload)
        XCTAssertEqual(payload.request.requestId, record.id.uuidString)
        XCTAssertEqual(withRecord.entityId, record.id.uuidString)
        outbox.removeEntry(id: withRecord.id)

        // Without one: an id is made once at enqueue and stored with the entry; the replay sends exactly that id.
        outbox.enqueueSendMaterialRequest(request, sendRecord: nil, organizationId: "TEST-ORG")
        let entry = try XCTUnwrap(outbox.entries.first)
        let stored = try JSONDecoder().decode(OfflineSendMaterialRequestPayload.self, from: entry.payload)
        let storedId = try XCTUnwrap(stored.request.requestId)
        XCTAssertEqual(entry.entityId, storedId)

        let seen = RequestIdLog()
        OfflineSyncCoordinator.replayTestSeam = .init(signedInUserId: "tester-uid") { sent, _ in
            seen.ids.append(sent.requestId)
        }
        let backend = FirebaseBackend()
        Self.retained.append(backend)
        _ = await OfflineSyncCoordinator.processOutbox(firebaseBackend: backend, outbox: outbox)
        XCTAssertEqual(seen.ids, [storedId])
        XCTAssertTrue(outbox.entries.isEmpty)
    }

    /// The email function says the same request is still being sent (409 `inProgress`): the item stays queued, the
    /// try is not counted, and it is not shown as "Email not sent".
    func testStillSendingKeepsTheEmailQueuedWithoutUsingATry() async throws {
        let storageKey = "offline_outbox_test_\(UUID().uuidString)"
        let outbox = OfflineOutboxStore(isolatedStorageKey: storageKey)
        Self.retained.append(outbox)
        defer {
            OfflineSyncCoordinator.replayTestSeam = nil
            UserDefaults.standard.removeObject(forKey: storageKey)
        }
        let request = MaterialOrderRequest(
            projectId: UUID(),
            projectNumber: "C648",
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
        OfflineSyncCoordinator.replayTestSeam = .init(signedInUserId: "tester-uid") { _, _ in
            throw MaterialRequestEmailError.stillSending
        }
        let backend = FirebaseBackend()
        Self.retained.append(backend)
        let result = await OfflineSyncCoordinator.processOutbox(firebaseBackend: backend, outbox: outbox)
        XCTAssertEqual(result.failed, 0)
        let entry = try XCTUnwrap(outbox.entries.first)
        XCTAssertEqual(entry.attemptCount, 0)
        XCTAssertFalse(entry.lastError?.hasPrefix("Email not sent") ?? false)
    }

    /// Stores are kept alive for the rest of the run (as in WarningInputsReadinessTests).
    private static var retained: [AnyObject] = []
}
