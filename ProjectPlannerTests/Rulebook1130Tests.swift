import XCTest
@testable import Project_Planner

/// RULEBOOK 1.12.2 / 1.13.0–1.13.2 behaviour on iOS through `CanonicalBusinessEngine`. Every expected value was
/// checked in node against the packed `canonical-business.js` (sha256 76ddcbc1…cfc).
@MainActor
final class Rulebook1130Tests: XCTestCase {
    // MARK: Half-applied user type (1.12.2 §11)

    private func managerSubject(id: String = "U1", organizationId: String = "ORG-A") -> [String: Any] {
        let flags: [String: Bool] = ["adminAccess": false, "manager": true, "operativeMode": false]
        var row: [String: Any] = flags
        row["permissions"] = flags
        row["role"] = "manager"
        row["isSuperAdmin"] = false
        row["id"] = id
        row["organizationId"] = organizationId
        return row
    }

    func testAccountTypeSyncStateFindsAPartlySavedType() throws {
        let stale = try XCTUnwrap(CanonicalBusinessEngine.accountTypeSyncState(
            person: managerSubject(), organizationId: "org-a", members: ["u1": "admin"]
        ))
        XCTAssertFalse(stale.inSync)
        XCTAssertEqual(stale.level, .manager)
        XCTAssertEqual(stale.membersRole, "admin")
        XCTAssertEqual(stale.repair, .manager)

        let same = try XCTUnwrap(CanonicalBusinessEngine.accountTypeSyncState(
            person: managerSubject(), organizationId: "org-a", members: ["U1": "manager"]
        ))
        XCTAssertTrue(same.inSync)
        XCTAssertNil(same.repair)

        let missing = try XCTUnwrap(CanonicalBusinessEngine.accountTypeSyncState(
            person: managerSubject(), organizationId: "org-a", members: [:]
        ))
        XCTAssertTrue(missing.inSync, "no members entry is not an admin mismatch")
        XCTAssertEqual(
            CanonicalBusinessEngine.accountTypeOutOfSyncMessage,
            "This person's user type was only partly saved. Press Save to finish it on every record."
        )
    }

    // MARK: Weekend bookings (1.13.1 §4.3) and the lunch warning (1.13.0 §8)

    private func day(_ key: String) throws -> Date {
        try XCTUnwrap(OrganizationRulebookContext.date(fromDayKey: key))
    }

    func testWeekendDaysOfferCustomHoursOnly() throws {
        // RULEBOOK 1.20.0 §4.3: Monday–Friday offers Full day and Custom only (`WEEKDAY_TIME_SLOTS`).
        XCTAssertEqual(CanonicalBusinessEngine.allowedTimeSlotsOnDay("2026-11-04", timeZone: "Europe/London"), [.fullDay, .custom])
        XCTAssertEqual(CanonicalBusinessEngine.allowedTimeSlotsOnDay("2026-11-07", timeZone: "Europe/London"), [.custom])
        XCTAssertEqual(CanonicalBusinessEngine.allowedTimeSlotsOnDay("2026-11-08", timeZone: "Europe/London"), [.custom])
        XCTAssertFalse(CanonicalBusinessEngine.timeSlotAllowedOnDay("FULL DAY", dayKey: "2026-11-07", timeZone: "Europe/London"))
        XCTAssertTrue(CanonicalBusinessEngine.timeSlotAllowedOnDay("CUSTOM_HOURS", dayKey: "2026-11-07", timeZone: "Europe/London"))
        XCTAssertFalse(CanonicalBusinessEngine.timeSlotAllowedOnDay("AM", dayKey: "2026-11-04", timeZone: "Europe/London"))
        XCTAssertTrue(CanonicalBusinessEngine.timeSlotAllowedOnDay("FULL DAY", dayKey: "2026-11-04", timeZone: "Europe/London"))
        // A stored weekend FULL DAY still shows its own slot when edited.
        let saturday = try day("2026-11-07")
        XCTAssertTrue(CanonicalBusinessEngine.slotOffered(.fullDay, on: saturday, storedTimeSlot: "FULL DAY"))
        XCTAssertFalse(CanonicalBusinessEngine.slotOffered(.am, on: saturday, storedTimeSlot: "FULL DAY"))
        XCTAssertEqual(TimeSlot.defaultPickerSlot(on: saturday), .customHours)
        XCTAssertEqual(TimeSlot.defaultPickerSlot(on: try day("2026-11-04")), .fullDay)
        XCTAssertEqual(ManagerTimeSlot.offered(on: [saturday]), [.customHours])
    }

