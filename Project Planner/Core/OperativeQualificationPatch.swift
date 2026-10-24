//
//  OperativeQualificationPatch.swift
//  Project Planner
//
//  Builds the operative qualification write from the shared script.
//  Assignments this editor loaded may be changed. Assignments it never loaded stay.
//

import Foundation

enum OperativeQualificationPatch {
    struct Maps: Sendable {
        var qualifications: [Qualification]
        var expiryDates: [String: Date]
        var certificateURLs: [String: String]
    }

    /// `baselineIds` are the qualification ids this editor loaded. A later assignment on the
    /// operative that is not in that set is kept. An id the editor removed is not written back.
    static func mergedWrite(
        stored: Maps,
        baselineIds: Set<String>,
        editor: Maps
    ) -> CanonicalBusinessEngine.CanonicalOperativeQualificationMaps? {
        let baseline = Set(baselineIds.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty })
        let selectedIds = editor.qualifications.map(\.id).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        let selected = Set(selectedIds)
        let clearedAssignments = baseline.subtracting(selected)
        let scriptRemoved = CanonicalBusinessEngine.removedQualificationCertificateIds(
            previousUrls: stored.certificateURLs,
            nextUrls: editor.certificateURLs,
            assignedIds: selectedIds
        ) ?? []
        let removedIds = Array(Set(scriptRemoved).union(clearedAssignments))
        let previous = CanonicalBusinessEngine.CanonicalOperativeQualificationMaps(
            qualifications: stored.qualifications.filter { qualification in
                let id = qualification.id.trimmingCharacters(in: .whitespacesAndNewlines)
                return !id.isEmpty && !baseline.contains(id)
            }.map(row),
            qualificationExpiryDates: isoDates(stored.expiryDates.filter { entry in
                !baseline.contains(entry.key.trimmingCharacters(in: .whitespacesAndNewlines))
            }),
            qualificationCertificateURLs: stored.certificateURLs
        )
        let next = CanonicalBusinessEngine.CanonicalOperativeQualificationNext(
            qualifications: editor.qualifications.map(row),
            qualificationExpiryDates: isoDates(editor.expiryDates),
            qualificationCertificateURLs: editor.certificateURLs,
            removedCertificateIds: removedIds
        )
        return CanonicalBusinessEngine.mergeOperativeQualificationWrite(
            CanonicalBusinessEngine.CanonicalOperativeQualificationMergeInput(previous: previous, next: next)
        )
    }

    static func qualifications(
        from rows: [CanonicalBusinessEngine.CanonicalAssignedQualificationRow],
        preferring existing: [Qualification]
    ) -> [Qualification] {
        rows.map { row in
            if var match = existing.first(where: { $0.id == row.id }) {
                match.name = row.name
                match.hasEndDate = row.hasEndDate
                match.createdAt = CanonicalBusinessEngine.date(fromIso: row.createdAtIso) ?? match.createdAt
                match.updatedAt = CanonicalBusinessEngine.date(fromIso: row.updatedAtIso) ?? match.updatedAt
                match.endDate = row.endDateIso.flatMap { CanonicalBusinessEngine.date(fromIso: $0) }
                return match
            }
            return Qualification(
                id: row.id,
                name: row.name,
                hasEndDate: row.hasEndDate,
                endDate: row.endDateIso.flatMap { CanonicalBusinessEngine.date(fromIso: $0) },
                createdAt: CanonicalBusinessEngine.date(fromIso: row.createdAtIso) ?? Date(),
                updatedAt: CanonicalBusinessEngine.date(fromIso: row.updatedAtIso) ?? Date()
            )
        }
    }

    static func expiryDates(from isoDates: [String: String]) -> [String: Date] {
        isoDates.reduce(into: [String: Date]()) { dates, entry in
            if let date = CanonicalBusinessEngine.date(fromIso: entry.value) {
                dates[entry.key] = date
            }
        }
    }

    private nonisolated static func row(_ qualification: Qualification) -> CanonicalBusinessEngine.CanonicalAssignedQualificationRow {
        CanonicalBusinessEngine.CanonicalAssignedQualificationRow(
            id: qualification.id,
            name: qualification.name,
            hasEndDate: qualification.hasEndDate,
            createdAtIso: CanonicalBusinessEngine.isoString(from: qualification.createdAt),
            updatedAtIso: CanonicalBusinessEngine.isoString(from: qualification.updatedAt),
            endDateIso: qualification.endDate.map { CanonicalBusinessEngine.isoString(from: $0) }
        )
    }

    private static func isoDates(_ dates: [String: Date]) -> [String: String] {
        dates.mapValues { CanonicalBusinessEngine.isoString(from: $0) }
    }
}
