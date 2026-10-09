import XCTest
@testable import Project_Planner

@MainActor
final class OrgSettingsCanonicalTests: XCTestCase {
    func testPaymentRunWriteKeepsCustomSplitAndBothDayFields() throws {
        var settings = OrganizationInvoicingSettings.default
        settings.paymentRunMode = .dateRanges
        settings.paymentDateMode = .specificDates
        settings.paymentRunDateRanges = [
            PaymentRunDateRange(startDay: 1, endDay: 16),
            PaymentRunDateRange(startDay: 17, endDay: 31),
        ]
        settings.paymentDates = [18, 28]
        let canonical = settings.canonicalInvoicingSettings()
        XCTAssertNil(CanonicalBusinessEngine.validateInvoicingSettings(canonical))
        let map = try XCTUnwrap(CanonicalBusinessEngine.invoicingToFirestore(canonical))
        let ranges = try XCTUnwrap(map["paymentRunDateRanges"] as? [[String: Any]])
        XCTAssertEqual(int(ranges[0]["startDay"]), 1)
        XCTAssertEqual(int(ranges[0]["endDay"]), 16)
        XCTAssertEqual(int(ranges[0]["startDate"]), 1)
        XCTAssertEqual(int(ranges[0]["endDate"]), 16)
        XCTAssertEqual(int(ranges[1]["startDay"]), 17)
        XCTAssertEqual(int(ranges[1]["endDay"]), 31)
        XCTAssertEqual(int(ranges[1]["startDate"]), 17)
        XCTAssertEqual(int(ranges[1]["endDate"]), 31)
    }

    func testLegacyStartDateDocumentAndMissingRanges() throws {
        let legacy = try XCTUnwrap(CanonicalBusinessEngine.parseInvoicing([
            "paymentRunDateRanges": [
                ["startDate": 1, "endDate": 16],
                ["startDate": 17, "endDate": 31],
            ],
        ]))
        XCTAssertEqual(legacy.paymentRunMode, "date_ranges")
        XCTAssertEqual(legacy.paymentRunDateRanges[0].startDay, 1)
        XCTAssertEqual(legacy.paymentRunDateRanges[0].endDay, 16)
        XCTAssertEqual(legacy.paymentRunDateRanges[1].startDay, 17)
        XCTAssertEqual(legacy.paymentRunDateRanges[1].endDay, 31)

        let missing = try XCTUnwrap(CanonicalBusinessEngine.parseInvoicing([:]))
        XCTAssertEqual(missing.paymentRunDateRanges.map(\.startDay), [1, 16])
        XCTAssertEqual(missing.paymentRunDateRanges.map(\.endDay), [15, 31])
    }

    func testOverlappingPaymentRunsAreRefused() {
        var settings = OrganizationInvoicingSettings.default
        settings.paymentDateMode = .specificDates
        settings.paymentRunDateRanges = [
            PaymentRunDateRange(startDay: 1, endDay: 20),
            PaymentRunDateRange(startDay: 16, endDay: 31),
        ]
        settings.paymentDates = [18, 28]
        let message = CanonicalBusinessEngine.validateInvoicingSettings(settings.canonicalInvoicingSettings())
        XCTAssertNotNil(message)
    }

    func testWarningDetectionSaveIsTheTopLevelMap() throws {
        let settings = OrgWarningDetectionSettings.default
        let map = FirebaseBackend.warningDetectionFirestoreMap(settings)
        XCTAssertEqual(map["clashLookaheadMode"] as? String, "numberOfDays")
        XCTAssertEqual(int(map["clashLookaheadDays"]), 7)
        XCTAssertEqual(map["detectClashes"] as? Bool, true)
        XCTAssertEqual(map["includeWeekendsForUnbookedLabour"] as? Bool, false)
        XCTAssertFalse(map.keys.contains("settings"))
    }

    func testOrgDocumentReadsMaterialCutOffAndLegacyPayrollNames() throws {
        let settings = FirebaseBackend.organizationSettingsFromOrgDocument([
            "settings": [
                "materialCutOff": [
                    "materialOrderCutOff": true,
                    "materialCutOffHour": 15,
                    "materialCutOffMinute": 30,
                    "materialCutOffOnSaturday": true,
                    "materialCutOffOnSunday": false,
                ],
            ],
            "payrollTimePolicy": [
                "sundaySameAsSaturday": true,
                "saturday": [
                    "definedWindowStart": "08:00",
                    "definedWindowEnd": "13:00",
                    "countsAsStandardHours": 5,
                    "outsideWindowMultiplier": 2,
                    "allHoursAtMultiplierMode": false,
                ],
            ],
        ])
        let cutOff = settings.materialCutOff
        XCTAssertEqual(cutOff?.materialCutOffHour, 15)
        XCTAssertEqual(cutOff?.materialCutOffMinute, 30)
        XCTAssertEqual(cutOff?.materialCutOffOnSaturday, true)
        XCTAssertEqual(settings.payrollTimePolicy.saturday.customStandardStart, "08:00")
        XCTAssertEqual(settings.payrollTimePolicy.saturday.customStandardEnd, "13:00")
        XCTAssertEqual(settings.payrollTimePolicy.saturday.countsAsHours, 5)
        XCTAssertEqual(settings.payrollTimePolicy.saturday.outsideStandardWindowMultiplier, 2)
        XCTAssertTrue(settings.payrollTimePolicy.sundaySameAsSaturday)
        let written = settings.payrollTimePolicy.asFirestoreDictionary()
        let saturday = try XCTUnwrap(written["saturday"] as? [String: Any])
        XCTAssertEqual(saturday["customStandardStart"] as? String, "08:00")
        XCTAssertEqual(saturday["countsAsHours"] as? Double, 5)
        XCTAssertEqual(written["sundaySameAsSaturday"] as? Bool, true)
        XCTAssertNil(saturday["definedWindowStart"])
        XCTAssertNil(saturday["countsAsStandardHours"])
    }

    func testStaffSeeVariationsAndOnlyAdminsManageTheTracker() {
        let operative = CanonicalBusinessEngine.CanonicalStaffAccountRole(
            isSuperAdmin: false,
            isAdmin: true,
            isManager: true,
            isOperativeMode: true
        )
        let manager = CanonicalBusinessEngine.CanonicalStaffAccountRole(
            isSuperAdmin: false,
            isAdmin: false,
            isManager: true,
            isOperativeMode: false
        )
        let admin = CanonicalBusinessEngine.CanonicalStaffAccountRole(
            isSuperAdmin: false,
            isAdmin: true,
            isManager: false,
            isOperativeMode: false
        )
        XCTAssertFalse(CanonicalBusinessEngine.canSeeVariations(operative))
        XCTAssertFalse(CanonicalBusinessEngine.canManageVariationTracker(operative))
        XCTAssertTrue(CanonicalBusinessEngine.canSeeVariations(manager))
        XCTAssertFalse(CanonicalBusinessEngine.canManageVariationTracker(manager))
        XCTAssertTrue(CanonicalBusinessEngine.canSeeVariations(admin))
        XCTAssertTrue(CanonicalBusinessEngine.canManageVariationTracker(admin))
    }

    private func int(_ value: Any?) -> Int? {
        (value as? NSNumber)?.intValue ?? value as? Int
    }
}
