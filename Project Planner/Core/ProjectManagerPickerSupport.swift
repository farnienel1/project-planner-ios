//
//  ProjectManagerPickerSupport.swift
//  Project Planner
//
//  Project / small-works manager picker including admins and super admins.
//

import Foundation

/// One manager stored on a job as the picker shows it (`jobManagerAssignments`, RULEBOOK 1.30.3 §11).
struct ProjectManagerAssignmentRow: Equatable {
    var manager: Manager
    var state: RulebookJobManagerAssignment.State
    /// `JOB_MANAGER_FORMER_NOTES[reason]` beside a former manager; nil when current or unknown.
    var note: String?
}

@MainActor
enum ProjectManagerPickerSupport {
    /// RULEBOOK 1.30.3 §11 `jobManagerCandidates(roster)`: who can be added, as `Manager` rows, less those already on
    /// the job. A candidate is their `managers` catalogue row when one is on their email, else a row with the stable id
    /// of that email (saved to the catalogue on first use). Empty when the script did not answer.
    static func availableManagers(
        operativeStore: OperativeStore,
        userStore: UserStore,
        excluding selected: [Manager]
    ) -> [Manager] {
        let candidates = CanonicalBusinessEngine.jobManagerCandidates(
            roster: JobManagerRulebook.roster(userStore.organizationUsers)
        ) ?? []
        return availableManagers(candidates: candidates, catalogue: operativeStore.allManagers, excluding: selected)
    }

    /// True when `jobManagerCandidates` has nobody (the picker shows `JOB_MANAGER_NO_CANDIDATES_MESSAGE`).
    static func hasNoCandidates(userStore: UserStore) -> Bool {
        CanonicalBusinessEngine.jobManagerCandidates(roster: JobManagerRulebook.roster(userStore.organizationUsers))?.isEmpty ?? false
    }

    /// The candidates as `Manager` rows, less anyone already selected (by id, or by a non-empty email).
    static func availableManagers(
        candidates: [RulebookJobManagerCandidate],
        catalogue: [Manager],
        excluding selected: [Manager]
    ) -> [Manager] {
        let selectedIds = Set(selected.map(\.id))
        let selectedEmails = Set(selected.map { StaffEmailIdentity.emailKey($0.email) }.filter { !$0.isEmpty })
        var output: [Manager] = []
        for candidate in candidates {
            let email = StaffEmailIdentity.emailKey(candidate.email)
            if !email.isEmpty, selectedEmails.contains(email) { continue }
            let candidateIds = Set(candidate.userIds.map { WorkDocumentKeys.inAppId(for: $0) })
            if !candidateIds.isDisjoint(with: selectedIds) { continue }
            let manager = manager(for: candidate, catalogue: catalogue)
            if selectedIds.contains(manager.id) { continue }
            output.append(manager)
        }
        return output
    }

    /// A candidate as a `Manager`: the catalogue row on their email (active first), else a new row keyed by the stable
    /// id of the email. With no email the row is keyed by the user id and is never saved to the catalogue.
    static func manager(for candidate: RulebookJobManagerCandidate, catalogue: [Manager]) -> Manager {
        let email = StaffEmailIdentity.emailKey(candidate.email)
        let parts = splitName(candidate.name, fallback: candidate.email)
        guard !email.isEmpty else {
            return Manager(id: WorkDocumentKeys.inAppId(for: candidate.id), firstName: parts.first, lastName: parts.last, email: "", mobileNumber: "")
        }
        let onEmail = catalogue.filter { StaffEmailIdentity.emailKey($0.email) == email }
        if let row = onEmail.first(where: \.isActive) ?? onEmail.first { return row }
        return Manager(
            id: stableManagerId(email: email),
            firstName: parts.first,
            lastName: parts.last,
            email: candidate.email.trimmingCharacters(in: .whitespacesAndNewlines),
            mobileNumber: "",
            isActive: true
        )
    }

    /// RULEBOOK 1.30.3 §11 `jobManagerAssignments(job, roster, catalogue)`: each manager stored on the job, in stored
    /// order, keyed by the in-app id of its stored id so a save writes every kept id back exactly as stored. A former
    /// manager carries the rulebook note; an unknown id (nobody loaded matches) is kept with no name and no email.
    static func assignedManagers(
        for project: Project,
        operativeStore: OperativeStore,
        userStore: UserStore
    ) -> [ProjectManagerAssignmentRow] {
        let assignments = CanonicalBusinessEngine.jobManagerAssignments(
            job: JobManagerRulebook.job(project),
            roster: JobManagerRulebook.roster(userStore.organizationUsers),
            catalogue: JobManagerRulebook.catalogue(operativeStore.allManagers)
        )
        return assignedManagers(for: project, assignments: assignments, catalogue: operativeStore.allManagers)
    }

