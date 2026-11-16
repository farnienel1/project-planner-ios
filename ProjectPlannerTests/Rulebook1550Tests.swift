import XCTest
import FirebaseFirestore
@testable import Project_Planner

/// RULEBOOK 1.55.0 (timesheet revisions, owner decisions 16 Nov) on iOS through `CanonicalBusinessEngine`: revision ids,
/// labels, invoice numbers and the difference; version chains (latest for lists, latest exported or signed off for
/// reports, earlier versions read only); when a revision is due; who may create one; the exact create shape (copied
/// fields as stored); one row per pay run from the list query; the read copy's version; the new
/// `timesheet_revision_to_sign` notice; the Payrun Snapshot and weekly report check line. Expected values checked in node
/// against the packed script (rulebook 1.55.0, web w155-timesheet-revisions 4c99d33).
@MainActor
final class Rulebook1550Tests: XCTestCase {
    private let original = "timesheet_u1_1793404800"
    private var revision1: String { original + "_rev1" }

    private func ms(_ iso: String) -> Double {
        (ISO8601DateFormatter().date(from: iso)?.timeIntervalSince1970 ?? 0) * 1000
    }

    private func timestamp(_ iso: String) -> Timestamp {
        Timestamp(date: ISO8601DateFormatter().date(from: iso) ?? Date(timeIntervalSince1970: 0))
    }

    /// A signed, counter-signed sheet with its snapshot (£632.35).
    private func signedSheet(exported: Bool) -> [String: Any] {
        var sheet: [String: Any] = [
            "userId": "u1",
            "weekStart": timestamp("2026-11-01T00:00:00Z"),
            "weekStartKey": "2026-11-01",
            "weekEndKey": "2026-11-15",
            "operativeSignedAt": timestamp("2026-11-15T10:00:00Z"),
            "operativeSignedByName": "Sam",
            "managerSignedAt": timestamp("2026-11-16T10:00:00Z"),
            "managerSignedByName": "Mia",
            "managerNote": "note",
            "weeklyReportOverride": [
                "approvedAt": timestamp("2026-11-16T10:00:00Z"),
                "approvedByUserId": "m1",
                "approvedByName": "Mia",
                "selfSigned": false,
                "lines": [["id": "l1", "date": timestamp("2026-11-03T00:00:00Z"), "amount": 632.35, "decision": "approved",
                           "paidHours": 8, "days": 1, "isOvertime": false]],
                "priceWork": [] as [Any],
                "expenses": [] as [Any],
            ] as [String: Any],
        ]
        if exported { sheet["exportedAt"] = timestamp("2026-11-20T10:00:00Z") }
        return sheet
    }

    private var openRevision: [String: Any] {
        ["userId": "u1", "weekStart": timestamp("2026-11-01T00:00:00Z"), "revisionOf": original, "revision": 1, "previousVersionId": original]
    }

    private var lineManagerReviewer: [String: Any] {
        ["writerUserId": "m1", "subjectUserId": "u1", "writerIsAdmin": false, "writerFormerIds": [] as [String],
         "writerAliasIds": [] as [String], "subjectLineManagerIds": ["m1"], "roster": [] as [Any]]
    }

    private func chain(_ documents: [(String, [String: Any])]) throws -> [TimesheetVersionInfo] {
        try XCTUnwrap(CanonicalBusinessEngine.timesheetVersionsForPeriod(documents.map { (documentId: $0.0, data: $0.1) })?.first)
    }

    // MARK: Ids, labels, numbers, difference

