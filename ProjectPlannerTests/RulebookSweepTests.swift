import XCTest
import FirebaseFirestore
@testable import Project_Planner

/// The iOS rulebook-bypass sweep: screens that kept their own copy of a rule the packed script already owns now call
/// it through `CanonicalBusinessEngine`. One test per swap, named after the rulebook function it relies on.
@MainActor
final class RulebookSweepTests: XCTestCase {
    private var orgCalendar: Calendar { OrganizationRulebookContext.calendar }

    private func orgDay(_ key: String) -> Date {
        CanonicalBusinessEngine.date(fromDayKey: key)!
    }

    // MARK: 1. Leave day counts (`leaveDaysInRange`)

    /// A Friday-to-Monday request takes two days, not four: the weekend inside a multi-day record is not leave
    /// (`leaveRecordDayKeys`). The request card and the "remaining after" note used to count every calendar day.
    func testLeaveCardCountsSkipTheWeekendInsideARequest() {
        let request = LogicFixtures.holiday(userId: "user-1", start: orgDay("2026-11-06"), end: orgDay("2026-11-09"))
        XCTAssertEqual(AnnualLeaveDateFormat.leaveDays(request), 2)
        XCTAssertTrue(AnnualLeaveDateFormat.bookingTitle(request).hasSuffix("· 2 days"), AnnualLeaveDateFormat.bookingTitle(request))

        let halfDays = LogicFixtures.holiday(
            userId: "user-1", start: orgDay("2026-11-06"), end: orgDay("2026-11-09"), slot: .morning
        )
        XCTAssertEqual(AnnualLeaveDateFormat.leaveDays(halfDays), 1)

        // A single-day record is that day, even on a weekend (rulebook §9).
        let saturday = LogicFixtures.holiday(userId: "user-1", start: orgDay("2026-11-07"), end: orgDay("2026-11-07"))
        XCTAssertEqual(AnnualLeaveDateFormat.leaveDays(saturday), 1)

        let span = AnnualLeaveDisplaySpan(bookings: [request, saturday])
        XCTAssertEqual(span.dayTotal, 3)
    }

    // MARK: 2. Leave balance matching (`leaveRecordsForAccount`)

    private func staffUser(id: String, email: String, formerUserIds: [String] = [], operativeMode: Bool = true) -> AppUser {
        var u = AppUser(
            id: id,
            email: email,
            organizationId: "org-test",
            role: operativeMode ? .operative : .manager,
            firstName: "Ada",
            surname: "Lovelace",
            isActive: true,
            passwordSet: true,
            permissions: UserPermissions(operativeMode: operativeMode)
        )
        u.formerUserIds = formerUserIds
        return u
    }

    /// Leave booked under an old invite id counts towards the person's balance: the balance reads the account's
    /// records (`leaveRecordsForAccount` via `HolidayStore.myBookings`). It used to compare `userId` with the
    /// current id or the email only, so this day was never taken from the allowance.
    func testLeaveUnderAFormerIdCountsInTheBalance() {
        let person = staffUser(id: "uid-new", email: "ada@example.com", formerUserIds: ["invite-old"])
        let store = HolidayStore()
        store.bookings = [
            LogicFixtures.holiday(userId: "INVITE-OLD", start: orgDay("2026-11-04"), end: orgDay("2026-11-04")),
            LogicFixtures.holiday(userId: "someone-else", start: orgDay("2026-11-05"), end: orgDay("2026-11-05")),
        ]
        let mine = store.myBookings(account: person, operatives: [])
        XCTAssertEqual(mine.map(\.userId), ["INVITE-OLD"])
        let summary = AnnualLeavePolicy.usageSummary(
            bookings: mine,
            daysPerYear: 25,
            startMonth: 1,
            endMonth: 12,
            carriesOver: false,
            referenceDate: orgDay("2026-11-04")
        )
        XCTAssertEqual(summary.takenDays, 1)
        XCTAssertEqual(summary.remainingDays, 24)
    }

    /// The requester behind a leave record is `resolveBookingPerson`: a catalogue row on the account's email finds the
    /// account (no Swift email match, no operative-mode filter).
    func testLeaveRequesterResolvesThroughTheRulebook() {
        let account = staffUser(id: "uid-1", email: "Ada@Example.com", operativeMode: false)
        let operativeId = UUID()
        let catalogue = LogicFixtures.operative(id: operativeId, email: "ada@example.com")
        var record = LogicFixtures.holiday(userId: "", start: orgDay("2026-11-04"), end: orgDay("2026-11-04"))
        record.userId = nil
        record.operativeIdRaw = catalogue.documentId
        XCTAssertEqual(
            AnnualLeaveApproval.requester(for: record, users: [account], operatives: [catalogue])?.id,
            "uid-1"
        )
    }

