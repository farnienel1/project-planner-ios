import FirebaseFirestore
import XCTest
@testable import Project_Planner

/// Bookings read and owned the same way on web and iOS: `parseBookingDocument`, `parseManagerSiteBookingDocument`,
/// `bookingIdsForAccount`, `resolveBookingPerson` and `bookingPersonKey`, called through `CanonicalBusinessEngine`.
/// The person here was deleted and re-added: one booking under the old catalogue row, one under the old invite id,
/// one under the new Firebase Auth uid.
@MainActor
final class BookingAuditTests: XCTestCase {
    private let oldCatalogueId = UUID(uuidString: "F05FE02E-0F7C-4F44-A3A8-FCF6F43D2995")!
    private let placeholderId = "7A27FFF5-65FD-4563-8A0D-D074647C2739"
    private let authUid = "rehiredOperativeUid0001"
    private let email = "rehired@example.com"
    private let thursday = LogicFixtures.day(2026, 10, 8, hour: 8)

    private func rehiredUser() -> AppUser {
        var user = LogicFixtures.selfEmployedUser(id: authUid, email: email, dayRate: 200)
        user.formerUserIds = [placeholderId]
        return user
    }

    private func document(_ id: String, _ data: [String: Any]) -> [String: Any] {
        ["id": id, "data": FirebaseBackend.firestoreJSON(data)]
    }

    // MARK: - Reading documents

    func testLowercaseStatusSlotAliasAndUidStillLoad() throws {
        let projectId = UUID()
        let parsed = try XCTUnwrap(CanonicalBusinessEngine.parseBookingDocuments([
            document(UUID().uuidString, [
                "operativeId": authUid,
                "projectId": projectId.uuidString,
                "date": Timestamp(date: thursday),
                "timeSlot": "morning",
                "status": "confirmed",
                "bookedBy": "Admin",
            ]),
            document("no-project", ["operativeId": authUid, "date": Timestamp(date: thursday), "timeSlot": "AM", "status": "Confirmed"]),
        ]))
        XCTAssertEqual(parsed.count, 1, "a document the rulebook refuses is left out, as on web")

        let booking = try XCTUnwrap(FirebaseBackend.booking(fromCanonical: parsed[0]))
        XCTAssertEqual(booking.status, .confirmed)
        XCTAssertEqual(booking.timeSlot, .morning)
        XCTAssertEqual(booking.projectId, projectId)
        XCTAssertEqual(booking.date.timeIntervalSince1970, thursday.timeIntervalSince1970, accuracy: 0.001)
        XCTAssertEqual(booking.storedOperativeId, authUid)
        XCTAssertEqual(booking.operativeId, Booking.internalOperativeId(for: authUid))
    }

    func testTentativeAndTextDateLoad() throws {
        let parsed = try XCTUnwrap(CanonicalBusinessEngine.parseBookingDocuments([
            document("B-1", [
                "operativeId": oldCatalogueId.uuidString,
                "projectId": UUID().uuidString,
                "date": "2026-10-08T00:00:00Z",
                "timeSlot": "FULL_DAY",
                "status": "tentative",
                "bookedBy": "Admin",
            ]),
        ]))
        let booking = try XCTUnwrap(parsed.first.flatMap(FirebaseBackend.booking(fromCanonical:)))
        XCTAssertEqual(booking.status, .tentative)
        XCTAssertEqual(booking.timeSlot, .fullDay)
        // A document id that is not a UUID keeps one id across reads.
        XCTAssertEqual(booking.id, FirebaseBackend.booking(fromCanonical: parsed[0])?.id)
    }

    func testManagerBookingWithoutLocationTypeLoadsAsProject() throws {
        let parsed = try XCTUnwrap(CanonicalBusinessEngine.parseManagerSiteBookingDocuments([
            document(UUID().uuidString, ["userId": authUid, "date": Timestamp(date: thursday), "timeSlot": "FULL DAY"]),
            document(UUID().uuidString, ["date": Timestamp(date: thursday), "timeSlot": "AM"]),
        ]))
        XCTAssertEqual(parsed.count, 1)
        XCTAssertEqual(parsed[0].locationType, "project")
        XCTAssertEqual(ManagerTimeSlot.fromStored(parsed[0].timeSlot), .fullDay)
    }

