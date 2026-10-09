import XCTest
@testable import Project_Planner

@MainActor
final class StaffEmailIdentityTests: XCTestCase {
    private let thursday = LogicFixtures.day(2026, 10, 8, hour: 8)

    func testOneEmailIsOnePersonForBookLabourAndHolidays() {
        let email = "operative@example.com"
        let quietId = UUID()
        let busyId = UUID()
        var user = LogicFixtures.selfEmployedUser(id: "op-user", email: email, dayRate: 350)
        user.passwordSet = true
        var other = LogicFixtures.selfEmployedUser(id: "other-user", email: "other@example.com")
        other.passwordSet = true
        let quiet = LogicFixtures.operative(id: quietId, email: email, dayRate: 25)
        let busy = LogicFixtures.operative(id: busyId, email: email, dayRate: 25)
        let otherOperative = LogicFixtures.operative(id: UUID(), email: other.email)
        let fullDay = LogicFixtures.booking(on: thursday, operativeId: busyId)
        let choices = BookLabourCandidateSelection.choices(
            day: thursday,
            users: [user, other],
            operatives: [quiet, busy, otherOperative],
            operativeBookings: [fullDay],
            managerBookings: [],
            holidays: [],
            policy: LogicFixtures.policy,
            focusedIds: [],
            includeThisDay: true
        )
        XCTAssertEqual(choices.map(\.userId), [other.id], "Eight hours on either operative id covers the person")

        let holiday = LogicFixtures.holiday(userId: "", start: thursday, end: thursday)
        var onAlias = holiday
        onAlias.operativeId = quietId
        onAlias.userId = nil
        let covered = BookLabourCandidateSelection.choices(
            day: thursday,
            users: [user, other],
            operatives: [quiet, busy, otherOperative],
            operativeBookings: [],
            managerBookings: [],
            holidays: [onAlias],
            policy: LogicFixtures.policy,
            focusedIds: [],
            includeThisDay: true
        )
        XCTAssertEqual(covered.map(\.userId), [other.id], "A holiday on any id for the email covers the person")
    }

    func testBookLabourLinksTheProfileThatHoldsTodaysHours() {
        let email = "operative@example.com"
        let heavyId = UUID()
        let busyId = UUID()
        var heavy = LogicFixtures.operative(id: heavyId, email: email)
        let qualificationId = UUID()
        heavy.qualificationExpiryDates = [qualificationId: thursday]
        heavy.qualificationCertificateURLs = [qualificationId: "https://example.test/cert"]
        let busy = LogicFixtures.operative(id: busyId, email: email)
        var user = LogicFixtures.selfEmployedUser(id: "op-user", email: email)
        user.passwordSet = true
        let morning = LogicFixtures.booking(on: thursday, slot: .morning, operativeId: busyId)
        let choices = BookLabourCandidateSelection.choices(
            day: thursday,
            users: [user],
            operatives: [heavy, busy],
            operativeBookings: [morning],
            managerBookings: [],
            holidays: [],
            policy: LogicFixtures.policy,
            focusedIds: [],
            includeThisDay: true
        )
        XCTAssertEqual(choices.map(\.operativeId), [busyId])
    }

    func testPreferredAccountAndPersonKey() {
        let pending = AppUser(
            id: "pending",
            email: "Manager@Example.com",
            organizationId: "org",
            role: .manager,
            firstName: "Pending",
            surname: "Manager",
            isActive: true,
            passwordSet: false,
            permissions: UserPermissions(manager: true)
        )
        let finished = AppUser(
            id: "finished",
            email: "manager@example.com",
            organizationId: "org",
            role: .manager,
            firstName: "Test",
            surname: "Manager",
            isActive: true,
            passwordSet: true,
            permissions: UserPermissions(manager: true),
            hourlyRate: 25,
            tradeTypePreset: "Electrician",
            employmentType: .selfEmployed
        )
        XCTAssertEqual(StaffEmailIdentity.preferredUser([pending, finished])?.id, "finished")
        XCTAssertEqual(StaffEmailIdentity.personKey(email: "Manager@Example.com", fallbackId: "raw"), "email:manager@example.com")
        let firstOperative = UUID()
        let secondOperative = UUID()
        let keys = StaffEmailIdentity.distinctPersonKeys(
            operativeIds: [firstOperative, secondOperative],
            userIds: [finished.id, pending.id],
            operatives: [
                LogicFixtures.operative(id: firstOperative, email: "same@example.com"),
                LogicFixtures.operative(id: secondOperative, email: "same@example.com")
            ],
            users: [finished, pending]
        )
        XCTAssertEqual(keys, ["email:same@example.com", "email:manager@example.com"])
    }

