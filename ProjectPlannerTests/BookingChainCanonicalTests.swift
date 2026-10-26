import XCTest
@testable import Project_Planner

/// Scheduling → Daily Overview → Warnings → Weekly Report, through the packed rulebook.
/// The same scenarios run on the web in `lib/canonical/canonical.test.ts` ("Booking chain").
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

    private func parsed(_ documents: [(id: String, data: [String: Any])]) throws -> [Booking] {
        let results = try XCTUnwrap(CanonicalBusinessEngine.parseBookingDocuments(documents), "the packed script did not run")
        XCTAssertEqual(results.count, documents.count)
        return results.compactMap { result in result.booking.flatMap { FirebaseBackend.booking(from: $0) } }
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

    // MARK: - Reading stored bookings

    func testRegressionBookingUnderFirebaseUserIdIsReadAndCoversThatPerson() throws {
        // Before: `bookingFromFirestoreDocument` required a UUID operativeId and dropped this document,
        // so Daily Overview and Warnings showed the person as not booked although web showed them booked.
        let bookings = try parsed([
            (id: "A1B2C3D4-0000-0000-0000-000000000001", data: [
                "operativeId": uid,
                "projectId": projectId,
                "date": dayTimestamp,
                "timeSlot": "FULL DAY",
                "status": "Confirmed",
                "bookedBy": "admin@site.test",
            ]),
        ])
        let booking = try XCTUnwrap(bookings.first)
        XCTAssertEqual(booking.operativeKey, uid)
        XCTAssertEqual(booking.storedOperativeId, uid)
        XCTAssertEqual(booking.operativeId, StableBookingIdentity.uuid(for: uid))
        XCTAssertTrue(CanonicalBusinessEngine.businessCalendar.isDate(booking.date, inSameDayAs: londonDay))

        XCTAssertEqual(rowsOnDay([booking]).map(\.personKey), [])
        // Without the booking the same person is a gap, so the empty list above is the booking's doing.
        XCTAssertEqual(rowsOnDay([]).map(\.personKey), [uid])
        // The booked row is named from the account, not "Not on the roster".
        XCTAssertEqual(rosterNameForLabourBooking(operativeId: booking.operativeId, operatives: [], users: [person()]), "Pat Login")
    }

    func testLegacySpellingsAreKeptLikeTheWebReader() throws {
        let results = try XCTUnwrap(CanonicalBusinessEngine.parseBookingDocuments([
            (id: "legacy-doc", data: [
                "operativeId": "11111111-2222-3333-4444-555555555556",
                "projectId": projectId,
                "date": londonDay.timeIntervalSince1970 * 1000,
                "status": "confirmed",
            ]),
            (id: "bad", data: ["projectId": projectId]),
        ]))
        XCTAssertEqual(results.map(\.ok), [true, false])
        let row = try XCTUnwrap(results[0].booking)
        XCTAssertEqual(row.status, "Confirmed")
        XCTAssertEqual(row.timeSlot, "FULL DAY")
        XCTAssertEqual(Set(results[0].repairs ?? []), ["date_not_timestamp", "status_alias", "slot_missing_full_day", "booked_by_missing"])
        XCTAssertEqual(Set(results[1].errors ?? []), ["missing_operative_id", "missing_date", "bad_status"])

        let booking = try XCTUnwrap(FirebaseBackend.booking(from: row))
        XCTAssertEqual(booking.documentKey, "legacy-doc", "a non-UUID document id is saved and deleted under its own id")
        XCTAssertNil(booking.storedOperativeId, "a UUID operative id keeps the uppercase uuidString")
        XCTAssertEqual(booking.operativeKey, "11111111-2222-3333-4444-555555555556".uppercased())
    }

    func testStableIdentityIsDeterministicAndPassesUUIDsThrough() {
        XCTAssertEqual(StableBookingIdentity.uuid(for: uid), StableBookingIdentity.uuid(for: " \(uid) "))
        XCTAssertNotEqual(StableBookingIdentity.uuid(for: uid), StableBookingIdentity.uuid(for: uid + "x"))
        XCTAssertEqual(StableBookingIdentity.uuid(for: projectId), UUID(uuidString: projectId))
        XCTAssertNil(StableBookingIdentity.storedIdIfNotUUID(projectId))
        XCTAssertEqual(StableBookingIdentity.storedIdIfNotUUID(uid), uid)
    }

    func testCachedBookingsWithoutTheNewKeysStillDecode() throws {
        var booking = LogicFixtures.booking(on: londonDay)
        booking.storedOperativeId = uid
        let roundTrip = try JSONDecoder().decode(Booking.self, from: JSONEncoder().encode(booking))
        XCTAssertEqual(roundTrip.operativeKey, uid)

        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(LogicFixtures.booking(on: londonDay))) as? [String: Any])
        legacy.removeValue(forKey: "storedOperativeId")
        legacy.removeValue(forKey: "storedProjectId")
        legacy.removeValue(forKey: "documentId")
        let decoded = try JSONDecoder().decode(Booking.self, from: JSONSerialization.data(withJSONObject: legacy))
        XCTAssertNil(decoded.storedOperativeId)
        XCTAssertEqual(decoded.operativeKey, decoded.operativeId.uuidString)
    }

    // MARK: - Coverage

    private func custom(_ start: String, _ end: String, on job: String) throws -> Booking {
        try XCTUnwrap(parsed([
            (id: UUID().uuidString, data: [
                "operativeId": uid,
                "projectId": job,
                "date": dayTimestamp,
                "timeSlot": "CUSTOM_HOURS",
                "workStartTime": start,
                "workEndTime": end,
                "status": "Confirmed",
                "bookedBy": "admin@site.test",
            ]),
        ]).first)
    }

    func testCoverageIsTheUnionAcrossAProjectAndASmallWorksJob() throws {
        let morning = try custom("07:30", "12:00", on: projectId)
        let afternoon = try custom("12:00", "16:00", on: smallWorksId)
        XCTAssertEqual(rowsOnDay([morning]).first?.missingHours, 3.5)
        XCTAssertEqual(rowsOnDay([morning, afternoon]).count, 0, "back-to-back bookings on two jobs cover the day")
        XCTAssertEqual(rowsOnDay([morning, try custom("11:00", "16:00", on: smallWorksId)]).count, 0, "overlap is not double counted")
        XCTAssertEqual(rowsOnDay([try custom("06:00", "18:00", on: projectId)]).count, 0, "hours beyond the company day still cover it")
    }

    func testNamedAmPlusPmIsAFullDay() throws {
        let am = LogicFixtures.booking(on: londonDay, slot: .morning)
        let pm = LogicFixtures.booking(on: londonDay, slot: .afternoon, operativeId: am.operativeId)
        let user = person(id: am.operativeId.uuidString)
        XCTAssertEqual(rowsOnDay([am], users: [user]).count, 1)
        XCTAssertEqual(rowsOnDay([am, pm], users: [user]).count, 0)
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
        let scriptDown = BookingDecodeReport(total: 4, refused: 4, repaired: 0, scriptFailed: true)
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
        XCTAssertEqual(
            CanonicalBusinessEngine.reportPersonPayCell([CanonicalReportPayLine(isPaye: true, pay: 0)])?.label,
            "PAYE"
        )
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

    // MARK: - Booking identity (web #189)

    func testCompletedBookingsCoverTheDayAndCancelledDoNot() {
        XCTAssertTrue(BookingStatus.confirmed.occupiesDay)
        XCTAssertTrue(BookingStatus.tentative.occupiesDay)
        XCTAssertTrue(BookingStatus.completed.occupiesDay, "a worked day is booked, as on web (bookingOccupiesDay)")
        XCTAssertFalse(BookingStatus.cancelled.occupiesDay)
    }

    func testBookingUnderAFormerInvitePlaceholderIdStillCoversThePerson() throws {
        let placeholder = "6C1F2E7A-1111-4222-8333-944455556666"
        var user = person()
        user.formerUserIds = [placeholder]
        let booking = try XCTUnwrap(parsed([
            (id: UUID().uuidString, data: [
                "operativeId": placeholder,
                "projectId": projectId,
                "date": dayTimestamp,
                "timeSlot": "FULL DAY",
                "status": "Confirmed",
                "bookedBy": "admin@site.test",
            ]),
        ]).first)
        XCTAssertEqual(rowsOnDay([booking], users: [user]).count, 0)
        var withoutFormer = user
        withoutFormer.formerUserIds = []
        XCTAssertEqual(rowsOnDay([booking], users: [withoutFormer]).count, 1)
        XCTAssertEqual(rosterNameForLabourBooking(operativeId: booking.operativeId, operatives: [], users: [user]), "Pat Login")
    }

    func testFormerIdsReadAndMigrateThroughTheRulebook() {
        XCTAssertEqual(CanonicalBusinessEngine.parseFormerUserIds(["formerUserIds": [" A ", "", "A", "B"]]), ["A", "B"])
        XCTAssertEqual(
            CanonicalBusinessEngine.inviteMigrationFormerIdWriteFields(placeholderId: "P1", authUid: uid, existingFormerIds: ["P0"]),
            ["formerUserIds": ["P0", "P1"]]
        )
    }

    func testABookableUserWithAFirebaseUidIsSavedUnderThatUid() {
        let id = StableBookingIdentity.uuid(for: uid)
        XCTAssertEqual(StableBookingIdentity.rawId(for: id), uid)
        let booking = LogicFixtures.booking(on: londonDay, operativeId: id)
        XCTAssertEqual(booking.operativeKey, uid, "a booking made on iOS for this person stores users/{uid}, as web does")
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

    // MARK: - Clash groups (overlappingIntervalGroups)

    func testClashGroupsChainAndBackToBackIsNotAClash() {
        let am = CanonicalMinuteInterval(start: 450, end: 720)
        let pm = CanonicalMinuteInterval(start: 720, end: 960)
        let middle = CanonicalMinuteInterval(start: 660, end: 780)
        XCTAssertEqual(CanonicalBusinessEngine.overlappingIntervalGroups([am, pm]), [])
        XCTAssertEqual(CanonicalBusinessEngine.overlappingIntervalGroups([am, pm, middle]), [[0, 1, 2]])
        XCTAssertEqual(CanonicalBusinessEngine.overlappingIntervalGroups([am, nil, middle]), [[0, 2]])
    }
}
