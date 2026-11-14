import XCTest
@testable import Project_Planner

/// RULEBOOK 1.43.0 through `CanonicalBusinessEngine` (owner reports, 14 Nov). Expected values were checked in node
/// against the packed `canonical-business.js` (sha256 23265359…a3b707c8) and match web `lib/canonical/canonical.test.ts`:
///   - a timesheet's standard line shows the standard-window times and its overtime line the overtime times
///     (`payrollLineClockRanges`), and the multiplied text is never printed twice (`timesheetLineClockText`);
///   - booking previews price the booking's own overtime rate (`bookingHoursExplanation`, `weekendBookingBreakdown`);
///   - sign-off waits for the period's bookings (`timesheetSnapshotReady`), an empty frozen snapshot is rebuilt
///     (`timesheetSnapshotNeedsRebuild`), and no extras are added once the line manager has signed
///     (`timesheetOwnerCanAddExtras`);
///   - "Manager who agreed this" suggestions are the price work approvers (`agreedManagerSuggestions`);
///   - a subcontractor's scheduling tile shows only its working window (`subcontractorScheduleCell`).
@MainActor
final class Rulebook1430Tests: XCTestCase {
    private let zone = "Europe/London"
    /// Wednesday 11 Nov 2026; Saturday 14 Nov 2026.
    private let wednesday = "2026-11-11"
    private let saturday = "2026-11-14"

    /// The owner's example: working day 07:00–16:00, 30 min unpaid break 12:00–12:30, organisation overtime 1.5×.
    private var ownerPolicy: OrgPayrollTimePolicy {
        var policy = OrgPayrollTimePolicy.default
        policy.standardDayStart = "07:00"
        policy.standardDayEnd = "16:00"
        policy.unpaidBreakMinutes = 30
        policy.breakPaid = false
        policy.breakWindowStart = "12:00"
        policy.breakWindowEnd = "12:30"
        policy.weekdayOutsideStandardMultiplier = 1.5
        return policy
    }

    func testThePackedScriptIs143AndExportsTheNewRules() throws {
        let stamp = try XCTUnwrap(CanonicalBusinessEngine.rulebookStamp())
        let parts = stamp.version.split(separator: ".").compactMap { Int($0) }
        XCTAssertFalse(parts.lexicographicallyPrecedes([1, 43, 0]), "rulebook \(stamp.version) predates 1.43.0")
        let names = Set(CanonicalBusinessEngine.exportNames())
        for name in [
            "payrollLineClockRanges", "timesheetLineClockText", "timesheetSnapshotReady", "timesheetSnapshotNeedsRebuild",
            "timesheetOwnerCanAddExtras", "agreedManagerSuggestions", "subcontractorScheduleCell",
        ] {
            XCTAssertTrue(names.contains(name), name)
        }
    }

    // MARK: Booking previews at the booking's own rate (owner example)

    func testOwnerExampleExplainsTheBookingsOwnRate() throws {
        let own = try XCTUnwrap(CanonicalBusinessEngine.bookingHoursExplanation(
            policy: ownerPolicy, dayKey: wednesday, start: "07:00", end: "19:00", isBreakRemoved: false, timeZone: zone,
            otMultiplierOverride: 2
        ))
        XCTAssertEqual(own.steps, ["07:00–16:00 = 8.5h (day, less 30 min unpaid break)", "+ 16:00–19:00 = 3h × 2 = 6h", "→ 14.5h"])
        XCTAssertEqual(own.totalPaidHours, 14.5, accuracy: 0.001)
        XCTAssertTrue(own.rule.contains("own overtime rate is 2×"), own.rule)

        // No rate (the organisation's): 13h, as before.
        let org = try XCTUnwrap(CanonicalBusinessEngine.bookingHoursExplanation(
            policy: ownerPolicy, dayKey: wednesday, start: "07:00", end: "19:00", isBreakRemoved: false, timeZone: zone
        ))
        XCTAssertEqual(org.steps.last, "→ 13h")
        XCTAssertEqual(org.totalPaidHours, 13, accuracy: 0.001)

        // The explanation is what the pay rule pays for the same booking (`payrollHoursResult`).
        let day = try XCTUnwrap(CanonicalBusinessEngine.date(fromDayKey: wednesday))
        let booking = Booking(
            operativeId: UUID(), projectId: UUID(), date: day, timeSlot: .customHours, bookedBy: "",
            workStartTime: "07:00", workEndTime: "19:00", isBreakRemoved: false, otMultiplierOverride: 2
        )
        let paid = try XCTUnwrap(PayrollHoursEngine.canonicalResult(booking: booking, day: day, policy: ownerPolicy))
        XCTAssertEqual(paid.totalPaidHours, own.totalPaidHours, accuracy: 0.001)
    }

