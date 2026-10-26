import XCTest
@testable import Project_Planner

/// One booking identity with web #189: string operative ids, `bookingOccupiesDay`, `labourBookingKind`,
/// `formerIdAliases`, and `parseFormerUserIds`, called through `CanonicalBusinessEngine`.
@MainActor
final class BookingIdentityTests: XCTestCase {
    private let authUid = "rehiredOperativeUid0001"
    private let placeholderId = "7A27FFF5-65FD-4563-8A0D-D074647C2739"

    private func user(
        id: String,
        email: String,
        role: UserRole = .operative,
        permissions: UserPermissions = UserPermissions(operativeMode: true),
        isActive: Bool = true,
        formerUserIds: [String] = []
    ) -> AppUser {
        var u = AppUser(
            id: id,
            email: email,
            organizationId: "ORG",
            role: role,
            firstName: "Farnie",
            surname: "Nel",
            isActive: isActive,
            passwordSet: true,
            permissions: permissions
        )
        u.formerUserIds = formerUserIds
        return u
    }

    // MARK: - Stored operative id

    func testUuidOperativeIdIsUsedAsIs() {
        let uuid = UUID()
        XCTAssertEqual(Booking.internalOperativeId(for: uuid.uuidString), uuid)
        XCTAssertEqual(Booking.storedOperativeId(for: uuid), uuid.uuidString)
    }

    func testAuthUidMapsToStableIdAndSavesBackAsTheUid() {
        let first = Booking.internalOperativeId(for: authUid)
        let second = Booking.internalOperativeId(for: " \(authUid) ")
        XCTAssertEqual(first, second)
        XCTAssertEqual(Booking.storedOperativeId(for: first), authUid)

        let booking = Booking(operativeId: first, projectId: UUID(), date: Date(), timeSlot: .fullDay, bookedBy: "Admin")
        XCTAssertNil(booking.operativeKey)
        XCTAssertEqual(booking.storedOperativeId, authUid)
    }

    func testOperativeKeyWinsWhenSet() {
        var booking = Booking(operativeId: UUID(), projectId: UUID(), date: Date(), timeSlot: .morning, bookedBy: "Admin")
        booking.operativeKey = authUid
        XCTAssertEqual(booking.storedOperativeId, authUid)
    }

    func testOlderCachedBookingWithoutOperativeKeyStillDecodes() throws {
        let original = Booking(operativeId: UUID(), projectId: UUID(), date: Date(), timeSlot: .afternoon, bookedBy: "Admin")
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as! [String: Any]
        json.removeValue(forKey: "operativeKey")
        let decoded = try JSONDecoder().decode(Booking.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(decoded.operativeId, original.operativeId)
        XCTAssertNil(decoded.operativeKey)
    }

    func testCachedBookingRegistersItsStoredIdBeforeTheServerAnswers() throws {
        // A uid this process has never seen: the saved copy is the first place it appears.
        let cachedUid = "cachedOnlyUid\(UUID().uuidString.prefix(8))"
        let derived = OperativeKeyRegistry.derivedUUID(for: cachedUid)
        var saved = Booking(operativeId: derived, projectId: UUID(), date: Date(), timeSlot: .fullDay, bookedBy: "Admin")
        saved.operativeKey = cachedUid
        let data = try JSONEncoder().encode([saved])

        let loaded = try JSONDecoder().decode([Booking].self, from: data)
        XCTAssertEqual(Booking.storedOperativeId(for: derived), derived.uuidString)

        Booking.registerStoredOperativeKeys(loaded)
        XCTAssertEqual(Booking.storedOperativeId(for: derived), cachedUid)
    }

    // MARK: - Rulebook wrappers

    func testBookingOccupiesDayMatchesTheScript() {
        XCTAssertEqual(CanonicalBusinessEngine.bookingOccupiesDay(BookingStatus.confirmed.rawValue), true)
        XCTAssertEqual(CanonicalBusinessEngine.bookingOccupiesDay(BookingStatus.tentative.rawValue), true)
        XCTAssertEqual(CanonicalBusinessEngine.bookingOccupiesDay(BookingStatus.completed.rawValue), true)
        XCTAssertEqual(CanonicalBusinessEngine.bookingOccupiesDay(BookingStatus.cancelled.rawValue), false)
    }

    func testLabourBookingKind() {
        XCTAssertEqual(ScheduleBookablePersonBuilder.labourKind(user(id: authUid, email: "op@test.com")), "operative")
        XCTAssertEqual(
            ScheduleBookablePersonBuilder.labourKind(user(id: "m", email: "m@test.com", role: .manager, permissions: UserPermissions(manager: true))),
            "manager"
        )
        XCTAssertNil(ScheduleBookablePersonBuilder.labourKind(user(id: "x", email: "x@test.com", isActive: false)))
        XCTAssertNil(
            ScheduleBookablePersonBuilder.labourKind(user(id: "n", email: "n@test.com", role: .basic, permissions: UserPermissions()))
        )
    }

    func testFormerIdAliasesPointAtTheCurrentAccount() {
        let aliases = CanonicalBusinessEngine.formerIdAliases([
            CanonicalFormerIdPerson(id: authUid, formerIds: [placeholderId])
        ])
        XCTAssertEqual(aliases?[placeholderId], authUid)
    }

    func testParseFormerUserIdsKeepsTrimmedUniqueStrings() {
        let parsed = CanonicalBusinessEngine.parseFormerUserIds([" \(placeholderId) ", placeholderId, 7, ""] as [Any])
        XCTAssertEqual(parsed, [placeholderId])
        XCTAssertEqual(CanonicalBusinessEngine.parseFormerUserIds(nil), [])
    }

    // MARK: - Screens

    func testPickerListsAnOperativeWhoseIdIsAnAuthUid() {
        let rehired = user(id: authUid, email: "rehired@test.com")
        let rows = ScheduleBookablePersonBuilder.operativesForScheduling(operatives: [], users: [rehired])
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first.map { Booking.storedOperativeId(for: $0.id) }, authUid)
    }

    func testBookingUnderTheOldPlaceholderNamesTheCurrentAccount() {
        let rehired = user(id: authUid, email: "rehired@test.com", formerUserIds: [placeholderId])
        let name = rosterNameForLabourBooking(
            operativeId: Booking.internalOperativeId(for: placeholderId),
            operatives: [],
            users: [rehired]
        )
        XCTAssertEqual(name, "Farnie Nel")
    }

    func testUnmatchedBookingShowsUnknownPerson() {
        let name = rosterNameForLabourBooking(
            operativeId: Booking.internalOperativeId(for: "nobodyAuthUid0000000000000"),
            operatives: [],
            users: []
        )
        XCTAssertEqual(name, unknownLabourPersonName)
    }
}