    // MARK: 3. Past timesheet runs (`isTimesheetFullySigned`)

    /// A self-signed admin's past run is complete with their own signature (`timesheetSelfSigned` →
    /// `isTimesheetFullySigned(fields, hasLineManager: false)`); an operative's still waits for the line manager.
    func testSelfSignedPastRunIsCompleteWithTheOwnersSignature() {
        OrganizationRulebookContext.update(
            from: Organization(firestoreDocumentId: "TEST-ORG-SWEEP", name: "TEST-Sweep", creatorUserId: "TEST-FOUNDER")
        )
        defer {
            RulebookRosterSnapshot.update([])
            OrganizationRulebookContext.update(from: nil)
        }
        var admin = AppUser(
            id: "TEST-ADMIN-SS", email: "admin@example.test", organizationId: "TEST-ORG-SWEEP", role: .admin,
            firstName: "Admin", surname: "Test", passwordSet: true,
            permissions: UserPermissions(adminAccess: true, manager: true, timesheetSelfSign: true)
        )
        admin.hasNoLineManager = true
        var operative = staffUser(id: "TEST-OP", email: "op@example.test")
        operative.setLineManagerUserIds([admin.id])
        RulebookRosterSnapshot.update([admin, operative])

        var draft = TimesheetDraft()
        draft.operativeSignedAt = orgDay("2026-10-30")
        draft.operativeSignedByName = "Admin Test"
        XCTAssertTrue(TimesheetApprovalPolicy.isTimesheetFullyApproved(draft: draft, user: admin))
        XCTAssertFalse(TimesheetApprovalPolicy.isTimesheetFullyApproved(draft: draft, user: operative))
    }

    // MARK: 4. Warning hours (`ScheduleCoverageFormat.hours`)

    /// Unbooked-labour and clash rows show hours as the pay rule gives them: 7.25h stays 7.25, never 7.5.
    func testWarningHoursAreNotSnappedToTheHalfHour() {
        XCTAssertEqual(WarningsComputation.formatHours(7.25), "7.25")
        XCTAssertEqual(WarningsComputation.formatHours(3.5), "3.5")
        XCTAssertEqual(WarningsComputation.formatHours(8), "8")
        XCTAssertEqual(WarningsComputation.formatHours(7.25), ScheduleCoverageFormat.hours(7.25))
    }

    // MARK: 5. Qualification reminders (`qualificationExpiryRows`)

    /// The Tasks banner lists the rows the Home badge counts: an already-expired qualification is included and the
    /// window is one calendar month on the organisation day (the banner used a 30-day device window without expired).
    func testQualificationBannerRowsIncludeExpiredAndUseTheRulebookWindow() {
        let reference = orgDay("2026-11-04")
        var operative = LogicFixtures.operative(id: UUID(), email: "ada@example.com")
        operative.qualificationExpiryDates = [
            "EXPIRED": orgDay("2026-11-01"),
            "SOON": orgDay("2026-11-14"),
            "LATER": orgDay("2026-12-20"),
        ]
        let rows = CanonicalBusinessEngine.qualificationExpiryRows(
            operatives: [operative.rulebookQualificationRow],
            reference: reference
        )
        XCTAssertEqual(Set(rows?.map(\.qualificationName) ?? []), ["EXPIRED", "SOON"])
        XCTAssertEqual(rows?.first(where: { $0.qualificationName == "EXPIRED" })?.daysUntilExpiry, -3)
        let count = CanonicalBusinessEngine.qualificationExpiryCount(
            operatives: [operative.rulebookQualificationRow],
            reference: reference
        )
        XCTAssertEqual(count?.total, rows?.count, "the banner and the Home badge read the same rows")
    }

    // MARK: 6. Task overdue counts (`isTaskOverdue`)

    /// The Tasks hub counts and filters overdue tasks with `isTaskOverdue`: due before today on the organisation day,
    /// never a completed task.
    func testTaskOverdueIsTheOrganisationDay() {
        let now = orgDay("2026-11-04").addingTimeInterval(30 * 60)
        let lateYesterday = orgDay("2026-11-04").addingTimeInterval(-30 * 60)
        XCTAssertTrue(CanonicalBusinessEngine.isTaskOverdue(status: ProjectTask.Status.todo.rawValue, dueDate: lateYesterday, now: now))
        XCTAssertFalse(CanonicalBusinessEngine.isTaskOverdue(status: ProjectTask.Status.completed.rawValue, dueDate: lateYesterday, now: now))
        XCTAssertFalse(CanonicalBusinessEngine.isTaskOverdue(status: ProjectTask.Status.todo.rawValue, dueDate: now, now: now))
    }

