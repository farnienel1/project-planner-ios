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

    /// Every job document, once: `workDocuments` (placeholders and exact duplicate ids out; two
    /// documents may share a job number, and bookings point at either, so both stay).
    ///
    /// Projects are passed as `projects` and small works as `smallWorks`, in that order, as web does: when a
    /// `projects` and a `smallWorks` document share an id (older builds re-saved a small works job typed
    /// "CAT A" into `projects` under the same id), the project is the one kept. The order used to follow
    /// whichever listener fired last, so the shared job dropped off Projects each time the projects listener ran.
    static func uniqueWorks(_ projects: [Project]) -> [Project] {
        let projectRows: [[String: Any]] = projects.filter { !$0.isSmallWorksDocument }
            .map { ["id": $0.id.uuidString, "jobNumber": $0.jobNumber] }
        let smallWorkRows: [[String: Any]] = projects.filter { $0.isSmallWorksDocument }
            .map { ["id": $0.id.uuidString, "jobNumber": $0.jobNumber] }
        guard let kept = CanonicalBusinessEngine.workDocuments(projects: projectRows, smallWorks: smallWorkRows) else {
            return uniqueById(projects.filter { !$0.isSmallWorksDocument } + projects.filter { $0.isSmallWorksDocument })
        }
        var byId: [String: Project] = [:]
        let projectsFirst = projects.filter { !$0.isSmallWorksDocument } + projects.filter { $0.isSmallWorksDocument }
        for project in projectsFirst {
            if let first = byId[project.id.uuidString] {
                // Not lost: a small works document whose id a projects document also holds is still listed under
                // Small works (`smallWorksList`), as web lists each collection on its own screen.
                NSLog(
                    "JOB_DOCUMENT_SHARES_ID id=%@ kept=%@ alsoIn=%@",
                    project.documentId,
                    first.isSmallWorksDocument ? "smallWorks" : "projects",
                    project.isSmallWorksDocument ? "smallWorks" : "projects"
                )
                continue
            }
            byId[project.id.uuidString] = project
        }
        return kept.compactMap { ($0["id"] as? String).flatMap { byId[$0] } }
    }

    /// The Small works list: every `smallWorks` document as read, as web lists the collection (`loadSmallWorks`).
    ///
    /// `store` is the store's job list (`uniqueWorks`, one row per id: when a `projects` and a `smallWorks` document
    /// share an id the project is kept there, so job lookups and pickers see one job). `smallWorksDocuments` is the
    /// last read of the `smallWorks` collection. A small works document that lost its id to a project in `store` is
    /// added back here, so it is never missing from Small works while web shows it. Every other small works row
    /// comes from `store`, so local creates, edits and deletes show at once.
    static func smallWorksList(store: [Project], smallWorksDocuments: [Project]) -> [Project] {
        var list = store.filter { $0.isSmallWorksDocument }
        var listed = Set(list.map(\.id))
        let projectIds = Set(store.filter { !$0.isSmallWorksDocument }.map(\.id))
        for document in smallWorksDocuments where document.isSmallWorksDocument
            && projectIds.contains(document.id)
            && listed.insert(document.id).inserted {
            list.append(document)
        }
        return list
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
            isSmallWorks ? project.isSmallWorksDocument : !project.isSmallWorksDocument
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
