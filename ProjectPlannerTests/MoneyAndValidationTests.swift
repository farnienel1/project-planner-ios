import XCTest
@testable import Project_Planner

@MainActor
final class MoneyAndValidationTests: XCTestCase {
    func testDayRateAndHourlyAmountsLandOnPennies() {
        let day = ResolvedPayrollRate(basis: .dayRate, dayRate: 200, hourlyRate: nil)
        XCTAssertClose(day.payForHours(8, standardDayHours: 8), 200)
        XCTAssertClose(day.payForHours(4, standardDayHours: 8), 100)

        let hourly = ResolvedPayrollRate(basis: .hourly, dayRate: nil, hourlyRate: 12.5)
        XCTAssertClose(hourly.payForHours(8, standardDayHours: 8), 100)
        XCTAssertClose(hourly.payForHours(1.5, standardDayHours: 8), 18.75)
    }

    func testSignedTimesheetTotalDropsDeclinesAndUsesEdits() {
        let day = LogicFixtures.day(2026, 10, 5)
        let labour = TimesheetPayrollLineItem(
            id: "op-day-normal",
            date: day,
            jobNumber: "100",
            projectName: "Site",
            details: "Full day",
            paidHours: 8,
            payrollBasis: .dayRate,
            dayRate: 100,
            hourlyRate: nil,
            amount: 100,
            isPayeDay: false,
            isOvertimeLine: false
        )
        let draft = TimesheetDraft(
            expenseEntries: [
                TimesheetExpenseEntry(
                    id: UUID(),
                    title: "Fuel",
                    details: "",
                    jobNumber: "100",
                    date: day,
                    amount: 10.10,
                    managerDecision: .approved
                ),
                TimesheetExpenseEntry(
                    id: UUID(),
                    title: "Parking",
                    details: "",
                    jobNumber: "100",
                    date: day,
                    amount: 4.50,
                    managerDecision: .declined
                ),
            ],
            priceWorkEntries: [
                TimesheetPriceWorkEntry(
                    id: UUID(),
                    title: "Extra sockets",
                    details: "",
                    jobNumber: "100",
                    agreedManagerName: "Manager",
                    startDate: day,
                    amount: 20,
                    managerDecision: .edited,
                    managerRevisedAmount: 15.25
                ),
            ]
        )
        let signed = TimesheetDraftAdjustments.grandTotal(
            lines: [labour],
            draft: draft,
            managerHasSigned: true
        )
        XCTAssertClose(signed, 125.35, "100 + 10.10 + 15.25; declined parking is omitted")
        let unsigned = TimesheetDraftAdjustments.grandTotal(
            lines: [labour],
            draft: draft,
            managerHasSigned: false
        )
        XCTAssertClose(unsigned, 134.60)
    }

    func testInvoiceTotalDoesNotAddVAT() {
        let labour = TimesheetPayrollLineItem(
            id: "op-day-normal",
            date: LogicFixtures.day(2026, 10, 5),
            jobNumber: "100",
            projectName: "Site",
            details: "Full day",
            paidHours: 8,
            payrollBasis: .dayRate,
            dayRate: 100,
            hourlyRate: nil,
            amount: 100,
            isPayeDay: false,
            isOvertimeLine: false
        )
        let total = TimesheetDraftAdjustments.grandTotal(
            lines: [labour],
            draft: TimesheetDraft(),
            managerHasSigned: true
        )
        XCTAssertClose(total, 100, "invoice totals are the net amount; 20% VAT is not added")
    }

    func testPayrollAmountsRoundToPennies() {
        let rate = ResolvedPayrollRate(basis: .dayRate, dayRate: 100, hourlyRate: nil)
        let raw = rate.payForHours(1.0 / 3.0, standardDayHours: 8)
        let pennies = (raw * 100).rounded() / 100
        XCTAssertClose(
            raw,
            pennies,
            accuracy: 0.000_000_1,
            "£100 day rate for 20 minutes (1/3 hour of an 8-hour day) should be stored in pennies"
        )
    }