    func testWeekdaySectionsCarryTheOwnRate() throws {
        let day = try XCTUnwrap(CanonicalBusinessEngine.date(fromDayKey: wednesday))
        let sections = CanonicalBusinessEngine.weekdayExplanationSections(
            on: [day], start: "07:00", end: "19:00", isBreakRemoved: false, fallbackPolicy: ownerPolicy,
            otMultiplierOverride: 2
        )
        let text = sections.flatMap(\.detail).joined(separator: "\n")
        XCTAssertTrue(text.contains("3h × 2 = 6h"), text)
        XCTAssertTrue(text.contains("→ 14.5h"), text)
    }

    func testWeekendRowsPriceTheOwnRate() throws {
        let org = try XCTUnwrap(CanonicalBusinessEngine.weekendBookingBreakdown(
            policy: .default, dayKeys: [saturday], start: "06:00", end: "18:00", isBreakRemoved: false, timeZone: zone
        )?.first)
        let own = try XCTUnwrap(CanonicalBusinessEngine.weekendBookingBreakdown(
            policy: .default, dayKeys: [saturday], start: "06:00", end: "18:00", isBreakRemoved: false, timeZone: zone,
            otMultiplierOverride: 3
        )?.first)
        XCTAssertEqual(own.multiplier, 3, accuracy: 0.001)
        XCTAssertEqual(own.overtimeHours, org.overtimeHours, accuracy: 0.001)
        XCTAssertGreaterThan(own.paidHoursEquivalent, org.paidHoursEquivalent)
        // A rate that is not a positive number is the organisation's (nil to the script).
        XCTAssertNil(CanonicalBusinessEngine.bookingOwnRate(0))
        XCTAssertNil(CanonicalBusinessEngine.bookingOwnRate(nil))
        XCTAssertEqual(CanonicalBusinessEngine.bookingOwnRate(2), 2)
    }

    // MARK: Timesheet line times

    func testStandardAndOvertimeLinesShowTheirOwnTimes() throws {
        let day = try XCTUnwrap(CanonicalBusinessEngine.date(fromDayKey: wednesday))
        func ranges(_ start: String, _ end: String) throws -> RulebookPayrollLineClockRanges {
            let booking = Booking(
                operativeId: UUID(), projectId: UUID(), date: day, timeSlot: .customHours, bookedBy: "",
                workStartTime: start, workEndTime: end, isBreakRemoved: false, otMultiplierOverride: nil
            )
            let hours = try XCTUnwrap(PayrollHoursEngine.canonicalResult(booking: booking, day: day, policy: ownerPolicy))
            return try XCTUnwrap(CanonicalBusinessEngine.payrollLineClockRanges(hours))
        }
        let owner = try ranges("07:00", "19:00")
        XCTAssertEqual(owner.standardText, "07:00–16:00")
        XCTAssertEqual(owner.overtimeText, "16:00–19:00")
        XCTAssertEqual(try ranges("05:00", "19:00").overtimeText, "05:00–07:00 + 16:00–19:00")
        XCTAssertEqual(try ranges("17:00", "20:00").standardText, "")

        // The line details the collector writes (web `timesheetPayrollCollector`).
        XCTAssertEqual(TimesheetPayrollCollector.standardLineDetails(clockRanges: owner, isBreakRemoved: false, fallback: "x"), "07:00–16:00")
        XCTAssertEqual(TimesheetPayrollCollector.standardLineDetails(clockRanges: owner, isBreakRemoved: true, fallback: "x"), "07:00–16:00 · no break")
        XCTAssertEqual(TimesheetPayrollCollector.standardLineDetails(clockRanges: nil, isBreakRemoved: false, fallback: "Full day"), "Full day")
        XCTAssertEqual(TimesheetPayrollCollector.overtimeLineDetails(clockRanges: owner, multiplied: nil, otHours: 3), "16:00–19:00")
        XCTAssertEqual(TimesheetPayrollCollector.overtimeLineDetails(clockRanges: nil, multiplied: nil, otHours: 3), "OT 3h")
    }

