import XCTest
import FirebaseFirestore
@testable import Project_Planner

/// RULEBOOK 1.46.0 (rates audit) through `CanonicalBusinessEngine`. Expected values were checked in node against the
/// packed `canonical-business.js` this branch mirrors and match web `lib/canonical/canonical.test.ts` (1.46.0 tests):
///   - a line manager's Edit hours re-prices the whole booking (`revisedPayrollLineAmounts`): 07:00–16:00 with a 30 min
///     unpaid break edited to 07:00–19:00 at ×2 on £250 a day pays 250 + 176.47 = 426.47 (the hours ratio paid 250);
///   - a review made against a booking that changed since is stale: 426.47, never 602.94;
///   - blank times or a start equal to the finish are refused (`revisedPayrollLineTimesError`);
///   - a signed sheet is never re-priced by a stale review (`reapplyReviews` with the line as signed);
///   - a review cached before 1.46.0 still decodes, and a 1.46.0 review round-trips its seven new fields;
///   - the weekly report sums each booking's rounded pay (`bookingPaySlices` + `mergeBookingPaySlice`): 132.36.
@MainActor
final class Rulebook1460Tests: XCTestCase {
    private let org = "TEST-org-146"
    private let dayKey = "2026-11-18" // a Wednesday

    override func setUp() {
        super.setUp()
        OrganizationRulebookContext.update(from: Organization(firestoreDocumentId: org, name: "TEST-Company 146"))
    }

    override func tearDown() {
        OrganizationRulebookContext.update(from: nil)
        super.tearDown()
    }

    /// The owner's working day: 07:00–16:00, 30 min unpaid 12:00–12:30 → 8.5 paid hours.
    private var ownerPolicy: OrgPayrollTimePolicy {
        var policy = OrgPayrollTimePolicy.default
        policy.standardDayStart = "07:00"
        policy.standardDayEnd = "16:00"
        policy.unpaidBreakMinutes = 30
        policy.breakPaid = false
        policy.breakWindowStart = "12:00"
        policy.breakWindowEnd = "12:30"
        policy.standardPaidHours = 8.5
        policy.paidHoursDerived = true
        return policy
    }

    private var day: Date { OrganizationRulebookContext.date(fromDayKey: dayKey)! }

    private func fingerprint(start: String, end: String) -> String? {
        CanonicalBusinessEngine.payrollLineBookingFingerprint(
            OvertimeBookingInput(
                id: "TEST-B1",
                collection: "bookings",
                personId: "",
                dayKey: dayKey,
                timeSlot: TimeSlot.customHours.rawValue,
                workStartTime: start,
                workEndTime: end,
                isBreakRemoved: false,
                otMultiplierOverride: 2,
                status: nil,
                jobId: nil
            )
        )
    }

    private func standardLine(amount: Double = 250, fingerprint: String?, hasOvertimeLine: Bool) -> TimesheetPayrollLineItem {
        TimesheetPayrollLineItem(
            id: "op-TEST-B1-normal",
            date: day,
            jobNumber: "TEST-1",
            projectName: "TEST-Kitchen refit",
            details: "07:00–16:00",
            paidHours: 8.5,
            payrollBasis: .dayRate,
            dayRate: 250,
            hourlyRate: nil,
            amount: amount,
            isPayeDay: false,
            isOvertimeLine: false,
            bookingId: "op-TEST-B1",
            bookingPaidHours: 8.5,
            bookingOvertimeHours: 0,
            bookingStartTime: "07:00",
            bookingEndTime: "16:00",
            bookingBreakRemoved: false,
            bookingFingerprint: fingerprint,
            bookingHasOvertimeLine: hasOvertimeLine,
            bookingOtMultiplierOverride: 2,
            bookingCollection: "bookings"
        )
    }

    private func overtimeLine(fingerprint: String?) -> TimesheetPayrollLineItem {
        TimesheetPayrollLineItem(
            id: "op-TEST-B1-ot",
            date: day,
            jobNumber: "TEST-1",
            projectName: "TEST-Kitchen refit (Overtime)",
            details: "16:00–19:00",
            paidHours: 3,
            payrollBasis: .dayRate,
            dayRate: 500,
            hourlyRate: nil,
            amount: 176.47,
            isPayeDay: false,
            isOvertimeLine: true,
            bookingId: "op-TEST-B1",
            otMultiplier: 2,
            otClockHours: 3,
            bookingFingerprint: fingerprint,
            bookingHasOvertimeLine: true,
            bookingOtMultiplierOverride: 2,
            bookingCollection: "bookings"
        )
    }

    // MARK: Script surface

    func testThePackedScriptIs146AndExportsTheNewRules() throws {
        let stamp = try XCTUnwrap(CanonicalBusinessEngine.rulebookStamp())
        let parts = stamp.version.split(separator: ".").compactMap { Int($0) }
        XCTAssertFalse(parts.lexicographicallyPrecedes([1, 46, 0]), "rulebook \(stamp.version) predates 1.46.0")
        let names = Set(CanonicalBusinessEngine.exportNames())
        for name in [
            "revisedPayrollLineAmounts", "revisedPayrollLineTimesError", "payrollLineReviewSnapshotParts",
            "bookingPaySlices", "mergeBookingPaySlice", "payrollLineReviewKey", "payrollLineBookingKey",
            "PAYROLL_LINE_EDIT_TIMES_MESSAGE",
        ] {
            XCTAssertTrue(names.contains(name), "\(name) is exported")
        }
    }

