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

    func testFinding2OneFailedReadBlocksOnlyThatPerson() {
        var stale = stripped(id: "OP-1")
        stale.formerUserIds = ["OLD-1"]
        let fine = stripped(id: "OP-2")
        let roster = [stale, fine]
        // OP-1's read was refused and nothing answered for any of their ids; OP-2 answered.
        let failed = FirebaseBackend.rosterFailedUserIds(
            roster,
            profiles: ["OP-2": payeProfile("OP-2")],
            failedProfileIds: ["OP-1"]
        )
        XCTAssertEqual(failed, ["op-1"])
        XCTAssertEqual(
            FirebaseBackend.rosterFailedUserIds(roster, profiles: ["OLD-1": payeProfile("OP-1")], failedProfileIds: ["OP-1"]),
            [],
            "a former id that answered is enough"
        )

        // The line manager's team: only OP-1's screens wait, with a message naming them.
        PrivatePayOverlayReadiness.update(own: .ready, roster: .ready, failedPersonIds: failed)
        let organization = Organization(firestoreDocumentId: "TEST-ORG-STRIP", name: "TEST-Company")
        XCTAssertEqual(
            PayInputsLoad.blockMessage(state: .loaded, organization: organization, scope: .forPerson(stale)),
            PrivatePayOverlayReadiness.personFailedMessage("Pat Payee")
        )
        XCTAssertNil(PayInputsLoad.blockMessage(state: .loaded, organization: organization, scope: .forPerson(fine)))
        XCTAssertNil(PayInputsLoad.blockMessage(state: .loaded, organization: organization, scope: .othersPay), "the team goes on")
        XCTAssertTrue(PrivatePayOverlayReadiness.personPayFailed(stale), "Export skips and names them")
        XCTAssertFalse(PrivatePayOverlayReadiness.personPayFailed(fine))
        // While the first overlay is loading, a person's screens say "Loading", and Export does not count it a failure.
        PrivatePayOverlayReadiness.update(own: .ready, roster: .loading)
        XCTAssertEqual(PrivatePayOverlayReadiness.blockMessage(scope: .forPerson(fine)), PrivatePayOverlayReadiness.loadingMessage)
        XCTAssertFalse(PrivatePayOverlayReadiness.personPayFailed(fine))
    }

    func testFinding2AFailedRefreshKeepsTheLastGoodCopyOfThatPerson() {
        let roster = [stripped(id: "OP-1"), stripped(id: "OP-2")]
        let key = UserStore.rosterPaySubjectsKey(roster, organizationId: "ORG", viewerId: "LM")
        let good = RosterPayProfileCache(key: key, profiles: ["OP-1": payeProfile("OP-1"), "OP-2": payeProfile("OP-2")])
        // A refresh: OP-1's read now fails; the copy of OP-1 from the last good overlay stays, nobody is blocked.
        let refresh = RosterPayOverlayResult(users: roster, profiles: ["OP-2": payeProfile("OP-2")], failedUserIds: ["op-1"])
        let merged = UserStore.rosterPayAfterResult(roster, result: refresh, cache: good, key: key)
        XCTAssertTrue(merged.failedIds.isEmpty)
        XCTAssertEqual(merged.users.first { $0.id == "OP-1" }?.employmentType, .paye)
        // No good copy: only OP-1 is failed.
        let first = UserStore.rosterPayAfterResult(roster, result: refresh, cache: nil, key: key)
        XCTAssertEqual(first.failedIds, ["op-1"])
        XCTAssertEqual(first.cache?.failedIds, ["op-1"])
    }

    func testFinding6APartialCacheAnswerIsNeverKeptAsLastGood() {
        let roster = [stripped(id: "OP-1"), stripped(id: "OP-2")]
        let key = UserStore.rosterPaySubjectsKey(roster, organizationId: "ORG", viewerId: "ADMIN")
        let offline = RosterPayOverlayResult(
            users: FirebaseBackend.layingRosterPayProfiles(roster, profiles: ["OP-2": payeProfile("OP-2")]),
            profiles: ["OP-2": payeProfile("OP-2")],
            failedUserIds: [],
            fromCache: true
        )
        let first = UserStore.rosterPayAfterResult(roster, result: offline, cache: nil, key: key)
        XCTAssertNil(first.cache, "not saved as last good")
        XCTAssertEqual(first.failedIds, ["op-1", "op-2"], "nothing about them is signed or exported until the server answers")
        let good = RosterPayProfileCache(key: key, profiles: ["OP-1": payeProfile("OP-1")])
        let kept = UserStore.rosterPayAfterResult(roster, result: offline, cache: good, key: key)
        XCTAssertEqual(kept.cache?.profiles.keys.sorted(), ["OP-1"], "the last good overlay stays")
        XCTAssertEqual(kept.users.first { $0.id == "OP-2" }?.employmentType, .selfEmployed, "shown from the last good copy")
    }

    func testFinding6PayIsAlwaysLaidOverTheRawRows() {
        let raw = [stripped(id: "OP-1")]
        let shown = FirebaseBackend.layingRosterPayProfiles(raw, profiles: ["OP-1": payeProfile("OP-1")])
        XCTAssertEqual(shown.first?.dayRate, 180)
        let laid = UserStore.rosterPayLaidMap(raw: raw, shown: shown)
        // The next overlay starts from the raw row; the profile was deleted meanwhile, so no old pay stays.
        let back = UserStore.rosterRawRows(shown, laid: laid)
        XCTAssertEqual(back, raw)
        XCTAssertEqual(FirebaseBackend.layingRosterPayProfiles(back, profiles: [:]), raw)
        // A row whose pay changed since (a new snapshot, an edit) is the document's own and is not touched.
        var edited = shown[0]
        edited.dayRate = 200
        XCTAssertEqual(UserStore.rosterRawRows([edited], laid: laid).first?.dayRate, 200)
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

    // MARK: Second review — reminder, first answer, the own-read wiring

    func testReminderWaitsForTheServerNotTheLaunchCopy() throws {
        let user = stripped()
        let key = UserStore.ownPayKey(user: user, organizationId: nil)
        let cached = try XCTUnwrap(UserStore.ownPayRecord(user: user, reads: [(id: user.id, read: true, data: payeProfile())]).record)
        let store = UserStore()
        store.currentUser = user
        store.ownPayOverlay = OwnPayOverlayState(key: key, finished: false, readable: true, record: cached, recordConfirmed: false)
        XCTAssertTrue(store.ownPayReady, "My Timesheets decides from the launch copy")
        XCTAssertFalse(store.ownPaySettled, "no reminder row is written or removed from it")
        store.ownPayOverlay = OwnPayOverlayState(key: key, finished: true, readable: true, record: cached, recordConfirmed: true)
        XCTAssertTrue(store.ownPaySettled)
    }

    func testTheFirstAnswerSaysWhetherTheSwitchesChanged() {
        SecuritySwitchContext.reset()
        SecuritySwitchContext.setReadForTests(false)
        let first = expectation(forNotification: .securitySwitchesFirstRead, object: nil) { note in
            (note.userInfo?["switchesChanged"] as? Bool) == true
        }
        // `privatePay` on at the first answer: `securitySwitchesDidChange` starts the overlays, the first read does not.
        SecuritySwitchContext.update(config: ["privatePay": true])
        wait(for: [first], timeout: 2)
    }

    func testOwnReadWiringCacheThenServerThenRetry() async throws {
        let previousDelay = UserStore.payOverlayRetryDelayNanoseconds
        UserStore.payOverlayRetryDelayNanoseconds = 50_000_000
        defer { UserStore.payOverlayRetryDelayNanoseconds = previousDelay }
        let user = stripped()
        let reader = FakePayProfileReader()
        reader.cached = payeProfile()
        // First server read: refused. The retry: answered.
        reader.serverAnswers = [
            PayProfileRead(read: false, data: nil, offline: false),
            PayProfileRead(read: true, data: payeProfile(), offline: false),
        ]
        let store = UserStore()
        store.ownPayOrganizationIdOverride = "TEST-ORG"
        store.payProfileReaderOverride = reader
        store.currentUser = user

        // The launch copy decides first; signing waits.
        try await waitUntil { store.ownPayOverlay.record != nil || store.ownPayOverlay.finished }
        // The refusal drops the launch copy (never "answered from the cache") and holds the decisions.
        try await waitUntil { store.ownPayOverlay.finished && !store.ownPayOverlay.readable }
        XCTAssertNil(store.ownPayOverlay.record)
        XCTAssertFalse(store.ownPayReady)
        XCTAssertEqual(reader.serverReadOrganizations, ["TEST-ORG"], "the organisation captured when the read began")
        // The retry (same generation) answers: PAYE, confirmed.
        try await waitUntil { store.ownPayOverlay.readable && store.ownPayOverlay.finished }
        XCTAssertEqual(store.ownPayOverlay.record?.employmentType, .paye)
        XCTAssertTrue(store.ownPaySettled)
        XCTAssertFalse(store.canAccessMyTimesheets())
        XCTAssertEqual(reader.serverReads, 2)

        // A newer read (another organisation) drops an older answer.
        reader.serverAnswers = [PayProfileRead(read: true, data: selfEmployedProfile("PAYE-1"), offline: false)]
        store.ownPayOrganizationIdOverride = "TEST-ORG-2"
        store.scheduleOwnPayOverlay()
        try await waitUntil { store.ownPayOverlay.key.hasPrefix("TEST-ORG-2") && store.ownPayOverlay.finished }
        XCTAssertEqual(store.ownPayOverlay.record?.employmentType, .selfEmployed)
    }

    private func waitUntil(_ condition: @MainActor () -> Bool, timeout: TimeInterval = 3) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { return XCTFail("timed out") }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    // MARK: Third review

    func testReportsWaitOnlyForThePeopleTheyPriceAndNameThem() {
        let priced = stripped(id: "OP-1")
        let other = stripped(id: "OP-2")
        func gate(_ people: [AppUser], roster: PayOverlayLoad = .ready, failed: Set<String> = []) -> ReportPayGate {
            PrivatePayOverlayReadiness.reportGate(
                people: people, switchesKnown: true, privatePay: true, roster: roster, failedPersonIds: failed
            )
        }
        XCTAssertEqual(gate([priced], failed: ["op-2"]).status, .ready, "someone with no rows never blocks it")
        let refused = gate([priced, other], failed: ["op-1"])
        XCTAssertEqual(refused.status, .failed)
        XCTAssertEqual(refused.message, PrivatePayOverlayReadiness.reportPeopleFailedMessage(["Pat Payee"]), "named, never priced as Rate not set / £0")
        var alias = stripped(id: "OP-9")
        alias.formerUserIds = ["Old-1"]
        XCTAssertEqual(gate([alias], failed: ["old-1"]).status, .failed, "matched over every id, without case")
        XCTAssertEqual(gate([priced], roster: .loading), ReportPayGate(status: .loading, message: nil), "Loading… while the organisation loads")
        XCTAssertEqual(gate([priced], roster: .failed).message, PrivatePayOverlayReadiness.reportFailedMessage)
        XCTAssertEqual(
            PrivatePayOverlayReadiness.reportGate(people: [priced], switchesKnown: true, privatePay: false, roster: .failed, failedPersonIds: ["op-1"]).status,
            .ready
        )
    }

    func testAReusedLastGoodServerOverlayLetsTheReportRunOffline() {
        let roster = [stripped(id: "OP-1")]
        let key = UserStore.rosterPaySubjectsKey(roster, organizationId: "ORG", viewerId: "ADMIN")
        let good = RosterPayProfileCache(key: key, profiles: ["OP-1": payeProfile("OP-1")])
        let offline = RosterPayOverlayResult(users: roster, profiles: [:], failedUserIds: [], fromCache: true)
        let merged = UserStore.rosterPayAfterResult(roster, result: offline, cache: good, key: key)
        XCTAssertNotNil(merged.cache, "the last good server overlay is kept, so the people are covered")
        XCTAssertTrue(merged.failedIds.isEmpty)
        XCTAssertEqual(
            PrivatePayOverlayReadiness.reportGate(
                people: roster, switchesKnown: true, privatePay: true, roster: .ready, failedPersonIds: merged.failedIds
            ).status,
            .ready,
            "rulebook §2: read-only offline from the last synced data"
        )
    }

    func testPricedPeopleAreThoseOfTheBookingsWeeksAndSheets() {
        let a = stripped(id: "OP-A")
        let b = stripped(id: "OP-B")
        let people: [String: WeeklyReportPayInputs.Person] = [
            "OP-A": WeeklyReportPayInputs.Person(id: "OP-A", name: "A", role: "", user: a, operative: nil, ids: ["OP-A", "Old-A"], operativeIds: []),
            "OP-B": WeeklyReportPayInputs.Person(id: "OP-B", name: "B", role: "", user: b, operative: nil, ids: ["OP-B"], operativeIds: []),
        ]
        let built = WeeklyReportPayInputs.Built(
            input: ["bookings": [["personId": "old-a"]], "timesheetWeeks": [], "sheets": []],
            people: people
        )
        XCTAssertEqual(WeeklyReportPayInputs.pricedUserIds(built), ["OP-A"], "without case, over every id; B has no rows")
    }

    func testRowsAreLookedUpAgainWithTheirPayLaidOver() {
        let kept = stripped(id: "OP-1")
        let live = overlaid(kept, profile: payeProfile("OP-1"))
        var differentCase = live
        differentCase.id = "op-1"
        XCTAssertEqual(UserStore.livePerson(kept, in: [differentCase]).employmentType, .paye)
        XCTAssertEqual(UserStore.livePerson(kept, in: []), kept, "not on the roster: as kept")
    }

    func testASavedProfileIsLaidOverNotTheOldOne() {
        let roster = [stripped(id: "OP-1")]
        let key = UserStore.rosterPaySubjectsKey(roster, organizationId: "ORG", viewerId: "ADMIN")
        let cache = RosterPayProfileCache(key: key, profiles: ["OP-1": payeProfile("OP-1")], failedIds: ["op-1"])
        let saved = UserStore.rosterPayCacheAfterSave(cache, subjectId: "OP-1", fields: ["employmentType": "self_employed", "dayRate": 220])
        let shown = UserStore.rosterPayAfterSnapshot(roster, cache: saved, key: key)
        XCTAssertEqual(shown.users.first?.employmentType, .selfEmployed)
        XCTAssertEqual(shown.users.first?.dayRate, 220)
        XCTAssertTrue(shown.failedIds.isEmpty)
        var me = stripped(id: "ME")
        me.formerUserIds = ["INVITE-1"]
        XCTAssertTrue(UserStore.payProfileSaveIsOwn(subjectId: "invite-1", user: me), "own pay read again after a save")
        XCTAssertFalse(UserStore.payProfileSaveIsOwn(subjectId: "OP-1", user: me))
    }

    func testPrivatePayWithNoOrganisationYetIsLoadingNotReady() {
        let store = UserStore()
        store.organizationUsers = [stripped(id: "OP-1")]
        XCTAssertEqual(store.rosterPayOverlayLoad, .loading)
        SecuritySwitchContext.update(config: ["privatePay": false])
        store.organizationUsers = [stripped(id: "OP-2")]
        XCTAssertEqual(store.rosterPayOverlayLoad, .ready)
    }

    func testOfflineCachedNoProfileIsUnknown() {
        let user = stripped()
        let key = UserStore.ownPayKey(user: user, organizationId: nil)
        let state = UserStore.ownPayStateAfterRead(
            key: key, previous: OwnPayOverlayState(key: key), record: nil, readable: true, offline: true, fromCache: true
        )
        XCTAssertFalse(UserStore.ownPayDecidable(state, key: key), "never settles My Timesheets on the stripped document")
        let store = UserStore()
        store.currentUser = user
        store.ownPayOverlay = state
        XCTAssertFalse(store.ownPayReady)
        XCTAssertFalse(store.canAccessMyTimesheets())
        XCTAssertFalse(store.shouldShowTimesheetsDisabledMessage())
    }

    func testEveryoneFailedIsNeverReady() {
        let roster = [stripped(id: "OP-1"), stripped(id: "OP-2")]
        XCTAssertEqual(UserStore.rosterPayLoadAfterResult(roster, failedIds: ["op-1", "op-2"]), .failed)
        XCTAssertEqual(UserStore.rosterPayLoadAfterResult(roster, failedIds: ["op-1"]), .ready)
        XCTAssertEqual(UserStore.rosterPayLoadAfterResult(roster, failedIds: []), .ready)
        // An all-or-nothing `.all` read that failed with no good copy: everyone failed, so not ready.
        let key = UserStore.rosterPaySubjectsKey(roster, organizationId: "ORG", viewerId: "ADMIN")
        let failedAll = RosterPayOverlayResult(users: roster, profiles: [:], failedUserIds: ["op-1", "op-2"])
        let merged = UserStore.rosterPayAfterResult(roster, result: failedAll, cache: nil, key: key)
        XCTAssertEqual(UserStore.rosterPayLoadAfterResult(roster, failedIds: merged.failedIds), .failed)
        PrivatePayOverlayReadiness.update(own: .ready, roster: .failed, failedPersonIds: merged.failedIds)
        XCTAssertEqual(PrivatePayOverlayReadiness.blockMessage(scope: .othersPay), PrivatePayOverlayReadiness.rosterFailedMessage)
    }

    func testOfflineFirstLaunchCacheMissNeverDecidesPrivatePayOff() {
        XCTAssertTrue(ForcedUpdateGate.ignoresUnknownCacheMiss(exists: false, fromCache: true, switchesKnown: false))
        XCTAssertFalse(ForcedUpdateGate.ignoresUnknownCacheMiss(exists: false, fromCache: false, switchesKnown: false), "the server says no document")
        XCTAssertFalse(ForcedUpdateGate.ignoresUnknownCacheMiss(exists: true, fromCache: true, switchesKnown: false), "a cached document is an answer")
        XCTAssertFalse(ForcedUpdateGate.ignoresUnknownCacheMiss(exists: false, fromCache: true, switchesKnown: true))
    }

    func testOwnProfileFromThePhonesCacheIsShownButNeverPricedOrSigned() throws {
        let user = stripped()
        let key = UserStore.ownPayKey(user: user, organizationId: nil)
        let record = try XCTUnwrap(UserStore.ownPayRecord(user: user, reads: [(id: user.id, read: true, data: payeProfile())]).record)
        let offline = UserStore.ownPayStateAfterRead(
            key: key, previous: OwnPayOverlayState(key: key), record: record, readable: true, offline: true, fromCache: true
        )
        XCTAssertTrue(offline.answeredFromCache)
        XCTAssertFalse(offline.recordConfirmed)
        XCTAssertTrue(UserStore.ownPayDecidable(offline, key: key), "shown")
        XCTAssertEqual(UserStore.ownPayLoad(offline, key: key), .loading, "never priced or signed from")
        let store = UserStore()
        store.currentUser = user
        store.ownPayOverlay = offline
        XCTAssertFalse(store.ownPaySettled, "no reminder row from it")
        // A record the server confirmed earlier stays confirmed.
        let confirmed = OwnPayOverlayState(key: key, finished: true, readable: true, record: record, recordConfirmed: true)
        let later = UserStore.ownPayStateAfterRead(key: key, previous: confirmed, record: record, readable: true, offline: true, fromCache: true)
        XCTAssertEqual(UserStore.ownPayLoad(later, key: key), .ready)
    }

    func testOwnReadFromCacheIsReadAgain() async throws {
        let previousDelay = UserStore.payOverlayRetryDelayNanoseconds
        UserStore.payOverlayRetryDelayNanoseconds = 50_000_000
        defer { UserStore.payOverlayRetryDelayNanoseconds = previousDelay }
        let reader = FakePayProfileReader()
        reader.serverAnswers = [
            PayProfileRead(read: true, data: payeProfile(), offline: true),
            PayProfileRead(read: true, data: payeProfile(), offline: false),
        ]
        let store = UserStore()
        store.ownPayOrganizationIdOverride = "TEST-ORG"
        store.payProfileReaderOverride = reader
        store.currentUser = stripped()
        try await waitUntil { store.ownPayOverlay.finished && store.ownPayOverlay.answeredFromCache }
        XCTAssertFalse(store.ownPaySettled)
        try await waitUntil { store.ownPayOverlay.finished && !store.ownPayOverlay.answeredFromCache }
        XCTAssertTrue(store.ownPaySettled)
        XCTAssertEqual(reader.serverReads, 2)
    }

    func testChangedPeopleKeepTheLastGoodPayForThoseStillPresent() {
        let roster = [stripped(id: "OP-1"), stripped(id: "OP-2")]
        let scope = UserStore.rosterPayScopeKey(organizationId: "ORG", viewerId: "LM")
        let key = UserStore.rosterPaySubjectsKey(roster, organizationId: "ORG", viewerId: "LM")
        let cache = RosterPayProfileCache(key: key, profiles: ["OP-1": payeProfile("OP-1")], scope: scope)
        let grown = roster + [stripped(id: "OP-3")]
        let grownKey = UserStore.rosterPaySubjectsKey(grown, organizationId: "ORG", viewerId: "LM")
        let next = UserStore.rosterPayAfterSnapshot(grown, cache: cache, key: grownKey, scope: scope)
        XCTAssertEqual(next.load, .loading, "the new person's pay is still being read")
        XCTAssertEqual(next.users.first { $0.id == "OP-1" }?.employmentType, .paye, "never a stripped row for OP-1")
        let otherViewer = UserStore.rosterPayScopeKey(organizationId: "ORG", viewerId: "OTHER")
        XCTAssertEqual(UserStore.rosterPayAfterSnapshot(grown, cache: cache, key: grownKey, scope: otherViewer).users, grown)
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

/// A `payProfiles` reader for the own-pay wiring test: a cached copy and a queue of server answers.
@MainActor
private final class FakePayProfileReader: PayProfileReading {
    var cached: [String: Any]?
    var serverAnswers: [PayProfileRead] = []
    private(set) var serverReads = 0
    private(set) var serverReadOrganizations: [String] = []

    func cachedPayProfile(organizationId: String, subjectId: String) async -> [String: Any]? { cached }

    func readPayProfile(organizationId: String, subjectId: String, cacheWhenOffline: Bool) async -> PayProfileRead {
        serverReads += 1
        if serverReadOrganizations.last != organizationId { serverReadOrganizations.append(organizationId) }
        guard !serverAnswers.isEmpty else { return PayProfileRead(read: false, data: nil, offline: true) }
        return serverAnswers.removeFirst()
    }
}
