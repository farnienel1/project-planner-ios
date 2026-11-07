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

    /// Failure before: a refused edit sent a notice for a change the server never took. (`completeBooking`, which wrote
    /// the status without the notice, had no callers and is deleted.)
    func testEveryLabourEditGoesThroughTheNoticeAfterTheServerHasIt() throws {
        let store = try source("Project Planner/Core/BookingStore.swift")
        XCTAssertNil(store.range(of: "func completeBooking("), "dead code: no caller")
        XCTAssertNil(store.range(of: "var cancelledBookings"), "dead code: no caller")
        let update = try functionBody("updateBooking", in: store)
        XCTAssertTrue(update.contains("if !changed.isEmpty, written {"), "notice only once the edit reached the server")
        XCTAssertTrue(update.contains("OvertimeReopenNotice.labour(before: before, after: booking)"))
        let coordinator = try source("Project Planner/Core/OfflineSyncCoordinator.swift")
        XCTAssertTrue(coordinator.contains(
            "OvertimeReopenNotice.labour(before: previous, after: payload.booking, organizationId: entry.organizationId)"
        ))
        XCTAssertTrue(coordinator.contains(
            "OvertimeReopenNotice.managerSite(before: previous, after: payload.booking, organizationId: entry.organizationId)"
        ))
        XCTAssertTrue(
            coordinator.contains("OvertimeReopenNotice.labour(before: booking, after: nil, organizationId: entry.organizationId)"),
            "a replayed delete tells them too"
        )
    }

    // MARK: 1a. A replayed notice is judged only in the company it was written to (review #209)

    /// Failure before: an edit queued in company A replayed while company B was open; the write went to A but the notice
    /// read B's roster, jobs, organisation and overtime records and wrote its rows in B.
    func testANoticeForAnotherCompanysWriteIsSkipped() {
        XCTAssertTrue(OvertimeReopenNotice.noticeMayBeSent(writtenOrganizationId: nil, openOrganizationId: "TEST-ORG-B"))
        XCTAssertTrue(OvertimeReopenNotice.noticeMayBeSent(writtenOrganizationId: " test-org-a ", openOrganizationId: "TEST-ORG-A"))
        XCTAssertFalse(OvertimeReopenNotice.noticeMayBeSent(writtenOrganizationId: "TEST-ORG-A", openOrganizationId: "TEST-ORG-B"))
        XCTAssertFalse(OvertimeReopenNotice.noticeMayBeSent(writtenOrganizationId: "TEST-ORG-A", openOrganizationId: nil))
    }

    func testTheNoticeChecksTheWrittenCompanyBeforeReadingAnything() throws {
        let service = try source("Project Planner/Core/NotificationService.swift")
        let body = try functionBody("notifyOvertimeLineReopened", in: service)
        let check = try XCTUnwrap(body.range(of: "OvertimeReopenNotice.noticeMayBeSent("))
        let firstRead = try XCTUnwrap(body.range(of: "projectStore?.projects"))
        XCTAssertLessThan(check.lowerBound, firstRead.lowerBound)
    }

    // MARK: 1b. One change, one notice (review #209)

    /// Failure before: an edit was queued, then the booking was edited again online before the queue flushed. The online
    /// write told the person; the older queued edit replayed later with its own "before" copy and told them again.
    func testAnOnlineEditSilencesTheOlderQueuedEdit() throws {
        let outbox = OfflineOutboxStore.shared
        let synced = LogicFixtures.booking(on: Date(), slot: .customHours, start: "07:30", end: "18:00")
        var queued = synced
        queued.workEndTime = "17:00"
        outbox.enqueueSaveBooking(queued, changedFields: ["workEndTime"], organizationId: "TEST-ORG", baselineFingerprint: "fp", previous: synced)
        let before = try XCTUnwrap(outbox.entries.first)

        outbox.clearReopenBaseline(bookingId: synced.id)

        let after = try XCTUnwrap(outbox.entries.first)
        XCTAssertEqual(outbox.entries.count, 1)
        XCTAssertEqual(after.id, before.id, "the same entry, same place in the queue")
        XCTAssertEqual(after.createdAt, before.createdAt)
        XCTAssertEqual(after.organizationId, before.organizationId)
        let payload = try JSONDecoder().decode(OfflineSaveBookingPayload.self, from: after.payload)
        XCTAssertNil(payload.previousBooking, "the replay stays silent")
        XCTAssertEqual(payload.booking.workEndTime, "17:00", "the queued write itself is unchanged")
        XCTAssertEqual(payload.changedFields, ["workEndTime"])
        XCTAssertEqual(payload.baselineFingerprint, "fp")

        // A later offline edit keeps the copy before it as the new "before".
        var later = queued
        later.workEndTime = "16:00"
        outbox.enqueueSaveBooking(later, changedFields: ["workEndTime"], organizationId: "TEST-ORG", previous: queued)
        let merged = try JSONDecoder().decode(OfflineSaveBookingPayload.self, from: try XCTUnwrap(outbox.entries.first).payload)
        XCTAssertEqual(merged.previousBooking?.workEndTime, "17:00")
    }

    func testAnOnlineEditSilencesTheOlderQueuedManagerScheduleEdit() throws {
        let outbox = OfflineOutboxStore.shared
        let synced = ManagerSiteBooking(id: UUID(), userId: "TEST-m1", date: Date(), timeSlot: .fullDay, locationType: .office)
        var edited = synced
        edited.timeSlot = .morning
        outbox.enqueueSaveManagerSiteBooking(edited, changedFields: ["timeSlot"], organizationId: "TEST-ORG", previous: synced)
        outbox.clearManagerSiteReopenBaseline(bookingId: synced.id)
        let payload = try JSONDecoder().decode(
            OfflineSaveManagerSiteBookingPayload.self, from: try XCTUnwrap(outbox.entries.first).payload
        )
        XCTAssertNil(payload.previousBooking)
        XCTAssertEqual(payload.booking.timeSlot, .morning)
    }

    func testClearingTheBaselineLeavesOtherEntriesAlone() throws {
        let outbox = OfflineOutboxStore.shared
        let other = LogicFixtures.booking(on: Date())
        var edited = other
        edited.notes = "changed"
        outbox.enqueueSaveBooking(edited, changedFields: ["notes"], organizationId: "TEST-ORG", previous: other)
        outbox.clearReopenBaseline(bookingId: UUID())
        let payload = try JSONDecoder().decode(OfflineSaveBookingPayload.self, from: try XCTUnwrap(outbox.entries.first).payload)
        XCTAssertNotNil(payload.previousBooking)
    }

    func testTheOnlineEditPathsClearTheQueuedBaselineBeforeNotifying() throws {
        let store = try source("Project Planner/Core/BookingStore.swift")
        let update = try functionBody("updateBooking", in: store)
        let clear = try XCTUnwrap(update.range(of: "OfflineOutboxStore.shared.clearReopenBaseline(bookingId: booking.id)"))
        let notice = try XCTUnwrap(update.range(of: "OvertimeReopenNotice.labour(before: before, after: booking)"))
        XCTAssertLessThan(clear.lowerBound, notice.lowerBound)
        let manager = try source("Project Planner/Core/ManagerScheduleStore.swift")
        XCTAssertTrue(manager.contains("OfflineOutboxStore.shared.clearManagerSiteReopenBaseline(bookingId: normalizedBooking.id)"))
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

    /// Each screen a figure opens as a sheet has its own Done button (review #209 asked; they already had one):
    /// My Schedule and Tasks own a NavigationStack with Done, Annual leave closes with its back button when
    /// `presentedAsSheet`. Wrapping them in another NavigationStack would nest two.
    func testEveryFigureSheetCanBeClosed() throws {
        for (path, marker) in [
            ("Project Planner/Views/MyScheduleView.swift", "accessibilityIdentifier(\"mySchedule.done\")"),
            ("Project Planner/Views/TasksDetailView.swift", "accessibilityIdentifier(\"tasksDetail.done\")"),
        ] {
            let text = try source(path)
            XCTAssertTrue(text.contains("Button(\"Done\") { dismiss() }"), path)
            XCTAssertTrue(text.contains(marker), path)
        }
        XCTAssertTrue(try source("Project Planner/Views/MyProfileFiguresCard.swift").contains("HolidayView(showRequests: false, presentedAsSheet: true)"))
    }

    func testTheDeletedCoverageHelperStaysDeleted() throws {
        XCTAssertNil(try source("Project Planner/Core/StaffEmailIdentity.swift").range(of: "static func coverage("))
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

    // MARK: 1.36.0 hand-off: rate history under every id of the person (§8)

    /// Failure before: pay and Edit User's previous rates read history under one `operatives` row, so a rate saved
    /// under the person's other row (a re-added person, a second catalogue row on their email) was missed.
    func testRateHistoryIdsCoverEveryOperativesRowOfThePerson() {
        let user = LogicFixtures.selfEmployedUser(id: "TEST-u1", email: "worker@example.com")
        let rowA = LogicFixtures.operative(id: UUID(), email: "worker@example.com")
        let rowB = LogicFixtures.operative(id: UUID(), email: "Worker@Example.com")
        let other = LogicFixtures.operative(id: UUID(), email: "someone@example.com")
        let ids = PayrollRateResolver.personOperativeIds(user: user, operative: nil, operatives: [rowA, rowB, other])
        XCTAssertEqual(Set(ids), [rowA.id.uuidString, rowB.id.uuidString])
        XCTAssertEqual(
            PayrollRateResolver.personOperativeIds(user: nil, operative: other, operatives: [rowA]),
            [other.id.uuidString]
        )
    }

    func testRateHistoryEntriesMatchEveryIdWithoutCase() {
        let rowId = UUID()
        func entry(_ day: Double, user: String?, operative: UUID?) -> OperativeDayRateHistoryEntry {
            OperativeDayRateHistoryEntry(
                id: UUID(),
                userId: user,
                operativeId: operative,
                dayRate: 200 + day,
                effectiveAt: Date(timeIntervalSince1970: day * 86_400),
                createdAt: Date(timeIntervalSince1970: day * 86_400)
            )
        }
        let collection = OperativeDayRateHistoryCollection(
            byUserId: ["test-u1": [entry(1, user: "test-u1", operative: nil)], "TEST-OLD": [entry(2, user: "TEST-OLD", operative: nil)]],
            byOperativeId: [rowId.uuidString: [entry(3, user: nil, operative: rowId)], UUID().uuidString: [entry(4, user: nil, operative: nil)]]
        )
        let rows = collection.entries(userIds: ["TEST-U1", "test-old"], operativeIds: [rowId.uuidString.lowercased()])
        XCTAssertEqual(rows.map(\.dayRate), [201, 202, 203])
    }
}
