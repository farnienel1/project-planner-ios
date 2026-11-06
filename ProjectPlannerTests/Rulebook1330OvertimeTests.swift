import XCTest
@testable import Project_Planner

/// RULEBOOK 1.33.0 iOS follow-on (web hand-off v1.33.0, items 1–3 and 9): PAYE overtime Send → Return
/// (`overtimeChoiceAfter`, `overtimeChoiceView`, `overtimeLineChoice`, `overtimeChoiceDecision`, `overtimeSubmitReady`,
/// `overtimeSubmitLines`, `overtimeReturnReady`, `overtimeReturnWrites`, `overtimeGenerateReady`,
/// `overtimeReportOutOfDate`, `overtimeRequestsSuperseded`, `overtimeDirectWrites` delete), the notices
/// (`overtimeRequestSubmittedMessage`, `overtimeReturnedMessage`, `overtimeDeciderIsLineManager`,
/// `overtimeReturnedRecipients`, `overtimeLineReopened`, `overtimeReopenedRecipients`, `overtimeReopenedMessage`,
/// `overtimeNotificationRange`), the report fields (`overtimeReportRows`, `reportGeneratedText`) and the Payrun Snapshot
/// (`payrunSnapshotPeriods`, `payrunSnapshotCustomPeriod`, `parsePayrunSnapshotSheet`, `payrunSnapshotRows`). Every answer
/// comes from the packed script through `CanonicalBusinessEngine`; these tests lock the Swift inputs and readings. The
/// expected values are the ones web `lib/canonical/canonical.test.ts` asserts for the same inputs.
@MainActor
final class Rulebook1330OvertimeTests: XCTestCase {
    private let org: [String: Any] = [
        "countryCode": "GB",
        "payrollTimePolicy": [
            "standardDayStart": "07:30",
            "standardDayEnd": "16:00",
            "unpaidBreakMinutes": 30,
            "breakWindowStart": "12:00",
            "breakWindowEnd": "12:30",
            "weekdayOutsideStandardMultiplier": 1.5,
            "saturday": [
                "allHoursAtMultiplierMode": false, "definedWindowStart": "07:30", "definedWindowEnd": "14:00",
                "countsAsStandardHours": 8, "outsideWindowMultiplier": 1.5,
            ] as [String: Any],
            "sunday": ["allHoursAtMultiplierMode": true, "allHoursMultiplier": 2, "sameAsSaturday": false] as [String: Any],
        ] as [String: Any],
        "invoicing": ["payePaydayHistory": [["day": 25, "effectiveFrom": "2026-01-01"]]] as [String: Any],
    ]
    private let range = (start: "2026-11-01", end: "2026-11-30")

    override func setUp() {
        super.setUp()
        OrganizationRulebookContext.update(from: Organization(firestoreDocumentId: "TEST-ORG-1330", name: "TEST-Company 1330"))
    }

    override func tearDown() {
        OrganizationRulebookContext.update(from: nil)
        super.tearDown()
    }

    private func booking(_ id: String, _ dayKey: String, _ start: String, _ end: String, person: String = "TEST-sam") -> OvertimeBookingInput {
        OvertimeBookingInput(
            id: id, collection: "bookings", personId: person, dayKey: dayKey, timeSlot: "CUSTOM_HOURS",
            workStartTime: start, workEndTime: end, isBreakRemoved: false, otMultiplierOverride: nil, status: "Confirmed",
            jobId: "TEST-job-1", jobNumber: "J-1", jobName: "TEST Site"
        )
    }

    private var roster: [[String: Any]] {
        [
            ["id": "TEST-sam", "email": "sam@x.test", "isActive": true, "role": ["isOperativeMode": true],
             "assignedManagerUserIds": ["TEST-lm"], "employmentType": "paye"],
            ["id": "TEST-lm", "email": "lm@x.test", "isActive": true, "role": ["isManager": true]],
            ["id": "TEST-adm", "email": "adm@x.test", "isActive": true, "role": ["isAdmin": true]],
        ]
    }

