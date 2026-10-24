import XCTest
@testable import Project_Planner

@MainActor
final class WarningScanCanonicalTests: XCTestCase {
    private let calendar = CanonicalBusinessEngine.businessCalendar

    func testEmptyOrganisationIdDoesNotDropTheCurrentBookingSnapshot() {
        let org = "2C67391E-D1FE-4F9F-8055-7149ACDE1F96"
        let other = "11111111-2222-3333-4444-555555555555"
        XCTAssertTrue(WarningsBookingScanScheduler.acceptsListener(
            listenerOrganizationId: org,
            currentOrganizationId: nil
        ))
        XCTAssertTrue(WarningsBookingScanScheduler.acceptsListener(
            listenerOrganizationId: org,
            currentOrganizationId: ""
        ))
        XCTAssertTrue(WarningsBookingScanScheduler.acceptsListener(
            listenerOrganizationId: "organizations/\(org)",
            currentOrganizationId: org.lowercased()
        ))
        XCTAssertFalse(WarningsBookingScanScheduler.acceptsListener(
            listenerOrganizationId: org,
            currentOrganizationId: other
        ))
        XCTAssertEqual(
            WarningsBookingScanScheduler.bookingCountAfterListener(
                existingCount: 150,
                incomingCount: 150,
                listenerOrganizationId: org,
                currentOrganizationId: nil
            ),
            150
        )
        XCTAssertEqual(
            WarningsBookingScanScheduler.bookingCountAfterListener(
                existingCount: 150,
                incomingCount: 0,
                listenerOrganizationId: org,
                currentOrganizationId: ""
            ),
            150
        )
        XCTAssertEqual(
            WarningsBookingScanScheduler.bookingCountAfterListener(
                existingCount: 150,
                incomingCount: 0,
                listenerOrganizationId: org,
                currentOrganizationId: other
            ),
            150
        )
        XCTAssertTrue(WarningsBookingScanScheduler.acceptsListener(
            listenerOrganizationId: org,
            currentOrganizationId: other,
            sessionOrganizationId: org
        ))
        XCTAssertFalse(WarningsBookingScanScheduler.acceptsListener(
            listenerOrganizationId: other,
            currentOrganizationId: other,
            sessionOrganizationId: org
        ))
        XCTAssertEqual(
            WarningsBookingScanScheduler.bookingCountAfterListener(
                existingCount: 0,
                incomingCount: 150,
                listenerOrganizationId: org,
                currentOrganizationId: other,
                sessionOrganizationId: org
            ),
            150
        )
        XCTAssertEqual(
            WarningsBookingScanScheduler.bookingCountAfterListener(
                existingCount: 150,
                incomingCount: 150,
                listenerOrganizationId: other,
                currentOrganizationId: other,
                sessionOrganizationId: org
            ),
            150
        )
    }

    func testStoredFullDaySpellingsLoadAsTheSameSlot() {
        XCTAssertEqual(TimeSlot.fromStored("FULL DAY"), .fullDay)
        XCTAssertEqual(TimeSlot.fromStored("FULL_DAY"), .fullDay)
        XCTAssertEqual(TimeSlot.fromStored("full day"), .fullDay)
        XCTAssertEqual(ManagerTimeSlot.fromStored("FULL DAY"), .fullDay)
        XCTAssertEqual(ManagerTimeSlot.fromStored("FULL_DAY"), .fullDay)
        XCTAssertNil(TimeSlot.fromStored(" "))
        XCTAssertNil(ManagerTimeSlot.fromStored("not-a-slot"))
    }

    func testSevenDayWindowIsTodayThroughSixDaysLater() throws {
        let monday = try day("2026-10-05")
        let window = try window(
            on: monday,
            mode: .numberOfDays,
            days: 7,
            ranges: Self.halfMonth
        )
        XCTAssertEqual(dayKey(window.start), "2026-10-05")
        XCTAssertEqual(dayKey(window.end), "2026-10-11")
    }

