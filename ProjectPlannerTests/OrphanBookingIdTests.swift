import XCTest
@testable import Project_Planner

/// Three paths that could leave a booking under an id no person resolves to ("Unknown person" in Data health):
/// (1) `OperativeStore.addOperative` kept a row the server never stored; (2) `ensureOperativeProfileForAppUser` and the
/// My Qualifications "Repair link now" created rows from a cache copy or an operative's phone, or re-linked by name;
/// (3) `Booking.storedOperativeId(for:)` fell back to an internal derived UUID.
@MainActor
final class OrphanBookingIdTests: XCTestCase {
    private struct TestError: LocalizedError { var errorDescription: String? { "TEST-refused" } }

    private func user(
        id: String,
        email: String,
        role: UserRole = .operative,
        permissions: UserPermissions = UserPermissions(operativeMode: true),
        first: String = "TEST-Farnie",
        last: String = "Nel"
    ) -> AppUser {
        AppUser(
            id: id,
            email: email,
            organizationId: "TEST-ORG",
            role: role,
            firstName: first,
            surname: last,
            isActive: true,
            passwordSet: true,
            permissions: permissions
        )
    }

    private func operativeRow(email: String, first: String = "TEST-Farnie", last: String = "Nel") -> Operative {
        Operative(firstName: first, lastName: last, email: email, startDate: Date())
    }

    // MARK: (1) addOperative keeps nothing the server did not confirm

    func testAddOperativeLeavesNothingWhenTheSaveFails() async {
        let store = OperativeStore()
        let row = operativeRow(email: "test-fail@example.test")
        let added = await store.addOperative(row, isOnline: true) { _ in .failure(TestError()) }
        XCTAssertFalse(added)
        XCTAssertFalse(store.operatives.contains { $0.id == row.id }, "a refused create is never bookable")
        XCTAssertEqual(store.errorMessage, OperativeStore.addOperativeFailedMessage(TestError()))
    }

    func testAddOperativeIsRefusedOfflineAndNeverQueued() async {
        let store = OperativeStore()
        let row = operativeRow(email: "test-offline@example.test")
        var persisted = false
        let added = await store.addOperative(row, isOnline: false) { _ in persisted = true; return .success(()) }
        XCTAssertFalse(added)
        XCTAssertFalse(persisted, "online only (RULEBOOK §2 users.invites): nothing written or queued")
        XCTAssertFalse(store.operatives.contains { $0.id == row.id })
        XCTAssertNotNil(store.errorMessage)
    }

    func testAddOperativeJoinsTheListOnlyAfterTheServerConfirms() async {
        let store = OperativeStore()
        let row = operativeRow(email: "test-ok@example.test")
        var listedDuringSave = true
        let added = await store.addOperative(row, isOnline: true) { _ in
            listedDuringSave = store.operatives.contains { $0.id == row.id }
            return .success(())
        }
        XCTAssertTrue(added)
        XCTAssertFalse(listedDuringSave, "not bookable while the create is unconfirmed")
        XCTAssertTrue(store.operatives.contains { $0.id == row.id })
        XCTAssertNil(store.errorMessage)
    }

    // MARK: (2) operatives rows are created only by staff, from a server list, matched by ids and email

    func testExistingRowIsMatchedByEmailNotByName() {
        let subject = user(id: "TEST-UID-1", email: "Person@Example.test")
        let byEmail = operativeRow(email: "person@example.test", first: "Other", last: "Name")
        let byName = operativeRow(email: "someone.else@example.test")
        let decision = OperativeProfileLinkPolicy.decide(
            subject: subject, actorLevel: .admin, operatives: [byName, byEmail],
            bookingIds: OperativeProfileLinkPolicy.bookingIds(for: subject, operatives: [byName, byEmail]),
            listConfirmedByServer: true
        )
        XCTAssertEqual(decision, .existing(byEmail.id))
    }

    func testANameMatchAloneIsNeverTheirRow() {
        let subject = user(id: "TEST-UID-2", email: "new.person@example.test")
        let sameName = operativeRow(email: "drifted@example.test")
        XCTAssertNil(OperativeProfileLinkPolicy.existingRow(for: subject, in: [sameName], bookingIds: ["TEST-UID-2", "new.person@example.test"]))
    }

    func testNoRowIsCreatedFromACacheCopy() {
        let subject = user(id: "TEST-UID-3", email: "cache@example.test")
        let decision = OperativeProfileLinkPolicy.decide(
            subject: subject, actorLevel: .admin, operatives: [], bookingIds: ["TEST-UID-3"], listConfirmedByServer: false
        )
        XCTAssertEqual(decision, .refuseListNotLoaded)
    }

    func testAnOperativeAccountNeverCreatesOrLinksARow() {
        let subject = user(id: "TEST-UID-4", email: "op@example.test")
        let decision = OperativeProfileLinkPolicy.decide(
            subject: subject, actorLevel: .operative, operatives: [], bookingIds: ["TEST-UID-4"], listConfirmedByServer: true
        )
        XCTAssertEqual(decision, .refuseNotStaff)
        XCTAssertEqual(
            OperativeProfileLinkPolicy.decide(subject: subject, actorLevel: nil, operatives: [], bookingIds: ["TEST-UID-4"], listConfirmedByServer: true),
            .refuseNotStaff,
            "an unknown actor creates nothing"
        )
    }

