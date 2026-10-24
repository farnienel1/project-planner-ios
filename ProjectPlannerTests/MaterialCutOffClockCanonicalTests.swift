import XCTest
@testable import Project_Planner

@MainActor
final class MaterialCutOffClockCanonicalTests: XCTestCase {
    func testOrgFifteenThirtyWinsOverUserPrefHour() throws {
        let clock = try XCTUnwrap(
            CanonicalBusinessEngine.resolveMaterialCutOffClock([
                "organizationMaterialCutOff": [
                    "materialCutOffHour": 15,
                    "materialCutOffMinute": 30,
                    "materialOrderCutOff": true,
                    "materialCutOffOnSaturday": false,
                    "materialCutOffOnSunday": true,
                ],
                "userNotificationPreferences": [
                    "materialCutOffHour": 16,
                    "materialCutOffMinute": 0,
                ],
            ])
        )
        XCTAssertEqual(clock.materialCutOffHour, 15)
        XCTAssertEqual(clock.materialCutOffMinute, 30)
        XCTAssertEqual(clock.materialCutOffOnSunday, true)
        XCTAssertEqual(CanonicalBusinessEngine.formatMaterialCutOffClock(clock), "15:30")
        XCTAssertEqual(CanonicalBusinessEngine.materialCutOffClockMinutes(clock), (15 * 60) + 30)

        let written = try XCTUnwrap(CanonicalBusinessEngine.materialCutOffToFirestore(clock))
        XCTAssertEqual(int(written["materialCutOffHour"]), 15)
        XCTAssertEqual(int(written["materialCutOffMinute"]), 30)
        XCTAssertEqual(written["materialOrderCutOff"] as? Bool, true)
        XCTAssertEqual(written["materialCutOffOnSunday"] as? Bool, true)
        XCTAssertFalse(written.keys.contains("notificationPreferences"))
        XCTAssertFalse(written.keys.contains("invoicing"))
        let again = try XCTUnwrap(CanonicalBusinessEngine.parseMaterialCutOff(written))
        XCTAssertEqual(again.materialCutOffHour, 15)
        XCTAssertEqual(again.materialCutOffMinute, 30)
    }

    func testMissingHourDefaultsToSixteenInsideTheScript() throws {
        let clock = try XCTUnwrap(
            CanonicalBusinessEngine.resolveMaterialCutOffClock([
                "organizationMaterialCutOff": [
                    "materialCutOffMinute": 30,
                ],
            ])
        )
        XCTAssertEqual(clock.materialCutOffHour, 16)
        XCTAssertEqual(clock.materialCutOffMinute, 30)
        XCTAssertEqual(CanonicalBusinessEngine.formatMaterialCutOffClock(clock), "16:30")
    }

    func testUserPrefHourAloneDoesNotSetTheClock() throws {
        let clock = try XCTUnwrap(
            CanonicalBusinessEngine.resolveMaterialCutOffClock([
                "userNotificationPreferences": [
                    "materialCutOffHour": 9,
                    "materialCutOffMinute": 15,
                ],
            ])
        )
        XCTAssertEqual(clock.materialCutOffHour, 16)
        XCTAssertEqual(clock.materialCutOffMinute, 0)
        XCTAssertNotEqual(clock.materialCutOffHour, 9)
        XCTAssertEqual(CanonicalBusinessEngine.formatMaterialCutOffClock(clock), "16:00")

        let stored = OrgMaterialCutOff(
            materialOrderCutOff: true,
            materialCutOffHour: 15,
            materialCutOffMinute: 30,
            materialCutOffOnSaturday: false,
            materialCutOffOnSunday: false
        )
        let resolved = try XCTUnwrap(
            OrgMaterialCutOff.resolve(stored: stored, organizationLoaded: true)
        )
        XCTAssertEqual(resolved.materialCutOffHour, 15)
        XCTAssertEqual(resolved.materialCutOffMinute, 30)
        XCTAssertNil(OrgMaterialCutOff.resolve(stored: stored, organizationLoaded: false))
    }

    private func int(_ value: Any?) -> Int? {
        if let number = value as? Int { return number }
        if let number = value as? NSNumber { return number.intValue }
        return nil
    }
}