    func testWeekendPrefillAndNoteComeFromTheRulebook() throws {
        let policy = OrgPayrollTimePolicy.default
        let saturdayWindow = try XCTUnwrap(CanonicalBusinessEngine.weekendCustomHoursDefault(policy: policy, dayKey: "2026-11-07", timeZone: "Europe/London"))
        XCTAssertEqual(saturdayWindow.start, "07:30")
        XCTAssertEqual(saturdayWindow.end, "13:00")
        XCTAssertNil(CanonicalBusinessEngine.weekendCustomHoursDefault(policy: policy, dayKey: "2026-11-08", timeZone: "Europe/London"), "all-hours Sunday")
        XCTAssertNil(CanonicalBusinessEngine.weekendCustomHoursDefault(policy: policy, dayKey: "2026-11-04", timeZone: "Europe/London"))
        XCTAssertEqual(
            CanonicalBusinessEngine.weekendBookingNote(policy: policy, dayKey: "2026-11-07", timeZone: "Europe/London"),
            "Saturday is paid on the hours you enter: 07:30\u{2013}13:00 counts as 8h, hours outside it at 2×. Change it in Working hours."
        )
        XCTAssertEqual(
            CanonicalBusinessEngine.weekendBookingNote(policy: policy, dayKey: "2026-11-08", timeZone: "Europe/London"),
            "Sunday is paid on the hours you enter, every hour at 2×. Change it in Working hours."
        )
        XCTAssertNil(CanonicalBusinessEngine.weekendBookingNote(policy: policy, dayKey: "2026-11-04", timeZone: "Europe/London"))
    }

    func testOneRequestNeverMixesWeekdaysAndWeekendDays() throws {
        XCTAssertTrue(CanonicalBusinessEngine.bookingDaysMixWeekdayAndWeekend(["2026-11-06", "2026-11-07"], timeZone: "Europe/London"))
        XCTAssertFalse(CanonicalBusinessEngine.bookingDaysMixWeekdayAndWeekend(["2026-11-07", "2026-11-08"], timeZone: "Europe/London"))
        XCTAssertFalse(CanonicalBusinessEngine.bookingDaysMixWeekdayAndWeekend(["2026-11-04", "2026-11-05"], timeZone: "Europe/London"))
        XCTAssertEqual(
            CanonicalBusinessEngine.weekendWeekdayMixMessage,
            "Weekends cannot be booked alongside Weekdays. Make your weekday booking first then weekend separately."
        )
        var selected: Set<Date> = [try day("2026-11-06")]
        let message = ScheduleDateSelectionPolicy.toggle(
            date: try day("2026-11-07"),
            selected: &selected,
            policy: .default,
            calendar: OrganizationRulebookContext.calendar
        )
        XCTAssertEqual(message, CanonicalBusinessEngine.weekendWeekdayMixMessage)
        XCTAssertEqual(selected.count, 1)
    }

