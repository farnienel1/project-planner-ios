import XCTest
@testable import Project_Planner

/// Rulebook 1.5.0 (§1 "Document readers", §9): `holidayBookings` documents are read only through the packed
/// `parseHolidayDocuments`, the way `FirebaseBackend.loadHolidayBookings` reads them, and the parsed ids and
/// organisation-zone day keys go to warnings and Daily Overview unchanged. Web locks the same reader in
/// `lib/canonical/canonical.test.ts`.
@MainActor
final class HolidayDocumentReaderTests: XCTestCase {
    /// Other tests set a signed-in viewer on the shared `JobAccessContext`; these check the unscoped rules, so start
    /// with no viewer (an admin-wide scope), as a device does before the profile loads.
    nonisolated override func setUp() {
        super.setUp()
        JobAccessContext.updateViewer(nil)
    }

    private let dayKey = "2026-10-27" // a Tuesday
    private let adminId = "ADMIN-ABC"

    private var day: Date {
        CanonicalBusinessEngine.date(fromDayKey: dayKey)!
    }

    private var admin: AppUser {
        AppUser(
            id: adminId,
            email: "ada@site.test",
            organizationId: "org-test",
            role: .admin,
            firstName: "Ada",
            surname: "Admin",
            isActive: true,
            passwordSet: true,
            permissions: UserPermissions(adminAccess: true)
        )
    }

    /// Stored documents read the way `FirebaseBackend.loadHolidayBookings` reads them.
    private func read(_ documents: [(id: String, data: [String: Any])]) -> [HolidayBooking] {
        FirebaseBackend.holidayBookings(fromDocuments: documents, organizationId: "org-test")
    }

    /// A record as web writes it: a document id that is not a UUID, a lower-case `userId` and an
    /// `operativeId` that is not a UUID.
    private var webRecord: (id: String, data: [String: Any]) {
        (id: "web-leave-1", data: [
            "userId": "admin-abc",
            "operativeId": "op-not-a-uuid",
            "startDate": dayKey,
            "endDate": dayKey,
            "status": "Approved",
            "timeSlot": "FULL DAY",
        ])
    }

    func testTheScriptAnswersTheHolidayReader() throws {
        let parsed = try XCTUnwrap(CanonicalBusinessEngine.parseHolidayDocuments([webRecord]), "the packed script did not run")
        XCTAssertEqual(parsed.count, 1)
        XCTAssertEqual(parsed.first?.id, "web-leave-1")
        XCTAssertEqual(parsed.first?.startDayKey, dayKey)
    }

    func testAWebRecordKeepsItsDocumentIdAndStoredIds() throws {
        let leave = try XCTUnwrap(read([webRecord]).first)
        XCTAssertEqual(leave.documentId, "web-leave-1")
        XCTAssertEqual(leave.id, Manager.stableId(forFirestoreDocumentId: "web-leave-1"))
        XCTAssertEqual(leave.userId, "admin-abc")
        XCTAssertEqual(leave.operativeIdRaw, "op-not-a-uuid", "a non-UUID operativeId is kept, never dropped")
        XCTAssertNil(leave.operativeId)
        XCTAssertTrue(leave.isOperativeRequest)
        XCTAssertEqual(leave.startDayKey, dayKey)
        XCTAssertEqual(leave.endDayKey, dayKey)
        XCTAssertEqual(leave.status, .approved)
        XCTAssertEqual(leave.organizationId, "org-test")
    }

    func testAnIosRecordKeepsItsUpperCaseUuidDocumentId() throws {
        let uuid = "A1B2C3D4-0000-0000-0000-000000000001"
        let leave = try XCTUnwrap(read([(id: uuid, data: ["userId": adminId, "startDate": dayKey])]).first)
        XCTAssertEqual(leave.documentId, uuid)
        XCTAssertEqual(leave.id.uuidString, uuid)
    }

    /// The regression: iOS listed an admin on approved leave as unbooked, because the record's lower-case
    /// `userId` did not match the upper-case roster id. Warnings (`unbookedLabourRows`) through the iOS path.
    func testWebLeaveWithLowerCaseUserIdCoversUpperCaseAdminInWarnings() {
        let leave = read([webRecord])
        XCTAssertEqual(leave.count, 1)
        XCTAssertEqual(unbookedWarnings(holidays: []).count, 1, "without leave the admin is unbooked")
        XCTAssertEqual(unbookedWarnings(holidays: leave).count, 0, "approved leave covers the admin")
    }

    /// The same record on Daily Overview (`unbookedLabourRowsOnDay`).
    func testWebLeaveWithLowerCaseUserIdCoversUpperCaseAdminOnDailyOverview() {
        let leave = read([webRecord])
        XCTAssertEqual(rowsOnDay(holidays: []).map(\.personKey), [adminId])
        XCTAssertEqual(rowsOnDay(holidays: leave).count, 0)
    }

