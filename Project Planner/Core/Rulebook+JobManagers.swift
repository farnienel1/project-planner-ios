//
//  Rulebook+JobManagers.swift
//  Project Planner
//
//  Rulebook 1.30.3 (docs/RULEBOOK.md §11): the project and small-works manager picker. Web
//  `lib/canonical/jobManagers.ts`, called through `CanonicalBusinessEngine`:
//    - `jobManagerCandidates(roster)`: who can be picked (active admins, super admins and managers, one per person;
//      never an operative, an inactive person, an invite not accepted yet or an anonymised deleted profile);
//    - `jobManagerAssignments(job, roster, catalogue)`: how each manager stored on the job reads now (`current`,
//      `former` with `JOB_MANAGER_FORMER_NOTES`, or `unknown`).
//  Nothing is decided here: the screens pass inputs and show the answer.
//

import Foundation

/// One `jobManagerCandidates` row.
nonisolated struct RulebookJobManagerCandidate: Equatable, Sendable {
    var id: String
    var userIds: [String]
    var email: String
    var name: String
    var level: String

    init?(_ raw: Any?) {
        guard let row = raw as? [String: Any], let id = row["id"] as? String else { return nil }
        self.id = id
        userIds = (row["userIds"] as? [Any])?.compactMap { $0 as? String } ?? [id]
        email = row["email"] as? String ?? ""
        name = row["name"] as? String ?? ""
        level = row["level"] as? String ?? "manager"
    }
}

/// One `jobManagerAssignments` row.
nonisolated struct RulebookJobManagerAssignment: Equatable, Sendable {
    enum State: String, Sendable { case current, former, unknown }

    var storedId: String
    var state: State
    var candidate: RulebookJobManagerCandidate?
    var name: String
    var reason: String?
    var note: String?

    init?(_ raw: Any?) {
        guard let row = raw as? [String: Any], let storedId = row["storedId"] as? String else { return nil }
        self.storedId = storedId
        state = State(rawValue: row["state"] as? String ?? "") ?? .unknown
        candidate = RulebookJobManagerCandidate(row["candidate"])
        name = row["name"] as? String ?? ""
        reason = row["reason"] as? String
        note = row["note"] as? String
    }
}

extension CanonicalBusinessEngine {
    /// `jobManagerCandidates(roster)`. Nil when the script did not answer.
    nonisolated static func jobManagerCandidates(roster: [[String: Any]]) -> [RulebookJobManagerCandidate]? {
        guard let rows = callJSON("jobManagerCandidates", arguments: [roster]) as? [Any] else { return nil }
        return rows.compactMap { RulebookJobManagerCandidate($0) }
    }

    /// `jobManagerAssignments(job, roster, catalogue)`. Nil when the script did not answer.
    nonisolated static func jobManagerAssignments(
        job: [String: Any],
        roster: [[String: Any]],
        catalogue: [[String: Any]]
    ) -> [RulebookJobManagerAssignment]? {
        guard let rows = callJSON("jobManagerAssignments", arguments: [job, roster, catalogue]) as? [Any] else { return nil }
        return rows.compactMap { RulebookJobManagerAssignment($0) }
    }

    /// `JOB_MANAGER_NO_CANDIDATES_MESSAGE`: the picker's empty state when nobody can be picked.
    nonisolated static var jobManagerNoCandidatesMessage: String {
        constant("JOB_MANAGER_NO_CANDIDATES_MESSAGE", as: String.self)
            ?? "No managers or admins yet. Invite a manager from Manage users, then return here."
    }
}

/// The inputs the job-manager rules read, built from the app's models.
@MainActor
enum JobManagerRulebook {
    /// A users document as `jobManagerCandidates` reads it: the line-manager roster row plus the invite `status`.
    static func row(_ user: AppUser) -> [String: Any] {
        var row = LineManagerRulebook.row(user)
        if let status = user.status { row["status"] = status }
        return row
    }

    static func roster(_ users: [AppUser]) -> [[String: Any]] {
        users.map { row($0) }
    }

    /// `organizations/{orgId}/managers` rows (`JobManagerCatalogueRow`), by their stored document id.
    static func catalogue(_ managers: [Manager]) -> [[String: Any]] {
        managers.map { manager -> [String: Any] in
            [
                "id": manager.firestoreDocumentId,
                "email": manager.email,
                "firstName": manager.firstName,
                "lastName": manager.lastName,
                "isActive": manager.isActive,
            ]
        }
    }

    /// The job's stored manager fields (`managerIds`, `managerId`) in stored spelling. `managerUserIds` is left out:
    /// it is derived from the same managers and recomputed by every save.
    static func job(_ project: Project) -> [String: Any] {
        var fields: [String: Any] = ["managerIds": project.allAssignedManagerIds.map { project.storedManagerId(for: $0) }]
        if let managerId = project.managerId { fields["managerId"] = project.storedManagerId(for: managerId) }
        return fields
    }
}
