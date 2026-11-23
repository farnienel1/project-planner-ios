import XCTest
@testable import Project_Planner

/// Owner report 23 Nov: "Warnings says Checking for about 30 seconds." Load timing only: which warnings are listed is
/// still the rulebook's (`unbookedLabourRows`, `operativeClashGroups`, `materialCutOffWarningRows`, …), unchanged.
@MainActor
final class WarningsSpeedTests: XCTestCase {
    private var appRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Project Planner")
    }

    private func source(_ rel: String) throws -> String {
        try String(contentsOf: appRoot.appendingPathComponent(rel), encoding: .utf8)
    }

    // MARK: Launch quiet

    func testLaunchQuietHoldsAScanOnlyUntilTheClashApprovalsHaveLoaded() {
        let now = Date()
        let quiet = now.addingTimeInterval(30)
        XCTAssertTrue(WarningsFirstOpenPolicy.launchQuietHoldsScan(quietUntil: quiet, now: now, clashApprovalsLoaded: false),
                      "inside the quiet a scan waits for both clash-approval listeners (an approved clash is never counted open)")
        XCTAssertFalse(WarningsFirstOpenPolicy.launchQuietHoldsScan(quietUntil: quiet, now: now, clashApprovalsLoaded: true),
                       "with the approvals loaded the scan runs: it no longer waits out the 30 s")
        XCTAssertFalse(WarningsFirstOpenPolicy.launchQuietHoldsScan(quietUntil: now.addingTimeInterval(-1), now: now, clashApprovalsLoaded: false),
                       "after the quiet nothing waits, as before")
        XCTAssertFalse(WarningsFirstOpenPolicy.launchQuietHoldsScan(quietUntil: nil, now: now, clashApprovalsLoaded: false))
    }

    /// Review of #274 (blocking): after a first list is published inside the quiet, an input change inside the quiet
    /// (leave arriving from the server after a cache snapshot, a roster answer, a booking edit) rescans at once.
    func testAnInputChangeInsideTheQuietRescansAfterTheFirstList() async {
        let quietUntil = Date().addingTimeInterval(30)
        var approvalsLoaded = false
        let scheduler = WarningsBookingScanScheduler()
        scheduler.debounceNanoseconds = 5_000_000
        scheduler.readinessRetryNanoseconds = 5_000_000
        scheduler.isReadyToScan = {
            !WarningsFirstOpenPolicy.launchQuietHoldsScan(quietUntil: quietUntil, now: Date(), clashApprovalsLoaded: approvalsLoaded)
        }
        var scans = 0
        scheduler.onScan = { scans += 1 }

        scheduler.noteBookingChange()
        try? await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(scans, 0, "approvals not loaded yet: no list")

        approvalsLoaded = true
        try? await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(scans, 1, "the first list, inside the quiet")

        scheduler.noteBookingChange()
        try? await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(scans, 2, "an input change inside the quiet rescans (it waited for the quiet before)")
        XCTAssertLessThan(Date(), quietUntil)
    }

    private func rosterUser(_ id: String, email: String) -> AppUser {
        var user = AppUser(id: id, email: email, organizationId: "TEST-org", role: .operative)
        user.firstName = "TEST"
        user.surname = id
        return user
    }

    /// Review of #274: a heartbeat must not restart the scan; a change the scan reads must.
    func testOnlyARosterChangeTheScanReadsAsksForARescan() {
        var roster = [rosterUser("TEST-a", email: "a@example.com"), rosterUser("TEST-b", email: "b@example.com")]
        var gate = WarningsRosterRescanGate()
        XCTAssertTrue(gate.shouldRescan(for: roster), "the first roster seen")
        XCTAssertFalse(gate.shouldRescan(for: roster), "the same roster published again")

        roster[0].lastSeenAt = Date()
        roster[1].profilePhotoURL = "https://example.com/p.jpg"
        roster[1].documentUpdatedAt = Date()
        XCTAssertFalse(gate.shouldRescan(for: roster), "lastSeenAt, a photo and the write time of a one-email person: no rescan")

        roster[0].isActive = false
        XCTAssertTrue(gate.shouldRescan(for: roster), "an active-flag change rescans")
        roster[1].assignedManagerUserIds = ["TEST-a"]
        XCTAssertTrue(gate.shouldRescan(for: roster), "a line-manager change rescans (the manager's warning scope)")
        roster[1].permissions.manager.toggle()
        XCTAssertTrue(gate.shouldRescan(for: roster), "a level change rescans (High vs Medium clashes)")

        // Two documents on one email: the newer write decides the one-per-email fold, so it counts there.
        var twins = [rosterUser("TEST-c", email: "c@example.com"), rosterUser("TEST-d", email: "C@example.com")]
        _ = gate.shouldRescan(for: twins)
        twins[0].documentUpdatedAt = Date()
        XCTAssertTrue(gate.shouldRescan(for: twins))
    }

    func testTheRosterTriggerUsesTheGate() throws {
        let content = try source("ContentView.swift")
        XCTAssertTrue(content.contains("if warningsRosterRescanGate.shouldRescan(for: users) {"))
    }

    func testTheBookingSchedulerAsksThePolicyAndStillWaitsForEveryInput() throws {
        let helper = try source("Core/WarningsRefreshHelper.swift")
        XCTAssertTrue(helper.contains("WarningsFirstOpenPolicy.launchQuietHoldsScan("))
        XCTAssertTrue(helper.contains("clashApprovalsLoaded: WarningResolutionStore.shared.clashApprovalsLoaded"))
        XCTAssertFalse(helper.contains("if let quietUntil = inputs.firebaseBackend.launchQuietUntil, Date() < quietUntil {"))
        // The readiness gate is untouched: a scan of inputs that have not loaded is never published.
        XCTAssertTrue(helper.contains("if !readiness.storeInputsReady { return false }"))
    }

    // MARK: Material cut-off inputs

    /// The one-after-the-other read the scan made before 23 Nov (reference for the concurrent read).
    private func loadOneAfterAnother(
        projectIds: [UUID],
        lines: (UUID) async -> [String]?,
        records: (UUID) async -> [String]?
    ) async -> (lines: [String], records: [String], loadedProjectIds: Set<UUID>) {
        var outLines: [String] = []
        var outRecords: [String] = []
        var loaded = Set<UUID>()
        for projectId in projectIds {
            guard let jobLines = await lines(projectId) else { continue }
            outLines.append(contentsOf: jobLines)
            loaded.insert(projectId)
            if let sent = await records(projectId) { outRecords.append(contentsOf: sent) }
        }
        return (outLines, outRecords, loaded)
    }

    func testConcurrentMaterialReadReturnsExactlyWhatTheSequentialReadReturned() async {
        let ids = (0..<7).map { _ in UUID() }
        // Job 2's lines fail (left out, records never read); job 4's records fail (lines kept); job 6 has no lines.
        let lineFails: Set<UUID> = [ids[2]]
        let recordFails: Set<UUID> = [ids[4]]
        let empty: Set<UUID> = [ids[6]]
        let recordReads = RecordReadLog()
        // Later jobs answer first, so a read that did not keep `projectIds` order would show up.
        let lines: @MainActor @Sendable (UUID) async -> [String]? = { id in
            let index = ids.firstIndex(of: id) ?? 0
            try? await Task.sleep(nanoseconds: UInt64(ids.count - index) * 15_000_000)
            if lineFails.contains(id) { return nil }
            if empty.contains(id) { return [] }
            return ["line-\(index)-a", "line-\(index)-b"]
        }
        let records: @MainActor @Sendable (UUID) async -> [String]? = { id in
            recordReads.ids.append(id)
            let index = ids.firstIndex(of: id) ?? 0
            try? await Task.sleep(nanoseconds: UInt64(ids.count - index) * 5_000_000)
            if recordFails.contains(id) { return nil }
            return ["sent-\(index)"]
        }
        let expected = await loadOneAfterAnother(projectIds: ids, lines: lines, records: records)
        recordReads.ids = []
        let actual = await WarningsMaterialCutOffLoad.load(projectIds: ids, lines: lines, records: records)
        XCTAssertEqual(actual.lines, expected.lines)
        XCTAssertEqual(actual.records, expected.records)
        XCTAssertEqual(actual.loadedProjectIds, expected.loadedProjectIds)
        XCTAssertFalse(actual.loadedProjectIds.contains(ids[2]), "a job whose lines failed is still left out")
        XCTAssertTrue(actual.loadedProjectIds.contains(ids[6]), "a job with no lines is still a loaded job")
        XCTAssertFalse(recordReads.ids.contains(ids[2]), "send records are read only after the job's lines were read")
    }

    func testConcurrentMaterialReadWithNoJobsIsEmpty() async {
        let result = await WarningsMaterialCutOffLoad.load(
            projectIds: [],
            lines: { _ -> [String]? in ["x"] },
            records: { _ -> [String]? in ["y"] }
        )
        XCTAssertTrue(result.lines.isEmpty)
        XCTAssertTrue(result.records.isEmpty)
        XCTAssertTrue(result.loadedProjectIds.isEmpty)
    }

    /// Deterministic: each read waits at a gate that opens when every job's read is in flight at once (or, if they
    /// were read one after the other, only when the test's fallback opens it). The count of reads in flight decides.
    func testTheJobsAreReadAtTheSameTime() async {
        let ids = (0..<5).map { _ in UUID() }
        let gate = ReadGate(expected: ids.count)
        let fallback = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            gate.open()
        }
        let result = await WarningsMaterialCutOffLoad.load(
            projectIds: ids,
            lines: { _ -> [String]? in
                await gate.enter()
                gate.leave()
                return ["line"]
            },
            records: { _ -> [String]? in ["sent"] }
        )
        fallback.cancel()
        XCTAssertEqual(gate.maxInFlight, ids.count, "every job's lines were being read at the same time")
        XCTAssertEqual(result.lines.count, ids.count)
    }

    func testCancellingTheScanCancelsTheReads() async {
        let ids = (0..<3).map { _ in UUID() }
        let seen = RecordReadLog()
        let scan = Task { @MainActor in
            await WarningsMaterialCutOffLoad.load(
                projectIds: ids,
                lines: { id -> [String]? in
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                    if Task.isCancelled { seen.ids.append(id) }
                    return nil
                },
                records: { _ -> [String]? in nil }
            )
        }
        try? await Task.sleep(nanoseconds: 20_000_000)
        scan.cancel()
        let result = await scan.value
        XCTAssertEqual(Set(seen.ids), Set(ids), "each job's read saw the scan's cancellation")
        XCTAssertTrue(result.loadedProjectIds.isEmpty)
    }

    func testTheScanUsesTheConcurrentReads() throws {
        let helper = try source("Core/WarningsRefreshHelper.swift")
        XCTAssertTrue(helper.contains("WarningsMaterialCutOffLoad.load("))
        XCTAssertTrue(helper.contains("async let dismissedKeysRead = firebaseBackend.loadDismissedQualificationKeys("))
        XCTAssertTrue(helper.contains("let dismissedQualificationKeys = await dismissedKeysRead"))
        XCTAssertFalse(helper.contains("for projectId in projectIds {"), "no one-after-the-other material loop is left")
    }
}

@MainActor
private final class RecordReadLog {
    var ids: [UUID] = []
}

/// Counts reads in flight; lets them through once `expected` are in flight together (or when `open()` is called).
@MainActor
private final class ReadGate {
    let expected: Int
    private(set) var inFlight = 0
    private(set) var maxInFlight = 0
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(expected: Int) { self.expected = expected }

    func enter() async {
        inFlight += 1
        maxInFlight = max(maxInFlight, inFlight)
        if inFlight >= expected { open() }
        if isOpen { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            if isOpen { continuation.resume() } else { waiters.append(continuation) }
        }
    }

    func leave() { inFlight -= 1 }

    func open() {
        isOpen = true
        let pending = waiters
        waiters = []
        for waiter in pending { waiter.resume() }
    }
}
