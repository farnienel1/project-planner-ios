import XCTest
@testable import Project_Planner

@MainActor
final class WarningsLogicTests: XCTestCase {
    /// Releasing a main-actor store at the end of a test hits a Swift runtime crash in this host.
    private static var retained: [AnyObject] = []
    func testWarningDetectionReadPrefersTopLevelAndFillsMissingDayCount() {
        let top: [String: Any] = [
            "clashLookaheadMode": "endOfInvoicingPeriod",
            "detectClashes": true,
            "includeWeekendsForUnbookedLabour": false,
            "excludedUserIdsFromUnbookedWarnings": ["a"],
        ]
        let nested: [String: Any] = [
            "clashLookaheadMode": "numberOfDays",
            "clashLookaheadDays": 4,
            "detectClashes": false,
            "includeWeekendsForUnbookedLabour": true,
            "excludedUserIdsFromUnbookedWarnings": ["b"],
        ]
        let resolved = OrgWarningDetectionSettings.resolved(topLevel: top, nested: nested)
        XCTAssertEqual(resolved.clashLookaheadMode, .endOfInvoicingPeriod)
        XCTAssertEqual(resolved.clashLookaheadDays, 4)
        XCTAssertEqual(resolved.detectClashes, true)
        XCTAssertEqual(resolved.includeWeekendsForUnbookedLabour, false)
        XCTAssertEqual(resolved.excludedUserIdsFromUnbookedWarnings, ["a"])

        let nestedOnly = OrgWarningDetectionSettings.resolved(topLevel: nil, nested: nested)
        XCTAssertEqual(nestedOnly.clashLookaheadMode, .numberOfDays)
        XCTAssertEqual(nestedOnly.clashLookaheadDays, 4)
        XCTAssertEqual(nestedOnly.detectClashes, false)
    }

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
            materialCutOffHour: 16,
            materialCutOffMinute: 0,
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

    func testMaterialsWarningUsesSavedCutoffAndSkipsOrderedLines() {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: today)!
        let projectId = UUID()
        var components = calendar.dateComponents([.year, .month, .day], from: today)
        components.hour = 15
        let beforeCutoff = calendar.date(from: components)!
        components.hour = 17
        let afterCutoff = calendar.date(from: components)!

        func snapshot(ordered: Bool) -> WarningsComputationSnapshot {
            WarningsComputationSnapshot(
                operatives: [],
                bookings: [],
                projects: [.init(id: projectId, jobNumber: "C1", siteName: "Site", isSmallWorks: false)],
                users: [],
                managerSiteBookings: [],
                holidayBookings: [],
                payrollTimePolicy: .init(
                    standardPaidHours: 8,
                    standardDayStart: "07:30",
                    standardDayEnd: "16:00",
                    standardUnpaidBreakHours: 0.5,
                    saturdayCountsAsHours: 0,
                    sundayCountsAsHours: 0
                ),
                warningDetection: .init(
                    detectClashes: true,
                    includeWeekendsForUnbookedLabour: false,
                    excludedUserIdsFromUnbookedWarnings: []
                ),
                coverageStart: today,
                coverageEnd: today,
                materialOrderCutOffEnabled: true,
                materialCutOffHour: 16,
                materialCutOffMinute: 30,
                materialCutOffOnSaturday: true,
                materialCutOffOnSunday: true,
                projectsWithTomorrowBookingIds: [projectId],
                materialItemsForTomorrow: [
                    .init(projectId: projectId, dayStart: tomorrow, isOrdered: ordered)
                ]
            )
        }

        let before = WarningsComputation.generate(snapshot(ordered: false), now: beforeCutoff)
        XCTAssertFalse(before.contains { $0.type == .materialsCutoff })

        let unordered = WarningsComputation.generate(snapshot(ordered: false), now: afterCutoff)
        XCTAssertEqual(unordered.filter { $0.type == .materialsCutoff }.count, 1)
        XCTAssertTrue(unordered.contains { $0.message.contains("16:30") })

        let ordered = WarningsComputation.generate(snapshot(ordered: true), now: afterCutoff)
        XCTAssertFalse(ordered.contains { $0.type == .materialsCutoff })
    }
}
