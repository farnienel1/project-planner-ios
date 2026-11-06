import XCTest
@testable import Project_Planner

/// RULEBOOK 1.32.4 §16: the auth-claims marker (`users/{uid}/private/authClaims` `{ v }`) makes the phone refresh its
/// ID token when the token's claims are older (`authClaimsTokenIsStale`), then reload the open organisation. A refused
/// marker read (rules not yet published) is ignored. Engine: `authClaimsMarkerPath`, `authClaimsTokenIsStale`.
@MainActor
final class AuthClaimsRefreshTests: XCTestCase {
    private func tokenClaims(stamp: Int) -> [String: Any] {
        let organizations: [String: Any] = ["org-a": ["admin", "admin", "c"] as [Any]]
        let pp: [String: Any] = ["v": 1, "s": stamp, "o": organizations, "u": [] as [Any]]
        return ["pp": pp, "email": "test-person@example.com"]
    }

    private final class SignOutFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var raised = false
        var value: Bool { lock.lock(); defer { lock.unlock() }; return raised }
        func set() { lock.lock(); raised = true; lock.unlock() }
    }

    private final class Counters {
        var reads = 0
        var refreshes = 0
        var reloads: [Double] = []
    }

    private func coordinator(
        claims: [String: Any]?,
        counters: Counters,
        refreshFails: Bool = false
    ) -> AuthClaimsMarkerCoordinator {
        AuthClaimsMarkerCoordinator(
            readClaims: {
                counters.reads += 1
                return claims
            },
            forceRefresh: {
                counters.refreshes += 1
                if refreshFails { throw NSError(domain: "test", code: 1) }
            },
            didRefresh: { counters.reloads.append($0) }
        )
    }

    // MARK: - Engine wrapper

    func testMarkerPathComesFromTheRulebook() {
        XCTAssertEqual(CanonicalBusinessEngine.authClaimsMarkerPath(uid: "uid-1"), "users/uid-1/private/authClaims")
        XCTAssertEqual(CanonicalBusinessEngine.authClaimsMarkerPath(uid: " uid-1 "), "users/uid-1/private/authClaims")
        XCTAssertNil(CanonicalBusinessEngine.authClaimsMarkerPath(uid: "  "))
    }

    func testTokenIsStaleComesFromTheRulebook() {
        let claims = tokenClaims(stamp: 5)
        XCTAssertEqual(CanonicalBusinessEngine.authClaimsTokenIsStale(markerVersion: 6, tokenClaims: claims), true)
        XCTAssertEqual(CanonicalBusinessEngine.authClaimsTokenIsStale(markerVersion: 5, tokenClaims: claims), false)
        XCTAssertEqual(CanonicalBusinessEngine.authClaimsTokenIsStale(markerVersion: 5, tokenClaims: ["email": "x"]), true,
                       "a token without claims is stale")
        XCTAssertEqual(CanonicalBusinessEngine.authClaimsTokenIsStale(markerVersion: 5, tokenClaims: nil), true)
    }

    // MARK: - Marker snapshots

    func testNewerMarkerTriggersExactlyOneForcedRefreshAndReload() async {
        let counters = Counters()
        let sut = coordinator(claims: tokenClaims(stamp: 5), counters: counters)
        let refreshed = await sut.markerChanged(version: 6)
        XCTAssertTrue(refreshed)
        // The same `v` again (cache then server snapshot) does not refresh twice.
        let again = await sut.markerChanged(version: 6)
        XCTAssertFalse(again)
        XCTAssertEqual(counters.refreshes, 1)
        XCTAssertEqual(counters.reloads, [6])
    }

    func testEqualMarkerDoesNotRefresh() async {
        let counters = Counters()
        let sut = coordinator(claims: tokenClaims(stamp: 5), counters: counters)
        let refreshed = await sut.markerChanged(version: 5)
        XCTAssertFalse(refreshed)
        XCTAssertEqual(counters.reads, 1)
        XCTAssertEqual(counters.refreshes, 0)
        XCTAssertTrue(counters.reloads.isEmpty)
    }

    func testMissingOrNonNumericMarkerDoesNothing() async {
        let counters = Counters()
        let sut = coordinator(claims: tokenClaims(stamp: 5), counters: counters)
        let missing = await sut.markerChanged(version: AuthClaimsMarkerCoordinator.markerVersion(from: nil))
        let flag = await sut.markerChanged(version: AuthClaimsMarkerCoordinator.markerVersion(from: ["v": true]))
        let text = await sut.markerChanged(version: AuthClaimsMarkerCoordinator.markerVersion(from: ["v": "6"]))
        XCTAssertFalse(missing || flag || text)
        XCTAssertEqual(counters.reads, 0)
        XCTAssertEqual(counters.refreshes, 0)
        XCTAssertEqual(AuthClaimsMarkerCoordinator.markerVersion(from: ["v": NSNumber(value: 7)]), 7)
    }

    func testUnreadableTokenClaimsRefresh() async {
        let counters = Counters()
        let sut = coordinator(claims: nil, counters: counters)
        let refreshed = await sut.markerChanged(version: 3)
        XCTAssertTrue(refreshed, "claims that could not be read are refreshed, as web does")
        XCTAssertEqual(counters.refreshes, 1)
    }

    func testFailedRefreshDoesNotReload() async {
        let counters = Counters()
        let sut = coordinator(claims: tokenClaims(stamp: 5), counters: counters, refreshFails: true)
        let refreshed = await sut.markerChanged(version: 6)
        XCTAssertFalse(refreshed)
        XCTAssertEqual(counters.refreshes, 1)
        XCTAssertTrue(counters.reloads.isEmpty)
    }

    // MARK: - Refused marker read

    func testRefusedMarkerReadDoesNotSignOutOrShowAnError() {
        let counters = Counters()
        let sut = coordinator(claims: tokenClaims(stamp: 5), counters: counters)
        let refused = NSError(domain: "FIRFirestoreErrorDomain", code: 7)
        sut.markerReadFailed(refused)
        XCTAssertEqual(counters.reads + counters.refreshes, 0)
        XCTAssertTrue(counters.reloads.isEmpty)

        let backend = FirebaseBackend()
        backend.isAuthenticated = true
        let signedOut = SignOutFlag()
        let observer = NotificationCenter.default.addObserver(forName: .userDidSignOut, object: nil, queue: nil) { _ in
            signedOut.set()
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        backend.authClaimsMarkerReadFailed(refused)
        XCTAssertTrue(backend.isAuthenticated, "a refused marker read does not sign out")
        XCTAssertNil(backend.errorMessage, "a refused marker read shows no error")
        XCTAssertFalse(signedOut.value)
    }
}