    /// The fingerprint comes from the rulebook, never built in Swift, so web and iPhone compare the same string.
    func testThePayrollLineFingerprintIsTheRulebooksString() {
        // The written format is the rulebook's; Swift only compares through `overtimeFingerprintsMatch`.
        let written = fingerprint(start: "07:00", end: "16:00")
        XCTAssertFalse((written ?? "").isEmpty)
        XCTAssertEqual(written, CanonicalBusinessEngine.overtimeBookingFingerprint(
            OvertimeBookingInput(
                id: "TEST-B1", collection: "bookings", personId: "", dayKey: dayKey, timeSlot: TimeSlot.customHours.rawValue,
                workStartTime: "07:00", workEndTime: "16:00", isBreakRemoved: false, otMultiplierOverride: 2, status: nil, jobId: nil
            )
        ))
        XCTAssertTrue(CanonicalBusinessEngine.overtimeFingerprintsMatch(written, "2026-11-18|CUSTOM_HOURS|07:00|16:00|2||confirmed"))
        XCTAssertFalse(CanonicalBusinessEngine.overtimeFingerprintsMatch(written, fingerprint(start: "07:00", end: "19:00")))
    }

    /// One booking, two spellings: web stores the slot `CUSTOM`, iOS reads it as `CUSTOM_HOURS` — the rulebook gives one
    /// fingerprint, and a fingerprint stored before 1.46.0 (`CUSTOM HOURS`) still matches (`overtimeFingerprintsMatch`).
    func testAWebCustomAndAnIOSCustomHoursBookingHaveOneFingerprint() throws {
        func stamp(_ slot: String) -> String {
            CanonicalBusinessEngine.overtimeBookingFingerprint(
                OvertimeBookingInput(
                    id: "TEST-B1", collection: "bookings", personId: "", dayKey: dayKey, timeSlot: slot,
                    workStartTime: "07:00", workEndTime: "16:00", isBreakRemoved: false, otMultiplierOverride: 2,
                    status: nil, jobId: nil
                )
            )
        }
        let web = stamp("CUSTOM")
        let iOS = stamp(TimeSlot.customHours.rawValue)
        XCTAssertFalse(web.isEmpty)
        XCTAssertFalse(iOS.isEmpty)
        // Matched through the rulebook, never by the written string.
        XCTAssertTrue(CanonicalBusinessEngine.overtimeFingerprintsMatch(web, iOS))
        XCTAssertTrue(CanonicalBusinessEngine.overtimeFingerprintsMatch(iOS, "2026-11-18|CUSTOM_HOURS|07:00|16:00|2||confirmed"))
        let storedBefore146 = "2026-11-18|CUSTOM HOURS|07:00|16:00|2||confirmed"
        XCTAssertTrue(CanonicalBusinessEngine.overtimeFingerprintsMatch(storedBefore146, web))
        XCTAssertTrue(CanonicalBusinessEngine.overtimeFingerprintsMatch(web, iOS))
        XCTAssertFalse(CanonicalBusinessEngine.overtimeFingerprintsMatch(web, stamp("FULL DAY")))
        XCTAssertFalse(CanonicalBusinessEngine.overtimeFingerprintsMatch("", ""), "empty never matches")

        // A review web wrote against the `CUSTOM` booking is current for the iPhone's `CUSTOM_HOURS` line.
        var draft = TimesheetDraft()
        draft.payrollLineReviews["op-TEST-B1-normal"] = TimesheetPayrollLineReview(
            decision: .edited, revisedAmount: 300, reviewedBookingFingerprint: storedBefore146
        )
        let line = standardLine(fingerprint: iOS, hasOvertimeLine: false)
        XCTAssertEqual(TimesheetDraftAdjustments.payrollReview(in: draft, lineId: line.id, live: line)?.revisedAmount, 300)
    }

    // MARK: Edit hours

    func testOwnerCaseEditHoursPays42647() throws {
        let edit = try XCTUnwrap(CanonicalBusinessEngine.revisedPayrollLineAmounts(
            dayKey: dayKey, policy: ownerPolicy, startTime: "07:00", endTime: "19:00", isBreakRemoved: false,
            otMultiplierOverride: 2, payBasis: "day", dayRate: 250, hourlyRate: nil, employment: nil,
            bookingHasOvertimeLine: false, bookingFingerprint: fingerprint(start: "07:00", end: "16:00")
        ))
        XCTAssertEqual(edit.standardHours, 8.5, accuracy: 0.0001)
        XCTAssertEqual(edit.overtimeHours, 3, accuracy: 0.0001)
        XCTAssertEqual(edit.standardAmount, 250, accuracy: 0.001)
        XCTAssertEqual(edit.overtimeAmount, 176.47, accuracy: 0.001)
        XCTAssertEqual(edit.standardLineAmount, 426.47, accuracy: 0.001, "no overtime line: the standard line carries it")
        XCTAssertNil(edit.overtimeLineAmount)
        XCTAssertEqual(edit.total, 426.47, accuracy: 0.001)

        // With its own overtime line: each line its own part.
        let two = try XCTUnwrap(CanonicalBusinessEngine.revisedPayrollLineAmounts(
            dayKey: dayKey, policy: ownerPolicy, startTime: "07:00", endTime: "19:00", isBreakRemoved: false,
            otMultiplierOverride: 2, payBasis: "day", dayRate: 250, hourlyRate: nil, employment: nil,
            bookingHasOvertimeLine: true, bookingFingerprint: nil
        ))
        XCTAssertEqual(two.standardLineAmount, 250, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(two.overtimeLineAmount), 176.47, accuracy: 0.001)
        XCTAssertEqual(two.total, 426.47, accuracy: 0.001)

        // A PAYE day keeps its hours and pays 0.
        let paye = try XCTUnwrap(CanonicalBusinessEngine.revisedPayrollLineAmounts(
            dayKey: dayKey, policy: ownerPolicy, startTime: "07:00", endTime: "19:00", isBreakRemoved: false,
            otMultiplierOverride: 2, payBasis: "day", dayRate: 250, hourlyRate: nil, employment: ["employmentType": "paye"],
            bookingHasOvertimeLine: false, bookingFingerprint: nil
        ))
        XCTAssertTrue(paye.isPayeDay)
        XCTAssertEqual(paye.total, 0, accuracy: 0.001)
    }

