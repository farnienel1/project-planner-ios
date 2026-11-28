//
//  Rulebook1740Tests.swift
//  RULEBOOK 1.74.0 §8 / §13 (owner decisions and reports 23 Nov; web `canonical.test.ts` `timesheetLineDisplayOrder`,
//  `timesheetReviewerBookingEditRecord`). The line manager's ⚙ / ✕ is recorded on the sheet so it stays with them; lines
//  are shown booking by booking and an all-overtime booking's empty standard line is not shown. Every answer comes from
//  the packed script through `CanonicalBusinessEngine`.
//

import XCTest
@testable import Project_Planner

@MainActor
final class Rulebook1740Tests: XCTestCase {
    private let signedAt = Date(timeIntervalSince1970: 1_795_514_400) // 24 Nov 2026 10:00 UTC

    override func setUp() {
        super.setUp()
        OrganizationRulebookContext.update(from: Organization(firestoreDocumentId: "TEST-ORG-174", name: "TEST-Company 174"))
    }

    override func tearDown() {
        OrganizationRulebookContext.update(from: nil)
        super.tearDown()
    }

    private func storedBooking(end: String = "19:00") -> [String: Any] {
        [
            "id": "B1",
            "collection": "bookings",
            "date": Date(timeIntervalSince1970: 1_795_392_000).timeIntervalSince1970 * 1000, // 23 Nov 2026
            "operativeId": "OP1",
            "projectId": "J1",
            "timeSlot": "CUSTOM_HOURS",
            "workStartTime": "07:00",
            "workEndTime": end,
            "status": "Confirmed",
        ]
    }

    // MARK: Copy

    func testReviewCopyIsTheRulebooks() {
        XCTAssertEqual(
            CanonicalBusinessEngine.timesheetReviewBookingUpdatedMessage,
            "Booking updated. Keep reviewing — the person sees the changes when you counter-sign."
        )
        XCTAssertTrue(CanonicalBusinessEngine.timesheetReviewBookingNotRecordedMessage.hasPrefix("Booking updated, but the timesheet could not record it"))
        XCTAssertEqual(CanonicalBusinessEngine.timesheetReviewerBookingEditsField, "reviewerBookingEdits")
        XCTAssertTrue(CanonicalBusinessEngine.timesheetReviewEditBookingNote.contains("the person sees the change when you counter-sign"))
    }

    // MARK: The reviewer's record

    func testRecordIsMadeOnlyForASignedUnexportedSheet() {
        guard let before = CanonicalBusinessEngine.timesheetReviewBookingDocument(collection: "bookings", id: "B1", data: storedBooking()),
              let after = CanonicalBusinessEngine.timesheetReviewBookingAfterEdit(before: before, set: ["workEndTime": "16:00"], remove: [])
        else { return XCTFail("script did not answer") }
        XCTAssertEqual(after["workEndTime"] as? String, "16:00")
        XCTAssertEqual(after["dayKey"] as? String, "2026-11-23")

        let signedMs = signedAt.timeIntervalSince1970 * 1000
        let record = CanonicalBusinessEngine.timesheetReviewerBookingEditRecord(
            sheet: ["operativeSignedAt": signedMs, "exportedAt": NSNull()],
            collection: "bookings", bookingId: "B1", after: after, deleted: false, editedBy: "LM"
        )
        XCTAssertEqual(record?.key, "bookings__b1")
        XCTAssertEqual(record?.value["deleted"] as? Bool, false)
        XCTAssertEqual((record?.value["forSignedAtMs"] as? NSNumber)?.doubleValue, signedMs)

        // Not signed by the person: nothing to record. Exported: frozen, nothing to record.
        XCTAssertNil(CanonicalBusinessEngine.timesheetReviewerBookingEditRecord(
            sheet: ["operativeSignedAt": NSNull()], collection: "bookings", bookingId: "B1", after: after, deleted: false, editedBy: "LM"
        ))
        XCTAssertNil(CanonicalBusinessEngine.timesheetReviewerBookingEditRecord(
            sheet: ["operativeSignedAt": signedMs, "exportedAt": signedMs + 1000],
            collection: "bookings", bookingId: "B1", after: nil, deleted: true, editedBy: "LM"
        ))
    }

