import XCTest
@testable import Project_Planner

/// RULEBOOK 1.84.0 §32 (D7): pseudonymous error reports with no message text. The fields, sanitiser, id and throttle are the packed rulebook's;
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

    func testCreateFieldsHoldNoMessageText() {
        let message = "❌ Error saving material: Order is locked by Jane Smith (jane@example.com)"
        let fields = CanonicalBusinessEngine.callJSON("clientErrorCreateFields", arguments: [[
            "platform": "ios",
            "source": "caught",
            "name": "LoggedError",
            "message": message,
            "messageHash": ClientErrorReporter.sha256Hex(message),
            "file": "Project_Planner/MaterialsView.swift",
            "function": "saveMaterial(_:for:)",
            "route": "/ios",
            "build": "1.84 (12)",
            "organizationId": "org_1",
            "nowMs": 1_764_000_000_000.0,
        ] as [String: Any]]) as? [String: Any]
        let text = String(describing: fields ?? [:])
        XCTAssertFalse(text.contains("Jane"))
        XCTAssertFalse(text.contains("@"))
        XCTAssertEqual(fields?["messageKey"] as? String, "other")
        XCTAssertEqual(fields?["where"] as? String, "MaterialsView.swift saveMaterial")
        XCTAssertEqual(fields?["kind"] as? String, "LoggedError")
        XCTAssertEqual(fields?["messageHash"] as? String, ClientErrorReporter.sha256Hex(message))
        XCTAssertEqual(CanonicalBusinessEngine.callJSON("clientErrorNextSlot", arguments: [19]) as? NSNumber, nil)
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
