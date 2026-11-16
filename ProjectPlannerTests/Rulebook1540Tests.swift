import XCTest
@testable import Project_Planner

/// RULEBOOK 1.54.0 (timesheet owner answers, 16 Nov) on iOS through `CanonicalBusinessEngine`: switched-off schedule
/// places are paid, late extras (price work and expenses after the line manager signed), the new
/// `timesheet_bookings_changed` notice and the Annual leave report's leave year. Expected values checked in node against
/// the packed script (rulebook 1.54.0, sha256 f0b0f339…c46cb, web 05a8078).
@MainActor
final class Rulebook1540Tests: XCTestCase {
    private func ms(_ iso: String) -> Double {
        (ISO8601DateFormatter().date(from: iso)?.timeIntervalSince1970 ?? 0) * 1000
    }

    private func seconds(_ iso: String) -> [String: Any] {
        ["seconds": Int(ms(iso) / 1000), "nanoseconds": 0]
    }

    private var lateTaxi: [String: Any] {
        ["kind": "expense", "id": "LATE-1", "title": "Taxi", "details": "", "jobNumber": "J1",
         "date": seconds("2026-11-05T00:00:00Z"), "amount": 25]
    }

    /// A sheet the line manager signed: one signed expense (`e1`, £40) and one late extra (£25).
    private func signedSheet(late: [[String: Any]]? = nil, reviews: [String: Any]? = nil) -> [String: Any] {
        var sheet: [String: Any] = [
            "userId": "u1",
            "operativeSignedAt": ms("2026-11-09T10:00:00Z"),
            "managerSignedAt": ms("2026-11-10T10:00:00Z"),
            "expenseEntries": [["id": "e1", "title": "Fuel", "details": "", "jobNumber": "J1", "date": seconds("2026-11-04T00:00:00Z"), "amount": 40]],
            "priceWorkEntries": [] as [Any],
            "lateExtras": late ?? [lateTaxi],
        ]
        if let reviews { sheet["extraEntryReviews"] = reviews }
        return sheet
    }

    private func invoiceRows(_ sheet: [String: Any]) throws -> [[String: Any]] {
        let input: [String: Any] = ["sheet": sheet, "payrollLines": [] as [Any], "extrasMode": "decided", "timeZone": "Europe/London"]
        return try XCTUnwrap(CanonicalBusinessEngine.callJSON("timesheetInvoiceRows", arguments: [input]) as? [[String: Any]])
    }

    private func approvedReview(_ row: [String: Any]) throws -> [String: Any] {
        let fingerprint = try XCTUnwrap(CanonicalBusinessEngine.callJSON("timesheetEntryFingerprint", arguments: [row, "expense"]) as? String)
        let id = try XCTUnwrap(row["id"] as? String)
        return [id: ["decision": "approved", "revisedAmount": NSNull(), "reviewedAmount": row["amount"] ?? 0,
                     "reviewedFingerprint": fingerprint, "lateExtra": true] as [String: Any]]
    }

    // MARK: 1. Switched-off schedule places are paid (§4.8, §8)

    func testOfficeBookingWithOfficeSwitchedOffIsPaid() {
        let day = LogicFixtures.day(2026, 10, 8, hour: 8)
        let person = AppUser(
            id: "m1", email: "m1@example.com", organizationId: "org", role: .manager,
            firstName: "Test", surname: "Manager", isActive: true, passwordSet: true,
            permissions: UserPermissions(manager: true), hourlyRate: 25, employmentType: .selfEmployed
        )
        let office = ManagerSiteBooking(userId: person.id, date: day, timeSlot: .fullDay, locationType: .office)
        let summary = TimesheetPayrollCollector.collect(
            for: person,
            in: day...day,
            bookings: [],
            managerBookings: [office],
            operatives: [],
            projects: [],
            smallWorks: [],
            history: .empty,
            policy: LogicFixtures.policy,
            scheduleOptions: MyScheduleOptions(showOffice: false),
            relatedUsers: [person]
        )
        // Before 1.54.0 the switched-off Office booking was left off the sheet (0 shifts, £0).
        XCTAssertEqual(summary.shiftCount, 1)
        XCTAssertGreaterThan(summary.baseAmount, 0)
        // It is a schedule-option place, so it never repairs an already-signed snapshot.
        XCTAssertTrue(summary.lineItems.allSatisfy(\.scheduleOptionPlace))
    }