    func testWeeklyReportTradeAndHourlyPayIgnoreOperativeDayRate() {
        let blank = AppUser(
            id: "blank",
            email: "manager@example.com",
            organizationId: "org",
            role: .manager,
            firstName: "Blank",
            surname: "Manager",
            isActive: true,
            passwordSet: true,
            permissions: UserPermissions(manager: true),
            employmentType: .selfEmployed
        )
        let hourly = AppUser(
            id: "hourly",
            email: "manager@example.com",
            organizationId: "org",
            role: .manager,
            firstName: "Test",
            surname: "Manager",
            isActive: true,
            passwordSet: true,
            permissions: UserPermissions(manager: true),
            hourlyRate: 25,
            tradeTypePreset: "Electrician",
            employmentType: .selfEmployed
        )
        var catalogue = LogicFixtures.operative(id: UUID(), email: hourly.email, dayRate: 25)
        catalogue.tradeTypePreset = "CIjapy1jlgsS95wUUR4e"
        let linked = StaffEmailIdentity.preferredUser([blank, hourly])
        XCTAssertEqual(linked?.id, "hourly")
        XCTAssertEqual(StaffEmailIdentity.reportTrade(for: linked), "Electrician")
        XCTAssertEqual(StaffEmailIdentity.reportTrade(preset: catalogue.tradeTypePreset, custom: nil), "General")
        XCTAssertNil(StaffEmailIdentity.operativeUsedForPay(user: linked, operative: catalogue))
        let rate = PayrollRateResolver.resolveForTimesheetDay(
            user: linked,
            operative: StaffEmailIdentity.operativeUsedForPay(user: linked, operative: catalogue),
            on: thursday,
            history: .empty,
            standardDayHours: 8
        )
        XCTAssertEqual(rate.basis, .hourly)
        XCTAssertEqual(rate.hourlyRate, 25)
        XCTAssertClose(rate.payForHours(40, standardDayHours: 8), 1000)
        XCTAssertClose(rate.payForHours(8, standardDayHours: 8), 200)
    }

    func testAliasManagerBookingIsCollectedOnce() {
        let email = "manager@example.com"
        let primary = AppUser(
            id: "primary",
            email: email,
            organizationId: "org",
            role: .manager,
            firstName: "Test",
            surname: "Manager",
            isActive: true,
            passwordSet: true,
            permissions: UserPermissions(manager: true),
            hourlyRate: 25,
            employmentType: .selfEmployed
        )
        let alias = AppUser(
            id: "alias",
            email: email,
            organizationId: "org",
            role: .manager,
            firstName: "Test",
            surname: "Manager",
            isActive: true,
            passwordSet: false,
            permissions: UserPermissions(manager: true),
            hourlyRate: 25,
            employmentType: .selfEmployed
        )
        let booking = ManagerSiteBooking(
            userId: alias.id,
            date: thursday,
            timeSlot: .fullDay,
            locationType: .project,
            locationId: UUID()
        )
        let summary = TimesheetPayrollCollector.collect(
            for: primary,
            in: thursday...thursday,
            bookings: [],
            managerBookings: [booking],
            operatives: [],
            projects: [],
            smallWorks: [],
            history: .empty,
            policy: LogicFixtures.policy,
            relatedUsers: [primary, alias]
        )
        XCTAssertEqual(summary.shiftCount, 1)
        XCTAssertClose(summary.totalHours, 8)
        XCTAssertClose(summary.baseAmount, 200)
    }

