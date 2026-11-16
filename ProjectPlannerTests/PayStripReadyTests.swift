import XCTest
@testable import Project_Planner

/// RULEBOOK §8 ("Who may see pay"; 1.26.0 / 1.26.1 `payEditorStartingValues` / `overlayPayProfile`): after the strip,
/// `users/{uid}` holds no pay — no rates, no pay basis and no employment type (so it reads as self-employed). Each test
/// takes a stripped users document plus the person's `payProfiles/{uid}` document and checks that the signed-in person's
/// own record (`UserStore.currentUserWithPay`, and so `displayUser`) and the screens built on it read the pay profile.
/// The first assertion of each test shows the break on the stripped document alone.
@MainActor
final class PayStripReadyTests: XCTestCase {
    private let thursday = LogicFixtures.day(2026, 10, 8, hour: 8)

    override func setUp() {
        super.setUp()
        SecuritySwitchContext.update(config: ["privatePay": true])
        PrivatePayOverlayReadiness.reset()
    }

    override func tearDown() {
        SecuritySwitchContext.reset()
        SecuritySwitchContext.setReadForTests(true)
        PrivatePayOverlayReadiness.reset()
        RulebookRosterSnapshot.update([])
        OrganizationRulebookContext.update(from: nil)
        super.tearDown()
    }

    // MARK: Fixtures

    /// A users document after the strip: no pay fields, so the employment type reads as the default (self-employed).
    private func stripped(id: String = "PAYE-1", manager: Bool = false) -> AppUser {
        AppUser(
            id: id,
            email: "\(id.lowercased())@example.com",
            organizationId: "org-test",
            role: manager ? .manager : .operative,
            firstName: "Pat",
            surname: "Payee",
            isActive: true,
            passwordSet: true,
            permissions: manager ? UserPermissions(manager: true) : UserPermissions(operativeMode: true)
        )
    }

    private func payeProfile(_ id: String = "PAYE-1") -> [String: Any] {
        ["userId": id, "employmentType": "paye", "payBasis": "day", "dayRate": 180]
    }

    private func selfEmployedProfile(_ id: String) -> [String: Any] {
        ["userId": id, "employmentType": "self_employed", "payBasis": "day", "dayRate": 180]
    }

    /// The signed-in person's record with their profile laid over, as `scheduleOwnPayOverlay` builds it.
    private func overlaid(_ user: AppUser, profile: [String: Any]) -> AppUser {
        let result = UserStore.ownPayRecord(user: user, reads: [(id: user.id, read: true, data: profile)])
        XCTAssertTrue(result.readable)
        let state = OwnPayOverlayState(
            key: UserStore.ownPayKey(user: user, organizationId: nil),
            finished: true,
            readable: true,
            record: result.record
        )
        return UserStore.layingOwnPay(state, over: user, key: state.key, privatePay: true)
    }

    /// A store signed in as `user` whose own pay profile read has finished with `profile`.
    private func store(signedIn user: AppUser, profile: [String: Any]?) -> UserStore {
        let store = UserStore()
        store.currentUser = user
        let record = profile.flatMap {
            UserStore.ownPayRecord(user: user, reads: [(id: user.id, read: true, data: $0)]).record
        }
        store.ownPayOverlay = OwnPayOverlayState(
            key: UserStore.ownPayKey(user: user, organizationId: nil),
            finished: true,
            readable: true,
            record: record,
            recordConfirmed: record != nil
        )
        return store
    }

    // MARK: The overlay itself

    func testOwnRecordReadsThePayProfileOwnIdFirstThenAFormerId() {
        var user = stripped()
        user.formerUserIds = ["INVITE-OLD"]
        XCTAssertEqual(user.employmentType, .selfEmployed, "the stripped document reads as self-employed")
        let own = UserStore.ownPayRecord(user: user, reads: [
            (id: "PAYE-1", read: true, data: payeProfile()),
            (id: "INVITE-OLD", read: true, data: selfEmployedProfile("INVITE-OLD")),
        ])
        XCTAssertEqual(own.record?.employmentType, .paye, "own id first")
        let former = UserStore.ownPayRecord(user: user, reads: [
            (id: "PAYE-1", read: true, data: nil),
            (id: "INVITE-OLD", read: true, data: payeProfile("INVITE-OLD")),
        ])
        XCTAssertEqual(former.record?.employmentType, .paye, "else a former invite id")
        XCTAssertEqual(former.record?.dayRate, 180)
        let refused = UserStore.ownPayRecord(user: user, reads: [(id: "PAYE-1", read: false, data: nil)])
        XCTAssertNil(refused.record)
        XCTAssertFalse(refused.readable, "a refused own read is unreadable, never 'no profile'")
    }