    func testScheduleOptionPlaceNeverRepairsASignedSnapshot() {
        let approved = Date(timeIntervalSince1970: ms("2026-11-10T00:00:00Z") / 1000)
        let before = Date(timeIntervalSince1970: ms("2026-11-01T00:00:00Z") / 1000)
        func needs(_ optionPlace: Bool) -> Bool {
            CanonicalBusinessEngine.timesheetSnapshotNeedsRebuild(
                storedOverrideLineCount: 0,
                overrideApprovedAt: approved,
                exportedAt: nil,
                managerSignedAt: nil,
                liveLabourLines: [(isPayeDay: false, bookingCreatedAt: before, bookingUpdatedAt: before, scheduleOptionPlace: optionPlace)]
            )
        }
        XCTAssertTrue(needs(false))
        XCTAssertFalse(needs(true))
    }

    // MARK: 2. Late extras (§8)

    func testLateExtraPaysNothingUntilALateReviewWithItsFingerprintApprovesIt() throws {
        // Pending: only the signed expense is on the invoice.
        XCTAssertEqual(try invoiceRows(signedSheet()).compactMap { $0["id"] as? String }, ["e1"])
        // An inline decision on a late extra is never read.
        var inline = lateTaxi
        inline["managerDecision"] = "approved"
        XCTAssertEqual(try invoiceRows(signedSheet(late: [inline])).compactMap { $0["id"] as? String }, ["e1"])
        // A `lateExtra` review with the entry's fingerprint: paid exactly the approved amount.
        let approved = try invoiceRows(signedSheet(reviews: try approvedReview(lateTaxi)))
        XCTAssertEqual(approved.compactMap { $0["id"] as? String }, ["e1", "LATE-1"])
        XCTAssertEqual((approved.last?["amount"] as? NSNumber)?.doubleValue ?? 0, 25, accuracy: 0.001)
        // A later change to the late extra makes the review stale (pending again).
        var edited = lateTaxi
        edited["amount"] = 30
        XCTAssertEqual(try invoiceRows(signedSheet(late: [edited], reviews: try approvedReview(lateTaxi))).compactMap { $0["id"] as? String }, ["e1"])
    }

    func testSignedEntriesStayClosedAndLateExtrasOpenUntilExport() throws {
        let signed = Date(timeIntervalSince1970: ms("2026-11-10T10:00:00Z") / 1000)
        // The signed entries: refused once the line manager has signed (unchanged since 1.43.0).
        XCTAssertFalse(CanonicalBusinessEngine.timesheetOwnerCanAddExtras(managerSignedAt: signed, approvedAt: nil, selfSigned: false).allowed)
        // The owner's save never carries them then; `lateExtras` passes.
        let keep = try XCTUnwrap(CanonicalBusinessEngine.timesheetOwnerWritableKeys(
            ["expenseEntries", "priceWorkEntries", "lateExtras", "managerNote"], subjectHasLineManager: true, managerSigned: true
        ))
        XCTAssertFalse(keep.contains("expenseEntries"))
        XCTAssertFalse(keep.contains("priceWorkEntries"))
        XCTAssertTrue(keep.contains("lateExtras"))
        // Late extras: only once signed, never self-signed, never once exported.
        XCTAssertTrue(CanonicalBusinessEngine.timesheetOwnerCanAddLateExtras(
            managerSignedAt: signed, approvedAt: nil, exportedAt: nil, exportedAtStored: false, selfSigned: false
        ).allowed)
        XCTAssertFalse(CanonicalBusinessEngine.timesheetOwnerCanAddLateExtras(
            managerSignedAt: nil, approvedAt: nil, exportedAt: nil, exportedAtStored: false, selfSigned: false
        ).allowed)
        XCTAssertFalse(CanonicalBusinessEngine.timesheetOwnerCanAddLateExtras(
            managerSignedAt: signed, approvedAt: nil, exportedAt: nil, exportedAtStored: false, selfSigned: true
        ).allowed)
        let exported = CanonicalBusinessEngine.timesheetOwnerCanAddLateExtras(
            managerSignedAt: signed, approvedAt: nil, exportedAt: nil, exportedAtStored: true, selfSigned: false
        )
        XCTAssertFalse(exported.allowed)
        XCTAssertEqual(exported.message, CanonicalBusinessEngine.timesheetExportedExtrasMessage)
    }

