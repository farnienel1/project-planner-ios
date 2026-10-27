import XCTest
@testable import Project_Planner

/// Scheduling → Daily Overview → Warnings → Weekly Report, through the packed rulebook.
/// The same scenarios run on the web in `lib/canonical/canonical.test.ts` ("Booking chain").
/// Booking identity itself is covered by `BookingIdentityTests` and `BookingAuditTests`.
@MainActor
final class BookingChainCanonicalTests: XCTestCase {
    /// A Firebase Auth uid: what web stores as `operativeId` for a person with no operative record.
    private let uid = "Xy7AbcFirebaseUid0123456789"
    private let projectId = "11111111-2222-3333-4444-555555555555"
    private let smallWorksId = "11111111-2222-3333-4444-666666666666"
    private let dayKey = "2026-10-27"

    private var londonDay: Date {
        CanonicalBusinessEngine.date(fromDayKey: dayKey)!
    }

    private var dayTimestamp: [String: Any] {
        ["seconds": Int(londonDay.timeIntervalSince1970), "nanoseconds": 0]
    }

    private func person(id: String? = nil, employment: EmploymentType = .selfEmployed) -> AppUser {
        AppUser(
            id: id ?? uid,
            email: "pat@site.test",
            organizationId: "org-test",
            role: .operative,
            firstName: "Pat",
            surname: "Login",
            isActive: true,
            passwordSet: true,
            permissions: UserPermissions(operativeMode: true),
            dayRate: 200,
            employmentType: employment
        )
    }

    /// Stored documents read the way `FirebaseBackend.bookingsFromFirestoreDocuments` reads them.
    private func read(_ documents: [(id: String, data: [String: Any])]) throws -> [Booking] {
        let payload: [[String: Any]] = documents.map { ["id": $0.id, "data": $0.data] }
        let parsed = try XCTUnwrap(CanonicalBusinessEngine.parseBookingDocuments(payload), "the packed script did not run")
        return parsed.compactMap { FirebaseBackend.booking(fromCanonical: $0) }
    }

    private func stored(_ start: String? = nil, _ end: String? = nil, slot: String = "FULL DAY", on job: String? = nil, id: String = UUID().uuidString) -> (id: String, data: [String: Any]) {
        var data: [String: Any] = [
            "operativeId": uid,
            "projectId": job ?? projectId,
            "date": dayTimestamp,
            "timeSlot": slot,
            "status": "Confirmed",
            "bookedBy": "admin@site.test",
        ]
        if let start { data["workStartTime"] = start }
        if let end { data["workEndTime"] = end }
        return (id: id, data: data)
    }

    private func rowsOnDay(_ bookings: [Booking], users: [AppUser]? = nil, excluded: [String] = []) -> [CanonicalUnbookedLabourRow] {
        WarningsComputation.unbookedLabourRowsOnDay(
            day: londonDay,
            users: users ?? [person()],
            operatives: [],
            operativeBookings: bookings,
            managerBookings: [],
            holidays: [],
            policy: .default,
            includeWeekends: false,
            excludedUserIds: excluded
        )
    }

    // MARK: - The missing-booking regression, end to end

    func testRegressionBookingUnderFirebaseUserIdCoversThatPersonOnDailyOverview() throws {
        // Before: iOS required a UUID operativeId and dropped this document, so Daily Overview and
        // Warnings showed the person as not booked although web showed them booked.
        let bookings = try read([stored()])
        XCTAssertEqual(bookings.count, 1)
        XCTAssertEqual(bookings.first?.storedOperativeId, uid)
        XCTAssertEqual(rowsOnDay(bookings).map(\.personKey), [])
        // Without the booking the same person is a gap, so the empty list above is the booking's doing.
        XCTAssertEqual(rowsOnDay([]).map(\.personKey), [uid])
    }

    func testABookingWhoseDocumentIdIsNotAUuidIsSavedAndDeletedUnderThatId() throws {
        let booking = try XCTUnwrap(read([stored(id: "legacy-doc")]).first)
        XCTAssertEqual(booking.documentKey, "legacy-doc")
        let normal = try XCTUnwrap(read([stored(id: "A1B2C3D4-0000-0000-0000-000000000001")]).first)
        XCTAssertEqual(normal.documentKey, "A1B2C3D4-0000-0000-0000-000000000001")
    }

    // MARK: - Coverage

