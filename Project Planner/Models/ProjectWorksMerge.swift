//
//  ProjectWorksMerge.swift
//  Project Planner
//

import Foundation

enum ProjectWorksMerge {
    static func uniqueById(_ projects: [Project]) -> [Project] {
        var seen = Set<UUID>()
        var result: [Project] = []
        result.reserveCapacity(projects.count)
        for project in projects {
            if seen.insert(project.id).inserted {
                result.append(project)
            }
        }
        return result
    }

    /// Collapse legacy duplicates where the same job number exists in both collections.
    static func dedupeByJobNumber(_ projects: [Project]) -> [Project] {
        var byJob: [String: Project] = [:]
        let sorted = projects.sorted { $0.updatedAt > $1.updatedAt }
        for project in sorted {
            let key = project.jobNumber.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if key.isEmpty {
                byJob[project.id.uuidString] = project
            } else if byJob[key] == nil {
                byJob[key] = project
            } else if project.jobType == .smallWorks, byJob[key]?.jobType != .smallWorks {
                byJob[key] = project
            }
        }
        return Array(byJob.values)
    }

    /// Every job document, once: `workDocuments` (placeholders and exact duplicate ids out; two
    /// documents may share a job number, and bookings point at either, so both stay).
    ///
    /// Projects are passed as `projects` and small works as `smallWorks`, in that order, as web does: when a
    /// `projects` and a `smallWorks` document share an id (older builds re-saved a small works job typed
    /// "CAT A" into `projects` under the same id), the project is the one kept. The order used to follow
    /// whichever listener fired last, so the shared job dropped off Projects each time the projects listener ran.
    static func uniqueWorks(_ projects: [Project]) -> [Project] {
        let projectRows: [[String: Any]] = projects.filter { $0.jobType != .smallWorks }
            .map { ["id": $0.id.uuidString, "jobNumber": $0.jobNumber] }
        let smallWorkRows: [[String: Any]] = projects.filter { $0.jobType == .smallWorks }
            .map { ["id": $0.id.uuidString, "jobNumber": $0.jobNumber] }
        guard let kept = CanonicalBusinessEngine.workDocuments(projects: projectRows, smallWorks: smallWorkRows) else {
            return uniqueById(projects.filter { $0.jobType != .smallWorks } + projects.filter { $0.jobType == .smallWorks })
        }
        var byId: [String: Project] = [:]
        let projectsFirst = projects.filter { $0.jobType != .smallWorks } + projects.filter { $0.jobType == .smallWorks }
        for project in projectsFirst where byId[project.id.uuidString] == nil {
            byId[project.id.uuidString] = project
        }
        return kept.compactMap { ($0["id"] as? String).flatMap { byId[$0] } }
    }

    /// Merge one collection (projects or small works) without letting an empty/failed
    /// remote snapshot wipe jobs that are already in memory or on disk.
    static func mergeWorkSlice(
        existingAll: [Project],
        remoteSlice: [Project]?,
        cachedSlice: [Project],
        isSmallWorks: Bool
    ) -> [Project] {
        let matches: (Project) -> Bool = { project in
            isSmallWorks ? project.jobType == .smallWorks : project.jobType != .smallWorks
        }
        let existingSlice = existingAll.filter(matches)
        let otherSlice = existingAll.filter { !matches($0) }
        let resolvedSlice: [Project]
        if let remoteSlice {
            if remoteSlice.isEmpty {
                if !existingSlice.isEmpty {
                    resolvedSlice = existingSlice
                } else if !cachedSlice.isEmpty {
                    resolvedSlice = cachedSlice
                } else {
                    resolvedSlice = []
                }
            } else {
                resolvedSlice = remoteSlice
            }
        } else if !existingSlice.isEmpty {
            resolvedSlice = existingSlice
        } else {
            resolvedSlice = cachedSlice
        }
        return uniqueWorks(resolvedSlice + otherSlice)
    }
}