    /// The screen path: Edit hours on the standard line → the reviews the save stores → invoice totals 426.47.
    func testEditHoursSaveStoresWebsFieldsAndTheTotalsAre42647() throws {
        let fp = try XCTUnwrap(fingerprint(start: "07:00", end: "16:00"))
        let line = standardLine(fingerprint: fp, hasOvertimeLine: false)
        let edit = TimesheetPayrollLineBookingLookup.payrollLineEdit(
            row: line, lines: [line], startTime: "07:00", endTime: "19:00", breakRemoved: false,
            typedOvertimeRate: nil, policy: ownerPolicy, employment: nil
        )
        XCTAssertNil(edit.error)
        XCTAssertEqual(try XCTUnwrap(edit.amounts).total, 426.47, accuracy: 0.001)

        var draft = TimesheetDraft()
        draft.payrollLineReviews = TimesheetPayrollLineBookingLookup.reviewsAfterEdit(edit, editedLineId: line.id, draft: draft)
        let review = try XCTUnwrap(draft.payrollLineReviews[line.id])
        XCTAssertEqual(review.decision, .edited)
        XCTAssertEqual(try XCTUnwrap(review.revisedAmount), 426.47, accuracy: 0.0001)
        XCTAssertEqual(review.revisedStandardHours, 8.5)
        XCTAssertEqual(review.revisedOvertimeHours, 3)
        XCTAssertEqual(review.revisedOvertimeClockHours, 3)
        XCTAssertEqual(review.revisedOvertimeMultiplier, 2)
        XCTAssertEqual(try XCTUnwrap(review.revisedStandardAmount), 250, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(review.revisedOvertimeAmount), 176.47, accuracy: 0.0001)
        XCTAssertEqual(review.reviewedBookingFingerprint, fp)

        // Exactly web's field names in the stored map.
        let stored = try XCTUnwrap(TimesheetDraftStore.asFirestoreMap(draft)["payrollLineReviews"] as? [String: [String: Any]])
        XCTAssertEqual(
            Set(try XCTUnwrap(stored[line.id]).keys),
            [
                "decision", "revisedAmount", "revisedStandardHours", "revisedOvertimeHours", "revisedOvertimeClockHours",
                "revisedOvertimeMultiplier", "revisedStandardAmount", "revisedOvertimeAmount", "reviewedBookingFingerprint",
            ]
        )

        draft.managerSignedAt = Date()
        let totals = try XCTUnwrap(TimesheetTotalsSource.totals(lines: [line], draft: draft, decided: true))
        XCTAssertEqual(totals.total, 426.47, accuracy: 0.001)
        XCTAssertEqual(totals.standardLabour, 250, accuracy: 0.001)
        XCTAssertEqual(totals.overtimeLabour, 176.47, accuracy: 0.001)
        XCTAssertEqual(
            TimesheetDraftAdjustments.effectivePayrollAmount(line: line, draft: draft, managerHasSigned: true),
            426.47,
            accuracy: 0.001
        )
    }

    /// A booking with its own overtime line: Edit hours on the standard line stores 250 and 176.47 on its two lines.
    func testABookingWithAnOvertimeLineGetsEachPartOnItsOwnLine() throws {
        let fp = try XCTUnwrap(fingerprint(start: "07:00", end: "16:00"))
        let std = standardLine(amount: 250, fingerprint: fp, hasOvertimeLine: true)
        var ot = overtimeLine(fingerprint: fp)
        ot = TimesheetPayrollLineItem(
            id: ot.id, date: ot.date, jobNumber: ot.jobNumber, projectName: ot.projectName, details: ot.details,
            paidHours: 1, payrollBasis: ot.payrollBasis, dayRate: ot.dayRate, hourlyRate: nil, amount: 58.82,
            isPayeDay: false, isOvertimeLine: true, bookingId: ot.bookingId, otMultiplier: 2, otClockHours: 1,
            bookingFingerprint: fp, bookingHasOvertimeLine: true, bookingOtMultiplierOverride: 2, bookingCollection: "bookings"
        )
        let edit = TimesheetPayrollLineBookingLookup.payrollLineEdit(
            row: std, lines: [std, ot], startTime: "07:00", endTime: "19:00", breakRemoved: false,
            typedOvertimeRate: nil, policy: ownerPolicy, employment: nil
        )
        let reviews = TimesheetPayrollLineBookingLookup.reviewsAfterEdit(edit, editedLineId: std.id, draft: TimesheetDraft())
        // The standard line's amount is unchanged (250): written because it is the edited line, as approved.
        XCTAssertEqual(reviews[std.id]?.decision, .approved)
        XCTAssertNil(reviews[std.id]?.revisedAmount)
        XCTAssertEqual(reviews[ot.id]?.decision, .edited)
        XCTAssertEqual(try XCTUnwrap(reviews[ot.id]?.revisedAmount), 176.47, accuracy: 0.0001)
    }

