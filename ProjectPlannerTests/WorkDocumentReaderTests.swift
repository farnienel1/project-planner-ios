import XCTest
import FirebaseFirestore
@testable import Project_Planner

/// Rulebook 1.7.0 (§1 "Document readers" and "Partial writes only", §2, §8): the work collections are read only
/// through the packed readers (`parseJobDocument`, `parseSubcontractorBookingDocument`, `parseTimesheetEntries`,
/// `parseDeadlineDocument`, `parseDeadlineAssignments` / `deadlineAssignedProjectIds`) and saved with
/// `jobWriteFields`, `bookingUpdateWriteFields`, `subcontractorBookingCreateFields` /
/// `subcontractorBookingWriteFields` and `deadlineAssignmentWriteFields`. Person and job deletes keep past bookings
/// (`bookingsToRemoveOnOperativeDelete`, `bookingsToRemoveOnProjectDelete`). Web locks the same functions in
/// `lib/canonical/canonical.test.ts`. Expected values were checked with Node against the packed
/// `canonical-business.js` (pack 7811bcff…).
@MainActor
final class WorkDocumentReaderTests: XCTestCase {
    /// 2026-11-02 00:00 UTC (= 00:00 Europe/London, GMT).
    private let monday: Int64 = 1_793_577_600
    /// 2026-10-05 09:00 UTC.
    private let createdSeconds: Int64 = 1_791_190_800

    func testTheScriptAnswersTheWorkReaders() throws {
        XCTAssertEqual(CanonicalBusinessEngine.rulebookStamp()?.version, "1.7.0")
        XCTAssertNotNil(CanonicalBusinessEngine.parseJobDocument(documentId: "j", data: [:], smallWorks: false))
        XCTAssertNotNil(CanonicalBusinessEngine.parseTimesheetEntries(sheetDocumentId: "s", sheet: [:]))
        XCTAssertEqual(CanonicalBusinessEngine.deadlineProjectKey(" abc "), "ABC")
        XCTAssertEqual(CanonicalBusinessEngine.deadlinesDocumentId(projectId: "abc", isSmallWorks: true), "deadlines_smallWorks_ABC")
    }

    // MARK: - Jobs

    /// A job web wrote: non-UUID document, client and manager ids, no start date (only `createdAt`).
    private var webJob: (id: String, data: [String: Any]) {
        (id: "web-job-1", data: [
            "jobNumber": "J1",
            "siteName": "Site",
            "client": ["id": "client-x", "name": "Acme"],
            "managerIds": ["mgr-a", "MGR-A", "mgr-b"],
            "createdAt": Timestamp(seconds: createdSeconds, nanoseconds: 0),
        ])
    }

    func testAWebJobKeepsItsStoredIdsAndStartsOnItsCreationDay() throws {
        let job = try XCTUnwrap(FirebaseBackend.jobs(fromDocuments: [webJob], smallWorks: false).first)
        XCTAssertEqual(job.documentId, "web-job-1")
        XCTAssertEqual(job.id, Manager.stableId(forFirestoreDocumentId: "web-job-1"))
        XCTAssertEqual(FirebaseBackend.jobs(fromDocuments: [webJob], smallWorks: false).first?.id, job.id, "stable, never random")
        XCTAssertEqual(job.startDate.timeIntervalSince1970, TimeInterval(createdSeconds), accuracy: 0.001)
        XCTAssertEqual(job.endDate, job.startDate)
        XCTAssertEqual(job.client.documentId, "client-x")
        XCTAssertEqual(job.managerIds.count, 2, "manager ids de-duplicated without case, none dropped")
        XCTAssertEqual(job.storedManagerIds, ["mgr-a", "mgr-b"])

        let payload = FirebaseBackend.jobDocumentPayload(job, organizationId: "org-1")
        XCTAssertEqual(payload["managerIds"] as? [String], ["mgr-a", "mgr-b"], "stored manager ids are written back unchanged")
        XCTAssertEqual(payload["managerId"] as? String, "mgr-a")
        XCTAssertEqual((payload["client"] as? [String: Any])?["id"] as? String, "client-x")
    }