    func testSwitchOffTheStoredDocumentIsUsedUnchanged() {
        SecuritySwitchContext.update(config: ["privatePay": false])
        let user = stripped()
        let record = UserStore.ownPayRecord(user: user, reads: [(id: user.id, read: true, data: payeProfile())]).record
        let state = OwnPayOverlayState(key: UserStore.ownPayKey(user: user, organizationId: nil), finished: true, readable: true, record: record)
        XCTAssertEqual(UserStore.layingOwnPay(state, over: user, key: state.key, privatePay: false), user)
        let store = UserStore()
        store.currentUser = user
        store.ownPayOverlay = state
        XCTAssertEqual(store.displayUser, user, "privatePay off: displayUser is the users document exactly")
        XCTAssertTrue(store.ownPayReady)
        XCTAssertNil(PrivatePayOverlayReadiness.blockMessage(scope: .ownPay, switchesKnown: true, privatePay: false, own: .failed, roster: .failed))
    }

    func testAReadForAnotherOrganisationOrPersonIsNeverLaidOver() {
        let user = stripped()
        let record = UserStore.ownPayRecord(user: user, reads: [(id: user.id, read: true, data: payeProfile())]).record
        let state = OwnPayOverlayState(key: UserStore.ownPayKey(user: user, organizationId: "ORG-A"), finished: true, readable: true, record: record)
        let otherKey = UserStore.ownPayKey(user: user, organizationId: "ORG-B")
        XCTAssertEqual(UserStore.layingOwnPay(state, over: user, key: otherKey, privatePay: true), user)
    }

    // MARK: Break 1 — My Timesheets for PAYE people

    func testBreak1MyTimesheetsIsHiddenForAPayePerson() {
        let user = stripped()
        XCTAssertTrue(
            TimesheetPayrollPolicy.canAccessMyTimesheets(user: user, settings: .default),
            "the stripped document alone would show My Timesheets"
        )
        let store = self.store(signedIn: user, profile: payeProfile())
        XCTAssertEqual(store.displayUser?.employmentType, .paye)
        XCTAssertFalse(store.canAccessMyTimesheets(), "PAYE: no My Timesheets")
    }

    func testBreak1NothingIsDecidedBeforeTheOwnProfileIsRead() {
        let store = UserStore()
        store.currentUser = stripped()
        // The read has not finished (no firebase backend in tests, so it never starts): wait, never decide on the
        // stripped document.
        XCTAssertFalse(store.ownPayReady)
        XCTAssertFalse(store.canAccessMyTimesheets())
        XCTAssertFalse(store.shouldShowTimesheetsDisabledMessage())
    }

    // MARK: Break 2 — the PAYE person's own Overtime, Expenses & Price Work button

    func testBreak2PayePersonKeepsTheirOwnOvertimeButton() {
        let user = stripped()
        let bare = CanonicalBusinessEngine.overtimeHubAccess(viewer: RulebookPeople.person(user), roster: [])
        XCTAssertFalse(bare.mine, "the stripped document alone loses My Overtime, Expenses & Price Work")
        let store = self.store(signedIn: user, profile: payeProfile())
        let access = store.overtimeHubAccess()
        XCTAssertTrue(access.mine)
        XCTAssertTrue(access.showButton)
    }

    // MARK: Break 3 — the own timesheet's rate and employment type

    func testBreak3OwnTimesheetIsPricedFromThePayProfile() {
        let user = stripped(id: "SE-1", manager: true)
        let booking = ManagerSiteBooking(
            userId: user.id,
            date: thursday,
            timeSlot: .fullDay,
            locationType: .project,
            locationId: UUID()
        )
        func collect(_ person: AppUser) -> TimesheetPayrollSummary {
            TimesheetPayrollCollector.collect(
                for: person,
                in: thursday...thursday,
                bookings: [],
                managerBookings: [booking],
                operatives: [],
                projects: [],
                smallWorks: [],
                history: .empty,
                policy: LogicFixtures.policy,
                relatedUsers: [person]
            )
        }
        XCTAssertClose(collect(user).baseAmount, 0, "stripped: rate not set")
        let store = self.store(signedIn: user, profile: selfEmployedProfile("SE-1"))
        guard let me = store.displayUser else { return XCTFail("signed in") }
        XCTAssertEqual(me.dayRate, 180)
        XCTAssertClose(collect(me).baseAmount, 180, "one full day at the profile's day rate")

        // A PAYE person's day is never a paid timesheet line (the stripped document would price it as self-employed).
        let payeStore = self.store(signedIn: stripped(id: "SE-1", manager: true), profile: payeProfile("SE-1"))
        guard let paye = payeStore.displayUser else { return XCTFail("signed in") }
        XCTAssertEqual(paye.employmentType(on: thursday), .paye)
        XCTAssertClose(collect(paye).baseAmount, 0)
    }

