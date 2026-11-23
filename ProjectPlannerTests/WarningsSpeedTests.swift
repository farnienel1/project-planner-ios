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

    func testLaunchQuietNeverHoldsTheFirstScan() {
        let now = Date()
        let quiet = now.addingTimeInterval(30)
        XCTAssertFalse(WarningsFirstOpenPolicy.launchQuietHoldsScan(quietUntil: quiet, now: now, hasCompletedLiveDetection: false),
                       "no list yet: the first scan waits for its inputs, not for the 30 s launch quiet")
        XCTAssertTrue(WarningsFirstOpenPolicy.launchQuietHoldsScan(quietUntil: quiet, now: now, hasCompletedLiveDetection: true),
                      "rescans after the first list still wait for the quiet, as before")
        XCTAssertFalse(WarningsFirstOpenPolicy.launchQuietHoldsScan(quietUntil: now.addingTimeInterval(-1), now: now, hasCompletedLiveDetection: true))
        XCTAssertFalse(WarningsFirstOpenPolicy.launchQuietHoldsScan(quietUntil: nil, now: now, hasCompletedLiveDetection: true))
    }

    func testTheBookingSchedulerAsksThePolicyAndStillWaitsForEveryInput() throws {
        let helper = try source("Core/WarningsRefreshHelper.swift")
        XCTAssertTrue(helper.contains("WarningsFirstOpenPolicy.launchQuietHoldsScan("))
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

    func testTheJobsAreReadAtTheSameTime() async {
        let ids = (0..<5).map { _ in UUID() }
        let started = Date()
        _ = await WarningsMaterialCutOffLoad.load(
            projectIds: ids,
            lines: { _ -> [String]? in
                try? await Task.sleep(nanoseconds: 200_000_000)
                return ["line"]
            },
            records: { _ -> [String]? in
                try? await Task.sleep(nanoseconds: 200_000_000)
                return ["sent"]
            }
        )
        // One after the other this is 5 × 0.4 s = 2 s; at the same time about 0.4 s.
        XCTAssertLessThan(Date().timeIntervalSince(started), 1.5)
    }

    func testTheScanUsesTheConcurrentReads() throws {
        let helper = try source("Core/WarningsRefreshHelper.swift")
        XCTAssertTrue(helper.contains("WarningsMaterialCutOffLoad.load("))
        XCTAssertTrue(helper.contains("let dismissedQualificationKeys = await dismissedKeysRead.value"))
        XCTAssertFalse(helper.contains("for projectId in projectIds {"), "no one-after-the-other material loop is left")
    }
}

@MainActor
private final class RecordReadLog {
    var ids: [UUID] = []
}