    static func assignedManagers(
        for project: Project,
        assignments: [RulebookJobManagerAssignment]?,
        catalogue: [Manager]
    ) -> [ProjectManagerAssignmentRow] {
        var inAppByStored: [String: UUID] = [:]
        for id in project.allAssignedManagerIds {
            let stored = project.storedManagerId(for: id).lowercased()
            if inAppByStored[stored] == nil { inAppByStored[stored] = id }
        }
        guard let assignments else {
            // Script silent: every stored id is kept as stored, named from the catalogue when its row is loaded.
            var seen = Set<UUID>()
            return project.allAssignedManagerIds.compactMap { id in
                guard seen.insert(id).inserted else { return nil }
                let manager = catalogue.first { $0.id == id }
                    ?? Manager(id: id, firstName: "", lastName: "", email: "", mobileNumber: "")
                return ProjectManagerAssignmentRow(manager: manager, state: .unknown, note: nil)
            }
        }
        var seen = Set<UUID>()
        return assignments.compactMap { assignment in
            let stored = assignment.storedId.trimmingCharacters(in: .whitespacesAndNewlines)
            let id = inAppByStored[stored.lowercased()] ?? WorkDocumentKeys.inAppId(for: stored)
            guard seen.insert(id).inserted else { return nil }
            let manager: Manager
            if let row = catalogue.first(where: { $0.id == id }) {
                manager = row
            } else {
                let parts = splitName(assignment.candidate?.name ?? assignment.name, fallback: assignment.candidate?.email ?? "")
                manager = Manager(
                    id: id,
                    firstName: parts.first,
                    lastName: parts.last,
                    email: assignment.candidate?.email ?? "",
                    mobileNumber: ""
                )
            }
            return ProjectManagerAssignmentRow(manager: manager, state: assignment.state, note: assignment.note)
        }
    }

    /// Before a job save: a manager already stored on the job (`storedIds`) is kept exactly as stored, resolved or
    /// not. A newly picked manager is its catalogue row (by id, then by a non-empty email); a new catalogue row is
    /// created only for a manager with an email. A manager row with no email is never created, and an empty email
    /// never matches another row (that repointed jobs at a junk row).
    static func resolveManagersForSave(
        _ managers: [Manager],
        keepingStored storedIds: Set<UUID> = [],
        operativeStore: OperativeStore
    ) async -> [Manager] {
        var resolved: [Manager] = []
        for manager in managers {
            if storedIds.contains(manager.id) {
                resolved.append(manager)
                continue
            }
            if let existing = operativeStore.allManagers.first(where: { $0.id == manager.id }) {
                resolved.append(existing)
                continue
            }
            let email = StaffEmailIdentity.emailKey(manager.email)
            guard !email.isEmpty else {
                resolved.append(manager)
                continue
            }
            if let existing = operativeStore.allManagers.first(where: { StaffEmailIdentity.emailKey($0.email) == email }) {
                resolved.append(existing)
                continue
            }
            await operativeStore.addManager(manager)
            resolved.append(
                operativeStore.allManagers.first { StaffEmailIdentity.emailKey($0.email) == email } ?? manager
            )
        }
        return resolved
    }

    private static func splitName(_ name: String, fallback: String) -> (first: String, last: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let value = trimmed.isEmpty ? fallback.trimmingCharacters(in: .whitespacesAndNewlines) : trimmed
        guard let space = value.firstIndex(of: " ") else { return (value, "") }
        return (String(value[..<space]), String(value[value.index(after: space)...]).trimmingCharacters(in: .whitespaces))
    }

    /// Stable id so admins who are not on the manager roster keep the same identity across picker refreshes and saves.
    nonisolated static func stableManagerId(email: String) -> UUID {
        let seed = "pp.manager.\(email.lowercased().trimmingCharacters(in: .whitespacesAndNewlines))"
        var bytes = [UInt8](repeating: 0, count: 16)
        let data = Array(seed.utf8)
        for (index, byte) in data.enumerated() {
            bytes[index % 16] ^= byte
            bytes[(index &* 7) % 16] &+= byte
        }
        bytes[6] = (bytes[6] & 0x0F) | 0x40
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }
}