    // MARK: Packed script

    func testThePackedScriptIs1330AndExportsTheSendReturnRules() throws {
        let version = try XCTUnwrap(CanonicalBusinessEngine.rulebookStamp()?.version)
        XCTAssertNotEqual(version.compare("1.33.0", options: .numeric), .orderedAscending, "rulebook \(version) is older than 1.33.0")
        let exports = Set(CanonicalBusinessEngine.exportNames())
        for name in [
            "overtimeChoiceAfter", "overtimeChoiceView", "overtimeLineChoice", "overtimeChoiceDecision", "overtimeSubmitReady",
            "overtimeSubmitLines", "overtimeReturnReady", "overtimeReturnWrites", "overtimeGenerateReady", "overtimeReportOutOfDate",
            "overtimeRequestsSuperseded", "overtimeReturnedMessage", "overtimeReturnedRecipients", "overtimeDeciderIsLineManager",
            "overtimeRequestSubmittedMessage", "overtimeLineReopened", "overtimeReopenedRecipients", "overtimeReopenedMessage",
            "overtimeNotificationRange", "reportGeneratedText", "payrunSnapshotPeriods", "payrunSnapshotCustomPeriod",
            "parsePayrunSnapshotSheet", "payrunSnapshotRows", "OVERTIME_DELETE_WARNING", "OVERTIME_RETURN_LABEL",
        ] {
            XCTAssertTrue(exports.contains(name), "\(name) is not exported")
        }
        XCTAssertEqual(CanonicalBusinessEngine.overtimeText("OVERTIME_RETURN_LABEL", fallback: ""), "Return overtime")
        XCTAssertEqual(CanonicalBusinessEngine.overtimeText("OVERTIME_SEND_FOR_APPROVAL_LABEL", fallback: ""), "Send for approval")
        XCTAssertEqual(CanonicalBusinessEngine.overtimeText("OVERTIME_REPORT_OUT_OF_DATE_LABEL", fallback: ""), "Out of date")
        XCTAssertEqual(CanonicalBusinessEngine.overtimeDeleteWarning?.footnote, "This cannot be undone. A manager can book it again.")
        XCTAssertEqual(CanonicalBusinessEngine.bookingTombstoneCollection, "deletedBookings")
    }

    // MARK: ✓ ✕ ⚙

