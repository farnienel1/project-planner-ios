//
//  Rulebook+BookingJobCollection.swift
//  Project Planner
//
//  Rulebook 1.11.0 (docs/RULEBOOK.md §16, §17): every labour, subcontractor and job-linked manager site booking
//  carries `jobCollection` — the collection its job is stored in — so the security rules can limit reads by kind.
//  Web `lib/canonical/bookings.ts` (`bookingJobCollectionFields`, `jobCollectionForJobId`) and `staffAccess.ts`
//  (`jobKind`), called through `CanonicalBusinessEngine`. Nothing is decided here.
//

import Foundation

extension CanonicalBusinessEngine {
    /// `jobCollectionForJobId(jobId, { projects, smallWorks })`: `projects`, `smallWorks`, or nil when the id is in
    /// neither list (or in both).
    nonisolated static func jobCollectionForJobId(_ jobId: String, projects: [String], smallWorks: [String]) -> String? {
        callJSON("jobCollectionForJobId", arguments: [jobId, ["projects": projects, "smallWorks": smallWorks]]) as? String
    }

    /// `bookingJobCollectionFields({ collection, jobCollection, locationType })`: `{ jobCollection }` to write on a
    /// booking, or `[:]` when the kind is not known (a manager site booking with no job never carries one).
    nonisolated static func bookingJobCollectionFields(collection: String, jobCollection: String?, locationType: String? = nil) -> [String: String] {
        var input: [String: Any] = ["collection": collection]
        if let jobCollection { input["jobCollection"] = jobCollection }
        if let locationType { input["locationType"] = locationType }
        guard let row = callJSON("bookingJobCollectionFields", arguments: [input]) as? [String: Any] else { return [:] }
        var out: [String: String] = [:]
        if let kind = row["jobCollection"] as? String { out["jobCollection"] = kind }
        return out
    }

    /// `jobKind(doc, collection)`: the collection decides; `jobType` only when the collection is not known.
    nonisolated static func jobKind(jobType: String?, collection: String?) -> String? {
        var doc: [String: Any] = [:]
        if let jobType { doc["jobType"] = jobType }
        return callJSON("jobKind", arguments: [doc, collection ?? NSNull()]) as? String
    }
}

/// The ids of the loaded projects and small works, by collection, for `jobCollectionForJobId`. `ProjectStore` keeps
/// it current (`JobAccessContext.updateJobs`). App plumbing, not a rule.
nonisolated enum BookingJobCollectionContext {
    nonisolated(unsafe) private(set) static var projectIds: [String] = []
    nonisolated(unsafe) private(set) static var smallWorkIds: [String] = []

    @MainActor static func update(_ jobs: [Project]) {
        // A loaded job's kind is the collection it was read from (`FirebaseBackend.job(fromCanonical:smallWorks:)`).
        projectIds = jobs.filter { $0.jobKind == .projects }.map(\.documentId)
        smallWorkIds = jobs.filter { $0.jobKind == .smallWorks }.map(\.documentId)
    }

    /// Organisation switch and sign-out: another company's jobs never decide this one's bookings.
    static func reset() {
        projectIds = []
        smallWorkIds = []
    }

    /// `jobCollectionForJobId` against the loaded jobs.
    static func jobCollection(forJobId jobId: String?) -> String? {
        guard let jobId, !jobId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return CanonicalBusinessEngine.jobCollectionForJobId(jobId, projects: projectIds, smallWorks: smallWorkIds)
    }

    /// `bookingJobCollectionFields` for a booking on `jobId` in `collection` (`bookings`, `managerSiteBookings`,
    /// `subcontractorBookings`).
    static func fields(collection: String, jobId: String?, locationType: String? = nil) -> [String: String] {
        CanonicalBusinessEngine.bookingJobCollectionFields(
            collection: collection,
            jobCollection: jobCollection(forJobId: jobId),
            locationType: locationType
        )
    }
}
