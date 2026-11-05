import XCTest
@testable import Project_Planner

/// RULEBOOK 1.32.0 iOS follow-on (web hand-off v1.32.0, §7, §8, §11): pay visibility narrowed
/// (`canViewPersonPay(viewer, subject, roster, { context })`), the Weekly report admin-only (`canOpenWeeklyReport`,
/// `permissionToggleRows`), the weekly report PAYE overtime rows per multiplier (`weeklyReportPayeOvertime`,
/// `OVERTIME_RATE_CHANGED_MARK`) and the pay summary per viewer (`reportPayForViewer`, `PAY_HIDDEN_CELL_LABEL`,
/// `PAY_HIDDEN_NOTE`). Every answer comes from the packed script through `CanonicalBusinessEngine`; these tests lock the
/// Swift inputs and readings.
@MainActor
final class Rulebook1320PayVisibilityTests: XCTestCase {
    // MARK: Fixtures

    private let operative: [String: Any] = [
        "id": "TEST-OP", "email": "op@test.example", "isActive": true, "role": "operative", "operativeMode": true,
        "permissions": ["operativeMode": true], "assignedManagerUserIds": ["TEST-LM"],
    ]
    private let lineManager: [String: Any] = [
        "id": "TEST-LM", "email": "lm@test.example", "isActive": true, "role": "manager", "manager": true,
        "permissions": ["manager": true],
    ]
    private let operativesManager: [String: Any] = [
        "id": "TEST-OM", "email": "om@test.example", "isActive": true, "role": "manager", "manager": true,
        "operatives": true, "permissions": ["manager": true, "operatives": true],
    ]
    private let admin: [String: Any] = [
        "id": "TEST-ADMIN", "email": "admin@test.example", "isActive": true, "role": "admin", "adminAccess": true,
        "permissions": ["adminAccess": true],
    ]
    private var roster: [[String: Any]] { [operative, lineManager, operativesManager, admin] }

    private let org: [String: Any] = [
        "countryCode": "GB",
        "payrollTimePolicy": [
            "standardDayStart": "07:30",
            "standardDayEnd": "16:00",
            "unpaidBreakMinutes": 30,
            "breakWindowStart": "12:00",
            "breakWindowEnd": "12:30",
            "weekdayOutsideStandardMultiplier": 1.5,
            "saturday": [
                "allHoursAtMultiplierMode": false, "definedWindowStart": "07:30", "definedWindowEnd": "14:00",
                "countsAsStandardHours": 8, "outsideWindowMultiplier": 1.5,
            ] as [String: Any],
            "sunday": ["allHoursAtMultiplierMode": true, "allHoursMultiplier": 2, "sameAsSaturday": false] as [String: Any],
        ] as [String: Any],
    ]

    override func setUp() {
        super.setUp()
        OrganizationRulebookContext.update(from: Organization(firestoreDocumentId: "TEST-ORG-1320", name: "TEST-Company 1320"))
        EffectivePermissionsCache.reset()
    }

    override func tearDown() {
        OrganizationRulebookContext.update(from: nil)
        EffectivePermissionsCache.reset()
        super.tearDown()
    }

    private func booking(_ id: String, _ dayKey: String, _ start: String, _ end: String, rate: Double? = nil) -> OvertimeBookingInput {
        OvertimeBookingInput(
            id: id,
            collection: "bookings",
            personId: "TEST-SAM",
            dayKey: dayKey,
            timeSlot: "CUSTOM_HOURS",
            workStartTime: start,
            workEndTime: end,
            isBreakRemoved: false,
            otMultiplierOverride: rate,
            status: "Confirmed",
            jobId: "TEST-JOB-1",
            jobNumber: "J-1042",
            jobName: "Riverside Flats"
        )
    }