    func testPaymentRunMustCoverTheMonthWithoutOverlap() {
        var settings = OrganizationInvoicingSettings.default
        settings.paymentRunMode = .dateRanges
        settings.paymentRunDateRanges = [
            PaymentRunDateRange(startDay: 1, endDay: 15),
            PaymentRunDateRange(startDay: 16, endDay: 31),
        ]
        XCTAssertNil(settings.fullMonthCoverageWarning())
        XCTAssertNil(settings.paymentRunRangesOverlapWarning())

        settings.paymentRunDateRanges = [
            PaymentRunDateRange(startDay: 1, endDay: 10),
            PaymentRunDateRange(startDay: 16, endDay: 31),
        ]
        XCTAssertNotNil(settings.fullMonthCoverageWarning())

        settings.paymentRunDateRanges = [
            PaymentRunDateRange(startDay: 1, endDay: 20),
            PaymentRunDateRange(startDay: 16, endDay: 31),
        ]
        XCTAssertNotNil(settings.paymentRunRangesOverlapWarning())
    }

    func testLeaveBookedBackwardsDoesNotConsumeDays() {
        let calendar = LogicFixtures.utc
        let backwards = LogicFixtures.holiday(
            userId: "user-1",
            start: LogicFixtures.day(2026, 5, 10, calendar: calendar),
            end: LogicFixtures.day(2026, 5, 8, calendar: calendar)
        )
        let consumed = AnnualLeavePolicy.consumedDays(
            bookings: [backwards],
            userId: "user-1",
            operativeId: nil,
            statuses: [.approved],
            rangeStart: LogicFixtures.day(2026, 1, 1, calendar: calendar),
            rangeEnd: LogicFixtures.day(2026, 12, 31, calendar: calendar),
            calendar: calendar
        )
        XCTAssertClose(consumed, 0)
    }

    func testFifteenMinutesTimesHourlyRateIsExactPennies() {
        let hourly = ResolvedPayrollRate(basis: .hourly, dayRate: nil, hourlyRate: 20)
        XCTAssertClose(hourly.payForHours(0.25, standardDayHours: 8), 5)
        XCTAssertClose(hourly.payForHours(7.25, standardDayHours: 8), 145)
    }

    func testHourlyAndDayRatePeopleInOneOrgAddUp() {
        let hourly = ResolvedPayrollRate(basis: .hourly, dayRate: nil, hourlyRate: 18)
        let day = ResolvedPayrollRate(basis: .dayRate, dayRate: 200, hourlyRate: nil)
        let hourlyPay = hourly.payForHours(7.25, standardDayHours: 8)
        let dayPay = day.payForHours(8, standardDayHours: 8)
        XCTAssertClose(hourlyPay, 130.50)
        XCTAssertClose(dayPay, 200)
        XCTAssertClose(hourlyPay + dayPay, 330.50)
    }

    func testSwitchingToHourlyDoesNotRepriceEarlierDayRateDays() {
        let calendar = LogicFixtures.utc
        let userId = "user-hourly-switch"
        let earlier = OperativeDayRateHistoryEntry(
            id: UUID(),
            userId: userId,
            operativeId: nil,
            dayRate: 200,
            effectiveAt: LogicFixtures.day(2026, 1, 1, calendar: calendar),
            createdAt: LogicFixtures.day(2026, 1, 1, calendar: calendar),
            payBasis: .dayRate
        )
        let switched = OperativeDayRateHistoryEntry(
            id: UUID(),
            userId: userId,
            operativeId: nil,
            dayRate: 25,
            effectiveAt: LogicFixtures.day(2026, 10, 6, calendar: calendar),
            createdAt: LogicFixtures.day(2026, 10, 6, calendar: calendar),
            payBasis: .hourly
        )
        let history = OperativeDayRateHistoryCollection(
            byUserId: [userId: [earlier, switched]],
            byOperativeId: [:]
        )
        var user = LogicFixtures.selfEmployedUser(id: userId, dayRate: 200)
        user.dayRate = nil
        user.hourlyRate = 25
        let monday = PayrollRateResolver.resolve(
            user: user,
            operative: nil,
            on: LogicFixtures.day(2026, 10, 5, calendar: calendar),
            history: history,
            standardDayHours: 8
        )
        let tuesday = PayrollRateResolver.resolve(
            user: user,
            operative: nil,
            on: LogicFixtures.day(2026, 10, 6, calendar: calendar),
            history: history,
            standardDayHours: 8
        )
        XCTAssertEqual(monday.basis, .dayRate)
        XCTAssertClose(monday.payForHours(8, standardDayHours: 8), 200)
        XCTAssertEqual(tuesday.basis, .hourly)
        XCTAssertClose(tuesday.payForHours(7.25, standardDayHours: 8), 181.25)
        XCTAssertNil(monday.hourlyRate)
        XCTAssertNil(tuesday.dayRate)
    }

