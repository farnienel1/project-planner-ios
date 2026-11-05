import XCTest
@testable import Project_Planner

/// RULEBOOK 1.32.0 booking screens on iOS (`Rulebook+BookingOvertimeRate.swift`): Office / Working from home / Site
/// survey / custom items follow `canBookOtherLocationsFor` (§2), the rate at create is pre-filled with the
/// organisation's and stored only when changed (`overtimeRateCreateControl`, `overtimeMultiplierCreateFields`, §25
/// decision A), the Daily Overview booking sheet keeps the rate on every save (`overtimeMultiplierMoveFields`), and a
/// manager site booking's stored rate reaches `bookingHoursLabel`. Same cases as web `canonical.test.ts`.
@MainActor
final class Rulebook1320BookingTests: XCTestCase {
    private let org: [String: Any] = [
        "countryCode": "GB",
        "payrollTimePolicy": [
            "standardDayStart": "07:30",
            "standardDayEnd": "16:00",
            "unpaidBreakMinutes": 30,
            "breakWindowStart": "12:00",
            "breakWindowEnd": "12:30",
            "weekdayOutsideStandardMultiplier": 1.5,
            "sunday": ["allHoursAtMultiplierMode": true, "allHoursMultiplier": 2, "sameAsSaturday": false] as [String: Any],
        ] as [String: Any],
    ]

    override func setUp() {
        super.setUp()
        OrganizationRulebookContext.update(from: Organization(firestoreDocumentId: "TEST-ORG-132", name: "TEST-Company 132"))
    }

    override func tearDown() {
        OrganizationRulebookContext.update(from: nil)
        super.tearDown()
    }

    private func viewer(admin: Bool = false, manager: Bool = false, operative: Bool = false) -> JobAccessViewer {
        JobAccessViewer(
            role: CanonicalBusinessEngine.CanonicalStaffAccountRole(
                isSuperAdmin: false, isAdmin: admin, isManager: manager, isOperativeMode: operative
            ),
            projectsToggle: true,
            smallWorksToggle: true,
            uid: "TEST-m1",
            ids: ["TEST-m1", "TEST-m1-old"],
            email: "test-m1@example.test"
        )
    }

    private func orgDay(_ year: Int, _ month: Int, _ day: Int) throws -> Date {
        try XCTUnwrap(OrganizationRulebookContext.calendar.date(from: DateComponents(year: year, month: month, day: day)))
    }

    // MARK: §2 canBookOtherLocationsFor

    func testOtherLocationsOnlyForOneselfUnlessAdmin() {
        let manager = viewer(manager: true)
        XCTAssertTrue(CanonicalBusinessEngine.canBookOtherLocationsFor(manager, personUserIds: ["TEST-m1"]))
        XCTAssertTrue(CanonicalBusinessEngine.canBookOtherLocationsFor(manager, personUserIds: ["TEST-m1-old"]))
        XCTAssertFalse(CanonicalBusinessEngine.canBookOtherLocationsFor(manager, personUserIds: ["TEST-m1", "TEST-report"]))
        XCTAssertTrue(CanonicalBusinessEngine.canBookOtherLocationsFor(viewer(admin: true), personUserIds: ["TEST-anyone", "TEST-else"]))
        XCTAssertFalse(CanonicalBusinessEngine.canBookOtherLocationsFor(viewer(operative: true), personUserIds: ["TEST-m1"]))
        XCTAssertFalse(CanonicalBusinessEngine.canBookOtherLocationsFor(manager, personUserIds: []))
        XCTAssertFalse(CanonicalBusinessEngine.canBookOtherLocationsFor(nil, personUserIds: ["TEST-m1"]))
    }

    // MARK: §25 overtimeRateCreateControl / overtimeMultiplierCreateFields

    func testCreateControlIsPrefilledWithTheOrganisationRateForTheDay() throws {
        let weekday = try XCTUnwrap(CanonicalBusinessEngine.overtimeRateCreateControl(dayKey: "2026-11-04", organization: org))
        XCTAssertEqual(weekday.organizationMultiplier, 1.5)
        XCTAssertEqual(weekday.prefill, 1.5)
        XCTAssertEqual(weekday.options.filter(\.organization).map(\.value), [1.5])
        XCTAssertEqual(weekday.options.first { $0.organization }?.label, "×1.5 (organisation rate)")
        XCTAssertEqual(weekday.options.map(\.value), [1, 1.25, 1.5, 1.75, 2, 2.25, 2.5, 2.75, 3])

        let sunday = try XCTUnwrap(CanonicalBusinessEngine.overtimeRateCreateControl(dayKey: "2026-11-08", organization: org))
        XCTAssertEqual(sunday.prefill, 2, "Sunday every hour ×2")
    }