    func testRevisionIdsLabelsAndInvoiceNumbers() throws {
        let base = try XCTUnwrap(CanonicalBusinessEngine.parseTimesheetRevisionDocId(original))
        XCTAssertEqual(base.revision, 0)
        XCTAssertEqual(base.baseDocumentId, original)
        let rev2 = try XCTUnwrap(CanonicalBusinessEngine.parseTimesheetRevisionDocId(original + "_rev2"))
        XCTAssertEqual(rev2.revision, 2)
        XCTAssertEqual(rev2.baseDocumentId, original)
        XCTAssertNil(CanonicalBusinessEngine.parseTimesheetRevisionDocId("jobTypes"))
        XCTAssertEqual(CanonicalBusinessEngine.timesheetRevisionDocId(baseDocumentId: original, revision: 1), revision1)
        // Never a revision of a revision, never above the limit.
        XCTAssertNil(CanonicalBusinessEngine.timesheetRevisionDocId(baseDocumentId: revision1, revision: 2))
        XCTAssertNil(CanonicalBusinessEngine.timesheetRevisionDocId(baseDocumentId: original, revision: 100))
        XCTAssertEqual(CanonicalBusinessEngine.timesheetRevisionLabel(1), "REV 1")
        XCTAssertEqual(CanonicalBusinessEngine.timesheetRevisionLabel(0), "")
        // Built only from the ORIGINAL's stored id and stored userId (review of #344).
        XCTAssertEqual(CanonicalBusinessEngine.timesheetInvoiceNumber(originalDocumentId: "timesheet_6a9632ba-xyz_1793404800", storedUserId: "6a9632ba-xyz"), "TS-1793404800-6A9632")
        XCTAssertEqual(CanonicalBusinessEngine.timesheetInvoiceNumber(originalDocumentId: original, storedUserId: "u1"), "TS-1793404800-U1")
        // An id ending `_rev0` is neither an original nor a revision.
        XCTAssertNil(CanonicalBusinessEngine.parseTimesheetRevisionDocId(original + "_rev0"))
        XCTAssertEqual(CanonicalBusinessEngine.timesheetInvoiceNumberForRevision("TS-20261101-6A9632", revision: 1), "TS-20261101-6A9632-REV1")
        XCTAssertEqual(CanonicalBusinessEngine.timesheetInvoiceNumberForRevision("TS-20261101-6A9632", revision: 0), "TS-20261101-6A9632")
        // A revision id names the same person (`timesheetDocumentSubjectId`).
        XCTAssertEqual(CanonicalBusinessEngine.timesheetDocumentSubjectId(revision1), "u1")
    }

    func testDifferenceAndRevisionCopy() throws {
        let up = try XCTUnwrap(CanonicalBusinessEngine.timesheetRevisionDifference(total: 676.47, previousTotal: 632.35, currency: "GBP"))
        XCTAssertEqual(up.text, "+£44.12")
        XCTAssertEqual(up.amount, 44.12, accuracy: 0.0001)
        XCTAssertEqual(CanonicalBusinessEngine.timesheetRevisionDifference(total: 600, previousTotal: 610, currency: "GBP")?.text, "-£10.00")
        XCTAssertNil(CanonicalBusinessEngine.timesheetRevisionDifference(total: 1, previousTotal: nil, currency: "GBP"))
        // The previous version's total is read from its frozen snapshot, never stored.
        XCTAssertEqual(try XCTUnwrap(CanonicalBusinessEngine.timesheetExportedTotal(signedSheet(exported: true))), 632.35, accuracy: 0.0001)
        let copy = TimesheetRevisionCopy.make(originalDocumentId: original, storedUserId: "u1", revision: 1, total: 676.47,
                                              previousExportedTotal: 632.35, previousKnown: true, currency: "GBP")
        XCTAssertEqual(copy.invoiceNumber, "TS-1793404800-U1-REV1")
        XCTAssertEqual(copy.note, "REV 1 · +£44.12 from the previous version")
        let originalCopy = TimesheetRevisionCopy.make(originalDocumentId: original, storedUserId: "u1", revision: 0, total: 632.35,
                                                      previousExportedTotal: nil, previousKnown: false, currency: "GBP")
        XCTAssertEqual(originalCopy.invoiceNumber, "TS-1793404800-U1")
        XCTAssertEqual(originalCopy.note, "")
        // A previous version with no signed snapshot: the difference is unknown, never a figure without its labour.
        XCTAssertNil(CanonicalBusinessEngine.timesheetExportedTotal(["userId": "u1"]))
        let unknown = TimesheetRevisionCopy.make(originalDocumentId: original, storedUserId: "u1", revision: 1, total: 676.47,
                                                 previousExportedTotal: nil, previousKnown: true, currency: "GBP")
        XCTAssertEqual(unknown.differenceText, CanonicalBusinessEngine.timesheetRevisionDifferenceUnknown)
        XCTAssertEqual(unknown.note, "REV 1 · Difference not available (older export)")
    }