    func testClockTextNeverPrintsTheMultipliedTextTwice() {
        XCTAssertEqual(CanonicalBusinessEngine.timesheetLineClockText("16:00–19:00 · OT 6.5h × 2 − 0.5h break = 12.5h"), "16:00–19:00")
        XCTAssertEqual(CanonicalBusinessEngine.timesheetLineClockText("07:00–16:00 · no break"), "07:00–16:00 · no break")
        XCTAssertEqual(TimesheetPayrollCollector.lineClockLabel("16:00–19:00 · OT 6.5h × 2 − 0.5h break = 12.5h"), "16:00–19:00")
        // An older line stored as only the multiplied text: the rate line shows it, the details line nothing.
        XCTAssertNil(TimesheetPayrollCollector.lineClockLabel("OT 6.5h × 2 − 0.5h break = 12.5h"))
        // The rate line still reads the multiplied text from the whole details.
        XCTAssertEqual(
            CanonicalBusinessEngine.payLineHoursText(details: "16:00–19:00 · OT 6.5h × 2 − 0.5h break = 12.5h", paidHours: 6.25, isOvertimeLine: true),
            "6.5h × 2 − 0.5h break = 12.5h"
        )
    }

    // MARK: Sign-off gates

    func testSignOffWaitsForTheBookings() throws {
        let loading = try XCTUnwrap(CanonicalBusinessEngine.timesheetSnapshotReady(bookingsLoaded: false, bookingsFailed: false))
        XCTAssertFalse(loading.ready)
        XCTAssertEqual(loading.message, "Loading bookings…")
        let failed = try XCTUnwrap(CanonicalBusinessEngine.timesheetSnapshotReady(bookingsLoaded: false, bookingsFailed: true))
        XCTAssertTrue(failed.failed)
        XCTAssertFalse(failed.ready)
        let ready = try XCTUnwrap(CanonicalBusinessEngine.timesheetSnapshotReady(bookingsLoaded: true, bookingsFailed: false))
        XCTAssertTrue(ready.ready)
        XCTAssertNil(ready.message)
        // The organisation is checked first (pay inputs), then the bookings.
        XCTAssertEqual(
            PayInputsLoad.blockMessage(state: .loaded, organization: nil, bookings: (loaded: true, failed: false)),
            PayInputsLoad.organisationNotLoadedMessage
        )
    }