    func testBlankOrEqualTimesAreRefused() {
        let message = CanonicalBusinessEngine.payrollLineEditTimesMessage
        XCTAssertEqual(message, "Enter a start and a finish time that are different.")
        for (start, end) in [("", "19:00"), ("07:00", ""), ("07:00", "07:00"), ("7", "19:00"), ("25:00", "19:00")] {
            XCTAssertEqual(CanonicalBusinessEngine.revisedPayrollLineTimesError(startTime: start, endTime: end), message, "\(start)–\(end)")
            let line = standardLine(fingerprint: nil, hasOvertimeLine: false)
            let edit = TimesheetPayrollLineBookingLookup.payrollLineEdit(
                row: line, lines: [line], startTime: start, endTime: end, breakRemoved: false,
                typedOvertimeRate: nil, policy: ownerPolicy, employment: nil
            )
            XCTAssertEqual(edit.error, message)
            XCTAssertNil(edit.amounts)
            XCTAssertTrue(TimesheetPayrollLineBookingLookup.reviewsAfterEdit(edit, editedLineId: line.id, draft: TimesheetDraft()).isEmpty)
        }
        XCTAssertNil(CanonicalBusinessEngine.revisedPayrollLineTimesError(startTime: "22:00", endTime: "06:00"), "overnight is allowed")
    }

    /// An overnight Edit hours (finish before start) is priced; the sheet refuses only what the rulebook refuses.
    func testAnOvernightEditIsPriced() throws {
        let line = standardLine(fingerprint: nil, hasOvertimeLine: false)
        let edit = TimesheetPayrollLineBookingLookup.payrollLineEdit(
            row: line, lines: [line], startTime: "22:00", endTime: "06:00", breakRemoved: false,
            typedOvertimeRate: nil, policy: ownerPolicy, employment: nil
        )
        XCTAssertNil(edit.error)
        XCTAssertGreaterThan(try XCTUnwrap(edit.amounts).total, 0)
        XCTAssertFalse(TimesheetPayrollLineBookingLookup.reviewsAfterEdit(edit, editedLineId: line.id, draft: TimesheetDraft()).isEmpty)
        let support = try source("Project Planner/Views/TimesheetManagerReviewSupport.swift")
        XCTAssertTrue(support.contains(".withAmountPreview(allowsOvernight: true)"), "Edit hours lets a finish before the start")
        let sheet = try source("Project Planner/Views/BookingHoursEditSheet.swift")
        XCTAssertTrue(sheet.contains("revisedPayrollLineTimesError(startTime: start, endTime: end)"))
    }

    /// "Line manager adjustments" lists only reviews that still apply to their live line: a stale edit is not current.
    func testTheAdjustmentsCardNeverShowsAStaleEditAsCurrent() throws {
        let before = try XCTUnwrap(fingerprint(start: "07:00", end: "16:00"))
        let after = try XCTUnwrap(fingerprint(start: "07:00", end: "19:00"))
        let original = standardLine(fingerprint: before, hasOvertimeLine: false)
        let edit = TimesheetPayrollLineBookingLookup.payrollLineEdit(
            row: original, lines: [original], startTime: "07:00", endTime: "19:00", breakRemoved: false,
            typedOvertimeRate: nil, policy: ownerPolicy, employment: nil
        )
        var draft = TimesheetDraft()
        draft.payrollLineReviews = TimesheetPayrollLineBookingLookup.reviewsAfterEdit(edit, editedLineId: original.id, draft: draft)
        let current = TimesheetDraftAdjustments.currentPayrollAdjustments(draft: draft, lines: [original])
        XCTAssertEqual(current.map { $0.line.id }, [original.id])
        XCTAssertEqual(TimesheetDraftAdjustments.managerAdjustmentCount(draft: draft, lines: [original]), 1)

        let changed = [standardLine(fingerprint: after, hasOvertimeLine: true), overtimeLine(fingerprint: after)]
        XCTAssertTrue(TimesheetDraftAdjustments.currentPayrollAdjustments(draft: draft, lines: changed).isEmpty)
        XCTAssertEqual(TimesheetDraftAdjustments.managerAdjustmentCount(draft: draft, lines: changed), 0)
        // A review whose line is gone is not listed either.
        XCTAssertEqual(TimesheetDraftAdjustments.managerAdjustmentCount(draft: draft, lines: []), 0)
    }

    // MARK: Stale reviews