    func testAnIosJobReadsAsBefore() throws {
        let id = "A1B2C3D4-0000-4000-8000-000000000001"
        let job = try XCTUnwrap(FirebaseBackend.jobs(fromDocuments: [(id: id, data: [
            "jobNumber": "J2",
            "siteName": "S2",
            "addressLine1": "1 Road",
            "townCity": "Town",
            "postcode": "AB1",
            "client": ["id": "C1", "name": "C"],
            "startDate": Timestamp(seconds: monday, nanoseconds: 0),
            "endDate": Timestamp(seconds: monday + 7 * 86_400, nanoseconds: 0),
            "managerId": "M1",
            "isLive": false,
        ])], smallWorks: false).first)
        XCTAssertEqual(job.id.uuidString, id)
        XCTAssertEqual(job.documentId, id)
        XCTAssertEqual(job.siteAddress, "1 Road, Town, AB1")
        XCTAssertFalse(job.isLive)
        XCTAssertEqual(job.managerIds.count, 1, "managerId alone is the manager list")
        XCTAssertEqual(job.endDate.timeIntervalSince(job.startDate), 7 * 86_400, accuracy: 0.001)
    }

    func testThePlaceholderJobIsSkipped() {
        XCTAssertTrue(FirebaseBackend.jobs(fromDocuments: [(id: "INITIAL-PLACEHOLDER", data: [:])], smallWorks: true).isEmpty)
    }

    func testJobWriteFieldsWritesTheManagerGroupAndNeverCreateOnlyFields() throws {
        let write = try XCTUnwrap(CanonicalBusinessEngine.peopleDocumentWrite(
            "jobWriteFields",
            before: ["siteName": "A", "managerId": "m1", "managerIds": ["m1"], "createdAt": Timestamp(seconds: 1, nanoseconds: 0)],
            next: [
                "siteName": "A",
                "managerId": "m1",
                "managerIds": ["m1", "m2"],
                "createdAt": Timestamp(seconds: 2, nanoseconds: 0),
                "customJobType": FieldValue.delete(),
            ]
        ))
        XCTAssertEqual(write.setKeys, ["managerId", "managerIds"])
        XCTAssertEqual(write.removeKeys, [], "a field the stored job lacks is never deleted")
    }

    // MARK: - Bookings

    func testABookingOnANonUuidJobIsKeptAndWritesTheJobIdBack() throws {
        let parsed = try XCTUnwrap(CanonicalBusinessEngine.parseBookingDocuments([
            ["id": "bk-1", "data": FirebaseBackend.firestoreJSON([
                "operativeId": "op-1",
                "projectId": "web-job-1",
                "date": Timestamp(seconds: monday, nanoseconds: 0),
                "timeSlot": "AM",
                "status": "Confirmed",
                "bookedBy": "x",
            ] as [String: Any])],
        ]))
        let booking = try XCTUnwrap(parsed.first.flatMap(FirebaseBackend.booking(fromCanonical:)))
        XCTAssertEqual(booking.projectId, Manager.stableId(forFirestoreDocumentId: "web-job-1"))
        XCTAssertEqual(booking.storedProjectId, "web-job-1")
        XCTAssertEqual(BookingWritePatch.labourValues(booking, deletesClearedFields: false)["projectId"] as? String, "web-job-1")
    }

    func testABookingEditNeverDeletesAFieldTheStoredCopyLacks() throws {
        var booking = Booking(
            operativeId: UUID(),
            projectId: UUID(),
            date: Date(timeIntervalSince1970: TimeInterval(monday)),
            timeSlot: .morning,
            bookedBy: "TEST-manager"
        )
        booking.status = .cancelled
        let next = BookingWritePatch.patch(
            BookingWritePatch.labourValues(booking, deletesClearedFields: true),
            fields: ["status", "notes", "workStartTime", "bookedBy"]
        )
        let write = try XCTUnwrap(CanonicalBusinessEngine.bookingUpdateWrite(
            before: ["status": "Confirmed", "timeSlot": "AM", "bookedBy": "someone else"],
            next: next
        ))
        XCTAssertEqual(write.setKeys, ["status"], "bookedBy is create-only; unchanged fields are not sent")
        XCTAssertEqual(write.removeKeys, [])
        XCTAssertTrue(try XCTUnwrap(CanonicalBusinessEngine.bookingUpdateWrite(before: nil, next: next)).isEmpty,
                      "an edit of a booking that is gone writes nothing (never a create)")
    }

