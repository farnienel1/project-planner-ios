import XCTest
@testable import Project_Planner

/// RULEBOOK 1.19.0 behaviour on iOS through `CanonicalBusinessEngine`. Every expected value was checked in node against
/// the packed `canonical-business.js` (sha256 853013bd…79a24562), fed the same stored shapes these Swift models write.
@MainActor
final class Rulebook1190Tests: XCTestCase {
    private let zone = "Europe/London"
    // Saturday 7 Nov 2026, Sunday 8 Nov, Monday 9 Nov.
    private let saturday = "2026-11-07"
    private let sunday = "2026-11-08"
    private let monday = "2026-11-09"

    /// The owner's examples: Saturday window 07:30–14:00 counts as 8h; Sunday every hour at 2× (the default Sunday);
    /// weekday break 12:00–12:30, 30 min, unpaid.
    private func ownerPolicy(
        saturdayBreakPaid: Bool? = nil,
        saturdayBreakMinutes: Int? = nil,
        saturdayBreakWindow: (String, String)? = nil,
        sundayBreakPaid: Bool? = nil
    ) -> OrgPayrollTimePolicy {
        var policy = OrgPayrollTimePolicy.default
        policy.saturday.customStandardEnd = "14:00"
        policy.saturday.breakPaid = saturdayBreakPaid
        policy.saturday.breakMinutes = saturdayBreakMinutes
        policy.saturday.breakWindowStart = saturdayBreakWindow?.0
        policy.saturday.breakWindowEnd = saturdayBreakWindow?.1
        policy.sunday.breakPaid = sundayBreakPaid
        return policy
    }

    private func paid(_ policy: OrgPayrollTimePolicy, day: String, _ start: String, _ end: String, breakRemoved: Bool = false) throws -> RulebookPayrollHours {
        try XCTUnwrap(CanonicalBusinessEngine.payrollHoursResult(RulebookPayrollHoursInput(
            booking: CanonicalPayrollBooking(
                timeSlot: "CUSTOM_HOURS", workStartTime: start, workEndTime: end, isBreakRemoved: breakRemoved, otMultiplierOverride: nil
            ),
            dayKey: day,
            policy: policy,
            timeZone: zone
        )))
    }

    func testThePackedScriptIsRulebook1190OrLater() throws {
        let stamp = try XCTUnwrap(CanonicalBusinessEngine.rulebookStamp())
        let parts = stamp.version.split(separator: ".").compactMap { Int($0) }
        XCTAssertFalse(parts.lexicographicallyPrecedes([1, 19, 0]), "rulebook \(stamp.version) predates 1.19.0")
        let names = Set(CanonicalBusinessEngine.exportNames())
        for name in [
            "payrollTimePolicySaveConflict", "parseWeekendCoverage", "resolveWeekendCoverageDay", "weekendBreakFor",
            "payrollBreakOnDay", "payrollDayWindows", "unpaidBreakAppliesOnDay", "weekendLunchBreakCopy",
            "payrollTimePolicyHistoryEntries", "parsePayrollTimePolicyHistory", "windowCoverage",
        ] {
            XCTAssertTrue(names.contains(name), name)
        }
    }

    // MARK: Owner's weekend lunch break examples (§4.3, §8)

    func testSaturdayWindowWithAPaidBreakPaysTheFullCountsAsHours() throws {
        let result = try paid(ownerPolicy(), day: saturday, "07:30", "14:00")
        XCTAssertEqual(result.hours.totalPaidHours, 8, accuracy: 0.001)
        XCTAssertEqual(result.unpaidBreakHours, 0, accuracy: 0.001)
    }

    func testSaturdayWindowWithAnUnpaidBreakTakesHalfAnHourOff() throws {
        let result = try paid(ownerPolicy(saturdayBreakPaid: false), day: saturday, "07:30", "14:00")
        XCTAssertEqual(result.hours.totalPaidHours, 7.5, accuracy: 0.001)
        XCTAssertEqual(result.unpaidBreakHours, 0.5, accuracy: 0.001)
    }