    /// Edit 07:00–16:00 to 07:00–19:00 (review 426.47), then the booking itself is changed to 07:00–19:00: the collector
    /// gives it an overtime line and the review is stale — 426.47, never 250 + 176.47 + 176.47 = 602.94.
    func testAChangedBookingMakesTheReviewStale602_94Becomes426_47() throws {
        let before = try XCTUnwrap(fingerprint(start: "07:00", end: "16:00"))
        let after = try XCTUnwrap(fingerprint(start: "07:00", end: "19:00"))
        let original = standardLine(fingerprint: before, hasOvertimeLine: false)
        let edit = TimesheetPayrollLineBookingLookup.payrollLineEdit(
            row: original, lines: [original], startTime: "07:00", endTime: "19:00", breakRemoved: false,
            typedOvertimeRate: nil, policy: ownerPolicy, employment: nil
        )
        var draft = TimesheetDraft()
        draft.payrollLineReviews = TimesheetPayrollLineBookingLookup.reviewsAfterEdit(edit, editedLineId: original.id, draft: draft)
        draft.managerSignedAt = Date()

        let changed = [standardLine(fingerprint: after, hasOvertimeLine: true), overtimeLine(fingerprint: after)]
        XCTAssertNil(TimesheetDraftAdjustments.payrollReview(in: draft, lineId: changed[0].id, live: changed[0]))
        let totals = try XCTUnwrap(TimesheetTotalsSource.totals(lines: changed, draft: draft, decided: true))
        XCTAssertEqual(totals.total, 426.47, accuracy: 0.001)

        // Same booking, but a working-hours change now gives it its own overtime line: stale too.
        let policyChange = [standardLine(fingerprint: before, hasOvertimeLine: true), overtimeLine(fingerprint: before)]
        XCTAssertEqual(try XCTUnwrap(TimesheetTotalsSource.totals(lines: policyChange, draft: draft, decided: true)).total, 426.47, accuracy: 0.001)
    }

    // MARK: Signed snapshot

    private func signedLine(fingerprint: String?, appliedReviewKey: String?) -> TimesheetWeeklyReportLabourLine {
        TimesheetWeeklyReportLabourLine(
            id: "op-TEST-B1-normal", date: day, jobNumber: "TEST-1", projectName: "TEST-Kitchen refit",
            locationKind: "project", details: "07:00–16:00", paidHours: 8.5, days: 1, amount: 250, isOvertime: false,
            decision: .approved, bookingId: "TEST-B1", payBasis: "day", bookingFingerprint: fingerprint,
            bookingHadOvertimeLine: false, appliedReviewKey: appliedReviewKey
        )
    }

    private var subject: AppUser {
        AppUser(
            id: "TEST-op-146", email: "op146@example.test", organizationId: org, role: .operative,
            firstName: "Op", surname: "OneFourSix", permissions: UserPermissions(operativeMode: true)
        )
    }

    private func override(_ lines: [TimesheetWeeklyReportLabourLine]) -> TimesheetWeeklyReportOverride {
        TimesheetWeeklyReportOverride(
            approvedAt: Date(), approvedByUserId: "TEST-lm", approvedByName: "TEST Line Manager", selfSigned: false,
            lines: lines, priceWork: [], expenses: []
        )
    }

    /// A signed sheet is never re-priced by a review made against another version of the booking (or by any
    /// fingerprinted review on a line signed before 1.46.0, which has no fingerprint).
    func testASignedSheetIsNeverRepricedByAStaleReview() throws {
        let signedPrint = try XCTUnwrap(fingerprint(start: "07:00", end: "16:00"))
        let laterPrint = try XCTUnwrap(fingerprint(start: "07:00", end: "17:00"))
        let line = standardLine(fingerprint: laterPrint, hasOvertimeLine: false)
        let edit = TimesheetPayrollLineBookingLookup.payrollLineEdit(
            row: line, lines: [line], startTime: "07:00", endTime: "19:00", breakRemoved: false,
            typedOvertimeRate: nil, policy: ownerPolicy, employment: nil
        )
        var draft = TimesheetDraft()
        draft.payrollLineReviews = TimesheetPayrollLineBookingLookup.reviewsAfterEdit(edit, editedLineId: line.id, draft: draft)
        draft.managerSignedAt = Date()

        for signed in [signedLine(fingerprint: signedPrint, appliedReviewKey: ""), signedLine(fingerprint: nil, appliedReviewKey: nil)] {
            let result = TimesheetWeeklyReportOverrideBuilder.reapplyReviews(to: override([signed]), draft: draft, user: subject, viewer: nil)
            XCTAssertEqual(result.lines.count, 1)
            XCTAssertEqual(result.lines[0].amount, 250, accuracy: 0.0001, "never re-priced")
            XCTAssertEqual(result.lines[0].paidHours, 8.5, accuracy: 0.0001)
        }
        // The same booking as signed: the review applies, split into its two parts.
        let current = signedLine(fingerprint: laterPrint, appliedReviewKey: "")
        let applied = TimesheetWeeklyReportOverrideBuilder.reapplyReviews(to: override([current]), draft: draft, user: subject, viewer: nil)
        XCTAssertEqual(applied.lines.map(\.id), ["op-TEST-B1-normal", "op-TEST-B1-ot"])
        XCTAssertEqual(applied.lines[0].amount, 250, accuracy: 0.0001)
        XCTAssertEqual(applied.lines[1].amount, 176.47, accuracy: 0.0001)
        XCTAssertEqual(applied.lines[1].otMultiplier, 2)
        XCTAssertEqual(applied.lines[1].reviewPartOf, "op-TEST-B1-normal", "the part records its standard line")
        XCTAssertNil(applied.lines[0].reviewPartOf)
        XCTAssertEqual(applied.lines[1].projectName, "TEST-Kitchen refit (Overtime)", "the added part keeps its own label")
        XCTAssertTrue(applied.lines[1].isOvertime)
        let key = try XCTUnwrap(applied.lines[0].appliedReviewKey)
        XCTAssertFalse(key.isEmpty)
        // Applied once: a second save with the same review changes nothing.
        let again = TimesheetWeeklyReportOverrideBuilder.reapplyReviews(to: applied, draft: draft, user: subject, viewer: nil)
        XCTAssertEqual(again.lines, applied.lines)
    }