    func testCustomHoursOverTheUnpaidBreakAskForConfirmation() {
        let policy = OrgPayrollTimePolicy.default
        let warning = "You are booking custom hours that cover the unpaid lunch break. Turn off Unpaid break to make sure they are paid for this time."
        XCTAssertEqual(CanonicalBusinessEngine.customHoursBreakWarning(
            policy: policy, dayKey: "2026-11-04", workStartTime: "08:00", workEndTime: "16:00", isBreakRemoved: false, timeZone: "Europe/London"
        ), warning)
        XCTAssertNil(CanonicalBusinessEngine.customHoursBreakWarning(
            policy: policy, dayKey: "2026-11-04", workStartTime: "08:00", workEndTime: "16:00", isBreakRemoved: true, timeZone: "Europe/London"
        ), "Unpaid break off")
        XCTAssertNil(CanonicalBusinessEngine.customHoursBreakWarning(
            policy: policy, dayKey: "2026-11-04", workStartTime: "08:00", workEndTime: "11:00", isBreakRemoved: false, timeZone: "Europe/London"
        ), "does not reach the break")
        XCTAssertNil(CanonicalBusinessEngine.customHoursBreakWarning(
            policy: policy, dayKey: "2026-11-07", workStartTime: "08:00", workEndTime: "16:00", isBreakRemoved: false, timeZone: "Europe/London"
        ), "weekend")
        var paidBreak = policy
        paidBreak.breakPaid = true
        XCTAssertNil(CanonicalBusinessEngine.customHoursBreakWarning(
            policy: paidBreak, dayKey: "2026-11-04", workStartTime: "08:00", workEndTime: "16:00", isBreakRemoved: false, timeZone: "Europe/London"
        ), "paid break")
    }

    func testAnOvernightBookingKeepsItsClockTimes() {
        // RULEBOOK 1.13.0 Q5: a finish before the start crosses midnight (`slotInterval` runs past 24:00).
        let interval = CanonicalBusinessEngine.slotInterval(
            timeSlot: "CUSTOM_HOURS",
            workStartTime: "22:00",
            workEndTime: "06:00",
            day: CanonicalStandardDayInput(policy: .default)
        )
        XCTAssertEqual(interval?.start, 22 * 60)
        XCTAssertEqual(interval?.end, 30 * 60)
    }

    // MARK: Pay privacy (1.13.0 Q1)

    func testPayProfileWritesCarryOnlyThePayFields() throws {
        XCTAssertEqual(CanonicalBusinessEngine.payProfilePath(organizationId: "org-1", subjectId: "u-1"), "organizations/org-1/payProfiles/u-1")
        XCTAssertNil(CanonicalBusinessEngine.payProfilePath(organizationId: " ", subjectId: "u-1"))
        let fields = try XCTUnwrap(CanonicalBusinessEngine.payProfileWriteFields(
            subjectId: "u-1",
            profileWrite: ["firstName": "Ann", "dayRate": 250.0, "payBasis": "day", "updatedAt": "stamp"]
        ))
        XCTAssertEqual(Set(fields.keys), ["userId", "dayRate", "payBasis"])
        XCTAssertEqual(fields["userId"] as? String, "u-1")
        XCTAssertEqual(fields["dayRate"] as? Double, 250)
        XCTAssertNil(CanonicalBusinessEngine.payProfileWriteFields(subjectId: "u-1", profileWrite: ["firstName": "Ann"]))
        XCTAssertEqual(CanonicalBusinessEngine.payProfileFields?.count, 6)
    }

    func testPayIsReadPayProfileFirst() throws {
        let person: [String: Any] = ["payBasis": "hourly", "dayRate": NSNull(), "hourlyRate": 20, "employmentType": "self_employed"]
        let row = try XCTUnwrap(CanonicalBusinessEngine.overlayPayProfile(
            person: person, profileId: "u-1", profile: ["dayRate": 250, "payBasis": "day", "userId": "u-1"]
        ))
        XCTAssertEqual(row["payBasis"] as? String, "day")
        XCTAssertEqual((row["dayRate"] as? NSNumber)?.doubleValue, 250)
        XCTAssertEqual((row["hourlyRate"] as? NSNumber)?.doubleValue, 20, "a field the pay profile lacks stays as stored")
        let untouched = try XCTUnwrap(CanonicalBusinessEngine.overlayPayProfile(person: person, profileId: "u-1", profile: nil))
        XCTAssertEqual(untouched["payBasis"] as? String, "hourly")
    }

