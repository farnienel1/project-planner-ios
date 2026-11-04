import XCTest
@testable import Project_Planner

/// RULEBOOK 1.26.0 "Security switches" (`enforcedReads`, `privatePay`) on iOS through `CanonicalBusinessEngine`. Expected
/// values were checked in node against the packed `canonical-business.js` (rulebook 1.26.0, sha256 7dcb97cc…a5c0158).
@MainActor
final class Rulebook1260Tests: XCTestCase {
    override func tearDown() {
        SecuritySwitchContext.reset()
        super.tearDown()
    }

    private func role(admin: Bool = false, manager: Bool = false, operative: Bool = false) -> CanonicalBusinessEngine.CanonicalStaffAccountRole {
        CanonicalBusinessEngine.CanonicalStaffAccountRole(isSuperAdmin: false, isAdmin: admin, isManager: manager, isOperativeMode: operative)
    }

    func testThePackedScriptIsRulebook1260OrLater() throws {
        let stamp = try XCTUnwrap(CanonicalBusinessEngine.rulebookStamp())
        let parts = stamp.version.split(separator: ".").compactMap { Int($0) }
        XCTAssertFalse(parts.lexicographicallyPrecedes([1, 26, 0]), "rulebook \(stamp.version) predates 1.26.0")
        let names = Set(CanonicalBusinessEngine.exportNames())
        for name in ["securitySwitchOn", "securitySwitches", "sharedDocumentPayWrite", "rateHistoryQueryPlan", "payProfileReadPlan", "overlayPayProfile"] {
            XCTAssertTrue(names.contains(name), "\(name) missing from the packed script")
        }
    }

    // MARK: Reading the switches

    func testMalformedConfigSwitchesNothingOn() {
        let off = SecuritySwitchState(enforcedReads: false, privatePay: false)
        let malformed: [[String: Any]?] = [
            nil,
            [:],
            ["enforcedReads": "true"],
            ["enforcedReadsOrganizationIds": "ORG1"],
            ["enforcedReadsOrganizationIds": [["id": "ORG1"]]],
            ["enforcedReadsOrganizationIds": ["org1"]],
        ]
        for config in malformed {
            XCTAssertEqual(CanonicalBusinessEngine.securitySwitches(config: config, organizationId: "ORG1"), off, "\(String(describing: config))")
        }
        XCTAssertEqual(
            CanonicalBusinessEngine.securitySwitches(config: ["enforcedReadsOrganizationIds": ["ORG1"]], organizationId: "ORG1"),
            SecuritySwitchState(enforcedReads: true, privatePay: false)
        )
        XCTAssertEqual(
            CanonicalBusinessEngine.securitySwitches(config: ["privatePay": true], organizationId: "ORG2"),
            SecuritySwitchState(enforcedReads: false, privatePay: true)
        )
    }

    func testTheContextReadsThePlatformConfigPerOrganisation() {
        SecuritySwitchContext.reset()
        XCTAssertEqual(SecuritySwitchContext.switches(organizationId: "ORG1"), SecuritySwitchState(enforcedReads: false, privatePay: false))
        SecuritySwitchContext.update(config: ["enforcedReadsOrganizationIds": ["ORG1"], "privatePayOrganizationIds": ["ORG2"]])
        XCTAssertEqual(SecuritySwitchContext.switches(organizationId: "ORG1"), SecuritySwitchState(enforcedReads: true, privatePay: false))
        XCTAssertEqual(SecuritySwitchContext.switches(organizationId: "ORG2"), SecuritySwitchState(enforcedReads: false, privatePay: true))
        SecuritySwitchContext.update(config: nil)
        XCTAssertEqual(SecuritySwitchContext.switches(organizationId: "ORG1"), SecuritySwitchState(enforcedReads: false, privatePay: false))
    }

    // MARK: enforcedReads plans

