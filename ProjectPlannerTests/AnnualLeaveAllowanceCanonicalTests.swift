import XCTest
@testable import Project_Planner

@MainActor
final class AnnualLeaveAllowanceCanonicalTests: XCTestCase {
    func testScriptExportsAllowanceFunctions() {
        let names = [
            "hasAnnualLeaveAllowance",
            "leaveYearBounds",
            "annualLeaveBalance",
            "applyRemainingOverride",
            "snapLeaveDays",
        ]
        for name in names {
            XCTAssertEqual(CanonicalBusinessEngine.exportKind(name), "function", name)
        }
        XCTAssertEqual(CanonicalBusinessEngine.exportKind("ANNUAL_LEAVE_ALLOWANCE_COPY"), "object")
    }

    func testAllowanceCopyMatchesTheRulebook() {
        let copy = CanonicalBusinessEngine.annualLeaveAllowanceCopy()
        XCTAssertEqual(copy?.toggleTitle, "Annual leave allowance")
        XCTAssertEqual(
            copy?.toggleDescription,
            "Turn off annual leave allowances using this toggle. This is generally used for self-employed staff who do not get paid annual leave, therefore they do not have a set number of days per year."
        )
        XCTAssertEqual(
            copy?.toggleNote,
            "When off, this person can still book and see annual leave. They see days taken in the company leave year, not a remaining balance or days per year."
        )
        XCTAssertEqual(
            copy?.remainingTitle,
            "Manually adjust this user's remaining annual leave allowance for this year"
        )
        XCTAssertEqual(
            copy?.remainingNote,
            "This number will reset to the Days per year figure at the end of your company year."
        )
    }

    func testNovemberHalfDayThenJanuaryResetsToDaysPerYear() {
        let override = CanonicalBusinessEngine.applyRemainingOverride(
            remaining: 0.5,
            taken: 0,
            pending: 0,
            yearKey: "2026-01-01"
        )
        XCTAssertEqual(override?.annualLeaveYearAllowance, 0.5)
        XCTAssertEqual(override?.annualLeaveYearAllowanceKey, "2026-01-01")

        let joined = balance(
            onDayKey: "2026-11-05",
            yearAllowance: override?.annualLeaveYearAllowance,
            yearAllowanceKey: override?.annualLeaveYearAllowanceKey,
            bookings: []
        )
        XCTAssertEqual(joined?.remaining, 0.5)
        XCTAssertEqual(joined?.taken, 0)

        let booked = balance(
            onDayKey: "2026-11-05",
            yearAllowance: override?.annualLeaveYearAllowance,
            yearAllowanceKey: override?.annualLeaveYearAllowanceKey,
            bookings: [
                CanonicalBusinessEngine.CanonicalLeaveBooking(
                    startDayKey: "2026-11-05",
                    endDayKey: "2026-11-05",
                    timeSlot: "AM",
                    status: "approved"
                ),
            ]
        )
        XCTAssertEqual(booked?.taken, 0.5)
        XCTAssertEqual(booked?.remaining, 0)

        let nextYear = balance(
            onDayKey: "2027-01-01",
            yearAllowance: override?.annualLeaveYearAllowance,
            yearAllowanceKey: override?.annualLeaveYearAllowanceKey,
            bookings: [
                CanonicalBusinessEngine.CanonicalLeaveBooking(
                    startDayKey: "2026-11-05",
                    endDayKey: "2026-11-05",
                    timeSlot: "AM",
                    status: "approved"
                ),
            ]
        )
        XCTAssertEqual(nextYear?.yearKey, "2027-01-01")
        XCTAssertEqual(nextYear?.taken, 0)
        XCTAssertEqual(nextYear?.remaining, 25)
    }

    func testNoAllowanceCountsTheCompanyLeaveYear() {
        XCTAssertFalse(CanonicalBusinessEngine.hasAnnualLeaveAllowance(false))
        let counted = CanonicalBusinessEngine.annualLeaveBalance(
            annualLeaveEnabled: false,
            daysPerYear: 25,
            startMonth: 4,
            endMonth: 3,
            orgDaysPerYear: 28,
            orgStartMonth: 1,
            orgEndMonth: 12,
            carriesOver: true,
            yearAllowance: 0.5,
            yearAllowanceKey: "2026-01-01",
            bookings: [
                CanonicalBusinessEngine.CanonicalLeaveBooking(
                    startDayKey: "2026-11-05",
                    endDayKey: "2026-11-05",
                    timeSlot: "AM",
                    status: "approved"
                ),
                CanonicalBusinessEngine.CanonicalLeaveBooking(
                    startDayKey: "2026-11-06",
                    endDayKey: "2026-11-06",
                    timeSlot: "FULL DAY",
                    status: "pending"
                ),
                CanonicalBusinessEngine.CanonicalLeaveBooking(
                    startDayKey: "2026-11-07",
                    endDayKey: "2026-11-07",
                    timeSlot: "FULL DAY",
                    status: "rejected"
                ),
            ],
            onDayKey: "2026-11-05"
        )
        XCTAssertEqual(counted?.hasAllowance, false)
        XCTAssertNil(counted?.remaining)
        XCTAssertEqual(counted?.yearKey, "2026-01-01")
        XCTAssertEqual(counted?.taken, 0.5)
        XCTAssertEqual(counted?.pending, 1)
        XCTAssertEqual(counted?.usedThisYear, 0.5)
    }

    func testUsageSummaryUsesTheSameNovemberPath() {
        let start = CanonicalBusinessEngine.date(fromDayKey: "2026-11-05")!
        let booking = LogicFixtures.holiday(
            userId: "user-1",
            start: start,
            end: start,
            status: .approved,
            slot: .morning
        )
        let summary = AnnualLeavePolicy.usageSummary(
            bookings: [booking],
            profileUserId: "user-1",
            operativeId: nil,
            daysPerYear: 25,
            startMonth: 1,
            endMonth: 12,
            carriesOver: false,
            referenceDate: start,
            annualLeaveEnabled: true,
            yearAllowance: 0.5,
            yearAllowanceKey: "2026-01-01"
        )
        XCTAssertEqual(summary.yearKey, "2026-01-01")
        XCTAssertClose(summary.takenDays, 0.5)
        XCTAssertClose(summary.remainingDays ?? -1, 0)
        XCTAssertTrue(summary.hasAllowance)
    }

    private func balance(
        onDayKey: String,
        yearAllowance: Double?,
        yearAllowanceKey: String?,
        bookings: [CanonicalBusinessEngine.CanonicalLeaveBooking]
    ) -> CanonicalBusinessEngine.CanonicalAnnualLeaveBalance? {
        CanonicalBusinessEngine.annualLeaveBalance(
            annualLeaveEnabled: true,
            daysPerYear: 25,
            startMonth: 1,
            endMonth: 12,
            orgDaysPerYear: 25,
            orgStartMonth: 1,
            orgEndMonth: 12,
            carriesOver: false,
            yearAllowance: yearAllowance,
            yearAllowanceKey: yearAllowanceKey,
            bookings: bookings,
            onDayKey: onDayKey
        )
    }
}
