import XCTest
@testable import Project_Planner

/// RULEBOOK 1.56.0 Phase A (§9, §17, §18; owner decisions 17 Nov): operatives read only their own annual leave, behind
/// the `platformConfig/app` switch `operativeOwnLeave` / `operativeOwnLeaveOrganizationIds`. Every plan is the packed
/// script's (`leaveQueryPlan`, `leaveQueryValues`, `readsOnlyOwnLeave`, `operativeOwnLeaveEnabled`); these lock the
/// Swift side that turns it into reads (`LeaveReadDecision`, `HolidayStore`). Expected values were checked with Node
/// against the packed `canonical-business.js` (rulebook 1.56.0).
@MainActor
final class OperativeOwnLeaveTests: XCTestCase {
    private func role(admin: Bool = false, manager: Bool = false, operative: Bool = false, superAdmin: Bool = false)
        -> CanonicalBusinessEngine.CanonicalStaffAccountRole {
        CanonicalBusinessEngine.CanonicalStaffAccountRole(
            isSuperAdmin: superAdmin,
            isAdmin: admin,
            isManager: manager,
            isOperativeMode: operative
        )
    }

    private func viewer(
        _ role: CanonicalBusinessEngine.CanonicalStaffAccountRole,
        uid: String = "UID",
        ids: [String] = ["UID"]
    ) -> JobAccessViewer {
        JobAccessViewer(role: role, projectsToggle: false, smallWorksToggle: false, uid: uid, ids: ids, email: "op@x.com")
    }

    private var savedViewer: JobAccessViewer?
    private var savedLeaveOperativeLevel = false
    private var savedLeaveEmail: String?
    private var savedRederiver: (@MainActor () -> Void)?
    private static var retained: [AnyObject] = []

    override func setUp() {
        super.setUp()
        savedViewer = JobAccessContext.readViewer
        savedLeaveOperativeLevel = JobAccessContext.leaveOperativeLevel
        savedLeaveEmail = JobAccessContext.leaveEmail
        savedRederiver = JobAccessContext.viewerRederiver
    }

    override func tearDown() {
        SecuritySwitchContext.reset()
        // Review of #246: the shared viewer state never leaks into the next test.
        JobAccessContext.viewerRederiver = savedRederiver
        JobAccessContext.updateViewer(savedViewer)
        JobAccessContext.updateLeaveViewer(operativeLevel: savedLeaveOperativeLevel, email: savedLeaveEmail)
        super.tearDown()
    }

    // MARK: - The switch

    func testTheSwitchIsOnOnlyForExactlyTrueOrAListedOrganisation() {
        XCTAssertEqual(CanonicalBusinessEngine.operativeOwnLeaveSwitchField, "operativeOwnLeave")
        XCTAssertEqual(CanonicalBusinessEngine.operativeOwnLeaveOrganizationIdsField, "operativeOwnLeaveOrganizationIds")
        XCTAssertEqual(CanonicalBusinessEngine.operativeOwnLeaveEnabled(config: ["operativeOwnLeave": true], organizationId: "ORG-A"), true)
        XCTAssertEqual(CanonicalBusinessEngine.operativeOwnLeaveEnabled(config: ["operativeOwnLeave": "true"], organizationId: "ORG-A"), false)
        XCTAssertEqual(
            CanonicalBusinessEngine.operativeOwnLeaveEnabled(config: ["operativeOwnLeaveOrganizationIds": ["ORG-A"]], organizationId: "ORG-A"),
            true
        )
        XCTAssertEqual(
            CanonicalBusinessEngine.operativeOwnLeaveEnabled(config: ["operativeOwnLeaveOrganizationIds": ["ORG-A"]], organizationId: "org-a"),
            false,
            "the id exactly as stored"
        )
        XCTAssertEqual(CanonicalBusinessEngine.operativeOwnLeaveEnabled(config: nil, organizationId: "ORG-A"), false)
    }

