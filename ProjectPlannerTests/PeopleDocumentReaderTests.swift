import XCTest
import FirebaseFirestore
@testable import Project_Planner

/// Rulebook 1.6.0 (§1 "Document readers" and "Partial writes only", §8, §11): the people collections are read only
/// through the packed readers (`parseUserDocument`, `parseOperativeDocument`, `parseManagerDocument`,
/// `parsePayRateHistoryDocuments`, `parseClientDocument`) and saved with `userProfileWriteFields` and its siblings.
/// Web locks the same functions in `lib/canonical/canonical.test.ts`. Expected values were checked with Node against
/// the packed `canonical-business.js` (pack c634b3b9…).
@MainActor
final class PeopleDocumentReaderTests: XCTestCase {
    private let leaveDefaults = OrganizationAnnualLeaveDefaults(daysPerYear: 28, startMonth: 4, endMonth: 3, carriesOver: true)

    /// The same person as iOS writes them: upper-case UUID id, current keys, a Timestamp.
    private var iosUser: [String: Any] {
        [
            "email": "Ada@Site.test",
            "firstName": "Ada",
            "surname": "Lovelace",
            "role": "operative",
            "operativeMode": true,
            "employmentType": "self_employed",
            "organizationId": "org-1",
            "assignedManagerUserIds": ["MGR-1"],
            "payBasis": "hourly",
            "hourlyRate": 18,
            "createdAt": Timestamp(seconds: 1_700_000_000, nanoseconds: 0),
        ]
    }

    /// The same person as web (and older builds) wrote them: lower-case id, legacy keys, text values.
    private var webUser: [String: Any] {
        [
            "email": "Ada@Site.test",
            "name": "Ada Lovelace",
            "role": "Operative",
            "permissions": ["operativeMode": "true"],
            "employmentType": "selfEmployed",
            "organizationId": "org-1",
            "assignedManagerUserId": "MGR-1",
            "payBasis": "hourly",
            "hourlyRate": "18",
            "createdAt": 1_700_000_000_000,
        ]
    }

    func testTheScriptAnswersThePeopleReaders() throws {
        let row = try XCTUnwrap(
            CanonicalBusinessEngine.parseUserDocument(documentId: "u-1", data: ["email": "a@b.c"], annualLeaveDefaults: nil),
            "the packed script did not run"
        )
        XCTAssertEqual(row.id, "u-1")
        XCTAssertNotNil(CanonicalBusinessEngine.parseOperativeDocument(documentId: "op", data: ["firstName": "Bo"]))
        XCTAssertNotNil(CanonicalBusinessEngine.parseClientDocument(documentId: "c", data: ["name": "Acme"]))
    }

    func testAnIosUserAndAWebUserParseIdentically() {
        let ios = FirebaseBackend.parseAppUserDocument(
            userId: "4F1C2B3A-0000-4000-8000-00000000000A", data: iosUser, annualLeaveDefaults: leaveDefaults
        )
        let web = FirebaseBackend.parseAppUserDocument(
            userId: "4f1c2b3a-0000-4000-8000-00000000000a", data: webUser, annualLeaveDefaults: leaveDefaults
        )
        // Ids keep their stored case.
        XCTAssertEqual(ios.id, "4F1C2B3A-0000-4000-8000-00000000000A")
        XCTAssertEqual(web.id, "4f1c2b3a-0000-4000-8000-00000000000a")
        for user in [ios, web] {
            XCTAssertEqual(user.email, "Ada@Site.test")
            XCTAssertEqual(user.firstName, "Ada")
            XCTAssertEqual(user.surname, "Lovelace")
            XCTAssertEqual(user.role, .operative)
            XCTAssertTrue(user.permissions.operativeMode)
            XCTAssertTrue(user.permissions.projects)
            XCTAssertTrue(user.permissions.smallWorks)
            XCTAssertFalse(user.permissions.materials)
            XCTAssertEqual(user.organizationId, "org-1")
            XCTAssertEqual(user.assignedManagerUserIds, ["MGR-1"])
            XCTAssertEqual(user.assignedManagerUserId, "MGR-1")
            XCTAssertEqual(user.payBasis, "hourly")
            XCTAssertNil(user.dayRate)
            XCTAssertEqual(user.hourlyRate, 18)
            XCTAssertEqual(user.employmentType, .selfEmployed)
            XCTAssertTrue(user.timesheetsEnabled)
            XCTAssertEqual(user.createdAt, Date(timeIntervalSince1970: 1_700_000_000))
        }
        XCTAssertEqual(ios.permissions, web.permissions)
        XCTAssertEqual(ios.annualLeaveDaysPerYear, web.annualLeaveDaysPerYear)
    }