    func testRecorderNeedsAStoredSheetAndTheNoticeFollowsIt() {
        var draft = TimesheetDraft()
        draft.operativeSignedAt = signedAt
        // No stored document: nothing can be recorded, and nothing really goes back (the sheet is not stored).
        XCTAssertNil(TimesheetReviewerEditRecorder.record(
            draft: draft, collection: "bookings", bookingId: "B1", booking: storedBooking(),
            write: (set: ["workEndTime": "16:00"], remove: []), editedBy: "LM"
        ))
        // Review of #276: signed and not exported, nothing recorded → it has gone back to the person (a copy read before
        // 1.55.0 has no document id, yet the stored sheet still reopens).
        XCTAssertEqual(TimesheetReviewerEditRecorder.notice(recorded: false, draft: draft), CanonicalBusinessEngine.timesheetReviewBookingNotRecordedMessage)
        var unsigned = TimesheetDraft()
        unsigned.versionDocumentId = "timesheet_OP1_1795392000"
        XCTAssertEqual(TimesheetReviewerEditRecorder.notice(recorded: false, draft: unsigned), CanonicalBusinessEngine.timesheetReviewBookingUpdatedMessage)

        draft.versionDocumentId = "timesheet_OP1_1795392000"
        let record = TimesheetReviewerEditRecorder.record(
            draft: draft, collection: "bookings", bookingId: "B1", booking: storedBooking(),
            write: (set: ["workEndTime": "16:00"], remove: []), editedBy: "LM"
        )
        XCTAssertEqual(record?.sheetDocumentId, "timesheet_OP1_1795392000")
        XCTAssertEqual(record?.edit.key, "bookings__b1")
        let deleted = TimesheetReviewerEditRecorder.record(
            draft: draft, collection: "bookings", bookingId: "B1", booking: nil, write: nil, editedBy: "LM"
        )
        XCTAssertEqual(deleted?.edit.value["deleted"] as? Bool, true)
        // Signed, stored, not exported and nothing recorded: it really has gone back to the person.
        XCTAssertEqual(TimesheetReviewerEditRecorder.notice(recorded: false, draft: draft), CanonicalBusinessEngine.timesheetReviewBookingNotRecordedMessage)
        XCTAssertEqual(TimesheetReviewerEditRecorder.notice(recorded: true, draft: draft), CanonicalBusinessEngine.timesheetReviewBookingUpdatedMessage)
    }

    func testRecordReachesTheChangeRuleButNeverADraftSave() {
        var draft = TimesheetDraft()
        draft.operativeSignedAt = signedAt
        draft.versionDocumentId = "timesheet_OP1_1795392000"
        guard let record = TimesheetReviewerEditRecorder.record(
            draft: draft, collection: "bookings", bookingId: "B1", booking: storedBooking(),
            write: (set: ["workEndTime": "16:00"], remove: []), editedBy: "LM"
        ) else { return XCTFail("no record") }
        TimesheetReviewerBookingEdits.adding(record.edit, to: &draft)
        let sheet = SignedTimesheetChangeInputs.sheet(draft, keys: [:])
        let edits = sheet["reviewerBookingEdits"] as? [String: Any]
        XCTAssertNotNil(edits?["bookings__b1"])
        // The person's (or reviewer's) draft save never writes it: it is not one of the saved fields.
        XCTAssertNil(TimesheetDraftStore.asFirestoreMap(draft)["reviewerBookingEdits"])
    }

    // MARK: Full chain (review of #276): record → SignedTimesheetChanges.change

    private let dayMs = 1_795_392_000_000.0 // Mon 23 Nov 2026 00:00 London

    /// Stored documents as the iPhone writes them: a labour FULL DAY on a lower/mixed-case job id, and a manager site
    /// booking at a project with "7:00 AM" clock text and a mixed-case location id.
    private func storedLabour(operativeId: String) -> [String: Any] {
        [
            "operativeId": operativeId,
            "projectId": "j-Abc-174",
            "date": dayMs,
            "timeSlot": "FULL DAY",
            "status": "Confirmed",
            "bookedBy": "TEST-Admin",
        ]
    }