    func testLateExtraCopyingASignedEntryIdIsIgnoredAndNeverReviewed() throws {
        var copy = lateTaxi
        copy["id"] = "E1" // the signed expense is `e1`
        let sheet = signedSheet(late: [copy])
        // Never paid.
        XCTAssertEqual(try invoiceRows(sheet).compactMap { $0["id"] as? String }, ["e1"])
        // Read as ignored, labelled, and not reviewable.
        let read = try XCTUnwrap(CanonicalBusinessEngine.parseTimesheetLateExtras(sheetDocumentId: "timesheet_u1_1", sheet: sheet, ownerUserIds: ["u1"]))
        let decision = try XCTUnwrap(read.first?.map("lateDecision"))
        XCTAssertEqual(decision["state"] as? String, "ignored")
        XCTAssertEqual(decision["reason"] as? String, "id-taken")
        XCTAssertEqual(
            CanonicalBusinessEngine.timesheetLateExtraLabel(state: "ignored", reason: "id-taken"),
            "Can't be reviewed — same reference as a signed item"
        )
        XCTAssertFalse(CanonicalBusinessEngine.timesheetLateExtraReviewable(state: "ignored", exported: false))
        // The reviewer's write never puts a late review under the signed entry's key.
        let fingerprint = try XCTUnwrap(CanonicalBusinessEngine.callJSON("timesheetEntryFingerprint", arguments: [copy, "expense"]) as? String)
        var row = copy
        row["managerDecision"] = "approved"
        row["lateExtra"] = true
        row["reviewFingerprint"] = fingerprint
        let written = try XCTUnwrap(CanonicalBusinessEngine.timesheetEntryReviewWriteFields(
            storedSheet: sheet, entryRows: [row], reviewedByUserId: "m", reviewedAtMs: 1, exported: false, sheetDocId: "timesheet_u1_1"
        ))
        XCTAssertTrue(written.isEmpty)
    }

    /// Final check of #337 (`timesheetLateExtraRowProblem`): a late extra with no title or a reserved `__…__` id is ignored —
    /// never waiting, never reviewed — and reads "Can't be reviewed — delete it and add it again".
    func testUntitledOrReservedIdLateExtrasAreIgnored() throws {
        var untitled = lateTaxi
        untitled["id"] = "L1"
        untitled["title"] = ""
        var reserved = lateTaxi
        reserved["id"] = "__x__"
        let sheet = signedSheet(late: [untitled, reserved])
        let summary = try XCTUnwrap(CanonicalBusinessEngine.timesheetLateExtrasSummary(sheet: sheet, entryFingerprints: [:], exportedAtStored: false))
        XCTAssertFalse(summary.waitingForLineManager)
        XCTAssertEqual(
            CanonicalBusinessEngine.timesheetLateExtraLabel(state: "ignored", reason: "no-title"),
            "Can't be reviewed — delete it and add it again"
        )
        XCTAssertEqual(
            CanonicalBusinessEngine.timesheetLateExtraLabel(state: "ignored", reason: "id-unusable"),
            "Can't be reviewed — delete it and add it again"
        )
        XCTAssertEqual(try invoiceRows(sheet).compactMap { $0["id"] as? String }, ["e1"])
    }

    func testReviewerWritesALateReviewOnlyBeforeExport() throws {
        let fingerprint = try XCTUnwrap(CanonicalBusinessEngine.callJSON("timesheetEntryFingerprint", arguments: [lateTaxi, "expense"]) as? String)
        var row = lateTaxi
        row["managerDecision"] = "approved"
        row["lateExtra"] = true
        row["reviewFingerprint"] = fingerprint
        let written = try XCTUnwrap(CanonicalBusinessEngine.timesheetEntryReviewWriteFields(
            storedSheet: signedSheet(), entryRows: [row], reviewedByUserId: "m", reviewedAtMs: 1, exported: false, sheetDocId: nil
        ))
        let review = try XCTUnwrap(written["extraEntryReviews.LATE-1"] as? [String: Any])
        XCTAssertEqual(review["lateExtra"] as? Bool, true)
        XCTAssertEqual(review["reviewedFingerprint"] as? String, fingerprint)
        let frozen = try XCTUnwrap(CanonicalBusinessEngine.timesheetEntryReviewWriteFields(
            storedSheet: signedSheet(), entryRows: [row], reviewedByUserId: "m", reviewedAtMs: 1, exported: true, sheetDocId: nil
        ))
        XCTAssertTrue(frozen.isEmpty, "an exported sheet's late extras are frozen")
    }