    // MARK: 7. Material cut-off clock (`resolveMaterialCutOffClock`, `materialCutOffClockMinutes`)

    /// The late-entry check and the line colour read the organisation's clock: a saved 15:30 stays 15:30; with no
    /// saved map the rulebook default (16:00) applies; nothing before the organisation is loaded.
    func testMaterialCutOffIsTheOrganisationClock() {
        let saved = OrgMaterialCutOff(
            materialOrderCutOff: true,
            materialCutOffHour: 15,
            materialCutOffMinute: 30,
            materialCutOffOnSaturday: false,
            materialCutOffOnSunday: false
        )
        XCTAssertEqual(OrgMaterialCutOff.clockMinutes(stored: saved, organizationLoaded: true), 15 * 60 + 30)
        XCTAssertEqual(OrgMaterialCutOff.clockLabel(stored: saved, organizationLoaded: true), "15:30")
        XCTAssertEqual(OrgMaterialCutOff.clockMinutes(stored: nil, organizationLoaded: true), 16 * 60)
        XCTAssertNil(OrgMaterialCutOff.clockMinutes(stored: saved, organizationLoaded: false))
        XCTAssertEqual(OrgMaterialCutOff.organizationMinuteOfDay(orgDay("2026-11-04").addingTimeInterval(15.5 * 3600)), 930)
    }

    // MARK: 9. Permission bridges (`canManageOperatives`, `canScheduleOperatives`, `canSendMaterialOrders`)

    private func levelUser(id: String, role: UserRole, permissions: UserPermissions) -> AppUser {
        AppUser(
            id: id, email: "\(id)@example.test", organizationId: "org-test", role: role,
            firstName: id, surname: "Test", isActive: true, passwordSet: true, permissions: permissions
        )
    }

    /// Operatives management and booking at other locations come from the level rules, never role flags in a screen.
    func testPermissionGatesComeFromTheRulebook() {
        let managerWith = levelUser(id: "mgr-on", role: .manager, permissions: UserPermissions(manager: true, operatives: true))
        let managerWithout = levelUser(id: "mgr-off", role: .manager, permissions: UserPermissions(manager: true, operatives: false))
        let operative = levelUser(id: "op", role: .operative, permissions: UserPermissions(operatives: true, operativeMode: true))
        XCTAssertTrue(CanonicalBusinessEngine.canManageOperatives(managerWith.permissionSubject))
        XCTAssertFalse(CanonicalBusinessEngine.canManageOperatives(managerWithout.permissionSubject))
        XCTAssertFalse(CanonicalBusinessEngine.canManageOperatives(operative.permissionSubject))
        XCTAssertTrue(CanonicalBusinessEngine.canScheduleOperatives(managerWithout.permissionSubject))
        XCTAssertFalse(CanonicalBusinessEngine.canScheduleOperatives(operative.permissionSubject))
        XCTAssertTrue(CanonicalBusinessEngine.canSendMaterialOrders(UserStore.staffAccountRole(for: managerWithout)))
        XCTAssertFalse(CanonicalBusinessEngine.canSendMaterialOrders(UserStore.staffAccountRole(for: operative)))

        XCTAssertTrue(WarningOperativeAccess.canOpen(actor: managerWith, target: operative))
        XCTAssertFalse(WarningOperativeAccess.canOpen(actor: managerWithout, target: operative))
        XCTAssertFalse(WarningOperativeAccess.canOpen(actor: managerWith, target: managerWithout))
    }

    /// Book labour: a candidate in operative mode (an admin included) is booked as an operative, never at other
    /// locations; a manager or an admin outside operative mode is.
    func testBookLabourOtherLocationsExcludeOperativeModeCandidates() {
        func candidate(_ user: AppUser) -> BookLabourCandidate {
            BookLabourCandidate(user: user, linkedOperative: nil, usesOperativeProjectBookings: false)
        }
        let manager = levelUser(id: "mgr", role: .manager, permissions: UserPermissions(manager: true))
        let admin = levelUser(id: "adm", role: .admin, permissions: UserPermissions(adminAccess: true, manager: true))
        let adminInOperativeMode = levelUser(
            id: "adm-op", role: .admin, permissions: UserPermissions(adminAccess: true, manager: true, operativeMode: true)
        )
        let operative = levelUser(id: "op", role: .operative, permissions: UserPermissions(operativeMode: true))
        XCTAssertTrue(candidate(manager).canBookOtherLocations)
        XCTAssertTrue(candidate(admin).canBookOtherLocations)
        XCTAssertFalse(candidate(adminInOperativeMode).canBookOtherLocations)
        XCTAssertFalse(candidate(operative).canBookOtherLocations)
    }

