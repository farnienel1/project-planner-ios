//
//  WarningsMaterialCutOffLoad.swift
//  Project Planner
//
//  Reads the inputs of `materialCutOffWarningRows` (the material lines and order send records of the jobs booked
//  tomorrow) for one warnings scan. Load only: which rows are shown is still the rulebook's
//  (`materialCutOffWarningRows` through `CanonicalBusinessEngine`).
//
//  Owner report 23 Nov ("Warnings says Checking for about 30 seconds"): the scan read every job's lines and records
//  one after the other, two server round trips per job, before it could start. The jobs are now read at the same
//  time; each job still reads its lines first and its send records only when its lines were read, and a job whose
//  lines could not be read is still left out (`loadedProjectIds`), so the result is the same as reading them in turn.
//

import Foundation

enum WarningsMaterialCutOffLoad {
    /// One job's answer, filled in by its read on the main actor.
    @MainActor
    private final class JobResult<Line, Record> {
        var lines: [Line]?
        var records: [Record]?
    }

    /// Every job's lines, then (only when its lines were read) its send records, for all jobs at once. The rows come
    /// back in `projectIds` order, exactly as the one-after-the-other read returned them. The reads are child tasks of
    /// the caller, so cancelling the scan cancels them (the caller then publishes nothing).
    @MainActor
    static func load<Line, Record>(
        projectIds: [UUID],
        lines: @escaping @MainActor @Sendable (UUID) async -> [Line]?,
        records: @escaping @MainActor @Sendable (UUID) async -> [Record]?
    ) async -> (lines: [Line], records: [Record], loadedProjectIds: Set<UUID>) {
        let results = projectIds.map { _ in JobResult<Line, Record>() }
        await withTaskGroup(of: Void.self) { group in
            for (projectId, result) in zip(projectIds, results) {
                group.addTask { @MainActor in
                    guard let loaded = await lines(projectId) else { return }
                    result.lines = loaded
                    result.records = await records(projectId)
                }
            }
            await group.waitForAll()
        }
        var outLines: [Line] = []
        var outRecords: [Record] = []
        var loaded = Set<UUID>()
        for (projectId, result) in zip(projectIds, results) {
            guard let jobLines = result.lines else { continue }
            outLines.append(contentsOf: jobLines)
            loaded.insert(projectId)
            if let sent = result.records { outRecords.append(contentsOf: sent) }
        }
        return (outLines, outRecords, loaded)
    }
}