    func testSwitchOffPlansAreTodaysPlans() throws {
        let manager = JobAccessViewer(role: role(manager: true), projectsToggle: false, smallWorksToggle: false, uid: "U-M", ids: ["U-M"], email: "m@x.com")
        let today = try XCTUnwrap(CanonicalBusinessEngine.jobQueryPlan(manager, documentIds: ["J1"]))
        let off = try XCTUnwrap(CanonicalBusinessEngine.jobQueryPlan(manager, documentIds: ["J1"], enforced: false))
        XCTAssertEqual(today as NSDictionary, off as NSDictionary)
        let offQueries: [[String: Any]] = try XCTUnwrap(off["queries"] as? [[String: Any]])
        let kinds: [String] = offQueries.compactMap { $0["kind"] as? String }
        XCTAssertEqual(kinds, ["all", "all"])
        let bookingsToday = try XCTUnwrap(CanonicalBusinessEngine.bookingQueryPlan(manager, visibleJobIds: ["J1"], ownBookingIds: nil))
        let bookingsOff = try XCTUnwrap(CanonicalBusinessEngine.bookingQueryPlan(manager, visibleJobIds: ["J1"], ownBookingIds: nil, enforced: false))
        XCTAssertEqual(bookingsToday as NSDictionary, bookingsOff as NSDictionary)
        XCTAssertTrue(CanonicalBusinessEngine.readsEveryBooking(manager, enforced: false))
    }

    func testSwitchOnRestrictsAManagerAndAnOperative() throws {
        let manager = JobAccessViewer(role: role(manager: true), projectsToggle: false, smallWorksToggle: false, uid: "U-M", ids: ["U-M"], email: "m@x.com")
        let managedPlan: [String: Any] = try XCTUnwrap(CanonicalBusinessEngine.jobQueryPlan(manager, documentIds: [], enforced: true))
        let managed: [[String: Any]] = try XCTUnwrap(managedPlan["queries"] as? [[String: Any]])
        let managedKinds: [String] = managed.compactMap { $0["kind"] as? String }
        XCTAssertEqual(managedKinds, ["managed", "managed"])
        let managedValue: String? = managed.first?["value"] as? String
        XCTAssertEqual(managedValue, "U-M")
        XCTAssertFalse(CanonicalBusinessEngine.readsEveryBooking(manager, enforced: true))

        let operative = JobAccessViewer(role: role(operative: true), projectsToggle: false, smallWorksToggle: false, uid: "U-OP", ids: ["U-OP"], email: "op@x.com")
        let jobPlan: [String: Any] = try XCTUnwrap(CanonicalBusinessEngine.jobQueryPlan(operative, documentIds: ["J1"], enforced: true))
        let jobs: [[String: Any]] = try XCTUnwrap(jobPlan["queries"] as? [[String: Any]])
        let jobKinds: [String] = jobs.compactMap { $0["kind"] as? String }
        XCTAssertEqual(jobKinds, ["documents", "documents"], "an operative's jobs by id only")
        let jobIds: [String]? = jobs.first?["ids"] as? [String]
        XCTAssertEqual(jobIds, ["J1", "j1"])
        let bookingPlan: [String: Any] = try XCTUnwrap(CanonicalBusinessEngine.bookingQueryPlan(
            operative, visibleJobIds: ["J1"], ownBookingIds: ["U-OP", "OPROW-1"], enforced: true
        ))
        let bookings: [[String: Any]] = try XCTUnwrap(bookingPlan["queries"] as? [[String: Any]])
        XCTAssertEqual(bookings.count, 1)
        let bookingKind: String? = bookings.first?["kind"] as? String
        XCTAssertEqual(bookingKind, "own")
        let bookingValues: [String]? = bookings.first?["values"] as? [String]
        XCTAssertEqual(bookingValues, ["U-OP", "OPROW-1"], "only their own bookings")

        let scope: [String: Any] = CanonicalBusinessEngine.warningScopeFor(
            viewer: manager, visibleJobIds: ["J1"], bookings: [], managerBookings: [], people: [], operatives: [], enforced: true
        )
        let unbooked: Bool? = scope["unbookedLabour"] as? Bool
        XCTAssertEqual(unbooked, false, "a restricted manager reads no unbooked labour once reads are enforced")
    }

    // MARK: privatePay