    // MARK: Versions

    func testChainLatestReportAndEarlierVersions() throws {
        let versions = try chain([(revision1, openRevision), (original, signedSheet(exported: true))])
        XCTAssertEqual(versions.map(\.documentId), [original, revision1])
        XCTAssertEqual(versions.map(\.exported), [true, false])
        // Lists and the period page: the latest version (the open revision).
        XCTAssertEqual(CanonicalBusinessEngine.timesheetLatestVersion(versions)?.documentId, revision1)
        // Weekly report and Payrun Snapshot (owner decision J4): the latest version; an open revision is not approved.
        let open = try XCTUnwrap(CanonicalBusinessEngine.timesheetRevisionReportState(revision: 1, exported: false, signedOff: false, change: nil))
        XCTAssertEqual(open.state, "open")
        XCTAssertEqual(open.label, "REV 1 waiting for signature")
        let due = try XCTUnwrap(CanonicalBusinessEngine.timesheetRevisionReportState(
            revision: 0, exported: true, signedOff: true, change: RulebookSignedTimesheetChange(json: ["changed": true, "exported": true])
        ))
        XCTAssertEqual(due.state, "due")
        XCTAssertEqual(due.label, "Revision due")
        XCTAssertEqual(CanonicalBusinessEngine.timesheetRevisionReportState(revision: 1, exported: true, signedOff: true, change: nil)?.state, "none")
        // Earlier versions, read only, under the latest.
        XCTAssertEqual(CanonicalBusinessEngine.timesheetEarlierVersions(versions).map(\.documentId), [original])
        // Each version keeps its stored Firestore values (a Timestamp stays a Timestamp).
        XCTAssertTrue(versions[0].data["exportedAt"] is Timestamp)
    }

    func testListQueryGivesOneRowPerPayRun() {
        let rows: [(documentId: String, data: [String: Any])] = [
            (original, signedSheet(exported: true)),
            (revision1, openRevision),
            ("jobTypes", ["jobTypes": ["A"]]),
        ]
        let latest = FirebaseBackend.collapseTimesheetVersions(rows, versions: .latest)
        XCTAssertEqual(Set(latest.compactMap { $0["__documentId"] as? String }), [revision1, "jobTypes"])
        // A revision row carries the previous version's exported total (the difference's base).
        let revisionRow = latest.first { ($0["__documentId"] as? String) == revision1 }
        XCTAssertEqual((revisionRow?["__previousExportedTotal"] as? NSNumber)?.doubleValue ?? 0, 632.35, accuracy: 0.0001)
        let all = FirebaseBackend.collapseTimesheetVersions(rows, versions: .all)
        XCTAssertEqual(all.count, 3)
    }

    func testPickTimesheetRowReadsVersionsAsOneRow() throws {
        // `pickTimesheetRowForPeriod` rows carry `documentId` (1.55.0): an original and its revision are one row — the
        // latest version (lists and, owner decision J4, reports). (This device keeps one local copy per pay run — its
        // latest version — so its own candidates never hold two versions.)
        let period: [String: Any] = ["startDayKey": "2026-11-01", "endDayKey": "2026-11-15"]
        let rows: [[String: Any]] = [
            ["startDayKey": "2026-11-01", "endDayKey": "2026-11-15", "documentId": original, "exported": true],
            ["startDayKey": "2026-11-01", "endDayKey": "2026-11-15", "documentId": revision1],
        ]
        XCTAssertEqual((CanonicalBusinessEngine.callJSON("pickTimesheetRowForPeriod", arguments: [rows, period]) as? NSNumber)?.intValue, 1)
    }