    func testAPendingRecordDoesNotCoverTheDay() {
        var record = webRecord
        record.data["status"] = "requested"
        let leave = read([record])
        XCTAssertEqual(leave.first?.status, .pending)
        XCTAssertEqual(rowsOnDay(holidays: leave).map(\.personKey), [adminId])
    }

    /// `HOLIDAY_STATUS_SYNONYMS` / `normalizeHolidayStatus`; missing or unknown is approved.
    func testStatusSynonymsComeFromTheRulebook() {
        let cases: [(String?, HolidayStatus)] = [
            ("declined", .rejected), ("Denied", .rejected), ("cancelled", .rejected), ("canceled", .rejected),
            ("requested", .pending), ("awaiting", .pending), ("awaiting approval", .pending), ("submitted", .pending),
            ("Confirmed", .approved), ("accepted", .approved), ("approved", .approved),
            (nil, .approved), ("something else", .approved),
        ]
        for (index, entry) in cases.enumerated() {
            var data: [String: Any] = ["userId": "u-1", "startDate": dayKey]
            if let status = entry.0 { data["status"] = status }
            let leave = read([(id: "leave-\(index)", data: data)]).first
            XCTAssertEqual(leave?.status, entry.1, "status \(entry.0 ?? "missing")")
            XCTAssertEqual(leave?.isApproved, entry.1 == .approved)
        }
    }

    /// `normalizeHolidayTimeSlot`, the start/end key lists, a nested user id and a reversed range.
    func testSlotSynonymsKeysAndReversedRange() throws {
        let leave = try XCTUnwrap(read([(id: "legacy", data: [
            "user": ["uid": "nested-uid"],
            "from": "2026-10-30",
            "to": "28/10/2026",
            "approvalStatus": "approved",
            "slot": "morning",
        ])]).first)
        XCTAssertEqual(leave.userId, "nested-uid")
        XCTAssertEqual(leave.timeSlot, .morning)
        XCTAssertEqual(leave.startDayKey, "2026-10-28")
        XCTAssertEqual(leave.endDayKey, "2026-10-30")
    }

    func testAnUnreadableDocumentIsDroppedAndTheRestAreKept() {
        let leave = read([(id: "no-date", data: ["userId": "u-1"]), webRecord])
        XCTAssertEqual(leave.map(\.documentId), ["web-leave-1"])
    }

    /// A timestamp stored as `{ seconds, nanoseconds }` becomes the organisation-zone day.
    func testATimestampIsTheOrganisationDay() throws {
        let seconds = Int(day.timeIntervalSince1970) + 3_600
        let leave = try XCTUnwrap(read([(id: "ts", data: [
            "userId": "u-1",
            "startDate": ["seconds": seconds, "nanoseconds": 0],
        ])]).first)
        XCTAssertEqual(leave.startDayKey, dayKey)
        XCTAssertEqual(leave.endDayKey, dayKey)
    }

    /// Moving a draft's dates keeps its day keys in step (they feed `leaveRecordDayKeys` and the scans).
    func testEditingADateUpdatesItsDayKey() {
        var leave = HolidayBooking(organizationId: "org-test", userId: "u-1", startDate: day, endDate: day)
        XCTAssertEqual(leave.documentId, leave.id.uuidString)
        leave.endDate = CanonicalBusinessEngine.date(fromDayKey: "2026-10-29")!
        XCTAssertEqual(leave.startDayKey, dayKey)
        XCTAssertEqual(leave.endDayKey, "2026-10-29")
    }

    // MARK: - Helpers

    private func unbookedWarnings(holidays: [HolidayBooking]) -> [Warning] {
        let input = WarningsComputationInput(
            operatives: [],
            bookings: [],
            projects: [],
            users: [admin],
            managerSiteBookings: [],
            holidayBookings: holidays,
            payrollTimePolicy: .default,
            warningDetection: .default,
            coverageStart: day,
            coverageEnd: day,
            materialOrderCutOffEnabled: false,
            materialCutOffOnSaturday: false,
            materialCutOffOnSunday: false,
            projectsWithTomorrowBookings: [],
            materialItemsForTomorrow: []
        )
        return WarningsComputation.generate(WarningsComputation.makeSnapshot(from: input))
            .filter { $0.type == .unbookedLabour }
    }

    private func rowsOnDay(holidays: [HolidayBooking]) -> [CanonicalUnbookedLabourRow] {
        WarningsComputation.unbookedLabourRowsOnDay(
            day: day,
            users: [admin],
            operatives: [],
            operativeBookings: [],
            managerBookings: [],
            holidays: holidays,
            policy: .default,
            includeWeekends: false,
            excludedUserIds: []
        )
    }
}