    func testStaffCreateOnlyWhenTheServerListHasNoRow() {
        let subject = user(id: "TEST-UID-5", email: "missing@example.test")
        let decision = OperativeProfileLinkPolicy.decide(
            subject: subject, actorLevel: .manager, operatives: [operativeRow(email: "other@example.test")],
            bookingIds: ["TEST-UID-5"], listConfirmedByServer: true
        )
        XCTAssertEqual(decision, .create)
        XCTAssertEqual(
            OperativeProfileLinkPolicy.decide(subject: subject, actorLevel: .manager, operatives: [], bookingIds: nil, listConfirmedByServer: true),
            .refuseCannotMatch,
            "no rulebook answer: nothing is guessed"
        )
    }

    func testServerSnapshotFlagFollowsTheOrganisation() {
        let store = OperativeStore()
        XCTAssertNil(store.operativesServerSnapshotOrganizationId)
        store.markOperativesServerSnapshot(organizationId: "TEST-ORG")
        XCTAssertEqual(store.operativesServerSnapshotOrganizationId, "TEST-ORG")
        store.discardInMemoryForOrganizationSwitch()
        XCTAssertNil(store.operativesServerSnapshotOrganizationId, "a company switch needs a new server answer")
        XCTAssertFalse(store.operativesConfirmedByServer, "no organisation open: never confirmed")
    }

    func testMyQualificationsHasNoAutomaticRepair() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Project Planner/Views/HomeView.swift")
        let source = try String(contentsOf: url, encoding: .utf8)
        XCTAssertFalse(source.contains("repairOperativeLinkIfNeeded"))
        XCTAssertFalse(source.contains("Repair link now"))
    }

    // MARK: (3) no derived id is ever written

    func testUnrememberedDerivedIdHasNoStoredId() {
        let derived = OperativeKeyRegistry.derivedUUID(for: "TEST-never-registered-\(UUID().uuidString)")
        XCTAssertTrue(OperativeKeyRegistry.isDerived(derived))
        XCTAssertNil(Booking.storedOperativeId(for: derived))
        XCTAssertEqual(Booking.operativeMatchKey(for: derived), derived.uuidString, "reading only: matches no stored id")
    }

    func testRealAndRegisteredIdsStillResolve() {
        let uuid = UUID()
        XCTAssertFalse(OperativeKeyRegistry.isDerived(uuid))
        XCTAssertEqual(Booking.storedOperativeId(for: uuid), uuid.uuidString)
        let mapped = Booking.internalOperativeId(for: "TEST-uid-orphan-1")
        XCTAssertEqual(Booking.storedOperativeId(for: mapped), "TEST-uid-orphan-1")
        // A stored id that is itself version-5 shaped is remembered as stored.
        let v5 = OperativeKeyRegistry.derivedUUID(for: "TEST-v5-\(UUID().uuidString)")
        let read = Booking.internalOperativeId(for: v5.uuidString.lowercased())
        XCTAssertEqual(Booking.storedOperativeId(for: read), v5.uuidString.lowercased())
    }

    func testBookingWithAnUnresolvedPersonIsRefused() {
        let derived = OperativeKeyRegistry.derivedUUID(for: "TEST-lost-\(UUID().uuidString)")
        let booking = Booking(operativeId: derived, projectId: UUID(), date: Date(), timeSlot: .fullDay, bookedBy: "TEST-Admin")
        XCTAssertNil(booking.writableOperativeId)
        XCTAssertEqual(BookingPersonResolution.refusal([booking]), BookingPersonResolution.unresolvedMessage)
        XCTAssertNil(BookingWritePatch.labourValues(booking, deletesClearedFields: false)["operativeId"], "never written")

        var keyed = booking
        keyed.operativeKey = "TEST-stored-uid"
        XCTAssertNil(BookingPersonResolution.refusal([keyed]), "a booking read from Firestore keeps its stored id")
        XCTAssertEqual(BookingWritePatch.labourValues(keyed, deletesClearedFields: false)["operativeId"] as? String, "TEST-stored-uid")
    }

    func testBookingStoreRefusesAnUnresolvedPersonBeforeAnythingIsAdded() async {
        let store = BookingStore()
        let derived = OperativeKeyRegistry.derivedUUID(for: "TEST-lost-store-\(UUID().uuidString)")
        let booking = Booking(operativeId: derived, projectId: UUID(), date: Date(), timeSlot: .fullDay, bookedBy: "TEST-Admin")
        let result = await store.addBookingsReportingProblem([booking])
        XCTAssertFalse(store.bookings.contains { $0.id == booking.id }, "nothing appended or queued")
        // `writeRefusal` (job access) may answer first; either way the booking is refused, never saved or queued.
        guard case .refused = result[booking.id] else { return XCTFail("expected a refusal, got \(String(describing: result[booking.id]))") }
    }
}