    private func storedManager(userId: String) -> [String: Any] {
        [
            "userId": userId,
            "date": dayMs + 86_400_000,
            "timeSlot": "CUSTOM_HOURS",
            "workStartTime": "7:00 AM",
            "workEndTime": "4:00 PM",
            "locationType": ManagerLocationType.project.rawValue,
            "locationId": "J-ABC-174",
        ]
    }

    private func labourModels(_ docs: [(String, [String: Any])]) throws -> [Booking] {
        let parsed = try XCTUnwrap(CanonicalBusinessEngine.parseBookingDocuments(docs.map { ["id": $0.0, "data": $0.1] }))
        return parsed.compactMap(FirebaseBackend.booking(fromCanonical:))
    }

    /// The same mapping as `FirebaseBackend.managerSiteBookingsFromFirestoreDocuments` (which needs a snapshot).
    private func managerModels(_ docs: [(String, [String: Any])]) throws -> [ManagerSiteBooking] {
        let parsed = try XCTUnwrap(CanonicalBusinessEngine.parseManagerSiteBookingDocuments(docs.map { ["id": $0.0, "data": $0.1] }))
        return try parsed.map { row in
            let key = row.locationId?.trimmingCharacters(in: .whitespacesAndNewlines)
            var booking = ManagerSiteBooking(
                id: UUID(uuidString: row.id) ?? UUID(),
                userId: row.userId,
                date: Date(timeIntervalSince1970: row.dateMs / 1000),
                timeSlot: try XCTUnwrap(ManagerTimeSlot.fromStored(row.timeSlot)),
                locationType: try XCTUnwrap(ManagerLocationType(rawValue: row.locationType)),
                locationId: (key?.isEmpty == false ? key : nil).map { WorkDocumentKeys.inAppId(for: $0) },
                customLocationName: row.customLocationName,
                workStartTime: row.workStartTime,
                workEndTime: row.workEndTime,
                isBreakRemoved: row.isBreakRemoved,
                createdAt: Date(timeIntervalSince1970: dayMs / 1000 - 86_400),
                updatedAt: Date(timeIntervalSince1970: dayMs / 1000 - 86_400)
            )
            booking.documentId = row.id == booking.id.uuidString ? nil : row.id
            booking.locationKey = key?.isEmpty == false ? key : nil
            return booking
        }
    }

    private func applied(_ doc: [String: Any], _ set: [String: Any], _ remove: [String]) -> [String: Any] {
        var out = doc
        for (key, value) in set { if value is NSNull { out.removeValue(forKey: key) } else { out[key] = value } }
        for key in remove { out.removeValue(forKey: key) }
        return out
    }

    private func reviewEdit(_ doc: [String: Any], id: String, collection: String, start: String, end: String, window: (start: String, end: String)?) throws -> (set: [String: Any], remove: [String]) {
        var input = doc
        input["id"] = id
        input["collection"] = collection
        guard case .write(_, _, let set, let remove, let changed)? = CanonicalBusinessEngine.timesheetReviewBookingEditWrites(
            booking: input, startTime: start, endTime: end, isBreakRemoved: false, overtimeRate: nil, slotWindow: window
        ) else { throw XCTSkip("script did not answer") }
        XCTAssertTrue(changed)
        return (set, remove)
    }