    // MARK: 10. Leave decision notices (`resolveBookingPerson`, then `holidayDecisionRecipients`)

    /// A request stored only under a catalogue row reaches the account on that row's email whatever its level (the
    /// screens used to accept an operative-mode account only), and the decider is never notified of their own decision.
    func testLeaveDecisionNoticeFindsTheRequesterAccount() {
        let manager = staffUser(id: "uid-mgr", email: "boss@example.com", operativeMode: false)
        let catalogue = LogicFixtures.operative(id: UUID(), email: "BOSS@example.com")
        var record = LogicFixtures.holiday(userId: "", start: orgDay("2026-11-04"), end: orgDay("2026-11-04"))
        record.userId = nil
        record.operativeIdRaw = catalogue.documentId
        let requester = AnnualLeaveApproval.requester(for: record, users: [manager], operatives: [catalogue])
        XCTAssertEqual(requester?.id, "uid-mgr")
        XCTAssertEqual(
            CanonicalBusinessEngine.holidayDecisionRecipients(requester: "uid-mgr", decider: "uid-admin", roster: []),
            ["uid-mgr"]
        )
        XCTAssertEqual(
            CanonicalBusinessEngine.holidayDecisionRecipients(requester: "uid-mgr", decider: "uid-mgr", roster: []),
            []
        )
    }

    // MARK: 11. Timesheet pay-run zone (`organizationTimeZone`)

    /// Pay-run day keys use the open organisation's zone, not a fixed Europe/London.
    func testTimesheetPayRunZoneIsTheOrganisationZone() {
        var org = Organization(firestoreDocumentId: "TEST-ORG-IE", name: "TEST-Ireland", creatorUserId: "TEST-FOUNDER")
        org.countryCode = "IE"
        OrganizationRulebookContext.update(from: org)
        defer { OrganizationRulebookContext.update(from: nil) }
        XCTAssertEqual(TimesheetPayrollPolicy.organizationTimeZone, "Europe/Dublin")
        XCTAssertEqual(TimesheetPayrollPolicy.organizationTimeZone, OrganizationRulebookContext.timeZoneIdentifier)
    }

    // MARK: 12. Monday-first weeks (`OrganizationRulebookContext.calendar`)

    /// Materials week strips start on Monday in the organisation zone whatever the phone's locale says.
    func testMaterialsWeekStartsOnMonday() {
        let days = MaterialsWeekHelpers.weekDays(containing: orgDay("2026-11-08"))
        XCTAssertEqual(days.count, 7)
        XCTAssertEqual(days.first.map(OrganizationRulebookContext.dayKey), "2026-11-02")
        XCTAssertEqual(days.last.map(OrganizationRulebookContext.dayKey), "2026-11-08")
    }

    /// The selected day, the lines on it and their labels are organisation days too, so they agree with the
    /// organisation-calendar week strip on a phone in another zone.
    func testMaterialsSelectionUsesOrganisationDays() {
        let lateMonday = orgDay("2026-11-02").addingTimeInterval(23.5 * 3600)
        let earlyTuesday = orgDay("2026-11-03").addingTimeInterval(0.5 * 3600)
        XCTAssertTrue(MaterialsDay.same(orgDay("2026-11-02"), lateMonday))
        XCTAssertFalse(MaterialsDay.same(lateMonday, earlyTuesday))
        XCTAssertEqual(MaterialsDay.formatter("d MMM").timeZone, OrganizationRulebookContext.timeZone)
        XCTAssertEqual(MaterialsDay.formatter("EEE").string(from: lateMonday).isEmpty, false)
    }

    // MARK: 13. No Swift fallbacks (`bookingIdsForAccount`, `lineManagerIds`, `userTimesheetSubjects`)

    /// With the script answering, the account's ids are the rulebook's (`bookingIdsForAccount`): own, former and the
    /// catalogue row on its email. The Swift copy used when the script did not answer is gone (fail closed).
    func testAccountIdsComeOnlyFromTheRulebook() {
        let person = staffUser(id: "uid-1", email: "ada@example.com", formerUserIds: ["invite-1"])
        let catalogue = LogicFixtures.operative(id: UUID(), email: "ADA@example.com")
        let ids = labourBookingIds(for: person, operatives: [catalogue])
        XCTAssertTrue(ids.contains(catalogue.id))
        XCTAssertTrue(ids.contains(Booking.internalOperativeId(for: "invite-1")))
        XCTAssertTrue(ids.contains(Booking.internalOperativeId(for: "uid-1")))
    }