    /// A `{booking}-ot` part a review added follows its standard line's review: declined → 0.
    func testAnAddedOvertimePartFollowsItsStandardLinesReview() throws {
        let booked = try XCTUnwrap(fingerprint(start: "07:00", end: "17:00"))
        let line = standardLine(fingerprint: booked, hasOvertimeLine: false)
        let edit = TimesheetPayrollLineBookingLookup.payrollLineEdit(
            row: line, lines: [line], startTime: "07:00", endTime: "19:00", breakRemoved: false,
            typedOvertimeRate: nil, policy: ownerPolicy, employment: nil
        )
        var draft = TimesheetDraft()
        draft.payrollLineReviews = TimesheetPayrollLineBookingLookup.reviewsAfterEdit(edit, editedLineId: line.id, draft: draft)
        draft.managerSignedAt = Date()
        let applied = TimesheetWeeklyReportOverrideBuilder.reapplyReviews(
            to: override([signedLine(fingerprint: booked, appliedReviewKey: "")]), draft: draft, user: subject, viewer: nil
        )
        XCTAssertEqual(applied.lines.count, 2)
        // The line manager then declines the standard line: its added overtime part pays 0 too.
        draft.payrollLineReviews[line.id] = TimesheetPayrollLineReview(decision: .declined, revisedAmount: nil)
        let declined = TimesheetWeeklyReportOverrideBuilder.reapplyReviews(to: applied, draft: draft, user: subject, viewer: nil)
        XCTAssertEqual(declined.lines.map(\.amount), [0, 0])
        XCTAssertEqual(declined.lines.map(\.decision), [.declined, .declined])
    }

    // MARK: Stored shapes