    // MARK: - Whose booking is it

    func testBookingOccupiesDayFollowsTheRulebook() {
        XCTAssertTrue(BookingStatus.confirmed.occupiesDay)
        XCTAssertTrue(BookingStatus.tentative.occupiesDay)
        XCTAssertTrue(BookingStatus.completed.occupiesDay)
        XCTAssertFalse(BookingStatus.cancelled.occupiesDay)
    }

    func testReAddedPersonOwnsBookingsUnderEveryId() {
        let ids = labourBookingIds(
            for: rehiredUser(),
            operatives: [LogicFixtures.operative(id: oldCatalogueId, email: "Rehired@Example.com")]
        )
        XCTAssertTrue(ids.contains(oldCatalogueId))
        XCTAssertTrue(ids.contains(UUID(uuidString: placeholderId)!))
        XCTAssertTrue(ids.contains(Booking.internalOperativeId(for: authUid)))
    }

    func testBookingUnderUidWithNoCatalogueRowFindsTheAccount() {
        let people = LabourBookingPeople(operatives: [], users: [rehiredUser()])
        XCTAssertEqual(people.person(for: Booking.internalOperativeId(for: authUid)).user?.id, authUid)
        XCTAssertEqual(people.person(for: UUID(uuidString: placeholderId)!).user?.id, authUid)
        XCTAssertNil(people.person(for: UUID()).user)
    }

    func testOldAndNewIdsShareOneClashKey() {
        let user = rehiredUser()
        let snapshot = WarningsComputationSnapshot.UserSnapshot(
            id: user.id,
            emailLowercased: email,
            displayName: "Ada Lovelace",
            isActive: true,
            passwordSet: true,
            createdAt: thursday,
            isOperativeMode: true,
            isManager: false,
            hasAdminAccess: false,
            isSuperAdmin: false,
            isAdminRole: false,
            formerUserIds: [placeholderId]
        )
        let catalogue = WarningsComputationSnapshot.OperativeSnapshot(
            id: oldCatalogueId, name: "Ada Lovelace", emailLowercased: email, isActive: true, qualificationExpiries: []
        )
        let people = WarningsBookingPeople(users: [snapshot], operatives: [catalogue])
        let key = people.key(for: Booking.internalOperativeId(for: authUid))
        XCTAssertEqual(people.key(for: oldCatalogueId), key)
        XCTAssertEqual(people.key(for: UUID(uuidString: placeholderId)!), key)
        XCTAssertNotEqual(people.key(for: UUID()), key)
        XCTAssertEqual(people.currentAccountId(forStoredUserId: placeholderId), authUid)
    }

    // MARK: - Screens

    func testTimesheetPaysEveryBookedDayOnce() {
        let user = rehiredUser()
        let catalogue = LogicFixtures.operative(id: oldCatalogueId, email: email)
        let friday = LogicFixtures.day(2026, 10, 9, hour: 8)
        let monday = LogicFixtures.day(2026, 10, 12, hour: 8)
        let tuesday = LogicFixtures.day(2026, 10, 13, hour: 8)
        let bookings = [
            LogicFixtures.booking(on: thursday, operativeId: oldCatalogueId),
            LogicFixtures.booking(on: friday, operativeId: UUID(uuidString: placeholderId)!),
            LogicFixtures.booking(on: monday, status: .completed, operativeId: Booking.internalOperativeId(for: authUid)),
            LogicFixtures.booking(on: tuesday, status: .cancelled, operativeId: Booking.internalOperativeId(for: authUid)),
            // The same day under two of the person's ids is one paid day, not two.
            LogicFixtures.booking(on: thursday, operativeId: Booking.internalOperativeId(for: authUid)),
        ]
        let summary = TimesheetPayrollCollector.collect(
            for: user,
            in: thursday...tuesday,
            bookings: bookings,
            managerBookings: [],
            operatives: [catalogue],
            projects: [],
            smallWorks: [],
            history: .empty,
            policy: LogicFixtures.policy,
            relatedUsers: [user]
        )
        XCTAssertEqual(summary.shiftCount, 3)
    }

