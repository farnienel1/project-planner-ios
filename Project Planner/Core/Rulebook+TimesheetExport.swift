//
//  Rulebook+TimesheetExport.swift
//  Project Planner
//
//  RULEBOOK 1.54.1 §16 / §24 `timesheetExportStoragePath(organizationId, fileName, stampSeconds, uploaderUid)`: a
//  timesheet export is stored as `timesheetExports/{uploader uid}_{seconds}_{file}`, read by admins and the exporter
//  only. The four-argument call is here (the three-argument wrapper in `Canonical/` is left as it is).
//

import Foundation

extension CanonicalBusinessEngine {
    /// The export's Storage path with the exporter's uid in front of the name. Nil when the script did not answer.
    nonisolated static func timesheetExportStoragePath(
        organizationId: String,
        fileName: String,
        stampSeconds: Int,
        uploaderUid: String
    ) -> String? {
        guard let path = callJSON(
            "timesheetExportStoragePath",
            arguments: [organizationId, fileName, stampSeconds, uploaderUid]
        ) as? String, !path.isEmpty else { return nil }
        return path
    }
}
