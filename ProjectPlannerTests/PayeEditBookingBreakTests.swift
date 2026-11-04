import XCTest
@testable import Project_Planner

/// Fix A: a PAYE operative's booking opened from Scheduling showed no break controls, so Edit booking opened with the
/// Unpaid break off and Save wrote `isBreakRemoved = true` on a booking nobody changed, and the overtime rate card
/// (RULEBOOK 1.29.0 §25, `overtimeRateControl`) was hidden. Scheduling now uses Daily Overview's controls for every
/// person and the sheet opens on the booking's stored break.
@MainActor
final class PayeEditBookingBreakTests: XCTestCase {
    private func choice(breakRemoved: Bool) -> OperativeDayBookingChoice {
        OperativeDayBookingChoice(
            timeSlot: .customHours,
            workStartTime: "07:00",
            workEndTime: "16:00",
            isBreakRemoved: breakRemoved,
            otMultiplierOverride: nil
        )
    }

    /// What the sheet hands to `onSave` for `isBreakRemoved` when nothing is touched (`!breakIncluded`).
    private func savedBreakRemoved(_ stored: Bool, options: LabourBookingEditOptions) -> Bool {
        !OperativeCustomHoursSheet.initialBreakIncluded(
            initialChoice: choice(breakRemoved: stored),
            showsBreakControls: options.showsBreakControls
        )
    }

    func testPayeBookingKeepsItsStoredBreakWhenSavedUnchanged() {
        let paye = LabourBookingEditOptions.forOperative(isPaye: true)
        XCTAssertFalse(savedBreakRemoved(false, options: paye), "a PAYE booking with its break on keeps it on")
        XCTAssertTrue(savedBreakRemoved(true, options: paye), "a PAYE booking with its break removed keeps it removed")
    }

    func testPayeBookingShowsTheSameControlsAsDailyOverview() {
        let paye = LabourBookingEditOptions.forOperative(isPaye: true)
        let selfEmployed = LabourBookingEditOptions.forOperative(isPaye: false)
        XCTAssertTrue(paye.showsBreakControls, "the overtime rate card needs the break controls")
        XCTAssertTrue(paye.allowsOtMultiplierOverride, "1.29.0 §25: the rate applies to PAYE bookings too")
        XCTAssertTrue(paye.showsBreakdown)
        XCTAssertTrue(paye.showsPayeNote, "the PAYE line still shows")
        XCTAssertFalse(selfEmployed.showsPayeNote)
        XCTAssertEqual(paye.showsBreakControls, selfEmployed.showsBreakControls)
        XCTAssertEqual(paye.allowsOtMultiplierOverride, selfEmployed.allowsOtMultiplierOverride)
    }

    func testCallersWithoutBreakControlsKeepTheirOldOpeningState() {
        // Subcontractor and timesheet overtime-line sheets show no break controls: unchanged, the break opens off.
        XCTAssertFalse(OperativeCustomHoursSheet.initialBreakIncluded(initialChoice: choice(breakRemoved: false), showsBreakControls: false))
        // A new booking opens with the unpaid break on, as web.
        XCTAssertTrue(OperativeCustomHoursSheet.initialBreakIncluded(initialChoice: nil, showsBreakControls: true))
    }
}