    // MARK: Break 4 — timesheet reminders

    func testBreak4PayePersonIsNotATimesheetParticipant() {
        let user = stripped()
        XCTAssertTrue(user.participatesInTimesheets(), "the stripped document alone would get timesheet reminders")
        let store = self.store(signedIn: user, profile: payeProfile())
        XCTAssertEqual(store.currentUserWithPay?.participatesInTimesheets(), false)
        // The reminder refresh also waits while the read is running (`NotificationService` checks `ownPayReady`).
        let waiting = UserStore()
        waiting.currentUser = user
        XCTAssertFalse(waiting.ownPayReady)
    }

    // MARK: Break 5 — the overtime "line reopened" notice (not changed here)
    // The PAYE pre-check stays as it was (review of #240): `overtimeReopenedRecipients` returns nobody unless the roster
    // row's employment type is PAYE, so skipping the pre-check gained nothing and added refused reads. Follow-up for the
    // web agent (shared rule).

    // MARK: Break 6 — signing waits for the pay overlays

    func testBreak6PayScreensWaitForThePayOverlaysTheyPrice() {
        func message(_ scope: PayOverlayScope, own: PayOverlayLoad, roster: PayOverlayLoad, privatePay: Bool = true) -> String? {
            PrivatePayOverlayReadiness.blockMessage(
                scope: scope, switchesKnown: true, privatePay: privatePay, own: own, roster: roster
            )
        }
        XCTAssertEqual(message(.ownPay, own: .loading, roster: .ready), PrivatePayOverlayReadiness.loadingMessage)
        XCTAssertEqual(message(.ownPay, own: .failed, roster: .ready), PrivatePayOverlayReadiness.ownFailedMessage)
        XCTAssertEqual(message(.othersPay, own: .ready, roster: .loading), PrivatePayOverlayReadiness.loadingMessage)
        XCTAssertNil(message(.ownPay, own: .ready, roster: .ready))
        XCTAssertNil(message(.othersPay, own: .failed, roster: .failed, privatePay: false), "switch off: never waits")

        // Sign-off, counter-signature, invoices, exports and the weekly report all go through this gate.
        let organization = Organization(firestoreDocumentId: "TEST-ORG-STRIP", name: "TEST-Company")
        PrivatePayOverlayReadiness.update(own: .loading, roster: .ready)
        XCTAssertEqual(PayInputsLoad.blockMessage(state: .loaded, organization: organization), PrivatePayOverlayReadiness.loadingMessage)
        PrivatePayOverlayReadiness.update(own: .ready, roster: .ready)
        XCTAssertNil(PayInputsLoad.blockMessage(state: .loaded, organization: organization))
        SecuritySwitchContext.update(config: ["privatePay": false])
        PrivatePayOverlayReadiness.update(own: .failed, roster: .failed)
        XCTAssertNil(PayInputsLoad.blockMessage(state: .loaded, organization: organization, scope: .othersPay))
    }

    // MARK: Review of #240, finding 1 — the switches not read yet