    func testTheSwitchContextReadsPlatformConfigPerOrganisationAndIsOffUntilRead() {
        SecuritySwitchContext.reset()
        XCTAssertFalse(SecuritySwitchContext.operativeOwnLeaveEnabled(organizationId: "ORG-A"), "not read yet is off")
        SecuritySwitchContext.update(config: ["operativeOwnLeaveOrganizationIds": ["ORG-A"]])
        XCTAssertTrue(SecuritySwitchContext.operativeOwnLeaveEnabled(organizationId: "ORG-A"))
        XCTAssertFalse(SecuritySwitchContext.operativeOwnLeaveEnabled(organizationId: "ORG-B"))
        SecuritySwitchContext.update(config: nil)
        XCTAssertFalse(SecuritySwitchContext.operativeOwnLeaveEnabled(organizationId: "ORG-A"), "a missing document is off")
    }

    // MARK: - Switch off: everyone reads the whole collection

    func testWithTheSwitchOffAnOperativeReadsTheWholeCollection() {
        let decision = LeaveReadDecision.decide(
            viewer: viewer(role(operative: true)),
            operativeLevel: true,
            ownIds: ["UID", "OP-1"],
            email: "op@x.com",
            operativeOwnLeave: false
        )
        XCTAssertEqual(decision, .all)
        XCTAssertEqual(CanonicalBusinessEngine.readsOnlyOwnLeave(viewer(role(operative: true)), operativeOwnLeave: false), false)
    }

    func testWithTheSwitchOffNothingWaitsForTheViewer() {
        // Off or unread: exactly as before 1.56.0, even before the profile has loaded.
        XCTAssertEqual(
            LeaveReadDecision.decide(viewer: nil, operativeLevel: false, ownIds: [], email: nil, operativeOwnLeave: false),
            .all
        )
    }

    // MARK: - Switch on

    func testWithTheSwitchOnAnOperativeRunsOnlyTheirOwnOrQuery() throws {
        let plan = try XCTUnwrap(CanonicalBusinessEngine.leaveQueryPlan(
            viewer(role(operative: true)),
            ownIds: ["OP-1", "UID", "FORMER"],
            email: "Op@X.com",
            operativeOwnLeave: true
        ))
        XCTAssertFalse(plan.readsEveryLeave, "never the whole collection")
        XCTAssertEqual(plan.ownQueries.count, 1)
        let decision = LeaveReadDecision.decide(
            viewer: viewer(role(operative: true)),
            operativeLevel: true,
            ownIds: ["OP-1", "UID", "FORMER"],
            email: "Op@X.com",
            operativeOwnLeave: true
        )
        guard case .own(let queries) = decision else { return XCTFail("an operative is narrowed: \(decision)") }
        XCTAssertEqual(queries, plan.ownQueries)
    }

    func testTheOrQueryValuesAreLeaveQueryValuesEmailsOnUserIdOnly() throws {
        let values = try XCTUnwrap(CanonicalBusinessEngine.leaveQueryValues(uid: "UID", ownIds: ["OP-1", "UID", "FORMER"], email: "Op@X.com"))
        XCTAssertEqual(values.ids, ["UID", "OP-1", "FORMER"])
        XCTAssertEqual(values.emails, ["Op@X.com", "op@x.com"])
        let plan = try XCTUnwrap(CanonicalBusinessEngine.leaveQueryPlan(
            viewer(role(operative: true)),
            ownIds: ["OP-1", "UID", "FORMER"],
            email: "Op@X.com",
            operativeOwnLeave: true
        ))
        let query = try XCTUnwrap(plan.ownQueries.first)
        XCTAssertEqual(query.userIdValues, values.ids + values.emails)
        XCTAssertEqual(query.operativeIdValues, values.ids, "an operativeId is never an email")
    }

