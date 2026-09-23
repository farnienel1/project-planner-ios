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

    static func uniqueWorks(_ projects: [Project]) -> [Project] {
        dedupeByJobNumber(uniqueById(projects))
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
