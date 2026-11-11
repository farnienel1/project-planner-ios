import XCTest
@testable import Project_Planner

/// The send list's success state says whether the email went now or waits in the offline outbox.
/// Before, a request queued with no signal also read "Order placed · Sent to N recipients".
@MainActor
final class MaterialsSendConfirmationCopyTests: XCTestCase {
    func testSentOrderReadsOrderPlaced() {
        let state = MaterialsSendListSheet.SendConfirmationState(requestType: .order, itemCount: 3, recipientCount: 2)
        XCTAssertEqual(MaterialsSendConfirmationView.headline(state), "Order placed")
        XCTAssertEqual(MaterialsSendConfirmationView.detail(state), "Sent to 2 recipients · 3 items")
    }

    func testSentQuoteSingular() {
        let state = MaterialsSendListSheet.SendConfirmationState(requestType: .quote, itemCount: 1, recipientCount: 1)
        XCTAssertEqual(MaterialsSendConfirmationView.headline(state), "Quote sent")
        XCTAssertEqual(MaterialsSendConfirmationView.detail(state), "Sent to 1 recipient · 1 item")
    }

    func testQueuedOrderSaysItWaitsForSignal() {
        let state = MaterialsSendListSheet.SendConfirmationState(
            requestType: .order,
            itemCount: 3,
            recipientCount: 2,
            queuedForSync: true
        )
        XCTAssertEqual(MaterialsSendConfirmationView.headline(state), "Order queued")
        XCTAssertEqual(
            MaterialsSendConfirmationView.detail(state),
            "No signal — it will be emailed to 2 recipients when you're back online · 3 items"
        )
    }
}