    func testSaturdaysOwnFortyFiveMinuteBreakTakesThreeQuartersOff() throws {
        let policy = ownerPolicy(saturdayBreakPaid: false, saturdayBreakMinutes: 45, saturdayBreakWindow: ("11:30", "12:15"))
        let result = try paid(policy, day: saturday, "07:30", "14:00")
        XCTAssertEqual(result.hours.totalPaidHours, 7.25, accuracy: 0.001)
        XCTAssertEqual(result.unpaidBreakHours, 0.75, accuracy: 0.001)
        let dayBreak = try XCTUnwrap(CanonicalBusinessEngine.payrollBreakOnDay(policy: policy, dayKey: saturday, timeZone: zone))
        XCTAssertEqual(dayBreak, RulebookDayBreak(start: 690, end: 735, minutes: 45, paid: false))
        XCTAssertEqual(
            CanonicalBusinessEngine.weekendLunchBreakCopy(policy: policy, weekday: .saturday),
            RulebookLunchBreakCopy(title: "Lunch break on Saturday", detail: "11:30–12:15, 45 min.")
        )
    }

    func testSundayEveryHourAtTwoPaidUnpaidAndNoUnpaidBreak() throws {
        XCTAssertEqual(try paid(ownerPolicy(), day: sunday, "07:30", "14:00").hours.totalPaidHours, 13, accuracy: 0.001)
        let unpaid = ownerPolicy(sundayBreakPaid: false)
        XCTAssertEqual(try paid(unpaid, day: sunday, "07:30", "14:00").hours.totalPaidHours, 12, accuracy: 0.001)
        XCTAssertEqual(
            try paid(unpaid, day: sunday, "07:30", "14:00", breakRemoved: true).hours.totalPaidHours, 13, accuracy: 0.001,
            "No unpaid break cancels the weekend break as on weekdays"
        )
    }

    func testWeekendBreakdownRowsCarryTheBreakLineAndTheMonFriStyleLines() throws {
        let rows = try XCTUnwrap(CanonicalBusinessEngine.weekendBookingBreakdown(
            policy: ownerPolicy(saturdayBreakPaid: false, sundayBreakPaid: false),
            dayKeys: [saturday, sunday], start: "07:30", end: "14:00", isBreakRemoved: false, timeZone: zone
        ))
        XCTAssertEqual(rows.map(\.line), [
            "Saturday 07:30–14:00 = 8h − 0.5h unpaid break = 7.5h",
            "Sunday 07:30–14:00 = (6.5h − 0.5h unpaid break) × 2 = 12h",
        ])
        XCTAssertEqual(rows.map(\.unpaidBreakHours), [0.5, 0.5])
        XCTAssertEqual(rows[0].lines.map(\.label), ["Set hours", "Unpaid break", "Total paid hours"])
        XCTAssertEqual(rows[0].lines.map(\.value), ["8h", "−0.5h", "7.5h"])
        XCTAssertEqual(rows[1].lines.map(\.label), ["Every hour", "Unpaid break", "Total paid hours"])
        XCTAssertEqual(rows[1].lines.map(\.value), ["6.5h × 2", "−0.5h", "12h"])
    }

    func testTheToggleAndLunchWarningOnAWeekendOnlyWhenThatDaysBreakIsUnpaid() {
        let paidSaturday = ownerPolicy()
        let unpaidSaturday = ownerPolicy(saturdayBreakPaid: false)
        XCTAssertFalse(CanonicalBusinessEngine.unpaidBreakAppliesOnDay(policy: paidSaturday, dayKey: saturday, timeZone: zone))
        XCTAssertTrue(CanonicalBusinessEngine.unpaidBreakAppliesOnDay(policy: unpaidSaturday, dayKey: saturday, timeZone: zone))
        XCTAssertTrue(CanonicalBusinessEngine.unpaidBreakAppliesOnDay(policy: paidSaturday, dayKey: monday, timeZone: zone))
        XCTAssertNil(CanonicalBusinessEngine.customHoursBreakWarning(
            policy: paidSaturday, dayKey: saturday, workStartTime: "07:30", workEndTime: "14:00", isBreakRemoved: false, timeZone: zone
        ))
        XCTAssertNotNil(CanonicalBusinessEngine.customHoursBreakWarning(
            policy: unpaidSaturday, dayKey: saturday, workStartTime: "07:30", workEndTime: "14:00", isBreakRemoved: false, timeZone: zone
        ))
        let windows = CanonicalBusinessEngine.payrollDayWindows(policy: unpaidSaturday, dayKey: saturday, timeZone: zone)
        XCTAssertEqual(windows?.paidWindow, CanonicalMinuteInterval(start: 450, end: 840))
        XCTAssertEqual(windows?.unpaidBreak, CanonicalMinuteInterval(start: 720, end: 750))
        let sundayBands = CanonicalBusinessEngine.payrollDayWindows(policy: paidSaturday, dayKey: sunday, timeZone: zone)
        XCTAssertNil(sundayBands?.paidWindow)
        XCTAssertNil(sundayBands?.unpaidBreak, "a paid weekend break draws no unpaid band")
        XCTAssertEqual(sundayBands?.allHoursMultiplier, 2)
        XCTAssertEqual(
            CanonicalBusinessEngine.weekendBreakFor(policy: paidSaturday, weekday: .saturday),
            RulebookWeekendBreak(paid: true, minutes: 30, start: "12:00", end: "12:30"),
            "an untouched weekend day is the weekday break, paid"
        )
    }

