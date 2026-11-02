import XCTest
import FirebaseFirestore
@testable import Project_Planner

/// RULEBOOK §2: annual leave requests, own profile fields and own notification toggles are queued offline as
/// partial updates. These lock the outbox value conversion and payload codec those queues rely on.
@MainActor
final class OfflineOwnWritesTests: XCTestCase {
    func testWriteMapValuesConvertToOutboxValues() {
        let day = Date(timeIntervalSince1970: 1_800_000_000)
        let fields: [String: Any] = [
            "cancellationRequestedAt": Timestamp(date: day),
            "cancellationRequestedByUserId": "TEST-uid",
            "decisionNote": NSNull(),
            "flag": true,
            "count": 3,
        ]
        let converted = OfflineFieldValue.fields(fields)
        XCTAssertEqual(converted?["cancellationRequestedAt"], .date(day))
        XCTAssertEqual(converted?["cancellationRequestedByUserId"], .string("TEST-uid"))
        XCTAssertEqual(converted?["decisionNote"], .null)
        XCTAssertEqual(converted?["flag"], .bool(true))
        XCTAssertEqual(converted?["count"], .number(3))
    }

    func testSentinelValuesAreNotQueued() {
        XCTAssertNil(OfflineFieldValue.fields(["updatedAt": FieldValue.serverTimestamp()]))
    }

    func testServerTimestampRoundTrips() throws {
        let data = try JSONEncoder().encode(OfflineFieldValue.serverTimestamp)
        XCTAssertEqual(try JSONDecoder().decode(OfflineFieldValue.self, from: data), .serverTimestamp)
    }

    func testOlderPayloadsStillStampWriteMetadata() throws {
        let legacy = #"{"documentPath":"users/TEST-uid","fields":{},"isCreate":false,"userId":"TEST-uid"}"#
        let payload = try JSONDecoder().decode(OfflinePartialUpdatePayload.self, from: Data(legacy.utf8))
        XCTAssertNil(payload.stampsWriteMetadata)
    }
}
