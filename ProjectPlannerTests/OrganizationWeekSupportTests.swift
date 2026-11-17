import XCTest
@testable import Project_Planner

/// Owner decision 17 Nov (guardrail 2, follow-up FU-4): the Scheduling week grid and the week screens use the
/// organisation's Monday–Sunday week and time zone (`organizationWeekDayKeys`), never the phone's
/// `Calendar.current` / `TimeZone.current`. Each test runs with the phone set to a zone far from the organisation's
/// (Europe/London): America/Los_Angeles (8 hours behind) and Pacific/Auckland (13 hours ahead).
@MainActor
final class OrganizationWeekSupportTests: XCTestCase {
    private let london = "Europe/London"
    private var savedDefaultZone: TimeZone!

    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    }

    private func source(_ path: String) throws -> String {
        try String(contentsOf: repoRoot.appendingPathComponent(path), encoding: .utf8)
    }

    override func setUp() async throws {
        savedDefaultZone = NSTimeZone.default
    }

    override func tearDown() async throws {
        NSTimeZone.default = savedDefaultZone
    }

    private func onPhonesIn(_ body: (String) throws -> Void) rethrows {
        for zone in ["America/Los_Angeles", "Pacific/Auckland"] {
            NSTimeZone.default = TimeZone(identifier: zone)!
            XCTAssertEqual(TimeZone.current.identifier, zone)
            try body(zone)
        }
    }

    private func instant(_ iso: String) -> Date {
        ISO8601DateFormatter().date(from: iso)!
    }

    private let novemberWeek = ["2026-11-16", "2026-11-17", "2026-11-18", "2026-11-19", "2026-11-20", "2026-11-21", "2026-11-22"]

    // MARK: The week and its columns

    /// Failure before: the grid's week came from a calendar, so a phone in Los Angeles or Auckland could start the week
    /// on the wrong day. Now the seven columns are the rulebook's day keys, Monday to Sunday, and each column is the
    /// organisation-zone midnight of its key.
    func testTheWeekIsTheOrganisationsMondayToSundayOnAnyPhone() {
        onPhonesIn { zone in
            let wednesday = instant("2026-11-18T12:00:00Z")
            XCTAssertEqual(OrganizationWeekSupport.weekDayKeys(containing: wednesday, timeZone: london), novemberWeek, zone)
            let columns = OrganizationWeekSupport.weekDays(containing: wednesday, timeZone: london)
            XCTAssertEqual(columns.map { OrganizationWeekSupport.dayKey($0, timeZone: london) }, novemberWeek, zone)
            // London is on GMT in November: Monday's column is 2026-11-16T00:00Z, not the phone's midnight.
            XCTAssertEqual(columns.first, instant("2026-11-16T00:00:00Z"), zone)
            XCTAssertEqual(OrganizationWeekSupport.weekStart(containing: wednesday, timeZone: london), instant("2026-11-16T00:00:00Z"), zone)
        }
    }

    /// Near midnight the phone's day differs from the organisation's: 23:30 on Sunday in London is Monday in Auckland
    /// and 15:30 on Sunday in Los Angeles. The grid follows London.
    func testNearMidnightTheGridFollowsTheOrganisationDay() {
        onPhonesIn { zone in
            let sundayLate = instant("2026-11-22T23:30:00Z")
            XCTAssertEqual(OrganizationWeekSupport.dayKey(sundayLate, timeZone: london), "2026-11-22", zone)
            XCTAssertEqual(OrganizationWeekSupport.weekDayKeys(containing: sundayLate, timeZone: london), novemberWeek, zone)
            let mondayEarly = instant("2026-11-23T00:30:00Z")
            XCTAssertEqual(OrganizationWeekSupport.dayKey(mondayEarly, timeZone: london), "2026-11-23", zone)
            XCTAssertEqual(OrganizationWeekSupport.weekDayKeys(containing: mondayEarly, timeZone: london).first, "2026-11-23", zone)
            XCTAssertTrue(OrganizationWeekSupport.isToday(instant("2026-11-22T00:00:00Z"), now: sundayLate, timeZone: london), zone)
            XCTAssertFalse(OrganizationWeekSupport.isToday(instant("2026-11-23T00:00:00Z"), now: sundayLate, timeZone: london), zone)
            XCTAssertTrue(OrganizationWeekSupport.isThisWeek(instant("2026-11-16T00:00:00Z"), now: sundayLate, timeZone: london), zone)
            XCTAssertFalse(OrganizationWeekSupport.isThisWeek(instant("2026-11-23T00:00:00Z"), now: sundayLate, timeZone: london), zone)
        }
    }

    /// The Swift day key every grid cell uses is the rulebook's `dayKeyInOrganizationZone`, on both sides of the clock
    /// changes, whatever the phone's zone.
    func testTheDayKeyIsTheRulebooksDayKeyInOrganizationZone() {
        let instants = [
            "2026-03-28T23:59:00Z", "2026-03-29T00:30:00Z", "2026-03-29T23:30:00Z", "2026-06-30T23:30:00Z",
            "2026-10-24T23:30:00Z", "2026-10-25T00:30:00Z", "2026-11-18T12:00:00Z", "2026-12-31T23:59:00Z",
        ].map(instant)
        onPhonesIn { zone in
            for date in instants {
                XCTAssertEqual(
                    OrganizationWeekSupport.dayKey(date, timeZone: london),
                    CanonicalBusinessEngine.dayKeyInOrganizationZone(date, timeZone: london),
                    "\(zone) \(date)"
                )
            }
        }
    }

    /// Week navigation moves by organisation weeks, across the March and October clock changes.
    func testWeekNavigationLandsOnTheOrganisationsMondays() {
        onPhonesIn { zone in
            let beforeSpringChange = instant("2026-03-25T12:00:00Z")
            let next = OrganizationWeekSupport.shiftedWeekStart(from: beforeSpringChange, by: 1, timeZone: london)
            XCTAssertEqual(OrganizationWeekSupport.dayKey(next, timeZone: london), "2026-03-30", zone)
            XCTAssertEqual(next, instant("2026-03-29T23:00:00Z"), zone) // London midnight on BST
            let back = OrganizationWeekSupport.shiftedWeekStart(from: next, by: -1, timeZone: london)
            XCTAssertEqual(OrganizationWeekSupport.dayKey(back, timeZone: london), "2026-03-23", zone)
            let autumn = OrganizationWeekSupport.shiftedWeekStart(from: instant("2026-10-21T12:00:00Z"), by: 1, timeZone: london)
            XCTAssertEqual(autumn, instant("2026-10-26T00:00:00Z"), zone)
            XCTAssertEqual(OrganizationWeekSupport.weekDays(containing: next, timeZone: london).count, 7, zone)
        }
    }

    /// "Days left" on a job and the past-end ring count organisation days.
    func testDaysFromTodayCountsOrganisationDays() {
        onPhonesIn { zone in
            let now = instant("2026-11-22T23:30:00Z") // Sunday 22 Nov in London
            XCTAssertEqual(OrganizationWeekSupport.daysFromToday(to: instant("2026-11-22T00:00:00Z"), now: now, timeZone: london), 0, zone)
            XCTAssertEqual(OrganizationWeekSupport.daysFromToday(to: instant("2026-11-23T00:00:00Z"), now: now, timeZone: london), 1, zone)
            XCTAssertEqual(OrganizationWeekSupport.daysFromToday(to: instant("2026-11-21T00:00:00Z"), now: now, timeZone: london), -1, zone)
            // Across the spring clock change: 28 Mar → 30 Mar is two days.
            XCTAssertEqual(OrganizationWeekSupport.daysFromToday(
                to: instant("2026-03-29T23:00:00Z"), now: instant("2026-03-28T12:00:00Z"), timeZone: london), 2, zone)
        }
    }

    /// Column and edit-sheet text is written in the organisation zone: Monday's column reads Monday on a phone in
    /// Los Angeles (where that instant is Sunday afternoon).
    func testDisplayTextIsWrittenInTheOrganisationZone() {
        onPhonesIn { zone in
            let monday = instant("2026-11-16T00:00:00Z")
            XCTAssertEqual(OrganizationWeekSupport.text(monday, format: "yyyy-MM-dd HH:mm", timeZone: london), "2026-11-16 00:00", zone)
            XCTAssertEqual(OrganizationWeekSupport.formatter("e", timeZone: london).timeZone.identifier, london, zone)
        }
    }

    /// A booking's clock block (My Schedule's clock text and the calendar export) is on its organisation day at its
    /// organisation-zone clock times, whatever the phone's zone.
    func testABookingsClockBlockIsInTheOrganisationZone() throws {
        let zone = OrganizationRulebookContext.timeZoneIdentifier
        let windows = try XCTUnwrap(CanonicalBusinessEngine.halfDayWindows(.init(policy: LogicFixtures.policy)))
        let mondayKey = "2026-11-16"
        let day = try XCTUnwrap(OrganizationWeekSupport.midnight(dayKey: mondayKey, timeZone: zone))
        onPhonesIn { phone in
            let booking = ManagerSiteBooking(userId: "TEST-user", date: day, timeSlot: .afternoon, locationType: .office)
            let block = booking.calendarBlock(on: day, policy: LogicFixtures.policy)
            XCTAssertEqual(OrganizationWeekSupport.dayKey(block.start, timeZone: zone), mondayKey, phone)
            let parts = OrganizationRulebookContext.calendar.dateComponents([.hour, .minute], from: block.start)
            XCTAssertEqual((parts.hour ?? 0) * 60 + (parts.minute ?? 0), windows.pm.start, phone)
        }
    }

    // MARK: Guardrail 7: no figure changes

    /// On a phone in the organisation's zone the grid's columns are exactly what they were before (the Monday-first
    /// organisation calendar), every day of a year with both clock changes: only phones elsewhere change.
    func testOnAPhoneInTheOrganisationZoneTheColumnsAreUnchanged() {
        NSTimeZone.default = TimeZone(identifier: london)!
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: london)!
        calendar.firstWeekday = 2
        calendar.minimumDaysInFirstWeek = 4
        var cursor = instant("2026-01-01T12:00:00Z")
        for _ in 0..<366 {
            let start = calendar.date(from: calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: cursor))!
            let before = (0..<7).compactMap { calendar.date(byAdding: .day, value: $0, to: start) }
            XCTAssertEqual(OrganizationWeekSupport.weekDays(containing: cursor, timeZone: london), before, "\(cursor)")
            cursor = calendar.date(byAdding: .day, value: 1, to: cursor)!
        }
    }

    // MARK: The screens call it

    func testTheSchedulingScreensUseTheOrganisationWeek() throws {
        let detail = try source("Project Planner/Views/ProjectDetailView.swift")
        XCTAssertTrue(detail.contains("OrganizationWeekSupport.weekStart(containing: selectedWeek)"))
        XCTAssertTrue(detail.contains("OrganizationWeekSupport.weekDays(containing: selectedWeek)"))
        XCTAssertTrue(detail.contains("OrganizationWeekSupport.shiftedWeekStart(from: selectedWeek, by: weeks)"))
        XCTAssertFalse(detail.contains("Calendar.current"))
        let schedule = try source("Project Planner/Views/MyScheduleView.swift")
        XCTAssertFalse(schedule.contains(".yearForWeekOfYear, .weekOfYear"))
        XCTAssertFalse(schedule.contains("byAdding: .weekOfYear"))
        XCTAssertFalse(schedule.contains("Calendar.current"))
        for path in [
            "Project Planner/Views/ScheduleOperativeView.swift",
            "Project Planner/Views/ScheduleSubcontractorView.swift",
            "Project Planner/Views/ScheduleQuickAddSheet.swift",
            "Project Planner/Views/WorksDashboardCard.swift",
            "Project Planner/Models/ManagerScheduleInterval.swift",
            "Project Planner/Models/OperativeBookingInterval.swift",
        ] {
            let text = try source(path)
            XCTAssertFalse(text.contains("Calendar.current"), path)
            XCTAssertFalse(text.contains("formatted(date: .abbreviated, time: .omitted)"), path)
            XCTAssertFalse(text.contains(".formatted(.dateTime"), path)
        }
    }
}