    func testPersonAndJobDeletesKeepPastBookings() throws {
        let now = Date(timeIntervalSince1970: TimeInterval(monday) + 12 * 3600)
        let ids = try XCTUnwrap(CanonicalBusinessEngine.bookingsToRemoveOnOperativeDelete(
            [
                .init(id: "past", operativeId: "op", dateMs: Double(monday - 86_400) * 1000),
                .init(id: "today", operativeId: "OP", dateMs: Double(monday) * 1000),
                .init(id: "other", operativeId: "x", dateMs: Double(monday + 3 * 86_400) * 1000),
            ],
            operativeIds: ["op"],
            now: now
        ))
        XCTAssertEqual(ids, ["today"])
        let jobIds = try XCTUnwrap(CanonicalBusinessEngine.bookingsToRemoveOnProjectDelete(
            [
                (id: "past", projectId: "p", date: Date(timeIntervalSince1970: TimeInterval(monday - 86_400))),
                (id: "fut", projectId: "P", date: Date(timeIntervalSince1970: TimeInterval(monday + 2 * 86_400))),
            ],
            projectId: "p",
            now: now,
            timeZone: "Europe/London"
        ))
        XCTAssertEqual(jobIds, ["fut"])
    }

    // MARK: - Subcontractor bookings

    func testAWebCreatedSubcontractorBookingIsVisibleWithItsStoredIds() throws {
        let bookings = FirebaseBackend.subcontractorBookings(fromDocuments: [(id: "abc-web-1", data: [
            "subcontractorId": "sub-firm",
            "projectId": "job-1",
            "date": Timestamp(seconds: monday + 86_400, nanoseconds: 0),
            "bookedContactIds": ["contact-1"],
        ])])
        let booking = try XCTUnwrap(bookings.first, "web wrote no id, status or slot; it is still a booking")
        XCTAssertEqual(booking.documentId, "abc-web-1")
        XCTAssertEqual(booking.status, .confirmed)
        XCTAssertEqual(booking.timeSlot, .fullDay)
        XCTAssertEqual(booking.storedSubcontractorId, "sub-firm")
        XCTAssertEqual(booking.storedProjectId, "job-1")
        XCTAssertEqual(booking.storedContactIds, ["contact-1"])
        XCTAssertEqual(FirebaseBackend.subcontractorBookings(fromDocuments: [(id: "abc-web-1", data: [
            "subcontractorId": "sub-firm", "projectId": "job-1", "date": Timestamp(seconds: monday, nanoseconds: 0),
        ])]).first?.id, booking.id, "stable in-app id across reads")
    }

    func testSubcontractorBookingCreateAndEditFields() throws {
        let fields = try XCTUnwrap(CanonicalBusinessEngine.subcontractorBookingCreateFields(
            id: "ID1",
            subcontractorId: "S",
            projectId: "P",
            date: Date(timeIntervalSince1970: 1),
            timeSlot: "FULL DAY",
            workStartTime: nil,
            workEndTime: nil,
            isBreakRemoved: false,
            bookedBy: "me",
            status: "Confirmed",
            bookedContactIds: [],
            bookedOperativeNames: [],
            createdAt: Date(timeIntervalSince1970: 0.005)
        ))
        XCTAssertEqual(fields["id"] as? String, "ID1")
        XCTAssertEqual(fields["status"] as? String, "Confirmed")
        XCTAssertEqual(fields["isBreakRemoved"] as? Bool, false)
        XCTAssertEqual(fields["bookedContactIds"] as? [String], [])
        XCTAssertEqual(fields["bookedOperativeNames"] as? [String], [])

        let write = try XCTUnwrap(CanonicalBusinessEngine.subcontractorBookingWrite(
            before: ["timeSlot": "AM", "bookedBy": "x", "bookedContactIds": ["a"], "bookedOperativeNames": ["A"]],
            next: ["timeSlot": "AM", "bookedBy": "y", "bookedContactIds": ["a", "b"]]
        ))
        XCTAssertEqual(write.setKeys, ["bookedContactIds"])
        XCTAssertEqual(write.removeKeys, [])
        XCTAssertTrue(try XCTUnwrap(CanonicalBusinessEngine.subcontractorBookingWrite(before: nil, next: ["timeSlot": "AM"])).isEmpty)
    }

    // MARK: - Timesheet entries

    private var sheet: [String: Any] {
        [
            "__documentId": "timesheet_uid1_1793577600",
            "expenseEntries": [
                ["title": "Fuel", "amount": 12.5, "date": Timestamp(seconds: monday, nanoseconds: 0)] as [String: Any],
                ["id": "exp-web-1", "title": "Parking", "amount": 3.0] as [String: Any],
            ],
            "extraEntryReviews": [
                "EXP-WEB-1": ["decision": "declined", "reviewedAmount": 3.0, "reviewedByUserId": "m", "reviewedAtMs": 1.0] as [String: Any],
            ],
        ]
    }