    func testCoverageIsTheUnionAcrossAProjectAndASmallWorksJob() throws {
        let morning = try XCTUnwrap(read([stored("07:30", "12:00", slot: "CUSTOM_HOURS")]).first)
        let afternoon = try XCTUnwrap(read([stored("12:00", "16:00", slot: "CUSTOM_HOURS", on: smallWorksId)]).first)
        let overlap = try XCTUnwrap(read([stored("11:00", "16:00", slot: "CUSTOM_HOURS", on: smallWorksId)]).first)
        let long = try XCTUnwrap(read([stored("06:00", "18:00", slot: "CUSTOM_HOURS")]).first)
        XCTAssertEqual(rowsOnDay([morning]).first?.missingHours, 3.5)
        XCTAssertEqual(rowsOnDay([morning, afternoon]).count, 0, "back-to-back bookings on two jobs cover the day")
        XCTAssertEqual(rowsOnDay([morning, overlap]).count, 0, "overlap is not double counted")
        XCTAssertEqual(rowsOnDay([long]).count, 0, "hours beyond the company day still cover it")
    }

    func testNamedAmPlusPmIsAFullDay() throws {
        let am = try XCTUnwrap(read([stored(slot: "AM")]).first)
        let pm = try XCTUnwrap(read([stored(slot: "PM")]).first)
        XCTAssertEqual(rowsOnDay([am]).count, 1)
        XCTAssertEqual(rowsOnDay([am, pm]).count, 0)
    }

    func testExcludedPersonIsNeverUnbookedAndComesBackWhenIncluded() {
        XCTAssertEqual(rowsOnDay([], excluded: [uid]).count, 0)
        XCTAssertEqual(rowsOnDay([], excluded: []).count, 1)
    }

    // MARK: - Incomplete data

    func testAFailedReadBlocksTheScanInsteadOfReportingUnbooked() {
        XCTAssertNil(WarningsDataCompleteness.blockingReason(bookingsLoadFailed: false, managerBookingsLoadFailed: false, bookingDecode: nil))
        XCTAssertNotNil(WarningsDataCompleteness.blockingReason(bookingsLoadFailed: true, managerBookingsLoadFailed: false, bookingDecode: nil))
        XCTAssertNotNil(WarningsDataCompleteness.blockingReason(bookingsLoadFailed: false, managerBookingsLoadFailed: true, bookingDecode: nil))
        let scriptDown = BookingDecodeReport(total: 4, refused: 0, repaired: 0, scriptFailed: true)
        XCTAssertNotNil(WarningsDataCompleteness.blockingReason(bookingsLoadFailed: false, managerBookingsLoadFailed: false, bookingDecode: scriptDown))
        // A document the shared reader refuses is refused on the web too, so it does not block the scan.
        let oneRefused = BookingDecodeReport(total: 4, refused: 1, repaired: 0, scriptFailed: false)
        XCTAssertNil(WarningsDataCompleteness.blockingReason(bookingsLoadFailed: false, managerBookingsLoadFailed: false, bookingDecode: oneRefused))
    }

    func testAServerSnapshotThatLostABookingIsNotTheSameList() {
        let kept = LogicFixtures.booking(on: londonDay)
        let deletedOnWeb = LogicFixtures.booking(on: londonDay)
        XCTAssertFalse(BookingStore.sameBookings([kept], [kept, deletedOnWeb]))
        XCTAssertTrue(BookingStore.sameBookings([deletedOnWeb, kept], [kept, deletedOnWeb]))
        var moved = kept
        moved.date = londonDay.addingTimeInterval(86_400)
        XCTAssertFalse(BookingStore.sameBookings([moved], [kept]))
    }

    // MARK: - Statuses

    func testOpenIsConfirmedOrTentativeOnly() {
        XCTAssertTrue(BookingStatus.confirmed.isOpen)
        XCTAssertTrue(BookingStatus.tentative.isOpen)
        XCTAssertFalse(BookingStatus.completed.isOpen, "a finished subcontractor booking is not open (isOpenBookingStatus)")
        XCTAssertFalse(BookingStatus.cancelled.isOpen)
        XCTAssertTrue(BookingStatus.completed.occupiesDay, "but a completed day was still booked (bookingOccupiesDay)")
    }

    // MARK: - Paid hours (payrollHoursResult)

    private func paid(_ slot: TimeSlot, _ start: String? = nil, _ end: String? = nil, dayKey: String = "2026-10-21") -> PayrollHoursResult {
        let day = CanonicalBusinessEngine.date(fromDayKey: dayKey)!
        let booking = LogicFixtures.booking(on: day, slot: slot, start: start, end: end)
        return PayrollHoursEngine.compute(booking: booking, day: day, policy: .default)
    }