    func testSameDayOperativeDayHistoryDoesNotHideHourlyProfile() {
        let calendar = LogicFixtures.utc
        let authId = "auth-manager"
        let inviteId = "invite-manager"
        let operativeId = UUID()
        let dayRateHistory = OperativeDayRateHistoryEntry(
            id: UUID(),
            userId: authId,
            operativeId: operativeId,
            dayRate: 100,
            effectiveAt: LogicFixtures.day(2026, 1, 1, calendar: calendar),
            createdAt: LogicFixtures.day(2026, 1, 1, calendar: calendar),
            payBasis: .dayRate
        )
        let hourlyHistory = OperativeDayRateHistoryEntry(
            id: UUID(),
            userId: inviteId,
            operativeId: nil,
            dayRate: 20,
            effectiveAt: LogicFixtures.day(2026, 10, 6, hour: 0, calendar: calendar),
            createdAt: LogicFixtures.day(2026, 10, 6, hour: 0, calendar: calendar),
            payBasis: .hourly
        )
        let echoedDay = OperativeDayRateHistoryEntry(
            id: UUID(),
            userId: authId,
            operativeId: operativeId,
            dayRate: 100,
            effectiveAt: LogicFixtures.day(2026, 10, 6, hour: 15, calendar: calendar),
            createdAt: LogicFixtures.day(2026, 10, 6, hour: 15, calendar: calendar),
            payBasis: .dayRate
        )
        let history = OperativeDayRateHistoryCollection(
            byUserId: [authId: [dayRateHistory, echoedDay], inviteId: [hourlyHistory]],
            byOperativeId: [operativeId.uuidString: [dayRateHistory, echoedDay]]
        )
        var bookingUser = LogicFixtures.selfEmployedUser(id: authId, dayRate: 100)
        bookingUser.dayRate = 100
        bookingUser.hourlyRate = nil
        let monday = PayrollRateResolver.resolve(
            user: bookingUser,
            operative: nil,
            on: LogicFixtures.day(2026, 10, 5, calendar: calendar),
            history: history,
            standardDayHours: 8,
            userIds: [authId, inviteId],
            livePrefersHourly: true,
            preferredHourlyRate: 20
        )
        let tuesday = PayrollRateResolver.resolve(
            user: bookingUser,
            operative: nil,
            on: LogicFixtures.day(2026, 10, 6, calendar: calendar),
            history: history,
            standardDayHours: 8,
            userIds: [authId, inviteId],
            livePrefersHourly: true,
            preferredHourlyRate: 20
        )
        XCTAssertEqual(monday.basis, .dayRate)
        XCTAssertClose(monday.payForHours(8, standardDayHours: 8), 100)
        XCTAssertEqual(tuesday.basis, .hourly)
        XCTAssertClose(tuesday.payForHours(8, standardDayHours: 8), 160)
        let line = PayrollPayLineFormatter.line(
            basis: tuesday.basis,
            paidHours: 8,
            standardDayHours: 8,
            rate: tuesday.hourlyRate,
            pay: tuesday.payForHours(8, standardDayHours: 8)
        )
        XCTAssertEqual(line.equationText, "8.00 hours × £20.00/hr = £160.00")
    }

    func testLegacyDuplicateRatesStayOnDayRateAndZeroBlankBecomesHourly() {
        let both = PayrollRateCodec.exclusive(dayRate: 250, hourlyRate: 250, payBasis: nil, treatZeroAsUnset: true)
        XCTAssertEqual(both.basis, .dayRate)
        XCTAssertEqual(both.dayRate, 250)
        XCTAssertNil(both.hourlyRate)

        let hourlyOnly = PayrollRateCodec.exclusive(dayRate: 0, hourlyRate: 18.5, payBasis: nil, treatZeroAsUnset: true)
        XCTAssertEqual(hourlyOnly.basis, .hourly)
        XCTAssertEqual(hourlyOnly.hourlyRate, 18.5)
        XCTAssertNil(hourlyOnly.dayRate)
    }

    func testHourlyPayLineIsHoursTimesRateNotADayCount() {
        let line = PayrollPayLineFormatter.line(
            basis: .hourly,
            paidHours: 24,
            standardDayHours: 8,
            rate: 20,
            pay: 480
        )
        XCTAssertEqual(line.rateTypeLabel, "Hourly")
        XCTAssertEqual(line.quantityText, "24.00 hours")
        XCTAssertEqual(line.rateText, "£20.00/hr")
        XCTAssertEqual(line.equationText, "24.00 hours × £20.00/hr = £480.00")
    }

