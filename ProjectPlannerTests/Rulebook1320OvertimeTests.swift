import XCTest
@testable import Project_Planner

/// RULEBOOK 1.32.0 iOS follow-on, PAYE overtime (§25, web hand-off v1.32.0): partial approval (`overtimeApprovalWrites`
/// → `lineOutcomes`, `waitingBookingIds`, `appliedBookingIds`, `complete`, `message`), one Approve
/// (`OVERTIME_APPROVE_LABEL`, `overtimeRequestAnyDecided`), per-line labels (`overtimeLineOutcomeLabel`,
/// `OVERTIME_NEEDS_ADMIN_LABEL`), all records for this person (`overtimePersonIds`), future days of the current payrun
/// (`overtimeEditableUntil`) and own edits as requests with a line manager (`canEditOwnBookingOvertime({ person, roster })`).
/// Every answer comes from the packed script through `CanonicalBusinessEngine`; these tests lock the Swift readings.
@MainActor
final class Rulebook1320OvertimeTests: XCTestCase {
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
        "invoicing": ["payePayday": 25] as [String: Any],
    ]

    override func setUp() {
        super.setUp()
        OrganizationRulebookContext.update(from: Organization(firestoreDocumentId: "TEST-ORG-1320", name: "TEST-Company 1320"))
    }

    override func tearDown() {
        OrganizationRulebookContext.update(from: nil)
        super.tearDown()
    }

    private func booking(_ id: String, _ dayKey: String, _ start: String, _ end: String, person: String = "TEST-sam") -> OvertimeBookingInput {
        OvertimeBookingInput(
            id: id,
            collection: "bookings",
            personId: person,
            dayKey: dayKey,
            timeSlot: "CUSTOM_HOURS",
            workStartTime: start,
            workEndTime: end,
            isBreakRemoved: false,
            otMultiplierOverride: nil,
            status: "Confirmed",
            jobId: "TEST-job-1",
            jobNumber: "J-1",
            jobName: "TEST Site"
        )
    }

    private func viewer(_ role: CanonicalBusinessEngine.CanonicalStaffAccountRole, id: String) -> JobAccessViewer {
        JobAccessViewer(role: role, projectsToggle: false, smallWorksToggle: false, uid: id, ids: [id], email: "\(id)@x.test")
    }

    // MARK: Packed script

    func testThePackedScriptIs1320OrLaterAndExportsTheNewOvertimeRules() throws {
        let version = try XCTUnwrap(CanonicalBusinessEngine.rulebookStamp()?.version)
        XCTAssertNotEqual(version.compare("1.32.0", options: .numeric), .orderedAscending, "rulebook \(version) is older than 1.32.0")
        let exports = Set(CanonicalBusinessEngine.exportNames())
        for name in [
            "overtimePersonIds", "overtimeEditableUntil", "overtimeRequestAnyDecided", "overtimeLineOutcomeLabel",
            "reviewApprovalMessage", "OVERTIME_APPROVE_LABEL", "OVERTIME_NEEDS_ADMIN_LABEL",
        ] {
            XCTAssertTrue(exports.contains(name), "\(name) is not exported")
        }
        XCTAssertEqual(CanonicalBusinessEngine.overtimeText("OVERTIME_APPROVE_LABEL", fallback: ""), "Approve")
        XCTAssertEqual(CanonicalBusinessEngine.overtimeText("OVERTIME_NEEDS_ADMIN_LABEL", fallback: ""), "Needs an admin")
    }

    // MARK: All records for this person

    func testOvertimePersonIdsTakesEveryIdAndEveryOperativesRowOnTheirEmail() {
        let person: [String: Any] = ["id": "TEST-u1", "email": "a@x.test"]
        let roster: [[String: Any]] = [["id": "TEST-u1", "email": "a@x.test"], ["id": "TEST-u2", "email": "A@x.test"]]
        let operatives: [[String: Any]] = [["id": "TEST-op1", "email": "a@x.test"], ["id": "TEST-op2", "email": "b@x.test"]]
        XCTAssertEqual(
            CanonicalBusinessEngine.overtimePersonIds(person: person, roster: roster, operatives: operatives),
            ["TEST-u1", "TEST-u2", "TEST-op1"]
        )
        XCTAssertEqual(CanonicalBusinessEngine.overtimePersonIds(person: [:], roster: roster, operatives: operatives), [])
    }

    // MARK: Who may change their own overtime

    func testFutureDaysOfTheCurrentPayrunAreEditableAndLaterPayrunsStayLocked() {
        XCTAssertEqual(CanonicalBusinessEngine.overtimeEditableUntil(org, todayKey: "2026-11-05"), "2026-11-25")
        XCTAssertEqual(CanonicalBusinessEngine.overtimeEditableUntil(["invoicing": [String: Any]()], todayKey: "2026-11-05"), "2026-11-05")
        let sam: [String: Any] = [
            "id": "TEST-sam", "email": "TEST-sam@x.test", "isActive": true, "role": ["isOperativeMode": true],
            "assignedManagerUserIds": ["TEST-lm"], "employmentType": "paye",
        ]
        let roster: [[String: Any]] = [sam, ["id": "TEST-lm", "email": "TEST-lm@x.test", "isActive": true, "role": ["isManager": true]]]
        let operative = viewer(.init(isSuperAdmin: false, isAdmin: false, isManager: false, isOperativeMode: true), id: "TEST-sam")
        let until = CanonicalBusinessEngine.overtimeEditableUntil(org, todayKey: "2026-11-05")
        func mode(_ dayKey: String) -> OvertimeEditMode {
            CanonicalBusinessEngine.canEditOwnBookingOvertime(
                viewer: operative, isPaye: true, booking: ["collection": "bookings", "projectId": "TEST-job-1", "dayKey": dayKey],
                job: nil, managers: [], todayKey: "2026-11-05", editableUntilKey: until, person: sam, roster: roster
            )
        }
        XCTAssertEqual(mode("2026-11-20"), .request, "a future day in the current payrun may be changed")
        XCTAssertEqual(mode("2026-11-26"), .readOnly, "the next payrun stays locked")
    }

    func testOwnEditsAreRequestsWhenThePersonHasALineManager() {
        let admin = viewer(.init(isSuperAdmin: false, isAdmin: true, isManager: false, isOperativeMode: false), id: "TEST-adm")
        let lm: [String: Any] = ["id": "TEST-lm", "email": "TEST-lm@x.test", "isActive": true, "role": ["isManager": true]]
        let noManager: [String: Any] = [
            "id": "TEST-adm", "email": "TEST-adm@x.test", "isActive": true, "role": ["isAdmin": true], "isAdmin": true,
            "adminAccess": true, "hasNoLineManager": true, "employmentType": "paye",
        ]
        var withManager = noManager
        withManager["hasNoLineManager"] = false
        withManager["assignedManagerUserIds"] = ["TEST-lm"]
        let row: [String: Any] = ["collection": "bookings", "projectId": "TEST-job-1", "dayKey": "2026-11-04"]
        XCTAssertEqual(CanonicalBusinessEngine.canEditOwnBookingOvertime(
            viewer: admin, isPaye: true, booking: row, job: nil, managers: [], todayKey: "2026-11-05",
            editableUntilKey: "2026-11-25", person: noManager, roster: [noManager, lm]
        ), .direct, "an admin with no line manager changes their own overtime directly")
        XCTAssertEqual(CanonicalBusinessEngine.canEditOwnBookingOvertime(
            viewer: admin, isPaye: true, booking: row, job: nil, managers: [], todayKey: "2026-11-05",
            editableUntilKey: "2026-11-25", person: withManager, roster: [withManager, lm]
        ), .request, "anyone with an active line manager sends a request")
    }

    // MARK: Partial approval

    func testApprovalAppliesWhatTheDeciderMayAndLeavesTheRestWaiting() throws {
        let b1 = booking("TEST-B1", "2026-11-04", "06:30", "14:00")
        let b2 = booking("TEST-B2", "2026-11-05", "07:30", "18:00")
        let b3 = booking("TEST-B3", "2026-11-03", "07:30", "17:30", person: "TEST-op1")
        let ids = ["TEST-sam", "TEST-op1"]
        let lines = try [b1, b2, b3].map {
            try XCTUnwrap(CanonicalBusinessEngine.overtimeRequestLineFields($0, organization: org, proposal: .keep, personIds: ids)).raw
        }
        var stored = try XCTUnwrap(CanonicalBusinessEngine.overtimeRequestWriteFields(
            userId: "TEST-sam", rangeStart: "2026-10-26", rangeEnd: "2026-11-25", lines: lines, personIds: ids, bookings: [b1, b2, b3]
        ))
        stored["createdAt"] = 1
        let request = try XCTUnwrap(CanonicalBusinessEngine.parseOvertimeRequestDocument(docId: "TEST-R1", data: stored))
        XCTAssertEqual(request.appliedBookingIds, [])

        // One Approve, enabled once any line is decided.
        XCTAssertFalse(CanonicalBusinessEngine.overtimeRequestAnyDecided(request, decisions: [:]))
        XCTAssertTrue(CanonicalBusinessEngine.overtimeRequestAnyDecided(request, decisions: ["TEST-B1": .approve]))

        // A line manager (not an admin): B1 applied, B2 changed since the request (waits), B3 under an operatives row
        // (owner decision A: needs an admin).
        var changed = b2
        changed.workEndTime = "19:00"
        let decisions: [String: OvertimeAction] = ["TEST-B1": .approve, "TEST-B2": .approve, "TEST-B3": .approve]
        let plan = try XCTUnwrap(CanonicalBusinessEngine.overtimeApprovalWrites(
            request: request, decisions: decisions, bookings: ["TEST-B1": b1, "TEST-B2": changed, "TEST-B3": b3], organization: org,
            deciderId: "TEST-lm", requesterIds: ids, deciderIsAdmin: false, writableBookingIds: [], unreadableBookingIds: []
        ))
        XCTAssertTrue(plan.ok)
        XCTAssertNil(plan.refusalMessage)
        XCTAssertEqual(plan.appliedBookingIds, ["TEST-B1"])
        XCTAssertEqual(plan.waitingBookingIds, ["TEST-B2", "TEST-B3"])
        XCTAssertEqual(plan.lineOutcomes, ["TEST-B1": "applied", "TEST-B2": "stale", "TEST-B3": "needsAdmin"])
        XCTAssertFalse(plan.complete)
        XCTAssertEqual(plan.message, "Approved 1 of 3. 1 needs an admin; 1 changed since the request.")
        XCTAssertEqual(plan.reviewWrites.map(\.docId), ["TEST-sam_TEST-B1"])
        XCTAssertEqual(plan.requestFields["status"] as? String, "pending", "the request stays pending until complete")
        XCTAssertEqual(plan.requestFields["appliedBookingIds"] as? [String], ["TEST-B1"])
        XCTAssertEqual(CanonicalBusinessEngine.overtimeLineOutcomeLabel(plan.lineOutcomes["TEST-B3"]), "Needs an admin")
        XCTAssertEqual(
            CanonicalBusinessEngine.overtimeLineOutcomeLabel(plan.lineOutcomes["TEST-B2"]),
            CanonicalBusinessEngine.overtimeText("OVERTIME_CHANGED_SINCE_REQUEST_LINE_MESSAGE", fallback: "")
        )
        XCTAssertNil(CanonicalBusinessEngine.overtimeLineOutcomeLabel(plan.lineOutcomes["TEST-B1"]))

        // The stored request after that approval: B1 is done; deciding only B1 again enables nothing.
        var after = stored
        for (key, value) in plan.requestFields { after[key] = value }
        let partial = try XCTUnwrap(CanonicalBusinessEngine.parseOvertimeRequestDocument(docId: "TEST-R1", data: after))
        XCTAssertTrue(partial.isPending)
        XCTAssertEqual(partial.appliedBookingIds, ["TEST-B1"])
        XCTAssertFalse(CanonicalBusinessEngine.overtimeRequestAnyDecided(partial, decisions: ["TEST-B1": .approve]))
        XCTAssertTrue(CanonicalBusinessEngine.overtimeRequestAnyDecided(partial, decisions: ["TEST-B3": .approve]))

        // An admin finishes it: the request is approved.
        let finish = try XCTUnwrap(CanonicalBusinessEngine.overtimeApprovalWrites(
            request: partial, decisions: ["TEST-B2": .approve, "TEST-B3": .approve], bookings: ["TEST-B1": b1, "TEST-B2": b2, "TEST-B3": b3],
            organization: org, deciderId: "TEST-adm", requesterIds: ids, deciderIsAdmin: true, writableBookingIds: [], unreadableBookingIds: []
        ))
        XCTAssertTrue(finish.ok)
        XCTAssertTrue(finish.complete)
        XCTAssertEqual(finish.lineOutcomes["TEST-B1"], "alreadyApplied")
        XCTAssertEqual(finish.appliedBookingIds, ["TEST-B2", "TEST-B3"])
        XCTAssertEqual(finish.requestFields["status"] as? String, "approved")
        XCTAssertEqual(finish.message, "Approved 2 of 2.")
    }

    func testNothingApprovedWritesNothingAndNamesWhy() throws {
        let b3 = booking("TEST-B3", "2026-11-03", "07:30", "17:30", person: "TEST-op1")
        let ids = ["TEST-sam", "TEST-op1"]
        let line = try XCTUnwrap(CanonicalBusinessEngine.overtimeRequestLineFields(b3, organization: org, proposal: .keep, personIds: ids)).raw
        let request = try XCTUnwrap(CanonicalBusinessEngine.parseOvertimeRequestDocument(docId: "TEST-R2", data: [
            "userId": "TEST-sam", "rangeStart": "2026-10-26", "rangeEnd": "2026-11-25", "status": "pending", "lines": [line],
        ]))
        let plan = try XCTUnwrap(CanonicalBusinessEngine.overtimeApprovalWrites(
            request: request, decisions: ["TEST-B3": .approve], bookings: ["TEST-B3": b3], organization: org,
            deciderId: "TEST-lm", requesterIds: ids, deciderIsAdmin: false, writableBookingIds: [], unreadableBookingIds: []
        ))
        XCTAssertFalse(plan.ok)
        XCTAssertEqual(plan.reason, "nothingApproved")
        XCTAssertTrue(plan.bookingWrites.isEmpty)
        XCTAssertTrue(plan.reviewWrites.isEmpty)
        XCTAssertEqual(plan.lineOutcomes, ["TEST-B3": "needsAdmin"])
        XCTAssertEqual(plan.refusalMessage, "Nothing was approved: 1 needs an admin.")

        var closed = request.raw
        closed["status"] = "approved"
        let notPending = try XCTUnwrap(CanonicalBusinessEngine.overtimeApprovalWrites(
            request: try XCTUnwrap(OvertimeRequestRecord(raw: closed)), decisions: ["TEST-B3": .approve], bookings: ["TEST-B3": b3],
            organization: org, deciderId: "TEST-adm", requesterIds: ids, deciderIsAdmin: true, writableBookingIds: [], unreadableBookingIds: []
        ))
        XCTAssertEqual(notPending.reason, "notPending")
        XCTAssertEqual(
            notPending.message,
            CanonicalBusinessEngine.overtimeText("OVERTIME_REQUEST_NOT_PENDING_MESSAGE", fallback: "")
        )
    }
}