    func testOnlyAnEmptyUnexportedSnapshotIsRebuilt() {
        let approved = Date(timeIntervalSince1970: 1_762_765_200) // 10 Nov 2026 09:00 UTC
        let before = approved.addingTimeInterval(-86_400)
        let after = approved.addingTimeInterval(86_400)
        func needs(
            stored: Int? = 0,
            exported: Date? = nil,
            overrideApprovedAt: Date? = approved,
            managerSignedAt: Date? = nil,
            _ lines: [(isPayeDay: Bool, bookingCreatedAt: Date?, bookingUpdatedAt: Date?)]
        ) -> Bool {
            CanonicalBusinessEngine.timesheetSnapshotNeedsRebuild(
                storedOverrideLineCount: stored,
                overrideApprovedAt: overrideApprovedAt,
                exportedAt: exported,
                managerSignedAt: managerSignedAt,
                liveLabourLines: lines
            )
        }
        // A booking that existed when the sheet was approved and is missing from the snapshot: the loading bug.
        XCTAssertTrue(needs([(isPayeDay: false, bookingCreatedAt: before, bookingUpdatedAt: before)]))
        XCTAssertTrue(needs(overrideApprovedAt: nil, managerSignedAt: approved, [(isPayeDay: false, bookingCreatedAt: before, bookingUpdatedAt: before)]))
        // Review r318: a booking added after approval, or of unknown age, never re-prices a signed sheet.
        XCTAssertFalse(needs([(isPayeDay: false, bookingCreatedAt: after, bookingUpdatedAt: after)]))
        XCTAssertFalse(needs([(isPayeDay: false, bookingCreatedAt: nil, bookingUpdatedAt: before)]))
        // 2nd round: the later of createdAt and updatedAt counts — a booking moved into the period after approval, or
        // with no updatedAt, never re-prices it.
        XCTAssertFalse(needs([(isPayeDay: false, bookingCreatedAt: before, bookingUpdatedAt: after)]), "changed after approval")
        XCTAssertFalse(needs([(isPayeDay: false, bookingCreatedAt: before, bookingUpdatedAt: nil)]), "updatedAt unknown")
        XCTAssertFalse(needs([(isPayeDay: true, bookingCreatedAt: before, bookingUpdatedAt: before)]), "PAYE days are never timesheet lines")
        XCTAssertFalse(needs([]))
        XCTAssertFalse(needs(stored: 1, [(isPayeDay: false, bookingCreatedAt: before, bookingUpdatedAt: before)]), "never re-priced")
        XCTAssertFalse(needs(exported: Date(), [(isPayeDay: false, bookingCreatedAt: before, bookingUpdatedAt: before)]), "exported")
        XCTAssertFalse(needs(stored: nil, [(isPayeDay: false, bookingCreatedAt: before, bookingUpdatedAt: before)]), "no snapshot")
        XCTAssertFalse(needs(overrideApprovedAt: nil, [(isPayeDay: false, bookingCreatedAt: before, bookingUpdatedAt: before)]), "no approval time")
    }

    /// Review r318: sign-off opens only on a server-answered read that reaches the period — never the cache's copy or a
    /// narrower, earlier window, and never another company's read.
    func testServerCoverageMustReachThePeriod() throws {
        let periodStart = try XCTUnwrap(CanonicalBusinessEngine.date(fromDayKey: "2026-11-01"))
        let earlier = try XCTUnwrap(CanonicalBusinessEngine.date(fromDayKey: "2026-10-26"))
        let later = try XCTUnwrap(CanonicalBusinessEngine.date(fromDayKey: "2026-11-09"))
        XCTAssertTrue(BookingServerCoverage(organizationId: "org", fromDate: earlier).covers(organizationId: "org", from: periodStart))
        XCTAssertTrue(BookingServerCoverage(organizationId: "org", fromDate: nil).covers(organizationId: "org", from: periodStart))
        XCTAssertFalse(BookingServerCoverage(organizationId: "org", fromDate: later).covers(organizationId: "org", from: periodStart))
        XCTAssertFalse(BookingServerCoverage(organizationId: "other", fromDate: nil).covers(organizationId: "org", from: periodStart))
        XCTAssertFalse(BookingServerCoverage(organizationId: "org", fromDate: earlier).covers(organizationId: "org", from: nil), "the whole archive was asked for")
    }

    func testNoExtrasOnceTheLineManagerHasSigned() {
        let signed = CanonicalBusinessEngine.timesheetOwnerCanAddExtras(managerSignedAt: Date(), approvedAt: nil, selfSigned: false)
        XCTAssertFalse(signed.allowed)
        XCTAssertEqual(signed.message, "This timesheet is signed off — add it to your next timesheet.")
        XCTAssertEqual(CanonicalBusinessEngine.timesheetSignedOffExtrasMessage, signed.message)
        XCTAssertTrue(CanonicalBusinessEngine.timesheetOwnerCanAddExtras(managerSignedAt: nil, approvedAt: nil, selfSigned: false).allowed)
        XCTAssertTrue(CanonicalBusinessEngine.timesheetOwnerCanAddExtras(managerSignedAt: Date(), approvedAt: nil, selfSigned: true).allowed)
        XCTAssertFalse(CanonicalBusinessEngine.timesheetOwnerCanAddExtras(managerSignedAt: nil, approvedAt: Date(), selfSigned: false).allowed)
    }