    func testFinding1NothingIsDecidedOrSignedBeforeTheSwitchesAreRead() {
        // Offline launch with no cached `platformConfig/app`: `privatePay` reads as false, but it is not known.
        SecuritySwitchContext.reset()
        SecuritySwitchContext.setReadForTests(false)
        let store = UserStore()
        store.currentUser = stripped()
        XCTAssertFalse(SecuritySwitchContext.privatePay)
        XCTAssertFalse(store.ownPayReady, "never decided on the stripped document while the switch is unknown")
        XCTAssertFalse(store.canAccessMyTimesheets())
        XCTAssertFalse(store.shouldShowTimesheetsDisabledMessage())
        let organization = Organization(firestoreDocumentId: "TEST-ORG-STRIP", name: "TEST-Company")
        XCTAssertEqual(PayInputsLoad.blockMessage(state: .loaded, organization: organization), PrivatePayOverlayReadiness.loadingMessage)
        XCTAssertEqual(
            PayInputsLoad.blockMessage(state: .loaded, organization: organization, scope: .othersPay),
            PrivatePayOverlayReadiness.loadingMessage,
            "no sign, counter-sign, export, invoice or weekly report either"
        )

        // The document answers with the switch off: everything decides on the users document as before.
        SecuritySwitchContext.update(config: ["privatePay": false])
        XCTAssertTrue(SecuritySwitchContext.hasRead)
        XCTAssertTrue(store.ownPayReady)
        XCTAssertNil(PayInputsLoad.blockMessage(state: .loaded, organization: organization))
    }

    func testFinding1TheFirstAnswerIsAnnouncedOnce() {
        SecuritySwitchContext.reset()
        SecuritySwitchContext.setReadForTests(false)
        let first = expectation(forNotification: .securitySwitchesFirstRead, object: nil)
        SecuritySwitchContext.update(config: nil)
        wait(for: [first], timeout: 2)
        let again = expectation(forNotification: .securitySwitchesFirstRead, object: nil)
        again.isInverted = true
        SecuritySwitchContext.update(config: nil)
        wait(for: [again], timeout: 0.5)
    }

    // MARK: Finding 2 — a failed roster overlay

    func testFinding2AFailedRosterOverlayBlocksOthersPayWithAMessage() {
        let roster = [stripped(id: "OP-1"), stripped(id: "OP-2")]
        let key = UserStore.rosterPaySubjectsKey(roster, organizationId: "ORG", viewerId: "ADMIN")
        XCTAssertEqual(UserStore.rosterPayLoadAfterFailure(cache: nil, key: key), .failed, "no good overlay: failed, never finished")
        let otherPeople = RosterPayProfileCache(key: key + "x", profiles: [:])
        XCTAssertEqual(UserStore.rosterPayLoadAfterFailure(cache: otherPeople, key: key), .failed)
        let samePeople = RosterPayProfileCache(key: key, profiles: ["OP-1": payeProfile("OP-1")])
        XCTAssertEqual(UserStore.rosterPayLoadAfterFailure(cache: samePeople, key: key), .ready, "the last good overlay is still laid over")

        let organization = Organization(firestoreDocumentId: "TEST-ORG-STRIP", name: "TEST-Company")
        PrivatePayOverlayReadiness.update(own: .ready, roster: .failed)
        XCTAssertEqual(
            PayInputsLoad.blockMessage(state: .loaded, organization: organization, scope: .othersPay),
            PrivatePayOverlayReadiness.rosterFailedMessage,
            "counter-sign, export, invoice and the weekly report say why"
        )
        XCTAssertNil(PayInputsLoad.blockMessage(state: .loaded, organization: organization, scope: .ownPay))
    }

    // MARK: Finding 3 — a failed own read

    func testFinding3AFailedOwnReadKeepsTheLastGoodRecordElseHolds() throws {
        let user = stripped()
        let key = UserStore.ownPayKey(user: user, organizationId: nil)
        let good = try XCTUnwrap(UserStore.ownPayRecord(user: user, reads: [(id: user.id, read: true, data: payeProfile())]).record)

        // A confirmed record is kept after a refusal or a failure: decisions and signing go on from it.
        let confirmed = OwnPayOverlayState(key: key, finished: true, readable: true, record: good, recordConfirmed: true)
        let afterFailure = UserStore.ownPayStateAfterRead(key: key, previous: confirmed, record: nil, readable: false, offline: false)
        XCTAssertEqual(afterFailure.record?.employmentType, .paye)
        XCTAssertTrue(UserStore.ownPayDecidable(afterFailure, key: key))
        XCTAssertEqual(UserStore.ownPayLoad(afterFailure, key: key), .ready)

        // With no good record, both decisions hold and signing says the read failed.
        let nothing = UserStore.ownPayStateAfterRead(key: key, previous: OwnPayOverlayState(key: key), record: nil, readable: false, offline: true)
        XCTAssertNil(nothing.record)
        XCTAssertFalse(UserStore.ownPayDecidable(nothing, key: key))
        XCTAssertEqual(UserStore.ownPayLoad(nothing, key: key), .failed)
        let store = UserStore()
        store.currentUser = user
        store.ownPayOverlay = nothing
        XCTAssertFalse(store.ownPayReady, "the reminder refresh writes nothing while this is false")
        XCTAssertFalse(store.canAccessMyTimesheets())
        XCTAssertFalse(store.shouldShowTimesheetsDisabledMessage())

        // Finding 5: the launch cache copy is dropped after a refusal (never "answered from the cache").
        let provisional = OwnPayOverlayState(key: key, finished: false, readable: true, record: good, recordConfirmed: false)
        let refused = UserStore.ownPayStateAfterRead(key: key, previous: provisional, record: nil, readable: false, offline: false)
        XCTAssertNil(refused.record)
        XCTAssertFalse(UserStore.ownPayDecidable(refused, key: key))
    }