    // MARK: Working hours save round-trip (CRITICAL: no field dropped)

    func testTheSwiftModelRoundTripsEveryWeekendBreakField() {
        var policy = ownerPolicy(saturdayBreakPaid: false, saturdayBreakMinutes: 45, saturdayBreakWindow: ("11:30", "12:15"))
        policy.sunday.breakPaid = false
        policy.sunday.breakMinutes = 60
        policy.sunday.breakWindowStart = "12:00"
        policy.sunday.breakWindowEnd = "13:00"
        let stored = policy.asFirestoreDictionary()
        let saturdayMap = stored["saturday"] as? [String: Any]
        XCTAssertEqual(saturdayMap?["breakPaid"] as? Bool, false)
        XCTAssertEqual(saturdayMap?["breakMinutes"] as? Int, 45)
        XCTAssertEqual(saturdayMap?["breakWindowStart"] as? String, "11:30")
        XCTAssertEqual(saturdayMap?["breakWindowEnd"] as? String, "12:15")
        let back = OrgPayrollTimePolicy.fromFirestore(stored)
        XCTAssertEqual(back.saturday.breakPaid, false)
        XCTAssertEqual(back.saturday.breakMinutes, 45)
        XCTAssertEqual(back.saturday.breakWindowStart, "11:30")
        XCTAssertEqual(back.saturday.breakWindowEnd, "12:15")
        XCTAssertEqual(back.sunday.breakPaid, false)
        XCTAssertEqual(back.sunday.breakMinutes, 60)
        XCTAssertEqual(back.sunday.breakWindowStart, "12:00")
        XCTAssertEqual(back.sunday.breakWindowEnd, "13:00")
        // An untouched day writes no own length or window (it keeps reading as the weekday break) and reads as paid.
        let untouched = OrgPayrollTimePolicy.default.asFirestoreDictionary()["saturday"] as? [String: Any]
        XCTAssertEqual(untouched?["breakPaid"] as? Bool, true)
        XCTAssertNil(untouched?["breakMinutes"])
        XCTAssertNil(untouched?["breakWindowStart"])
        XCTAssertNil(OrgPayrollTimePolicy.fromFirestore([:]).saturday.breakPaid)
        XCTAssertTrue(OrgPayrollTimePolicy.fromFirestore([:]).saturday.isBreakPaid)
    }

