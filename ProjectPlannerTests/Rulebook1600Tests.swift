import XCTest
@testable import Project_Planner

/// RULEBOOK 1.60.0 (owner report and request 17 Nov 2026). Web locks the same rules in `lib/canonical/canonical.test.ts`
/// (`multiPersonBookingBlocks`), `lib/book-labour/candidates.test.ts` (leave cover in Book labour) and
/// `lib/daily-overview/leaveCover.test.ts`.
@MainActor
final class Rulebook1600Tests: XCTestCase {
    nonisolated override func setUp() {
        super.setUp()
        JobAccessContext.updateViewer(nil)
    }

    private let dayKey = "2026-11-23" // a Monday
    private var day: Date { CanonicalBusinessEngine.date(fromDayKey: dayKey)! }

    private var admin: AppUser {
        AppUser(
            id: "TEST-ADMIN",
            email: "test.admin@site.test",
            organizationId: "org-test",
            role: .admin,
            firstName: "Test",
            surname: "Admin",
            isActive: true,
            passwordSet: true,
            permissions: UserPermissions(adminAccess: true)
        )
    }

    private func amLeave(status: String = "approved") -> [HolidayBooking] {
        FirebaseBackend.holidayBookings(fromDocuments: [(id: "leave-am", data: [
            "userId": "TEST-ADMIN",
            "startDate": dayKey,
            "endDate": dayKey,
            "status": status,
            "timeSlot": "AM",
        ])], organizationId: "org-test")
    }

    // MARK: - Half-day unbooked (Book labour, Daily Overview)

    func testHalfDayLeaveNotCoveredIsListedForTheDayWithTheGap() throws {
        let rows = WarningsComputation.leaveCoverRowsOnDay(
            day: day,
            users: [admin],
            operatives: [],
            operativeBookings: [],
            managerBookings: [],
            holidays: amLeave(),
            policy: .default,
            warningDetection: .default
        )
        XCTAssertEqual(rows.count, 1, "the owner's case: AM leave, nothing booked for the PM")
        let detail = try XCTUnwrap(rows.first?.annualLeave)
        XCTAssertEqual(detail.kind, "leave_cover")
        XCTAssertEqual(detail.userId, "TEST-ADMIN")
        XCTAssertEqual(detail.dayKey, dayKey)
        XCTAssertEqual(detail.leaveLabel, "AM")
        XCTAssertEqual(detail.workingLabel, "PM")
        // Default working day 07:30–16:00, lunch 12:00–12:30: the PM half is 11:45–16:00 (`leaveCoverBookingWindow`).
        XCTAssertEqual(detail.gapStart, "11:45")
        XCTAssertEqual(detail.gapEnd, "16:00")
        XCTAssertEqual(detail.missingHours, 3.75, accuracy: 0.001)
    }

    /// Review of #373: already booked 13:00–14:00, the prefill stops at that booking (never 11:45–16:00, a clash).
    func testThePrefillNeverRunsAcrossAnExistingBooking() throws {
        let booked = ManagerSiteBooking(
            userId: "TEST-ADMIN",
            date: day,
            timeSlot: .customHours,
            locationType: .office,
            locationId: nil,
            workStartTime: "13:00",
            workEndTime: "14:00"
        )
        let rows = WarningsComputation.leaveCoverRowsOnDay(
            day: day,
            users: [admin],
            operatives: [],
            operativeBookings: [],
            managerBookings: [booked],
            holidays: amLeave(),
            policy: .default,
            warningDetection: .default
        )
        let detail = try XCTUnwrap(rows.first?.annualLeave)
        XCTAssertEqual(detail.gapStart, "11:45")
        XCTAssertEqual(detail.gapEnd, "13:00")
        XCTAssertEqual(detail.missingHours, 2.75, accuracy: 0.001)
    }

    func testAPendingRequestIsNotLeaveCover() {
        let rows = WarningsComputation.leaveCoverRowsOnDay(
            day: day,
            users: [admin],
            operatives: [],
            operativeBookings: [],
            managerBookings: [],
            holidays: amLeave(status: "pending"),
            policy: .default,
            warningDetection: .default
        )
        XCTAssertTrue(rows.isEmpty)
    }

    func testOlderCachedLeaveWarningsStillDecode() throws {
        let json = #"{"kind":"leave_cover","personName":"Ada","missingRanges":["12:30–16:00"],"missingHours":3.5}"#
        let detail = try JSONDecoder().decode(Warning.AnnualLeaveWarningDetails.self, from: Data(json.utf8))
        XCTAssertNil(detail.userId)
        XCTAssertNil(detail.gapStart)
        XCTAssertEqual(detail.workingLabel, "PM")
    }

    // MARK: - More than one person, someone already booked