    func testTheChoiceStateMachineAndWhatItDraws() throws {
        let tick = try XCTUnwrap(CanonicalBusinessEngine.overtimeChoiceAfter(nil, event: .tick))
        XCTAssertEqual(tick, OvertimeChoice(mark: "tick", edit: nil))
        XCTAssertEqual(CanonicalBusinessEngine.overtimeChoiceAfter(tick, event: .tick), OvertimeChoice.empty, "a second ✓ clears it")
        let cross = try XCTUnwrap(CanonicalBusinessEngine.overtimeChoiceAfter(tick, event: .cross))
        XCTAssertEqual(cross.mark, "cross")
        let cog = try XCTUnwrap(CanonicalBusinessEngine.overtimeChoiceAfter(tick, event: .cog(start: "7:30", end: "17:00", multiplier: 2)))
        XCTAssertEqual(cog, OvertimeChoice(mark: "none", edit: .init(start: "07:30", end: "17:00", multiplier: 2)), "the cog unticks")
        let cogTick = try XCTUnwrap(CanonicalBusinessEngine.overtimeChoiceAfter(cog, event: .tick))
        XCTAssertEqual(CanonicalBusinessEngine.overtimeChoiceDecision(cogTick), .edit(start: "07:30", end: "17:00", multiplier: 2))
        XCTAssertNil(CanonicalBusinessEngine.overtimeChoiceDecision(cog), "⚙ still needs ✓ or ✕")
        XCTAssertEqual(CanonicalBusinessEngine.overtimeChoiceDecision(cross), .strike)
        XCTAssertEqual(CanonicalBusinessEngine.overtimeChoiceDecision(tick), .approve)
        XCTAssertEqual(
            CanonicalBusinessEngine.overtimeChoiceAfter(tick, event: .cog(start: "07:30", end: "07:30", multiplier: nil)), tick,
            "an invalid cog changes nothing"
        )

        let b1 = booking("TEST-B1", "2026-11-04", "06:30", "14:00")
        let look = CanonicalBusinessEngine.overtimeChoiceView(tick, booking: b1, organization: org, role: "person")
        XCTAssertEqual(look, OvertimeChoiceLook(
            tick: "filled", cross: "grey", cog: "grey", figureStruck: false, oldFigure: "1h × 1.5 = 1.5h", newFigure: nil,
            label: "Confirmed", complete: true
        ))
        let idle = CanonicalBusinessEngine.overtimeChoiceView(nil, booking: b1, organization: org, role: "person")
        XCTAssertEqual([idle.tick, idle.cross, idle.cog], ["idle", "idle", "idle"])
        XCTAssertEqual(CanonicalBusinessEngine.overtimeChoiceView(cross, booking: b1, organization: org, role: "decider").label, "Declined")
        let sunday = booking("TEST-B4", "2026-11-08", "07:30", "14:00")
        let removed = CanonicalBusinessEngine.overtimeChoiceView(cross, booking: sunday, organization: org, role: "person")
        XCTAssertEqual([removed.newFigure, removed.label], ["Booking removed", "Not worked"])
        XCTAssertTrue(removed.figureStruck)
        XCTAssertEqual(CanonicalBusinessEngine.overtimeChoiceLabels(role: "person")["tick"], "Confirmed")
        XCTAssertEqual(CanonicalBusinessEngine.overtimeChoiceLabels(role: "decider")["tick"], "Approved")
    }

    // MARK: Send for approval → Return → Generate

