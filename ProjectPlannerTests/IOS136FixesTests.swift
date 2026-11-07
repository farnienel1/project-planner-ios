import XCTest
@testable import Project_Planner

/// iOS-only fixes of the 1.36 clean-up release. Each test names the failure it locks out.
@MainActor
final class IOS136FixesTests: XCTestCase {
    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    }

    private func source(_ path: String) throws -> String {
        try String(contentsOf: repoRoot.appendingPathComponent(path), encoding: .utf8)
    }

    /// The text of `func <name>` up to the next `func ` at the same file (good enough for a guard on one function).
    private func functionBody(_ name: String, in text: String) throws -> String {
        let start = try XCTUnwrap(text.range(of: "func \(name)("), "func \(name) not found")
        let rest = text[start.upperBound...]
        let end = rest.range(of: "\n    func ")?.lowerBound
            ?? rest.range(of: "\n    private func ")?.lowerBound
            ?? rest.endIndex
        return String(rest[..<end])
    }

    override func setUp() async throws {
        OfflineOutboxStore.shared.clearAll()
    }

    override func tearDown() async throws {
        OfflineOutboxStore.shared.clearAll()
    }

    // MARK: 1. Overtime reopen notice on every booking edit path (RULEBOOK 1.33.0 §25)

    /// Failure before: an edit made offline was queued without the copy it changed, so when it replayed nobody was told
    /// their overtime line had reopened (web always tells them after its write).
    func testAQueuedEditKeepsTheCopyBeforeTheFirstEditForTheReopenNotice() throws {
        let outbox = OfflineOutboxStore.shared
        let synced = LogicFixtures.booking(on: Date(), slot: .customHours, start: "07:30", end: "18:00")
        var first = synced
        first.workEndTime = "17:00"
        var second = first
        second.workEndTime = "16:30"
        outbox.enqueueSaveBooking(first, changedFields: ["workEndTime"], organizationId: "TEST-ORG", previous: synced)
        outbox.enqueueSaveBooking(second, changedFields: ["workEndTime"], organizationId: "TEST-ORG", previous: first)
        XCTAssertEqual(outbox.entries.count, 1)
        let payload = try JSONDecoder().decode(OfflineSaveBookingPayload.self, from: try XCTUnwrap(outbox.entries.first).payload)
        XCTAssertEqual(payload.previousBooking?.workEndTime, "18:00", "the copy the server still has, not the unsynced edit")
        XCTAssertEqual(payload.booking.workEndTime, "16:30")
    }

    func testAQueuedCreateCarriesNoPreviousCopy() throws {
        let outbox = OfflineOutboxStore.shared
        let booking = LogicFixtures.booking(on: Date())
        outbox.enqueueSaveBooking(booking, changedFields: nil, organizationId: "TEST-ORG", previous: booking)
        let payload = try JSONDecoder().decode(OfflineSaveBookingPayload.self, from: try XCTUnwrap(outbox.entries.first).payload)
        XCTAssertNil(payload.previousBooking)
    }

    func testAQueuedManagerScheduleEditKeepsTheCopyBeforeIt() throws {
        let outbox = OfflineOutboxStore.shared
        let synced = ManagerSiteBooking(id: UUID(), userId: "TEST-m1", date: Date(), timeSlot: .fullDay, locationType: .office)
        var edited = synced
        edited.timeSlot = .morning
        outbox.enqueueSaveManagerSiteBooking(edited, changedFields: ["timeSlot"], organizationId: "TEST-ORG", previous: synced)
        let payload = try JSONDecoder().decode(
            OfflineSaveManagerSiteBookingPayload.self, from: try XCTUnwrap(outbox.entries.first).payload
        )
        XCTAssertEqual(payload.previousBooking?.timeSlot, .fullDay)
    }

    func testAnOlderQueuedEditWithoutThePreviousCopyStillDecodes() throws {
        let booking = LogicFixtures.booking(on: Date())
        let encoded = try JSONEncoder().encode(OfflineSaveBookingPayload(booking: booking, changedFields: ["notes"]))
        var object = try XCTUnwrap(try JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object.removeValue(forKey: "previousBooking")
        let older = try JSONSerialization.data(withJSONObject: object)
        let payload = try JSONDecoder().decode(OfflineSaveBookingPayload.self, from: older)
        XCTAssertNil(payload.previousBooking)
        XCTAssertEqual(payload.changedFields, ["notes"])
    }

    /// Failure before: `completeBooking` wrote the status itself and never sent the reopen notice, although the status
    /// is part of `overtimeBookingFingerprint`. A refused edit also sent a notice for a change the server never took.
    func testEveryLabourEditGoesThroughTheNoticeAfterTheServerHasIt() throws {
        let store = try source("Project Planner/Core/BookingStore.swift")
        let complete = try functionBody("completeBooking", in: store)
        XCTAssertTrue(complete.contains("await updateBooking("), "completeBooking must reuse updateBooking (reopen notice)")
        XCTAssertFalse(complete.contains("saveData("), "completeBooking must not write on its own")
        let update = try functionBody("updateBooking", in: store)
        XCTAssertTrue(update.contains("written { OvertimeReopenNotice.labour"), "notice only once the edit reached the server")
        let coordinator = try source("Project Planner/Core/OfflineSyncCoordinator.swift")
        XCTAssertTrue(coordinator.contains("OvertimeReopenNotice.labour(before: previous, after: payload.booking)"))
        XCTAssertTrue(coordinator.contains("OvertimeReopenNotice.managerSite(before: previous, after: payload.booking)"))
        XCTAssertTrue(coordinator.contains("OvertimeReopenNotice.labour(before: booking, after: nil)"), "a replayed delete tells them too")
    }
}
