import XCTest
@testable import Project_Planner

/// RULEBOOK 1.61.0 §8 (owner decision 17 Nov): a day-rate overtime line reads in hours through `CanonicalBusinessEngine
/// .dayRateOvertimeCalcText` — wording only, the amount is the line's own. Expected text checked in node against the
/// packed script.
@MainActor
final class Rulebook1610Tests: XCTestCase {
    func testOwnerExampleReadsInHours() {
        // £225/day, 8.5h paid day, 6h at ×1.5 → £238.24 (was "0.71 days × £337.50/day = £238.24").
        XCTAssertEqual(
            CanonicalBusinessEngine.dayRateOvertimeCalcText(
                clockHours: 6, multiplier: 1.5, breakHours: 0, dayRate: 225, dayRateHours: 8.5, pay: 238.24, currencyCode: "GBP"
            ),
            "6h × 1.5 = 9h · 9h × £26.47/h (rounded) = £238.24 (£225.00/day ÷ 8.5h)"
        )
        // With an unpaid break in the multiplied hours; an exact hourly rate is not marked rounded.
        XCTAssertEqual(
            CanonicalBusinessEngine.dayRateOvertimeCalcText(
                clockHours: 6.5, multiplier: 2, breakHours: 0.5, dayRate: 200, dayRateHours: 8, pay: 312.5, currencyCode: "GBP"
            ),
            "6.5h × 2 − 0.5h break = 12.5h · 12.5h × £25.00/h = £312.50 (£200.00/day ÷ 8h)"
        )
        XCTAssertNil(CanonicalBusinessEngine.dayRateOvertimeCalcText(
            clockHours: 6, multiplier: 1.5, breakHours: 0, dayRate: 0, dayRateHours: 8.5, pay: 0, currencyCode: "GBP"
        ))
    }

    func testInvoiceLineUsesItOnlyForDayRateOvertime() {
        var overtime = InvoiceLineItem(
            lineId: "op-b1-ot", date: Date(), jobNumber: "J-1", projectName: "Site (Overtime)", details: "16:00–22:00",
            paidHours: 6, payrollBasis: .dayRate, dayRate: 337.5, hourlyRate: nil, amount: 238.24, isOvertimeLine: true
        )
        XCTAssertNil(overtime.dayRateOvertimeText, "no multiplier known → the older text stays")
        overtime.otMultiplier = 1.5
        overtime.baseDayRate = 225
        overtime.dayRateDivisor = 8.5
        XCTAssertEqual(overtime.dayRateOvertimeText, "6h × 1.5 = 9h · 9h × £26.47/h (rounded) = £238.24 (£225.00/day ÷ 8.5h)")
        var standard = InvoiceLineItem(
            lineId: "op-b1-normal", date: Date(), jobNumber: "J-1", projectName: "Site", details: "07:00–16:00",
            paidHours: 8.5, payrollBasis: .dayRate, dayRate: 225, hourlyRate: nil, amount: 225
        )
        standard.otMultiplier = 1.5
        standard.baseDayRate = 225
        standard.dayRateDivisor = 8.5
        XCTAssertNil(standard.dayRateOvertimeText, "standard lines keep their wording")
    }
}