    func testReadCopyKnowsItsVersion() throws {
        var row = openRevision
        row["__documentId"] = revision1
        row["__previousExportedTotal"] = 632.35
        let draft = try XCTUnwrap(TimesheetDraftStore.decodeFirestoreMap(row))
        XCTAssertEqual(draft.versionDocumentId, revision1)
        XCTAssertEqual(draft.revision, 1)
        XCTAssertEqual(draft.previousVersionExportedTotal ?? 0, 632.35, accuracy: 0.0001)
        XCTAssertEqual(TimesheetDraftStore.revisionLabel(for: draft), "REV 1")
        // Never written back as a field.
        let written = TimesheetDraftStore.asFirestoreMap(draft)
        for key in ["versionDocumentId", "revision", "previousVersionExportedTotal", "__documentId", "revisionOf"] {
            XCTAssertNil(written[key], key)
        }
    }

    func testSaveTargetIsOnlyAVersionOfThisPayRun() {
        XCTAssertEqual(FirebaseBackend.versionDocumentId(revision1, ofCanonical: original), revision1)
        XCTAssertEqual(FirebaseBackend.versionDocumentId(original, ofCanonical: original), original)
        XCTAssertNil(FirebaseBackend.versionDocumentId("timesheet_u2_1793404800_rev1", ofCanonical: original))
        XCTAssertNil(FirebaseBackend.versionDocumentId(nil, ofCanonical: original))
    }

    // MARK: Revision due (after export only)

    func testRevisionDueOnlyOnAnExportedLatestVersionWhoseBookingsChanged() throws {
        let exported = try chain([(original, signedSheet(exported: true))])
        let changed = RulebookSignedTimesheetChange(json: ["changed": true, "exported": true, "reopened": false])
        let due = try XCTUnwrap(CanonicalBusinessEngine.timesheetRevisionDue(chain: exported, change: changed))
        XCTAssertTrue(due.due)
        XCTAssertEqual(due.documentId, revision1)
        XCTAssertEqual(due.label, "REV 1")
        XCTAssertEqual(due.message, CanonicalBusinessEngine.timesheetRevisionDueMessage)
        XCTAssertEqual(due.reviewerMessage, CanonicalBusinessEngine.timesheetRevisionDueReviewerMessage)
        let unchanged = RulebookSignedTimesheetChange(json: ["changed": false, "exported": true])
        XCTAssertFalse(try XCTUnwrap(CanonicalBusinessEngine.timesheetRevisionDue(chain: exported, change: unchanged)).due)
        // Before export nothing changes from 1.47.0: no revision.
        let signedOnly = try chain([(original, signedSheet(exported: false))])
        let reopened = RulebookSignedTimesheetChange(json: ["changed": true, "exported": false, "reopened": true])
        XCTAssertFalse(try XCTUnwrap(CanonicalBusinessEngine.timesheetRevisionDue(chain: signedOnly, change: reopened)).due)
    }

    func testRevisionDueFromTheDeviceCopy() throws {
        var row = signedSheet(exported: true)
        row["__documentId"] = original
        let draft = try XCTUnwrap(TimesheetDraftStore.decodeFirestoreMap(row))
        let week = try XCTUnwrap(CanonicalBusinessEngine.date(fromDayKey: "2026-11-01"))
        let changed = RulebookSignedTimesheetChange(json: ["changed": true, "exported": true])
        let due = TimesheetDraftStore.revisionDue(for: draft, userId: "u1", weekStart: week, change: changed)
        XCTAssertTrue(due.due)
        XCTAssertEqual(due.documentId, revision1)
        XCTAssertFalse(TimesheetDraftStore.revisionDue(for: draft, userId: "u1", weekStart: week, change: nil).due)
    }

    // MARK: Who may create one