    func testApprovedWeeksForOneEmailMergeBookingIds() {
        let start = LogicFixtures.day(2026, 10, 5)
        let end = LogicFixtures.day(2026, 10, 11)
        let users = [
            AppUser(id: "a", email: "manager@example.com", organizationId: "org", role: .manager, passwordSet: true, permissions: UserPermissions(manager: true)),
            AppUser(id: "b", email: "manager@example.com", organizationId: "org", role: .manager, passwordSet: true, permissions: UserPermissions(manager: true))
        ]
        let shared = labourLine(id: "shared", bookingId: "booking-1", amount: 200)
        let onlyA = labourLine(id: "only-a", bookingId: "booking-2", amount: 100)
        let onlyB = labourLine(id: "only-b", bookingId: "booking-3", amount: 50)
        let weeks = [
            approvedWeek(userId: "a", start: start, end: end, lines: [shared, onlyA]),
            approvedWeek(userId: "b", start: start, end: end, lines: [shared, onlyB])
        ]
        let merged = WeeklyReportTimesheetFeed.mergeApprovedWeeks(weeks, users: users)
        XCTAssertEqual(merged.count, 1)
        let bookingIds = Set(merged[0].override.lines.compactMap(\.bookingId))
        XCTAssertEqual(bookingIds, ["booking-1", "booking-2", "booking-3"])
        XCTAssertEqual(merged[0].override.lines.filter { $0.bookingId == "booking-1" }.count, 1)
        XCTAssertEqual(merged[0].coveredUserIds, ["a", "b"])
    }

    func testIssuedTalkTitleDropsStoragePrefixAndKeepsTheFile() {
        let prefixed = "abcdefghijklmnopqrstuvwxyz 1710000000000 SiteAudit C983 Pre-Start 2Jun26"
        let talk = HSToolboxTalk(
            id: "upload-1",
            title: prefixed,
            category: .general,
            isGeneral: true,
            trades: [],
            purpose: "",
            keyPoints: [],
            source: .uploaded,
            ownerOrganizationId: nil,
            status: .approved,
            version: 1,
            updatedAt: thursday,
            fileURL: "https://example.test/uploads/site-audit.pdf"
        )
        XCTAssertEqual(talk.displayTitle, "SiteAudit C983 Pre-Start 2Jun26")
        XCTAssertEqual(
            ToolboxTalkLibrary.resolvedTitle(talkId: talk.id, storedTalks: [talk]),
            "SiteAudit C983 Pre-Start 2Jun26"
        )
        XCTAssertEqual(ToolboxTalkLibrary.strippingStorageObjectPrefix("Working at Height"), "Working at Height")
        let placeholder = HSToolboxTalk(
            id: "TBT-UP-3ACF8B6D",
            title: "TBT",
            category: .general,
            isGeneral: true,
            trades: [],
            purpose: "CUSTOM",
            keyPoints: [],
            source: .uploaded,
            ownerOrganizationId: nil,
            status: .approved,
            version: 1,
            updatedAt: thursday,
            fileURL: "https://firebasestorage.googleapis.com/v0/b/project-planner-f986c.firebasestorage.app/o/organizations%2Forg%2FhealthSafety%2Fjob%2Fother%2Fdul1tDjfQfMX6ruXPHb8kJX5P7g2_1789399717_SiteAudit_C983_Pre-Start_2Jun26.pdf?alt=media&token=abc"
        )
        XCTAssertEqual(placeholder.displayTitle, "SiteAudit C983 Pre-Start 2Jun26")
        XCTAssertEqual(placeholder.storedFileURL?.absoluteString, placeholder.fileURL)
        XCTAssertTrue(talk.isCustomUpload)
        XCTAssertEqual(talk.storedFileURL?.absoluteString, "https://example.test/uploads/site-audit.pdf")
    }