    func testAnIOSApplyFromTodayKeepsWeekendBreaksHistoryAndRevision() throws {
        let previous = ownerPolicy()
        let next = ownerPolicy(saturdayBreakPaid: false, saturdayBreakMinutes: 45, saturdayBreakWindow: ("11:30", "12:15"), sundayBreakPaid: false)
        let stored: [String: Any] = ["countryCode": "GB", "payrollTimePolicy": previous.asFirestoreDictionary()]
        let fields = try XCTUnwrap(CanonicalBusinessEngine.payrollTimePolicyApplyNowWriteFields(
            orgDocument: stored, policy: next, todayKey: "2026-11-03", timeZone: zone
        ))
        // Partial update of the working-hours fields only.
        XCTAssertEqual(Set(fields.keys), [
            "payrollTimePolicy", "payrollTimePolicyPrior", "payrollTimePolicyEffectiveFrom",
            "payrollTimePolicyHistory", "payrollTimePolicyRevision",
        ])
        XCTAssertEqual(fields["payrollTimePolicyRevision"] as? Int, 1)
        let current = try XCTUnwrap(fields["payrollTimePolicy"] as? [String: Any])
        let saturdayMap = try XCTUnwrap(current["saturday"] as? [String: Any])
        XCTAssertEqual(saturdayMap["breakPaid"] as? Bool, false)
        XCTAssertEqual(saturdayMap["breakMinutes"] as? Int, 45)
        XCTAssertEqual(saturdayMap["breakWindowStart"] as? String, "11:30")
        XCTAssertEqual(saturdayMap["breakWindowEnd"] as? String, "12:15")
        XCTAssertEqual((current["sunday"] as? [String: Any])?["breakPaid"] as? Bool, false)
        let history = try XCTUnwrap(fields["payrollTimePolicyHistory"] as? [[String: Any]])
        XCTAssertEqual(history.compactMap { $0["effectiveFrom"] as? String }, ["1970-01-01", "2026-11-03"])

        // Read back as the app reads the document (listener / after the transaction): nothing is lost.
        var merged = stored
        for (key, value) in fields { merged[key] = value }
        var org = Organization(name: "TEST-Org")
        FirebaseBackend.applyPayrollPolicyFields(from: merged, to: &org)
        XCTAssertEqual(org.settings.payrollTimePolicy.saturday.breakPaid, false)
        XCTAssertEqual(org.settings.payrollTimePolicy.saturday.breakMinutes, 45)
        XCTAssertEqual(org.settings.payrollTimePolicy.saturday.breakWindowStart, "11:30")
        XCTAssertEqual(org.settings.payrollTimePolicy.saturday.breakWindowEnd, "12:15")
        XCTAssertEqual(org.settings.payrollTimePolicy.sunday.breakPaid, false)
        let state = try XCTUnwrap(PayrollTimePolicyCatalog.payrollStateDocument(json: org.payrollPolicyStateJSON))
        XCTAssertEqual((state["payrollTimePolicyHistory"] as? [Any])?.count, 2)
        XCTAssertEqual(state["payrollTimePolicyRevision"] as? Int, 1)
        XCTAssertEqual(CanonicalBusinessEngine.payrollTimePolicyRevision(orgDocument: state, timeZone: zone), 1)
        // The pricing document is the stored state, history included.
        let document = PayrollTimePolicyCatalog.payrollPolicyDocument(for: org)
        XCTAssertNotNil(document["payrollTimePolicyHistory"])

        // A second save from the read-back state appends; it never drops an entry.
        let second = try XCTUnwrap(CanonicalBusinessEngine.payrollTimePolicyApplyNowWriteFields(
            orgDocument: state, policy: org.settings.payrollTimePolicy, todayKey: "2026-11-04", timeZone: zone
        ))
        XCTAssertEqual((second["payrollTimePolicyHistory"] as? [Any])?.count, 3)
        XCTAssertEqual(second["payrollTimePolicyRevision"] as? Int, 2)
        let secondSaturday = ((second["payrollTimePolicy"] as? [String: Any])?["saturday"] as? [String: Any])
        XCTAssertEqual(secondSaturday?["breakMinutes"] as? Int, 45, "a Swift re-save keeps the weekend break")
    }

    func testAStaleSaveIsRefusedWithTheRulebookMessage() throws {
        let base: [String: Any] = ["payrollTimePolicy": ownerPolicy().asFirestoreDictionary()]
        let fields = try XCTUnwrap(CanonicalBusinessEngine.payrollTimePolicyApplyNowWriteFields(
            orgDocument: base, policy: ownerPolicy(saturdayBreakPaid: false), todayKey: "2026-11-03", timeZone: zone
        ))
        var live = base
        for (key, value) in fields { live[key] = value }
        XCTAssertEqual(
            CanonicalBusinessEngine.payrollTimePolicySaveConflict(baseOrgDocument: base, liveOrgDocument: live, timeZone: zone),
            "Someone else changed the working hours while you were editing. Your change was not saved — check the latest working hours and try again."
        )
        XCTAssertEqual(CanonicalBusinessEngine.payrollPolicyStaleSaveMessage, CanonicalBusinessEngine.payrollTimePolicySaveConflict(
            baseOrgDocument: base, liveOrgDocument: live, timeZone: zone
        ))
        XCTAssertNil(CanonicalBusinessEngine.payrollTimePolicySaveConflict(baseOrgDocument: live, liveOrgDocument: live, timeZone: zone))
    }

