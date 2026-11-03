import XCTest
import FirebaseFirestore
@testable import Project_Planner

/// RULEBOOK 1.10.0 §2, §8, §11, §16, §17 through `CanonicalBusinessEngine`: job visibility and the job editor gates,
/// booking write and delete gates, the rules-compatible read plans, the Daily Overview / warnings scope, user delete
/// refusals and the pay-history refusal. Expected values were checked in Node against the packed script
/// (admin vs manager with a toggle vs restricted manager vs operative).
@MainActor
final class Rulebook1100JobAccessTests: XCTestCase {
    private typealias Role = CanonicalBusinessEngine.CanonicalStaffAccountRole

    private func viewer(
        _ role: Role,
        projects: Bool = false,
        smallWorks: Bool = false,
        uid: String
    ) -> JobAccessViewer {
        JobAccessViewer(role: role, projectsToggle: projects, smallWorksToggle: smallWorks, uid: uid, ids: [uid], email: "\(uid)@x.t")
    }

    private var admin: JobAccessViewer {
        viewer(Role(isSuperAdmin: false, isAdmin: true, isManager: false, isOperativeMode: false), uid: "a1")
    }

    private var toggleManager: JobAccessViewer {
        viewer(Role(isSuperAdmin: false, isAdmin: false, isManager: true, isOperativeMode: false), projects: true, uid: "t1")
    }

    private var manager: JobAccessViewer {
        viewer(Role(isSuperAdmin: false, isAdmin: false, isManager: true, isOperativeMode: false), uid: "m1")
    }

    private var operative: JobAccessViewer {
        viewer(Role(isSuperAdmin: false, isAdmin: false, isManager: false, isOperativeMode: true), uid: "o1")
    }

    private func managedBy(_ uid: String) -> [String: Any] { ["managerUserIds": [uid]] }

    // MARK: Job visibility and the editor

    func testCanSeeJobByRoleAndToggle() {
        XCTAssertTrue(CanonicalBusinessEngine.canSeeJob(admin, job: managedBy("zz"), managers: [], kind: .projects))
        XCTAssertTrue(CanonicalBusinessEngine.canSeeJob(toggleManager, job: managedBy("zz"), managers: [], kind: .projects))
        XCTAssertFalse(CanonicalBusinessEngine.canSeeJob(toggleManager, job: managedBy("zz"), managers: [], kind: .smallWorks),
                       "the Projects toggle does not show every small works job")
        XCTAssertTrue(CanonicalBusinessEngine.canSeeJob(manager, job: managedBy("m1"), managers: [], kind: .projects))
        XCTAssertFalse(CanonicalBusinessEngine.canSeeJob(manager, job: managedBy("zz"), managers: [], kind: .projects))
        XCTAssertFalse(CanonicalBusinessEngine.canSeeJob(operative, job: managedBy("o1"), managers: [], kind: .projects))
    }

    func testJobEditorGates() {
        XCTAssertTrue(CanonicalBusinessEngine.canCreateJob(admin, kind: .smallWorks))
        XCTAssertTrue(CanonicalBusinessEngine.canCreateJob(toggleManager, kind: .projects))
        XCTAssertFalse(CanonicalBusinessEngine.canCreateJob(toggleManager, kind: .smallWorks))
        XCTAssertFalse(CanonicalBusinessEngine.canCreateJob(manager, kind: .projects))
        XCTAssertFalse(CanonicalBusinessEngine.canCreateJob(operative, kind: .projects))
        XCTAssertTrue(CanonicalBusinessEngine.canEditJob(manager, job: managedBy("m1"), kind: .smallWorks, managers: []),
                      "a manager edits the details of a job they manage")
        XCTAssertFalse(CanonicalBusinessEngine.canEditJob(manager, job: managedBy("zz"), kind: .smallWorks, managers: []))
        XCTAssertFalse(CanonicalBusinessEngine.canChangeJobManagers(manager, kind: .projects),
                       "without the toggle the manager list stays as stored")
        XCTAssertFalse(CanonicalBusinessEngine.canEditJob(operative, job: managedBy("o1"), kind: .projects, managers: []))
    }

    func testJobManagerUserIdsAndTheManagerListFields() {
        let ids = CanonicalBusinessEngine.jobManagerUserIds(
            job: ["managerIds": ["MGR-ROW-1"]],
            managers: [["id": "MGR-ROW-1", "email": "m@x.t"]],
            accounts: [["id": "m1", "email": "M@x.t", "isActive": true], ["id": "m2", "email": "m@x.t", "isActive": false]]
        )
        XCTAssertEqual(ids, ["m1"], "a managers-list row resolves to the active accounts on its email")
        XCTAssertEqual(
            CanonicalBusinessEngine.jobWriteKeysWithoutManagerList(["siteName", "managerIds", "managerId", "managerUserIds"]),
            ["siteName"]
        )
    }