    func testMissingLeaveFieldsTakeTheOrganisationDefaults() {
        let user = FirebaseBackend.parseAppUserDocument(userId: "u-1", data: iosUser, annualLeaveDefaults: leaveDefaults)
        XCTAssertEqual(user.annualLeaveDaysPerYear, 28)
        XCTAssertEqual(user.annualLeaveYearStartMonth, 4)
        XCTAssertEqual(user.annualLeaveYearEndMonth, 3)
        XCTAssertTrue(user.annualLeaveCarriesOver)

        var stored = iosUser
        stored["annualLeaveDaysPerYear"] = 20
        let own = FirebaseBackend.parseAppUserDocument(userId: "u-1", data: stored, annualLeaveDefaults: leaveDefaults)
        XCTAssertEqual(own.annualLeaveDaysPerYear, 20)

        let noOrganisation = FirebaseBackend.parseAppUserDocument(userId: "u-1", data: iosUser, annualLeaveDefaults: nil)
        XCTAssertEqual(noOrganisation.annualLeaveDaysPerYear, 25)
        XCTAssertEqual(noOrganisation.annualLeaveYearStartMonth, 1)
        XCTAssertEqual(noOrganisation.annualLeaveYearEndMonth, 12)
    }

    func testMissingTimesheetsFlagIsTheRulebookDefault() {
        let payeManager = FirebaseBackend.parseAppUserDocument(
            userId: "m-1",
            data: ["email": "m@site.test", "role": "manager", "manager": true, "employmentType": "paye"],
            annualLeaveDefaults: nil
        )
        XCTAssertFalse(payeManager.timesheetsEnabled)
        XCTAssertEqual(CanonicalBusinessEngine.defaultTimesheetsEnabled(operativeMode: false, employmentType: "paye"), false)
        XCTAssertEqual(CanonicalBusinessEngine.defaultTimesheetsEnabled(operativeMode: false, employmentType: "self_employed"), true)
    }

    func testAStrayOperativeModeFlagLeavesAnAdminOnTheAdminList() {
        let admin = FirebaseBackend.parseAppUserDocument(
            userId: "a-1",
            data: ["email": "a@site.test", "role": "admin", "operativeMode": true],
            annualLeaveDefaults: nil
        )
        XCTAssertEqual(admin.role, .admin)
        XCTAssertFalse(admin.permissions.operativeMode)
        XCTAssertTrue(admin.operativeModeStored)
        XCTAssertTrue(admin.appearsOnAdminsList)
        // The approval rules still read the stored flag.
        XCTAssertEqual(RulebookPeople.person(admin)["operativeMode"] as? Bool, true)
        // A save writes the stored flag back unchanged.
        XCTAssertEqual(FirebaseBackend.userDocumentPayload(admin)["operativeMode"] as? Bool, true)
    }

    func testAnHourlyOperativeStaysHourly() throws {
        let operatives = FirebaseBackend.operatives(fromDocuments: [
            (id: "op-not-a-uuid", data: ["firstName": "Bo", "lastName": "B", "payBasis": "hourly", "dayRate": 200, "hourlyRate": 20]),
        ])
        let operative = try XCTUnwrap(operatives.first)
        XCTAssertEqual(operative.payBasis, "hourly")
        XCTAssertNil(operative.dayRate)
        XCTAssertEqual(operative.hourlyRate, 20)
        XCTAssertEqual(operative.storedPayBasis, "hourly")
        XCTAssertEqual(operative.storedPayAmount, 20)
    }

    func testANonUuidOperativeIdRoundTripsToItsDocumentId() throws {
        let operatives = FirebaseBackend.operatives(fromDocuments: [
            (id: "op-not-a-uuid", data: ["firstName": "Bo", "lastName": "B"]),
            (id: "nameless", data: ["email": "only@e.mail"]),
            (id: "INITIAL-PLACEHOLDER", data: ["name": "Initial operative"]),
            (id: "empty", data: [:]),
        ])
        XCTAssertEqual(operatives.map(\.documentId), ["op-not-a-uuid", "nameless"])
        let operative = try XCTUnwrap(operatives.first)
        XCTAssertEqual(operative.id, Booking.internalOperativeId(for: "op-not-a-uuid"))
        XCTAssertEqual(Booking.storedOperativeId(for: operative.id), "op-not-a-uuid")
        // Reading twice gives the same in-app id (never random).
        XCTAssertEqual(FirebaseBackend.operatives(fromDocuments: [(id: "op-not-a-uuid", data: ["firstName": "Bo"])]).first?.id, operative.id)
    }