    func testCanViewPersonPayFollowsTheRulebook() {
        let op: [String: Any] = ["id": "op", "email": "op@x.com", "isActive": true, "role": "operative", "operativeMode": true,
                                 "permissions": ["operativeMode": true], "assignedManagerUserIds": ["lm"]]
        let lineManager: [String: Any] = ["id": "lm", "email": "lm@x.com", "isActive": true, "role": "manager", "manager": true,
                                          "permissions": ["manager": true]]
        let otherManager: [String: Any] = ["id": "m2", "email": "m2@x.com", "isActive": true, "role": "manager", "manager": true,
                                           "operatives": false, "permissions": ["manager": true, "operatives": false]]
        let operativesManager: [String: Any] = ["id": "m3", "email": "m3@x.com", "isActive": true, "role": "manager", "manager": true,
                                                "operatives": true, "permissions": ["manager": true, "operatives": true]]
        let admin: [String: Any] = ["id": "a", "email": "a@x.com", "isActive": true, "role": "admin", "adminAccess": true,
                                    "permissions": ["adminAccess": true]]
        let roster = [op, lineManager, otherManager, operativesManager, admin]
        XCTAssertTrue(CanonicalBusinessEngine.canViewPersonPay(viewer: op, subject: op, roster: roster, context: .profile))
        // RULEBOOK 1.32.0 §8 (owner decisions 5 Nov): a plain line manager sees a report's pay only on the timesheets
        // they review, never on the profile.
        XCTAssertFalse(CanonicalBusinessEngine.canViewPersonPay(viewer: lineManager, subject: op, roster: roster, context: .profile))
        XCTAssertTrue(CanonicalBusinessEngine.canViewPersonPay(viewer: lineManager, subject: op, roster: roster, context: .timesheetReview))
        XCTAssertFalse(CanonicalBusinessEngine.canViewPersonPay(viewer: otherManager, subject: op, roster: roster, context: .profile))
        XCTAssertTrue(CanonicalBusinessEngine.canViewPersonPay(viewer: operativesManager, subject: op, roster: roster, context: .profile))
        XCTAssertTrue(CanonicalBusinessEngine.canViewPersonPay(viewer: admin, subject: op, roster: roster, context: .profile))
        XCTAssertFalse(CanonicalBusinessEngine.canViewPersonPay(viewer: operativesManager, subject: lineManager, roster: roster, context: .profile))
    }

    // MARK: Carry-over and pro rata (1.13.0 Q4 §4.4)

    func testMaxCarryOverDaysParsesLikeWeb() {
        XCTAssertEqual(CanonicalBusinessEngine.parseMaxCarryOverDays("5"), 5)
        XCTAssertEqual(CanonicalBusinessEngine.parseMaxCarryOverDays("2.3"), 2.5)
        XCTAssertNil(CanonicalBusinessEngine.parseMaxCarryOverDays("-1"))
        XCTAssertNil(CanonicalBusinessEngine.parseMaxCarryOverDays(""))
        XCTAssertNil(CanonicalBusinessEngine.parseMaxCarryOverDays("x"))
        XCTAssertNil(CanonicalBusinessEngine.parseMaxCarryOverDays(nil))
        XCTAssertEqual(CanonicalBusinessEngine.parseMaxCarryOverDays(NSNumber(value: 400)), 365)
        XCTAssertEqual(CanonicalBusinessEngine.suggestedMaxCarryOverDays, 5)
        let defaults = OrganizationAnnualLeaveDefaults(daysPerYear: 25, startMonth: 1, endMonth: 12, carriesOver: true)
        XCTAssertTrue(defaults.firestoreMap["maxCarryOverDays"] is NSNull, "no cap is written as null, never dropped")
    }

    private func balance(start: String?, cap: Double?) throws -> (balance: CanonicalBusinessEngine.CanonicalAnnualLeaveBalance, yearEntitlement: Double, proRata: Bool) {
        try XCTUnwrap(CanonicalBusinessEngine.annualLeaveBalanceDetail(
            annualLeaveEnabled: true, daysPerYear: 20, startMonth: 1, endMonth: 12,
            orgDaysPerYear: nil, orgStartMonth: nil, orgEndMonth: nil, carriesOver: true,
            yearAllowance: nil, yearAllowanceKey: nil, bookings: [], onDayKey: "2026-11-03",
            nonWorkingDayKeys: [], employmentStartDayKey: start, maxCarryOverDays: cap, timeZone: "Europe/London"
        ))
    }