    func testWhoMayCreateARevision() throws {
        let exported = try chain([(original, signedSheet(exported: true))])
        let manager = try XCTUnwrap(CanonicalBusinessEngine.canCreateTimesheetRevision(reviewer: lineManagerReviewer, chain: exported, writerIsSubject: false))
        XCTAssertTrue(manager.allowed)
        XCTAssertEqual(manager.documentId, revision1)
        var stranger = lineManagerReviewer
        stranger["writerUserId"] = "x9"
        XCTAssertEqual(CanonicalBusinessEngine.canCreateTimesheetRevision(reviewer: stranger, chain: exported, writerIsSubject: false)?.reason, "not-reviewer")
        var person = lineManagerReviewer
        person["writerUserId"] = "u1"
        XCTAssertTrue(try XCTUnwrap(CanonicalBusinessEngine.canCreateTimesheetRevision(reviewer: person, chain: exported, writerIsSubject: true)).allowed)
        // A second open revision is impossible; an unexported sheet has none.
        let open = try chain([(original, signedSheet(exported: true)), (revision1, openRevision)])
        XCTAssertEqual(CanonicalBusinessEngine.canCreateTimesheetRevision(reviewer: lineManagerReviewer, chain: open, writerIsSubject: false)?.reason, "revision-open")
        let unexported = try chain([(original, signedSheet(exported: false))])
        XCTAssertEqual(CanonicalBusinessEngine.canCreateTimesheetRevision(reviewer: lineManagerReviewer, chain: unexported, writerIsSubject: false)?.reason, "not-exported")
    }

    // MARK: The create shape

    func testCreateFieldsCopyStoredValuesExactlyAndNothingElse() throws {
        var previous = signedSheet(exported: true)
        previous["priceWorkEntries"] = [["id": "p1", "title": "Tiling", "amount": 5]]
        previous["expenseEntries"] = [] as [Any]
        previous["extraEntryReviews"] = ["p1": ["decision": "approved"]]
        previous["lateExtras"] = NSNull()
        let made = try XCTUnwrap(CanonicalBusinessEngine.timesheetRevisionCreateFields(previousDocumentId: original, previousData: previous, writerUserId: "u1"))
        XCTAssertEqual(made.documentId, revision1)
        XCTAssertEqual(made.revision, 1)
        XCTAssertEqual(made.fields["revisionOf"] as? String, original)
        XCTAssertEqual((made.fields["revision"] as? NSNumber)?.intValue, 1)
        XCTAssertEqual(made.fields["previousVersionId"] as? String, original)
        XCTAssertEqual(made.fields["revisionCreatedBy"] as? String, "u1")
        // The copied fields are the stored Firestore values (the rules compare them with the previous version).
        XCTAssertTrue(made.fields["weekStart"] is Timestamp)
        XCTAssertEqual(made.fields["weekStartKey"] as? String, "2026-11-01")
        XCTAssertNotNil(made.fields["priceWorkEntries"])
        XCTAssertNotNil(made.fields["extraEntryReviews"])
        // A copied key stored as null stays null (never "removed" against the previous version).
        XCTAssertTrue(made.fields["lateExtras"] is NSNull)
        // No live lines: every labour decision is dropped (pending again).
        XCTAssertNil(made.fields["payrollLineReviews"])
        // Never signatures, the snapshot, notes, exportedAt or any figure.
        for key in ["operativeSignedAt", "managerSignedAt", "weeklyReportOverride", "managerNote", "exportedAt", "operativeSignedByName"] {
            XCTAssertNil(made.fields[key], key)
        }
        let allowed = Set(CanonicalBusinessEngine.timesheetRevisionCopiedFields + ["revisionOf", "revision", "previousVersionId", "revisionCreatedBy"])
        XCTAssertTrue(Set(made.fields.keys).isSubset(of: allowed))
        // Only an exported version can have a revision.
        XCTAssertNil(CanonicalBusinessEngine.timesheetRevisionCreateFields(previousDocumentId: original, previousData: signedSheet(exported: false), writerUserId: "u1"))
    }

