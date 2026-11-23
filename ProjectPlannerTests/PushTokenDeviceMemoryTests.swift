import XCTest
@testable import Project_Planner

/// Owner report 23 Nov: a line manager held 8 tokens and got every push twice. A phone must replace its own previous
/// token when Firebase gives it a new one, and never touch another phone's token.
final class PushTokenDeviceMemoryTests: XCTestCase {
    private final class MemoryStore: PushTokenMemoryStore {
        var values: [String: String] = [:]
        func string(forKey key: String) -> String? { values[key] }
        func set(_ value: String, forKey key: String) { values[key] = value }
    }

    func testRemembersTheLastWrittenTokenPerAccount() {
        let memory = PushTokenDeviceMemory(store: MemoryStore())
        XCTAssertNil(memory.lastWrittenToken(uid: "uidA"))
        memory.recordWritten(token: " tokA ", uid: "uidA")
        memory.recordWritten(token: "tokB", uid: "uidB")
        XCTAssertEqual(memory.lastWrittenToken(uid: "uidA"), "tokA")
        XCTAssertEqual(memory.lastWrittenToken(uid: "uidB"), "tokB")
        memory.recordWritten(token: "", uid: "uidA")
        XCTAssertEqual(memory.lastWrittenToken(uid: "uidA"), "tokA")
    }

    func testANewTokenReplacesOnlyThisPhonesPreviousToken() {
        XCTAssertEqual(PushTokenDeviceMemory.tokensReplacedBy(current: "new", previous: "old"), ["old"])
        XCTAssertEqual(PushTokenDeviceMemory.tokensReplacedBy(current: "same", previous: "same"), [])
        XCTAssertEqual(PushTokenDeviceMemory.tokensReplacedBy(current: "new", previous: nil), [])

        // Stored newest first; the other phone's token ("ipad") stays.
        let next = LaunchStartupPolicy.nextStoredPushTokens(
            existing: ["old", "ipad"],
            currentDeviceToken: "new",
            failedTokens: PushTokenDeviceMemory.tokensReplacedBy(current: "new", previous: "old")
        )
        XCTAssertEqual(next, ["new", "ipad"])
    }

    func testSameTokenAgainChangesNothing() {
        let next = LaunchStartupPolicy.nextStoredPushTokens(
            existing: ["tok", "ipad"],
            currentDeviceToken: "tok",
            failedTokens: PushTokenDeviceMemory.tokensReplacedBy(current: "tok", previous: "tok")
        )
        XCTAssertEqual(next, ["tok", "ipad"])
    }

    func testSignOutRemovesCurrentAndPreviousOnce() {
        XCTAssertEqual(PushTokenDeviceMemory.tokensToRemoveOnSignOut(current: "new", previous: "old"), ["new", "old"])
        XCTAssertEqual(PushTokenDeviceMemory.tokensToRemoveOnSignOut(current: "tok", previous: "tok"), ["tok"])
        XCTAssertEqual(PushTokenDeviceMemory.tokensToRemoveOnSignOut(current: "tok", previous: nil), ["tok"])
    }
}