    func testAManagerWithoutTheToggleSavesNoManagerListFields() {
        let job = Project(
            jobNumber: "J-1", siteName: "Site", addressLine1: "1 Road", townCity: "Leeds", postcode: "LS1",
            client: Client(name: "Client"), startDate: Date(timeIntervalSince1970: 1_790_000_000),
            endDate: Date(timeIntervalSince1970: 1_790_100_000), jobType: .catA, manager: .custom
        )
        let restricted = FirebaseBackend.jobSaveFields(job, previous: job, organizationId: "ORG", viewer: manager)
        for key in CanonicalBusinessEngine.jobManagerListFields {
            XCTAssertNil(restricted.payload[key], "\(key) is not sent by a manager without the toggle")
        }
        XCTAssertNotNil(restricted.payload["siteName"])
        let full = FirebaseBackend.jobSaveFields(job, previous: job, organizationId: "ORG", viewer: admin)
        XCTAssertNotNil(full.payload["managerIds"], "an admin save keeps the manager fields")
    }

    // MARK: Booking writes

    func testBookingWriteAndDeleteGates() {
        let labour: [String: Any] = ["collection": "bookings", "projectId": "j"]
        XCTAssertTrue(CanonicalBusinessEngine.canWriteBooking(admin, booking: labour, job: managedBy("zz"), managers: []))
        XCTAssertTrue(CanonicalBusinessEngine.canWriteBooking(manager, booking: labour, job: managedBy("m1"), managers: []))
        XCTAssertFalse(CanonicalBusinessEngine.canWriteBooking(manager, booking: labour, job: managedBy("zz"), managers: []))
        XCTAssertFalse(CanonicalBusinessEngine.canWriteBooking(toggleManager, booking: labour, job: managedBy("zz"), managers: []),
                       "the toggle shows every job but books only on managed ones")
        XCTAssertFalse(CanonicalBusinessEngine.canWriteBooking(operative, booking: labour, job: managedBy("o1"), managers: []))
        let office: [String: Any] = ["collection": "managerSiteBookings", "userId": "m1", "locationType": "office"]
        XCTAssertTrue(CanonicalBusinessEngine.canWriteBooking(manager, booking: office, job: nil, managers: []))
        let subcontractor: [String: Any] = ["collection": "subcontractorBookings", "projectId": "j"]
        XCTAssertTrue(CanonicalBusinessEngine.canDeleteBooking(manager, booking: subcontractor, job: managedBy("m1"), managers: []),
                      "1.10.0: managers delete bookings on jobs they manage")
        XCTAssertFalse(CanonicalBusinessEngine.canDeleteBooking(operative, booking: subcontractor, job: managedBy("o1"), managers: []))
    }

    // MARK: Read plans (§17)

    private func queries(_ plan: [String: Any]?) -> [[String: Any]] {
        plan?["queries"] as? [[String: Any]] ?? []
    }

    func testJobQueryPlanPerViewer() {
        let adminPlan = queries(CanonicalBusinessEngine.jobQueryPlan(admin, documentIds: [], enforced: true))
        XCTAssertEqual(adminPlan.map { $0["kind"] as? String }, ["all", "all"])
        let togglePlan = queries(CanonicalBusinessEngine.jobQueryPlan(toggleManager, documentIds: [], enforced: true))
        XCTAssertEqual(togglePlan.map { $0["kind"] as? String }, ["all", "managed"])
        XCTAssertEqual(togglePlan.last?["value"] as? String, "t1")
        let managerPlan = queries(CanonicalBusinessEngine.jobQueryPlan(manager, documentIds: [], enforced: true))
        XCTAssertEqual(managerPlan.map { $0["kind"] as? String }, ["managed", "managed"])
        XCTAssertEqual(managerPlan.first?["field"] as? String, "managerUserIds")
        let operativePlan = queries(CanonicalBusinessEngine.jobQueryPlan(operative, documentIds: ["a1b2"], enforced: true))
        XCTAssertEqual(operativePlan.map { $0["kind"] as? String }, ["documents", "documents"])
        XCTAssertEqual(operativePlan.first?["ids"] as? [String], ["a1b2", "A1B2"], "every spelling the rules can trace")
        XCTAssertTrue(queries(CanonicalBusinessEngine.jobQueryPlan(operative, documentIds: [], enforced: true)).isEmpty,
                      "an operative never lists a job collection")
    }

