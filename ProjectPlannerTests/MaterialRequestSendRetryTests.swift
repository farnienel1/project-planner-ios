import XCTest
@testable import Project_Planner

/// Material quote / order emails sent while online: a dropped connection or a timeout is retried straight away with
/// the same request id (the `sendEmail` function never sends one id twice) before the email is queued for the next
/// sync. Before, any error mentioning "network" queued it at once, even with signal, and it waited for the next flush.
@MainActor
final class MaterialRequestSendRetryTests: XCTestCase {
    private let lost = URLError(.networkConnectionLost)

    func testOnlineConnectionLostIsRetriedTwiceThenQueued() {
        XCTAssertEqual(MaterialRequestSendRetry.action(after: lost, isOnline: true, retriesSoFar: 0), .retry(after: 0.5))
        XCTAssertEqual(MaterialRequestSendRetry.action(after: lost, isOnline: true, retriesSoFar: 1), .retry(after: 1.5))
        XCTAssertEqual(MaterialRequestSendRetry.action(after: lost, isOnline: true, retriesSoFar: 2), .queue)
    }

    func testAMessageThatOnlyMentionsNetworkIsRetriedBeforeQueuing() {
        let error = NSError(domain: "FIRFunctions", code: 14, userInfo: [NSLocalizedDescriptionKey: "A network error occurred"])
        XCTAssertEqual(MaterialRequestSendRetry.action(after: error, isOnline: true, retriesSoFar: 0), .retry(after: 0.5))
        XCTAssertEqual(MaterialRequestSendRetry.action(after: error, isOnline: true, retriesSoFar: 2), .queue)
    }

    func testTimeoutIsRetriedOnceThenFailsAsBefore() {
        let timedOut = MaterialRequestEmailError.timedOut
        XCTAssertEqual(MaterialRequestSendRetry.action(after: timedOut, isOnline: true, retriesSoFar: 0), .retry(after: 0.5))
        // Still unanswered: shown as "did not answer in time" (the Send press keeps its id for a retry), as before.
        XCTAssertEqual(MaterialRequestSendRetry.action(after: timedOut, isOnline: true, retriesSoFar: 1), .fail)
    }

    func testOfflineQueuesAtOnceAndStillSendingQueues() {
        XCTAssertEqual(MaterialRequestSendRetry.action(after: lost, isOnline: false, retriesSoFar: 0), .queue)
        XCTAssertEqual(
            MaterialRequestSendRetry.action(after: MaterialRequestEmailError.stillSending, isOnline: true, retriesSoFar: 0),
            .queue
        )
    }

    func testARefusalIsNeverRetried() {
        let refused = MaterialRequestEmailError.refused(status: 409, reason: "The job number does not match this job.")
        XCTAssertEqual(MaterialRequestSendRetry.action(after: refused, isOnline: true, retriesSoFar: 0), .fail)
        XCTAssertEqual(MaterialRequestSendRetry.action(after: MaterialRequestEmailError.notSignedIn, isOnline: true, retriesSoFar: 0), .fail)
    }

    func testPerformRetriesThenSendsWithoutQueuing() async throws {
        var calls = 0
        var slept: [TimeInterval] = []
        let outcome = try await MaterialRequestSendRetry.perform(isOnline: true, sleep: { slept.append($0) }) {
            calls += 1
            if calls < 3 { throw URLError(.networkConnectionLost) }
        }
        XCTAssertEqual(outcome, .sent)
        XCTAssertEqual(calls, 3)
        XCTAssertEqual(slept, [0.5, 1.5])
    }

    func testPerformQueuesAfterTheQuickRetries() async throws {
        var calls = 0
        let outcome = try await MaterialRequestSendRetry.perform(isOnline: true, sleep: { _ in }) {
            calls += 1
            throw URLError(.notConnectedToInternet)
        }
        XCTAssertEqual(outcome, .queue)
        XCTAssertEqual(calls, 3)
    }

    func testPerformRethrowsARefusalAfterOneCall() async {
        var calls = 0
        do {
            _ = try await MaterialRequestSendRetry.perform(isOnline: true, sleep: { _ in }) {
                calls += 1
                throw MaterialRequestEmailError.refused(status: 403, reason: "You cannot send materials for this job.")
            }
            XCTFail("expected the refusal")
        } catch {
            XCTAssertEqual(error as? MaterialRequestEmailError, .refused(status: 403, reason: "You cannot send materials for this job."))
        }
        XCTAssertEqual(calls, 1)
    }

    func testEveryRetryUsesTheSameRequestId() async throws {
        var ids: [String?] = []
        var request = MaterialOrderRequest(
            projectId: UUID(),
            projectNumber: "J-1",
            projectName: "TEST-Kitchen refit",
            siteAddress: "",
            materials: [],
            requestType: .order,
            sentBy: "Max",
            recipientContacts: [],
            senderName: "Max",
            senderEmail: "max@example.com"
        )
        request.requestId = "6F1D2C3B-4A5E-4F60-8172-93A4B5C6D7E8"
        _ = try await MaterialRequestSendRetry.perform(isOnline: true, sleep: { _ in }) {
            ids.append(request.requestId)
            if ids.count < 2 { throw URLError(.networkConnectionLost) }
        }
        XCTAssertEqual(ids, ["6F1D2C3B-4A5E-4F60-8172-93A4B5C6D7E8", "6F1D2C3B-4A5E-4F60-8172-93A4B5C6D7E8"])
    }

    func testARequestWithoutAnIdIsNeverRetried() async throws {
        XCTAssertEqual(
            MaterialRequestSendRetry.action(after: URLError(.notConnectedToInternet), isOnline: true, retriesSoFar: 0, canRetry: false),
            .queue
        )
        XCTAssertEqual(MaterialRequestSendRetry.action(after: MaterialRequestEmailError.timedOut, isOnline: true, retriesSoFar: 0, canRetry: false), .fail)
        var calls = 0
        let outcome = try await MaterialRequestSendRetry.perform(isOnline: true, canRetry: false, sleep: { _ in }) {
            calls += 1
            throw URLError(.notConnectedToInternet)
        }
        XCTAssertEqual(outcome, .queue)
        XCTAssertEqual(calls, 1)
    }

    func testUnconfirmedIsParsedAndTreatedLikeATimeout() {
        let body = Data(#"{"sent":false,"unconfirmed":true,"error":"The email service did not confirm the send.","failed":["a@x.example"]}"#.utf8)
        let parsed = MaterialRequestEmailPayload.parseResponse(statusCode: 502, data: body)
        XCTAssertEqual(parsed, .failure(.unconfirmed))
        XCTAssertTrue(MaterialRequestEmailError.unconfirmed.errorDescription?.contains("may not have received this yet") == true)
        XCTAssertEqual(MaterialRequestSendRetry.action(after: MaterialRequestEmailError.unconfirmed, isOnline: true, retriesSoFar: 0), .retry(after: 0.5))
        XCTAssertEqual(MaterialRequestSendRetry.action(after: MaterialRequestEmailError.unconfirmed, isOnline: true, retriesSoFar: 1), .fail)
    }
}
