import XCTest
@testable import Project_Planner

/// RULEBOOK 1.84.0 §32 (D7): anonymous error reports. The fields, sanitiser, id and throttle are the packed rulebook's;
/// the phone only hashes (CryptoKit) — the hash must be the lower-case hex SHA-256 the security rules recompute.
final class ClientErrorReporterTests: XCTestCase {
    func testHashMatchesTheRulesHash() {
        // sha256("uid-1|20416") — the same value web's SubtleCrypto and the rules' hashing.sha256 give.
        let input = CanonicalBusinessEngine.callJSON("clientErrorHashInput", arguments: ["uid-1", 20416]) as? String
        XCTAssertEqual(input, "uid-1|20416")
        let hex = ClientErrorReporter.sha256Hex("abc")
        XCTAssertEqual(hex, "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        let id = CanonicalBusinessEngine.callJSON("clientErrorDocId", arguments: [hex, 19]) as? String
        XCTAssertEqual(id, "\(hex)_19")
        XCTAssertNil(CanonicalBusinessEngine.callJSON("clientErrorDocId", arguments: [hex, 20]) as? String)
    }

    func testCreateFieldsStripPersonalData() {
        let fields = CanonicalBusinessEngine.callJSON("clientErrorCreateFields", arguments: [[
            "platform": "ios",
            "source": "caught",
            "message": "❌ Error saving for jane@example.com doc 123e4567-e89b-12d3-a456-426614174000",
            "route": "/ios",
            "build": "1.84 (12)",
            "organizationId": "org_1",
            "nowMs": 1_764_000_000_000.0,
        ]]) as? [String: Any]
        let message = fields?["message"] as? String ?? ""
        XCTAssertFalse(message.contains("@"))
        XCTAssertFalse(message.contains("123e4567"))
        XCTAssertEqual(fields?["platform"] as? String, "ios")
        XCTAssertEqual(fields?["organizationId"] as? String, "org_1")
    }

    func testThrottleCapsAtTwentyADay() {
        var state: [String: Any] = ["dayIndex": 1, "used": 19, "sent": [] as [String]]
        let last = CanonicalBusinessEngine.callJSON("clientErrorThrottle", arguments: [state, ["dayIndex": 1, "signature": "a"]]) as? [String: Any]
        XCTAssertEqual(last?["send"] as? Bool, true)
        state = last?["state"] as? [String: Any] ?? [:]
        let over = CanonicalBusinessEngine.callJSON("clientErrorThrottle", arguments: [state, ["dayIndex": 1, "signature": "b"]]) as? [String: Any]
        XCTAssertEqual(over?["send"] as? Bool, false)
    }
}