    func testCreateFieldsStoreTheRateOnlyWhenChanged() {
        XCTAssertNil(CanonicalBusinessEngine.overtimeMultiplierCreateFields(chosen: 1.5, organizationMultiplier: 1.5))
        XCTAssertEqual(CanonicalBusinessEngine.overtimeMultiplierCreateFields(chosen: 2, organizationMultiplier: 1.5), 2)
        XCTAssertNil(CanonicalBusinessEngine.overtimeMultiplierCreateFields(chosen: 3.1, organizationMultiplier: 1.5))
        XCTAssertNil(CanonicalBusinessEngine.overtimeMultiplierCreateFields(chosen: nil, organizationMultiplier: 1.5))
    }

    /// Each booked day is compared with its own organisation rate (the open organisation's document).
    func testCreateOverrideComparesWithThatDaysOrganisationRate() throws {
        let day = try orgDay(2026, 11, 4)
        let control = try XCTUnwrap(CanonicalBusinessEngine.overtimeRateCreateControl(on: day))
        XCTAssertNil(CanonicalBusinessEngine.createOtMultiplierOverride(chosen: nil, on: day), "left at the organisation's")
        XCTAssertNil(CanonicalBusinessEngine.createOtMultiplierOverride(chosen: control.organizationMultiplier, on: day))
        let other = try XCTUnwrap(control.options.first { !$0.organization }?.value)
        XCTAssertEqual(CanonicalBusinessEngine.createOtMultiplierOverride(chosen: other, on: day), other)
    }

    // MARK: §25 overtimeMultiplierMoveFields (Daily Overview booking sheet)

    func testMoveFieldsKeepTheRateOnEverySave() {
        func move(_ stored: Double?, _ chosen: Double?, shown: Bool = true, newDocument: Bool = false) -> OvertimeMultiplierFieldWrite? {
            CanonicalBusinessEngine.overtimeMultiplierMoveFields(
                stored: stored, chosen: chosen, rateShown: shown, organizationMultiplier: 1.5, newDocument: newDocument
            )
        }
        XCTAssertEqual(move(2, 2), .keep)
        XCTAssertEqual(move(2, 2.5), .set(2.5))
        XCTAssertEqual(move(2, nil), .remove, "back to the organisation's rate")
        XCTAssertEqual(move(2, 1.5), .remove, "equal to the organisation's: removed, never stored")
        XCTAssertEqual(move(2, nil, shown: false), .keep, "rate not on screen: the stored one stays")
        XCTAssertEqual(move(2, nil, shown: false, newDocument: true), .set(2), "a move to a new document carries it")
        XCTAssertEqual(move(nil, nil, newDocument: true), .keep)
        XCTAssertEqual(OvertimeMultiplierFieldWrite.keep.applied(to: 2), 2)
        XCTAssertNil(OvertimeMultiplierFieldWrite.remove.applied(to: 2))
    }

    func testSavedOverrideKeepsAStoredRateWhenTheRateIsNotShown() throws {
        let day = try orgDay(2026, 11, 4)
        XCTAssertEqual(CanonicalBusinessEngine.savedOtMultiplierOverride(stored: 2.5, chosen: nil, rateShown: false, on: day), 2.5)
        XCTAssertEqual(CanonicalBusinessEngine.savedOtMultiplierOverride(stored: 2.5, chosen: 2.5, rateShown: true, on: day), 2.5)
        XCTAssertNil(CanonicalBusinessEngine.savedOtMultiplierOverride(stored: 2.5, chosen: nil, rateShown: true, on: day))
    }

    // MARK: managers' own site bookings (owner decision 4 Nov)

    /// A manager site booking's stored rate goes to `payrollHoursResult` → `bookingHoursLabel` like a labour booking's
    /// (Scheduling, Daily Overview and My Schedule read `ManagerSiteBooking.payrollHoursResult`).
    func testManagerSiteBookingLabelUsesItsStoredRate() throws {
        let day = try orgDay(2026, 11, 4)
        func booking(_ rate: Double?) -> ManagerSiteBooking {
            ManagerSiteBooking(
                userId: "TEST-m1",
                date: day,
                timeSlot: .customHours,
                locationType: .office,
                workStartTime: "05:30",
                workEndTime: "18:00",
                otMultiplierOverride: rate
            )
        }
        let stored = booking(3)
        XCTAssertEqual(stored.otMultiplierOverride, 3)
        XCTAssertEqual(stored.operativePayrollProbe().otMultiplierOverride, 3)
        let policy = OrgPayrollTimePolicy.default
        let withRate = stored.payrollHoursResult(policy: policy)
        let organisation = booking(nil).payrollHoursResult(policy: policy)
        XCTAssertEqual(withRate.outsideMultiplier, 3)
        XCTAssertNotEqual(withRate.paidHoursLabel, organisation.paidHoursLabel)
        XCTAssertGreaterThan(withRate.totalPaidHours, organisation.totalPaidHours)
    }
}