    private func user(
        _ id: String,
        role: UserRole,
        permissions: UserPermissions,
        isActive: Bool = true,
        isSuperAdmin: Bool = false,
        managers: [String] = []
    ) -> AppUser {
        AppUser(
            id: id,
            email: "\(id.lowercased())@test.example",
            organizationId: "TEST-ORG-1320",
            role: role,
            firstName: id,
            surname: "Test",
            isActive: isActive,
            passwordSet: true,
            permissions: permissions,
            isSuperAdmin: isSuperAdmin,
            assignedManagerUserIds: managers
        )
    }

    // MARK: Packed script

    func testThePackedScriptIs1320OrLaterAndExportsThePayVisibilityRules() throws {
        let version = try XCTUnwrap(CanonicalBusinessEngine.rulebookStamp()?.version)
        XCTAssertNotEqual(version.compare("1.32.0", options: .numeric), .orderedAscending, "rulebook \(version) is older than 1.32.0")
        let exports = Set(CanonicalBusinessEngine.exportNames())
        for name in [
            "canViewPersonPay", "canOpenWeeklyReport", "reportPayForViewer", "PAY_HIDDEN_CELL_LABEL", "PAY_HIDDEN_NOTE",
            "weeklyReportPayeOvertime", "overtimeMultiplierText", "OVERTIME_RATE_CHANGED_MARK", "permissionToggleRows",
        ] {
            XCTAssertTrue(exports.contains(name), "missing export \(name)")
        }
    }

    // MARK: canViewPersonPay context (§8)

    func testALineManagerSeesAReportsPayOnlyInTimesheetReview() {
        XCTAssertFalse(CanonicalBusinessEngine.canViewPersonPay(viewer: lineManager, subject: operative, roster: roster, context: .profile))
        XCTAssertTrue(CanonicalBusinessEngine.canViewPersonPay(viewer: lineManager, subject: operative, roster: roster, context: .timesheetReview))
    }

    func testAdminsOperativesManagersAndThePersonSeePayInEveryContext() {
        for context in [RulebookPayViewContext.profile, .timesheetReview] {
            XCTAssertTrue(CanonicalBusinessEngine.canViewPersonPay(viewer: admin, subject: operative, roster: roster, context: context))
            XCTAssertTrue(CanonicalBusinessEngine.canViewPersonPay(viewer: operativesManager, subject: operative, roster: roster, context: context))
            XCTAssertTrue(CanonicalBusinessEngine.canViewPersonPay(viewer: operative, subject: operative, roster: roster, context: context))
            XCTAssertFalse(CanonicalBusinessEngine.canViewPersonPay(viewer: operativesManager, subject: lineManager, roster: roster, context: context))
        }
    }

    func testUserStoreCanViewPayPassesTheContext() {
        let store = UserStore()
        let manager = user("TEST-LM", role: .manager, permissions: UserPermissions(manager: true))
        let report = user("TEST-OP", role: .operative, permissions: UserPermissions(operativeMode: true), managers: ["TEST-LM"])
        store.currentUser = manager
        store.organizationUsers = [manager, report]
        XCTAssertFalse(store.canViewPay(of: report, context: .profile), "Manage Users is not a timesheet review")
        XCTAssertTrue(store.canViewPay(of: report, context: .timesheetReview))
        XCTAssertTrue(store.canViewPay(of: manager, context: .profile), "the person always sees their own pay")
    }

    // MARK: Weekly report access (§7, §11)

    func testOnlyActiveAdminsOpenTheWeeklyReport() {
        XCTAssertTrue(CanonicalBusinessEngine.canOpenWeeklyReport(admin))
        var managerWithToggle = lineManager
        managerWithToggle["weeklyReports"] = true
        managerWithToggle["permissions"] = ["manager": true, "weeklyReports": true]
        XCTAssertFalse(CanonicalBusinessEngine.canOpenWeeklyReport(managerWithToggle), "a manager's stored weeklyReports is ignored")
        XCTAssertFalse(CanonicalBusinessEngine.canOpenWeeklyReport(operative))
        var inactiveAdmin = admin
        inactiveAdmin["isActive"] = false
        XCTAssertFalse(CanonicalBusinessEngine.canOpenWeeklyReport(inactiveAdmin))
    }