    func testCatalogueManagerWithoutAUserIsNotEligible() {
        let catalogue = Manager(
            firstName: "P",
            lastName: "N",
            email: "p@ekecteic.con",
            mobileNumber: "",
            isActive: true
        )
        let inactive = Manager(
            firstName: "Old",
            lastName: "Manager",
            email: "old@example.com",
            mobileNumber: "",
            isActive: false
        )
        let linked = Manager(
            firstName: "Test",
            lastName: "Manager",
            email: "manager@example.com",
            mobileNumber: "",
            isActive: true
        )
        let alreadyAssigned = Manager(
            firstName: "Kept",
            lastName: "On Job",
            email: "kept@example.com",
            mobileNumber: "",
            isActive: true
        )
        let users = [
            AppUser(id: "mgr", email: "manager@example.com", organizationId: "org", role: .manager, isActive: true, passwordSet: true, permissions: UserPermissions(manager: true)),
            AppUser(id: "kept", email: "kept@example.com", organizationId: "org", role: .manager, isActive: true, passwordSet: true, permissions: UserPermissions(manager: true)),
            AppUser(id: "old", email: "old@example.com", organizationId: "org", role: .manager, isActive: false, passwordSet: true, permissions: UserPermissions(manager: true))
        ]
        let eligible = ProjectManagerPickerSupport.eligibleCatalogueManagers(
            roster: [catalogue, inactive, linked, alreadyAssigned],
            users: users,
            excluding: [alreadyAssigned]
        )
        XCTAssertEqual(eligible.map(\.email), ["manager@example.com"])
    }

    func testUnbookedBoardStillListsSomeoneExcludedFromWarnings() {
        let admin = AppUser(
            id: "admin",
            email: "admin@example.com",
            organizationId: "org",
            role: .admin,
            firstName: "Test",
            surname: "Admin",
            isActive: true,
            passwordSet: true,
            permissions: UserPermissions(adminAccess: true),
            isSuperAdmin: true
        )
        let lines = LabourDayCoverage.unbookedLines(
            day: thursday,
            users: [admin],
            operatives: [],
            operativeBookings: [],
            managerBookings: [],
            holidays: [],
            policy: LogicFixtures.policy
        )
        XCTAssertEqual(lines, ["Test Admin (missing 8h)"])
    }

    func testExcludedWarningIdsCoverEveryAccountOnTheEmail() {
        let people: [[String: Any]] = [
            ["id": "admin-a", "email": "Admin@Example.com"],
            ["id": "admin-b", "email": "admin@example.com"],
            ["id": "manager", "email": "manager@example.com"]
        ]
        let expanded = Set(WarningsComputation.expandedExcludedUserIds(["admin-a"], people: people))
        XCTAssertEqual(expanded, ["admin-a", "admin-b"])
    }

    func testUnbookedScriptUsesTheSameAccountOnEveryPhone() {
        let people = WarningsComputation.orderedPeopleForUnbookedScript([
            ["id": "rWoccK8LDZVJjBj3UCbqay8bPyf2", "email": "Manager@Example.com", "passwordSet": true, "isActive": true],
            ["id": "463952DE-0375-435D-8AB3-67570C902C56", "email": "manager@example.com", "passwordSet": true, "isActive": true]
        ])
        let firstFinished = people.first { ($0["passwordSet"] as? Bool) == true }
        XCTAssertEqual(firstFinished?["id"] as? String, "463952DE-0375-435D-8AB3-67570C902C56")
    }

    func testEveningPaidHoursDoNotHideAnUnbookedStandardDay() throws {
        let calendar = CanonicalBusinessEngine.businessCalendar
        let monday = try XCTUnwrap(CanonicalBusinessEngine.date(fromDayKey: "2026-10-05", calendar: calendar))
        let operativeId = UUID()
        let snapshot = WarningsComputationSnapshot(
            operatives: [
                .init(
                    id: operativeId,
                    name: "Ada Lovelace",
                    emailLowercased: "ada@example.com",
                    isActive: true,
                    qualificationExpiries: []
                )
            ],
            bookings: [
                .init(
                    id: UUID(),
                    operativeId: operativeId,
                    projectId: UUID(),
                    date: monday,
                    dayStart: monday,
                    isActiveStatus: true,
                    paidHours: 8,
                    scheduleLabel: "Evening",
                    clashInterval: nil,
                    timeSlot: "CUSTOM_HOURS",
                    workStart: "18:00",
                    workEnd: "20:00"
                )
            ],
            projects: [],
            users: [
                .init(
                    id: "ada-user",
                    emailLowercased: "ada@example.com",
                    displayName: "Ada Lovelace",
                    isActive: true,
                    passwordSet: true,
                    createdAt: monday,
                    isOperativeMode: true,
                    isManager: false,
                    hasAdminAccess: false,
                    isSuperAdmin: false,
                    isAdminRole: false
                )
            ],
            managerSiteBookings: [],
            holidayBookings: [],
            payrollTimePolicy: .init(
                standardPaidHours: 8,
                standardDayStart: "07:30",
                standardDayEnd: "16:00",
                breakWindowStart: "12:00",
                breakWindowEnd: "12:30",
                standardUnpaidBreakHours: 0.5,
                saturdayCountsAsHours: 0,
                sundayCountsAsHours: 0
            ),
            warningDetection: .init(
                detectClashes: false,
                includeWeekendsForUnbookedLabour: false,
                excludedUserIdsFromUnbookedWarnings: []
            ),
            coverageStart: monday,
            coverageEnd: monday,
            materialOrderCutOffEnabled: false,
            materialCutOffOnSaturday: false,
            materialCutOffOnSunday: false,
            projectsWithTomorrowBookingIds: [],
            materialItemsForTomorrow: []
        )
        let unbooked = WarningsComputation.generate(snapshot).filter { $0.type == .unbookedLabour }
        XCTAssertEqual(unbooked.count, 1)
        XCTAssertTrue(unbooked[0].message.contains("Ada Lovelace"))
    }

