import XCTest
@testable import Project_Planner

/// The legal gate at launch (`AppUser.showsLegalPackGate` over `CanonicalBusinessEngine.legalPackNeedsAcceptance`).
/// The launch placeholder must never flash the terms screen; only a profile read from `users/{uid}` decides.
final class LegalPackGateTests: XCTestCase {
    private func user(policyAccepted: Bool, legalPackVersion: String?) -> AppUser {
        AppUser(
            id: "TEST-uid",
            email: "test-gate@example.com",
            organizationId: "TEST-org",
            role: .manager,
            policyAccepted: policyAccepted,
            legalPackVersion: legalPackVersion
        )
    }

    func testProvisionalUserNeverShowsTheGate() {
        var placeholder = user(policyAccepted: true, legalPackVersion: nil)
        placeholder.isProvisional = true
        XCTAssertFalse(placeholder.showsLegalPackGate)

        var notAccepted = user(policyAccepted: false, legalPackVersion: nil)
        notAccepted.isProvisional = true
        XCTAssertFalse(notAccepted.showsLegalPackGate)
    }

    func testIdentityOnlyFallbackNeverShowsTheGate() {
        var fallback = user(policyAccepted: false, legalPackVersion: nil)
        fallback.parsedWithoutRulebook = true
        XCTAssertFalse(fallback.showsLegalPackGate)
    }

    func testRealUserWithCurrentVersionDoesNotShowTheGate() {
        XCTAssertEqual(CustomerLegalPack.version, "1.1")
        XCTAssertNotNil(
            CanonicalBusinessEngine.legalPackNeedsAcceptance(policyAccepted: true, acceptedVersion: "1.1", currentVersion: "1.1"),
            "the packed script answers legalPackNeedsAcceptance"
        )
        XCTAssertFalse(user(policyAccepted: true, legalPackVersion: "1.1").showsLegalPackGate)
    }

    func testRealUserMissingVersionShowsTheGate() {
        XCTAssertTrue(user(policyAccepted: true, legalPackVersion: nil).showsLegalPackGate)
        XCTAssertTrue(user(policyAccepted: false, legalPackVersion: nil).showsLegalPackGate)
    }

    func testOfflineCacheRoundTripKeepsAcceptedVersionAndDropsProvisional() throws {
        var cached = user(policyAccepted: true, legalPackVersion: "1.1")
        cached.isProvisional = true
        let decoded = try JSONDecoder().decode(AppUser.self, from: JSONEncoder().encode(cached))
        XCTAssertEqual(decoded.legalPackVersion, "1.1")
        XCTAssertFalse(decoded.isProvisional, "not encoded")
        XCTAssertFalse(decoded.showsLegalPackGate)
    }
}