    func testSendReturnAndGenerateFollowTheButtonRules() throws {
        let b1 = booking("TEST-B1", "2026-11-04", "06:30", "14:00")
        let b2 = booking("TEST-B2", "2026-11-05", "07:30", "18:00")
        let lines = CanonicalBusinessEngine.payeOvertimeLines(
            personIds: ["TEST-sam"], bookings: [b1, b2], organization: org, range: range, reviews: [], requests: []
        )
        XCTAssertEqual(lines.map(\.state), ["needsReview", "needsReview"])
        let unmarked = CanonicalBusinessEngine.overtimeSubmitReady(lines: lines, choices: [:])
        XCTAssertFalse(unmarked.ready)
        XCTAssertEqual(unmarked.undecidedCount, 2)
        XCTAssertEqual(unmarked.message, CanonicalBusinessEngine.overtimeText("OVERTIME_SUBMIT_UNDECIDED_MESSAGE", fallback: ""))

        let choices: [String: OvertimeChoice] = ["TEST-B1": OvertimeChoice(mark: "tick", edit: nil), "TEST-B2": OvertimeChoice(mark: "cross", edit: nil)]
        let ready = CanonicalBusinessEngine.overtimeSubmitReady(lines: lines, choices: choices)
        XCTAssertTrue(ready.ready)
        XCTAssertEqual(ready.bookingIds, ["TEST-B1", "TEST-B2"])
        let built = CanonicalBusinessEngine.overtimeSubmitLines(
            lines: lines, choices: choices, bookings: [b1, b2], organization: org, personIds: ["TEST-sam"]
        )
        XCTAssertEqual(built.refused, [])
        XCTAssertEqual(built.lines.map { $0["action"] as? String }, ["keep", "strike"])
        XCTAssertEqual(built.lines.last?["proposedEnd"] as? String, "16:00", "✕ on a weekday trims to the working day")
        XCTAssertEqual(CanonicalBusinessEngine.overtimeLineChoice(lines[0], choices: choices), choices["TEST-B1"])

        var stored = try XCTUnwrap(CanonicalBusinessEngine.overtimeRequestWriteFields(
            userId: "TEST-sam", rangeStart: range.start, rangeEnd: range.end, lines: built.lines, personIds: ["TEST-sam"], bookings: [b1, b2]
        ))
        stored["createdAt"] = 1
        let request = try XCTUnwrap(CanonicalBusinessEngine.parseOvertimeRequestDocument(docId: "TEST-R1", data: stored))
        XCTAssertEqual(CanonicalBusinessEngine.overtimeRequestsSuperseded([request], userId: "TEST-SAM", bookingIds: ["TEST-B1", "TEST-B2"]), ["TEST-R1"])
        XCTAssertEqual(CanonicalBusinessEngine.overtimeRequestsSuperseded([request], userId: "TEST-sam", bookingIds: ["TEST-B1"]), [])
        let waiting = CanonicalBusinessEngine.payeOvertimeLines(
            personIds: ["TEST-sam"], bookings: [b1, b2], organization: org, range: range, reviews: [], requests: [request]
        )
        XCTAssertEqual(waiting.map(\.state), ["waiting", "waiting"])
        XCTAssertEqual(
            CanonicalBusinessEngine.overtimeSubmitReady(lines: waiting, choices: [:]).message,
            CanonicalBusinessEngine.overtimeText("OVERTIME_SUBMIT_NOTHING_CHANGED_MESSAGE", fallback: ""),
            "waiting lines are locked"
        )

        // The line manager ✓ B1 and ✕ B2 ("I don't agree"): Return writes reviews, no booking change.
        let plan = try XCTUnwrap(CanonicalBusinessEngine.overtimeReturnWrites(
            request: request, decisions: ["TEST-B1": .approve, "TEST-B2": .strike], bookings: ["TEST-B1": b1, "TEST-B2": b2],
            organization: org, deciderId: "TEST-lm", requesterIds: ["TEST-sam"], unreadableBookingIds: []
        ))
        XCTAssertTrue(plan.ok)
        XCTAssertTrue(plan.bookingWrites.isEmpty && plan.bookingDeletes.isEmpty)
        XCTAssertEqual(plan.message, "Returned 2 lines.")
        let reviews = try plan.reviewWrites.map { write -> OvertimeReviewRecord in
            var fields = write.fields
            fields["reviewedAt"] = 10
            return try XCTUnwrap(CanonicalBusinessEngine.parseOvertimeReviewDocument(docId: write.docId, data: fields))
        }
        var returnedData = stored
        for (key, value) in plan.requestFields { returnedData[key] = value }
        returnedData["decidedAt"] = 10
        let returned = try XCTUnwrap(CanonicalBusinessEngine.parseOvertimeRequestDocument(docId: "TEST-R1", data: returnedData))
        let after = CanonicalBusinessEngine.payeOvertimeLines(
            personIds: ["TEST-sam"], bookings: [b1, b2], organization: org, range: range, reviews: reviews, requests: [returned],
            names: ["TEST-lm": "TEST Lee"]
        )
        XCTAssertEqual(after.map(\.state), ["returnedApproved", "returnedDeclined"])
        XCTAssertEqual(after.last?.deciderName, "TEST Lee")
        XCTAssertNotNil(after.first?.sentLine)
        // After a Return, Send stays grey until a line changes; only the changed line is sent.
        XCTAssertFalse(CanonicalBusinessEngine.overtimeSubmitReady(lines: after, choices: [:]).ready)
        XCTAssertEqual(
            CanonicalBusinessEngine.overtimeSubmitReady(lines: after, choices: ["TEST-B2": OvertimeChoice(mark: "tick", edit: nil)]).bookingIds,
            ["TEST-B2"]
        )
        // Generate: every line returned, nothing unsent.
        XCTAssertTrue(CanonicalBusinessEngine.overtimeGenerateReady(lines: after, hasLineManager: true, choices: [:], reports: []).ready)
        XCTAssertEqual(
            CanonicalBusinessEngine.overtimeGenerateReady(
                lines: after, hasLineManager: true, choices: ["TEST-B2": OvertimeChoice(mark: "tick", edit: nil)], reports: []
            ).message,
            CanonicalBusinessEngine.overtimeText("OVERTIME_GENERATE_UNSENT_MESSAGE", fallback: "")
        )
        XCTAssertEqual(
            CanonicalBusinessEngine.overtimeGenerateReady(lines: lines, hasLineManager: true, choices: [:], reports: []).message,
            CanonicalBusinessEngine.overtimeText("OVERTIME_GENERATE_NOT_READY_MESSAGE", fallback: "")
        )

        // The report: the declined line at 0h "Declined by TEST Lee"; Generate grey while it is up to date.
        var snapshot = try XCTUnwrap(CanonicalBusinessEngine.overtimeReportSnapshot(
            userId: "TEST-sam", userName: "TEST Sam", companyName: "TEST-Co", rangeStart: range.start, rangeEnd: range.end,
            lines: after, generatedBy: "TEST-sam"
        ))
        snapshot["generatedAt"] = 1_762_437_900_000.0
        let report = try XCTUnwrap(CanonicalBusinessEngine.parseOvertimeReportDocument(docId: "TEST-REP", data: snapshot))
        XCTAssertFalse(CanonicalBusinessEngine.overtimeReportOutOfDate(report, lines: after))
        XCTAssertFalse(CanonicalBusinessEngine.overtimeGenerateReady(lines: after, hasLineManager: true, choices: [:], reports: [report]).ready)
        let rows = try XCTUnwrap(CanonicalBusinessEngine.overtimeReportRows(report.raw))
        XCTAssertEqual(rows.documentTitle, "Overtime report")
        XCTAssertEqual(rows.columns, ["Day", "Job", "Start–Finish", "Overtime"])
        XCTAssertEqual(rows.table.map(\.overtime), ["1h × 1.5 = 1.5h", "0h"])
        XCTAssertEqual(rows.table.last?.note, "Declined by TEST Lee")
        XCTAssertEqual(rows.table.last?.declined, true)
        XCTAssertEqual(rows.generated, "6 Nov 2025, 14:05 by TEST Sam", "generated by / at in the organisation zone")
        XCTAssertEqual(rows.footer, "TEST-Co · Overtime report · TEST Sam")
        XCTAssertFalse(rows.outOfDate)
        // A manager changes B1: the line reopens and the saved report is out of date.
        var moved = b1
        moved.workEndTime = "15:00"
        let reopened = CanonicalBusinessEngine.payeOvertimeLines(
            personIds: ["TEST-sam"], bookings: [moved, b2], organization: org, range: range, reviews: reviews, requests: [returned]
        )
        XCTAssertTrue(CanonicalBusinessEngine.overtimeReportOutOfDate(report, lines: reopened))
    }