    func testRevisionKeepsLabourDecisionsOnlyForUnchangedBookings() throws {
        var previous = signedSheet(exported: true)
        previous["weeklyReportOverride"] = [
            "approvedAt": timestamp("2026-11-16T10:00:00Z"),
            "lines": [["id": "op-b1", "bookingFingerprint": "FP1", "amount": 100, "paidHours": 8, "decision": "edited"],
                      ["id": "op-b2", "bookingFingerprint": "FP2", "amount": 50, "paidHours": 4, "decision": "approved"]],
        ] as [String: Any]
        previous["payrollLineReviews"] = ["op-b1": ["decision": "edited", "revisedAmount": 90], "op-b2": ["decision": "declined"]]
        let live: [[String: Any]] = [["id": "op-b1", "bookingFingerprint": "FP1", "amount": 100, "paidHours": 8],
                                     ["id": "op-b2", "bookingFingerprint": "FPX", "amount": 50, "paidHours": 4]]
        let made = try XCTUnwrap(CanonicalBusinessEngine.timesheetRevisionCreateFields(previousDocumentId: original, previousData: previous, writerUserId: "u1", liveLines: live))
        let reviews = try XCTUnwrap(made.fields["payrollLineReviews"] as? [String: Any])
        XCTAssertEqual(Set(reviews.keys), ["op-b1"])
        XCTAssertEqual((reviews["op-b1"] as? [String: Any])?["decision"] as? String, "edited")
    }

    func testRevisionEntriesAreFrozenForThePerson() {
        let extras = CanonicalBusinessEngine.timesheetOwnerCanAddExtras(managerSignedAt: nil, approvedAt: nil, selfSigned: false, revision: 1)
        XCTAssertFalse(extras.allowed)
        XCTAssertEqual(extras.message, CanonicalBusinessEngine.timesheetRevisionExtrasMessage)
        XCTAssertFalse(CanonicalBusinessEngine.canEditTimesheetEntry(managerSignedAt: nil, approvedAt: nil, viewerIsOwner: true, selfSigned: false, revision: 1).allowed)
        XCTAssertTrue(CanonicalBusinessEngine.timesheetOwnerCanAddExtras(managerSignedAt: nil, approvedAt: nil, selfSigned: false, revision: 0).allowed)
    }

    func testRevisionEntryIdsAreTheOriginals() throws {
        let entry: [String: Any] = ["title": "Fuel", "amount": 4]
        let onOriginal = CanonicalBusinessEngine.callJSON("timesheetEntryId", arguments: [original, "expenseEntries", 0, entry]) as? String
        let onRevision = CanonicalBusinessEngine.callJSON("timesheetEntryId", arguments: [revision1, "expenseEntries", 0, entry]) as? String
        XCTAssertNotNil(onOriginal)
        XCTAssertEqual(onOriginal, onRevision)
    }

    // MARK: The notice

    func testRevisionNoticeDecodesRoutesAndNeverReachesTheActor() throws {
        XCTAssertEqual(AppNotification.NotificationType(stored: "timesheet_revision_to_sign"), .timesheetRevisionToSign)
        XCTAssertTrue(CanonicalBusinessEngine.knownNotificationTypes.contains("timesheet_revision_to_sign"))
        XCTAssertEqual(CanonicalBusinessEngine.timesheetRevisionNoticeType, AppNotification.NotificationType.timesheetRevisionToSign.rawValue)
        let destination = try XCTUnwrap(CanonicalBusinessEngine.notificationDestination(
            type: "timesheet_revision_to_sign", relatedId: nil, dayKey: "2026-11-01", catalogue: nil, role: "operative", deepLinkUserId: "u1"
        ))
        XCTAssertEqual(destination.kind, "timesheetMine")
        XCTAssertEqual(destination.dayKey, "2026-11-01")
        XCTAssertEqual(UserNotificationToggle.preference(for: .timesheetRevisionToSign), .timesheetSignoff)
        let roster: [[String: Any]] = [["id": "u1", "isActive": true, "passwordSet": true], ["id": "m1", "isActive": true, "passwordSet": true]]
        XCTAssertEqual(CanonicalBusinessEngine.timesheetRevisionToSignRecipients(subject: ["id": "u1", "isActive": true], actor: "m1", roster: roster), ["u1"])
        XCTAssertEqual(CanonicalBusinessEngine.timesheetRevisionToSignRecipients(subject: "u1", actor: "u1", roster: roster), [])
        XCTAssertEqual(CanonicalBusinessEngine.timesheetRevisionNoticeKey(revision1), "timesheetRevision|\(revision1)")
        XCTAssertNil(CanonicalBusinessEngine.timesheetRevisionNoticeKey(original))
    }

