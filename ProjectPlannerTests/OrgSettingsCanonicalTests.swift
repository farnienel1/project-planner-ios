import XCTest
@testable import Project_Planner

@MainActor
final class OrgSettingsCanonicalTests: XCTestCase {
    func testEmptyOrganizationNameIsMissingAndRoundTrips() throws {
        let missing = try XCTUnwrap(CanonicalBusinessEngine.parseOrganizationName([:]))
        XCTAssertEqual(missing, "")
        let blank = try XCTUnwrap(CanonicalBusinessEngine.parseOrganizationName(["name": "   "]))
        XCTAssertEqual(blank, "")
        XCTAssertEqual(CanonicalBusinessEngine.displayOrganizationName(""), "Organisation")
        XCTAssertEqual(CanonicalBusinessEngine.displayOrganizationName("  "), "Organisation")

        let written = try XCTUnwrap(CanonicalBusinessEngine.organizationNameToFirestore("  Acme  "))
        XCTAssertEqual(written.count, 1)
        XCTAssertEqual(written["name"] as? String, "Acme")
        let again = try XCTUnwrap(CanonicalBusinessEngine.parseOrganizationName(written))
        XCTAssertEqual(again, "Acme")

        let blankFirestore = try XCTUnwrap(CanonicalBusinessEngine.organizationNameToFirestore(""))
        XCTAssertTrue(blankFirestore.isEmpty)
        XCTAssertNil(blankFirestore["name"])
        let blankWrite = try XCTUnwrap(
            CanonicalBusinessEngine.organizationNameWriteFields("   ", existingName: "Raccord MEP")
        )
        XCTAssertTrue(blankWrite.isEmpty)
        XCTAssertNil(blankWrite["name"])
        let renamed = try XCTUnwrap(
            CanonicalBusinessEngine.organizationNameWriteFields("  Acme  ", existingName: "Raccord MEP")
        )
        XCTAssertEqual(renamed.count, 1)
        XCTAssertEqual(renamed["name"] as? String, "Acme")
        XCTAssertEqual(
            CanonicalBusinessEngine.coalesceOrganizationName(["", "  ", "Raccord MEP"]),
            "Raccord MEP"
        )
        XCTAssertEqual(CanonicalBusinessEngine.coalesceOrganizationName(["", ""]), "")
    }

    func testDateRangeLeftoverRecurringDateShowsMonthStrip() throws {
        let leftover = try XCTUnwrap(CanonicalBusinessEngine.parseInvoicing([
            "paymentRunMode": "date_ranges",
            "paymentDateMode": "recurring_date",
            "paymentDates": [20, 5],
            "paymentRunDateRanges": [
                ["startDate": 1, "endDate": 15],
                ["startDate": 16, "endDate": 31],
            ],
        ]))
        XCTAssertEqual(leftover.paymentRunMode, "date_ranges")
        XCTAssertEqual(leftover.paymentDateMode, "specific_dates")
        let leftoverCoverage = try XCTUnwrap(CanonicalBusinessEngine.paymentRunShowsMonthCoverage(leftover))
        XCTAssertTrue(leftoverCoverage)

        let recurring = try XCTUnwrap(CanonicalBusinessEngine.parseInvoicing([
            "paymentRunMode": "recurring_timeframe",
            "paymentDateMode": "recurring_date",
            "recurringRunStartDay": "monday",
            "recurringRunEndDay": "sunday",
            "recurringPaymentDay": "friday",
        ]))
        XCTAssertEqual(recurring.paymentRunMode, "recurring_timeframe")
        XCTAssertEqual(recurring.paymentDateMode, "recurring_date")
        let recurringCoverage = try XCTUnwrap(CanonicalBusinessEngine.paymentRunShowsMonthCoverage(recurring))
        XCTAssertFalse(recurringCoverage)
    }

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

    func testPaymentRunStripFollowsParsedRangesAndTheSaveGate() throws {
        let covered = try XCTUnwrap(CanonicalBusinessEngine.parseInvoicing([
            "paymentRunMode": "date_ranges",
            "paymentDateMode": "specific_dates",
            "paymentRunDateRanges": [
                ["startDay": 1, "endDay": 15, "startDate": 1, "endDate": 15],
                ["startDay": 16, "endDay": 31, "startDate": 16, "endDate": 31],
            ],
            "paymentDates": [18, 28],
        ]))
        let coveredDays = PaymentRunMonthCoverage.days(in: covered.paymentRunDateRanges)
        XCTAssertEqual(coveredDays.filter { $0.state == .run1 }.map(\.day), Array(1...15))
        XCTAssertEqual(coveredDays.filter { $0.state == .run2 }.map(\.day), Array(16...31))
        XCTAssertEqual(PaymentRunMonthCoverage.legend(for: coveredDays), .coveredOnce)
        XCTAssertEqual(PaymentRunMonthCoverage.legend(for: coveredDays).text, "✓ Every day covered once")
        XCTAssertNil(CanonicalBusinessEngine.validateInvoicingSettings(covered))

        let overlap = try XCTUnwrap(CanonicalBusinessEngine.parseInvoicing([
            "paymentRunMode": "date_ranges",
            "paymentDateMode": "specific_dates",
            "paymentRunDateRanges": [
                ["startDay": 1, "endDay": 20],
                ["startDay": 16, "endDay": 31],
            ],
            "paymentDates": [18, 28],
        ]))
        let overlapDays = PaymentRunMonthCoverage.days(in: overlap.paymentRunDateRanges)
        XCTAssertEqual(overlapDays.filter { $0.state == .overlap }.map(\.day), Array(16...20))
        XCTAssertEqual(
            PaymentRunMonthCoverage.legend(for: overlapDays).text,
            "5 days in both runs"
        )
        XCTAssertNotNil(CanonicalBusinessEngine.validateInvoicingSettings(overlap))

        let gap = try XCTUnwrap(CanonicalBusinessEngine.parseInvoicing([
            "paymentRunMode": "date_ranges",
            "paymentDateMode": "specific_dates",
            "paymentRunDateRanges": [
                ["startDay": 1, "endDay": 10],
                ["startDay": 16, "endDay": 31],
            ],
            "paymentDates": [18, 28],
        ]))
        let gapDays = PaymentRunMonthCoverage.days(in: gap.paymentRunDateRanges)
        XCTAssertEqual(gapDays.filter { $0.state == .gap }.map(\.day), Array(11...15))
        XCTAssertEqual(PaymentRunMonthCoverage.legend(for: gapDays).text, "5 days not covered")
        XCTAssertNotNil(CanonicalBusinessEngine.validateInvoicingSettings(gap))

        let wrapped = try XCTUnwrap(CanonicalBusinessEngine.normalizePaymentRunRange(startDay: 27, endDay: 11))
        XCTAssertEqual(wrapped.startDay, 27)
        XCTAssertEqual(wrapped.endDay, 11)
        let wrappedDays = PaymentRunMonthCoverage.days(in: [
            wrapped,
            CanonicalBusinessEngine.CanonicalPaymentRunRange(startDay: 12, endDay: 26),
        ])
        XCTAssertTrue(wrappedDays.filter { $0.state == .run1 }.isEmpty)
        XCTAssertEqual(wrappedDays.filter { $0.state == .gap }.map(\.day), Array(1...11) + Array(27...31))
        XCTAssertEqual(wrappedDays.filter { $0.state == .run2 }.map(\.day), Array(12...26))
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