    func testAnApprovedRedXDeletesTheBookingWithItsTombstone() throws {
        let sunday = booking("TEST-B4", "2026-11-08", "07:30", "14:00")
        XCTAssertEqual(CanonicalBusinessEngine.overtimeStrikeOutcome(sunday, organization: org)?.kind, "delete")
        let line = try XCTUnwrap(CanonicalBusinessEngine.overtimeRequestLineFields(sunday, organization: org, proposal: .strike, personIds: ["TEST-sam"]))
        let request = try XCTUnwrap(CanonicalBusinessEngine.parseOvertimeRequestDocument(docId: "TEST-R4", data: [
            "userId": "TEST-sam", "rangeStart": range.start, "rangeEnd": range.end, "status": "pending", "lines": [line.raw],
        ]))
        let plan = try XCTUnwrap(CanonicalBusinessEngine.overtimeReturnWrites(
            request: request, decisions: ["TEST-B4": .approve], bookings: ["TEST-B4": sunday], organization: org,
            deciderId: "TEST-lm", requesterIds: ["TEST-sam"], unreadableBookingIds: []
        ))
        let delete = try XCTUnwrap(plan.bookingDeletes.first)
        XCTAssertEqual(delete.collection, "bookings")
        XCTAssertEqual(delete.bookingId, "TEST-B4")
        XCTAssertEqual(delete.tombstone["overtimeRequestId"] as? String, "TEST-R4")
        XCTAssertEqual(delete.tombstone["deletedBy"] as? String, "TEST-lm")
        XCTAssertEqual(delete.tombstone["deletedFrom"] as? String, "ios")
        XCTAssertEqual(plan.reviewWrites.first?.fields["decision"] as? String, "deleted")
        XCTAssertEqual(plan.requestFields["deletedBookingIds"] as? [String], ["TEST-B4"])

        // No line manager: the direct red X deletes it too, with a tombstone that names no request.
        let direct = try XCTUnwrap(CanonicalBusinessEngine.overtimeDirectWrites(
            sunday, action: .strike, userId: "TEST-sam", reviewerId: "TEST-sam", organization: org
        ))
        XCTAssertNil(direct.bookingWrite)
        XCTAssertEqual(direct.bookingDelete?.bookingId, "TEST-B4")
        XCTAssertNil(direct.bookingDelete?.tombstone["overtimeRequestId"])
        XCTAssertEqual(direct.bookingDelete?.tombstone["deletedFrom"] as? String, "ios")
        XCTAssertEqual(direct.reviewWrite.fields["decision"] as? String, "deleted")
        XCTAssertTrue(direct.hoursChanged)
    }

