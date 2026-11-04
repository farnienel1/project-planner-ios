import XCTest
@testable import Project_Planner

/// Guardrail 7 (booking UI upgrade): the same booking opened in Edit booking and saved without changes writes the same
/// fields and prices the same through `payrollHoursResult` before and after the restyle, and the restyled header shows
/// the figures the old Breakdown card showed. Bookings: a weekday 07:00–20:00 with the break on at the organisation
/// rate and at a custom ×1.5, ×2; a Saturday custom 08:00–14:00.
@MainActor
final class BookingEditSaveParityTests: XCTestCase {
    private let policy = OrgPayrollTimePolicy.default

    private func day(_ key: String) throws -> Date {
        try XCTUnwrap(CanonicalBusinessEngine.date(fromDayKey: key))
    }

    private func stored(on day: Date, start: String, end: String, breakRemoved: Bool = false, rate: Double? = nil) -> Booking {
        var booking = LogicFixtures.booking(on: day, slot: .customHours, start: start, end: end, breakRemoved: breakRemoved)
        booking.otMultiplierOverride = rate
        return booking
    }

    /// The arguments Edit booking passes to `onSave` when opened on `booking` and saved unchanged.
    private struct SaveArguments: Equatable {
        let start: String
        let end: String
        let isBreakRemoved: Bool
        let otMultiplierOverride: Double?
    }

    /// `oldOpening` is the pre-restyle opening state (`showsBreakControls ? !isBreakRemoved : false`); otherwise the
    /// current `OperativeCustomHoursSheet.initialBreakIncluded`. Times and rate open exactly as the sheet's init does.
    private func saveArguments(_ booking: Booking, showsBreakControls: Bool, oldOpening: Bool) -> SaveArguments {
        let choice = OperativeDayBookingChoice(from: booking)
        let start = BookingHMTimePickerSupport.clampToQuarterHour(choice.workStartTime ?? "", fallbackHour: 8, fallbackMinute: 0)
        let end = BookingHMTimePickerSupport.clampToQuarterHour(choice.workEndTime ?? "", fallbackHour: 16, fallbackMinute: 30)
        let breakIncluded = oldOpening
            ? (showsBreakControls ? !choice.isBreakRemoved : false)
            : OperativeCustomHoursSheet.initialBreakIncluded(initialChoice: choice, showsBreakControls: showsBreakControls)
        return SaveArguments(
            start: BookingHMTimePickerSupport.format(hour: start.hour, minute: start.minute),
            end: BookingHMTimePickerSupport.format(hour: end.hour, minute: end.minute),
            isBreakRemoved: !breakIncluded,
            otMultiplierOverride: choice.otMultiplierOverride
        )
    }

    /// The labour save closures' field mapping (Scheduling `projectDetailBookingEditSheet` `.operative` onSave and
    /// Daily Overview `saveOperativeBookingEdit`).
    private func written(_ booking: Booking, _ args: SaveArguments) -> Booking {
        var updated = booking
        updated.timeSlot = .customHours
        updated.workStartTime = args.start
        updated.workEndTime = args.end
        updated.isBreakRemoved = args.isBreakRemoved
        updated.otMultiplierOverride = args.otMultiplierOverride
        return updated
    }

    private struct Figures: Equatable {
        let total: Double
        let standard: Double
        let outside: Double
        let unpaidBreak: Double
        let multipliedText: String?
    }

    private func figures(_ booking: Booking, on day: Date) -> Figures {
        let result = PayrollHoursEngine.compute(booking: booking, day: day, policy: policy)
        return Figures(
            total: result.totalPaidHours,
            standard: result.standardHours,
            outside: result.outsideHours,
            unpaidBreak: result.unpaidBreakHours,
            multipliedText: result.multipliedHours?.text
        )
    }

    private func cases() throws -> [(name: String, day: Date, booking: Booking)] {
        let monday = try day("2026-11-02")
        let saturday = try day("2026-11-07")
        return [
            ("weekday 07:00–20:00 break on, organisation rate", monday, stored(on: monday, start: "07:00", end: "20:00")),
            ("weekday 07:00–20:00 break on, ×1.5", monday, stored(on: monday, start: "07:00", end: "20:00", rate: 1.5)),
            ("weekday 07:00–20:00 break on, ×2", monday, stored(on: monday, start: "07:00", end: "20:00", rate: 2)),
            ("weekday 07:00–20:00 break removed", monday, stored(on: monday, start: "07:00", end: "20:00", breakRemoved: true)),
            ("Saturday custom 08:00–14:00", saturday, stored(on: saturday, start: "08:00", end: "14:00")),
        ]
    }