    func testWorkingWeekIsMondayToFriday() throws {
        let friday = try day("2026-10-09")
        let window = try window(
            on: friday,
            mode: .endOfWorkingWeek,
            days: 7,
            ranges: Self.halfMonth
        )
        XCTAssertEqual(dayKey(window.start), "2026-10-05")
        XCTAssertEqual(dayKey(window.end), "2026-10-09")
        let unbookedEnd = CanonicalBusinessEngine.unbookedLabourWindowEnd(
            coverageEnd: window.end,
            clashLookaheadMode: WarningClashLookaheadMode.endOfWorkingWeek.rawValue,
            includeWeekends: true
        )
        XCTAssertEqual(dayKey(unbookedEnd), "2026-10-11")
        let weekdaysOnly = CanonicalBusinessEngine.unbookedLabourWindowEnd(
            coverageEnd: window.end,
            clashLookaheadMode: WarningClashLookaheadMode.endOfWorkingWeek.rawValue,
            includeWeekends: false
        )
        XCTAssertEqual(dayKey(weekdaysOnly), "2026-10-09")
    }

    func testInvoicingPeriodKeepsHalfMonthAndCustomRuns() throws {
        let ninth = try day("2026-10-09")
        let twentieth = try day("2026-10-20")
        let half = try window(on: ninth, mode: .endOfInvoicingPeriod, days: 7, ranges: Self.halfMonth)
        XCTAssertEqual(dayKey(half.start), "2026-10-01")
        XCTAssertEqual(dayKey(half.end), "2026-10-15")
        let custom = try window(on: twentieth, mode: .endOfInvoicingPeriod, days: 7, ranges: Self.customMonth)
        XCTAssertEqual(dayKey(custom.start), "2026-10-17")
        XCTAssertEqual(dayKey(custom.end), "2026-10-31")
    }

    func testLeftoverWebEndDayDoesNotAddTheDayAfterTheSavedRun() throws {
        let sixth = try day("2026-10-06")
        let settings = FirebaseBackend.organizationSettingsFromOrgDocument([
            "warningDetection": ["clashLookaheadMode": "endOfInvoicingPeriod"],
            "invoicing": [
                "paymentRunMode": "date_ranges",
                "paymentRunDateRanges": [
                    ["startDay": 1, "endDay": 16, "startDate": 1, "endDate": 15],
                    ["startDay": 17, "endDay": 31, "startDate": 16, "endDate": 31],
                ],
            ],
        ])
        XCTAssertEqual(settings.invoicing.paymentRunDateRanges.map(\.startDay), [1, 16])
        XCTAssertEqual(settings.invoicing.paymentRunDateRanges.map(\.endDay), [15, 31])
        let window = CanonicalBusinessEngine.warningBounds(
            detection: settings.warningDetection,
            invoicing: settings.invoicing,
            reference: sixth
        )
        XCTAssertEqual(dayKey(window.start), "2026-10-01")
        XCTAssertEqual(dayKey(window.end), "2026-10-15")
    }

    func testLivePaymentRunsReplaceALeftoverSixteenDayWindow() throws {
        let saved = OrgWarningDetectionSettings(
            clashLookaheadMode: .endOfInvoicingPeriod,
            clashLookaheadDays: 12,
            excludedUserIdsFromUnbookedWarnings: ["admin-1"]
        )
        let kept = FirebaseBackend.detectionForWarningScan(current: saved, loaded: .default)
        XCTAssertEqual(kept.clashLookaheadMode, .endOfInvoicingPeriod)
        XCTAssertEqual(kept.clashLookaheadDays, 12)
        let replaced = FirebaseBackend.detectionForWarningScan(
            current: saved,
            loaded: OrgWarningDetectionSettings(clashLookaheadMode: .endOfWorkingWeek)
        )
        XCTAssertEqual(replaced.clashLookaheadMode, .endOfWorkingWeek)

        let live = FirebaseBackend.organizationSettingsFromOrgDocument([
            "invoicing": [
                "paymentRunMode": "date_ranges",
                "paymentRunDateRanges": [
                    ["startDay": 1, "endDay": 15],
                    ["startDay": 16, "endDay": 31],
                ],
            ],
        ])
        let ninth = try day("2026-10-09")
        let window = CanonicalBusinessEngine.warningBounds(
            detection: kept,
            invoicing: live.invoicing,
            reference: ninth
        )
        XCTAssertEqual(dayKey(window.end), "2026-10-15")

        let sixteenth = try day("2026-10-16")
        let stale = Warning(
            resolutionKey: "unbooked-2026-10-16",
            type: .unbookedLabour,
            title: "Unbooked labour",
            message: "Sam is missing 8h on 16 October.",
            severity: .high,
            occurrenceDate: sixteenth,
            operativeClash: nil,
            managerClash: nil,
            unbookedLabour: nil,
            annualLeave: nil,
            materialsCutoff: nil,
            bookingClashDetails: nil,
            operativeEmail: nil
        )
        let keptRow = Warning(
            resolutionKey: "qual-1",
            type: .qualificationExpiry,
            title: "Qualification expiry",
            message: "Card expired",
            severity: .low,
            occurrenceDate: sixteenth,
            operativeClash: nil,
            managerClash: nil,
            unbookedLabour: nil,
            annualLeave: nil,
            materialsCutoff: nil,
            bookingClashDetails: nil,
            operativeEmail: nil
        )
        let visible = WarningsService.warningsInsideCoverageWindow(
            [stale, keptRow],
            start: window.start,
            end: window.end,
            unbookedEnd: window.end
        )
        XCTAssertEqual(visible.map(\.resolutionKey), ["qual-1"])
    }

