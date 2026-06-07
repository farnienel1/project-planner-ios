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
}