    func testReviewerEditsRecordedOnTheSheetDoNotSendItBackButWithoutThemTheyDo() throws {
        let user = LogicFixtures.selfEmployedUser(id: "TEST-user-174", email: "test-174@example.com", dayRate: 200)
        let operative = LogicFixtures.operative(id: UUID(), email: user.email, dayRate: 200)
        let labourId = "lab-174-b1"
        let managerId = "MGR-174-M1"
        let labourV1 = storedLabour(operativeId: operative.id.uuidString)
        let managerV1 = storedManager(userId: user.id)
        let start = Date(timeIntervalSince1970: dayMs / 1000)
        let period = WeekRange(start: start, end: start.addingTimeInterval(6 * 86_400), title: "TEST 174")
        func inputs(_ labour: [String: Any], _ manager: [String: Any]) throws -> SignedTimesheetChanges.Inputs {
            SignedTimesheetChanges.Inputs(
                bookings: try labourModels([(labourId, labour)]),
                managerBookings: try managerModels([(managerId, manager)]),
                operatives: [operative],
                projects: [],
                smallWorks: [],
                organization: nil,
                users: [user],
                liveLoaded: true
            )
        }
        let before = try inputs(labourV1, managerV1)
        XCTAssertEqual(before.bookings.first?.projectKey, "j-Abc-174")
        XCTAssertEqual(before.managerBookings.first?.workStartTime, "07:00")

        // The person signs the live bookings.
        var draft = TimesheetDraft()
        draft.operativeSignedAt = Date(timeIntervalSince1970: dayMs / 1000 + 7 * 86_400)
        draft.versionDocumentId = "timesheet_TEST-user-174_1795392000"
        let lines = SignedTimesheetChanges.liveLines(user: user, period: period, inputs: before)
        XCTAssertFalse(lines.isEmpty)
        XCTAssertTrue(SignedTimesheetChanges.stampSignedBookings(on: &draft, lines: lines, bookings: before.bookings, managerBookings: before.managerBookings))
        XCTAssertEqual(SignedTimesheetChanges.change(draft: draft, user: user, period: period, inputs: before)?.changed, false)

        // The line manager edits both bookings from the review (⚙): the booking writes and the sheet's records.
        let labourEdit = try reviewEdit(labourV1, id: labourId, collection: "bookings", start: "07:00", end: "18:00", window: ("07:00", "16:00"))
        let managerEdit = try reviewEdit(managerV1, id: managerId, collection: "managerSiteBookings", start: "08:00", end: "17:00", window: nil)
        var recorded = draft
        for (doc, id, collection, edit) in [
            (labourV1, labourId, "bookings", labourEdit),
            (managerV1, managerId, "managerSiteBookings", managerEdit),
        ] {
            var stored = doc
            stored["id"] = id
            stored["collection"] = collection
            let record = try XCTUnwrap(TimesheetReviewerEditRecorder.record(
                draft: recorded, collection: collection, bookingId: id, booking: stored, write: edit, editedBy: "TEST-LM"
            ))
            TimesheetReviewerBookingEdits.adding(record.edit, to: &recorded)
        }
        let after = try inputs(applied(labourV1, labourEdit.set, labourEdit.remove), applied(managerV1, managerEdit.set, managerEdit.remove))

        // Recorded: still exactly as the reviewer left them → no change for the person.
        let kept = try XCTUnwrap(SignedTimesheetChanges.change(draft: recorded, user: user, period: period, inputs: after))
        XCTAssertFalse(kept.changed, "\(kept)")
        XCTAssertNil(kept.waitingFor)

        // Not recorded (an older build's edit): the sheet goes back to the person (1.47.0).
        let reopened = try XCTUnwrap(SignedTimesheetChanges.change(draft: draft, user: user, period: period, inputs: after))
        XCTAssertTrue(reopened.changed)
        XCTAssertEqual(reopened.waitingFor, "person")
    }

    // MARK: Line order

    private struct Line {
        let id: String
        let booking: String
        let overtime: Bool
        let hours: Double
        let amount: Double
        let start: String
        let end: String
        let details: String
    }

    func testLinesAreBookingByBookingAndTheEmptyStandardLineIsHidden() {
        let day = Date(timeIntervalSince1970: 1_795_392_000 + 12 * 3600)
        let lines = [
            Line(id: "op-B-normal", booking: "B", overtime: false, hours: 6, amount: 150, start: "10:00", end: "19:00", details: "10:00–16:00"),
            Line(id: "op-B-ot", booking: "B", overtime: true, hours: 4.5, amount: 60, start: "10:00", end: "19:00", details: "16:00–19:00"),
            // A: all overtime (05:00–07:00) — its 0h / £0 standard line is not shown.
            Line(id: "op-A-normal", booking: "A", overtime: false, hours: 0, amount: 0, start: "05:00", end: "07:00", details: ""),
            Line(id: "op-A-ot", booking: "A", overtime: true, hours: 3, amount: 40, start: "05:00", end: "07:00", details: "05:00–07:00"),
        ]
        let ordered = TimesheetLineDisplayOrder.ordered(lines) { line in
            TimesheetLineOrderInput(
                id: line.id, bookingId: "op-\(line.booking)", bookingCollection: "bookings", date: day,
                isOvertimeLine: line.overtime, paidHours: line.hours, amount: line.amount,
                bookingStartTime: line.start, bookingEndTime: line.end, details: line.details
            )
        }
        XCTAssertEqual(ordered.map(\.id), ["op-A-ot", "op-B-normal", "op-B-ot"])
        // Display only: the total of every line is unchanged, and the hidden line is £0.
        XCTAssertEqual(lines.reduce(0) { $0 + $1.amount }, ordered.reduce(0) { $0 + $1.amount })
    }