    // MARK: Three changes keep past days (§1, §4.3)

    func testAThreeChangeHistoryKeepsEachPastDayOnItsOwnRules() throws {
        func ending(_ end: String) -> OrgPayrollTimePolicy {
            var policy = ownerPolicy()
            policy.standardDayEnd = end
            return policy
        }
        var document: [String: Any] = ["payrollTimePolicy": ending("16:00").asFirestoreDictionary()]
        let first = try XCTUnwrap(CanonicalBusinessEngine.payrollTimePolicyApplyNowWriteFields(
            orgDocument: document, policy: ending("17:00"), todayKey: "2026-10-01", timeZone: zone
        ))
        for (key, value) in first { document[key] = value }
        let second = try XCTUnwrap(CanonicalBusinessEngine.payrollTimePolicyApplyNowWriteFields(
            orgDocument: document, policy: ending("18:00"), todayKey: "2026-11-01", timeZone: zone
        ))
        for (key, value) in second { document[key] = value }
        XCTAssertEqual(document["payrollTimePolicyRevision"] as? Int, 2)
        let entries = try XCTUnwrap(CanonicalBusinessEngine.payrollTimePolicyHistoryEntries(orgDocument: document, timeZone: zone))
        XCTAssertEqual(entries.map(\.effectiveFrom), ["1970-01-01", "2026-10-01", "2026-11-01"])
        XCTAssertEqual(entries.map(\.policy.standardDayEnd), ["16:00", "17:00", "18:00"])
        for (day, end) in [("2026-09-15", "16:00"), ("2026-10-15", "17:00"), ("2026-11-15", "18:00")] {
            XCTAssertEqual(
                CanonicalBusinessEngine.effectivePayrollTimePolicy(orgDocument: document, dayKey: day, timeZone: zone)?.standardDayEnd,
                end,
                day
            )
        }
        // Before 1.19.0 only the prior was kept, so September read the second change's rules (17:00).
        let legacy: [String: Any] = [
            "payrollTimePolicy": ending("18:00").asFirestoreDictionary(),
            "payrollTimePolicyPrior": ending("17:00").asFirestoreDictionary(),
            "payrollTimePolicyEffectiveFrom": "2026-11-01",
        ]
        XCTAssertEqual(
            CanonicalBusinessEngine.effectivePayrollTimePolicy(orgDocument: legacy, dayKey: "2026-09-15", timeZone: zone)?.standardDayEnd,
            "17:00"
        )
    }

    // MARK: Weekend hours to cover (§4.6, §5)

    private func unbookedRows(bookings: [[String: Any]], coverage: OrgWeekendCoverage) throws -> [[String: Any]] {
        let document: [String: Any] = ["payrollTimePolicy": ownerPolicy().asFirestoreDictionary()]
        let state = try XCTUnwrap(CanonicalBusinessEngine.payrollPolicyState(document: document, todayKey: "2026-11-03", timeZone: zone))
        let payload: [String: Any] = [
            "timeZone": zone,
            "startDayKey": saturday,
            "endDayKey": sunday,
            "includeWeekends": true,
            "excludedUserIds": [String](),
            "standardPaidHours": 8,
            "saturdayCountsAsHours": 8,
            "sundayCountsAsHours": 8,
            "standardDayStart": "07:30",
            "standardDayEnd": "16:00",
            "breakWindowStart": "12:00",
            "breakWindowEnd": "12:30",
            "people": [[
                "id": "u1", "email": "op@x.com", "name": "Op One", "isActive": true, "passwordSet": true,
                "isOperativeMode": true, "isManager": false, "isAdmin": false, "isSuperAdmin": false,
            ]],
            "operatives": [[String: Any]](),
            "bookings": bookings,
            "holidays": [[String: Any]](),
            "payrollPolicy": state,
            "weekendCoverage": coverage.asFirestoreDictionary(),
        ]
        return try XCTUnwrap(CanonicalBusinessEngine.objectRows(function: "unbookedLabourRows", payload: payload))
    }

