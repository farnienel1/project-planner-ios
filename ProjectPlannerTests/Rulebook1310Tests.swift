import XCTest
@testable import Project_Planner

/// RULEBOOK 1.31.0 (people and access) and the owner decisions of 4 Nov on iOS, through `CanonicalBusinessEngine`:
/// warning scope, line-manager reports and the change block, job-manager removal, a new job's manager, Change Super
/// Admin, deactivate / reactivate on every same-email document, the one flag reader, an operatives manager's booking
/// delete, exported timesheet history, never deleting leave, Book labour for an account with no Operatives-list row,
/// and the job `manager` label.
@MainActor
final class Rulebook1310Tests: XCTestCase {
    private let org = "TEST-ORG-1310"

    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    }

    private func user(
        _ id: String,
        role: UserRole,
        admin: Bool = false,
        manager: Bool = false,
        operative: Bool = false,
        active: Bool = true,
        lineManagers: [String] = [],
        email: String? = nil,
        employmentType: EmploymentType = .selfEmployed
    ) -> AppUser {
        AppUser(
            id: id,
            email: email ?? "\(id.lowercased())@example.test",
            organizationId: org,
            role: role,
            firstName: "TEST-\(id)",
            surname: "Person",
            isActive: active,
            passwordSet: true,
            permissions: UserPermissions(adminAccess: admin, manager: manager || admin, operativeMode: operative),
            assignedManagerUserIds: lineManagers,
            employmentType: employmentType
        )
    }

    private var admin: AppUser { user("ADMIN", role: .admin, admin: true) }
    private var lineManager: AppUser { user("MGR", role: .manager, manager: true, lineManagers: ["ADMIN"]) }
    private var report: AppUser { user("OP", role: .operative, operative: true, lineManagers: ["MGR"]) }
    private var operativeLevelLineManager: AppUser { user("OPLM", role: .operative, operative: true, lineManagers: ["MGR"]) }
    private var reportOfOperative: AppUser { user("OP2", role: .operative, operative: true, lineManagers: ["OPLM"]) }
    private var roster: [AppUser] { [admin, lineManager, report, operativeLevelLineManager, reportOfOperative] }
    private var rosterRows: [[String: Any]] { roster.map { RulebookPeople.person($0) } }

    // MARK: Line managers (§8, §11)

    func testAnOperativeLevelPersonIsNobodysLineManager() throws {
        let ids = try XCTUnwrap(CanonicalBusinessEngine.lineManagerIds(user: RulebookPeople.person(reportOfOperative), roster: rosterRows))
        XCTAssertEqual(ids, [], "no rights carry over: an operative is never a line manager")
        XCTAssertEqual(CanonicalBusinessEngine.lineManagerIds(user: RulebookPeople.person(report), roster: rosterRows), ["MGR"])
    }

    func testMakingALineManagerAnOperativeIsBlockedAndListsTheReports() throws {
        let block = try XCTUnwrap(CanonicalBusinessEngine.lineManagerChangeBlock(
            person: RulebookPeople.person(lineManager),
            roster: rosterRows,
            change: .level(.operative)
        ))
        XCTAssertTrue(block.blocked)
        XCTAssertEqual(Set(block.reports.map(\.id)), ["OP", "OPLM"])
        XCTAssertEqual(block.message, CanonicalBusinessEngine.lineManagerReportsBlockMessage)
        for change in [RulebookPersonAccessChange.deactivate, .delete] {
            XCTAssertEqual(
                CanonicalBusinessEngine.lineManagerChangeBlock(person: RulebookPeople.person(lineManager), roster: rosterRows, change: change)?.blocked,
                true,
                "\(change) is blocked too"
            )
        }
        let adminToManager = try XCTUnwrap(CanonicalBusinessEngine.lineManagerChangeBlock(
            person: RulebookPeople.person(admin),
            roster: rosterRows,
            change: .level(.manager)
        ))
        XCTAssertFalse(adminToManager.blocked, "admin ↔ manager never blocks")
    }

    func testTheStoreRefusesWithTheReportsListed() throws {
        let store = UserStore()
        store.organizationUsers = roster
        let message = try XCTUnwrap(store.lineManagerChangeBlockMessage(for: lineManager, change: .deactivate))
        XCTAssertTrue(message.hasPrefix(CanonicalBusinessEngine.lineManagerReportsBlockMessage))
        XCTAssertTrue(message.contains("TEST-OP Person"))
        XCTAssertNil(store.lineManagerChangeBlockMessage(for: report, change: .delete), "nobody reports to an operative")
    }

    // MARK: Job managers (§11)

    func testAManagerWhoStopsBeingOneIsTakenOffTheirJobs() {
        let jobs: [[String: Any]] = [
            ["id": "J1", "collection": "projects", "managerIds": ["mgr-row"], "managerId": "mgr-row", "managerUserIds": ["MGR"]],
            ["id": "J2", "collection": "smallWorks", "managerIds": ["mgr-row", "adm-row"], "managerUserIds": ["MGR", "ADMIN"]],
            ["id": "J3", "collection": "projects", "managerIds": ["adm-row"], "managerUserIds": ["ADMIN"]],
        ]
        let writes = CanonicalBusinessEngine.jobManagerRemovalWrites(
            organizationId: org,
            person: RulebookPeople.person(lineManager),
            change: .deactivate,
            jobs: jobs,
            roster: rosterRows,
            managers: [["id": "mgr-row", "email": "mgr@example.test"]]
        )
        XCTAssertEqual(writes.map(\.jobId), ["J1", "J2"], "a job that does not name them is not written")
        XCTAssertEqual(Set(writes[0].remove), ["managerIds", "managerUserIds", "managerId"], "the job stays, with no manager")
        XCTAssertEqual(writes[1].setLists["managerIds"], ["adm-row"])
        XCTAssertEqual(writes[1].setLists["managerUserIds"], ["ADMIN"])
        XCTAssertEqual(writes[0].path, "organizations/\(org)/projects/J1")
        XCTAssertTrue(
            CanonicalBusinessEngine.jobManagerRemovalWrites(
                organizationId: org,
                person: RulebookPeople.person(admin),
                change: .level(.manager),
                jobs: jobs,
                roster: rosterRows,
                managers: []
            ).isEmpty,
            "admin ↔ manager keeps every job"
        )
        XCTAssertTrue(CanonicalBusinessEngine.changeRemovesJobManager(person: RulebookPeople.person(lineManager), change: .level(.operative)))
        XCTAssertFalse(CanonicalBusinessEngine.changeRemovesJobManager(person: RulebookPeople.person(lineManager), change: .level(.admin)))
        let notice = CanonicalBusinessEngine.jobManagerRemovedNoticeText(name: "TEST-MGR Person", jobCount: 2)
        XCTAssertEqual(notice.title, "Manager removed from jobs")
        XCTAssertTrue(notice.message.contains("2 jobs"))
        XCTAssertEqual(AppNotification.NotificationType.jobManagerRemoved.rawValue, "job_manager_removed")
        XCTAssertEqual(AppNotification.NotificationType.operativeDeleted.rawValue, "operative_deleted")
        XCTAssertTrue(CanonicalBusinessEngine.companyActivityNoticeTypes.contains("job_manager_removed"))
        XCTAssertTrue(CanonicalBusinessEngine.companyActivityNoticeTypes.contains("operative_deleted"))
    }

    func testANewJobNeedsAManager() {
        XCTAssertEqual(CanonicalBusinessEngine.jobManagerRequiredError(managerIds: []), "Please assign at least one manager")
        XCTAssertEqual(CanonicalBusinessEngine.jobManagerRequiredError(managerIds: ["  "]), "Please assign at least one manager")
        XCTAssertNil(CanonicalBusinessEngine.jobManagerRequiredError(managerIds: ["mgr-row"]))
    }

    func testANewJobWritesItsManagersNameNotCustom() throws {
        var job = Project(
            jobNumber: "TEST-J-1310",
            siteName: "TEST-Site",
            siteAddress: "1 Test Street",
            client: Client(name: "TEST-Client"),
            startDate: Date(),
            endDate: Date(),
            jobType: .catA,
            manager: .custom
        )
        job.managerName = "TEST-MGR Person"
        XCTAssertEqual(FirebaseBackend.jobDocumentPayload(job, organizationId: org)["manager"] as? String, "TEST-MGR Person")
        job.managerName = "Custom"
        XCTAssertEqual(JobManagerLabel.storedValue(job), "Custom", "an older job read as Custom keeps its label")
        let read = try XCTUnwrap(FirebaseBackend.jobs(fromDocuments: [(id: "web-1310", data: [
            "jobNumber": "J-1310", "siteName": "TEST-Site", "client": ["id": "c", "name": "TEST-Client"], "manager": "Ada North",
        ])], smallWorks: false).first)
        XCTAssertEqual(read.managerName, "Ada North")
        XCTAssertEqual(JobManagerLabel.storedValue(read), "Ada North", "an edit writes the stored name back, never Custom")
    }

    // MARK: Warning scope (§5)

    func testAManagersWarningScopeIsThemselvesTheirReportsAndTheirJobs() throws {
        let viewer = JobAccessViewer(
            role: UserStore.staffAccountRole(for: lineManager),
            projectsToggle: true,
            smallWorksToggle: true,
            uid: "MGR",
            ids: ["MGR"],
            email: "mgr@example.test"
        )
        let scope = CanonicalBusinessEngine.warningScopeFor(
            viewer: viewer,
            visibleJobIds: [],
            bookings: [],
            managerBookings: [],
            people: [],
            operatives: [],
            jobs: [["id": "J1", "managerUserIds": ["MGR"]], ["id": "J9", "managerUserIds": ["ADMIN"]]],
            managers: [],
            roster: rosterRows
        )
        XCTAssertEqual(scope["kind"] as? String, "jobs", "both job toggles no longer widen a manager's scope")
        XCTAssertTrue(CanonicalBusinessEngine.isWarningRowInScope(scope, jobIds: ["J1"], personIds: []))
        XCTAssertTrue(CanonicalBusinessEngine.isWarningRowInScope(scope, jobIds: [], personIds: ["OP"]), "a report")
        XCTAssertTrue(CanonicalBusinessEngine.isWarningRowInScope(scope, jobIds: [], personIds: ["mgr"]), "themselves, any case")
        XCTAssertFalse(CanonicalBusinessEngine.isWarningRowInScope(scope, jobIds: ["J9"], personIds: ["ADMIN"]))
        XCTAssertTrue(CanonicalBusinessEngine.isWarningRowInScope(nil, jobIds: [], personIds: []), "no scope keeps every row")

        let adminViewer = JobAccessViewer(
            role: UserStore.staffAccountRole(for: admin), projectsToggle: true, smallWorksToggle: true,
            uid: "ADMIN", ids: ["ADMIN"], email: "admin@example.test"
        )
        let all = CanonicalBusinessEngine.warningScopeFor(
            viewer: adminViewer, visibleJobIds: [], bookings: [], managerBookings: [], people: [], operatives: []
        )
        XCTAssertEqual(all["kind"] as? String, "all")
        XCTAssertTrue(CanonicalBusinessEngine.warningScopeListsUnbookedLabour(nil))
        XCTAssertFalse(CanonicalBusinessEngine.warningScopeListsUnbookedLabour(["kind": "jobs", "unbookedLabour": false]))
        XCTAssertEqual(BookLabourCopy.noAccessTitle, "You can't see unbooked labour for the whole company")
    }

    func testTheWarningsScanFiltersClashAndLeaveRowsByScope() throws {
        let source = try String(contentsOf: repoRoot.appendingPathComponent("Project Planner/Core/WarningsComputation.swift"), encoding: .utf8)
        XCTAssertTrue(source.contains("isWarningRowInScope"), "clash and leave-cover rows are scoped (RULEBOOK 1.31.0 §5)")
        let support = try String(contentsOf: repoRoot.appendingPathComponent("Project Planner/Core/Rulebook+JobAccess.swift"), encoding: .utf8)
        XCTAssertFalse(support.contains("if CanonicalBusinessEngine.seesEveryJob(viewer, kind: nil) { return nil }"),
                       "a manager with both toggles is not given every warning")
    }

    // MARK: Same-email documents, Super Admin, flags (§11)

    func testDeactivateWritesEverySameEmailDocumentOfThisOrganisation() {
        let writes = CanonicalBusinessEngine.userActiveWrites(
            organizationId: org,
            personId: "OP",
            email: "op@example.test",
            isActive: false,
            roster: [
                ["id": "OP", "email": "op@example.test", "organizationId": org],
                ["id": "op-uid", "email": "OP@example.test", "organizationId": org],
                ["id": "elsewhere", "email": "op@example.test", "organizationId": "TEST-OTHER"],
            ]
        )
        XCTAssertEqual(writes.map(\.path), ["users/OP", "users/op-uid", "users/OP/orgMemberships/\(org)"])
        XCTAssertEqual(writes.first?.fields["isActive"] as? Bool, false)
        XCTAssertEqual(writes.last?.fields["accountActive"] as? Bool, false)
    }

    func testChangeSuperAdminIsOneBatchAndKeepsTheOutgoingSelfApproved() throws {
        var outgoing = user("SA", role: .admin, admin: true)
        outgoing.isSuperAdmin = true
        let rows = [outgoing, admin].map { RulebookPeople.person($0) }
        let writes = try XCTUnwrap(CanonicalBusinessEngine.superAdminTransferWrites(
            organizationId: org, fromUserId: "SA", toUserId: "ADMIN", previousCreatorUserId: "SA", roster: rows
        ))
        XCTAssertEqual(writes.first?.path, "organizations/\(org)")
        XCTAssertEqual(writes.first?.fields["creatorUserId"] as? String, "ADMIN")
        let incoming = try XCTUnwrap(writes.first { $0.path == "users/ADMIN" })
        XCTAssertEqual(incoming.fields["isSuperAdmin"] as? Bool, true)
        let leaving = try XCTUnwrap(writes.first { $0.path == "users/SA" })
        XCTAssertEqual(leaving.fields["isSuperAdmin"] as? Bool, false)
        XCTAssertEqual(leaving.fields["annualLeaveSelfBook"] as? Bool, true, "no line manager: kept self-approved")
        XCTAssertEqual(leaving.fields["timesheetSelfSign"] as? Bool, true)
        XCTAssertNil(CanonicalBusinessEngine.superAdminTransferWrites(
            organizationId: org, fromUserId: "SA", toUserId: "SA", previousCreatorUserId: nil, roster: rows
        ))
    }

    func testOneFlagReaderTopLevelFirst() {
        XCTAssertEqual(CanonicalBusinessEngine.userPermissionFlag(["adminAccess": false, "permissions": ["adminAccess": true]], key: "adminAccess"), false)
        XCTAssertEqual(CanonicalBusinessEngine.userPermissionFlag(["permissions": ["adminAccess": true]], key: "adminAccess"), true)
        XCTAssertEqual(CanonicalBusinessEngine.userPermissionFlag([:], key: "adminAccess"), false)
    }

    func testChangeUserTypeReachesAListedSameEmailDocument() throws {
        var person = RulebookPeople.person(lineManager)
        person["role"] = "manager"
        person["organizationId"] = org
        let plan = try XCTUnwrap(CanonicalBusinessEngine.accountTypeChangeWrites(
            person: person,
            kind: .operative,
            organizationId: org,
            roster: [
                ["id": "MGR", "email": "mgr@example.test", "organizationId": org],
                ["id": "mgr-uid", "email": "mgr@example.test", "organizationId": org],
            ],
            permissions: nil,
            members: ["MGR": "manager", "mgr-uid": "manager"]
        ))
        guard case .ok(_, _, let writes, _) = plan else { return XCTFail("refused") }
        let member = writes.compactMap { write -> [String: Sendable]? in
            if case .organizationMember(_, let fields) = write { return fields }
            return nil
        }.first
        XCTAssertEqual(member?["members.mgr-uid"] as? String, "operative", "the listed same-email document gets the new role")
        XCTAssertTrue(writes.contains { write in
            if case .userProfile(let path, _) = write { return path == "users/mgr-uid" }
            return false
        })
    }

    func testTheUnfoldedRosterKeepsEveryDocument() {
        let store = UserStore()
        store.organizationUsers = [admin]
        XCTAssertEqual(store.unfoldedOrganizationUsers.map(\.id), ["ADMIN"], "until a load reads the documents, the roster")
        XCTAssertEqual(store.unfoldedRosterRows.first?["id"] as? String, "ADMIN")
    }

    // MARK: Bookings (§2, §11)

    func testAnOperativesManagerDeletesOnlyFutureBookingsOfOperativesWithoutALogin() throws {
        let now = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-11-04T10:00:00Z"))
        let tomorrow = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-11-05T00:00:00Z"))
        let today = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-11-04T00:00:00Z"))
        XCTAssertTrue(CanonicalBusinessEngine.operativesManagerMayDeleteBooking(date: tomorrow, now: now, timeZone: "Europe/London", operativeHasAccount: false))
        XCTAssertFalse(CanonicalBusinessEngine.operativesManagerMayDeleteBooking(date: today, now: now, timeZone: "Europe/London", operativeHasAccount: false))
        XCTAssertFalse(CanonicalBusinessEngine.operativesManagerMayDeleteBooking(date: tomorrow, now: now, timeZone: "Europe/London", operativeHasAccount: true))
    }

    // MARK: Exported timesheets (§8)

    func testExportedHistoryIncludesTheViewersOwnAndInactivePeopleInScope() throws {
        let inactiveReport = user("OPX", role: .operative, operative: true, active: false, lineManagers: ["MGR"])
        let ids = try XCTUnwrap(UserTimesheetAccessRulebook.exportedHistoryUserIds(
            viewer: lineManager,
            members: [admin, lineManager, report, inactiveReport]
        ))
        XCTAssertEqual(Set(ids), ["MGR", "OP", "OPX"])
        let store = UserStore()
        store.organizationUsers = [admin, lineManager, report, inactiveReport]
        XCTAssertEqual(Set(store.exportedTimesheetHistoryUsers(viewer: lineManager).map(\.id)), ["MGR", "OP", "OPX"])
    }

    // MARK: Never delete leave (owner decision 4 Nov)

    func testNothingDeletesLeaveWhenAnnualLeaveManagementChanges() throws {
        let enumerator = FileManager.default.enumerator(at: repoRoot.appendingPathComponent("Project Planner"), includingPropertiesForKeys: nil)
        var offenders: [String] = []
        while let url = enumerator?.nextObject() as? URL {
            guard url.pathExtension == "swift", let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            for name in ["deleteSelfBookedApprovedHolidaysFor", "deletePendingHolidayRequestsFor", "shouldClearSelfBookedAnnualLeave", "shouldClearPendingAnnualLeave"]
            where text.contains(name) {
                offenders.append("\(url.lastPathComponent): \(name)")
            }
        }
        XCTAssertEqual(offenders, [], "the toggle only decides whether future leave is approved or requested")
        XCTAssertTrue(ManageUsersLeaveCopy.selfBookOffMessage.contains("existing annual leave stays"))
    }

    // MARK: Book labour for an account with no Operatives-list row (web #262)

    func testAnAccountWithNoCatalogueRowIsBookedUnderItsUsersId() {
        let account = user("op-uid-1310", role: .operative, operative: true, email: "solo@example.test", employmentType: .paye)
        let row = AccountLabourBooking.operative(for: account)
        XCTAssertEqual(Booking.storedOperativeId(for: row.id), "op-uid-1310", "the booking's operativeId is the users id")
        XCTAssertEqual(row.documentId, "op-uid-1310")
        XCTAssertEqual(AccountLabourBooking.account(forOperativeId: row.id, users: [account])?.id, "op-uid-1310")

        let buckets = StaffEmailIdentity.scheduleBuckets(
            operativeIds: [row.id],
            userIds: ["op-uid-1310"],
            operatives: [],
            users: [account]
        )
        XCTAssertEqual(buckets.count, 1, "the booking sits in the account's row, not a separate op: row")

        let booking = Booking(
            operativeId: row.id,
            projectId: UUID(),
            date: Date(),
            timeSlot: .fullDay,
            bookedBy: "TEST-ADMIN"
        )
        XCTAssertTrue(LabourBookingEditOptions.isPaye(booking, operatives: [], users: [account]), "PAYE is read from the account")
    }
}