    func testFinding5OnlyAnOfflineFailureMayUseThePhonesCopy() {
        XCTAssertFalse(FirebaseBackend.payProfileReadErrorIsOffline(domain: "FIRFirestoreErrorDomain", code: 7), "permission denied")
        XCTAssertTrue(FirebaseBackend.payProfileReadErrorIsOffline(domain: "FIRFirestoreErrorDomain", code: 14), "unavailable")
        XCTAssertTrue(FirebaseBackend.payProfileReadErrorIsOffline(domain: "FIRFirestoreErrorDomain", code: 4), "deadline exceeded")
        XCTAssertTrue(FirebaseBackend.payProfileReadErrorIsOffline(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet))
        XCTAssertFalse(FirebaseBackend.payProfileReadErrorIsOffline(domain: "FIRFirestoreErrorDomain", code: 5))
    }

    func testFinding8TheLaunchCopyDecidesMyTimesheetsButSigningWaitsForTheServer() throws {
        let user = stripped()
        let key = UserStore.ownPayKey(user: user, organizationId: nil)
        let cached = try XCTUnwrap(UserStore.ownPayRecord(user: user, reads: [(id: user.id, read: true, data: payeProfile())]).record)
        let store = UserStore()
        store.currentUser = user
        store.ownPayOverlay = OwnPayOverlayState(key: key, finished: false, readable: true, record: cached, recordConfirmed: false)
        XCTAssertTrue(store.ownPayReady, "no hide-then-show of My Timesheets while the server read runs")
        XCTAssertFalse(store.canAccessMyTimesheets(), "PAYE from the last good copy")
        XCTAssertEqual(UserStore.ownPayLoad(store.ownPayOverlay, key: key), .loading, "signing waits for the server")
    }

    func testFinding9AnAdminsFailedOwnReadDoesNotBlockOthersSheets() {
        let organization = Organization(firestoreDocumentId: "TEST-ORG-STRIP", name: "TEST-Company")
        PrivatePayOverlayReadiness.update(own: .failed, roster: .ready)
        XCTAssertNil(
            PayInputsLoad.blockMessage(state: .loaded, organization: organization, bookings: (loaded: true, failed: false), scope: .othersPay),
            "counter-signing others and the weekly report go on"
        )
        XCTAssertEqual(
            PayInputsLoad.blockMessage(state: .loaded, organization: organization, scope: .ownPay),
            PrivatePayOverlayReadiness.ownFailedMessage
        )
    }

    // MARK: Finding 4 — roster refreshes

    func testFinding4ARefreshOfTheSamePeopleStaysReadyAndKeepsThePay() {
        let roster = [stripped(id: "OP-1"), stripped(id: "OP-2")]
        let key = UserStore.rosterPaySubjectsKey(roster, organizationId: "ORG", viewerId: "ADMIN")
        XCTAssertEqual(
            UserStore.rosterPaySubjectsKey(roster.reversed(), organizationId: "ORG", viewerId: "ADMIN"), key,
            "order does not change the people"
        )
        let cache = RosterPayProfileCache(key: key, profiles: ["OP-1": payeProfile("OP-1")])

        // A new snapshot of the same people (stripped again): laid over at once, ready — no "Loading pay details…".
        let same = UserStore.rosterPayAfterSnapshot(roster, cache: cache, key: key)
        XCTAssertEqual(same.load, .ready)
        XCTAssertEqual(same.users.first { $0.id == "OP-1" }?.employmentType, .paye)
        XCTAssertEqual(same.users.first { $0.id == "OP-1" }?.dayRate, 180)

        // Someone joined: not ready until the overlay of the new set answers.
        let grown = roster + [stripped(id: "OP-3")]
        let grownKey = UserStore.rosterPaySubjectsKey(grown, organizationId: "ORG", viewerId: "ADMIN")
        XCTAssertNotEqual(grownKey, key)
        let next = UserStore.rosterPayAfterSnapshot(grown, cache: cache, key: grownKey)
        XCTAssertEqual(next.load, .loading)
        XCTAssertEqual(next.users, grown)
        XCTAssertEqual(UserStore.rosterPayAfterSnapshot(roster, cache: nil, key: key).load, .loading, "first overlay")
    }

