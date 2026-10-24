import XCTest
@testable import Project_Planner

@MainActor
final class MaterialDeliveryCanonicalTests: XCTestCase {
    func testWeekdayNowIsTomorrowAt0800London() throws {
        let friday = try XCTUnwrap(Self.fixedNow("2026-10-09T15:00:00+01:00"))
        let at = try XCTUnwrap(CanonicalBusinessEngine.defaultMaterialDeliveryRequiredAt(now: friday))
        XCTAssertEqual(
            CanonicalBusinessEngine.formatMaterialDeliveryRequired(at),
            "Saturday 10 October at 08:00"
        )
        XCTAssertEqual(CanonicalBusinessEngine.exportKind("unbookedLabourRowsOnDay"), "function" as String?)
        XCTAssertEqual(CanonicalBusinessEngine.exportKind("sortWarningsByDate"), "function" as String?)
    }

    func testSaturdayAndSundayNowAreNextMondayAt0800London() throws {
        let saturday = try XCTUnwrap(Self.fixedNow("2026-10-10T09:30:00+01:00"))
        let fromSaturday = try XCTUnwrap(CanonicalBusinessEngine.defaultMaterialDeliveryRequiredAt(now: saturday))
        XCTAssertEqual(
            CanonicalBusinessEngine.formatMaterialDeliveryRequired(fromSaturday),
            "Monday 12 October at 08:00"
        )

        let sunday = try XCTUnwrap(Self.fixedNow("2026-10-11T22:00:00+01:00"))
        let fromSunday = try XCTUnwrap(CanonicalBusinessEngine.defaultMaterialDeliveryRequiredAt(now: sunday))
        XCTAssertEqual(
            CanonicalBusinessEngine.formatMaterialDeliveryRequired(fromSunday),
            "Monday 12 October at 08:00"
        )
    }

    func testOrderIncludesDeliveryRequiredAndQuoteDoesNot() {
        XCTAssertEqual(CanonicalBusinessEngine.materialOrderIncludesDeliveryRequired("Order"), true as Bool?)
        XCTAssertEqual(CanonicalBusinessEngine.materialOrderIncludesDeliveryRequired("order"), true as Bool?)
        XCTAssertEqual(CanonicalBusinessEngine.materialOrderIncludesDeliveryRequired("Quote"), false as Bool?)
        XCTAssertEqual(CanonicalBusinessEngine.materialOrderIncludesDeliveryRequired("quote"), false as Bool?)
    }

    func testFormatRendersInstantAndQuotePathSkipsMissingValue() throws {
        let saturday = try XCTUnwrap(Self.fixedNow("2026-10-10T09:30:00+01:00"))
        let at = try XCTUnwrap(CanonicalBusinessEngine.defaultMaterialDeliveryRequiredAt(now: saturday))
        XCTAssertEqual(
            CanonicalBusinessEngine.formatMaterialDeliveryRequired(at),
            "Monday 12 October at 08:00"
        )
        XCTAssertNil(CanonicalBusinessEngine.orderDeliveryRequiredLabel(requestType: "Quote", at: nil))
        XCTAssertNil(CanonicalBusinessEngine.orderDeliveryRequiredLabel(requestType: "Order", at: nil))
        XCTAssertNil(CanonicalBusinessEngine.orderDeliveryRequiredLabel(requestType: "Quote", at: at))
        XCTAssertEqual(
            CanonicalBusinessEngine.orderDeliveryRequiredLabel(requestType: "Order", at: at),
            "Monday 12 October at 08:00"
        )
    }

    private static func fixedNow(_ iso: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: iso)
    }
}