    // MARK: Reports

    func testPayrunSnapshotSheetKeepsItsDocumentId() throws {
        var data = openRevision
        data["weekStart"] = ["seconds": 1_793_404_800, "nanoseconds": 0]
        data["weekStartKey"] = "2026-11-01"
        data["weekEndKey"] = "2026-11-15"
        let sheet = try XCTUnwrap(CanonicalBusinessEngine.parsePayrunSnapshotSheet(docId: revision1, data: data))
        XCTAssertEqual(sheet["documentId"] as? String, revision1)
    }

    func testWeeklyReportCheckLineNamesTheRevisionUsed() throws {
        let weekend: [String: Any] = ["allHoursAtMultiplierMode": false, "allHoursMultiplier": 2, "definedWindowStart": "07:30",
                                      "definedWindowEnd": "14:00", "countsAsStandardHours": 8, "outsideWindowMultiplier": 1.5, "breakPaid": true]
        var sunday = weekend
        sunday["sameAsSaturday"] = false
        let policy: [String: Any] = ["standardDayStart": "07:00", "standardDayEnd": "16:00", "unpaidBreakMinutes": 30,
                                     "breakWindowStart": "12:00", "breakWindowEnd": "12:30", "standardPaidHours": 8.5,
                                     "paidHoursDerived": true, "weekdayOutsideStandardMultiplier": 1.5,
                                     "saturday": weekend, "sunday": sunday]
        func input(_ revision: Int) -> [String: Any] {
            [
                "people": [["id": "u-admin", "name": "Test Admin", "role": "Admin User", "ids": ["u-admin"],
                            "user": ["id": "u-admin", "payBasis": "day", "dayRate": 240, "employmentType": "self_employed"],
                            "hasLineManager": false,
                            "paySubject": ["id": "u-admin", "email": "admin@x.com", "role": "admin", "adminAccess": true, "isActive": true]]],
                "bookings": [["id": "b02", "personId": "u-admin", "dayKey": "2026-11-02", "timeSlot": "CUSTOM_HOURS",
                              "workStartTime": "07:00", "workEndTime": "16:00", "status": "Confirmed", "jobId": "proj1",
                              "jobNumber": "C646", "jobName": "1 Carnaby Street", "locationKind": "project"]],
                "organization": policy,
                "payRateHistory": [["id": "h1", "userId": "u-admin", "dayRate": 250, "payBasis": "day", "effectiveAt": "2026-01-01T00:00:00Z"]],
                "range": ["start": "2026-11-01", "end": "2026-11-15"],
                "timeZone": "Europe/London",
                "currency": "GBP",
                "showAllPay": true,
                "sheets": [["personId": "u-admin", "startDayKey": "2026-11-01", "endDayKey": "2026-11-15", "payrollLines": [] as [Any],
                            "revision": revision,
                            "sheet": ["operativeSignedAt": "2026-11-16T10:00:00Z", "operativeSignedByName": "Test Admin",
                                      "operativeSignatureImageBase64": "x",
                                      "weeklyReportOverride": ["lines": [["id": "op-b02-normal", "date": "2026-11-02", "amount": 250,
                                                                          "paidHours": 8.5, "days": 1, "isOvertime": false]],
                                                               "priceWork": [] as [Any], "expenses": [] as [Any]]]]],
            ]
        }
        func label(_ revision: Int) -> String? {
            let result = CanonicalBusinessEngine.callJSON("weeklyReportPayRows", arguments: [input(revision)]) as? [String: Any]
            let person = (result?["people"] as? [[String: Any]])?.first
            return (person?["check"] as? [String: Any])?["label"] as? String
        }
        XCTAssertEqual(label(1), "Timesheet: Signed · REV 1 · Invoice £250.00 ✓")
        XCTAssertEqual(label(0), "Timesheet: Signed · Invoice £250.00 ✓")
    }
}