    // MARK: Notices and where they open

    func testSendReturnAndReopenNotices() throws {
        let submitted = try XCTUnwrap(CanonicalBusinessEngine.overtimeRequestSubmittedMessage(
            requesterName: "Sam", rangeStart: "2026-10-26", rangeEnd: "2026-11-25"
        ))
        XCTAssertEqual(submitted.title, "Overtime request from Sam")
        XCTAssertEqual(submitted.message, "Sam sent their overtime for Mon 26 Oct – Wed 25 Nov for approval.")
        XCTAssertEqual(
            CanonicalBusinessEngine.overtimeReturnedMessage(deciderName: "Lee Manager", deciderIsLineManager: true)?.message,
            "Your line manager Lee Manager has returned your overtime request"
        )
        XCTAssertEqual(
            CanonicalBusinessEngine.overtimeReturnedMessage(deciderName: "Ada Admin", deciderIsLineManager: false)?.message,
            "Ada Admin has returned your overtime request"
        )
        XCTAssertTrue(CanonicalBusinessEngine.overtimeDeciderIsLineManager(decider: "TEST-lm", requester: roster[0], roster: roster))
        XCTAssertFalse(CanonicalBusinessEngine.overtimeDeciderIsLineManager(decider: "TEST-adm", requester: roster[0], roster: roster))
        XCTAssertEqual(CanonicalBusinessEngine.overtimeReturnedRecipients(requester: "TEST-sam", decider: "TEST-lm", roster: roster), ["TEST-sam"])

        // Reopen: a returned line tells the person and their line manager, never the editor.
        let b1 = booking("TEST-B1", "2026-11-04", "06:30", "14:00")
        var moved = b1
        moved.workEndTime = "15:00"
        let review = try XCTUnwrap(CanonicalBusinessEngine.parseOvertimeReviewDocument(docId: "TEST-sam_TEST-B1", data: [
            "userId": "TEST-sam", "bookingId": "TEST-B1", "decision": "approved",
            "fingerprint": CanonicalBusinessEngine.overtimeBookingFingerprint(b1), "requestId": "TEST-R1",
        ]))
        let outcome = CanonicalBusinessEngine.overtimeLineReopened(before: b1, after: moved, organization: org, reviews: [review], requests: [])
        XCTAssertTrue(outcome.reopened)
        XCTAssertTrue(outcome.returned)
        XCTAssertFalse(CanonicalBusinessEngine.overtimeLineReopened(before: b1, after: b1, organization: org, reviews: [review], requests: []).reopened)
        let unreadable = CanonicalBusinessEngine.overtimeLineReopened(before: b1, after: nil, organization: org, reviews: nil, requests: nil)
        XCTAssertTrue(unreadable.reopened, "an editor who cannot read the records: any overtime change counts")
        XCTAssertFalse(unreadable.returned)
        XCTAssertEqual(
            CanonicalBusinessEngine.overtimeReopenedRecipients(bookedId: "TEST-sam", actor: "TEST-adm", roster: roster, operatives: [], returned: true),
            ["TEST-sam", "TEST-lm"]
        )
        XCTAssertEqual(
            CanonicalBusinessEngine.overtimeReopenedRecipients(bookedId: "TEST-sam", actor: "TEST-lm", roster: roster, operatives: [], returned: true),
            ["TEST-sam"]
        )
        XCTAssertEqual(
            CanonicalBusinessEngine.overtimeReopenedMessage(dayKey: "2026-11-04", jobNumber: "J-1", forLineManager: false, personName: nil)?.message,
            "Your booking on Wed 4 Nov (J-1) changed. Check that overtime line and send it again."
        )
        XCTAssertEqual(
            CanonicalBusinessEngine.overtimeReopenedMessage(dayKey: "2026-11-04", jobNumber: "J-1", forLineManager: true, personName: "Sam Test")?.message,
            "Sam Test's booking on Wed 4 Nov (J-1) changed after you returned their overtime. They need to check it and send it again."
        )

        // Where an overtime notice opens: the current payrun, a past one, or the request's own range.
        XCTAssertEqual(
            CanonicalBusinessEngine.overtimeNotificationRange(organization: org, todayKey: "2026-11-06", rangeStart: "2026-10-26", rangeEnd: "2026-11-25", dayKey: nil),
            OvertimeNotificationRange(range: "current", start: "2026-10-26", end: "2026-11-25")
        )
        XCTAssertEqual(
            CanonicalBusinessEngine.overtimeNotificationRange(organization: org, todayKey: "2026-11-06", rangeStart: nil, rangeEnd: nil, dayKey: "2026-10-04"),
            OvertimeNotificationRange(range: "past", start: "2026-09-26", end: "2026-10-25")
        )
        XCTAssertNil(CanonicalBusinessEngine.overtimeNotificationRange(organization: org, todayKey: "2026-11-06", rangeStart: nil, rangeEnd: nil, dayKey: nil))
    }