    func testBookingQueryPlanPerViewer() {
        let adminPlan = CanonicalBusinessEngine.bookingQueryPlan(admin, visibleJobIds: ["job-1"], ownBookingIds: nil, enforced: true)
        XCTAssertEqual(adminPlan?["readsEveryBooking"] as? Bool, true)
        XCTAssertEqual(queries(adminPlan).count, 3)
        // RULEBOOK 1.11.0 §17: enforced, `readsEveryBooking` is admins only; a toggle manager reads their kind by
        // `jobCollection` (web staffAccess.ts `readsEveryBooking`).
        XCTAssertFalse(CanonicalBusinessEngine.readsEveryBooking(toggleManager, enforced: true))
        XCTAssertTrue(CanonicalBusinessEngine.readsEveryBooking(toggleManager, enforced: false), "every manager reads every booking while enforced reads are off")
        let managerPlan = queries(CanonicalBusinessEngine.bookingQueryPlan(manager, visibleJobIds: ["job-1"], ownBookingIds: ["m1", "OP-1"], enforced: true))
        XCTAssertEqual(managerPlan.map { $0["collection"] as? String },
                       ["bookings", "subcontractorBookings", "managerSiteBookings", "bookings", "managerSiteBookings"])
        XCTAssertEqual(managerPlan.first?["values"] as? [String], ["job-1", "JOB-1"])
        XCTAssertEqual(managerPlan.last?["op"] as? String, "==")
        let operativePlan = queries(CanonicalBusinessEngine.bookingQueryPlan(operative, visibleJobIds: ["job-1"], ownBookingIds: ["o1", "OP-1"], enforced: true))
        XCTAssertEqual(operativePlan.count, 1, "an operative reads their own bookings only")
        XCTAssertEqual(operativePlan.first?["field"] as? String, "operativeId")
        XCTAssertEqual(operativePlan.first?["values"] as? [String], ["o1", "OP-1"])
    }

    func testWarningScopePerViewer() {
        let input: (JobAccessViewer) -> [String: Any] = { viewer in
            CanonicalBusinessEngine.warningScopeFor(
                viewer: viewer,
                visibleJobIds: ["job-1"],
                bookings: [["projectId": "JOB-1", "operativeId": "OP-9"]],
                managerBookings: [],
                people: [],
                operatives: [["id": "OP-9", "email": "p@x.t"]],
                enforced: true
            )
        }
        XCTAssertEqual(input(admin)["kind"] as? String, "all")
        let restricted = input(manager)
        XCTAssertEqual(restricted["kind"] as? String, "jobs")
        XCTAssertEqual(restricted["personIds"] as? [String], ["op-9"])
        XCTAssertEqual(restricted["unbookedLabour"] as? Bool, false, "unbooked labour needs every booking")
        // 1.11.0: `unbookedLabour` is `readsEveryBooking`, which (enforced) is admins only.
        XCTAssertEqual(input(toggleManager)["unbookedLabour"] as? Bool, false)
        XCTAssertTrue(CanonicalBusinessEngine.isJobInWarningScope(restricted, jobId: "JOB-1"))
        XCTAssertFalse(CanonicalBusinessEngine.isJobInWarningScope(restricted, jobId: "job-2"))
    }

    // MARK: User delete (§11)

    private func appUser(_ id: String, role: UserRole, permissions: UserPermissions) -> AppUser {
        AppUser(id: id, email: "\(id)@x.t", organizationId: "ORG", role: role, permissions: permissions)
    }

    func testUserDeleteIsRefusedBeforeAnyWrite() {
        let store = UserStore()
        let admin = appUser("a1", role: .admin, permissions: UserPermissions(adminAccess: true))
        let otherAdmin = appUser("a2", role: .admin, permissions: UserPermissions(adminAccess: true))
        let manager = appUser("m1", role: .manager, permissions: UserPermissions(manager: true))
        let operative = appUser("o1", role: .operative, permissions: UserPermissions(operativeMode: true))
        XCTAssertEqual(store.userDeleteRefusalMessage(targetUser: otherAdmin, actingUser: admin),
                       "Only the super admin can delete an admin.")
        XCTAssertEqual(store.userDeleteRefusalMessage(targetUser: admin, actingUser: admin),
                       "You cannot delete your own account here.")
        XCTAssertEqual(store.userDeleteRefusalMessage(targetUser: operative, actingUser: manager),
                       "Only an admin can delete people.")
        XCTAssertNil(store.userDeleteRefusalMessage(targetUser: operative, actingUser: admin))
    }

    func testUserDeleteWritesAccountBatchFirst() throws {
        let operative = appUser("o1", role: .operative, permissions: UserPermissions(operativeMode: true))
        let input: [String: Any] = [
            "orgId": "ORG",
            "user": UserStore.userDeletePerson(operative),
            "actorUserId": "a1",
            "platform": "ios",
            "bookings": [["id": "B1", "operativeId": "o1", "dateMs": Date().addingTimeInterval(3 * 86_400).timeIntervalSince1970 * 1000]],
            "nowIso": CanonicalBusinessEngine.isoString(from: Date()),
            "tz": "Europe/London",
        ]
        let steps = try XCTUnwrap(CanonicalBusinessEngine.callJSON("userDeleteWrites", arguments: [input]) as? [[String: Any]])
        XCTAssertEqual(steps.map { $0["step"] as? String }, ["account", "bookings"])
        let account = (steps.first?["writes"] as? [[String: Any]] ?? []).compactMap { $0["path"] as? String }
        XCTAssertEqual(account.first, "users/o1")
        XCTAssertTrue(account.contains("users/o1/orgMemberships/ORG"))
        XCTAssertTrue(account.contains("users/o1/private/taxIds"))
    }