    // MARK: 15. 1.31.0 hand-off item (`timesheetDocumentSubjectId`)

    /// Exported sheets stored without `userId` are matched by their document id.
    func testTimesheetSubjectIdComesFromTheDocumentId() {
        XCTAssertEqual(CanonicalBusinessEngine.timesheetDocumentSubjectId("timesheet_ABC-123_1761955200"), "ABC-123")
        XCTAssertEqual(CanonicalBusinessEngine.timesheetDocumentSubjectId("timesheet_user_with_underscore_1761955200"), "user_with_underscore")
        XCTAssertEqual(CanonicalBusinessEngine.timesheetDocumentSubjectId("settings"), "")
    }

    // MARK: 16. Own-profile save: changed fields only (`userProfileWriteFields`)

    /// A phone-number edit sends the phone only; a name edit sends the name group, never the email or phone again.
    func testProfileIdentitySaveSendsOnlyChangedFields() throws {
        var loaded = staffUser(id: "uid-1", email: "ada@example.com")
        loaded.mobileNumber = "07000 000000"
        let phoneOnly = try XCTUnwrap(FirebaseBackend.userIdentityChanges(
            firstName: "Ada", surname: "Lovelace", email: "ada@example.com", mobileNumber: "07111 111111", previous: loaded
        ))
        XCTAssertEqual(Set(phoneOnly.keys), ["mobileNumber"])
        XCTAssertEqual(phoneOnly["mobileNumber"] as? String, "07111 111111")

        let rename = try XCTUnwrap(FirebaseBackend.userIdentityChanges(
            firstName: "Augusta", surname: "Lovelace", email: "ada@example.com", mobileNumber: "07000 000000", previous: loaded
        ))
        XCTAssertTrue(rename.keys.contains("firstName"))
        XCTAssertFalse(rename.keys.contains("email"))
        XCTAssertFalse(rename.keys.contains("mobileNumber"))

        let unchanged = try XCTUnwrap(FirebaseBackend.userIdentityChanges(
            firstName: "Ada", surname: "Lovelace", email: "ADA@example.com ", mobileNumber: "07000 000000", previous: loaded
        ))
        XCTAssertTrue(unchanged.isEmpty)
    }

    // MARK: 17. Variation deep links (`notificationDestination` → `variations`)

    /// A renumbered-variations notice opens that job's Variations tile (web opens Variations); it used to fall back
    /// to the notification inbox. The job's collection comes from the payload's `catalogue`, never from `userId`
    /// (the recipient); with no catalogue it is left to the loaded jobs (no `isSmallWorks` in the request).
    func testVariationNoticeOpensTheJobsVariations() {
        let admin = levelUser(id: "admin", role: .admin, permissions: UserPermissions(adminAccess: true, manager: true))
        var received: [[String: Any]] = []
        let token = NotificationCenter.default.addObserver(forName: .openWorkCatalogueDetail, object: nil, queue: nil) { note in
            received.append(note.userInfo as? [String: Any] ?? [:])
        }
        defer { NotificationCenter.default.removeObserver(token) }
        NotificationDeepLink.route(
            userInfo: [
                NotificationDeepLink.typeKey: "variation_renumbered",
                NotificationDeepLink.relatedIdKey: "TEST-JOB-1",
                NotificationDeepLink.catalogueKey: "smallWorks",
                NotificationDeepLink.userIdKey: "recipient-uid",
            ],
            user: admin
        )
        NotificationDeepLink.route(
            userInfo: [
                NotificationDeepLink.typeKey: "variation_renumbered",
                NotificationDeepLink.relatedIdKey: "TEST-JOB-2",
                NotificationDeepLink.userIdKey: "smallWork",
            ],
            user: admin
        )
        XCTAssertEqual(received.count, 2)
        XCTAssertEqual(received.first?["section"] as? String, "variations")
        XCTAssertEqual(received.first?["isSmallWorks"] as? Bool, true)
        XCTAssertEqual(received.first?["projectId"] as? UUID, JobKeys.inAppId("TEST-JOB-1"))
        XCTAssertNil(received.last?["isSmallWorks"], "userId is the recipient and never decides the job's collection")
        XCTAssertEqual(received.last?["projectId"] as? UUID, JobKeys.inAppId("TEST-JOB-2"))
    }
}