    func testAppUserAndUserStoreAskCanOpenWeeklyReport() {
        let adminUser = user("TEST-ADMIN", role: .admin, permissions: UserPermissions(adminAccess: true))
        let managerUser = user("TEST-LM", role: .manager, permissions: UserPermissions(manager: true, weeklyReports: true))
        let inactiveAdmin = user("TEST-ADMIN-2", role: .admin, permissions: UserPermissions(adminAccess: true), isActive: false)
        XCTAssertTrue(adminUser.canOpenWeeklyReport)
        XCTAssertFalse(managerUser.canOpenWeeklyReport)
        XCTAssertFalse(inactiveAdmin.canOpenWeeklyReport)

        let store = UserStore()
        store.currentUser = managerUser
        XCTAssertFalse(store.canOpenWeeklyReport())
        XCTAssertFalse(store.canViewWeeklyReports(), "the Home tile follows canOpenWeeklyReport")
        store.currentUser = adminUser
        XCTAssertTrue(store.canOpenWeeklyReport())
        XCTAssertTrue(store.canViewWeeklyReports())
    }

    func testTheWeeklyReportsToggleIsAdminOnlyInThePermissionRows() {
        for mode in [RulebookPermissionToggleMode.add, .edit] {
            let managerRows = CanonicalBusinessEngine.permissionToggleRows(level: .manager, user: nil, mode: mode).filter(\.visible)
            XCTAssertFalse(managerRows.contains { $0.field == "weeklyReports" }, "manager \(mode.rawValue) rows")
            let operativeRows = CanonicalBusinessEngine.permissionToggleRows(level: .operative, user: nil, mode: mode).filter(\.visible)
            XCTAssertFalse(operativeRows.contains { $0.field == "weeklyReports" }, "operative \(mode.rawValue) rows")
            let adminRows = CanonicalBusinessEngine.permissionToggleRows(level: .admin, user: nil, mode: mode).filter(\.visible)
            XCTAssertTrue(adminRows.contains { $0.field == "weeklyReports" }, "admin \(mode.rawValue) rows")
        }
    }

    // MARK: Weekly report PAYE overtime per multiplier (§7)

    func testPayeOvertimeRowsCarryTheMultiplierAndMarkAChangedRate() throws {
        let people: [[String: Any]] = [["id": "TEST-SAM", "name": "Sam", "employmentType": "paye"]]
        let rows = CanonicalBusinessEngine.weeklyReportPayeOvertime(
            people: people,
            bookings: [booking("B1", "2026-11-04", "06:30", "14:00"), booking("B2", "2026-11-05", "07:30", "18:00", rate: 2)],
            organization: org,
            range: ("2026-11-02", "2026-11-08")
        )
        XCTAssertEqual(rows.count, 2)
        let atOrganizationRate = try XCTUnwrap(rows.first)
        XCTAssertEqual(atOrganizationRate.multiplier, 1.5, accuracy: 0.0001)
        XCTAssertEqual(atOrganizationRate.clockHours, 1, accuracy: 0.0001)
        XCTAssertEqual(atOrganizationRate.overtimeHours, 1.5, accuracy: 0.0001)
        XCTAssertFalse(atOrganizationRate.changedFromOrganization)
        XCTAssertEqual(atOrganizationRate.multiplierText, "1h at ×1.5 = 1.5h")
        XCTAssertEqual(atOrganizationRate.label, "Sam · J-1042 · 1h at ×1.5 = 1.5h")

        let changed = try XCTUnwrap(rows.last)
        XCTAssertEqual(changed.multiplier, 2, accuracy: 0.0001)
        XCTAssertEqual(changed.organizationMultiplier, 1.5, accuracy: 0.0001)
        XCTAssertTrue(changed.changedFromOrganization)
        XCTAssertEqual(changed.multiplierText, "2h at ×2 = 4h")
        let mark = try XCTUnwrap(CanonicalBusinessEngine.overtimeRateChangedMark)
        XCTAssertEqual(mark, "changed from organisation rate")
        XCTAssertEqual(changed.label, "Sam · J-1042 · 2h at ×2 = 4h · \(mark) (×1.5)")
    }