    func testPaidHoursMatchTheWebFigures() {
        XCTAssertEqual(paid(.customHours, "07:30", "16:00").totalPaidHours, 8, accuracy: 0.001)
        XCTAssertEqual(paid(.customHours, "07:30", "18:00").totalPaidHours, 11, accuracy: 0.001)
        // The 21/10 small works booking on the web Daily Overview: 06:00–17:45.
        let early = paid(.customHours, "06:00", "17:45")
        XCTAssertEqual(early.totalPaidHours, 8 + 3.25 * 1.5, accuracy: 0.001)
        XCTAssertEqual(early.outsideMultiplier, 1.5, accuracy: 0.001)
        XCTAssertEqual(paid(.morning).totalPaidHours, 4, accuracy: 0.001)
        XCTAssertEqual(paid(.fullDay).totalPaidHours, 8, accuracy: 0.001)
        XCTAssertEqual(paid(.customHours, "22:00", "02:00").totalPaidHours, 4, accuracy: 0.001)
        XCTAssertEqual(CanonicalBusinessEngine.reportDayValue(totalPaidHours: 11, standardPaidHours: 8) ?? 0, 1.375, accuracy: 0.001)
        XCTAssertEqual(CanonicalBusinessEngine.subcontractorDayValue("CUSTOM_HOURS"), 0.5)
    }

    func testAWeekendDayTheCompanyNeverSavedUsesTheDefaults() {
        let policy = OrgPayrollTimePolicy.fromFirestore(["standardDayStart": "07:30"])
        XCTAssertEqual(policy.saturday, .defaultSaturday)
        XCTAssertEqual(policy.sunday, .defaultSunday)
        // Saturday 24/10, 07:30–13:00: the default window credits the full 8h.
        XCTAssertEqual(
            PayrollHoursEngine.compute(
                booking: LogicFixtures.booking(on: CanonicalBusinessEngine.date(fromDayKey: "2026-10-24")!, slot: .customHours, start: "07:30", end: "13:00"),
                day: CanonicalBusinessEngine.date(fromDayKey: "2026-10-24")!,
                policy: policy
            ).totalPaidHours,
            8,
            accuracy: 0.001
        )
    }

    // MARK: - Clash groups (overlappingIntervalGroups)

    func testClashGroupsChainAndBackToBackIsNotAClash() {
        let am = CanonicalMinuteInterval(start: 450, end: 720)
        let pm = CanonicalMinuteInterval(start: 720, end: 960)
        let middle = CanonicalMinuteInterval(start: 660, end: 780)
        XCTAssertEqual(CanonicalBusinessEngine.overlappingIntervalGroups([am, pm]), [])
        XCTAssertEqual(CanonicalBusinessEngine.overlappingIntervalGroups([am, pm, middle]), [[0, 1, 2]])
        XCTAssertEqual(CanonicalBusinessEngine.overlappingIntervalGroups([am, nil, middle]), [[0, 2]])
    }

    // MARK: - Weekly report pay

    func testPayeLineShowsPayeNeverZeroAndIsNotTotalled() throws {
        let paye = try XCTUnwrap(CanonicalBusinessEngine.reportPayCell(CanonicalReportPayLine(isPaye: true, pay: 0)))
        XCTAssertEqual(paye, CanonicalReportPayCell(pay: nil, label: "PAYE", countsTowardPayTotal: false))
        let selfEmployed = try XCTUnwrap(CanonicalBusinessEngine.reportPayCell(CanonicalReportPayLine(isPaye: false, pay: 150.004)))
        XCTAssertEqual(selfEmployed, CanonicalReportPayCell(pay: 150, label: nil, countsTowardPayTotal: true))
        let noRate = try XCTUnwrap(CanonicalBusinessEngine.reportPayCell(CanonicalReportPayLine(isPaye: false, pay: nil)))
        XCTAssertEqual(noRate, CanonicalReportPayCell(pay: nil, label: nil, countsTowardPayTotal: false))
        XCTAssertEqual(CanonicalBusinessEngine.reportPayTotal([
            CanonicalReportPayLine(isPaye: false, pay: 150),
            CanonicalReportPayLine(isPaye: true, pay: 120),
            CanonicalReportPayLine(isPaye: false, pay: 75.5),
        ]), 225.5)
        XCTAssertEqual(CanonicalBusinessEngine.reportPersonPayCell([CanonicalReportPayLine(isPaye: true, pay: 0)])?.label, "PAYE")
        let mixed = try XCTUnwrap(CanonicalBusinessEngine.reportPersonPayCell([
            CanonicalReportPayLine(isPaye: true, pay: 0),
            CanonicalReportPayLine(isPaye: false, pay: 200),
        ]))
        XCTAssertEqual(mixed, CanonicalReportPayCell(pay: 200, label: nil, countsTowardPayTotal: true))
    }

    func testEmploymentTypeOnTheDayDecidesPaye() {
        var user = person(employment: .paye)
        user.employmentTypeTransitionFrom = .selfEmployed
        user.employmentTypeEffectiveAt = CanonicalBusinessEngine.date(fromDayKey: "2026-10-28")
        XCTAssertEqual(user.employmentType(on: londonDay), .selfEmployed)
        XCTAssertEqual(user.employmentType(on: CanonicalBusinessEngine.date(fromDayKey: "2026-10-28")!), .paye)
    }
}