    func testQuarterHourDisplaysAsQuarterNotARoundedHalf() {
        let line = PayrollPayLineFormatter.line(
            basis: .hourly,
            paidHours: 0.25,
            standardDayHours: 8,
            rate: 20,
            pay: 5
        )
        XCTAssertEqual(line.quantityText, "0.25 hours")
        XCTAssertEqual(line.equationText, "0.25 hours × £20.00/hr = £5.00")
    }

    func testDayAndHourlyUseOrgDayLengthNotAForcedEight() {
        XCTAssertEqual(PayrollPayLineFormatter.orgDayHours(7.5), 7.5)

        let day = ResolvedPayrollRate(basis: .dayRate, dayRate: 150, hourlyRate: nil)
        XCTAssertClose(day.payForHours(7.5, standardDayHours: 7.5), 150)
        let dayLine = PayrollPayLineFormatter.line(
            basis: .dayRate,
            paidHours: 7.5,
            standardDayHours: 7.5,
            rate: 150,
            pay: 150
        )
        XCTAssertEqual(dayLine.rateTypeLabel, "Day")
        XCTAssertEqual(dayLine.quantityText, "1.00 day")
        XCTAssertEqual(dayLine.rateText, "£150.00/day")
        XCTAssertEqual(dayLine.equationText, "1.00 day × £150.00/day = £150.00")

        let half = PayrollPayLineFormatter.line(
            basis: .dayRate,
            paidHours: 3.75,
            standardDayHours: 7.5,
            rate: 150,
            pay: 75
        )
        XCTAssertEqual(half.quantityText, "0.50 days")

        let hourly = ResolvedPayrollRate(basis: .hourly, dayRate: nil, hourlyRate: 20)
        XCTAssertClose(hourly.payForHours(7.5, standardDayHours: 7.5), 150)
        let hourlyLine = PayrollPayLineFormatter.line(
            basis: .hourly,
            paidHours: 7.5,
            standardDayHours: 7.5,
            rate: 20,
            pay: 150
        )
        XCTAssertEqual(hourlyLine.quantityText, "7.50 hours")
        XCTAssertEqual(hourlyLine.equationText, "7.50 hours × £20.00/hr = £150.00")
    }

    func testSignedHourlyManagerSheetReachesLineManagerAndInvoicesHoursTimesRate() {
        let email = "farnie@raccordmep.co.uk"
        let roster = TimesheetSignOffQueue.Person(
            id: "invite-manager",
            email: email,
            lineManagerUserIds: [],
            hasNoLineManager: false,
            includedInQueue: true,
            isActive: true
        )
        let signedIn = TimesheetSignOffQueue.Person(
            id: "auth-manager",
            email: email,
            lineManagerUserIds: ["test-admin"],
            hasNoLineManager: false,
            includedInQueue: true,
            isActive: true
        )
        let documents = [roster, signedIn]
        let sheet = TimesheetSignOffQueue.Sheet(
            userId: signedIn.id,
            operativeSigned: true,
            managerSigned: false,
            exported: false
        )
        XCTAssertTrue(TimesheetSignOffQueue.shouldQueueForLineManager(
            rosterUserId: roster.id,
            viewerUserId: "test-admin",
            documents: documents,
            sheets: [sheet]
        ))
        XCTAssertFalse(TimesheetSignOffQueue.shouldQueueForLineManager(
            rosterUserId: roster.id,
            viewerUserId: "someone-else",
            documents: documents,
            sheets: [sheet]
        ))
        XCTAssertFalse(TimesheetSignOffQueue.shouldQueueForLineManager(
            rosterUserId: roster.id,
            viewerUserId: "test-admin",
            documents: documents,
            sheets: [TimesheetSignOffQueue.Sheet(
                userId: signedIn.id,
                operativeSigned: true,
                managerSigned: true,
                exported: false
            )]
        ))

        let hourly = ResolvedPayrollRate(basis: .hourly, dayRate: nil, hourlyRate: 20)
        let labour = hourly.payForHours(8, standardDayHours: 8)
        XCTAssertEqual(labour, 160)
        let invoice = PayrollPayLineFormatter.line(
            basis: .hourly,
            paidHours: 8,
            standardDayHours: 8,
            rate: 20,
            pay: labour
        )
        XCTAssertEqual(invoice.rateTypeLabel, "Hourly")
        XCTAssertEqual(invoice.quantityText, "8.00 hours")
        XCTAssertEqual(invoice.rateText, "£20.00/hr")
        XCTAssertEqual(invoice.equationText, "8.00 hours × £20.00/hr = £160.00")

        let reportHourly = PayrollPayLineFormatter.line(
            basis: .hourly,
            paidHours: 24,
            standardDayHours: 8,
            rate: 20,
            pay: hourly.payForHours(24, standardDayHours: 8)
        )
        XCTAssertEqual(reportHourly.quantityText, "24.00 hours")
        XCTAssertEqual(reportHourly.rateText, "£20.00/hr")
        XCTAssertEqual(reportHourly.equationText, "24.00 hours × £20.00/hr = £480.00")

        let reportDay = PayrollPayLineFormatter.line(
            basis: .dayRate,
            paidHours: 24,
            standardDayHours: 8,
            rate: 250,
            pay: ResolvedPayrollRate(basis: .dayRate, dayRate: 250, hourlyRate: nil)
                .payForHours(24, standardDayHours: 8)
        )
        XCTAssertEqual(reportDay.rateTypeLabel, "Day")
        XCTAssertEqual(reportDay.quantityText, "3.00 days")
        XCTAssertEqual(reportDay.rateText, "£250.00/day")
        XCTAssertEqual(reportDay.equationText, "3.00 days × £250.00/day = £750.00")

        XCTAssertEqual(PayrollPayLineFormatter.orgDayHours(7.5), 7.5)
        let shorterDay = PayrollPayLineFormatter.line(
            basis: .hourly,
            paidHours: 7.5,
            standardDayHours: 7.5,
            rate: 20,
            pay: 150
        )
        XCTAssertEqual(shorterDay.quantityText, "7.50 hours")
    }