    func testTimesheetEntriesKeepStoredIdsAndGetStableIdsWhenMissing() throws {
        let first = try XCTUnwrap(TimesheetDraftStore.decodeFirestoreMap(sheet))
        let second = try XCTUnwrap(TimesheetDraftStore.decodeFirestoreMap(sheet))
        XCTAssertEqual(first.expenseEntries.count, 2, "a non-UUID id no longer drops the entry")
        XCTAssertEqual(first.expenseEntries[0].storedId, "51C46F9C-4A77-829A-935A-4D524C9F0C2C", "timesheetEntryId")
        XCTAssertEqual(first.expenseEntries.map(\.id), second.expenseEntries.map(\.id), "the same ids on every read")
        XCTAssertEqual(first.expenseEntries[1].storedId, "exp-web-1")
        XCTAssertEqual(first.expenseEntries[1].managerDecision, .declined, "a review keyed in another letter case is found")

        let written = TimesheetDraftStore.asFirestoreMap(first)["expenseEntries"] as? [[String: Any]]
        XCTAssertEqual(written?.compactMap { $0["id"] as? String }, ["51C46F9C-4A77-829A-935A-4D524C9F0C2C", "exp-web-1"])
    }

    func testTheSheetIdComesFromThePeriodFieldsWithoutAReadId() throws {
        var stored = sheet
        stored.removeValue(forKey: "__documentId")
        stored["userId"] = "uid1"
        stored["weekStartKey"] = "2026-11-02"
        let draft = try XCTUnwrap(TimesheetDraftStore.decodeFirestoreMap(stored))
        XCTAssertEqual(draft.expenseEntries.first?.storedId, "51C46F9C-4A77-829A-935A-4D524C9F0C2C")
    }

    // MARK: - Deadlines

    func testTheDeadlineAssignmentWriteIsAFieldPathNotADottedKey() throws {
        let write = try XCTUnwrap(CanonicalBusinessEngine.deadlineAssignmentWriteFields(projectId: "abc-job", assigneeUserIds: ["u2", "U2", "u1"]))
        XCTAssertEqual(write.fieldPath, ["projects", "ABC-JOB"])
        XCTAssertEqual(write.value, ["u1", "u2"])
        XCTAssertFalse(write.createFields.keys.contains { $0.contains(".") }, "never a literal projects.{KEY} field")
        XCTAssertEqual((write.createFields["projects"] as? [String: Any])?["ABC-JOB"] as? [String], ["u1", "u2"])
    }

    func testDeadlineAssignmentsReadTheMapAndOlderLiteralFields() throws {
        let data: [String: Any] = ["projects.OLD": ["u1"], "projects": ["NEW": ["U1"]]]
        XCTAssertEqual(CanonicalBusinessEngine.deadlineAssignedProjectIds(data, personIds: ["u1"]), ["NEW", "OLD"])
        XCTAssertEqual(CanonicalBusinessEngine.parseDeadlineAssignments(data)?["OLD"], ["u1"])
    }

    func testDeadlineItemsKeepNonUuidIds() throws {
        let data: [String: Any] = [
            "items": [
                [
                    "id": "web-dl-1",
                    "title": "T",
                    "due": Timestamp(seconds: monday + 7 * 86_400, nanoseconds: 0),
                    "dependsOn": ["web-dl-0"],
                    "history": [["id": "h1", "type": "weird", "at": Timestamp(seconds: 1, nanoseconds: 0)] as [String: Any]],
                ] as [String: Any],
                ["title": "no id"] as [String: Any],
            ],
        ]
        let items = try XCTUnwrap(FirebaseBackend.deadlines(fromDocument: "deadlines_projects_ABC", data: data, projectKey: "abc"))
        XCTAssertEqual(items.count, 1, "an item without an id is skipped")
        let item = try XCTUnwrap(items.first)
        XCTAssertEqual(item.id, Manager.stableId(forFirestoreDocumentId: "web-dl-1"))
        XCTAssertEqual(WorkDocumentKeys.storedId(for: item.id), "web-dl-1")
        XCTAssertEqual(item.dependsOn.map { WorkDocumentKeys.storedId(for: $0) }, ["web-dl-0"])
        XCTAssertEqual(item.history.first?.line, "weird", "an unknown change type reads as a note")
    }
}