    func testAReviewCachedBefore146StillDecodesAndA146ReviewRoundTrips() throws {
        let old = #"{"decision":"edited","revisedAmount":300}"#.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(TimesheetPayrollLineReview.self, from: old)
        XCTAssertEqual(decoded.decision, .edited)
        XCTAssertEqual(decoded.revisedAmount, 300)
        XCTAssertNil(decoded.revisedStandardHours)
        XCTAssertNil(decoded.reviewedBookingFingerprint)
        XCTAssertEqual(Set(decoded.storedFields.keys), ["decision", "revisedAmount"], "an older review keeps its stored shape")

        let full = TimesheetPayrollLineReview(
            decision: .edited, revisedAmount: 426.47, revisedStandardHours: 8.5, revisedOvertimeHours: 3,
            revisedOvertimeClockHours: 3, revisedOvertimeMultiplier: 2, revisedStandardAmount: 250,
            revisedOvertimeAmount: 176.47, reviewedBookingFingerprint: "fp"
        )
        XCTAssertEqual(try JSONDecoder().decode(TimesheetPayrollLineReview.self, from: JSONEncoder().encode(full)), full)
        XCTAssertEqual(TimesheetPayrollLineReview(stored: full.storedFields), full)

        // Firestore returns whole numbers as integers: they still read.
        let fromFirestore = TimesheetPayrollLineReview(stored: [
            "decision": "edited", "revisedAmount": NSNumber(value: 250), "revisedStandardHours": NSNumber(value: 8),
            "revisedOvertimeHours": NSNumber(value: 0), "revisedOvertimeMultiplier": NSNull(),
        ])
        XCTAssertEqual(fromFirestore.revisedAmount, 250)
        XCTAssertEqual(fromFirestore.revisedStandardHours, 8)
        XCTAssertNil(fromFirestore.revisedOvertimeMultiplier)
        XCTAssertTrue(fromFirestore.storedFields["revisedOvertimeMultiplier"] is NSNull, "null kept as web writes it")

        // A review cached with only its decision (no amount) decodes too.
        let bare = try JSONDecoder().decode(TimesheetPayrollLineReview.self, from: #"{"decision":"declined"}"#.data(using: .utf8)!)
        XCTAssertEqual(bare.decision, .declined)
        XCTAssertNil(bare.revisedAmount)
    }

    /// 4th web review (#324): every write keeps the signed-line fields and every review field — not only signing. A
    /// sheet as web stores it is read, an unrelated field changes, and the map the save sends still holds them all
    /// (dropping them re-priced a signed 426.47 to 293.48, or paid 602.94).
    func testEverySaveKeepsTheReviewFieldsAndTheSignedLineFields() throws {
        let review: [String: Any] = [
            "decision": "edited", "revisedAmount": 426.47, "reviewedBookingFingerprint": "2026-11-18|CUSTOM_HOURS|07:00|16:00|2||confirmed",
            "revisedStandardHours": 8.5, "revisedOvertimeHours": 3, "revisedOvertimeClockHours": 3, "revisedOvertimeMultiplier": 2,
            "revisedStandardAmount": 250, "revisedOvertimeAmount": 176.47,
        ]
        let noOvertime: [String: Any] = [
            "decision": "edited", "revisedAmount": 250, "reviewedBookingFingerprint": "fp-2",
            "revisedStandardHours": 8.5, "revisedOvertimeHours": 0, "revisedOvertimeClockHours": 0, "revisedOvertimeMultiplier": NSNull(),
            "revisedStandardAmount": 250, "revisedOvertimeAmount": 0,
        ]
        let signedNormal: [String: Any] = [
            "id": "op-TEST-B1-normal", "date": Timestamp(date: day), "jobNumber": "TEST-1", "projectName": "TEST-Kitchen refit",
            "locationKind": "project", "details": "07:00–16:00", "paidHours": 8.5, "days": 1.0, "amount": 250.0,
            "isOvertime": false, "decision": "edited", "bookingId": "TEST-B1", "payBasis": "day",
            "bookingFingerprint": "2026-11-18|CUSTOM_HOURS|07:00|16:00|2||confirmed", "bookingHadOvertimeLine": false,
            "isPayeDay": true, "isLeave": false,
            "appliedReviewKey": "edited|426.47|8.5|3|3|2|250|176.47|2026-11-18|CUSTOM_HOURS|07:00|16:00|2||confirmed",
        ]
        var signedOvertime = signedNormal
        signedOvertime["id"] = "op-TEST-B1-ot"
        signedOvertime["isOvertime"] = true
        signedOvertime["paidHours"] = 3.0
        signedOvertime["amount"] = 176.47
        signedOvertime["otMultiplier"] = 2.0
        signedOvertime["bookingHadOvertimeLine"] = true
        signedOvertime["reviewPartOf"] = "op-TEST-B1-normal"
        signedOvertime["isPayeDay"] = false
        signedOvertime["isLeave"] = false
        let stored: [String: Any] = [
            "managerNote": "",
            "payrollLineReviews": ["op-TEST-B1-normal": review, "op-TEST-B2-normal": noOvertime],
            "weeklyReportOverride": [
                "approvedAt": Timestamp(date: day), "approvedByUserId": "TEST-lm", "approvedByName": "TEST LM", "selfSigned": false,
                "lines": [signedNormal, signedOvertime], "priceWork": [], "expenses": [],
            ],
        ]
        var draft = try XCTUnwrap(TimesheetDraftStore.decodeFirestoreMap(stored))
        draft.managerNote = "TEST-unrelated change"
        let written = TimesheetDraftStore.asFirestoreMap(draft)

        let reviews = try XCTUnwrap(written["payrollLineReviews"] as? [String: [String: Any]])
        for (id, original) in [("op-TEST-B1-normal", review), ("op-TEST-B2-normal", noOvertime)] {
            let row = try XCTUnwrap(reviews[id], id)
            XCTAssertEqual(Set(row.keys), Set(original.keys), id)
            for (key, value) in original {
                if value is NSNull {
                    XCTAssertTrue(row[key] is NSNull, "\(id).\(key) stays null")
                } else if let text = value as? String {
                    XCTAssertEqual(row[key] as? String, text, "\(id).\(key)")
                } else {
                    XCTAssertEqual((row[key] as? NSNumber)?.doubleValue, (value as? NSNumber)?.doubleValue, "\(id).\(key)")
                }
            }
        }

        let override = try XCTUnwrap(written["weeklyReportOverride"] as? [String: Any])
        let lines = try XCTUnwrap(override["lines"] as? [[String: Any]])
        XCTAssertEqual(lines.count, 2)
        for (line, original) in zip(lines, [signedNormal, signedOvertime]) {
            XCTAssertEqual(line["bookingFingerprint"] as? String, original["bookingFingerprint"] as? String)
            XCTAssertEqual(line["bookingHadOvertimeLine"] as? Bool, original["bookingHadOvertimeLine"] as? Bool)
            XCTAssertEqual(line["appliedReviewKey"] as? String, original["appliedReviewKey"] as? String)
            XCTAssertEqual(line["reviewPartOf"] as? String, original["reviewPartOf"] as? String)
            XCTAssertEqual(line["isPayeDay"] as? Bool, original["isPayeDay"] as? Bool)
            XCTAssertEqual(line["isLeave"] as? Bool, original["isLeave"] as? Bool)
            XCTAssertEqual((line["amount"] as? NSNumber)?.doubleValue, (original["amount"] as? NSNumber)?.doubleValue)
        }
        XCTAssertEqual((lines[1]["otMultiplier"] as? NSNumber)?.doubleValue, 2)

        // And the Swift cache (Codable) keeps them too.
        let cached = try JSONDecoder().decode(TimesheetDraft.self, from: JSONEncoder().encode(draft))
        XCTAssertEqual(cached.payrollLineReviews, draft.payrollLineReviews)
        XCTAssertEqual(cached.weeklyReportOverride?.lines, draft.weeklyReportOverride?.lines)
    }

    /// A signed sheet's invoice is its own: a signed line flagged PAYE never reaches the invoice, whatever the live lines.
    func testASignedPayeLineNeverReachesTheInvoice() throws {
        var paye = signedLine(fingerprint: nil, appliedReviewKey: "")
        paye.isPayeDay = true
        paye.isLeave = false
        var worked = signedLine(fingerprint: nil, appliedReviewKey: "")
        worked.id = "op-TEST-B2-normal"
        worked.isPayeDay = false
        worked.isLeave = false
        var draft = TimesheetDraft()
        draft.managerSignedAt = Date()
        draft.weeklyReportOverride = override([paye, worked])
        let totals = try XCTUnwrap(TimesheetTotalsSource.totals(lines: [], draft: draft, decided: true))
        XCTAssertEqual(totals.total, 250, accuracy: 0.001, "only the self-employed signed line counts")
    }

    /// `payrollLineBookingKey` groups a booking's standard and overtime line (same collection and `bookingId`) and keeps a
    /// labour and a manager site booking with one id apart.
    func testTheBookingKeyGroupsTheStandardAndOvertimeLines() {
        let std = standardLine(fingerprint: nil, hasOvertimeLine: true)
        let ot = overtimeLine(fingerprint: nil)
        let key = { (line: TimesheetPayrollLineItem) in
            CanonicalBusinessEngine.payrollLineBookingKey(lineId: line.id, bookingId: line.bookingId, bookingCollection: line.bookingCollection)
        }
        XCTAssertNotNil(key(std))
        XCTAssertEqual(key(std), key(ot))
        // A line without its collection is a labour booking unless its id starts `mgr-`.
        XCTAssertEqual(key(std), CanonicalBusinessEngine.payrollLineBookingKey(lineId: ot.id, bookingId: ot.bookingId, bookingCollection: nil))
        XCTAssertEqual(
            CanonicalBusinessEngine.payrollLineBookingKey(lineId: "mgr-TEST-M1-normal", bookingId: "mgr-TEST-M1", bookingCollection: nil),
            CanonicalBusinessEngine.payrollLineBookingKey(lineId: "mgr-TEST-M1-ot", bookingId: "mgr-TEST-M1", bookingCollection: "managerSiteBookings")
        )
        XCTAssertNotEqual(
            key(std),
            CanonicalBusinessEngine.payrollLineBookingKey(lineId: std.id, bookingId: std.bookingId, bookingCollection: "managerSiteBookings")
        )
    }

    func testRevisedAmountsAreStoredInPennies() {
        XCTAssertEqual(CanonicalBusinessEngine.roundPennies(176.47058823529), 176.47, accuracy: 0.0000001)
        XCTAssertEqual(CanonicalBusinessEngine.roundPennies(10.006), 10.01, accuracy: 0.0000001)
    }

    // MARK: Weekly report

    /// Three days of 1h overtime at ×1.5 on a £250 / 8.5h day: 44.12 each → 132.36 (one price of 3h was 132.35).
    func testTheWeeklyReportSumsEachBookingsPennies() throws {
        let probe = Booking(
            operativeId: UUID(), projectId: UUID(), date: day, timeSlot: .customHours, bookedBy: "",
            workStartTime: "07:00", workEndTime: "17:00", isBreakRemoved: false, otMultiplierOverride: 1.5
        )
        let slices = try XCTUnwrap(CanonicalBusinessEngine.bookingPaySlices(
            hoursInput: PayrollHoursEngine.canonicalInput(booking: probe, day: day, policy: ownerPolicy),
            standardDayHours: CanonicalBusinessEngine.weekdayPaidHours(ownerPolicy),
            payBasis: "day", dayRate: 250, hourlyRate: nil, isPaye: false
        ))
        XCTAssertEqual(slices.count, 2)
        let overtime = try XCTUnwrap(slices.first(where: \.isOvertime))
        XCTAssertEqual(overtime.paidHours, 1, accuracy: 0.0001)
        XCTAssertEqual(overtime.pay, 44.12, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(overtime.rate), 375, accuracy: 0.0001)
        var row = overtime
        row = try XCTUnwrap(CanonicalBusinessEngine.mergeBookingPaySlice(row, overtime))
        row = try XCTUnwrap(CanonicalBusinessEngine.mergeBookingPaySlice(row, overtime))
        XCTAssertEqual(row.paidHours, 3, accuracy: 0.0001)
        XCTAssertEqual(row.pay, 132.36, accuracy: 0.0001)

        let paye = try XCTUnwrap(CanonicalBusinessEngine.bookingPaySlices(
            hoursInput: PayrollHoursEngine.canonicalInput(booking: probe, day: day, policy: ownerPolicy),
            standardDayHours: 8.5, payBasis: "day", dayRate: 250, hourlyRate: nil, isPaye: true
        ))
        XCTAssertEqual(paye.map(\.pay), [0, 0])
        XCTAssertEqual(paye.map(\.rate), [nil, nil])
    }

    // MARK: Second calculators stay deleted

    func testTheOldRatioAndTheDayRateOverEightHelperAreGone() throws {
        let support = try source("Project Planner/Views/TimesheetManagerReviewSupport.swift")
        XCTAssertFalse(support.contains("relevantHours / row.paidHours"), "Edit hours never scales by the hours ratio")
        XCTAssertTrue(support.contains("revisedPayrollLineAmounts"))
        XCTAssertFalse(try source("Project Planner/Models/AppModels.swift").contains("payrollHourlyRate"))
        let weekly = try source("Project Planner/Views/WeeklyReportView.swift")
        XCTAssertFalse(weekly.contains("paid - (otHours * otMultiplier)"), "the weekly report prices each booking")
        XCTAssertTrue(weekly.contains("bookingPaySlices"))
    }

    private func source(_ relative: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(relative), encoding: .utf8)
    }
}