    func testMultiPersonBlocksNameTheBookedPersonAndDay() throws {
        let blocks = try XCTUnwrap(CanonicalBusinessEngine.multiPersonBookingBlocks(
            people: [
                .init(personKey: "A", name: "Ada", ids: ["U-ADA", "OP-ADA"]),
                .init(personKey: "B", name: "Ben", ids: ["U-BEN"]),
            ],
            dayKeys: [dayKey],
            bookings: [
                .init(id: "b1", personId: "op-ada", dayKey: dayKey, status: "Confirmed"),
                .init(id: "b2", personId: "U-BEN", dayKey: dayKey, status: "Cancelled"),
            ]
        ), "the packed script did not run")
        XCTAssertEqual(blocks.map(\.personKey), ["A"])
        XCTAssertEqual(blocks.first?.dayKeys, [dayKey])
        XCTAssertEqual(blocks.first?.message, CanonicalBusinessEngine.multiPersonAlreadyBookedMessage)
        XCTAssertTrue(CanonicalBusinessEngine.multiPersonAlreadyBookedMessage.hasPrefix("This user already has hours booked for this day."))
        XCTAssertEqual(CanonicalBusinessEngine.multiPersonAlreadyBookedRemoveLabel, "Remove")
    }

    func testAManagerSiteBookingWithNoStatusCountsAndOnePersonIsNeverBlocked() throws {
        let manager = RulebookMultiPersonBooking(id: "m1", personId: "U-BEN", dayKey: dayKey, status: nil)
        let blocks = try XCTUnwrap(CanonicalBusinessEngine.multiPersonBookingBlocks(
            people: [.init(personKey: "A", name: "Ada", ids: ["U-ADA"]), .init(personKey: "B", name: "Ben", ids: ["U-BEN"])],
            dayKeys: [dayKey],
            bookings: [manager]
        ))
        XCTAssertEqual(blocks.map(\.personKey), ["B"])
        let single = CanonicalBusinessEngine.multiPersonBookingBlocks(
            people: [.init(personKey: "B", name: "Ben", ids: ["U-BEN"])],
            dayKeys: [dayKey],
            bookings: [manager]
        )
        XCTAssertEqual(single, [])
        let edited = CanonicalBusinessEngine.multiPersonBookingBlocks(
            people: [.init(personKey: "A", name: "Ada", ids: ["U-ADA"]), .init(personKey: "B", name: "Ben", ids: ["U-BEN"])],
            dayKeys: [dayKey],
            bookings: [manager],
            ignoreBookingIds: ["M1"]
        )
        XCTAssertEqual(edited, [])
    }

    func testAccountIdsAreTheRulebooksPersonIds() {
        var account = admin
        account.formerUserIds = ["OLD-INVITE-ID"]
        let row = Operative(id: UUID(), firstName: "Test", lastName: "Admin", email: "TEST.ADMIN@site.test", startDate: Date(timeIntervalSince1970: 0))
        let ids = MultiPersonBookingCheck.ids(forUserId: "TEST-ADMIN", users: [account], operatives: [row])
        XCTAssertTrue(ids.contains("TEST-ADMIN"))
        XCTAssertTrue(ids.contains("OLD-INVITE-ID"), "formerUserIds (personIdSet)")
        XCTAssertTrue(ids.contains { $0.caseInsensitiveCompare(row.documentId) == .orderedSame }, "operatives row on the email")
    }

    /// The Scheduling wizard / Select Operatives check: two people selected, one already booked that day.
    func testTheSchedulingWizardNamesThePersonAlreadyBooked() throws {
        let opA = UUID()
        let opB = UUID()
        let people = [
            ScheduleBookablePerson(operativeId: opA, userId: nil, name: "Ada", email: "", roleLabel: "Operative", tradeLabel: "", hasPastBookingOnProject: false),
            ScheduleBookablePerson(operativeId: opB, userId: nil, name: "Ben", email: "", roleLabel: "Operative", tradeLabel: "", hasPastBookingOnProject: false),
        ]
        let existing = Booking(operativeId: opB, projectId: UUID(), date: day, timeSlot: .fullDay, bookedBy: "TEST")
        let blocks = try XCTUnwrap(MultiPersonBookingCheck.scheduleBlocks(
            people: people,
            selected: [opA, opB],
            dates: [day],
            operativeBookings: [existing],
            managerBookings: [],
            users: [],
            operatives: [],
            excludingBookingIds: []
        ))
        XCTAssertEqual(blocks.map(\.name), ["Ben"])
        XCTAssertEqual(blocks.first?.dayKeys, [dayKey])
        // One person selected keeps the ✓ / ✕ / Replace rows: no block.
        XCTAssertEqual(MultiPersonBookingCheck.scheduleBlocks(
            people: people,
            selected: [opB],
            dates: [day],
            operativeBookings: [existing],
            managerBookings: [],
            users: [],
            operatives: [],
            excludingBookingIds: []
        ), [])
        // The booking being edited never blocks.
        XCTAssertEqual(MultiPersonBookingCheck.scheduleBlocks(
            people: people,
            selected: [opA, opB],
            dates: [day],
            operativeBookings: [existing],
            managerBookings: [],
            users: [],
            operatives: [],
            excludingBookingIds: [existing.id]
        ), [])
    }
}