    func testMoreThanFourteenIdsSplitIntoSeveralQueriesWithTheEmailsOnTheFirst() throws {
        XCTAssertEqual(CanonicalBusinessEngine.ownLeaveIdsPerQuery, 14)
        let ids = (0..<16).map { "id\($0)" }
        let plan = try XCTUnwrap(CanonicalBusinessEngine.leaveQueryPlan(
            viewer(role(operative: true), uid: "id0", ids: ["id0"]),
            ownIds: ids,
            email: "A@B.co",
            operativeOwnLeave: true
        ))
        XCTAssertEqual(plan.ownQueries.count, 2)
        XCTAssertEqual(plan.ownQueries[0].operativeIdValues, Array(ids.prefix(14)))
        XCTAssertEqual(plan.ownQueries[0].userIdValues, Array(ids.prefix(14)) + ["A@B.co", "a@b.co"])
        XCTAssertEqual(plan.ownQueries[1].userIdValues, ["id14", "id15"])
        XCTAssertEqual(plan.ownQueries[1].operativeIdValues, ["id14", "id15"])
    }

    func testEmptyOwnIdsFallBackToTheViewersIdsNeverTheWholeCollection() throws {
        let plan = try XCTUnwrap(CanonicalBusinessEngine.leaveQueryPlan(
            viewer(role(operative: true), ids: ["UID", "FORMER"]),
            ownIds: [],
            email: nil,
            operativeOwnLeave: true
        ))
        XCTAssertFalse(plan.readsEveryLeave)
        XCTAssertEqual(plan.ownQueries.first?.operativeIdValues, ["UID", "FORMER"])
    }

    func testAdminsManagersAndSuperAdminsKeepTheWholeCollectionWithTheSwitchOn() {
        for staff in [role(admin: true), role(manager: true), role(admin: true, superAdmin: true)] {
            XCTAssertEqual(
                LeaveReadDecision.decide(viewer: viewer(staff), operativeLevel: false, ownIds: ["UID"], email: "a@x.com", operativeOwnLeave: true),
                .all
            )
        }
    }

    func testOnlyTheOperativeLevelIsNarrowedNotAStrayOperativeModeFlag() {
        // An admin with a stray operative-mode flag, and a no-flag legacy user: `permissionLevelOf` is not operative.
        let strayFlag = viewer(role(admin: true, operative: true))
        XCTAssertEqual(
            LeaveReadDecision.decide(viewer: strayFlag, operativeLevel: false, ownIds: ["UID"], email: nil, operativeOwnLeave: true),
            .all
        )
        XCTAssertEqual(
            LeaveReadDecision.decide(viewer: viewer(role()), operativeLevel: false, ownIds: ["UID"], email: nil, operativeOwnLeave: true),
            .all
        )
        XCTAssertFalse(strayFlag.leaveViewer(operativeLevel: false).role.isOperativeMode)
        XCTAssertTrue(viewer(role()).leaveViewer(operativeLevel: true).role.isOperativeMode)
    }

    func testAViewerWithNoUidRunsNothing() {
        let noUid = viewer(role(operative: true), uid: "", ids: [])
        let plan = CanonicalBusinessEngine.leaveQueryPlan(noUid, ownIds: [], email: nil, operativeOwnLeave: true)
        XCTAssertEqual(plan, RulebookLeaveQueryPlan(readsEveryLeave: false, ownQueries: []))
        XCTAssertEqual(
            LeaveReadDecision.decide(viewer: noUid, operativeLevel: true, ownIds: [], email: nil, operativeOwnLeave: true),
            .nothing
        )
        XCTAssertEqual(CanonicalBusinessEngine.leaveQueryPlan(nil, ownIds: [], email: nil, operativeOwnLeave: true)?.ownQueries, [])
    }

    func testWithTheSwitchOnNothingIsReadBeforeTheViewerIsKnown() {
        XCTAssertEqual(
            LeaveReadDecision.decide(viewer: nil, operativeLevel: false, ownIds: [], email: nil, operativeOwnLeave: true),
            .nothing
        )
    }

