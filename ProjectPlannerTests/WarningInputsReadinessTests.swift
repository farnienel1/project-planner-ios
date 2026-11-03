import XCTest
@testable import Project_Planner

/// The Warnings screen and Home wait for every input of the shared warning functions before showing a count.
/// First open used to scan before settings, payment runs, bookings or leave had loaded and showed "0 active"
/// with the default window; a second refresh then showed the real warnings.
@MainActor
final class WarningInputsReadinessTests: XCTestCase {
    /// Releasing a main-actor store at the end of a test hits a Swift runtime crash in this host.
    private static var retained: [AnyObject] = []

    private func readiness(
        settings: Bool = true,
        paymentRuns: Bool = true,
        invoicing: Bool = false,
        bookings: Bool = true,
        managerBookings: Bool = true,
        operatives: Bool = true,
        roster: Bool = true,
        leave: Bool = true,
        jobs: Bool = true
    ) -> WarningInputsReadiness {
        WarningInputsReadiness(
            organisationSettingsLoaded: settings,
            paymentRunsLoaded: paymentRuns,
            usesInvoicingPeriod: invoicing,
            bookingsLoaded: bookings,
            managerBookingsLoaded: managerBookings,
            operativesLoaded: operatives,
            rosterLoaded: roster,
            annualLeaveLoaded: leave,
            jobsLoaded: jobs
        )
    }

    func testEveryInputLoadedIsReady() {
        XCTAssertTrue(WarningInputsReadiness.allLoaded.isReady)
        XCTAssertTrue(WarningInputsReadiness.allLoaded.storeInputsReady)
        XCTAssertNil(WarningInputsReadiness.allLoaded.waitingMessage)
        XCTAssertTrue(WarningInputsReadiness.allLoaded.canShowInvoicingSummary)
    }

    func testEachMissingInputBlocksTheScan() {
        XCTAssertEqual(readiness(settings: false).missing, [.organisationSettings])
        XCTAssertEqual(readiness(bookings: false).missing, [.bookings])
        XCTAssertEqual(readiness(managerBookings: false).missing, [.managerBookings])
        XCTAssertEqual(readiness(operatives: false).missing, [.people])
        XCTAssertEqual(readiness(roster: false).missing, [.people])
        XCTAssertEqual(readiness(leave: false).missing, [.annualLeave])
        XCTAssertEqual(readiness(jobs: false).missing, [.jobs])
        for state in [
            readiness(settings: false), readiness(bookings: false), readiness(managerBookings: false),
            readiness(operatives: false), readiness(roster: false), readiness(leave: false), readiness(jobs: false)
        ] {
            XCTAssertFalse(state.isReady)
        }
    }

    func testPaymentRunsAreNeededOnlyForTheInvoicingPeriod() {
        // Set number of days / Full week do not read payment runs.
        XCTAssertTrue(readiness(paymentRuns: false, invoicing: false).isReady)
        // Invoicing period waits for the server read of the payment runs.
        let invoicingWaiting = readiness(paymentRuns: false, invoicing: true)
        XCTAssertEqual(invoicingWaiting.missing, [.paymentRuns])
        XCTAssertFalse(invoicingWaiting.isReady)
        XCTAssertFalse(invoicingWaiting.canShowInvoicingSummary)
        XCTAssertTrue(readiness(paymentRuns: true, invoicing: true).canShowInvoicingSummary)
    }

    func testInvoicingSummaryNeverShowsFromUnloadedSettings() {
        XCTAssertFalse(readiness(settings: false).canShowInvoicingSummary)
        XCTAssertFalse(readiness(settings: false, invoicing: true).canShowInvoicingSummary)
    }

    func testStoreInputsIgnoreSettingsTheScanReadsItself() {
        // A scan may start (it reads the organisation document from the server) but publishes only when ready.
        let state = readiness(settings: false, paymentRuns: false, invoicing: true)
        XCTAssertTrue(state.storeInputsReady)
        XCTAssertFalse(state.isReady)
        XCTAssertFalse(readiness(leave: false).storeInputsReady)
    }

    func testWaitingMessageNamesWhatIsStillLoading() {
        XCTAssertEqual(readiness(leave: false).waitingMessage, "Waiting for annual leave.")
        XCTAssertEqual(
            readiness(bookings: false, leave: false).waitingMessage,
            "Waiting for bookings and annual leave."
        )
        XCTAssertEqual(
            readiness(settings: false, bookings: false, jobs: false).waitingMessage,
            "Waiting for organisation settings, bookings and jobs."
        )
    }

    func testScreenShowsLoadingUntilAScanOfLoadedInputsHasPublished() {
        // Before the first complete scan: loading, never "0 active" or an all-clear.
        XCTAssertEqual(
            WarningsDisplayPhase.phase(hasCompletedLiveDetection: false, incompleteDataMessage: nil, activeCount: 0),
            .loading
        )
        XCTAssertEqual(
            WarningsDisplayPhase.phase(hasCompletedLiveDetection: true, incompleteDataMessage: nil, activeCount: 0),
            .ready(activeCount: 0)
        )
        XCTAssertEqual(
            WarningsDisplayPhase.phase(hasCompletedLiveDetection: true, incompleteDataMessage: nil, activeCount: 4),
            .ready(activeCount: 4)
        )
        // A failed booking read is said, never shown as all clear.
        XCTAssertEqual(
            WarningsDisplayPhase.phase(hasCompletedLiveDetection: false, incompleteDataMessage: "Bookings could not be loaded", activeCount: 0),
            .incomplete("Bookings could not be loaded")
        )
    }

    func testHomePillWaitsForTheFirstScan() {
        XCTAssertEqual(WarningsDisplayPhase.homePillValue(hasCompletedLiveDetection: false, activeCount: 0), "Checking…")
        XCTAssertEqual(WarningsDisplayPhase.homePillValue(hasCompletedLiveDetection: true, activeCount: 0), "All clear")
        XCTAssertEqual(WarningsDisplayPhase.homePillValue(hasCompletedLiveDetection: true, activeCount: 3), "3 active")
        XCTAssertEqual(WarningsDisplayPhase.homeMetricValue(hasCompletedLiveDetection: false, activeCount: 0), "–")
        XCTAssertEqual(WarningsDisplayPhase.homeMetricValue(hasCompletedLiveDetection: true, activeCount: 0), "0")
    }

    /// Fresh stores (nothing read yet, no organisation open) are not ready, so no scan publishes from them.
    func testFreshStoresAreNotReady() {
        let operativeStore = OperativeStore()
        let bookingStore = BookingStore()
        let projectStore = ProjectStore()
        let userStore = UserStore()
        let managerScheduleStore = ManagerScheduleStore()
        let holidayStore = HolidayStore()
        let firebaseBackend = FirebaseBackend()
        Self.retained += [operativeStore, bookingStore, projectStore, userStore, managerScheduleStore, holidayStore, firebaseBackend]
        let state = WarningsRefreshHelper.inputsReadiness(
            operativeStore: operativeStore,
            bookingStore: bookingStore,
            projectStore: projectStore,
            userStore: userStore,
            managerScheduleStore: managerScheduleStore,
            holidayStore: holidayStore,
            firebaseBackend: firebaseBackend
        )
        XCTAssertFalse(state.isReady)
        XCTAssertFalse(state.storeInputsReady)
        XCTAssertFalse(state.canShowInvoicingSummary)
        XCTAssertTrue(state.missing.contains(.bookings))
        XCTAssertTrue(state.missing.contains(.annualLeave))
        XCTAssertTrue(state.missing.contains(.people))
    }
}
