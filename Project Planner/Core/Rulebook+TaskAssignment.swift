//
//  Rulebook+TaskAssignment.swift
//  Project Planner
//
//  RULEBOOK 1.35.0 §12 / §23 `tasksAssignedToViewer`: the tasks assigned to the signed-in person under every id they
//  go by (their users id, former and same-email ids, `operatives` and `managers` rows on their email), the same rule
//  Home (`homeOverviewMetrics`), My Profile (`myProfileSummary`) and web My tasks use. Swift only maps the stores into
//  plain rows (the same shape `HomeOverviewMetrics.compute` sends); it keeps no matcher of its own (guardrail 1).
//

import Foundation

extension CanonicalBusinessEngine {
    /// `tasksAssignedToViewer(input)`: the `id` of each task row the rule keeps. Nil when the script did not answer.
    nonisolated static func tasksAssignedToViewerIds(_ input: [String: Any]) -> Set<String>? {
        guard let rows = callJSON("tasksAssignedToViewer", arguments: [input]) as? [Any] else { return nil }
        return Set(rows.compactMap { ($0 as? [String: Any])?["id"] as? String })
    }
}

enum TaskAssignmentRulebook {
    /// The rulebook input for `tasksAssignedToViewer`.
    static func input(
        tasks: [ProjectTask],
        viewerId: String?,
        viewerEmail: String?,
        organizationUsers: [AppUser],
        operatives: [Operative],
        managers: [Manager]
    ) -> [String: Any] {
        func optional(_ value: String?) -> Any {
            let text = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return text.isEmpty ? NSNull() : text
        }
        return [
            "viewer": ["id": optional(viewerId), "email": optional(viewerEmail)],
            "roster": organizationUsers.map(RulebookRosterLists.levelRow),
            "operatives": operatives.map { operative -> [String: Any] in
                ["id": Booking.operativeMatchKey(for: operative.id), "email": operative.email, "isActive": operative.isActive]
            },
            "managers": managers.map { ["id": $0.id.uuidString, "email": $0.email] as [String: Any] },
            "tasks": tasks.map { task -> [String: Any] in
                [
                    "id": task.id.uuidString,
                    "assignedOperativeIds": task.assignedOperativeIds.map { Booking.operativeMatchKey(for: $0) },
                    "assignedOperativeId": task.assignedOperativeId.map { Booking.operativeMatchKey(for: $0) as Any } ?? NSNull(),
                    "assignedManagerIds": task.assignedManagerIds.map(\.uuidString),
                    "assignedManagerId": task.assignedManagerId.map { $0.uuidString as Any } ?? NSNull(),
                ]
            },
        ]
    }

    /// The tasks of `tasks` assigned to the viewer, in their order. Script silent: none (never a guess).
    static func assignedTasks(
        _ tasks: [ProjectTask],
        viewer: AppUser?,
        organizationUsers: [AppUser],
        operatives: [Operative],
        managers: [Manager]
    ) -> [ProjectTask] {
        guard let viewer, !tasks.isEmpty else { return [] }
        let payload = input(
            tasks: tasks,
            viewerId: viewer.id,
            viewerEmail: viewer.email,
            organizationUsers: organizationUsers,
            operatives: operatives,
            managers: managers
        )
        guard let ids = CanonicalBusinessEngine.tasksAssignedToViewerIds(payload) else { return [] }
        return tasks.filter { ids.contains($0.id.uuidString) }
    }

    /// One task: whether it is assigned to the viewer.
    static func isAssigned(
        _ task: ProjectTask,
        viewer: AppUser?,
        organizationUsers: [AppUser],
        operatives: [Operative],
        managers: [Manager]
    ) -> Bool {
        !assignedTasks([task], viewer: viewer, organizationUsers: organizationUsers, operatives: operatives, managers: managers).isEmpty
    }
}
