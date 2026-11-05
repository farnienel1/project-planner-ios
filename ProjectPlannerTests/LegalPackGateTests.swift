import XCTest
import FirebaseFirestore
@testable import Project_Planner

/// The legal gate at launch (`AppUser.showsLegalPackGate` over `CanonicalBusinessEngine.legalPackNeedsAcceptance`).
/// The launch placeholder must never flash the terms screen; only a profile read from `users/{uid}` decides.
@MainActor
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
        XCTAssertFalse(placeholder.showsLegalPackGate(isOnline: true))

        var notAccepted = user(policyAccepted: false, legalPackVersion: nil)
        notAccepted.isProvisional = true
        XCTAssertFalse(notAccepted.showsLegalPackGate(isOnline: true))
    }

    func testIdentityOnlyFallbackNeverShowsTheGate() {
        var fallback = user(policyAccepted: false, legalPackVersion: nil)
        fallback.parsedWithoutRulebook = true
        XCTAssertFalse(fallback.showsLegalPackGate(isOnline: true))
    }

    func testRealUserWithCurrentVersionDoesNotShowTheGate() {
        XCTAssertEqual(CustomerLegalPack.version, "1.1")
        XCTAssertNotNil(
            CanonicalBusinessEngine.legalPackNeedsAcceptance(policyAccepted: true, acceptedVersion: "1.1", currentVersion: "1.1"),
            "the packed script answers legalPackNeedsAcceptance"
        )
        XCTAssertFalse(user(policyAccepted: true, legalPackVersion: "1.1").showsLegalPackGate(isOnline: true))
    }

    func testRealUserMissingVersionShowsTheGate() {
        XCTAssertTrue(user(policyAccepted: true, legalPackVersion: nil).showsLegalPackGate(isOnline: true))
        XCTAssertTrue(user(policyAccepted: false, legalPackVersion: nil).showsLegalPackGate(isOnline: true))
    }

    func testOfflineCacheRoundTripKeepsAcceptedVersionAndDropsProvisional() throws {
        var cached = user(policyAccepted: true, legalPackVersion: "1.1")
        cached.isProvisional = true
        let decoded = try JSONDecoder().decode(AppUser.self, from: JSONEncoder().encode(cached))
        XCTAssertEqual(decoded.legalPackVersion, "1.1")
        XCTAssertFalse(decoded.isProvisional, "not encoded")
        XCTAssertFalse(decoded.showsLegalPackGate(isOnline: true))
    }

    // MARK: - The acceptance write (web `LegalPackGate` shape)

    func testAcceptanceWriteStoresPolicyAcceptedAndTheWebShape() throws {
        let at = Date(timeIntervalSince1970: 1_793_000_000)
        let write = FirebaseBackend.legalPackAcceptanceWrite(
            userId: "TEST-uid",
            email: "test-gate@example.com",
            organizationName: "TEST Org",
            authorisedToBind: true,
            acceptedAt: at,
            signedInUserId: "TEST-uid"
        )
        XCTAssertEqual(write["policyAccepted"] as? Bool, true, "legalPackNeedsAcceptance reads policyAccepted first")
        XCTAssertEqual((write["policyAcceptedAt"] as? Timestamp)?.dateValue(), at)
        XCTAssertEqual(write["legalPackVersion"] as? String, CustomerLegalPack.version)
        XCTAssertEqual((write["legalPackAcceptedAt"] as? Timestamp)?.dateValue(), at)
        let acceptances = try XCTUnwrap(write["legalAcceptances"] as? [String: Any])
        for key in ["saas", "dpa", "aup", "privacy", "authorisedToBind"] {
            XCTAssertEqual(acceptances[key] as? Bool, true, key)
        }
        XCTAssertEqual(acceptances["organizationName"] as? String, "TEST Org")
        XCTAssertEqual(acceptances["email"] as? String, "test-gate@example.com")
        XCTAssertEqual(acceptances["userId"] as? String, "TEST-uid")
        XCTAssertNotNil(write["updatedAt"], "write metadata")
        XCTAssertEqual(write["updatedBy"] as? String, "TEST-uid")
        XCTAssertEqual(write["updatedFrom"] as? String, "ios")
        XCTAssertFalse(write.keys.contains { $0.contains(".") }, "a partial update with top-level keys only")
        XCTAssertEqual(
            Set(write.keys),
            ["policyAccepted", "policyAcceptedAt", "legalPackVersion", "legalPackAcceptedAt", "legalAcceptances",
             "updatedAt", "updatedBy", "updatedFrom"],
            "nothing else on users/{uid} is written"
        )
    }

    func testAcceptanceWriteReadBackClosesTheGate() {
        let write = FirebaseBackend.legalPackAcceptanceWrite(
            userId: "TEST-uid", email: "test-gate@example.com", organizationName: "TEST Org",
            authorisedToBind: false, acceptedAt: Date(), signedInUserId: "TEST-uid"
        )
        var stored: [String: Any] = ["email": "test-gate@example.com", "organizationId": "TEST-org", "role": "manager"]
        for (key, value) in write where !(value is FieldValue) { stored[key] = value }
        let parsed = FirebaseBackend.parseAppUserDocument(userId: "TEST-uid", data: stored, annualLeaveDefaults: nil)
        XCTAssertTrue(parsed.policyAccepted)
        XCTAssertEqual(parsed.legalPackVersion, CustomerLegalPack.version)
        XCTAssertFalse(parsed.showsLegalPackGate(isOnline: true))
    }

    /// The bug the owner saw: an iOS-only acceptance stored the version but not `policyAccepted`.
    func testVersionWithoutPolicyAcceptedStillShowsTheGate() {
        let stored: [String: Any] = [
            "email": "test-gate@example.com", "organizationId": "TEST-org", "role": "manager",
            "legalPackVersion": CustomerLegalPack.version,
            "legalAcceptances": ["privacy": true],
        ]
        let parsed = FirebaseBackend.parseAppUserDocument(userId: "TEST-uid", data: stored, annualLeaveDefaults: nil)
        XCTAssertTrue(parsed.showsLegalPackGate(isOnline: true), "read side unchanged until web lib/canonical decides")
    }

    // MARK: - Cached copy, then server copy

    func testStaleCachedCopyWaitsForTheServerWhileOnline() {
        var cached = user(policyAccepted: false, legalPackVersion: nil)
        cached.readFromLocalCache = true
        XCTAssertFalse(cached.showsLegalPackGate(isOnline: true), "an older cached users/{uid} must not flash the gate")

        let server = user(policyAccepted: true, legalPackVersion: CustomerLegalPack.version)
        XCTAssertFalse(server.showsLegalPackGate(isOnline: true), "the server copy says accepted")
    }

    func testServerCopyThatNeedsAcceptanceShowsTheGate() {
        var cached = user(policyAccepted: true, legalPackVersion: CustomerLegalPack.version)
        cached.readFromLocalCache = true
        XCTAssertFalse(cached.showsLegalPackGate(isOnline: true))

        let server = user(policyAccepted: false, legalPackVersion: nil)
        XCTAssertTrue(server.showsLegalPackGate(isOnline: true), "a genuinely unaccepted account still sees the gate")
    }

    func testOfflineTheCachedCopyDecides() {
        var cached = user(policyAccepted: false, legalPackVersion: nil)
        cached.readFromLocalCache = true
        XCTAssertTrue(cached.showsLegalPackGate(isOnline: false))
    }

    // MARK: - Session and roster copies keep the users/{uid} acceptance

    func testCompanySessionProfileKeepsTheUsersDocumentAcceptance() {
        let usersDoc = user(policyAccepted: true, legalPackVersion: CustomerLegalPack.version)
        // An orgMemberships row carries no acceptance; parsed alone it reads not accepted.
        let membership = FirebaseBackend.parseAppUserDocument(
            userId: "TEST-uid",
            data: ["email": "test-gate@example.com", "organizationId": "TEST-other-org", "role": "manager"],
            annualLeaveDefaults: nil
        )
        XCTAssertTrue(membership.showsLegalPackGate(isOnline: true), "the root cause of the flash in another company")
        let session = membership.carryingLegalAcceptance(from: usersDoc)
        XCTAssertFalse(session.showsLegalPackGate(isOnline: true))
        XCTAssertEqual(session.legalPackVersion, CustomerLegalPack.version)
    }

    func testSnapshotMemoForwardsOnlyDataOrSourceChanges() {
        let memo = CurrentUserSnapshotMemo()
        let data: [String: Any] = ["policyAccepted": false]
        XCTAssertTrue(memo.shouldForward(data: data, fromCache: true), "first snapshot")
        XCTAssertFalse(memo.shouldForward(data: data, fromCache: true), "metadata-only change")
        XCTAssertTrue(memo.shouldForward(data: data, fromCache: false), "server confirmed identical data")
        XCTAssertTrue(memo.shouldForward(data: ["policyAccepted": true], fromCache: false), "data changed")
        memo.reset()
        XCTAssertTrue(memo.shouldForward(data: ["policyAccepted": true], fromCache: false))
    }
}