    // MARK: Weekly report pay summary per viewer (§7, §8)

    private func payRow(_ index: Int, subject: [String: Any]?, pay: Double) -> [String: Any] {
        var row: [String: Any] = [
            "summaryIndex": index,
            "lines": [["rate": 100, "pay": pay, "payLabel": NSNull(), "isPaye": false] as [String: Any]],
            "personTotal": pay,
            "personTotalLabel": NSNull(),
        ]
        if let subject { row["paySubject"] = subject }
        return row
    }

    func testReportPayForViewerHidesPayTheViewerMayNotSee() throws {
        let rows = [payRow(0, subject: operative, pay: 200), payRow(1, subject: lineManager, pay: 300)]
        let shown = try XCTUnwrap(CanonicalBusinessEngine.reportPayForViewer(rows: rows, viewer: lineManager, roster: roster))
        let hiddenLabel = try XCTUnwrap(CanonicalBusinessEngine.payHiddenCellLabel)
        XCTAssertEqual(hiddenLabel, "—")
        XCTAssertEqual(shown.hiddenPeople, 1, "the weekly report is not a timesheet review: the report's pay is hidden")
        XCTAssertEqual(shown.grandTotal, 300, accuracy: 0.001, "the grand total covers the people shown only")
        let hidden = try XCTUnwrap(shown.rows.first { ($0["summaryIndex"] as? NSNumber)?.intValue == 0 })
        let hiddenLine = try XCTUnwrap((hidden["lines"] as? [[String: Any]])?.first)
        XCTAssertEqual(hiddenLine["rateText"] as? String, hiddenLabel)
        XCTAssertEqual(hiddenLine["payLabel"] as? String, hiddenLabel)
        XCTAssertEqual(hidden["personTotalLabel"] as? String, hiddenLabel)
        let own = try XCTUnwrap(shown.rows.first { ($0["summaryIndex"] as? NSNumber)?.intValue == 1 })
        XCTAssertNil((own["lines"] as? [[String: Any]])?.first?["rateText"] as? String)
        XCTAssertEqual(CanonicalBusinessEngine.payHiddenNote,
                       "Rates and pay are shown only for people whose pay you may see; the grand total covers those people only.")
    }

    func testReportPayForViewerShowsAdminsEveryRowIncludingOnesWithNoPerson() throws {
        let rows = [payRow(0, subject: operative, pay: 200), payRow(1, subject: nil, pay: 50)]
        let shown = try XCTUnwrap(CanonicalBusinessEngine.reportPayForViewer(rows: rows, viewer: admin, roster: roster))
        XCTAssertEqual(shown.hiddenPeople, 0)
        XCTAssertEqual(shown.grandTotal, 250, accuracy: 0.001)
        let operativesView = try XCTUnwrap(CanonicalBusinessEngine.reportPayForViewer(rows: rows, viewer: operativesManager, roster: roster))
        XCTAssertEqual(operativesView.hiddenPeople, 1, "a row with no known person is for admins only")
        XCTAssertEqual(operativesView.grandTotal, 200, accuracy: 0.001)
        let nobody = try XCTUnwrap(CanonicalBusinessEngine.reportPayForViewer(rows: rows, viewer: nil, roster: roster))
        XCTAssertEqual(nobody.hiddenPeople, 2)
        XCTAssertEqual(nobody.grandTotal, 0, accuracy: 0.001)
    }
}
