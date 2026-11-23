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

    /// What one save changes in `qualificationExpiryDates` and `qualificationCertificateURLs` (review of #269):
    /// only what the person changed in this editor, judged against the maps the editor LOADED (`baseline*`), never
    /// against the live stored row — so an expiry or certificate saved on another device after this phone loaded,
    /// and an expiry kept under another spelling of the id (#19), are never overwritten or deleted.
    struct MapChanges: Equatable {
        var setExpiry: [String: Date] = [:]
        var removeExpiry: [String] = []
        var setCertificates: [String: String] = [:]
        var removeCertificates: [String] = []

        /// The maps after this save: `current` (the stored row) less the removed keys plus the set ones.
        func applied(expiry current: [String: Date]) -> [String: Date] {
            var out = current
            for key in removeExpiry { out.removeValue(forKey: key) }
            for (key, value) in setExpiry { out[key] = value }
            return out
        }

        func applied(certificates current: [String: String]) -> [String: String] {
            var out = current
            for key in removeCertificates { out.removeValue(forKey: key) }
            for (key, value) in setCertificates { out[key] = value }
            return out
        }
    }

    /// The editor's own changes:
    /// - expiry set: an entry the editor holds for a selected qualification that is new or on another day than when
    ///   loaded; expiry removed: a key the editor loaded that it no longer holds (the person switched it off or
    ///   removed the qualification). A key under another spelling stays in the editor's map, so it is never removed.
    /// - certificate set: a link the editor holds that differs from when loaded; certificate removed: a key the
    ///   editor loaded that it no longer holds (Remove Certificate, or the qualification removed).
    /// - `uploaded`: new certificates this save uploaded — each set under its id, and every OTHER spelling of that id
    ///   in `knownCertificates` (what this phone holds, stored row included) removed, so the server keeps one link.
    static func changes(
        baselineExpiry: [String: Date],
        editorExpiry: [String: Date],
        selectedIds: Set<String>,
        baselineCertificates: [String: String],
        editorCertificates: [String: String],
        uploaded: [String: String] = [:],
        knownCertificates: [String: String] = [:],
        calendar: Calendar = OrganizationRulebookContext.calendar
    ) -> MapChanges {
        var changes = MapChanges()
        for (key, date) in editorExpiry where selectedIds.contains(key) {
            let day = calendar.startOfDay(for: date)
            if let loaded = baselineExpiry[key], calendar.isDate(loaded, inSameDayAs: day) { continue }
            changes.setExpiry[key] = day
        }
        changes.removeExpiry = baselineExpiry.keys.filter { editorExpiry[$0] == nil }.sorted()
        for (key, url) in editorCertificates where baselineCertificates[key] != url {
            changes.setCertificates[key] = url
        }
        var removedCertificates = Set(baselineCertificates.keys.filter { editorCertificates[$0] == nil })
        for (id, url) in uploaded {
            changes.setCertificates[id] = url
            removedCertificates.remove(id)
            let target = id.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let spellings = Set(knownCertificates.keys).union(baselineCertificates.keys).union(editorCertificates.keys)
            for key in spellings where key != id
                && key.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == target {
                removedCertificates.insert(key)
            }
        }
        changes.removeCertificates = removedCertificates.filter { changes.setCertificates[$0] == nil }.sorted()
        return changes
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