    // MARK: Owner answers 23 Nov (amended #425)

    func testEmptyStandardLineBesideADeclinedOvertimeLineIsShownDeclined() {
        let day = Date(timeIntervalSince1970: 1_795_392_000 + 12 * 3600)
        let lines = [
            Line(id: "op-A-normal", booking: "A", overtime: false, hours: 0, amount: 0, start: "05:00", end: "07:00", details: ""),
            Line(id: "op-A-ot", booking: "A", overtime: true, hours: 3, amount: 40, start: "05:00", end: "07:00", details: "05:00–07:00"),
        ]
        func input(_ line: Line) -> TimesheetLineOrderInput {
            TimesheetLineOrderInput(
                id: line.id, bookingId: "op-\(line.booking)", bookingCollection: "bookings", date: day,
                isOvertimeLine: line.overtime, paidHours: line.hours, amount: line.amount,
                bookingStartTime: line.start, bookingEndTime: line.end, details: line.details
            )
        }
        // Overtime not declined: the £0 standard line is hidden.
        let plain = TimesheetLineDisplayOrder.shown(lines, input: input, isDeclined: { _ in false })
        XCTAssertEqual(plain.map(\.item.id), ["op-A-ot"])
        // Overtime declined: the £0 standard line stays, shown declined (`timesheetLineShownDeclined`).
        let declined = TimesheetLineDisplayOrder.shown(lines, input: input, isDeclined: { $0.id == "op-A-ot" })
        XCTAssertEqual(declined.map(\.item.id), ["op-A-normal", "op-A-ot"])
        XCTAssertEqual(declined.map(\.shownDeclined), [true, false])
    }

    func testCounterSignNoticeSaysTheSheetWasUpdatedOnlyWithAReviewerEditForThisSignature() {
        let signedMs = signedAt.timeIntervalSince1970 * 1000
        let record: [String: Any] = [
            "bookings__b1": ["bookingId": "B1", "collection": "bookings", "fingerprint": "x", "place": "", "deleted": false, "editedBy": "LM", "forSignedAtMs": signedMs],
        ]
        XCTAssertTrue(CanonicalBusinessEngine.timesheetSheetChangedByReviewer(["operativeSignedAt": signedMs, "reviewerBookingEdits": record]))
        XCTAssertFalse(CanonicalBusinessEngine.timesheetSheetChangedByReviewer(["operativeSignedAt": signedMs]))
        // A record for an earlier signature does not count.
        XCTAssertFalse(CanonicalBusinessEngine.timesheetSheetChangedByReviewer(["operativeSignedAt": signedMs + 3_600_000, "reviewerBookingEdits": record]))

        let updated = CanonicalBusinessEngine.timesheetSignedNoticeText(signedByName: "Lee", changedByReviewer: true)
        XCTAssertEqual(updated?.title, CanonicalBusinessEngine.constant("TIMESHEET_SIGNED_UPDATED_NOTICE_TITLE", as: String.self))
        // The message names the signer the iOS notice already passes (no generic "line manager" wording).
        XCTAssertEqual(updated?.message, "Lee changed your timesheet and signed it off. Open it to check the changes. Next: generate your timesheet.")
        let plain = CanonicalBusinessEngine.timesheetSignedNoticeText(signedByName: "Lee", changedByReviewer: false)
        XCTAssertEqual(plain?.title, CanonicalBusinessEngine.constant("TIMESHEET_SIGNED_NOTICE_TITLE", as: String.self))
        XCTAssertNotEqual(plain?.title, updated?.title)

        // The draft as the reviewer holds it after recording an edit.
        var draft = TimesheetDraft()
        draft.operativeSignedAt = signedAt
        draft.versionDocumentId = "timesheet_OP1_1795392000"
        XCTAssertFalse(CanonicalBusinessEngine.timesheetSheetChangedByReviewer(SignedTimesheetChangeInputs.sheet(draft, keys: [:])))
        if let edit = TimesheetReviewerEditRecorder.record(
            draft: draft, collection: "bookings", bookingId: "B1", booking: storedBooking(),
            write: (set: ["workEndTime": "16:00"], remove: []), editedBy: "LM"
        ) {
            TimesheetReviewerBookingEdits.adding(edit.edit, to: &draft)
        }
        XCTAssertTrue(CanonicalBusinessEngine.timesheetSheetChangedByReviewer(SignedTimesheetChangeInputs.sheet(draft, keys: [:])))
    }

