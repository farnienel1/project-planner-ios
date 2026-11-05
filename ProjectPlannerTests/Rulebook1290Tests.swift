import XCTest
@testable import Project_Planner

/// RULEBOOK 1.29.0 on iOS through `CanonicalBusinessEngine` (`Rulebook+PayeOvertime.swift`): PAYE payday and payruns,
/// PAYE overtime lines and states, the red X, the cog, operative requests and their approval, direct changes, the report
/// snapshot, the weekly report PAYE section and the overtime notices. Every answer comes from the packed script
/// (`payePayrunPeriod`, `payePastPayruns`, `payePaydayWriteFields`, `payeOvertimeLines`, `overtimeStrikeOutcome`,
/// `overtimeCogPreview`, `overtimeRequestLineFields`, `overtimeApprovalWrites`, `overtimeDirectWrites`,
/// `overtimeReportSnapshot`, `weeklyReportPayeOvertime`, …); these tests lock the Swift inputs and readings, the same
/// cases web's `canonical.test.ts` asserts.
@MainActor
final class Rulebook1290Tests: XCTestCase {
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
    ]
    private let range = (start: "2026-11-01", end: "2026-11-30")

    override func setUp() {
        super.setUp()
        OrganizationRulebookContext.update(from: Organization(firestoreDocumentId: "TEST-ORG-129", name: "TEST-Company 129"))
    }

    override func tearDown() {
        OrganizationRulebookContext.update(from: nil)
        super.tearDown()
    }

    private func booking(
        _ id: String,
        _ dayKey: String,
        _ start: String,
        _ end: String,
        person: String = "sam",
        collection: String = "bookings",
        slot: String = "CUSTOM_HOURS",
        rate: Double? = nil,
        status: String? = "Confirmed"
    ) -> OvertimeBookingInput {
        OvertimeBookingInput(
            id: id,
            collection: collection,
            personId: person,
            dayKey: dayKey,
            timeSlot: slot,
            workStartTime: start,
            workEndTime: end,
            isBreakRemoved: false,
            otMultiplierOverride: rate,
            status: status,
            jobId: "job-1",
            jobNumber: "J-1042",
            jobName: "Riverside Flats"
        )
    }

    private func request(_ id: String, _ data: [String: Any]) throws -> OvertimeRequestRecord {
        try XCTUnwrap(CanonicalBusinessEngine.parseOvertimeRequestDocument(docId: id, data: data))
    }

    // MARK: Packed script

    func testThePackedScriptIsRulebook1290OrLaterAndExportsTheOvertimeRules() throws {
        let stamp = try XCTUnwrap(CanonicalBusinessEngine.rulebookStamp())
        let parts = stamp.version.split(separator: ".").compactMap { Int($0) }
        XCTAssertFalse(parts.lexicographicallyPrecedes([1, 29, 0]), "rulebook \(stamp.version) predates 1.29.0")
        let exports = Set(CanonicalBusinessEngine.exportNames())
        for name in [
            "payePayrunPeriod", "payePastPayruns", "payePaydayWriteFields", "payePaydayHistory", "payePayday",
            "payePaydayValidationError", "payeCustomRange", "payeOvertimeLines", "overtimeBookingFingerprint",
            "overtimeLineIsStale", "overtimeStrikeOutcome", "overtimeCogPreview", "overtimeRateControl",
            "overtimeMultiplierWriteFields", "canEditOwnBookingOvertime", "canDecideOvertimeRequest", "overtimeUserSubjects",
            "overtimeHubAccess", "overtimeRequestLineFields", "overtimeRequestWriteFields", "overtimeRequestsToReplace",
            "overtimeRequestWithdrawWriteFields", "overtimeApprovalWrites", "overtimeDirectWrites",
            "overtimeBookingIsTheirs", "overtimeDeciderMayWriteBooking", "parseOvertimeRequestDocument",
            "parseOvertimeReviewDocument", "parseOvertimeReportDocument", "overtimeReportSnapshot", "overtimeReportRows",
            "weeklyReportPayeOvertime", "weeklyReportPayeDay", "overtimeRequestRecipients", "overtimeReviewedRecipients",
            "bookingHoursChangedRecipients", "OVERTIME_CANCEL_WARNING", "PAYE_PAYDAY_NOT_SET_MESSAGE",
        ] {
            XCTAssertTrue(exports.contains(name), "\(name) is not exported")
        }
    }

    // MARK: PAYE payday and payruns (§4.5)

    func testPayrunRunsFromTheDayAfterLastPaydayAndClampsShortMonths() throws {
        let org25: [String: Any] = ["invoicing": ["payePayday": 25, "payePaydayHistory": [["day": 25, "effectiveFrom": "2026-10-26"]]]]
        let run = try XCTUnwrap(CanonicalBusinessEngine.payePayrunPeriod(org25, dayKey: "2026-11-04"))
        XCTAssertEqual([run.start, run.end, run.payDate], ["2026-10-26", "2026-11-25", "2026-11-25"])
        XCTAssertEqual(CanonicalBusinessEngine.payePayrunLabel(run), "PAYE payrun: 26 Oct – 25 Nov · paid 25 Nov")
        // A payday of the 31st is the last day of February (no weekend moves).
        let org31: [String: Any] = ["invoicing": ["payePayday": 31]]
        let feb = try XCTUnwrap(CanonicalBusinessEngine.payePayrunPeriod(org31, dayKey: "2027-02-10"))
        XCTAssertEqual([feb.start, feb.end], ["2027-02-01", "2027-02-28"])
        // No payday: no payrun, and the screens say so.
        XCTAssertNil(CanonicalBusinessEngine.payePayrunPeriod(["invoicing": [String: Any]()], dayKey: "2026-11-04"))
        XCTAssertEqual(CanonicalBusinessEngine.overtimeText("PAYE_PAYDAY_NOT_SET_MESSAGE", fallback: ""), "Ask an admin to set the PAYE payday")
        // Past payruns, newest first.
        let past = CanonicalBusinessEngine.payePastPayruns(["invoicing": ["payePaydayHistory": [["day": 25, "effectiveFrom": "2026-08-26"]]]], todayKey: "2026-11-04")
        XCTAssertEqual(past.map(\.start), ["2026-09-26", "2026-08-26"])
    }

    func testAPaydayChangeAppliesFromTheNextPayrunAndHistoryIsAppendOnly() throws {
        let first = try XCTUnwrap(CanonicalBusinessEngine.payePaydayWriteFields(["invoicing": [String: Any]()], day: 25, todayKey: "2026-11-04"))
        XCTAssertEqual(first["invoicing.payePayday"] as? Int, 25)
        let history = try XCTUnwrap(first["invoicing.payePaydayHistory"] as? [[String: Any]])
        XCTAssertEqual(history.count, 1)
        XCTAssertEqual(history.first?["effectiveFrom"] as? String, "2026-10-26")
        let stored: [String: Any] = ["invoicing": ["payePayday": 25, "payePaydayHistory": history]]
        XCTAssertNil(CanonicalBusinessEngine.payePaydayWriteFields(stored, day: 25, todayKey: "2026-11-04"), "unchanged writes nothing")
        let change = try XCTUnwrap(CanonicalBusinessEngine.payePaydayWriteFields(stored, day: 16, todayKey: "2026-11-04"))
        let next = try XCTUnwrap(change["invoicing.payePaydayHistory"] as? [[String: Any]])
        XCTAssertEqual(next.count, 2)
        XCTAssertEqual(next.last?["effectiveFrom"] as? String, "2026-11-26", "a change starts after the current payrun")
        // The current payrun keeps its dates.
        let merged: [String: Any] = ["invoicing": ["payePayday": 16, "payePaydayHistory": next]]
        XCTAssertEqual(CanonicalBusinessEngine.payePayrunPeriod(merged, dayKey: "2026-11-04")?.end, "2026-11-25")
        XCTAssertNotNil(CanonicalBusinessEngine.payePaydayValidationError(32))
        XCTAssertNil(CanonicalBusinessEngine.payePaydayValidationError(29))
    }

    func testTheOrganisationKeepsThePaydayExactlyAsStored() throws {
        let data: [String: Any] = ["invoicing": [
            "paymentRunMode": "date_ranges",
            "payePayday": 25,
            "payePaydayHistory": [["day": 25, "effectiveFrom": "2026-10-26"]],
        ]]
        let json = OvertimeOrganizationDocument.payePaydayJSON(fromOrganizationData: data)
        let invoicing = OvertimeOrganizationDocument.invoicing(json: json)
        XCTAssertEqual(invoicing["payePayday"] as? Int, 25)
        XCTAssertNil(invoicing["paymentRunMode"], "only the PAYE fields are kept")
        XCTAssertNil(OvertimeOrganizationDocument.payePaydayJSON(fromOrganizationData: ["invoicing": ["paymentRunMode": "date_ranges"]]))
        var organization = Organization(firestoreDocumentId: "TEST-ORG-129", name: "TEST-Company 129")
        organization.payePaydayJSON = json
        let document = OvertimeOrganizationDocument.document(organization)
        XCTAssertEqual(CanonicalBusinessEngine.payePayday(document), 25)
        let encoded = try JSONEncoder().encode(organization)
        XCTAssertEqual(try JSONDecoder().decode(Organization.self, from: encoded).payePaydayJSON, json)
    }

    // MARK: Lines and states (§25)

    func testLinesFollowTheWorkingHoursOfEachDay() {
        let bookings = [
            booking("B1", "2026-11-04", "06:30", "14:00"),
            booking("B2", "2026-11-05", "07:30", "18:00"),
            booking("B3", "2026-11-07", "07:30", "15:00"),
            booking("B4", "2026-11-08", "07:30", "14:00"),
            booking("B5", "2026-11-03", "07:30", "16:00"),
            booking("B6", "2026-11-02", "07:30", "16:10"),
            booking("OTHER", "2026-11-02", "18:00", "21:00", person: "someone-else"),
        ]
        let lines = CanonicalBusinessEngine.payeOvertimeLines(
            personIds: ["SAM"], bookings: bookings, organization: org, range: range, reviews: [], requests: []
        )
        XCTAssertEqual(lines.map(\.bookingId), ["B1", "B2", "B3", "B4"], "under 15 minutes and other people's bookings are not lines")
        XCTAssertEqual(lines.map { $0.figures?.text ?? "" }, ["1h × 1.5 = 1.5h", "2h × 1.5 = 3h", "1h × 1.5 = 1.5h", "6.5h × 2 = 13h"])
        XCTAssertEqual(lines.first?.title, "J-1042 · Riverside Flats")
        XCTAssertEqual(lines.first?.state, "needsReview")
        XCTAssertEqual(CanonicalBusinessEngine.overtimeLinesTotal(lines), 19, accuracy: 0.001)
    }

    func testLineStatesAndStaleness() throws {
        let b1 = booking("B1", "2026-11-04", "06:30", "14:00")
        let fingerprint = CanonicalBusinessEngine.overtimeBookingFingerprint(b1)
        XCTAssertEqual(fingerprint, "2026-11-04|CUSTOM HOURS|06:30|14:00|||confirmed")
        let review = try XCTUnwrap(CanonicalBusinessEngine.parseOvertimeReviewDocument(
            docId: "sam_B1", data: ["userId": "sam", "bookingId": "B1", "decision": "approved", "fingerprint": fingerprint]
        ))
        func state(_ booking: OvertimeBookingInput, reviews: [OvertimeReviewRecord] = [], requests: [OvertimeRequestRecord] = []) -> String? {
            CanonicalBusinessEngine.payeOvertimeLines(
                personIds: ["sam"], bookings: [booking], organization: org, range: range, reviews: reviews, requests: requests
            ).first?.state
        }
        XCTAssertEqual(state(b1, reviews: [review]), "approved")
        var moved = b1
        moved.workEndTime = "15:00"
        XCTAssertTrue(CanonicalBusinessEngine.overtimeLineIsStale(storedFingerprint: fingerprint, booking: moved))
        XCTAssertTrue(CanonicalBusinessEngine.overtimeLineIsStale(storedFingerprint: fingerprint, booking: nil))
        XCTAssertEqual(state(moved, reviews: [review]), "needsReview", "a change after a decision goes back to Needs review")
        let line = try XCTUnwrap(CanonicalBusinessEngine.overtimeRequestLineFields(b1, organization: org, proposal: .keep, personIds: nil))
        let pending = try request("R1", ["userId": "sam", "rangeStart": range.start, "rangeEnd": range.end, "status": "pending", "lines": [line.raw]])
        XCTAssertEqual(state(b1, requests: [pending]), "waiting")
        XCTAssertEqual(state(moved, requests: [pending]), "changedSinceRequest")
        let approvedLines = CanonicalBusinessEngine.payeOvertimeLines(
            personIds: ["sam"], bookings: [b1], organization: org, range: range, reviews: [review], requests: []
        )
        XCTAssertTrue(CanonicalBusinessEngine.canGenerateOvertimeReport(approvedLines))
        XCTAssertFalse(CanonicalBusinessEngine.canGenerateOvertimeReport([]))
    }

    // MARK: The red X and the cog

    func testStrikeTrimsOrCancelsWithTheSharedWarning() throws {
        let trim = try XCTUnwrap(CanonicalBusinessEngine.overtimeStrikeOutcome(booking("B1", "2026-11-04", "06:30", "14:00"), organization: org))
        XCTAssertEqual([trim.kind, trim.start, trim.end], ["trim", "07:30", "14:00"])
        let window = try XCTUnwrap(CanonicalBusinessEngine.overtimeStrikeOutcome(booking("B3", "2026-11-07", "07:30", "15:00"), organization: org))
        XCTAssertEqual([window.kind, window.end], ["trim", "14:00"], "a weekend set window is trimmed to the window")
        XCTAssertEqual(CanonicalBusinessEngine.overtimeStrikeOutcome(booking("B5", "2026-11-03", "07:30", "16:00"), organization: org)?.kind, "none")
        let sunday = try XCTUnwrap(CanonicalBusinessEngine.overtimeStrikeOutcome(booking("B4", "2026-11-08", "07:30", "14:00"), organization: org))
        XCTAssertEqual(sunday.kind, "cancel", "a weekend paid at a multiplier only is cancelled")
        XCTAssertEqual(sunday.warning?.summary, "Sun 8 Nov · J-1042 Riverside Flats · 07:30–14:00")
        XCTAssertEqual(sunday.warning?.title, "Remove this booking?")
        XCTAssertEqual(sunday.warning?.confirm, "Remove booking")
        XCTAssertEqual(sunday.warning?.back, "Go back")
        XCTAssertEqual(sunday.warning?.footnote, "A manager can restore it if this was a mistake.")
        XCTAssertEqual(CanonicalBusinessEngine.overtimeCancelWarning?.body, sunday.warning?.body)
        XCTAssertEqual(CanonicalBusinessEngine.overtimeStrikeOutcome(booking("B7", "2026-11-02", "18:00", "21:00"), organization: org)?.kind,
                       "cancel", "a weekday booking all outside the day is cancelled")
        XCTAssertEqual(CanonicalBusinessEngine.overtimeStrikeOutcome(
            booking("M", "2026-11-02", "18:00", "21:00", collection: "managerSiteBookings"), organization: org
        )?.kind, "notAllowed")
    }

    func testCogPreviewAndTheRateSteps() throws {
        let b2 = booking("B2", "2026-11-05", "07:30", "18:00")
        let preview = try XCTUnwrap(CanonicalBusinessEngine.overtimeCogPreview(b2, organization: org, start: "07:30", end: "19:00", multiplier: 2))
        XCTAssertEqual([preview.beforeText, preview.afterText], ["2h × 1.5 = 3h", "3h × 2 = 6h"])
        XCTAssertTrue(preview.changed)
        XCTAssertNil(preview.error)
        XCTAssertNotNil(CanonicalBusinessEngine.overtimeCogPreview(b2, organization: org, start: "07:30", end: "18:00", multiplier: 1.1)?.error)
        XCTAssertEqual(CanonicalBusinessEngine.overtimeMultiplierSteps, [1, 1.25, 1.5, 1.75, 2, 2.25, 2.5, 2.75, 3])
        XCTAssertNil(CanonicalBusinessEngine.overtimeMultiplierValidationError(nil))
        XCTAssertNotNil(CanonicalBusinessEngine.overtimeMultiplierValidationError(3.25))
        let control = try XCTUnwrap(CanonicalBusinessEngine.overtimeRateControl(booking("B2", "2026-11-05", "07:30", "18:00", rate: 2), organization: org))
        XCTAssertTrue(control.show)
        XCTAssertEqual(control.organizationLabel, "Organisation (×1.5)")
        XCTAssertEqual(control.customMultiplier, 2)
        XCTAssertEqual(CanonicalBusinessEngine.overtimeMultiplierWriteFields(stored: 2, next: nil)?.remove, ["otMultiplierOverride"])
        XCTAssertEqual(CanonicalBusinessEngine.overtimeMultiplierWriteFields(stored: nil, next: 2.5)?.set["otMultiplierOverride"] as? Double, 2.5)
    }

    /// The organisation rate on a counter-change is sent as JSON null, never left out (left out = "leave the rate").
    func testAnOrganisationRateDecisionIsSentAsNull() throws {
        let decision = OvertimeAction.edit(start: "07:30", end: "18:00", multiplier: nil).decisionJSON
        XCTAssertTrue(decision.keys.contains("multiplier"))
        XCTAssertTrue(decision["multiplier"] is NSNull)
        let b2 = booking("B2", "2026-11-05", "07:30", "18:00", rate: 2)
        let plan = try XCTUnwrap(CanonicalBusinessEngine.overtimeDirectWrites(
            b2, action: .edit(start: "07:30", end: "18:00", multiplier: nil), userId: "lm", reviewerId: "lm", organization: org
        ))
        XCTAssertEqual(plan.bookingWrite?.remove, ["otMultiplierOverride"])
        XCTAssertTrue(plan.hoursChanged)
    }

    // MARK: Requests and approval

    func testApprovalWritesEverythingOnceAndRefusesStaleOrForeignLines() throws {
        let b1 = booking("B1", "2026-11-04", "06:30", "14:00")
        let b2 = booking("B2", "2026-11-05", "07:30", "18:00")
        let b4 = booking("B4", "2026-11-08", "07:30", "14:00")
        let gone = booking("GONE", "2026-11-06", "07:30", "17:00")
        let lines = try [
            XCTUnwrap(CanonicalBusinessEngine.overtimeRequestLineFields(b1, organization: org, proposal: .keep, personIds: ["sam"])),
            XCTUnwrap(CanonicalBusinessEngine.overtimeRequestLineFields(b2, organization: org, proposal: .edit(start: "07:30", end: "19:00", multiplier: 2), personIds: ["sam"])),
            XCTUnwrap(CanonicalBusinessEngine.overtimeRequestLineFields(b4, organization: org, proposal: .strike, personIds: ["sam"])),
            XCTUnwrap(CanonicalBusinessEngine.overtimeRequestLineFields(gone, organization: org, proposal: .keep, personIds: ["sam"])),
        ]
        XCTAssertEqual([lines[1].line.overtimeHoursBefore, lines[1].line.overtimeHoursAfter], [3, 6])
        XCTAssertTrue(lines[2].line.cancel, "the red X on a multiplier-only Sunday asks to cancel")
        XCTAssertNil(CanonicalBusinessEngine.overtimeRequestLineFields(
            booking("X1", "2026-11-04", "06:30", "14:00", person: "someone-else"), organization: org, proposal: .strike, personIds: ["sam"]
        ), "a request never names someone else's booking")
        let fields = try XCTUnwrap(CanonicalBusinessEngine.overtimeRequestWriteFields(
            userId: "sam", rangeStart: range.start, rangeEnd: range.end, lines: lines.map(\.raw), personIds: ["sam"], bookings: [b1, b2, b4, gone]
        ))
        XCTAssertEqual(fields["status"] as? String, "pending")
        XCTAssertEqual(Set(fields.keys), ["userId", "rangeStart", "rangeEnd", "status", "lines"], "only the fields the security rules allow")
        var stored = fields
        stored["createdAt"] = 1
        let pending = try request("R1", stored)
        let decisions: [String: OvertimeAction] = [
            "B1": .approve,
            "B2": .edit(start: "07:30", end: "18:30", multiplier: 1.5),
            "B4": .approve,
            "GONE": .approve,
        ]
        // RULEBOOK 1.32.0: one Approve, enabled once any line is decided (`overtimeRequestAnyDecided`).
        XCTAssertFalse(CanonicalBusinessEngine.overtimeRequestAnyDecided(pending, decisions: [:]))
        XCTAssertTrue(CanonicalBusinessEngine.overtimeRequestAnyDecided(pending, decisions: ["B1": .approve]))
        func approve(_ live: [String: OvertimeBookingInput], requesterIds: [String] = ["sam"]) -> OvertimeApprovalPlan? {
            CanonicalBusinessEngine.overtimeApprovalWrites(
                request: pending, decisions: decisions, bookings: live, organization: org, deciderId: "lm",
                requesterIds: requesterIds, deciderIsAdmin: true, writableBookingIds: [], unreadableBookingIds: []
            )
        }
        let plan = try XCTUnwrap(approve(["B1": b1, "B2": b2, "B4": b4]))
        XCTAssertTrue(plan.ok, "the approval is refused")
        XCTAssertEqual(plan.bookingWrites.map(\.bookingId), ["B2", "B4"])
        XCTAssertEqual(plan.bookingWrites.first?.set["workEndTime"] as? String, "18:30")
        XCTAssertEqual(plan.bookingWrites.first?.set["otMultiplierOverride"] as? Double, 1.5)
        XCTAssertEqual(plan.bookingWrites.last?.set["status"] as? String, "Cancelled", "cancelled, never deleted")
        XCTAssertEqual(plan.reviewWrites.map(\.docId), ["sam_B1", "sam_B2", "sam_B4"])
        XCTAssertEqual(plan.reviewWrites.map { $0.fields["decision"] as? String ?? "" }, ["approved", "edited", "cancelled"])
        XCTAssertEqual(plan.deletedBookingIds, ["GONE"])
        XCTAssertTrue(plan.complete)
        XCTAssertEqual(plan.requestFields["status"] as? String, "approved")
        XCTAssertEqual(plan.requestFields["decidedBy"] as? String, "lm")
        // 1.32.0: a booking changed after sending stays waiting on its own; the other lines are applied.
        var changed = b1
        changed.workStartTime = "06:00"
        let stale = try XCTUnwrap(approve(["B1": changed, "B2": b2, "B4": b4]))
        XCTAssertTrue(stale.ok, "a changed booking no longer refuses the whole approval")
        XCTAssertEqual(stale.lineOutcomes["B1"], "stale")
        XCTAssertEqual(stale.waitingBookingIds, ["B1"])
        XCTAssertEqual(stale.appliedBookingIds, ["B2", "B4"])
        XCTAssertFalse(stale.complete)
        XCTAssertEqual(stale.requestFields["status"] as? String, "pending", "the request stays pending until complete")
        // A booking that is not the requester's is left out, never written; with nothing applied, nothing is approved.
        let foreign = try XCTUnwrap(approve(["B1": b1, "B2": b2, "B4": b4], requesterIds: ["sam-other-id"]))
        XCTAssertFalse(foreign.ok)
        XCTAssertEqual(foreign.reason, "nothingApproved")
        XCTAssertTrue(foreign.bookingWrites.isEmpty)
        XCTAssertEqual(foreign.lineOutcomes["B1"], "foreign")
        XCTAssertEqual(foreign.lineOutcomes["B2"], "foreign")
        XCTAssertEqual(foreign.lineOutcomes["B4"], "foreign")
        // A line manager who is not an admin may not decide a booking filed under an operatives row id (§16, owner
        // decision A): that line waits as "Needs an admin"; the rest is applied.
        var underRow = b2
        underRow.personId = "OP-ROW"
        let notAdmin = try XCTUnwrap(CanonicalBusinessEngine.overtimeApprovalWrites(
            request: pending, decisions: decisions, bookings: ["B1": b1, "B2": underRow, "B4": b4], organization: org, deciderId: "lm",
            requesterIds: ["sam", "OP-ROW"], deciderIsAdmin: false, writableBookingIds: [], unreadableBookingIds: []
        ))
        XCTAssertTrue(notAdmin.ok)
        XCTAssertEqual(notAdmin.lineOutcomes["B2"], "needsAdmin")
        XCTAssertEqual(notAdmin.waitingBookingIds, ["B2"])
        XCTAssertEqual(CanonicalBusinessEngine.overtimeLineOutcomeLabel(notAdmin.lineOutcomes["B2"]), "Needs an admin")
        XCTAssertTrue(CanonicalBusinessEngine.overtimeDeciderMayWriteBooking(b2, requesterUserId: "sam", deciderIsAdmin: false, writableBookingIds: []))
        XCTAssertFalse(CanonicalBusinessEngine.overtimeDeciderMayWriteBooking(
            booking("B9", "2026-11-05", "07:30", "18:00", person: "OP-ROW"), requesterUserId: "sam", deciderIsAdmin: false, writableBookingIds: []
        ))
        // Sending again withdraws the pending request for the same range.
        XCTAssertEqual(CanonicalBusinessEngine.overtimeRequestsToReplace([pending], userId: "SAM", rangeStart: range.start, rangeEnd: range.end), ["R1"])
        XCTAssertEqual(CanonicalBusinessEngine.overtimeRequestWithdrawWriteFields(pending)?["status"] as? String, "withdrawn")
    }

    // MARK: Who, notices, report, weekly report

    func testWhoDecidesAndWhoIsNotified() {
        let roster: [[String: Any]] = [
            ["id": "sam", "email": "sam@x.test", "isActive": true, "role": ["isOperativeMode": true], "assignedManagerUserIds": ["lm"], "employmentType": "paye"],
            ["id": "lm", "email": "lm@x.test", "isActive": true, "role": ["isManager": true], "assignedManagerUserIds": ["admin"]],
            ["id": "admin", "email": "admin@x.test", "isActive": true, "role": ["isAdmin": true]],
            ["id": "admin2", "email": "admin2@x.test", "isActive": true, "role": ["isAdmin": true]],
            ["id": "op2", "email": "op2@x.test", "isActive": true, "role": ["isOperativeMode": true], "assignedManagerUserIds": ["admin"]],
        ]
        let sam = roster[0]
        XCTAssertTrue(CanonicalBusinessEngine.canDecideOvertimeRequest(viewer: ["id": "lm", "role": ["isManager": true]], requester: sam, roster: roster))
        XCTAssertFalse(CanonicalBusinessEngine.canDecideOvertimeRequest(viewer: ["id": "sam", "role": ["isAdmin": true]], requester: sam, roster: roster))
        XCTAssertFalse(CanonicalBusinessEngine.canDecideOvertimeRequest(viewer: ["id": "op2", "role": ["isOperativeMode": true]], requester: sam, roster: roster))
        XCTAssertEqual(CanonicalBusinessEngine.overtimeUserSubjects(viewer: ["id": "lm", "role": ["isManager": true]], roster: roster), ["sam"])
        XCTAssertEqual(CanonicalBusinessEngine.overtimeHubAccess(viewer: sam, roster: roster), OvertimeHubAccess(showButton: true, mine: true, users: false))
        XCTAssertEqual(CanonicalBusinessEngine.overtimeHubAccess(viewer: roster[4], roster: roster), .hidden)
        XCTAssertEqual(CanonicalBusinessEngine.overtimeRequestRecipients(requester: "sam", roster: roster), ["lm", "admin", "admin2"])
        XCTAssertEqual(CanonicalBusinessEngine.overtimeReviewedRecipients(requester: "sam", decider: "sam", roster: roster), [])
        XCTAssertEqual(CanonicalBusinessEngine.bookingHoursChangedRecipients(owner: "lm", jobManagerIds: ["lm", "admin2"], roster: roster), ["admin2", "admin"])
        let viewer = JobAccessViewer(
            role: CanonicalBusinessEngine.CanonicalStaffAccountRole(isSuperAdmin: false, isAdmin: false, isManager: false, isOperativeMode: true),
            projectsToggle: false, smallWorksToggle: false, uid: "sam", ids: ["sam"], email: "sam@x.test"
        )
        XCTAssertEqual(CanonicalBusinessEngine.canEditOwnBookingOvertime(
            viewer: viewer, isPaye: true, booking: ["collection": "bookings", "projectId": "job-1", "dayKey": "2026-11-04"],
            job: ["managerUserIds": ["lm"]], managers: [], todayKey: "2026-11-04", editableUntilKey: nil, person: sam, roster: roster
        ), .request, "a PAYE operative's changes are requests")
        // 1.32.0 (option 2): with no PAYE payday the last editable day is today, so a future booking stays locked.
        XCTAssertEqual(CanonicalBusinessEngine.canEditOwnBookingOvertime(
            viewer: viewer, isPaye: true, booking: ["collection": "bookings", "projectId": "job-1", "dayKey": "2026-11-05"],
            job: nil, managers: [], todayKey: "2026-11-04",
            editableUntilKey: CanonicalBusinessEngine.overtimeEditableUntil(["invoicing": [String: Any]()], todayKey: "2026-11-04"),
            person: sam, roster: roster
        ), .readOnly, "a booking after the last editable day has no overtime to change")
    }

    func testNoticeTypesTogglesAndDestinations() {
        for type in ["overtime_request_submitted", "overtime_request_reviewed", "booking_hours_changed_by_owner"] {
            XCTAssertNotEqual(AppNotification.NotificationType(stored: type), .unknown, type)
            XCTAssertTrue(CanonicalBusinessEngine.knownNotificationTypes.contains(type), type)
        }
        XCTAssertEqual(CanonicalBusinessEngine.notificationDeliversDevicePush("overtime_request_submitted"), true)
        XCTAssertEqual(CanonicalBusinessEngine.notificationDeliversDevicePush("booking_hours_changed_by_owner"), false)
        XCTAssertEqual(CanonicalBusinessEngine.notificationPreferenceAllowsDelivery(prefs: ["overtime": false], type: "overtime_request_reviewed"), false)
        XCTAssertEqual(CanonicalBusinessEngine.notificationDestination(
            type: "overtime_request_submitted", relatedId: "R1", dayKey: nil, catalogue: nil, role: "manager", deepLinkUserId: "sam"
        ), CanonicalBusinessEngine.CanonicalNotificationDestination(kind: "overtimeUser", relatedId: "R1", dayKey: nil, userId: "sam"))
        XCTAssertEqual(CanonicalBusinessEngine.notificationDestination(
            type: "overtime_request_reviewed", relatedId: "R1", dayKey: nil, catalogue: nil, role: "operative", deepLinkUserId: nil
        )?.kind, "overtimeMine")
        let row = AppNotification(organizationId: "TEST-ORG", type: .overtimeRequestSubmitted, title: "t", message: "m", userId: "lm", relatedKey: "REQ-1")
        XCTAssertEqual(FirebaseBackend.notificationRelatedId(for: row), "REQ-1", "the request id is the related id")
        let hours = AppNotification(organizationId: "TEST-ORG", type: .bookingHoursChangedByOwner, title: "t", message: "m", userId: "lm", relatedKey: "B1")
        XCTAssertEqual(FirebaseBackend.notificationRelatedId(for: hours), "B1")
        XCTAssertEqual(IOSLiveListenerCoverage.uncoveredListenIds(), [])
    }

    func testReportSnapshotRoundTripsAndTheWeeklyReportPayeSection() throws {
        let b1 = booking("B1", "2026-11-04", "06:30", "14:00")
        let lines = CanonicalBusinessEngine.payeOvertimeLines(personIds: ["sam"], bookings: [b1], organization: org, range: range, reviews: [], requests: [])
        let snapshot = try XCTUnwrap(CanonicalBusinessEngine.overtimeReportSnapshot(
            userId: "sam", userName: "Sam", companyName: "TEST-Acme", rangeStart: "2026-10-26", rangeEnd: "2026-11-25", lines: lines, generatedBy: "sam"
        ))
        XCTAssertEqual(snapshot["kind"] as? String, "overtime")
        let report = try XCTUnwrap(CanonicalBusinessEngine.parseOvertimeReportDocument(docId: "REP1", data: snapshot))
        XCTAssertEqual(report.overtimeHours, 1.5, accuracy: 0.001)
        let rows = try XCTUnwrap(CanonicalBusinessEngine.overtimeReportRows(report.raw))
        XCTAssertEqual(rows.title, "Overtime report · Sam")
        XCTAssertEqual(rows.rows, ["Wed 4 Nov · J-1042 Riverside Flats · 06:30–14:00 · 1h × 1.5 = 1.5h"])
        XCTAssertEqual(rows.total, "Total overtime: 1.5h")
        let people: [[String: Any]] = [
            ["id": "sam", "name": "Sam", "employmentType": "paye"],
            ["id": "pat", "name": "Pat", "employmentType": "self_employed"],
        ]
        let section = CanonicalBusinessEngine.weeklyReportPayeOvertime(
            people: people,
            bookings: [b1, booking("B2", "2026-11-05", "07:30", "18:00"), booking("P1", "2026-11-05", "07:30", "18:00", person: "pat")],
            organization: org,
            range: ("2026-11-02", "2026-11-08")
        )
        XCTAssertEqual(section.map(\.label), ["Sam · J-1042 · 4.5h"])
        XCTAssertTrue(CanonicalBusinessEngine.weeklyReportPayeDay(employment: people[0], dayKey: "2026-11-04"))
        XCTAssertFalse(CanonicalBusinessEngine.weeklyReportPayeDay(employment: people[1], dayKey: "2026-11-04"))
        let switching: [String: Any] = ["employmentType": "paye", "employmentTypeTransitionFrom": "self_employed", "employmentTypeEffectiveAt": "2026-11-05T00:00:00Z"]
        XCTAssertFalse(CanonicalBusinessEngine.weeklyReportPayeDay(employment: switching, dayKey: "2026-11-04"))
        XCTAssertTrue(CanonicalBusinessEngine.weeklyReportPayeDay(employment: switching, dayKey: "2026-11-05"))
    }

    // MARK: Manager site booking rate (§8, §25)

    func testManagerSiteBookingsCarryTheirOvertimeRate() {
        let documents: [[String: Any]] = [[
            "id": "MSB-1",
            "data": [
                "userId": "lm", "date": ["seconds": 1_793_750_400, "nanoseconds": 0], "timeSlot": "CUSTOM_HOURS",
                "locationType": "project", "locationId": "job-1", "workStartTime": "07:30", "workEndTime": "18:00",
                "otMultiplierOverride": 2,
            ] as [String: Any],
        ]]
        XCTAssertEqual(OvertimeBookingInputs.managerSiteRates(documents: documents)["MSB-1"], 2)
        var old = ManagerSiteBooking(userId: "lm", date: Date(), timeSlot: .customHours, locationType: .office)
        old.otMultiplierOverride = nil
        var new = old
        new.otMultiplierOverride = 2.5
        XCTAssertEqual(BookingWritePatch.changedManagerFields(from: old, to: new), ["otMultiplierOverride"])
        XCTAssertEqual(BookingWritePatch.managerValues(new, deletesClearedFields: true)["otMultiplierOverride"] as? Double, 2.5)
        XCTAssertTrue(BookingWritePatch.managerFieldNames.contains("otMultiplierOverride"))
    }
}