    func testWaitingLateExtrasPutTheSheetWithTheLineManagerAndStopExport() throws {
        let summary = try XCTUnwrap(CanonicalBusinessEngine.timesheetLateExtrasSummary(sheet: signedSheet(), entryFingerprints: [:], exportedAtStored: false))
        XCTAssertEqual(summary.pending, 1)
        XCTAssertTrue(summary.waitingForLineManager)
        let change = try XCTUnwrap(CanonicalBusinessEngine.timesheetChangesWithLateExtras(bookingChange: nil, late: summary))
        XCTAssertTrue(change.waitingForLineManager)
        XCTAssertTrue(change.lateExtrasOnly)
        XCTAssertFalse(change.bookingsChanged)
        XCTAssertNil(change.message, "the person has nothing to sign")
        XCTAssertEqual(change.reviewerMessage, CanonicalBusinessEngine.timesheetLateExtrasReviewerMessage)
        XCTAssertFalse(CanonicalBusinessEngine.signedTimesheetActions(change).mayExport)
        XCTAssertFalse(CanonicalBusinessEngine.signedTimesheetActions(change).mayGenerateInvoice)
        // Approved: nothing waits.
        let approved = try XCTUnwrap(CanonicalBusinessEngine.timesheetLateExtrasSummary(
            sheet: signedSheet(reviews: try approvedReview(lateTaxi)), entryFingerprints: [:], exportedAtStored: false
        ))
        XCTAssertFalse(approved.waitingForLineManager)
        XCTAssertNil(CanonicalBusinessEngine.timesheetChangesWithLateExtras(bookingChange: nil, late: approved))
    }

    func testDraftReadsLateExtrasAndWritesThemWithoutADecision() throws {
        var stored = signedSheet(reviews: try approvedReview(lateTaxi))
        stored["__documentId"] = "timesheet_u1_1"
        let draft = try XCTUnwrap(TimesheetDraftStore.decodeFirestoreMap(stored))
        let late = try XCTUnwrap(draft.lateExtras?.first)
        XCTAssertEqual(late.id, "LATE-1")
        XCTAssertEqual(late.kind, "expense")
        XCTAssertEqual(late.lateState, "approved")
        XCTAssertNotNil(late.reviewFingerprint)
        XCTAssertNotNil(draft.extraEntryReviewsJSON)
        // Written back as its own fields and kind, never a decision.
        let rows = try XCTUnwrap(TimesheetDraftStore.asFirestoreMap(draft)["lateExtras"] as? [[String: Any]])
        XCTAssertEqual(rows.first?["kind"] as? String, "expense")
        XCTAssertNil(rows.first?["managerDecision"])
        XCTAssertNil(rows.first?["managerRevisedAmount"])
        // A sheet without `lateExtras` keeps its stored shape (no key written).
        var plain = signedSheet()
        plain.removeValue(forKey: "lateExtras")
        let plainDraft = try XCTUnwrap(TimesheetDraftStore.decodeFirestoreMap(plain))
        XCTAssertNil(plainDraft.lateExtras)
        XCTAssertNil(TimesheetDraftStore.asFirestoreMap(plainDraft)["lateExtras"])
    }

    func testApprovedLateExtraJoinsTheSnapshotAndLeavesItWhenNoLongerApproved() throws {
        var stored = signedSheet(reviews: try approvedReview(lateTaxi))
        stored["__documentId"] = "timesheet_u1_1"
        var draft = try XCTUnwrap(TimesheetDraftStore.decodeFirestoreMap(stored))
        // The reviewer's save adds the approved late extra to the snapshot's money rows, marked `lateExtra`.
        let lines = try XCTUnwrap(TimesheetLateExtrasSupport.snapshotMoneyLines(draft))
        XCTAssertEqual(lines.expenses.map(\.id), ["LATE-1"])
        XCTAssertEqual(lines.expenses.first?.lateExtra, true)
        XCTAssertEqual(lines.expenses.first?.amount ?? 0, 25, accuracy: 0.001)
        // A snapshot holding it counts the row only while the late extra is still approved at that amount.
        draft.weeklyReportOverride = TimesheetWeeklyReportOverride(
            approvedAt: Date(), approvedByUserId: "m", approvedByName: "M", selfSigned: false, lines: [], priceWork: [],
            expenses: [
                TimesheetWeeklyReportMoneyLine(id: "e1", title: "Fuel", details: "", jobNumber: "J1", date: Date(), amount: 40, decision: .approved),
                lines.expenses[0],
            ]
        )
        XCTAssertEqual(TimesheetLateExtrasSupport.draftWithCurrentLateRows(draft).weeklyReportOverride?.expenses.count, 2)
        var edited = draft
        edited.lateExtras?[0].amount = 30
        edited.lateExtras?[0].reviewFingerprint = nil
        XCTAssertEqual(TimesheetLateExtrasSupport.draftWithCurrentLateRows(edited).weeklyReportOverride?.expenses.map(\.id), ["e1"])
    }