    // MARK: Pay history (§8)

    func testPayRateChangeIsRefusedWhenHistoryDidNotLoad() throws {
        let refused = try XCTUnwrap(CanonicalBusinessEngine.payRateChangeWrites(
            userId: "u1", operativeId: nil,
            previous: (100, "day"), next: (120, "day"),
            historyRowIds: nil, effective: Date(), seedEffective: Date(timeIntervalSince1970: 1_767_225_600)
        ))
        XCTAssertEqual(refused.refusal, "Pay history could not be loaded. Check your connection and save again.")
        XCTAssertTrue(refused.rows.isEmpty)
        let seeded = try XCTUnwrap(CanonicalBusinessEngine.payRateChangeWrites(
            userId: "u1", operativeId: nil,
            previous: (100, "day"), next: (120, "day"),
            historyRowIds: [], effective: Date(), seedEffective: Date(timeIntervalSince1970: 1_767_225_600)
        ))
        XCTAssertNil(seeded.refusal)
        XCTAssertEqual(seeded.rows.map(\.dayRate), [100, 120], "empty loaded history: the seed row, then the new rate")
        let unchanged = try XCTUnwrap(CanonicalBusinessEngine.payRateChangeWrites(
            userId: "u1", operativeId: nil,
            previous: (100, "day"), next: (100, "day"),
            historyRowIds: nil, effective: Date(), seedEffective: nil
        ))
        XCTAssertNil(unchanged.refusal, "an unchanged rate writes nothing and needs no history")
        XCTAssertTrue(unchanged.rows.isEmpty)
    }

    func testPayArithmeticIsTheRulebooks() {
        let day = ResolvedPayrollRate(basis: .dayRate, dayRate: 200, hourlyRate: nil)
        XCTAssertEqual(day.payForHours(4, standardDayHours: 8), 100, accuracy: 0.0001)
        XCTAssertEqual(day.payForHours(0, standardDayHours: 8), 0)
        let hourly = ResolvedPayrollRate(basis: .hourly, dayRate: nil, hourlyRate: 12.5)
        XCTAssertEqual(hourly.payForHours(2, standardDayHours: 8, otMultiplier: 1.5), 37.5, accuracy: 0.0001)
        XCTAssertEqual(hourly.effectiveDayRate(standardDayHours: 8), 100, accuracy: 0.0001)
    }

    // MARK: Sync writes (§1, §7)

    func testWeeklyReportNeverWritesAndTheWarningKeyMigrationMay() {
        XCTAssertFalse(CanonicalBusinessEngine.syncWriteAllowed(.weeklyReport))
        XCTAssertTrue(CanonicalBusinessEngine.syncWriteAllowed(.listenerSnapshot, migration: "warningResolutionMigrationWrites"))
        XCTAssertFalse(CanonicalBusinessEngine.syncWriteAllowed(.weeklyReport, migration: "warningResolutionMigrationWrites"))
        XCTAssertFalse(CanonicalBusinessEngine.syncWriteAllowed(.listenerSnapshot, migration: "somethingElse"))
    }

    // MARK: Job types (§1)

    func testJobTypesSaveOnlyTheExplicitChange() {
        let added = CanonicalBusinessEngine.jobTypesChangeWriteFields(stored: ["CAT A"], add: ["Fit out"], remove: [])
        XCTAssertEqual(added??.sorted(), ["CAT A", "Fit out"])
        let removed = CanonicalBusinessEngine.jobTypesChangeWriteFields(stored: ["CAT A", "Fit out"], add: [], remove: ["fit out"])
        XCTAssertEqual(removed ?? nil, ["CAT A"])
    }

    /// Rulebook 1.10.1: enforced reads stay off until the backfill, so a manager without a job toggle reads whole
    /// collections (as before 1.10.0) and the screens filter with `canSeeJob`.
    func testEnforcedReadsAreOffByDefaultUntilTheBackfill() {
        let plan = CanonicalBusinessEngine.jobQueryPlan(manager, documentIds: [])
        let kinds = (plan?["queries"] as? [[String: Any]] ?? []).map { $0["kind"] as? String }
        XCTAssertEqual(kinds, ["all", "all"])
        XCTAssertTrue(CanonicalBusinessEngine.readsEveryBooking(manager))
    }
}