    func testWarningPayloadRepeatsAliasCoverage() {
        let bookings: [[String: Any]] = [[
            "personId": "alias",
            "dayKey": "2026-10-08",
            "kind": "manager",
            "timeSlot": "FULL DAY",
            "workStart": "",
            "workEnd": ""
        ]]
        let holidays: [[String: Any]] = [[
            "userId": "",
            "operativeId": "quiet-operative",
            "startDayKey": "2026-10-08",
            "endDayKey": "2026-10-08",
            "approved": true
        ]]
        let people: [[String: Any]] = [
            ["id": "primary", "email": "person@example.com"],
            ["id": "alias", "email": "person@example.com"]
        ]
        let operatives: [[String: Any]] = [
            ["id": "quiet-operative", "email": "person@example.com"],
            ["id": "busy-operative", "email": "person@example.com"]
        ]
        let shared = WarningsComputation.shareCoverageAcrossEmail(
            bookings: bookings,
            holidays: holidays,
            people: people,
            operatives: operatives
        )
        let personIds = Set(shared.bookings.compactMap { $0["personId"] as? String })
        XCTAssertEqual(personIds, ["primary", "alias"])
        let holidayOperatives = Set(shared.holidays.compactMap { $0["operativeId"] as? String })
        XCTAssertTrue(holidayOperatives.contains("busy-operative"))
        XCTAssertTrue(holidayOperatives.contains("quiet-operative"))
    }

    func testQualificationsHubStaysOpenWhenTheCatalogueToggleIsOff() {
        let manager = AppUser(
            id: "mgr",
            email: "manager@example.com",
            organizationId: "org",
            role: .manager,
            passwordSet: true,
            permissions: UserPermissions(manager: true, qualifications: false)
        )
        XCTAssertTrue(QualificationsAccessPolicy.canOpenQualificationsHub(user: manager, isOperativeMode: false, hasAdminAccess: false))
        XCTAssertFalse(QualificationsAccessPolicy.canManageOrganisationCatalogue(user: manager, isOperativeMode: false, hasAdminAccess: false))
        let superAdmin = AppUser(
            id: "super",
            email: "admin@example.com",
            organizationId: "org",
            role: .admin,
            passwordSet: true,
            permissions: UserPermissions(qualifications: false),
            isSuperAdmin: true
        )
        XCTAssertTrue(QualificationsAccessPolicy.canManageOrganisationCatalogue(user: superAdmin, isOperativeMode: false, hasAdminAccess: true))
        XCTAssertFalse(QualificationsAccessPolicy.canOpenQualificationsHub(user: manager, isOperativeMode: true, hasAdminAccess: false))
        XCTAssertTrue(QualificationsAccessPolicy.managePermissionDoesNotMutateStoredQualifications)
    }