    func testCounterSignedHourlyTimesheetUnlocksInvoiceAtHoursTimesRate() {
        let email = "farnie@raccordmep.co.uk"
        let roster = TimesheetSignOffQueue.Person(
            id: "invite-manager",
            email: email,
            lineManagerUserIds: ["test-admin"],
            hasNoLineManager: false,
            includedInQueue: true,
            isActive: true
        )
        let signedIn = TimesheetSignOffQueue.Person(
            id: "rWoccK8LDZVJjBj3UCbqay8bPyf2",
            email: email,
            lineManagerUserIds: ["test-admin"],
            hasNoLineManager: false,
            includedInQueue: true,
            isActive: true
        )
        let operativeOnly = TimesheetSignOffQueue.Sheet(
            userId: roster.id,
            operativeSigned: true,
            managerSigned: false,
            exported: false
        )
        let counterSigned = TimesheetSignOffQueue.Sheet(
            userId: signedIn.id,
            operativeSigned: true,
            managerSigned: true,
            exported: false
        )
        XCTAssertFalse(TimesheetSignOffQueue.allowsInvoice(
            ownerUserId: roster.id,
            documents: [roster, signedIn],
            sheets: [operativeOnly]
        ))
        XCTAssertTrue(TimesheetSignOffQueue.allowsInvoice(
            ownerUserId: roster.id,
            documents: [roster, signedIn],
            sheets: [operativeOnly, counterSigned]
        ))
        XCTAssertEqual(
            TimesheetSignOffQueue.invoiceSourceUserId(
                ownerUserId: roster.id,
                siblingIds: [roster.id, signedIn.id],
                sheets: [operativeOnly, counterSigned]
            ),
            signedIn.id
        )
        var staleDraft = TimesheetDraft()
        staleDraft.operativeSignedAt = Date()
        staleDraft.operativeSignedByName = "Test Manager"
        var counterSignedDraft = staleDraft
        counterSignedDraft.managerSignedAt = Date()
        counterSignedDraft.managerSignedByName = "Test Admin"
        let chosen = TimesheetApprovalPolicy.preferringCounterSign(staleDraft, counterSignedDraft)
        XCTAssertEqual(chosen.managerSignedByName, "Test Admin")
        XCTAssertGreaterThan(
            TimesheetApprovalPolicy.approvalRank(of: chosen),
            TimesheetApprovalPolicy.approvalRank(of: staleDraft)
        )

        let hourly = ResolvedPayrollRate(basis: .hourly, dayRate: nil, hourlyRate: 20)
        let pay = hourly.payForHours(8, standardDayHours: 8)
        XCTAssertEqual(pay, 160)
        let line = PayrollPayLineFormatter.line(
            basis: .hourly,
            paidHours: 8,
            standardDayHours: 8,
            rate: 20,
            pay: pay
        )
        XCTAssertEqual(line.equationText, "8.00 hours × £20.00/hr = £160.00")
    }
}