    private func saturdayBooking(_ start: String, _ end: String) -> [String: Any] {
        ["personId": "u1", "dayKey": saturday, "kind": "operative", "timeSlot": "CUSTOM_HOURS", "workStart": start, "workEnd": end]
    }

    private let saturdayOnly = OrgWeekendCoverage(
        saturday: OrgWeekendCoverageDay(enabled: true, start: "07:30", end: "14:00"),
        sunday: OrgWeekendCoverageDay(enabled: false, start: nil, end: nil)
    )

    func testSaturdayBookedUntilHalfElevenIsMissingTwoHours() throws {
        let rows = try unbookedRows(bookings: [saturdayBooking("07:30", "11:30")], coverage: saturdayOnly)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?["dayKey"] as? String, saturday)
        XCTAssertEqual((rows.first?["missingHours"] as? NSNumber)?.doubleValue ?? -1, 2, accuracy: 0.001)
        XCTAssertEqual(rows.first?["message"] as? String, "Op One is missing 2h on Saturday 7 November.")
    }

    func testBookingsEitherSideOfLunchCoverTheDay() throws {
        let rows = try unbookedRows(
            bookings: [saturdayBooking("07:30", "12:00"), saturdayBooking("12:30", "14:00")],
            coverage: saturdayOnly
        )
        XCTAssertTrue(rows.isEmpty, "lunch never needs covering and Sunday is off")
    }

    func testSundaySwitchedOffIsNotScanned() throws {
        let rows = try unbookedRows(bookings: [], coverage: saturdayOnly)
        XCTAssertEqual(rows.compactMap { $0["dayKey"] as? String }, [saturday])
        XCTAssertEqual((rows.first?["missingHours"] as? NSNumber)?.doubleValue ?? -1, 6, accuracy: 0.001, "6.5h less the 30-min lunch")
    }

    func testWeekendCoverageIsReadSavedWholeAndDefaultsAsBefore() throws {
        // Missing: both days follow include-weekends, windows unset.
        let missing = try XCTUnwrap(CanonicalBusinessEngine.parseWeekendCoverage(nil, includeWeekends: true))
        XCTAssertEqual(missing, OrgWeekendCoverage(
            saturday: OrgWeekendCoverageDay(enabled: true, start: nil, end: nil),
            sunday: OrgWeekendCoverageDay(enabled: true, start: nil, end: nil)
        ))
        // A reversed window is not a window.
        let reversed = try XCTUnwrap(CanonicalBusinessEngine.parseWeekendCoverage(
            ["saturday": ["enabled": true, "start": "14:00", "end": "07:30"]], includeWeekends: false
        ))
        XCTAssertEqual(reversed.saturday, OrgWeekendCoverageDay(enabled: true, start: nil, end: nil))
        XCTAssertEqual(reversed.sunday.enabled, false)
        // Default window: that day's set window, else the standard day.
        XCTAssertEqual(
            CanonicalBusinessEngine.resolveWeekendCoverageDay(coverage: nil, includeWeekends: true, policy: ownerPolicy(), weekday: .saturday),
            RulebookWeekendCoverageDay(enabled: true, start: "07:30", end: "14:00")
        )
        XCTAssertEqual(
            CanonicalBusinessEngine.resolveWeekendCoverageDay(coverage: nil, includeWeekends: true, policy: ownerPolicy(), weekday: .sunday),
            RulebookWeekendCoverageDay(enabled: true, start: "07:30", end: "16:00")
        )
        // Read from the stored map and written back whole as one field of the partial update.
        let detection = try XCTUnwrap(OrgWarningDetectionSettings(firestoreRaw: [
            "includeWeekendsForUnbookedLabour": true,
            "weekendCoverage": ["saturday": ["enabled": true, "start": "07:30", "end": "14:00"], "sunday": ["enabled": false]],
        ]))
        XCTAssertEqual(detection.weekendCoverage, saturdayOnly)
        var other = detection
        other.detectClashes = false
        let map = FirebaseBackend.warningDetectionFirestoreMap(other)
        let written = try XCTUnwrap(map["weekendCoverage"] as? [String: Any])
        XCTAssertEqual((written["saturday"] as? [String: Any])?["start"] as? String, "07:30")
        XCTAssertEqual((written["sunday"] as? [String: Any])?["enabled"] as? Bool, false, "another setting's save keeps the map")
    }
}
