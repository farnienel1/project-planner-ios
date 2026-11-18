import Foundation

/// RULEBOOK 1.68.0 §29: the site audit report and field limits come from the packed script, never Swift.
/// `siteAuditReportLayout` lays the whole report out (wrapped lines, card heights, page breaks, "Page n of N",
/// photo boxes); `SiteAuditPDFBuilder` only draws its ops, so the iPhone PDF matches web's.
extension CanonicalBusinessEngine {
    /// `siteAuditReportLayout(input)` → `{ page, pages: [{ number, ops }], fileName, reference }`.
    nonisolated static func siteAuditReportLayout(_ input: [String: Any]) -> [String: Any]? {
        callJSON("siteAuditReportLayout", arguments: [input]) as? [String: Any]
    }

    /// `siteAuditReportInput({ audit, organizationName, job, photos, logo, timeZone })` (review of #262): the report's
    /// input composed the same way as web — the job's address lines (never map coordinates), a stored photo that did
    /// not load keeps a 4 : 3 box — so the same audit gives the same pages on both apps.
    nonisolated static func siteAuditReportInput(_ args: [String: Any]) -> [String: Any]? {
        callJSON("siteAuditReportInput", arguments: [args]) as? [String: Any]
    }

    /// `siteAuditReportTextLines(layout)`: each page's text, in drawing order (the shared fixture compares these).
    nonisolated static func siteAuditReportTextLines(_ layout: [String: Any]) -> [[String]]? {
        callJSON("siteAuditReportTextLines", arguments: [layout]) as? [[String]]
    }

    /// `siteAuditPhotoObjectPath({ kind, organizationId, userId, auditId, createdAtMs, index, extension })` (final
    /// review of #389 / #262): where one site audit photo is stored, `{uid}_{createdAtMs + index}.{ext}` — unique per
    /// item, the same on every retry of that queued copy.
    nonisolated static func siteAuditPhotoObjectPath(
        kind: String,
        organizationId: String,
        userId: String,
        auditId: String,
        createdAtMs: Int64,
        index: Int,
        fileExtension: String
    ) -> String? {
        let input: [String: Any] = [
            "kind": kind, "organizationId": organizationId, "userId": userId, "auditId": auditId,
            "createdAtMs": createdAtMs, "index": index, "extension": fileExtension,
        ]
        return callJSON("siteAuditPhotoObjectPath", arguments: [input]) as? String
    }

    /// `SITE_AUDIT_FIELD_LIMITS`: maximum characters of a NEW edit (title 120, location 120, assignee 80,
    /// comments 2000, annotations 2000, customTitle 120; personal audits jobNumber 60, jobName 200). Stored longer
    /// text is never cut.
    nonisolated static var siteAuditFieldLimits: [String: Int] {
        constant("SITE_AUDIT_FIELD_LIMITS", as: [String: Int].self) ?? [:]
    }

    /// `SITE_AUDIT_FIELD_LABELS[field]`: the shared label (Title, Location, Assignee, Comments, Annotations,
    /// "Title (optional)" for the audit's custom title), the same words on both apps and in the report.
    nonisolated static func siteAuditFieldLabel(_ field: String) -> String? {
        constant("SITE_AUDIT_FIELD_LABELS", as: [String: String].self)?[field]
    }

    /// `siteAuditFieldCounter(field, value, { stored })` → "34 / 120", over, blocksSave.
    nonisolated static func siteAuditFieldCounter(
        field: String,
        value: String,
        stored: String? = nil
    ) -> (label: String, over: Bool, blocksSave: Bool)? {
        var arguments: [Any] = [field, value]
        if let stored { arguments.append(["stored": stored]) }
        guard let row = callJSON("siteAuditFieldCounter", arguments: arguments) as? [String: Any],
              let label = row["label"] as? String else { return nil }
        return (label, (row["over"] as? Bool) ?? false, (row["blocksSave"] as? Bool) ?? false)
    }

    /// `siteAuditFieldLimitError(fields, stored)`: nil when the edit may be saved, else the message. A field
    /// unchanged from what is stored passes whatever its length (guardrail 3).
    nonisolated static func siteAuditFieldLimitError(_ fields: [String: String], stored: [String: String]? = nil) -> String? {
        var arguments: [Any] = [fields]
        if let stored { arguments.append(stored) }
        return callJSON("siteAuditFieldLimitError", arguments: arguments) as? String
    }

    /// The shared fixture: `SITE_AUDIT_REPORT_FIXTURE_INPUTS` and `SITE_AUDIT_REPORT_FIXTURE_EXPECTED`.
    nonisolated static func siteAuditReportFixture() -> (inputs: [[String: Any]], expected: [[String: Any]])? {
        guard let inputs = callJSON("siteAuditReportFixtureForApps", arguments: []) as? [String: Any],
              let rows = inputs["inputs"] as? [[String: Any]],
              let expected = inputs["expected"] as? [[String: Any]] else { return nil }
        return (rows, expected)
    }
}