    func testFinding4ACounterSignatureNeverSavesWithoutItsSnapshot() {
        OrganizationRulebookContext.update(
            from: Organization(firestoreDocumentId: "TEST-ORG-STRIP", name: "TEST-Company", creatorUserId: "TEST-FOUNDER")
        )
        let manager = AppUser(
            id: "TEST-LM", email: "lm@example.test", organizationId: "TEST-ORG-STRIP", role: .manager,
            firstName: "Line", surname: "Manager", isActive: true, passwordSet: true,
            permissions: UserPermissions(manager: true)
        )
        var operative = AppUser(
            id: "TEST-OP", email: "op@example.test", organizationId: "TEST-ORG-STRIP", role: .operative,
            firstName: "Op", surname: "Erative", isActive: true, passwordSet: true,
            permissions: UserPermissions(operativeMode: true), dayRate: 200, employmentType: .selfEmployed
        )
        operative.setLineManagerUserIds([manager.id])
        RulebookRosterSnapshot.update([manager, operative])

        var draft = TimesheetDraft()
        draft.operativeSignedAt = thursday
        draft.operativeSignedByName = "Op Erative"
        draft.managerSignedAt = thursday.addingTimeInterval(60)
        draft.managerSignedByName = "Line Manager"
        XCTAssertTrue(TimesheetApprovalPolicy.isTimesheetFullyApproved(draft: draft, user: operative))
        let loading = PrivatePayOverlayReadiness.loadingMessage
        func refusal(_ d: TimesheetDraft, block: String?, reviewer: Bool? = true, rebuild: Bool = false) -> String? {
            TimesheetWeeklyReportOverrideBuilder.saveRefusalWhilePayInputsBlocked(
                draft: d, user: operative, writerIsReviewer: reviewer, blockMessage: block, rebuildSnapshot: rebuild
            )
        }
        // The roster refresh is in flight while the line manager counter-signs: refused, never saved unfrozen.
        XCTAssertEqual(refusal(draft, block: loading), loading)
        XCTAssertNil(refusal(draft, block: nil), "inputs ready: the snapshot is built and saved")
        // A sheet that already holds its snapshot keeps it (a note, a review): the save goes on.
        var frozen = draft
        frozen.weeklyReportOverride = TimesheetWeeklyReportOverride(
            approvedAt: thursday, approvedByUserId: manager.id, approvedByName: "Line Manager", selfSigned: false,
            lines: [], priceWork: [], expenses: []
        )
        XCTAssertNil(refusal(frozen, block: loading))
        XCTAssertEqual(refusal(frozen, block: loading, rebuild: true), loading, "a reopened sheet's rebuild waits too")
        // Not completed by this save, or the owner's own save with a line manager: nothing to freeze.
        var halfSigned = draft
        halfSigned.managerSignedAt = nil
        halfSigned.managerSignedByName = nil
        XCTAssertNil(refusal(halfSigned, block: loading))
        XCTAssertNil(refusal(draft, block: loading, reviewer: false))
    }

    // MARK: Break 7 — the PAYE note on Edit booking

    func testBreak7PayeNoteFollowsReadablePayOnly() {
        let id = UUID()
        let user = stripped(id: id.uuidString)
        let booking = LogicFixtures.booking(on: thursday, operativeId: id)
        XCTAssertFalse(
            LabourBookingEditOptions.isPaye(booking, operatives: [], users: [user]),
            "pay not readable by this viewer: no note (RULEBOOK §8 — the employment type is pay data)"
        )
        let shown = overlaid(user, profile: payeProfile(id.uuidString))
        XCTAssertTrue(LabourBookingEditOptions.isPaye(booking, operatives: [], users: [shown]), "readable pay: the note shows")
    }
}