    func testReportGeneratedTextIsTheRulebooks() {
        let text = CanonicalBusinessEngine.reportGeneratedText(
            generatedAtMs: 1_762_437_900_000, generatedBy: "TEST-sam", userId: "TEST-sam", userName: "Sam Test", now: nil
        )
        XCTAssertEqual(text.generatedAt, "6 Nov 2025, 14:05")
        XCTAssertEqual(text.generated, "6 Nov 2025, 14:05 by Sam Test")
        XCTAssertEqual(
            CanonicalBusinessEngine.reportGeneratedText(
                generatedAtMs: 1_762_437_900_000, generatedBy: "TEST-adm", userId: "TEST-sam", userName: "Sam Test",
                generatedByName: "TEST Ada", now: nil
            ).generatedBy,
            "TEST Ada"
        )
    }

    // MARK: Payrun Snapshot

    func testPayrunSnapshotPeriodsRowsAndLinks() throws {
        let periods = CanonicalBusinessEngine.payrunSnapshotPeriods(organization: org, todayKey: "2026-11-06")
        XCTAssertEqual(periods.paye, PayrunSnapshotPeriod(kind: "paye", start: "2026-10-26", end: "2026-11-25", label: "PAYE payrun: 26 Oct – 25 Nov · paid 25 Nov"))
        XCTAssertEqual(
            CanonicalBusinessEngine.payrunSnapshotCustomPeriod(start: "2026-11-10", end: "2026-11-01"),
            PayrunSnapshotPeriod(kind: "custom", start: "2026-11-01", end: "2026-11-10", label: "Custom: Sun 1 Nov – Tue 10 Nov")
        )
        XCTAssertNil(CanonicalBusinessEngine.payrunSnapshotCustomPeriod(start: "", end: "2026-11-01"))
        let sheet = try XCTUnwrap(CanonicalBusinessEngine.parsePayrunSnapshotSheet(
            docId: "timesheet_TEST-sam_1", data: ["userId": "TEST-sam", "weekStartKey": "2026-11-02", "weekEndKey": "2026-11-08"]
        ))
        XCTAssertEqual(sheet["startDayKey"] as? String, "2026-11-02")
        XCTAssertNil(CanonicalBusinessEngine.parsePayrunSnapshotSheet(docId: "invoicing", data: ["userId": "TEST-sam"]))

        let people: [[String: Any]] = [
            ["id": "TEST-sam", "email": "sam@x.test", "firstName": "Sam", "surname": "Test", "isActive": true, "passwordSet": true,
             "role": ["isOperativeMode": true], "operativeMode": true, "assignedManagerUserIds": ["TEST-lm"], "employmentType": "paye"],
            ["id": "TEST-lm", "email": "lm@x.test", "firstName": "Lee", "surname": "Manager", "isActive": true, "passwordSet": true,
             "role": ["isManager": true], "manager": true, "employmentType": "self_employed"],
        ]
        let pending = try XCTUnwrap(CanonicalBusinessEngine.parseOvertimeRequestDocument(docId: "TEST-R1", data: [
            "userId": "TEST-sam", "rangeStart": "2026-10-26", "rangeEnd": "2026-11-25", "status": "pending", "lines": [[String: Any]](),
        ]))
        let fuel = try XCTUnwrap(CanonicalBusinessEngine.parsePayeClaimDocument(
            kind: .expense, docId: "TEST-E1", data: ["userId": "TEST-sam", "title": "TEST-Fuel", "date": "2026-11-02", "amount": 5],
            organizationId: "TEST-ORG-1330"
        ))
        let rows = CanonicalBusinessEngine.payrunSnapshotRows(
            roster: people,
            organization: org,
            period: try XCTUnwrap(periods.paye),
            inputs: PayrunSnapshotInputs(overtimeRequests: [pending], expenses: [fuel]),
            bookings: [],
            operatives: []
        )
        XCTAssertEqual(rows.map(\.name), ["Lee Manager", "Sam Test"])
        let sam = try XCTUnwrap(rows.last)
        XCTAssertEqual(sam.levelLabel, "Operative")
        XCTAssertEqual(sam.employmentLabel, "PAYE")
        XCTAssertEqual(sam.cells.timesheet.tone, "blocked")
        XCTAssertNil(sam.cells.timesheet.link, "red cells open nothing")
        XCTAssertEqual(sam.cells.overtime.label, "Submitted")
        XCTAssertEqual(sam.cells.overtime.link, PayrunSnapshotLink(kind: "overtime", personId: "TEST-sam", start: "2026-10-26", end: "2026-11-25"))
        XCTAssertEqual(sam.cells.expenses.label, "1 item, no report")
        XCTAssertEqual(sam.cells.expenses.link?.kind, "expenses")
        XCTAssertEqual(sam.cells.priceWork.label, "No items")
        let lee = try XCTUnwrap(rows.first)
        XCTAssertEqual(lee.employmentLabel, "Self-employed")
        XCTAssertEqual(lee.cells.overtime.label, "Self Employed")
        XCTAssertEqual(lee.cells.timesheet.link?.kind, "timesheet")
        XCTAssertEqual(
            CanonicalBusinessEngine.payrunSnapshotColumns,
            ["Name", "User level", "Employment type", "Timesheet", "Overtime", "Expenses", "Price work"]
        )
    }
}