    func testSignaturesChangeWithThePlan() {
        let narrow = LeaveReadDecision.decide(
            viewer: viewer(role(operative: true)), operativeLevel: true, ownIds: ["UID"], email: nil, operativeOwnLeave: true
        )
        let wider = LeaveReadDecision.decide(
            viewer: viewer(role(operative: true)), operativeLevel: true, ownIds: ["UID", "OP-ROW"], email: nil, operativeOwnLeave: true
        )
        XCTAssertEqual(LeaveReadDecision.all.signature, "all")
        XCTAssertNotEqual(narrow.signature, "all")
        XCTAssertNotEqual(narrow.signature, wider.signature, "an operatives row arriving re-plans the listener")
    }

    // MARK: - HolidayStore plumbing

    func testRowsAreClearedForAnotherUserOrWhenThePlanNarrows() {
        XCTAssertTrue(HolidayStore.mustClearRows(previousUserId: "A", userId: "B", previousSignature: "all", signature: "all"))
        XCTAssertTrue(HolidayStore.mustClearRows(previousUserId: "A", userId: "A", previousSignature: "all", signature: "own:u:A/o:A"))
        XCTAssertFalse(HolidayStore.mustClearRows(previousUserId: "A", userId: "A", previousSignature: "own:u:A/o:A", signature: "all"))
        XCTAssertFalse(HolidayStore.mustClearRows(previousUserId: nil, userId: "A", previousSignature: nil, signature: "own:u:A/o:A"))
        XCTAssertFalse(HolidayStore.mustClearRows(previousUserId: "A", userId: "A", previousSignature: "all", signature: "all"))
    }

    func testRetriesAfterARefusalAreCapped() {
        let t0 = Date(timeIntervalSince1970: 1_000)
        XCTAssertEqual(HolidayStore.nextAllowedReplan(afterRefusals: 1, at: t0), t0.addingTimeInterval(30))
        XCTAssertEqual(HolidayStore.nextAllowedReplan(afterRefusals: 2, at: t0), t0.addingTimeInterval(120))
        XCTAssertNil(HolidayStore.nextAllowedReplan(afterRefusals: 3, at: t0), "then none until the plan changes")
        XCTAssertNil(HolidayStore.nextAllowedReplan(afterRefusals: 0, at: t0))
        // The planned listener's own re-attach is capped too: a refusal once, then none.
        XCTAssertEqual(LiveListenerAttachPolicy.retryDelay(afterFailures: 1, permissionDenied: true), 30)
        XCTAssertNil(LiveListenerAttachPolicy.retryDelay(afterFailures: 2, permissionDenied: true))
    }

    func testRefusalKeysAreScopedToOrganisationUserAndPlan() {
        let key = HolidayStore.refusalKey(organizationId: " ORG-A ", userId: "UID", signature: "own:x")
        XCTAssertEqual(key, "ORG-A|UID|own:x")
        XCTAssertTrue(key.hasPrefix(HolidayStore.refusalKey(organizationId: "ORG-A", userId: "UID", signature: "")))
        XCTAssertFalse(key.hasPrefix(HolidayStore.refusalKey(organizationId: "ORG-A", userId: "OTHER", signature: "")))
    }