    func testRosterAdminAndAccountTypePresets() {
        let operative = AppUser(
            id: "op",
            email: "op@example.com",
            organizationId: "org",
            role: .operative,
            permissions: UserPermissions(operativeMode: true)
        )
        let adminByRole = AppUser(
            id: "admin",
            email: "admin@example.com",
            organizationId: "org",
            role: .admin,
            permissions: UserPermissions()
        )
        XCTAssertFalse(operative.isRosterAdmin)
        XCTAssertTrue(adminByRole.isRosterAdmin)
        XCTAssertTrue(operative.appearsOnOperativesList)
        XCTAssertFalse(adminByRole.appearsOnOperativesList)

        let operativePermissions = UserRoleTransitionPolicy.permissions(
            for: .operative,
            carryingFrom: UserPermissions(manager: true, projects: true, weeklyReports: true),
            manager: nil,
            operative: OperativeUserTypeTransitionConfig(materials: true, siteAudit: false)
        )
        XCTAssertTrue(operativePermissions.operativeMode)
        XCTAssertTrue(operativePermissions.materials)
        XCTAssertFalse(operativePermissions.siteAudit)
        XCTAssertFalse(operativePermissions.weeklyReports)
        XCTAssertFalse(operativePermissions.adminAccess)
        let staff = UserRoleTransitionPolicy.permissions(
            for: .manager,
            carryingFrom: UserPermissions(),
            manager: nil,
            operative: nil
        )
        XCTAssertTrue(staff.materials)
        XCTAssertTrue(staff.siteAudit)
        XCTAssertEqual(
            UserRoleTransitionPolicy.adminAccessLockedUntilAccountTypeChanges,
            "Change user type at the bottom of their profile, to enable admin level access."
        )
    }

    func testPermissionTogglesFollowTheRulebook() {
        let store = UserStore()
        store.currentUser = AppUser(
            id: "super",
            email: "admin@example.com",
            organizationId: "org",
            role: .admin,
            isActive: true,
            passwordSet: true,
            permissions: UserPermissions(operatives: false, projects: false, smallWorks: false, weeklyReports: false, dailyOverview: false, wholesalersOrderHistory: false),
            isSuperAdmin: true
        )
        XCTAssertTrue(store.canManageWorkCatalogue(.projects))
        XCTAssertTrue(store.canManageWorkCatalogue(.smallWorks))
        XCTAssertTrue(store.canViewOperatives())
        XCTAssertTrue(store.canAccessWholesalers())
        XCTAssertTrue(store.canViewProjects())
        XCTAssertFalse(store.canViewWeeklyReports())
        XCTAssertFalse(store.canViewDailyOverview())
        XCTAssertTrue(store.canManageUsers())
        XCTAssertFalse(store.canManageSkills())

        store.currentUser = AppUser(
            id: "manager",
            email: "manager@example.com",
            organizationId: "org",
            role: .manager,
            isActive: true,
            passwordSet: true,
            permissions: UserPermissions(manager: true, operatives: true, projects: false, smallWorks: true, weeklyReports: false, dailyOverview: true, wholesalersOrderHistory: false)
        )
        XCTAssertFalse(store.canManageWorkCatalogue(.projects))
        XCTAssertTrue(store.canManageWorkCatalogue(.smallWorks))
        XCTAssertTrue(store.canViewProjects())
        XCTAssertTrue(store.canViewOperatives())
        XCTAssertFalse(store.canAccessWholesalers())
        XCTAssertFalse(store.canViewWeeklyReports())
        XCTAssertTrue(store.canViewDailyOverview())
        XCTAssertFalse(store.canManageUsers())
        XCTAssertTrue(store.isActingManagerOperativeManagementOnly())

        store.currentUser = AppUser(
            id: "operative",
            email: "op@example.com",
            organizationId: "org",
            role: .operative,
            isActive: true,
            passwordSet: true,
            permissions: UserPermissions(materials: true, projects: true, operativeMode: true, siteAudit: true, wholesalersOrderHistory: true)
        )
        XCTAssertFalse(store.canAccessWholesalers())
        XCTAssertFalse(store.canViewOperatives())
        XCTAssertFalse(store.canManageUsers())
        XCTAssertTrue(store.canViewMaterials())
        XCTAssertTrue(store.canViewSiteAudit())
    }

