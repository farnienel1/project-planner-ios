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

    // MARK: - Owner 17 Nov: the calculation must never fail

    /// The amount as the timesheet collector prices it (`payForHours` in the packed script).
    private func payForHours(dayRate: Double, paidHours: Double, divisor: Double, multiplier: Double) -> Double {
        let input: [String: Any] = ["payBasis": "day", "dayRate": dayRate, "paidHours": paidHours, "standardDayHours": divisor, "otMultiplier": multiplier]
        return (CanonicalBusinessEngine.callJSON("payForHours", arguments: [input]) as? NSNumber)?.doubleValue ?? .nan
    }

    func testEveryFigureIsTheRulebooksOverManyInputs() throws {
        let multipliers: [Double] = [1, 1.25, 1.5, 1.75, 2, 2.25, 2.5, 2.75, 3]
        let paidDays: [Double] = [7, 7.5, 8, 8.5, 9, 9.5, 10]
        let dayRates: [Double] = [100, 180, 225, 237.5, 275.55, 333.33, 412.17]
        let clocks: [Double] = [0.25, 1, 2.5, 3.75, 6]
        let breaks: [Double] = [0, 0.5]
        var checked = 0
        for multiplier in multipliers {
            for divisor in paidDays {
                for dayRate in dayRates {
                    for clock in clocks {
                        for brk in breaks where clock * multiplier > brk {
                            // The hours the booking pays at the multiplier (clock − break ÷ N, as `payrollHoursResult`).
                            let baseHours = clock - brk / multiplier
                            let pay = payForHours(dayRate: dayRate, paidHours: baseHours, divisor: divisor, multiplier: multiplier)
                            let calc = try XCTUnwrap(CanonicalBusinessEngine.dayRateOvertimeCalc(
                                clockHours: clock, multiplier: multiplier, breakHours: brk,
                                dayRate: dayRate, dayRateHours: divisor, pay: pay, currencyCode: "GBP"
                            ))
                            let label = "\(clock)h ×\(multiplier) − \(brk) £\(dayRate)/day ÷ \(divisor)"
                            // The £ shown is the line amount exactly.
                            XCTAssertEqual(calc.pay, pay, label)
                            XCTAssertTrue(calc.text.contains("= \(OrgMoney.format(pay, currencyCode: "GBP")) ("), "\(label): \(calc.text)")
                            // The hours sum shown is the overtime paid hours.
                            XCTAssertEqual(calc.paidHours, baseHours * multiplier, accuracy: 1e-9, label)
                            XCTAssertTrue(calc.text.hasPrefix(CanonicalBusinessEngine.multipliedHoursText(clockHours: clock, multiplier: multiplier, breakHours: brk)), label)
                            // The rounded hourly rate is day rate ÷ divisor in pennies.
                            XCTAssertEqual(calc.hourlyRate, CanonicalBusinessEngine.roundPennies(dayRate / divisor), label)
                            XCTAssertEqual(CanonicalBusinessEngine.dayRateHourlyEquivalent(dayRate: dayRate, dayRateHours: divisor), calc.hourlyRate, label)
                            checked += 1
                        }
                    }
                }
            }
        }
        XCTAssertGreaterThan(checked, 3000)
    }

    func testTextNeverChangesOrBlocksTheAmount() {
        // A line whose stored multiplied text does not match its paid hours: the older wording, the amount as priced.
        var mismatched = InvoiceLineItem(
            lineId: "op-b2-ot", date: Date(), jobNumber: "J-1", projectName: "Site (Overtime)",
            details: "16:00–22:30 · OT 6.5h × 2 − 0.5h break = 12.5h",
            paidHours: 6, payrollBasis: .dayRate, dayRate: 400, hourlyRate: nil, amount: 300, isOvertimeLine: true
        )
        mismatched.otMultiplier = 2
        mismatched.baseDayRate = 200
        mismatched.dayRateDivisor = 8
        XCTAssertNil(mismatched.dayRateOvertimeText, "hours that are not the line's own are never shown")
        XCTAssertEqual(mismatched.amount, 300)
        // The same line with its own paid hours (6.25h × 2 = 12.5h) shows the hours wording; the amount is unchanged.
        var matched = InvoiceLineItem(
            lineId: "op-b2-ot", date: Date(), jobNumber: "J-1", projectName: "Site (Overtime)",
            details: "16:00–22:30 · OT 6.5h × 2 − 0.5h break = 12.5h",
            paidHours: 6.25, payrollBasis: .dayRate, dayRate: 400, hourlyRate: nil, amount: 312.5, isOvertimeLine: true
        )
        matched.otMultiplier = 2
        matched.baseDayRate = 200
        matched.dayRateDivisor = 8
        XCTAssertEqual(matched.dayRateOvertimeText, "6.5h × 2 − 0.5h break = 12.5h · 12.5h × £25.00/h = £312.50 (£200.00/day ÷ 8h)")
        XCTAssertEqual(matched.amount, 312.5)
        // A divisor below 1 hour: no text (the caller keeps the older wording), the amount untouched.
        matched.dayRateDivisor = 0.5
        XCTAssertNil(matched.dayRateOvertimeText)
        XCTAssertEqual(matched.amount, 312.5)
    }
}