    func testAOneOffLoadIsUsedOnlyWhileItsPlanUserAndOrganisationAreCurrent() {
        XCTAssertTrue(HolidayStore.loadResultStillCurrent(
            decisionSignature: "all", currentSignature: "all", userId: "U", currentUserId: "U",
            organizationId: "ORG-A", currentOrganizationId: "org-a"
        ))
        XCTAssertFalse(HolidayStore.loadResultStillCurrent(
            decisionSignature: "all", currentSignature: "own:u:U/o:U", userId: "U", currentUserId: "U",
            organizationId: "ORG-A", currentOrganizationId: "ORG-A"
        ), "a whole-collection read finishing after the plan narrowed is dropped")
        XCTAssertFalse(HolidayStore.loadResultStillCurrent(
            decisionSignature: "all", currentSignature: "all", userId: "U", currentUserId: nil,
            organizationId: "ORG-A", currentOrganizationId: "ORG-A"
        ), "signed out")
        XCTAssertFalse(HolidayStore.loadResultStillCurrent(
            decisionSignature: "all", currentSignature: "all", userId: "U", currentUserId: "U",
            organizationId: "ORG-A", currentOrganizationId: "ORG-B"
        ), "another company")
    }

    func testSignOutClearsLeaveAndForgetsThePlan() {
        let store = HolidayStore()
        store.bookings = [HolidayBooking(
            organizationId: "ORG-A",
            userId: "U",
            operativeId: nil,
            startDate: Date(timeIntervalSince1970: 1_800_000_000),
            endDate: Date(timeIntervalSince1970: 1_800_000_000),
            status: .approved,
            timeSlot: .fullDay,
            approvedByUserId: nil
        )]
        store.resetForSignOut()
        XCTAssertTrue(store.bookings.isEmpty)
        XCTAssertNil(store.requestedOrganizationId)
        XCTAssertNil(store.plannedSignature)
        XCTAssertNil(store.plannedUserId)
        XCTAssertNil(store.finishedLoadOrganizationId)
    }

    // MARK: - Review of #246

    func testOneRefusalIsCountedOncePerPlanEvenWithSeveralQueries() {
        let once = HolidayStore.RefusalOnce()
        XCTAssertTrue(once.claim(), "the first refused query counts")
        XCTAssertFalse(once.claim(), "the second query of the same plan does not")
        XCTAssertFalse(once.claim())
        XCTAssertTrue(HolidayStore.RefusalOnce().claim(), "a new attach counts again")
    }

    func testAnOperativeWhosePlanCannotBeWorkedOutIsToldAndRetried() {
        XCTAssertEqual(LeaveReadDecision.unavailable.signature, "unavailable")
        XCTAssertFalse(LeaveReadDecision.unavailable.readsLeave, "never the whole collection")
        XCTAssertFalse(LeaveReadDecision.nothing.readsLeave)
        XCTAssertTrue(LeaveReadDecision.all.readsLeave)
        XCTAssertTrue(LeaveReadDecision.own([RulebookOwnLeaveQuery(userIdValues: ["U"], operativeIdValues: ["U"])]).readsLeave)
        XCTAssertEqual(LeaveReadDecision.unavailableMessage, "Couldn't load your leave — try again.")
        XCTAssertEqual(HolidayStore.unavailableReplanDelay(afterAttempts: 0), 5)
        XCTAssertEqual(HolidayStore.unavailableReplanDelay(afterAttempts: 3), 120)
        XCTAssertNil(HolidayStore.unavailableReplanDelay(afterAttempts: 4), "capped")
    }

    /// Review of #246: a listener that gave up (not refused) is re-attached by a re-plan only after a short back-off.
    func testAGivenUpListenerIsReattachedAfterABackOff() {
        let t0 = Date(timeIntervalSince1970: 1_000)
        XCTAssertEqual(HolidayStore.gaveUpReattachDelay, 5)
        XCTAssertNil(HolidayStore.gaveUpReattachWait(gaveUpAt: nil, now: t0))
        XCTAssertEqual(HolidayStore.gaveUpReattachWait(gaveUpAt: t0, now: t0), 5)
        XCTAssertEqual(HolidayStore.gaveUpReattachWait(gaveUpAt: t0, now: t0.addingTimeInterval(2)), 3)
        XCTAssertNil(HolidayStore.gaveUpReattachWait(gaveUpAt: t0, now: t0.addingTimeInterval(5)))
    }