    /// RULEBOOK 1.74.0 §8 (owner answer 23 Nov, choice 6): the live invoice leaves off the £0 empty standard row of a
    /// booking with an overtime line, declined or not — `timesheetInvoiceRows` `omitEmptyStandardParts` (what
    /// `TimesheetInvoiceRows` passes), read from the iPhone's own line shape (`rulebookTotalsJSON`).
    func testLiveInvoiceOmitsTheEmptyStandardRowWhateverTheOvertimeDecision() throws {
        let saturday = LogicFixtures.day(2026, 11, 21)
        let monday = LogicFixtures.day(2026, 11, 23)
        let standard = TimesheetPayrollLineItem(
            id: "op-A1-normal", date: saturday, jobNumber: "J-1", projectName: "Site", details: "",
            paidHours: 0, payrollBasis: .dayRate, dayRate: 200, hourlyRate: nil, amount: 0, isPayeDay: false,
            isOvertimeLine: false, bookingId: "op-A1", bookingPaidHours: 13, bookingOvertimeHours: 6.5
        )
        let overtime = TimesheetPayrollLineItem(
            id: "op-A1-ot", date: saturday, jobNumber: "J-1", projectName: "Site (Overtime)", details: "07:30–14:00",
            paidHours: 13, payrollBasis: .dayRate, dayRate: 200, hourlyRate: nil, amount: 325, isPayeDay: false,
            isOvertimeLine: true, bookingId: "op-A1", otMultiplier: 2, otClockHours: 6.5
        )
        let other = TimesheetPayrollLineItem(
            id: "op-B1-normal", date: monday, jobNumber: "J-1", projectName: "Site", details: "07:30–16:00",
            paidHours: 8, payrollBasis: .dayRate, dayRate: 200, hourlyRate: nil, amount: 200, isPayeDay: false,
            isOvertimeLine: false, bookingId: "op-B1"
        )
        let lines = [standard, overtime, other].map(\.rulebookTotalsJSON)
        func ids(_ sheet: [String: Any], omit: Bool) throws -> [String] {
            let rows = try XCTUnwrap(CanonicalBusinessEngine.callJSON("timesheetInvoiceRows", arguments: [[
                "sheet": sheet, "payrollLines": lines, "extrasMode": "decided",
                "timeZone": OrganizationRulebookContext.timeZoneIdentifier, "omitEmptyStandardParts": omit,
            ] as [String: Any]]) as? [[String: Any]])
            return rows.compactMap { $0["id"] as? String }
        }
        XCTAssertEqual(try ids([:], omit: false), ["op-A1-normal", "op-A1-ot", "op-B1-normal"])
        XCTAssertEqual(try ids([:], omit: true), ["op-A1-ot", "op-B1-normal"])
        let declined: [String: Any] = [
            "managerSignedAt": signedAt.timeIntervalSince1970 * 1000,
            "payrollLineReviews": ["op-A1-ot": ["decision": "declined"]],
        ]
        // Overtime declined: neither row is invoiced (the review shows the £0 line struck through instead).
        XCTAssertEqual(try ids(declined, omit: true), ["op-B1-normal"])
    }
}
