import XCTest
@testable import Project_Planner

/// Fix B: Edit booking offers Delete on a labour booking only when RULEBOOK 1.10.0 §2, §16 `canDeleteBooking` allows
/// it (admins; managers cancel instead), and a refused delete is reported instead of the sheet closing as if it had
/// worked. Offline the bin is disabled with `OfflinePolicy.onlineOnlyMessage` (§2, deletes are online only).
@MainActor
final class LabourBookingDeleteGateTests: XCTestCase {
    private typealias Role = CanonicalBusinessEngine.CanonicalStaffAccountRole

    nonisolated override func setUp() {
        super.setUp()
        JobAccessContext.updateViewer(nil)
    }

    nonisolated override func tearDown() {
        JobAccessContext.updateViewer(nil)
        super.tearDown()
    }

    private func viewer(_ role: Role, uid: String) -> JobAccessViewer {
        JobAccessViewer(role: role, projectsToggle: true, smallWorksToggle: true, uid: uid, ids: [uid], email: "\(uid)@x.t")
    }

    private var admin: JobAccessViewer {
        viewer(Role(isSuperAdmin: false, isAdmin: true, isManager: false, isOperativeMode: false), uid: "TEST-admin")
    }

    private var manager: JobAccessViewer {
        viewer(Role(isSuperAdmin: false, isAdmin: false, isManager: true, isOperativeMode: false), uid: "TEST-manager")
    }

    func testOnlyAdminsAreOfferedDeleteOnALabourBooking() {
        let store = BookingStore()
        let booking = LogicFixtures.booking(on: Date(), operativeId: UUID())

        JobAccessContext.updateViewer(admin)
        XCTAssertTrue(store.canDeleteBooking(booking))

        JobAccessContext.updateViewer(manager)
        XCTAssertFalse(store.canDeleteBooking(booking), "managers cancel labour bookings instead of deleting them")
    }

    func testARefusedDeleteIsReportedAndTheBookingStays() async {
        let store = BookingStore()
        let booking = LogicFixtures.booking(on: Date(), operativeId: UUID())
        store.bookings = [booking]
        JobAccessContext.updateViewer(manager)

        let message = await store.deleteBookingReportingRefusal(booking)

        XCTAssertNotNil(message, "the sheet must not close silently")
        XCTAssertFalse(message?.isEmpty ?? true)
        XCTAssertTrue(store.bookings.contains { $0.id == booking.id })
    }

    func testDeletingABookingIsOnlineOnly() {
        XCTAssertFalse(OfflinePolicy.isEnabled(.deleteBooking, isOnline: false))
        XCTAssertTrue(OfflinePolicy.isEnabled(.deleteBooking, isOnline: true))
        XCTAssertFalse(OfflinePolicy.onlineOnlyMessage.isEmpty)
    }
}