    func testTheLeaveYearJoinedIsProRataAndCarryOverIsCapped() throws {
        let joined = try balance(start: "2026-07-01", cap: nil)
        XCTAssertEqual(joined.yearEntitlement, 10.5)
        XCTAssertTrue(joined.proRata)
        XCTAssertEqual(joined.balance.carriedForward, 0)
        XCTAssertEqual(joined.balance.remaining, 10.5)
        let capped = try balance(start: nil, cap: 5)
        XCTAssertEqual(capped.yearEntitlement, 20)
        XCTAssertFalse(capped.proRata)
        XCTAssertEqual(capped.balance.carriedForward, 5)
        XCTAssertEqual(capped.balance.remaining, 25)
        let uncapped = try balance(start: nil, cap: nil)
        XCTAssertEqual(uncapped.balance.carriedForward, 20)
        XCTAssertEqual(uncapped.balance.remaining, 40)
    }

    func testLeaveYearStartMonthIsTheCanonicalFunction() {
        XCTAssertEqual(CanonicalBusinessEngine.leaveYearStartMonth(endingIn: 12), 1)
        XCTAssertEqual(CanonicalBusinessEngine.leaveYearStartMonth(endingIn: 3), 4)
        XCTAssertEqual(CanonicalBusinessEngine.leaveYearStartMonth(endingIn: 1), 2)
    }

    // MARK: Launch countries (1.13.0 Q6 §4.1)

    func testCompanyCountryPickerOffersLaunchCountriesAndKeepsAStoredOne() {
        XCTAssertEqual(CanonicalBusinessEngine.launchCountryOptions(storedCountryCode: "GB")?.map(\.code), ["GB", "IE"])
        XCTAssertEqual(CanonicalBusinessEngine.launchCountryOptions(storedCountryCode: nil)?.map(\.code), ["GB", "IE"])
        XCTAssertEqual(CanonicalBusinessEngine.launchCountryOptions(storedCountryCode: "FR")?.map(\.code), ["GB", "IE", "FR"])
        XCTAssertEqual(CanonicalBusinessEngine.launchCountryOptions(storedCountryCode: "GB")?.first?.title, "United Kingdom")
    }

    // MARK: Self email change (1.13.0 §14)

    func testSelfEmailChangeUsesTheRulebook() throws {
        XCTAssertEqual(CanonicalBusinessEngine.selfEmailChangeAction(storedEmail: "a@x.com", nextEmail: " A@x.com "), .unchanged)
        XCTAssertEqual(CanonicalBusinessEngine.selfEmailChangeAction(storedEmail: "a@x.com", nextEmail: "bad"), .invalid)
        XCTAssertEqual(CanonicalBusinessEngine.selfEmailChangeAction(storedEmail: "a@x.com", nextEmail: "b@x.com"), .verifyBeforeUpdate)
        XCTAssertEqual(
            CanonicalBusinessEngine.selfEmailChangeSentMessage("B@x.com"),
            "We sent a link to b@x.com. Open it to confirm, then sign in with b@x.com. Until then you sign in with your current email."
        )
        let plan = try XCTUnwrap(CanonicalBusinessEngine.signInEmailSyncWrites(
            userId: "u1", organizationId: "org", tokenEmail: "b@x.com", tokenEmailVerified: true, storedEmail: "a@x.com"
        ))
        XCTAssertEqual(plan.email, "b@x.com")
        XCTAssertEqual(plan.claimSetPath, "organizations/org/userEmails/b@x.com")
        XCTAssertEqual(plan.claimSetUserId, "u1")
        XCTAssertEqual(plan.claimDeletePath, "organizations/org/userEmails/a@x.com")
        XCTAssertNil(CanonicalBusinessEngine.signInEmailSyncWrites(
            userId: "u1", organizationId: "org", tokenEmail: "b@x.com", tokenEmailVerified: false, storedEmail: "a@x.com"
        ))
    }
}
