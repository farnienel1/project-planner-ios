import XCTest
@testable import Project_Planner

/// iOS 1.33.1 (owner test on iPhone, 7 Nov): (a) Save in project / small works scheduling kept spinning although the
/// booking had saved; (b) editing a booking's time from Scheduling opened the whole Schedule booking screen instead of
/// the wheels in Edit booking. Guardrail 7: the edit writes exactly the fields it wrote before.
@MainActor
final class Booking1331SaveFlowTests: XCTestCase {
    nonisolated override func setUp() {
        super.setUp()
        JobAccessContext.updateViewer(nil)
    }

    nonisolated override func tearDown() {
        JobAccessContext.updateViewer(nil)
        super.tearDown()
    }

    private func day(_ key: String) throws -> Date {
        try XCTUnwrap(CanonicalBusinessEngine.date(fromDayKey: key))
    }

    private var appRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Project Planner")
    }

    private func source(_ rel: String) throws -> String {
        try String(contentsOf: appRoot.appendingPathComponent(rel), encoding: .utf8)
    }

    /// The body of `func name(` in `text`, up to the next `    private func ` / `    func ` at the same indent.
    private func body(of marker: String, in text: String) throws -> Substring {
        let start = try XCTUnwrap(text.range(of: marker), "\(marker) not found")
        let rest = text[start.upperBound...]
        let next = rest.range(of: "\n    private func ") ?? rest.range(of: "\n    func ")
        return rest[..<(next?.lowerBound ?? rest.endIndex)]
    }

    // MARK: (a) the screen finishes when the save is done

    func testOutcomeIsDecidedFromThisSaveOnly() {
        XCTAssertEqual(ScheduleBookingSaveOutcome.decide(savedCount: 3, problem: nil), .confirmed)
        XCTAssertEqual(ScheduleBookingSaveOutcome.decide(savedCount: 1, problem: "  "), .confirmed)
        XCTAssertEqual(
            ScheduleBookingSaveOutcome.decide(savedCount: 2, problem: "Some bookings saved locally and will sync when you're back online."),
            .savedWithProblem("Some bookings saved locally and will sync when you're back online.")
        )
        XCTAssertEqual(ScheduleBookingSaveOutcome.decide(savedCount: 0, problem: "Refused"), .notSaved("Refused"))
        XCTAssertEqual(ScheduleBookingSaveOutcome.decide(savedCount: 0, problem: nil), .nothingToSave)

        // Every outcome ends the spinner with something on screen; only a save that did nothing keeps the choices.
        XCTAssertTrue(ScheduleBookingSaveOutcome.confirmed.closesScreen)
        XCTAssertTrue(ScheduleBookingSaveOutcome.savedWithProblem("x").closesScreen)
        XCTAssertTrue(ScheduleBookingSaveOutcome.nothingToSave.closesScreen)
        XCTAssertFalse(ScheduleBookingSaveOutcome.notSaved("x").closesScreen)
        XCTAssertFalse(ScheduleBookingSaveOutcome.notSaved("x").clearsSelection)
        XCTAssertTrue(ScheduleBookingSaveOutcome.savedWithProblem("x").clearsSelection)
    }

    func testAStaleStoreMessageIsNotReadAsThisEditFailing() async throws {
        let store = BookingStore()
        let monday = try day("2026-11-02")
        let booking = LogicFixtures.booking(on: monday, slot: .customHours, start: "07:30", end: "16:00")
        store.bookings = [booking]
        store.errorMessage = "Missing or insufficient permissions."  // left by an earlier load

        var edited = booking
        edited.workEndTime = "17:00"
        let problem = await store.updateBookingReportingProblem(edited)

        XCTAssertNil(problem, "the edit saved; the earlier load's message is not this save's")
        XCTAssertEqual(store.bookings.first?.workEndTime, "17:00")
    }

    func testARefusedSaveReportsItsOwnMessage() async throws {
        var job = Project(
            jobNumber: "TEST-J1",
            siteName: "TEST-Kitchen refit",
            siteAddress: "1 Test Street",
            client: Client(name: "TEST-Client"),
            startDate: Date(),
            endDate: Date(),
            jobType: .catA,
            manager: .na
        )
        job.storedManagerUserIds = ["TEST-someone-else"]
        JobAccessContext.updateJobs([job])
        defer { JobAccessContext.updateJobs([]) }
        JobAccessContext.updateViewer(JobAccessViewer(
            role: CanonicalBusinessEngine.CanonicalStaffAccountRole(isSuperAdmin: false, isAdmin: false, isManager: true, isOperativeMode: false),
            projectsToggle: true,
            smallWorksToggle: true,
            uid: "TEST-manager",
            ids: ["TEST-manager"],
            email: "TEST-manager@x.t"
        ))
        let store = BookingStore()
        let booking = LogicFixtures.booking(on: try day("2026-11-02"), projectId: job.id)

        let problem = await store.addBookingsReportingProblem([booking])

        XCTAssertNotNil(problem, "a manager is refused on a job they do not manage, and the screen says so")
        XCTAssertFalse(store.bookings.contains { $0.id == booking.id })
    }

    func testAWriteTheServerNeverConfirmsStopsWaitingAndQueues() async {
        let started = Date()
        do {
            try await FirestoreWriteAck.run(timeoutSeconds: 0.2) {
                try await Task.sleep(nanoseconds: 30_000_000_000)
            }
            XCTFail("expected the bounded wait to end")
        } catch {
            XCTAssertTrue(error is FirestoreWriteAck.TimedOut)
            XCTAssertTrue(OfflineWriteSupport.shouldQueue(error: error, isOnline: true), "queued as Pending sync")
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 5)
    }

    func testAConfirmedOrRefusedWriteIsPassedThrough() async {
        do {
            try await FirestoreWriteAck.run(timeoutSeconds: 5) {}
        } catch {
            XCTFail("a confirmed write must not throw: \(error)")
        }
        struct Refused: Error {}
        do {
            try await FirestoreWriteAck.run(timeoutSeconds: 5) { throw Refused() }
            XCTFail("expected the refusal")
        } catch {
            XCTAssertTrue(error is Refused)
        }
    }

    func testScheduleBookingAndQuickAddDoNotWaitForTheNotices() throws {
        let wizard = try source("Views/ScheduleOperativeView.swift")
        let proceed = try body(of: "private func proceedWithBooking()", in: wizard)
        XCTAssertFalse(proceed.contains("await notificationService.notifyBookedUsers"))
        XCTAssertFalse(proceed.contains("bookingStore.errorMessage == nil"))
        XCTAssertTrue(proceed.contains("updateBookingReportingProblem"))

        let detail = try source("Views/ProjectDetailView.swift")
        let quickAdd = try body(of: "private func commitQuickAdd(", in: detail)
        XCTAssertFalse(quickAdd.contains("await notificationService.notifyBookedUsers"))
    }

    // MARK: (b) Edit booking from Scheduling

    func testTappingAGroupBookingOpensEditBookingNotTheScheduleScreen() throws {
        let detail = try source("Views/ProjectDetailView.swift")
        let tap = try body(of: "private func handleSchedulingCellTap(", in: detail)
        let operativeBranch = try XCTUnwrap(tap.range(of: "if let booking = day.operativeBooking {"))
        let managerBranch = try XCTUnwrap(tap.range(of: "if let booking = day.managerBooking {"))
        let branch = tap[operativeBranch.upperBound..<managerBranch.lowerBound]
        XCTAssertFalse(branch.contains("showingScheduleOperative"), "a tap on a booking never opens Schedule booking")
        XCTAssertTrue(branch.contains("bookingEditTarget = .operative("))
        XCTAssertEqual(detail.components(separatedBy: "showsInlineWheels: true").count - 1, 2, "labour and manager edit")
    }

    /// The closure's mapping before 1.33.1, kept here as written so the moved helper is held to it.
    private func oldLabourSave(_ booking: Booking, _ start: String, _ end: String, _ breakRemoved: Bool, _ rate: Double?, now: Date) -> Booking {
        var updated = booking
        updated.timeSlot = .customHours
        updated.workStartTime = start
        updated.workEndTime = end
        updated.isBreakRemoved = breakRemoved
        updated.otMultiplierOverride = rate
        updated.updatedAt = now
        return updated
    }

    func testEditBookingWritesTheSameFieldsAsBefore() throws {
        let monday = try day("2026-11-02")
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        var cases: [Booking] = [
            LogicFixtures.booking(on: monday, slot: .customHours, start: "07:30", end: "16:00"),
            LogicFixtures.booking(on: monday, slot: .fullDay),
            LogicFixtures.booking(on: monday, slot: .customHours, start: "06:00", end: "18:00", breakRemoved: true),
        ]
        cases[2].otMultiplierOverride = 2
        for stored in cases {
            let edits: [(String, String, Bool, Double?)] = [("07:30", "17:00", false, nil), ("08:00", "16:00", true, 1.5)]
            for (start, end, breakRemoved, rate) in edits {
                let new = ScheduleBookingEditSave.labour(stored, start: start, end: end, isBreakRemoved: breakRemoved, otMultiplierOverride: rate, now: now)
                let old = oldLabourSave(stored, start, end, breakRemoved, rate, now: now)
                XCTAssertEqual(new, old)
                XCTAssertEqual(
                    BookingWritePatch.changedLabourFields(from: stored, to: new),
                    BookingWritePatch.changedLabourFields(from: stored, to: old)
                )
                let policy = OrgPayrollTimePolicy.default
                XCTAssertEqual(
                    PayrollHoursEngine.compute(booking: new, day: monday, policy: policy).totalPaidHours,
                    PayrollHoursEngine.compute(booking: old, day: monday, policy: policy).totalPaidHours
                )
            }
        }
    }

    func testEditingOnePersonOfAGroupChangesOnlyTheirTimes() throws {
        let monday = try day("2026-11-02")
        var stored = LogicFixtures.booking(on: monday, slot: .customHours, start: "07:30", end: "16:00")
        stored.bookingGroupId = "TEST-group"
        let edited = ScheduleBookingEditSave.labour(stored, start: "07:30", end: "17:00", isBreakRemoved: false, otMultiplierOverride: nil)

        XCTAssertEqual(BookingWritePatch.changedLabourFields(from: stored, to: edited), ["workEndTime"])
        XCTAssertEqual(edited.bookingGroupId, "TEST-group", "the group stays; Edit group still finds it")
        XCTAssertEqual(edited.status, stored.status)
    }

    func testManagerSiteEditWritesTheSameFieldsAsBefore() throws {
        let monday = try day("2026-11-02")
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let stored = ManagerSiteBooking(
            userId: "TEST-manager",
            date: monday,
            timeSlot: .fullDay,
            locationType: .project,
            locationId: UUID()
        )
        let new = ScheduleBookingEditSave.managerSite(stored, start: "08:00", end: "15:30", isBreakRemoved: true, now: now)
        var old = stored
        old.timeSlot = .customHours
        old.workStartTime = "08:00"
        old.workEndTime = "15:30"
        old.isBreakRemoved = true
        old.updatedAt = now
        XCTAssertEqual(new, old)
        XCTAssertEqual(
            BookingWritePatch.changedManagerFields(from: stored, to: new),
            ["timeSlot", "workStartTime", "workEndTime", "isBreakRemoved"]
        )
    }
}