    /// Review of #246: only the listener still registered under its token reports giving up.
    func testOnlyTheRegisteredListenerCanBeMarkedForReattach() {
        let registry = OrgListenerRegistry()
        let old = registry.set(key: "holidayBookings", target: "a", remove: {})
        let current = registry.set(key: "holidayBookings", target: "b", remove: {})
        XCTAssertFalse(registry.markForReattach(key: "holidayBookings", token: old))
        XCTAssertTrue(registry.markForReattach(key: "holidayBookings", token: current))
    }

    func testAnOrganisationSwitchForgetsThePreviousCompanysRoleAndEmail() {
        JobAccessContext.viewerRederiver = nil
        JobAccessContext.updateViewer(viewer(role(operative: true)))
        JobAccessContext.updateLeaveViewer(operativeLevel: true, email: "op@x.com")
        XCTAssertTrue(JobAccessContext.leaveOperativeLevel)
        XCTAssertEqual(JobAccessContext.leaveEmail, "op@x.com")
        JobAccessContext.resetForOrganizationSwitchAndRederiveViewer()
        XCTAssertFalse(JobAccessContext.leaveOperativeLevel)
        XCTAssertNil(JobAccessContext.leaveEmail)
        XCTAssertNil(JobAccessContext.readViewer, "no profile to re-derive from")
    }

    /// Review of #246 (2nd round): `switchOrganization` loads the new company's profile before it stops the
    /// listeners. The switch then clears the viewer and re-derives it at once from that profile, so screens never
    /// stay on "Loading your team…" waiting for a profile change that already happened.
    func testACompanySwitchAfterTheProfileLoadedStillEndsWithAViewer() {
        let store = UserStore()
        Self.retained.append(store)
        store.currentUser = AppUser(
            id: "op-switch-1",
            email: "op-switch-1@example.test",
            organizationId: "ORG-B",
            role: .operative,
            firstName: "TEST-Op",
            surname: "Person",
            permissions: UserPermissions(operativeMode: true)
        )
        let before = JobAccessContext.readViewer
        XCTAssertNotNil(before)
        XCTAssertEqual(JobAccessContext.leaveEmail, "op-switch-1@example.test")

        let backend = FirebaseBackend()
        Self.retained.append(backend)
        backend.stopScheduleLiveListeners()

        XCTAssertNotNil(JobAccessContext.readViewer, "the viewer is set again from the profile already loaded")
        XCTAssertEqual(JobAccessContext.readViewer, before)
        XCTAssertEqual(JobAccessContext.leaveEmail, "op-switch-1@example.test")
        XCTAssertFalse(JobAccessContext.viewerPending)
    }

    /// Review of #246: the first settings-listener attach at launch is not a switch and clears nothing.
    func testTheFirstSettingsListenerAttachIsNotASwitch() throws {
        let backend = try String(contentsOfFile: Self.sourcePath("Project Planner/FirebaseBackend.swift"), encoding: .utf8)
        XCTAssertTrue(backend.contains("stopScheduleLiveListeners(resetsJobAccess: wasListening)"))
        XCTAssertTrue(backend.contains("JobAccessContext.resetForOrganizationSwitchAndRederiveViewer()"))
    }

    private static func sourcePath(_ relative: String) -> String {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(relative).path
    }

    func testALoadWithNoBackendLeavesNoPendingRequest() async {
        let store = HolidayStore()
        await store.loadData()
        XCTAssertFalse(store.pendingLoadRequested)
        XCTAssertFalse(store.isLoading)
        XCTAssertNotNil(store.errorMessage)
        XCTAssertEqual(HolidayStore.maxLoadRunsPerRequest, 3)
    }

    func testAReplanWithNoBackendOrOrganisationDoesNothing() {
        let store = HolidayStore()
        store.replanLiveUpdates()
        XCTAssertNil(store.plannedSignature)
        XCTAssertNil(store.requestedOrganizationId)
    }
}