    func testManagerBookingUnderFormerIdIsPaid() {
        let user = rehiredUser()
        let summary = TimesheetPayrollCollector.collect(
            for: user,
            in: thursday...thursday,
            bookings: [],
            managerBookings: [ManagerSiteBooking(userId: placeholderId, date: thursday, timeSlot: .fullDay, locationType: .project, locationId: UUID())],
            operatives: [],
            projects: [],
            smallWorks: [],
            history: .empty,
            policy: LogicFixtures.policy,
            relatedUsers: [user]
        )
        XCTAssertEqual(summary.shiftCount, 1)
    }

    func testBookLabourPersonOwnsUidAndFormerIdBookings() {
        let user = rehiredUser()
        let project = UUID()
        let people = ScheduleBookablePersonBuilder.build(
            operatives: [],
            users: [user],
            projectId: project,
            bookings: [LogicFixtures.booking(on: thursday, operativeId: oldCatalogueId, projectId: project)]
        )
        let person = try? XCTUnwrap(people.first { $0.userId == authUid })
        XCTAssertNotNil(person)
        // No catalogue row in the roster: the uid and the former invite id are still this person's.
        XCTAssertTrue(person?.owns(LogicFixtures.booking(on: thursday, operativeId: UUID(uuidString: placeholderId)!)) ?? false)
        XCTAssertTrue(person?.owns(LogicFixtures.booking(on: thursday, operativeId: Booking.internalOperativeId(for: authUid))) ?? false)
    }

    // MARK: - Deleting and placeholders

    func testDeletingAPersonKeepsTheirPastBookings() {
        let store = BookingStore()
        let today = Date()
        let lastWeek = Calendar.current.date(byAdding: .day, value: -7, to: today)!
        let nextWeek = Calendar.current.date(byAdding: .day, value: 7, to: today)!
        let uid = Booking.internalOperativeId(for: authUid)
        let past = LogicFixtures.booking(on: lastWeek, operativeId: oldCatalogueId)
        let future = LogicFixtures.booking(on: nextWeek, operativeId: oldCatalogueId)
        let futureUnderUid = LogicFixtures.booking(on: nextWeek, operativeId: uid)
        let someoneElse = LogicFixtures.booking(on: nextWeek, operativeId: UUID())
        store.bookings = [past, future, futureUnderUid, someoneElse]
        let removed = Set(store.bookingsToRemoveOnPersonDelete(personIds: [oldCatalogueId, uid], now: today).map(\.id))
        XCTAssertEqual(removed, [future.id, futureUnderUid.id])
    }

    func testSetupPlaceholderBookingIsNotABooking() throws {
        let parsed = try XCTUnwrap(CanonicalBusinessEngine.parseBookingDocuments([
            document("INITIAL-PLACEHOLDER", [
                "operativeId": oldCatalogueId.uuidString,
                "projectId": UUID().uuidString,
                "date": Timestamp(date: thursday),
                "timeSlot": "morning",
                "status": "tentative",
            ]),
        ]))
        XCTAssertTrue(parsed.isEmpty)
    }

    func testMyScheduleSeesBookingsUnderUidAndFormerIdWithNoCatalogueRow() {
        let user = rehiredUser()
        let ids = WorkAccess.signedInOperativeIds(
            email: user.email, firstName: user.firstName, surname: user.surname, operatives: [], users: [user]
        )
        XCTAssertTrue(ids.contains(Booking.internalOperativeId(for: authUid)))
        XCTAssertTrue(ids.contains(UUID(uuidString: placeholderId)!))
        XCTAssertTrue(WorkAccess.signedInAccountIds(authUid: authUid, currentUser: user, organizationUsers: [user]).contains(placeholderId))
    }

    func testPickingTheOldCatalogueRowFindsBookingsUnderTheNewUid() {
        let ids = labourBookingIds(
            sameAs: oldCatalogueId,
            operatives: [LogicFixtures.operative(id: oldCatalogueId, email: email)],
            users: [rehiredUser()]
        )
        XCTAssertEqual(ids, [oldCatalogueId, Booking.internalOperativeId(for: authUid), UUID(uuidString: placeholderId)!])
        XCTAssertEqual(labourBookingIds(sameAs: UUID(uuidString: placeholderId)!, operatives: [], users: [rehiredUser()]).count, 2)
    }
}