    func testAnUnchangedSaveWritesTheSameFieldsAndPricesTheSame() throws {
        for item in try cases() {
            // A self-employed operative: break controls on, before and after.
            let old = written(item.booking, saveArguments(item.booking, showsBreakControls: true, oldOpening: true))
            let new = written(item.booking, saveArguments(item.booking, showsBreakControls: true, oldOpening: false))
            XCTAssertEqual(old.timeSlot, new.timeSlot, item.name)
            XCTAssertEqual(old.workStartTime, new.workStartTime, item.name)
            XCTAssertEqual(old.workEndTime, new.workEndTime, item.name)
            XCTAssertEqual(old.isBreakRemoved, new.isBreakRemoved, item.name)
            XCTAssertEqual(old.otMultiplierOverride, new.otMultiplierOverride, item.name)
            // And both equal what was stored.
            XCTAssertEqual(new.workStartTime, item.booking.workStartTime, item.name)
            XCTAssertEqual(new.workEndTime, item.booking.workEndTime, item.name)
            XCTAssertEqual(new.isBreakRemoved, item.booking.isBreakRemoved, item.name)
            XCTAssertEqual(new.otMultiplierOverride, item.booking.otMultiplierOverride, item.name)
            XCTAssertEqual(figures(old, on: item.day), figures(new, on: item.day), item.name)
            XCTAssertEqual(figures(new, on: item.day), figures(item.booking, on: item.day), item.name)
        }
    }

    func testPayeFromSchedulingNowSavesLikeDailyOverview() throws {
        let paye = LabourBookingEditOptions.forOperative(isPaye: true)
        for item in try cases() {
            // Daily Overview always opened with break controls; Scheduling's PAYE path now uses the same options.
            let dailyOverview = written(item.booking, saveArguments(item.booking, showsBreakControls: true, oldOpening: true))
            let scheduling = written(item.booking, saveArguments(item.booking, showsBreakControls: paye.showsBreakControls, oldOpening: false))
            XCTAssertEqual(scheduling.isBreakRemoved, dailyOverview.isBreakRemoved, item.name)
            XCTAssertEqual(scheduling.isBreakRemoved, item.booking.isBreakRemoved, "fix A: the stored break is kept — \(item.name)")
            XCTAssertEqual(figures(scheduling, on: item.day), figures(dailyOverview, on: item.day), item.name)
        }
    }

    /// The restyled header binds `payrollHoursResult` values; the old Breakdown card showed the same numbers.
    func testTheHeaderShowsTheOldBreakdownFigures() throws {
        for item in try cases() {
            let choice = OperativeDayBookingChoice(from: item.booking)
            let probe = choice.bookingProbe(operativeId: UUID(), projectId: UUID(), date: item.day, bookedBy: "")
            let breakdown = BookingEditHoursBreakdown.compute(
                booking: probe,
                policy: policy,
                day: item.day,
                breakIncluded: !choice.isBreakRemoved
            )
            XCTAssertEqual(breakdown.standardRateHours, breakdown.result.standardHours, accuracy: 0.0001, "Standard hrs — \(item.name)")
            XCTAssertEqual(breakdown.overtimeText, breakdown.result.multipliedHours?.text ?? "", "OT text — \(item.name)")
            XCTAssertEqual(breakdown.breakDeductionHours, breakdown.result.unpaidBreakHours, accuracy: 0.0001, "Unpaid break — \(item.name)")
            XCTAssertEqual(breakdown.totalHours, figures(item.booking, on: item.day).total, accuracy: 0.0001, "Total — \(item.name)")
        }
    }

    /// The rate chips' per-rate figures re-run the probe at that rate; saving that rate prices exactly that.
    func testEachRateFigureMatchesTheBookingSavedAtThatRate() throws {
        let monday = try day("2026-11-02")
        let booking = stored(on: monday, start: "07:00", end: "20:00")
        for rate in [nil, 1, 1.25, 1.5, 2, 3] as [Double?] {
            let probe = OperativeDayBookingChoice(
                timeSlot: .customHours,
                workStartTime: "07:00",
                workEndTime: "20:00",
                isBreakRemoved: false,
                otMultiplierOverride: rate
            ).bookingProbe(operativeId: UUID(), projectId: UUID(), date: monday, bookedBy: "")
            var saved = booking
            saved.otMultiplierOverride = rate
            XCTAssertEqual(figures(probe, on: monday), figures(saved, on: monday), "rate \(String(describing: rate))")
            XCTAssertEqual(probe.paidBookedHours(policy: policy), saved.paidBookedHours(policy: policy), accuracy: 0.0001)
        }
    }
}