    func testASavedSixteenDayRunKeepsTheSixteenth() throws {
        let sixth = try day("2026-10-06")
        let settings = FirebaseBackend.organizationSettingsFromOrgDocument([
            "invoicing": [
                "paymentRunMode": "date_ranges",
                "paymentRunDateRanges": [
                    ["startDay": 1, "endDay": 16],
                    ["startDay": 17, "endDay": 31],
                ],
            ],
        ])
        let window = CanonicalBusinessEngine.warningBounds(
            detection: OrgWarningDetectionSettings(clashLookaheadMode: .endOfInvoicingPeriod),
            invoicing: settings.invoicing,
            reference: sixth
        )
        XCTAssertEqual(dayKey(window.start), "2026-10-01")
        XCTAssertEqual(dayKey(window.end), "2026-10-16")
    }

    func testFullDayCoveringTheStandardDayIsNotUnbooked() throws {
        let fifteenth = try day("2026-10-15")
        let operativeId = UUID()
        let snapshot = WarningsComputationSnapshot(
            operatives: [
                .init(
                    id: operativeId,
                    name: "Sam Booked",
                    emailLowercased: "sam@site.test",
                    isActive: true,
                    qualificationExpiries: []
                )
            ],
            bookings: [
                .init(
                    id: UUID(),
                    operativeId: operativeId,
                    projectId: UUID(),
                    date: fifteenth,
                    dayStart: fifteenth,
                    isActiveStatus: true,
                    paidHours: 8,
                    scheduleLabel: "Site",
                    clashInterval: nil,
                    timeSlot: "FULL DAY",
                    workStart: "09:00",
                    workEnd: "10:00"
                )
            ],
            projects: [],
            users: [
                .init(
                    id: "U-SAM",
                    emailLowercased: "sam@site.test",
                    displayName: "Sam Booked",
                    isActive: true,
                    passwordSet: true,
                    createdAt: fifteenth,
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
            coverageStart: fifteenth,
            coverageEnd: fifteenth,
            materialOrderCutOffEnabled: false,
            materialCutOffOnSaturday: false,
            materialCutOffOnSunday: false,
            projectsWithTomorrowBookingIds: [],
            materialItemsForTomorrow: []
        )
        let unbooked = WarningsComputation.generate(snapshot).filter { $0.type == .unbookedLabour }
        XCTAssertEqual(unbooked, [])

        let rows = CanonicalBusinessEngine.objectRows(
            function: "unbookedLabourRows",
            payload: [
                "timeZone": "Europe/London",
                "startDayKey": "2026-10-15",
                "endDayKey": "2026-10-16",
                "includeWeekends": false,
                "standardPaidHours": 8,
                "standardDayStart": "07:30",
                "standardDayEnd": "16:00",
                "breakWindowStart": "12:00",
                "breakWindowEnd": "12:30",
                "people": [[
                    "id": "U-SAM",
                    "email": "sam@site.test",
                    "name": "Sam Booked",
                    "isActive": true,
                    "passwordSet": true,
                    "isOperativeMode": true,
                ]],
                "operatives": [[
                    "id": operativeId.uuidString,
                    "email": "sam@site.test",
                    "name": "Sam Booked",
                    "isActive": true,
                ]],
                "bookings": [[
                    "personId": "U-SAM",
                    "dayKey": "2026-10-15",
                    "kind": "operative",
                    "timeSlot": "FULL_DAY",
                    "workStart": "",
                    "workEnd": "",
                ]],
                "holidays": [] as [[String: Any]],
            ]
        )
        let fifteenthRows = rows?.filter { ($0["dayKey"] as? String) == "2026-10-15" }
        XCTAssertEqual(fifteenthRows?.count, 0)
    }

    func testStartDateEndDateDocumentKeepsThoseDays() {
        let settings = FirebaseBackend.organizationSettingsFromOrgDocument([
            "invoicing": [
                "paymentRunMode": "date_ranges",
                "paymentRunDateRanges": [
                    ["startDate": 1, "endDate": 16],
                    ["startDate": 17, "endDate": 31],
                ],
            ],
        ])
        XCTAssertEqual(settings.invoicing.paymentRunDateRanges.map(\.startDay), [1, 17])
        XCTAssertEqual(settings.invoicing.paymentRunDateRanges.map(\.endDay), [16, 31])
    }

    func testMissingEndDayDoesNotBecomeTheNextDay() {
        let settings = FirebaseBackend.organizationSettingsFromOrgDocument([
            "invoicing": [
                "paymentRunDateRanges": [
                    ["startDay": 1],
                    ["startDay": 16, "endDay": 31],
                ],
            ],
        ])
        XCTAssertEqual(settings.invoicing.paymentRunDateRanges.map(\.startDay), [16])
        XCTAssertEqual(settings.invoicing.paymentRunDateRanges.map(\.endDay), [31])
    }

    func testMissingRangesStayHalfMonth() {
        let settings = FirebaseBackend.organizationSettingsFromOrgDocument([
            "invoicing": ["paymentRunMode": "date_ranges"],
        ])
        XCTAssertEqual(settings.invoicing.paymentRunDateRanges.map(\.startDay), [1, 16])
        XCTAssertEqual(settings.invoicing.paymentRunDateRanges.map(\.endDay), [15, 31])
    }

    func testUnbookedLabourRowsOnDayMatchesThatLondonDay() throws {
        let people = [
            CanonicalUnbookedLabourPerson(
                id: "U-SAM",
                email: "sam@site.test",
                name: "Sam Site",
                isActive: true,
                passwordSet: true,
                isOperativeMode: true,
                isManager: false,
                isAdmin: false,
                isSuperAdmin: false
            ),
            CanonicalUnbookedLabourPerson(
                id: "U-EX",
                email: "ex@site.test",
                name: "Excluded User",
                isActive: true,
                passwordSet: true,
                isOperativeMode: true,
                isManager: false,
                isAdmin: false,
                isSuperAdmin: false
            ),
        ]
        func dayInput(dayKey: String, includeWeekends: Bool, excluded: [String]) -> CanonicalUnbookedLabourDayInput {
            CanonicalUnbookedLabourDayInput(
                timeZone: "Europe/London",
                dayKey: dayKey,
                includeWeekends: includeWeekends,
                excludedUserIds: excluded,
                standardPaidHours: 8,
                saturdayCountsAsHours: 8,
                sundayCountsAsHours: 8,
                standardDayStart: "07:30",
                standardDayEnd: "16:00",
                breakWindowStart: "12:00",
                breakWindowEnd: "12:30",
                people: people,
                operatives: [],
                bookings: [],
                holidays: []
            )
        }
        let range = CanonicalUnbookedLabourInput(
            timeZone: "Europe/London",
            startDayKey: "2026-10-16",
            endDayKey: "2026-10-18",
            includeWeekends: true,
            excludedUserIds: [],
            standardPaidHours: 8,
            saturdayCountsAsHours: 8,
            sundayCountsAsHours: 8,
            standardDayStart: "07:30",
            standardDayEnd: "16:00",
            breakWindowStart: "12:00",
            breakWindowEnd: "12:30",
            people: people,
            operatives: [],
            bookings: [],
            holidays: []
        )
        let rows = try XCTUnwrap(CanonicalBusinessEngine.unbookedLabourRows(range))
        for dayKey in ["2026-10-17", "2026-10-18"] {
            let onDay = try XCTUnwrap(CanonicalBusinessEngine.unbookedLabourRowsOnDay(
                dayInput(dayKey: dayKey, includeWeekends: true, excluded: [])
            ))
            let filtered = rows.filter { $0.dayKey == dayKey }
            XCTAssertEqual(onDay.map(\.personKey), filtered.map(\.personKey))
            XCTAssertEqual(onDay.map(\.id), filtered.map(\.id))
            XCTAssertFalse(onDay.isEmpty)
        }

        let saturdayOff = try XCTUnwrap(CanonicalBusinessEngine.unbookedLabourRowsOnDay(
            dayInput(dayKey: "2026-10-17", includeWeekends: false, excluded: [])
        ))
        let sundayOff = try XCTUnwrap(CanonicalBusinessEngine.unbookedLabourRowsOnDay(
            dayInput(dayKey: "2026-10-18", includeWeekends: false, excluded: [])
        ))
        XCTAssertEqual(saturdayOff.map(\.personKey), [])
        XCTAssertEqual(sundayOff.map(\.personKey), [])

        let excludedSaturday = try XCTUnwrap(CanonicalBusinessEngine.unbookedLabourRowsOnDay(
            dayInput(dayKey: "2026-10-17", includeWeekends: true, excluded: ["U-EX"])
        ))
        XCTAssertEqual(excludedSaturday.map(\.personKey), ["U-SAM"])
        XCTAssertNil(excludedSaturday.first { $0.personKey == "U-EX" || $0.userId == "U-EX" })
    }

    func testOperativeModeHidesStaffWarnings() {
        let operative = CanonicalBusinessEngine.CanonicalStaffAccountRole(
            isSuperAdmin: false,
            isAdmin: true,
            isManager: true,
            isOperativeMode: true
        )
        XCTAssertFalse(CanonicalBusinessEngine.canViewStaffWarnings(operative))
        XCTAssertFalse(CanonicalBusinessEngine.isStaffAccount(operative))
        XCTAssertFalse(CanonicalBusinessEngine.seesEveryJob(operative))

        let manager = CanonicalBusinessEngine.CanonicalStaffAccountRole(
            isSuperAdmin: false,
            isAdmin: false,
            isManager: true,
            isOperativeMode: false
        )
        XCTAssertTrue(CanonicalBusinessEngine.canViewStaffWarnings(manager))
        XCTAssertTrue(CanonicalBusinessEngine.seesEveryJob(manager))

        let admin = CanonicalBusinessEngine.CanonicalStaffAccountRole(
            isSuperAdmin: false,
            isAdmin: true,
            isManager: false,
            isOperativeMode: false
        )
        XCTAssertTrue(CanonicalBusinessEngine.canViewStaffWarnings(admin))
    }

    private func window(
        on reference: Date,
        mode: WarningClashLookaheadMode,
        days: Int,
        ranges: [PaymentRunDateRange]
    ) throws -> (start: Date, end: Date) {
        var invoicing = OrganizationInvoicingSettings.default
        invoicing.paymentRunMode = .dateRanges
        invoicing.paymentRunDateRanges = ranges
        let detection = OrgWarningDetectionSettings(
            clashLookaheadMode: mode,
            clashLookaheadDays: days
        )
        return CanonicalBusinessEngine.warningBounds(
            detection: detection,
            invoicing: invoicing,
            reference: reference
        )
    }

    private func day(_ key: String) throws -> Date {
        try XCTUnwrap(CanonicalBusinessEngine.date(fromDayKey: key, calendar: calendar))
    }

    private func dayKey(_ date: Date) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    private static let halfMonth = [
        PaymentRunDateRange(startDay: 1, endDay: 15),
        PaymentRunDateRange(startDay: 16, endDay: 31),
    ]

    private static let customMonth = [
        PaymentRunDateRange(startDay: 1, endDay: 16),
        PaymentRunDateRange(startDay: 17, endDay: 31),
    ]
}
