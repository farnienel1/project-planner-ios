import XCTest
@testable import Project_Planner

/// Fix B: Edit booking offers Delete on a labour booking only when RULEBOOK 1.10.0 §2, §16 `canDeleteBooking` allows
/// it — an admin on any job, a manager on a job they manage (the same test as `canWriteBooking`), an operative never —
/// and a refused delete is reported instead of the sheet closing as if it had worked. Offline the bin is disabled with
/// `OfflinePolicy.onlineOnlyMessage` (§2, deletes are online only).
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

    private var operative: JobAccessViewer {
        viewer(Role(isSuperAdmin: false, isAdmin: false, isManager: false, isOperativeMode: true), uid: "TEST-operative")
    }

    /// A loaded job whose stored managers are `managerUserIds`.
    private func job(managedBy managerUserIds: [String]) -> Project {
        var job = Project(
            jobNumber: "TEST-J1",
            siteName: "TEST-Kitchen refit",
            siteAddress: "1 Test Street",
            client: Client(name: "TEST-Client"),
            startDate: Date(),
            endDate: Date(),
            jobType: .catA,
            manager: .na
        )
        job.storedManagerUserIds = managerUserIds
        return job
    }

    func testAdminsAndTheJobsManagersAreOfferedDeleteOperativesNever() {
        let store = BookingStore()
        let managed = job(managedBy: ["TEST-manager"])
        let otherJob = job(managedBy: ["TEST-someone-else"])
        JobAccessContext.updateJobs([managed, otherJob])
        defer { JobAccessContext.updateJobs([]) }
        let onManagedJob = LogicFixtures.booking(on: Date(), operativeId: UUID(), projectId: managed.id)
        let onOtherJob = LogicFixtures.booking(on: Date(), operativeId: UUID(), projectId: otherJob.id)

        JobAccessContext.updateViewer(admin)
        XCTAssertTrue(store.canDeleteBooking(onManagedJob))
        XCTAssertTrue(store.canDeleteBooking(onOtherJob), "an admin deletes a labour booking on any job")

        JobAccessContext.updateViewer(manager)
        XCTAssertTrue(store.canDeleteBooking(onManagedJob), "a manager deletes bookings on jobs they manage")
        XCTAssertFalse(store.canDeleteBooking(onOtherJob), "never on a job someone else manages")

        JobAccessContext.updateViewer(operative)
        XCTAssertFalse(store.canDeleteBooking(onManagedJob))
        XCTAssertFalse(store.canDeleteBooking(onOtherJob))
    }

    func testDeleteFollowsTheWriteRule() {
        let managed = job(managedBy: ["TEST-manager"])
        let otherJob = job(managedBy: ["TEST-someone-else"])
        for viewer in [admin, manager, operative] {
            for job in [managed, otherJob] {
                let booking: [String: Any] = ["collection": "bookings", "projectId": job.documentId]
                XCTAssertEqual(
                    CanonicalBusinessEngine.canDeleteBooking(viewer, booking: booking, job: job.jobAccessFields, managers: []),
                    CanonicalBusinessEngine.canWriteBooking(viewer, booking: booking, job: job.jobAccessFields, managers: []),
                    "canDeleteBooking = canWriteBooking for \(viewer.uid) on \(job.storedManagerUserIds)"
                )
            }
        }
    }

    func testARefusedDeleteIsReportedAndTheBookingStays() async {
        let store = BookingStore()
        let otherJob = job(managedBy: ["TEST-someone-else"])
        JobAccessContext.updateJobs([otherJob])
        defer { JobAccessContext.updateJobs([]) }
        let booking = LogicFixtures.booking(on: Date(), operativeId: UUID(), projectId: otherJob.id)
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