    func testRosterKeepsReadableTradeFromTheOtherAccount() {
        let blank = AppUser(
            id: "463952DE-0375-435D-8AB3-67570C902C56",
            email: "manager@example.com",
            organizationId: "org",
            role: .manager,
            firstName: "Test",
            surname: "Manager",
            isActive: true,
            passwordSet: true,
            permissions: UserPermissions(manager: true),
            hourlyRate: 25,
            employmentType: .selfEmployed
        )
        let electrician = AppUser(
            id: "rWoccK8LDZVJjBj3UCbqay8bPyf2",
            email: "manager@example.com",
            organizationId: "org",
            role: .manager,
            firstName: "Test",
            surname: "Manager",
            isActive: true,
            passwordSet: true,
            permissions: UserPermissions(manager: true, operativeMode: true),
            hourlyRate: 25,
            tradeTypePreset: "Electrician",
            employmentType: .selfEmployed
        )
        let kept = FirebaseBackend.collapsedRosterUser(blank, electrician)
        XCTAssertEqual(kept.id, blank.id)
        XCTAssertEqual(StaffEmailIdentity.reportTrade(for: kept), "Electrician")
        XCTAssertEqual(Set(kept.sameEmailUserIds), ["rWoccK8LDZVJjBj3UCbqay8bPyf2"])
        XCTAssertEqual(
            StaffEmailIdentity.userIds(sharing: kept.email, in: [kept]),
            ["463952DE-0375-435D-8AB3-67570C902C56", "rWoccK8LDZVJjBj3UCbqay8bPyf2"]
        )
        let keptOtherWay = FirebaseBackend.collapsedRosterUser(electrician, blank)
        XCTAssertEqual(StaffEmailIdentity.reportTrade(for: keptOtherWay), "Electrician")
    }

    func testExcludedWarningIdsSurviveFirestoreArrayShapes() {
        let uid = "dul1tDjfQfMX6ruXPHb8kJX5P7g2"
        let ns = NSArray(object: uid as NSString)
        let fromArray = OrgWarningDetectionSettings.excludedUserIds(from: [
            "excludedUserIdsFromUnbookedWarnings": ns,
        ])
        XCTAssertEqual(fromArray, [uid])

        let org = FirebaseBackend.organizationSettingsFromOrgDocument([
            "warningDetection": [
                "detectClashes": true,
                "clashLookaheadMode": "endOfInvoicingPeriod",
                "excludedUserIdsFromUnbookedWarnings": [] as [String],
            ],
            "settings": [
                "warningDetection": [
                    "excludedUserIdsFromUnbookedWarnings": [uid],
                ],
            ],
        ])
        XCTAssertEqual(org.warningDetection.excludedUserIdsFromUnbookedWarnings, [])
        XCTAssertEqual(org.warningDetection.clashLookaheadMode, .endOfInvoicingPeriod)
        XCTAssertEqual(org.warningDetection.clashLookaheadDays, 7)

        let filledFromNested = FirebaseBackend.organizationSettingsFromOrgDocument([
            "warningDetection": [
                "clashLookaheadMode": "numberOfDays",
            ],
            "settings": [
                "warningDetection": [
                    "excludedUserIdsFromUnbookedWarnings": [uid],
                ],
            ],
        ])
        XCTAssertEqual(filledFromNested.warningDetection.excludedUserIdsFromUnbookedWarnings, [uid])
    }

    private func labourLine(id: String, bookingId: String, amount: Double) -> TimesheetWeeklyReportLabourLine {
        TimesheetWeeklyReportLabourLine(
            id: id,
            date: thursday,
            jobNumber: "C984",
            projectName: "71 Broadwick Street",
            locationKind: "project",
            details: "Full day",
            paidHours: 8,
            days: 1,
            amount: amount,
            isOvertime: false,
            decision: .approved,
            bookingId: bookingId
        )
    }

    private func approvedWeek(
        userId: String,
        start: Date,
        end: Date,
        lines: [TimesheetWeeklyReportLabourLine]
    ) -> WeeklyReportTimesheetFeed.ApprovedWeek {
        WeeklyReportTimesheetFeed.ApprovedWeek(
            userId: userId,
            personName: "Test Manager",
            role: "Admin User",
            tradeDisplay: "Electrician",
            tradeSortKey: "electrician",
            weekStart: start,
            weekEnd: end,
            override: TimesheetWeeklyReportOverride(
                approvedAt: thursday,
                approvedByUserId: userId,
                approvedByName: "Test Manager",
                selfSigned: false,
                lines: lines,
                priceWork: [],
                expenses: []
            ),
            coveredUserIds: [userId]
        )
    }
}