    func testPayWritesStayOffSharedDocumentsOnlyWhileTheSwitchIsOn() {
        let write: [String: Any] = ["firstName": "Ada", "dayRate": 200, "payBasis": "day", "employmentType": "self_employed", "updatedAt": "now"]
        XCTAssertEqual(Set(CanonicalBusinessEngine.sharedDocumentPayWrite(write, privatePay: false).keys), Set(write.keys))
        XCTAssertEqual(Set(CanonicalBusinessEngine.sharedDocumentPayWrite(write, privatePay: true).keys), ["firstName", "updatedAt"])
        XCTAssertFalse(FirebaseBackend.hasFieldsBesidesMetadata(["updatedAt": 1, "updatedBy": "u", "updatedFrom": "ios"]))
        XCTAssertTrue(FirebaseBackend.hasFieldsBesidesMetadata(["updatedAt": 1, "firstName": "Ada"]))
    }

    func testRateHistoryIsPerPersonOnlyWhileTheSwitchIsOn() {
        let operative: [String: Any] = ["id": "OP-1", "email": "op@x.com", "isActive": true, "role": "operative", "operativeMode": true, "permissions": ["operativeMode": true]]
        let admin: [String: Any] = ["id": "A-1", "email": "a@x.com", "isActive": true, "role": "admin", "adminAccess": true, "permissions": ["adminAccess": true]]
        let manager: [String: Any] = ["id": "M-1", "email": "m@x.com", "isActive": true, "role": "manager", "manager": true, "operatives": true, "permissions": ["manager": true, "operatives": true]]
        let roster = [operative, admin, manager]
        XCTAssertEqual(CanonicalBusinessEngine.rateHistoryQueryPlan(viewer: operative, subjects: roster, roster: roster, privatePay: false), .all)
        XCTAssertEqual(CanonicalBusinessEngine.rateHistoryQueryPlan(viewer: operative, subjects: roster, roster: roster, privatePay: true), .people(["OP-1"]))
        XCTAssertEqual(CanonicalBusinessEngine.rateHistoryQueryPlan(viewer: admin, subjects: roster, roster: roster, privatePay: true), .all)
        XCTAssertEqual(CanonicalBusinessEngine.rateHistoryQueryPlan(viewer: manager, subjects: roster, roster: roster, privatePay: true), .people(["M-1", "OP-1"]))
        XCTAssertEqual(CanonicalBusinessEngine.payProfileReadPlan(viewer: operative, subjects: roster, roster: roster), .documents(["OP-1"]))
    }

    /// With `privatePay` off the users documents are shown unchanged: a stale pay profile (an older build's) is never
    /// laid over them, though `overlayPayProfile` would replace the rate if it were.
    func testAStaleProfileIsIgnoredWhileTheSwitchIsOff() async {
        SecuritySwitchContext.reset()
        var user = LogicFixtures.selfEmployedUser(id: "OP-1", dayRate: 200)
        user.payBasis = "day"
        let stale: [String: Any] = ["dayRate": 150, "payBasis": "day", "userId": "OP-1"]
        XCTAssertEqual(user.overlayingPayProfile(stale).dayRate, 150, "the overlay itself would replace the rate")
        let shown = await FirebaseBackend().overlayRosterPayIfPrivate([user])
        XCTAssertEqual(shown.first?.dayRate, 200)
    }

    /// Releasing a main-actor store at the end of a test hits a Swift runtime crash in this host.
    private static var retained: [AnyObject] = []

    /// Manage Users and My Profile seed pay from the users document while `privatePay` is off: a stale pay profile is
    /// ignored in the editor seed (`AppUser.payShown`, `UserStore.refreshPayFromPayProfile`), and used once it is on.
    func testTheEditorSeedIgnoresAStaleProfileWhileTheSwitchIsOff() async {
        SecuritySwitchContext.reset()
        var user = LogicFixtures.selfEmployedUser(id: "OP-1", dayRate: 200)
        user.payBasis = "day"
        let stale: [String: Any] = ["dayRate": 150, "payBasis": "day", "userId": "OP-1"]
        XCTAssertEqual(user.payShown(with: stale, privatePay: false).dayRate, 200)
        XCTAssertEqual(user.payShown(with: stale, privatePay: true).dayRate, 150)
        let store = UserStore()
        Self.retained.append(store)
        let seeded = await store.refreshPayFromPayProfile(of: user)
        XCTAssertEqual(seeded.dayRate, 200, "with the switch off nothing is read from the pay profile")
    }
}