    // MARK: Agreed-manager suggestions

    func testAgreedManagerSuggestionsAreThePriceWorkApprovers() {
        let org = "org-143"
        func row(_ id: String, _ first: String, _ last: String, role: String, extra: [String: Any] = [:], active: Bool = true) -> [String: Any] {
            var row: [String: Any] = [
                "id": id, "firstName": first, "surname": last, "email": "\(id)@x.com", "role": role,
                "isActive": active, "passwordSet": true, "organizationId": org,
            ]
            for (key, value) in extra { row[key] = value }
            return row
        }
        let roster = [
            row("op", "Olly", "Operative", role: "operative", extra: ["operativeMode": true]),
            row("pat", "Pat", "Manager", role: "manager", extra: ["manager": true]),
            row("ann", "Ann", "Admin", role: "admin", extra: ["adminAccess": true]),
            row("old", "Patricia", "Gone", role: "manager", extra: ["manager": true], active: false),
            row("op2", "Patrick", "Worker", role: "operative", extra: ["operativeMode": true]),
        ]
        let person = roster[0]
        XCTAssertEqual(CanonicalBusinessEngine.agreedManagerSuggestions(query: "PAT", person: person, roster: roster, organizationId: org), ["Pat Manager"])
        XCTAssertEqual(CanonicalBusinessEngine.agreedManagerSuggestions(query: "min", person: person, roster: roster, organizationId: org), ["Ann Admin"])
        XCTAssertEqual(CanonicalBusinessEngine.agreedManagerSuggestions(query: "Pat Manager", person: person, roster: roster, organizationId: org), [])
        XCTAssertEqual(CanonicalBusinessEngine.agreedManagerSuggestions(query: "  ", person: person, roster: roster, organizationId: org), [])
        XCTAssertEqual(CanonicalBusinessEngine.agreedManagerSuggestions(query: "pat", person: roster[1], roster: roster, organizationId: org), [])
    }

    // MARK: Subcontractor tiles

    func testSubcontractorTileShowsOnlyTheWorkingWindow() throws {
        let one = try XCTUnwrap(CanonicalBusinessEngine.subcontractorScheduleCell(
            bookings: [(timeSlot: "CUSTOM_HOURS", workStartTime: "07:00", workEndTime: "19:00")],
            policy: ownerPolicy,
            dayKey: wednesday
        ))
        XCTAssertEqual(one.headline, "07:00–19:00")
        XCTAssertNil(one.countText)
        let tile = one.dayCell
        XCTAssertEqual(tile.hoursText, "07:00–19:00")
        XCTAssertNil(tile.standardText)
        XCTAssertNil(tile.overtimeText)
        XCTAssertTrue(tile.overtimeLines.isEmpty)
        XCTAssertEqual(tile.cell.tone, "standard")

        let two = try XCTUnwrap(CanonicalBusinessEngine.subcontractorScheduleCell(
            bookings: [
                (timeSlot: "CUSTOM_HOURS", workStartTime: "13:00", workEndTime: "16:00"),
                (timeSlot: "CUSTOM_HOURS", workStartTime: "07:00", workEndTime: "12:00"),
            ],
            policy: nil,
            dayKey: wednesday
        ))
        XCTAssertEqual(two.timesText, "07:00–12:00 + 13:00–16:00")
        XCTAssertEqual(two.headline, "07:00–12:00 + 13:00–16:00 · 2 bookings")
        XCTAssertEqual(two.dayCell.countText, "2 bookings")

        // A named slot is its clock window under the day's working hours.
        let fullDay = try XCTUnwrap(CanonicalBusinessEngine.subcontractorScheduleCell(
            bookings: [(timeSlot: "FULL DAY", workStartTime: nil, workEndTime: nil)],
            policy: ownerPolicy,
            dayKey: wednesday
        ))
        XCTAssertEqual(fullDay.timesText, "07:00–16:00")
        XCTAssertNil(CanonicalBusinessEngine.subcontractorScheduleCell(bookings: [], policy: nil, dayKey: wednesday))
    }
}