    func testALowerCaseUuidOperativeKeepsItsStoredCase() throws {
        let stored = "9b2e6c4a-1111-4222-8333-444455556666"
        let operative = try XCTUnwrap(FirebaseBackend.operatives(fromDocuments: [(id: stored, data: ["firstName": "Lo"])]).first)
        XCTAssertEqual(operative.id, UUID(uuidString: stored))
        XCTAssertEqual(operative.documentId, stored)
    }

    func testANonUuidClientIsKeptUnderItsDocumentId() throws {
        let clients = FirebaseBackend.clients(fromDocuments: [
            (id: "client-abc", data: ["id": "OTHER", "name": "Acme"]),
            (id: "no-name", data: ["email": "x@y.z"]),
        ])
        let client = try XCTUnwrap(clients.first)
        XCTAssertEqual(clients.count, 1)
        XCTAssertEqual(client.documentId, "client-abc")
        XCTAssertEqual(client.id, Manager.stableId(forFirestoreDocumentId: "client-abc"))
        XCTAssertEqual(client.name, "Acme")
    }

    func testANonUuidHistoryRowIsKeptWithItsStoredIds() throws {
        let history = FirebaseBackend.operativeDayRateHistory(fromDocuments: [
            (id: "hist-1", data: [
                "operativeId": "op-not-a-uuid",
                "dayRate": 20,
                "payBasis": "hourly",
                "effectiveAt": Timestamp(seconds: 1_700_000_000, nanoseconds: 0),
            ]),
            (id: "h2", data: [
                "userId": "u",
                "dayRate": NSNull(),
                "effectiveAt": Timestamp(seconds: 1_690_000_000, nanoseconds: 0),
            ]),
        ])
        let key = Booking.internalOperativeId(for: "op-not-a-uuid").uuidString
        let row = try XCTUnwrap(history.byOperativeId[key]?.first)
        XCTAssertEqual(row.documentId, "hist-1")
        XCTAssertEqual(row.operativeIdRaw, "op-not-a-uuid")
        XCTAssertEqual(row.dayRate, 20)
        XCTAssertEqual(row.payBasis, "hourly")
        let cleared = try XCTUnwrap(history.byUserId["u"]?.first)
        XCTAssertNil(cleared.dayRate)
        XCTAssertEqual(cleared.documentId, "h2")
    }

    func testUserProfileWriteFieldsWritesOnlyChangedFieldsAndNeverRemovesAnAbsentOne() throws {
        let before: [String: Any] = ["firstName": "Ada", "surname": "L", "mobileNumber": "1"]
        let unchanged = try XCTUnwrap(CanonicalBusinessEngine.peopleDocumentWrite(
            "userProfileWriteFields",
            before: before,
            next: ["firstName": "Ada", "surname": "L", "mobileNumber": "1", "profilePhotoURL": FieldValue.delete()]
        ))
        XCTAssertTrue(unchanged.isEmpty, "profilePhotoURL is not stored, so it is not removed")

        let next: [String: Any] = ["firstName": "Ada", "surname": "Lovelace", "mobileNumber": FieldValue.delete()]
        let write = try XCTUnwrap(CanonicalBusinessEngine.peopleDocumentWrite("userProfileWriteFields", before: before, next: next))
        XCTAssertEqual(Set(write.setKeys), ["firstName", "surname"])
        XCTAssertEqual(write.removeKeys, ["mobileNumber"])
        let fields = write.firestoreFields(from: next)
        XCTAssertEqual(fields["surname"] as? String, "Lovelace")
        XCTAssertTrue(fields["mobileNumber"] is FieldValue)

        let created = try XCTUnwrap(CanonicalBusinessEngine.peopleDocumentWrite(
            "userProfileWriteFields", before: before, next: ["organizationId": "org-2", "createdAt": Timestamp(date: Date())]
        ))
        XCTAssertTrue(created.isEmpty, "organizationId and createdAt are never rewritten")
    }
}
