import XCTest
@testable import Project_Planner

/// RULEBOOK §1 `LIVE_COLLECTIONS` ("Pay history `operativeDayRateHistory` listens while open") and 1.26.0 / 1.27.0 §8
/// `rateHistoryQueryPlan`: the listeners Edit User holds for one person's pay history
/// (`FirebaseBackend.rateHistoryPersonListenQueries`), mirroring web `watchOperativeDayRateHistory`.
@MainActor
final class PayHistoryLiveListenerTests: XCTestCase {
    func testWholeCollectionWhilePrivatePayIsOffOrTheViewerSeesEveryPay() {
        let queries = FirebaseBackend.rateHistoryPersonListenQueries(plan: .all, userIds: ["U1"], operativeRowIds: ["ROW1"])
        XCTAssertEqual(queries.map(\.key), ["all"])
    }

    func testOneListenerPerIdOfThePersonThatThePlanLists() {
        let plan = RulebookRateHistoryPlan.people(["U1", "invite-old", "U-OTHER"], operativeIds: ["ROW-CATALOGUE"])
        let queries = FirebaseBackend.rateHistoryPersonListenQueries(
            plan: plan,
            // The person's ids in another letter case still match the plan's stored ids; ids the plan does not list
            // (another person's, or one this viewer may not read) get no listener.
            userIds: ["u1", "INVITE-OLD", "U-NOT-IN-PLAN"],
            operativeRowIds: ["row-catalogue", "ROW-ACCOUNT"]
        )
        XCTAssertEqual(queries.map(\.key), ["u:U1", "u:invite-old", "o:ROW-CATALOGUE"])
    }

    func testAPersonWhosePayTheViewerMayNotSeeGetsNoListener() {
        let plan = RulebookRateHistoryPlan.people(["ME"], operativeIds: [])
        XCTAssertTrue(FirebaseBackend.rateHistoryPersonListenQueries(plan: plan, userIds: ["U1"], operativeRowIds: []).isEmpty)
    }

    func testLiveRowsReadThroughTheRulebookReader() throws {
        // One snapshot's rows go through `parsePayRateHistoryDocuments`, as the screen's load does.
        let rows: LiveDocumentRows = [
            (id: "H1", data: ["userId": "U1", "dayRate": 200, "payBasis": "day", "effectiveAt": "2026-11-02T00:00:00Z"]),
            (id: "H2", data: ["userId": "U1", "dayRate": 220, "payBasis": "day", "effectiveAt": "2026-11-09T00:00:00Z"]),
        ]
        let entries = FirebaseBackend.operativeDayRateHistory(fromDocuments: rows).entries(userIds: ["U1"], operativeIds: [])
        XCTAssertEqual(entries.map(\.dayRate), [200, 220])
    }
}
