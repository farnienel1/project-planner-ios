import XCTest
import FirebaseFirestore
@testable import Project_Planner

/// The legal gate at launch (`AppUser.legalGateState` over `CanonicalBusinessEngine.legalPackNeedsAcceptance`).
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
        XCTAssertEqual(placeholder.legalGateState(isOnline: true, cacheGraceExpired: false), .open)

        var notAccepted = user(policyAccepted: false, legalPackVersion: nil)
        notAccepted.isProvisional = true
        XCTAssertEqual(notAccepted.legalGateState(isOnline: true, cacheGraceExpired: false), .open)
    }

    func testIdentityOnlyFallbackNeverShowsTheGate() {
        var fallback = user(policyAccepted: false, legalPackVersion: nil)
        fallback.parsedWithoutRulebook = true
        XCTAssertEqual(fallback.legalGateState(isOnline: true, cacheGraceExpired: false), .open)
    }

    func testRealUserWithCurrentVersionDoesNotShowTheGate() {
        XCTAssertEqual(CustomerLegalPack.version, "1.1")
        XCTAssertNotNil(
            CanonicalBusinessEngine.legalPackNeedsAcceptance(policyAccepted: true, acceptedVersion: "1.1", currentVersion: "1.1"),
            "the packed script answers legalPackNeedsAcceptance"
        )
        XCTAssertEqual(user(policyAccepted: true, legalPackVersion: "1.1").legalGateState(isOnline: true, cacheGraceExpired: false), .open)
    }

    func testRealUserMissingVersionShowsTheGate() {
        XCTAssertEqual(user(policyAccepted: true, legalPackVersion: nil).legalGateState(isOnline: true, cacheGraceExpired: false), .gate)
        XCTAssertEqual(user(policyAccepted: false, legalPackVersion: nil).legalGateState(isOnline: true, cacheGraceExpired: false), .gate)
    }

    func testOfflineCacheRoundTripKeepsAcceptedVersionAndDropsProvisional() throws {
        var cached = user(policyAccepted: true, legalPackVersion: "1.1")
        cached.isProvisional = true
        let decoded = try JSONDecoder().decode(AppUser.self, from: JSONEncoder().encode(cached))
        XCTAssertEqual(decoded.legalPackVersion, "1.1")
        XCTAssertFalse(decoded.isProvisional, "not encoded")
        XCTAssertEqual(decoded.legalGateState(isOnline: true, cacheGraceExpired: false), .open)
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
        XCTAssertEqual(parsed.legalGateState(isOnline: true, cacheGraceExpired: false), .open)
    }

    /// The bug the owner saw: an iOS-only acceptance stored the version but not `policyAccepted`.
    func testVersionWithoutPolicyAcceptedStillShowsTheGate() {
        let stored: [String: Any] = [
            "email": "test-gate@example.com", "organizationId": "TEST-org", "role": "manager",
            "legalPackVersion": CustomerLegalPack.version,
            "legalAcceptances": ["privacy": true],
        ]
        let parsed = FirebaseBackend.parseAppUserDocument(userId: "TEST-uid", data: stored, annualLeaveDefaults: nil)
        XCTAssertEqual(parsed.legalGateState(isOnline: true, cacheGraceExpired: false), .gate, "read side unchanged until web lib/canonical decides")
    }

    // MARK: - Cached copy, then server copy (fails closed)

    private func cachedCopy(policyAccepted: Bool, legalPackVersion: String?) -> AppUser {
        var copy = user(policyAccepted: policyAccepted, legalPackVersion: legalPackVersion)
        copy.readFromLocalCache = true
        return copy
    }

    func testStaleUnacceptedCacheCopyWaitsOnCheckingThenServerOpensTheApp() {
        let cached = cachedCopy(policyAccepted: false, legalPackVersion: nil)
        XCTAssertEqual(cached.legalGateState(isOnline: true, cacheGraceExpired: false), .checking,
                       "neither the terms flash nor the app while the server copy is on its way")
        let server = user(policyAccepted: true, legalPackVersion: CustomerLegalPack.version)
        XCTAssertEqual(server.legalGateState(isOnline: true, cacheGraceExpired: false), .open, "the server copy says accepted")
    }

    func testUnacceptedCacheOnlyCopyIsGatedAfterTheGracePeriod() {
        let cached = cachedCopy(policyAccepted: false, legalPackVersion: nil)
        XCTAssertEqual(cached.legalGateState(isOnline: true, cacheGraceExpired: true), .gate,
                       "Firestore stuck on the cache (captive portal, blocked host): the cached copy decides")
        XCTAssertGreaterThan(LegalGateState.cacheGraceSeconds, 0)
    }

    func testOfflineTheCachedCopyDecides() {
        XCTAssertEqual(cachedCopy(policyAccepted: false, legalPackVersion: nil)
            .legalGateState(isOnline: false, cacheGraceExpired: false), .gate)
    }

    func testAcceptedCacheCopyOpensTheAppAndTheServerCanStillGate() {
        let cached = cachedCopy(policyAccepted: true, legalPackVersion: CustomerLegalPack.version)
        XCTAssertEqual(cached.legalGateState(isOnline: true, cacheGraceExpired: false), .open, "no flash for an accepted account")
        let server = user(policyAccepted: false, legalPackVersion: nil)
        XCTAssertEqual(server.legalGateState(isOnline: true, cacheGraceExpired: false), .gate,
                       "a genuinely unaccepted account still sees the gate")
    }

    func testOlderAcceptedVersionInCacheNeverOpensTheApp() {
        let cached = cachedCopy(policyAccepted: true, legalPackVersion: "1.0")
        XCTAssertNotEqual(cached.legalGateState(isOnline: true, cacheGraceExpired: false), .open)
        XCTAssertEqual(cached.legalGateState(isOnline: true, cacheGraceExpired: true), .gate)
    }

    // MARK: - One-off read against the live copy (UserStore.loadCurrentUser)

    func testLateCachedOneOffReadKeepsTheServerAcceptance() throws {
        let server = user(policyAccepted: false, legalPackVersion: nil)
        let lateCached = cachedCopy(policyAccepted: true, legalPackVersion: CustomerLegalPack.version)
        let next = try XCTUnwrap(UserStore.oneOffReadProfile(current: server, loaded: lateCached, generationAtStart: 3, generationNow: 3))
        XCTAssertFalse(next.policyAccepted, "a timed-out read's cache copy never lifts the gate the server copy decided")
        XCTAssertFalse(next.readFromLocalCache)
        XCTAssertEqual(next.legalGateState(isOnline: true, cacheGraceExpired: false), .gate)
    }

    /// Organisation switch (`performQueuedOrganizationSwitch`) or foreground membership refresh whose read timed out
    /// and fell back to the cache: the new company's role and permissions still go on screen; the acceptance stays.
    func testOrganisationSwitchWithCachedReadAppliesTheNewCompanyAndKeepsTheAcceptance() throws {
        var previousCompany = user(policyAccepted: true, legalPackVersion: CustomerLegalPack.version)
        previousCompany.role = .admin
        previousCompany.permissions = UserPermissions(adminAccess: true, manager: true, operatives: true)
        previousCompany.organizationId = "TEST-org-A"

        // The cached users/{uid} copy predates the acceptance; merged with the new company's membership row.
        let cachedUsersDoc = cachedCopy(policyAccepted: false, legalPackVersion: nil)
        let membership = FirebaseBackend.parseAppUserDocument(
            userId: "TEST-uid",
            data: ["email": "test-gate@example.com", "organizationId": "TEST-org-B", "role": "operative",
                   "permissions": ["operativeMode": true]],
            annualLeaveDefaults: nil
        )
        var newCompany = FirebaseBackend.mergedDeviceSessionProfile(membership, user: cachedUsersDoc)
        newCompany.organizationId = "TEST-org-B"
        XCTAssertTrue(newCompany.readFromLocalCache)

        let next = try XCTUnwrap(UserStore.oneOffReadProfile(
            current: previousCompany, loaded: newCompany, generationAtStart: 7, generationNow: 7
        ), "a cached read is still applied on an organisation switch")
        XCTAssertEqual(next.organizationId, "TEST-org-B")
        XCTAssertEqual(next.role, membership.role, "the new company's role")
        XCTAssertEqual(next.permissions, membership.permissions, "the new company's permissions")
        XCTAssertNotEqual(next.permissions, previousCompany.permissions)
        XCTAssertTrue(next.policyAccepted, "the server copy's acceptance")
        XCTAssertEqual(next.legalPackVersion, CustomerLegalPack.version)
        XCTAssertFalse(next.readFromLocalCache)
        XCTAssertEqual(next.legalGateState(isOnline: true, cacheGraceExpired: false), .open)
    }

    func testOneOffReadYieldsToASnapshotThatArrivedWhileItRan() {
        let live = user(policyAccepted: false, legalPackVersion: nil)
        let read = user(policyAccepted: true, legalPackVersion: CustomerLegalPack.version)
        XCTAssertNil(UserStore.oneOffReadProfile(current: live, loaded: read, generationAtStart: 3, generationNow: 4))
    }

    func testOneOffReadReplacesPlaceholderCacheCopyOrNothing() {
        var placeholder = user(policyAccepted: true, legalPackVersion: nil)
        placeholder.isProvisional = true
        let read = cachedCopy(policyAccepted: false, legalPackVersion: nil)
        XCTAssertEqual(UserStore.oneOffReadProfile(current: placeholder, loaded: read, generationAtStart: 1, generationNow: 2), read)
        XCTAssertEqual(UserStore.oneOffReadProfile(current: nil, loaded: read, generationAtStart: 0, generationNow: 0), read)
        let server = user(policyAccepted: true, legalPackVersion: CustomerLegalPack.version)
        XCTAssertEqual(UserStore.oneOffReadProfile(current: read, loaded: server, generationAtStart: 2, generationNow: 2), server,
                       "a server read replaces a cached copy")
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
        XCTAssertEqual(membership.legalGateState(isOnline: true, cacheGraceExpired: false), .gate, "the root cause of the flash in another company")
        let session = membership.carryingLegalAcceptance(from: usersDoc)
        XCTAssertEqual(session.legalGateState(isOnline: true, cacheGraceExpired: false), .open)
        XCTAssertEqual(session.legalPackVersion, CustomerLegalPack.version)
    }

    func testDeviceSessionMergeKeepsTheUsersDocumentAcceptance() {
        var usersDoc = user(policyAccepted: true, legalPackVersion: CustomerLegalPack.version)
        usersDoc.profilePhotoURL = "https://example.com/TEST-photo.jpg"
        let membership = FirebaseBackend.parseAppUserDocument(
            userId: "TEST-uid",
            data: ["email": "test-gate@example.com", "organizationId": "TEST-other-org", "role": "operative"],
            annualLeaveDefaults: nil
        )
        let merged = FirebaseBackend.mergedDeviceSessionProfile(membership, user: usersDoc)
        XCTAssertTrue(merged.policyAccepted)
        XCTAssertEqual(merged.legalPackVersion, CustomerLegalPack.version)
        XCTAssertEqual(merged.profilePhotoURL, usersDoc.profilePhotoURL)
        XCTAssertEqual(merged.role, membership.role, "the company's role stays the membership's")
        XCTAssertEqual(merged.legalGateState(isOnline: true, cacheGraceExpired: false), .open)

        var cachedUsersDoc = usersDoc
        cachedUsersDoc.policyAccepted = false
        cachedUsersDoc.readFromLocalCache = true
        let mergedCached = FirebaseBackend.mergedDeviceSessionProfile(membership, user: cachedUsersDoc)
        XCTAssertTrue(mergedCached.readFromLocalCache, "the source of the users/{uid} copy comes with it")
    }

    func testTimesheetsToggleRosterRowKeepsTheAcceptance() {
        let current = user(policyAccepted: true, legalPackVersion: CustomerLegalPack.version)
        var rosterRow = user(policyAccepted: false, legalPackVersion: nil)
        rosterRow.timesheetsEnabled = true
        let next = UserStore.currentUserReplacedByRosterRow(rosterRow, current: current)
        XCTAssertTrue(next.timesheetsEnabled)
        XCTAssertTrue(next.policyAccepted)
        XCTAssertEqual(next.legalPackVersion, CustomerLegalPack.version)
        XCTAssertEqual(next.legalGateState(isOnline: true, cacheGraceExpired: false), .open)
    }

    func testAcceptanceTicksSurviveARebuildForTheSamePersonOnly() {
        let draft = PolicyAcceptanceDraft()
        draft.keep(for: "TEST-uid")
        draft.accepted[.privacy] = true
        draft.authorisedToBind = true
        draft.keep(for: "TEST-uid")
        XCTAssertEqual(draft.accepted[.privacy], true, "a rebuild of the gate keeps the ticks")
        XCTAssertTrue(draft.authorisedToBind)
        draft.keep(for: "TEST-other-uid")
        XCTAssertEqual(draft.accepted[.privacy], false, "another person starts unticked")
        XCTAssertFalse(draft.authorisedToBind)
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
