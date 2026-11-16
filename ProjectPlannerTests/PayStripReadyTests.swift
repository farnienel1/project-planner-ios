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
        PrivatePayOverlayReadiness.reset()
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
            record: record
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
        XCTAssertNil(PrivatePayOverlayReadiness.blockMessage(privatePay: false, ownFinished: false, ownReadable: false, rosterFinished: false))
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

    // MARK: Break 5 — the overtime "line reopened" notice

    func testBreak5UnreadablePersonIsNotRuledOutAsSelfEmployed() {
        let person = stripped(id: "OTHER-1")
        XCTAssertTrue(
            OvertimeReopenNotice.mayBePaye(person, privatePay: true, payProfileReadIds: []),
            "privatePay on, pay not readable: let overtimeLineReopened decide"
        )
        XCTAssertFalse(
            OvertimeReopenNotice.mayBePaye(person, privatePay: true, payProfileReadIds: ["other-1"]),
            "pay read and self-employed: skip"
        )
        XCTAssertFalse(OvertimeReopenNotice.mayBePaye(person, privatePay: false, payProfileReadIds: []), "switch off: as before")
        let paye = overlaid(person, profile: payeProfile("OTHER-1"))
        XCTAssertTrue(OvertimeReopenNotice.mayBePaye(paye, privatePay: true, payProfileReadIds: ["other-1"]))
    }

    func testBreak5SignedInPersonCountsAsReadOnceTheirProfileIsRead() {
        let store = self.store(signedIn: stripped(), profile: payeProfile())
        XCTAssertTrue(store.payProfileReadIds.contains("paye-1"))
    }

    // MARK: Break 6 — signing waits for the pay overlays

    func testBreak6PayScreensWaitForThePayOverlays() {
        XCTAssertEqual(
            PrivatePayOverlayReadiness.blockMessage(privatePay: true, ownFinished: false, ownReadable: true, rosterFinished: true),
            PrivatePayOverlayReadiness.loadingMessage
        )
        XCTAssertEqual(
            PrivatePayOverlayReadiness.blockMessage(privatePay: true, ownFinished: true, ownReadable: true, rosterFinished: false),
            PrivatePayOverlayReadiness.loadingMessage,
            "a reviewer waits for the roster's pay profiles too"
        )
        XCTAssertEqual(
            PrivatePayOverlayReadiness.blockMessage(privatePay: true, ownFinished: true, ownReadable: false, rosterFinished: true),
            PrivatePayOverlayReadiness.ownFailedMessage
        )
        XCTAssertNil(PrivatePayOverlayReadiness.blockMessage(privatePay: true, ownFinished: true, ownReadable: true, rosterFinished: true))

        // Sign-off, counter-signature, invoices, exports and the weekly report all go through this gate.
        let organization = Organization(firestoreDocumentId: "TEST-ORG-STRIP", name: "TEST-Company")
        PrivatePayOverlayReadiness.update(ownFinished: false, ownReadable: true, rosterFinished: true)
        XCTAssertEqual(PayInputsLoad.blockMessage(state: .loaded, organization: organization), PrivatePayOverlayReadiness.loadingMessage)
        PrivatePayOverlayReadiness.update(ownFinished: true, ownReadable: true, rosterFinished: true)
        XCTAssertNil(PayInputsLoad.blockMessage(state: .loaded, organization: organization))
        // privatePay off: never waits.
        SecuritySwitchContext.update(config: ["privatePay": false])
        PrivatePayOverlayReadiness.update(ownFinished: false, ownReadable: false, rosterFinished: false)
        XCTAssertNil(PayInputsLoad.blockMessage(state: .loaded, organization: organization))
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
