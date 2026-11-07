import XCTest
@testable import Project_Planner

/// iOS-only fixes of the 1.36 clean-up release. Each test names the failure it locks out.
@MainActor
final class IOS136FixesTests: XCTestCase {
    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    }

    private func source(_ path: String) throws -> String {
        try String(contentsOf: repoRoot.appendingPathComponent(path), encoding: .utf8)
    }

    /// The text of `func <name>` up to the next `func ` at the same file (good enough for a guard on one function).
    private func functionBody(_ name: String, in text: String) throws -> String {
        let start = try XCTUnwrap(text.range(of: "func \(name)("), "func \(name) not found")
        let rest = text[start.upperBound...]
        let end = rest.range(of: "\n    func ")?.lowerBound
            ?? rest.range(of: "\n    private func ")?.lowerBound
            ?? rest.endIndex
        return String(rest[..<end])
    }

    override func setUp() async throws {
        OfflineOutboxStore.shared.clearAll()
    }

    override func tearDown() async throws {
        OfflineOutboxStore.shared.clearAll()
    }

    // MARK: 1. Overtime reopen notice on every booking edit path (RULEBOOK 1.33.0 §25)

    /// Failure before: an edit made offline was queued without the copy it changed, so when it replayed nobody was told
    /// their overtime line had reopened (web always tells them after its write).
    func testAQueuedEditKeepsTheCopyBeforeTheFirstEditForTheReopenNotice() throws {
        let outbox = OfflineOutboxStore.shared
        let synced = LogicFixtures.booking(on: Date(), slot: .customHours, start: "07:30", end: "18:00")
        var first = synced
        first.workEndTime = "17:00"
        var second = first
        second.workEndTime = "16:30"
        outbox.enqueueSaveBooking(first, changedFields: ["workEndTime"], organizationId: "TEST-ORG", previous: synced)
        outbox.enqueueSaveBooking(second, changedFields: ["workEndTime"], organizationId: "TEST-ORG", previous: first)
        XCTAssertEqual(outbox.entries.count, 1)
        let payload = try JSONDecoder().decode(OfflineSaveBookingPayload.self, from: try XCTUnwrap(outbox.entries.first).payload)
        XCTAssertEqual(payload.previousBooking?.workEndTime, "18:00", "the copy the server still has, not the unsynced edit")
        XCTAssertEqual(payload.booking.workEndTime, "16:30")
    }

    func testAQueuedCreateCarriesNoPreviousCopy() throws {
        let outbox = OfflineOutboxStore.shared
        let booking = LogicFixtures.booking(on: Date())
        outbox.enqueueSaveBooking(booking, changedFields: nil, organizationId: "TEST-ORG", previous: booking)
        let payload = try JSONDecoder().decode(OfflineSaveBookingPayload.self, from: try XCTUnwrap(outbox.entries.first).payload)
        XCTAssertNil(payload.previousBooking)
    }

    func testAQueuedManagerScheduleEditKeepsTheCopyBeforeIt() throws {
        let outbox = OfflineOutboxStore.shared
        let synced = ManagerSiteBooking(id: UUID(), userId: "TEST-m1", date: Date(), timeSlot: .fullDay, locationType: .office)
        var edited = synced
        edited.timeSlot = .morning
        outbox.enqueueSaveManagerSiteBooking(edited, changedFields: ["timeSlot"], organizationId: "TEST-ORG", previous: synced)
        let payload = try JSONDecoder().decode(
            OfflineSaveManagerSiteBookingPayload.self, from: try XCTUnwrap(outbox.entries.first).payload
        )
        XCTAssertEqual(payload.previousBooking?.timeSlot, .fullDay)
    }

    func testAnOlderQueuedEditWithoutThePreviousCopyStillDecodes() throws {
        let booking = LogicFixtures.booking(on: Date())
        let encoded = try JSONEncoder().encode(OfflineSaveBookingPayload(booking: booking, changedFields: ["notes"]))
        var object = try XCTUnwrap(try JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object.removeValue(forKey: "previousBooking")
        let older = try JSONSerialization.data(withJSONObject: object)
        let payload = try JSONDecoder().decode(OfflineSaveBookingPayload.self, from: older)
        XCTAssertNil(payload.previousBooking)
        XCTAssertEqual(payload.changedFields, ["notes"])
    }

    /// Failure before: `completeBooking` wrote the status itself and never sent the reopen notice, although the status
    /// is part of `overtimeBookingFingerprint`. A refused edit also sent a notice for a change the server never took.
    func testEveryLabourEditGoesThroughTheNoticeAfterTheServerHasIt() throws {
        let store = try source("Project Planner/Core/BookingStore.swift")
        let complete = try functionBody("completeBooking", in: store)
        XCTAssertTrue(complete.contains("await updateBooking("), "completeBooking must reuse updateBooking (reopen notice)")
        XCTAssertFalse(complete.contains("saveData("), "completeBooking must not write on its own")
        let update = try functionBody("updateBooking", in: store)
        XCTAssertTrue(update.contains("written { OvertimeReopenNotice.labour"), "notice only once the edit reached the server")
        let coordinator = try source("Project Planner/Core/OfflineSyncCoordinator.swift")
        XCTAssertTrue(coordinator.contains("OvertimeReopenNotice.labour(before: previous, after: payload.booking)"))
        XCTAssertTrue(coordinator.contains("OvertimeReopenNotice.managerSite(before: previous, after: payload.booking)"))
        XCTAssertTrue(coordinator.contains("OvertimeReopenNotice.labour(before: booking, after: nil)"), "a replayed delete tells them too")
    }

    // MARK: 2. `bookingOccupiesDay`, never a private Cancelled / Completed filter

    /// Failure before: the week grid ignored a Completed booking when checking a new booking for overlap, although the
    /// rulebook (`bookingOccupiesDay`, `bookingRequestClashIds`) says Completed still fills the day; Cancelled never does.
    func testTheWeekGridOverlapCountsCompletedButNeverCancelled() {
        let calendar = CanonicalBusinessEngine.businessCalendar
        let day = LogicFixtures.day(2026, 11, 4, calendar: calendar)
        let person = UUID()
        func message(_ status: BookingStatus) -> String? {
            let existing = LogicFixtures.booking(
                on: day, slot: .customHours, start: "07:30", end: "16:00", status: status, operativeId: person
            )
            return ScheduleWeekGrid.overlapMessage(
                operativeIds: [person],
                userIds: [],
                day: day,
                timeSlot: .customHours,
                workStart: "15:00",
                workEnd: "17:00",
                operativeBookings: [existing],
                managerBookings: [],
                policy: LogicFixtures.policy,
                calendar: calendar
            )
        }
        XCTAssertNotNil(message(.completed))
        XCTAssertNotNil(message(.confirmed))
        XCTAssertNil(message(.cancelled))
    }

    func testTheOccupiesDayAnswerIsTheRulebooksForEveryStatus() {
        for status in BookingStatus.allCases {
            XCTAssertEqual(status.occupiesDay, CanonicalBusinessEngine.bookingOccupiesDay(status.rawValue), status.rawValue)
        }
    }

    /// Booking-day filters call `occupiesDay`; the only `.cancelled` left in these files is none.
    func testNoPrivateCancelledFilterInTheBookingDayScreens() throws {
        for path in [
            "Project Planner/Core/ScheduleWeekGrid.swift",
            "Project Planner/Views/BookLabourFlowView.swift",
            "Project Planner/Views/DailyOverviewView.swift",
            "Project Planner/Views/WeeklyReportView.swift",
        ] {
            XCTAssertFalse(try source(path).contains("status != .cancelled"), path)
        }
    }

    // MARK: 3. Bank holiday years are a union per organisation and region

    /// Failure before: opening Company details (no `alsoYears`) after a leave screen replaced the loaded years, so the
    /// previous leave year's bank holidays vanished and carry-over counted them as leave days until a leave screen
    /// reloaded.
    func testALoadWithoutExtraYearsKeepsTheYearsALeaveScreenLoaded() {
        let scope = BankHolidayService.loadScope(organizationId: "TEST-ORG", regionId: "GB-ENG-WLS")
        let leaveScreen = BankHolidayService.yearsToLoad(requested: [2025, 2026, 2027, 2028, 2024], previouslyLoaded: [])
        let companyDetails = BankHolidayService.yearsToLoad(
            requested: [2025, 2026, 2027, 2028],
            previouslyLoaded: Set(leaveScreen)
        )
        XCTAssertEqual(companyDetails, [2024, 2025, 2026, 2027, 2028])
        XCTAssertEqual(scope, BankHolidayService.loadScope(organizationId: "test-org", regionId: "GB-ENG-WLS"))
    }

    func testAnotherOrganisationOrRegionStartsAfresh() {
        let home = BankHolidayService.loadScope(organizationId: "TEST-ORG", regionId: "GB-ENG-WLS")
        XCTAssertNotEqual(home, BankHolidayService.loadScope(organizationId: "TEST-OTHER", regionId: "GB-ENG-WLS"))
        XCTAssertNotEqual(home, BankHolidayService.loadScope(organizationId: "TEST-ORG", regionId: "GB-SCT"))
        let service = try? source("Project Planner/Core/BankHolidayService.swift")
        XCTAssertTrue(service?.contains("previouslyLoaded: loadedScope == scope ? loadedYears : []") == true)
    }

    // MARK: 4. My Profile figures open their screens

    /// Failure before: the figure rows were plain text (web links each one). Each row now opens its screen, and every
    /// store those screens read reaches the card through both hosts (Settings → My Profile and the Home profile sheet,
    /// which did not pass `SmartCacheService`, so My Schedule, Tasks and Annual leave would have had no cache service).
    func testEveryLinkedFigureOpensItsScreenWithItsStores() throws {
        XCTAssertEqual(MyProfileFiguresCard.Destination.allCases.map(\.rawValue), ["annualLeave", "mySchedule", "tasks", "qualifications"])
        let card = try source("Project Planner/Views/MyProfileFiguresCard.swift")
        for destination in MyProfileFiguresCard.Destination.allCases {
            XCTAssertTrue(card.contains("opens: .\(destination.rawValue)"), "no row opens \(destination.rawValue)")
        }
        XCTAssertTrue(card.contains(".sheet(item: $destination)"))
        let home = try source("Project Planner/Views/HomeView.swift")
        let presentation = try XCTUnwrap(home.range(of: "HomeProfileCardSheet()\n"))
        XCTAssertTrue(home[presentation.upperBound...].prefix(80).contains(".environmentObject(smartCache)"))
        let sheetStart = try XCTUnwrap(home.range(of: "SettingsProfileDetailView(isSheetRoot: true)"))
        let sheetInjections = home[sheetStart.upperBound...].prefix(900)
        for store in ["projectStore", "appSettings", "notificationService", "smartCache"] {
            XCTAssertTrue(sheetInjections.contains(".environmentObject(\(store))"), store)
        }
    }

    // MARK: 5. Scheduling days are organisation-zone days (guardrail 2)

    /// Failure before: the date picker's toggle used the organisation calendar but its defaults (quick select, the
    /// Saturday/Sunday check, the week grid overlap) used the phone's, so one selection could hold both kinds of
    /// midnight, and a phone west of the organisation put a stored booking on the day before.
    func testDateSelectionDefaultsToOrganisationDays() {
        var selected = Set<Date>()
        let calendar = OrganizationRulebookContext.calendar
        let wednesdayNoon = LogicFixtures.day(2026, 11, 4, calendar: calendar)
        XCTAssertNil(ScheduleDateSelectionPolicy.toggle(date: wednesdayNoon, selected: &selected, policy: .default))
        XCTAssertEqual(selected, [calendar.startOfDay(for: wednesdayNoon)])
        XCTAssertEqual(selected.first.map { OrganizationRulebookContext.dayKey($0) }, "2026-11-04")
        let saturday = LogicFixtures.day(2026, 11, 7, calendar: calendar)
        XCTAssertTrue(PayrollTimePolicyCatalog.isWeekend(saturday))
        XCTAssertFalse(PayrollTimePolicyCatalog.isWeekend(wednesdayNoon))
    }

    func testTheSchedulingWeekReadsTheOrganisationCalendar() throws {
        let view = try source("Project Planner/Views/ProjectDetailView.swift")
        for name in ["weekStartDate", "weekDays", "bookingsForDate", "subcontractorBookingsForDate", "managerBookingsForDate", "changeWeek", "schedulingDayCard", "schedulingCompactDayCell", "schedulingShortDayTitle"] {
            let marker = name == "weekStartDate" || name == "weekDays" ? "private var \(name):" : "private func \(name)("
            let start = try XCTUnwrap(view.range(of: marker), name)
            let body = view[start.upperBound...].prefix(700)
            let end = body.range(of: "\n    private ")?.lowerBound ?? body.endIndex
            XCTAssertFalse(body[..<end].contains("Calendar.current"), name)
            XCTAssertFalse(body[..<end].contains("isDateInToday"), name)
        }
        let subcontractor = try source("Project Planner/Views/ScheduleSubcontractorView.swift")
        XCTAssertFalse(subcontractor.contains("Calendar.current"))
    }
}
