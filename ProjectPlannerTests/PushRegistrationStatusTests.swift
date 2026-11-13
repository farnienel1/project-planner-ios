import XCTest
@testable import Project_Planner

/// Settings → My notifications → Notifications check reads `PushRegistrationStatus`. The token is shown only as a
/// suffix, a sign-out clears the saved-token state and a blank token is never kept.
@MainActor
final class PushRegistrationStatusTests: XCTestCase {
    func testTokenSuffixNeverShowsTheWholeToken() {
        XCTAssertEqual(PushRegistrationStatus.tokenSuffix("abcdefghijklmnop"), "…klmnop")
        XCTAssertEqual(PushRegistrationStatus.tokenSuffix(" "), "")
        XCTAssertEqual(PushRegistrationStatus.tokenSuffix(nil), "")
    }

    func testBlankTokenIsIgnoredAndSignOutClearsSavedState() {
        let status = PushRegistrationStatus.shared
        status.recordFCMToken("token-under-test-123456")
        status.recordFCMToken("   ")
        XCTAssertEqual(status.latestFCMToken, "token-under-test-123456")
        status.recordSaveFailure("offline")
        XCTAssertEqual(status.lastSaveError, "offline")
        status.recordSaved(at: Date(timeIntervalSince1970: 1_800_000_000))
        XCTAssertNil(status.lastSaveError)
        XCTAssertNotNil(status.lastSavedAt)
        status.resetForSignOut()
        XCTAssertNil(status.lastSavedAt)
        XCTAssertEqual(status.latestFCMToken, "token-under-test-123456", "the phone's token outlives the account")
    }

    func testApnsFailureIsRecorded() {
        let status = PushRegistrationStatus.shared
        status.recordAPNsFailure("no valid aps-environment entitlement string found for application")
        XCTAssertEqual(status.apnsRegistered, false)
        XCTAssertNotNil(status.apnsError)
        status.recordAPNsRegistered()
        XCTAssertEqual(status.apnsRegistered, true)
        XCTAssertNil(status.apnsError)
    }
}