    // MARK: 3. The new notice (§13)

    func testTimesheetBookingsChangedDecodesAndOpensMyTimesheets() throws {
        XCTAssertEqual(AppNotification.NotificationType(stored: "timesheet_bookings_changed"), .timesheetBookingsChanged)
        let destination = try XCTUnwrap(CanonicalBusinessEngine.notificationDestination(
            type: "timesheet_bookings_changed", relatedId: nil, dayKey: "2026-11-01", catalogue: nil, role: "operative", deepLinkUserId: "u1"
        ))
        XCTAssertEqual(destination.kind, "timesheetMine")
        XCTAssertEqual(destination.dayKey, "2026-11-01")
        XCTAssertEqual(UserNotificationToggle.preference(for: .timesheetBookingsChanged), .timesheetSignoff)
    }

    // MARK: 4. Annual leave report = the balance's leave year (§9)

    func testLeaveReportCountsTheBalancesLeaveYear() throws {
        let months = try XCTUnwrap(CanonicalBusinessEngine.annualLeaveReportYearMonths(
            annualLeaveEnabled: true, startMonth: 4, endMonth: 3, orgStartMonth: 1, orgEndMonth: 12,
            onDayKey: "2026-11-16", employment: nil, timeZone: "Europe/London"
        ))
        XCTAssertEqual(months.startMonth, 4)
        XCTAssertEqual(months.endMonth, 3)
        // No allowance: the organisation's year.
        let org = try XCTUnwrap(CanonicalBusinessEngine.annualLeaveReportYearMonths(
            annualLeaveEnabled: false, startMonth: 4, endMonth: 3, orgStartMonth: 1, orgEndMonth: 12,
            onDayKey: "2026-11-16", employment: nil, timeZone: "Europe/London"
        ))
        XCTAssertEqual(org.startMonth, 1)
        // An April–March person in a January–December company: 2 Feb, 4 May and 2 Nov 2026 → 2 days, the balance's taken.
        let records = [("a", "2026-02-02"), ("b", "2026-05-04"), ("c", "2026-11-02")].map { id, day in
            RulebookLeaveReportRecord(id: id, userId: "u1", operativeId: nil, startDayKey: day, endDayKey: day, timeSlot: "FULL DAY", status: "approved")
        }
        let report = try XCTUnwrap(CanonicalBusinessEngine.leaveReportRows(
            records: records, personIds: ["u1"], onDayKey: "2026-11-16", startMonth: months.startMonth,
            timeZone: "Europe/London", nonWorkingDayKeys: []
        ))
        XCTAssertEqual(report.totalDays, 2, accuracy: 0.001)
        let balanceInput: [String: Any] = [
            "annualLeaveEnabled": true, "startMonth": 4, "endMonth": 3, "orgStartMonth": 1, "orgEndMonth": 12,
            "onDayKey": "2026-11-16", "timeZone": "Europe/London", "nonWorkingDayKeys": [] as [Any], "daysPerYear": 25,
            "bookings": records.map { ["startDayKey": $0.startDayKey, "endDayKey": $0.endDayKey, "timeSlot": "FULL DAY", "status": "approved"] },
        ]
        let balance = try XCTUnwrap(CanonicalBusinessEngine.callJSON("annualLeaveBalance", arguments: [balanceInput]) as? [String: Any])
        XCTAssertEqual((balance["taken"] as? NSNumber)?.doubleValue ?? -1, report.totalDays, accuracy: 0.001)
    }

    // MARK: Mirror

    func testRulebookIs1540() {
        XCTAssertEqual(CanonicalBusinessEngine.rulebookStamp()?.version, "1.54.0")
    }
}
