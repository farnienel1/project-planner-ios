import XCTest
@testable import Project_Planner

@MainActor
final class WarningsLogicTests: XCTestCase {
    /// Releasing a main-actor store at the end of a test hits a Swift runtime crash in this host.
    private static var retained: [AnyObject] = []
    func testActiveAndExpiredQualificationCounts() {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let yesterday = calendar.date(byAdding: .day, value: -3, to: today)!
        let soon = calendar.date(byAdding: .day, value: 10, to: today)!
        let later = calendar.date(byAdding: .day, value: 40, to: today)!
        let activeId = UUID()
        let inactiveId = UUID()
        let expiredQualification = UUID()
        let soonQualification = UUID()
        let laterQualification = UUID()
        let inactiveQualification = UUID()

        let snapshot = WarningsComputationSnapshot(
            operatives: [
                .init(
                    id: activeId,
                    name: "Ada Lovelace",
                    emailLowercased: "ada@example.com",
                    isActive: true,
                    qualificationExpiries: [
                        .init(qualificationId: expiredQualification, qualificationName: "IPAF", expiryDate: yesterday),
                        .init(qualificationId: soonQualification, qualificationName: "CSCS", expiryDate: soon),
                        .init(qualificationId: laterQualification, qualificationName: "First aid", expiryDate: later),
                    ]
                ),
                .init(
                    id: inactiveId,
                    name: "Inactive",
                    emailLowercased: "old@example.com",
                    isActive: false,
                    qualificationExpiries: [
                        .init(qualificationId: inactiveQualification, qualificationName: "CSCS", expiryDate: yesterday),
                    ]
                ),
            ],
            bookings: [],
            projects: [],
            users: [],
            managerSiteBookings: [],
            holidayBookings: [],
            payrollTimePolicy: .init(
                standardPaidHours: 8,
                standardDayStart: "07:30",
                standardDayEnd: "16:00",
                breakWindowStart: "12:00",
                breakWindowEnd: "12:30",
                standardUnpaidBreakHours: 0.5,
                saturdayCountsAsHours: 8,
                sundayCountsAsHours: 8
            ),
            warningDetection: .init(
                detectClashes: true,
                includeWeekendsForUnbookedLabour: false,
                excludedUserIdsFromUnbookedWarnings: []
            ),
            coverageStart: today,
            coverageEnd: today,
            materialOrderCutOffEnabled: false,
            materialCutOffOnSaturday: false,
            materialCutOffOnSunday: false,
            projectsWithTomorrowBookingIds: [],
            materialItemsForTomorrow: []
        )

        let warnings = WarningsComputation.generate(snapshot)
        let expired = warnings.filter { $0.title == "Qualification expired" }
        let active = warnings.filter { $0.title == "Qualification expiry" }
        XCTAssertEqual(expired.count, 1)
        XCTAssertEqual(active.count, 1)
        XCTAssertTrue(expired[0].message.contains("IPAF"))
        XCTAssertTrue(active[0].message.contains("CSCS"))
        XCTAssertFalse(warnings.contains { $0.message.contains("First aid") })
        XCTAssertFalse(warnings.contains { $0.message.contains("Inactive") })
    }

    func testDismissedWarningsAreNotActive() {
        let suite = "ProjectPlannerTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = WarningResolutionStore(defaults: defaults)
        Self.retained.append(store)
        store.adoptOrganization("unit-test-org")
        XCTAssertTrue(store.shouldShowActive("qual-soon"))
        XCTAssertTrue(store.shouldShowActive("qual-expired"))
        store.dismiss("qual-expired")
        store.approve("clash-1")
        XCTAssertFalse(store.shouldShowActive("qual-expired"))
        XCTAssertFalse(store.shouldShowActive("clash-1"))
        XCTAssertTrue(store.shouldShowActive("qual-soon"))
        let visible = ["qual-soon", "qual-expired", "clash-1"].filter { store.shouldShowActive($0) }
        XCTAssertEqual(visible, ["qual-soon"])
    }
}
