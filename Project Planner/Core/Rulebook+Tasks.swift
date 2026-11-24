//
//  Rulebook+Tasks.swift
//  Project Planner
//
//  RULEBOOK 1.89.0 §32 "Tasks: words, tabs, actions, the popup and uploads" (web `lib/canonical/taskRules.ts`, the
//  owner's Tasks pack). Every task word (status, priority, due date), tab, count, sort order, action and permission
//  on iOS comes from the packed script through `CanonicalBusinessEngine.callJSON`, memoised by its exact input. Swift
//  only maps `ProjectTask` into the script's plain rows and maps the answer back (guardrail: no second calculator).
//
//  The stored task shape is unchanged (status `To Do` / `In Progress` / `Completed`, priorities Low / Normal / High /
//  Urgent, `items` + `completedItemIds`), so older builds read every task written here.
//

import Foundation

/// `TaskDueLabel`: the due date in words ("3 days overdue", "Due today", "Due Thu", "Due 28 Nov", "Completed 20 Nov",
/// "No due date") and its tone.
nonisolated struct TaskDueText: Hashable, Sendable {
    var label: String
    var secondary: String?
    /// grey | blue | green | amber | red
    var tone: String
    var overdue: Bool
}

/// `TaskActionKey`. "Carry out" is gone (RULEBOOK 1.89.0 F1).
nonisolated enum TaskActionKind: String, Hashable, Sendable, CaseIterable {
    case start, complete, reopen
}

/// `TaskTabKey`: the tabs every task list shows, in order.
nonisolated enum TaskTab: String, Hashable, Sendable, CaseIterable {
    case active, overdue, completed

    var label: String {
        switch self {
        case .active: return "Active"
        case .overdue: return "Overdue"
        case .completed: return "Completed"
        }
    }
}

/// `TaskScopeKey`: My tasks or Everyone (staff only).
nonisolated enum TaskScope: String, Hashable, Sendable, CaseIterable {
    case mine, everyone

    var label: String {
        switch self {
        case .mine: return "My tasks"
        case .everyone: return "Everyone"
        }
    }
}

/// `TaskAccess`: who may do what with a task (as the security rules allow today).
nonisolated struct TaskRulebookAccess: Hashable, Sendable {
    var seesEveryone: Bool
    var canCreate: Bool
    var canEdit: Bool
    var canDelete: Bool
    var canAct: Bool

    /// Nothing allowed: used only when the script did not answer.
    static let none = TaskRulebookAccess(seesEveryone: false, canCreate: false, canEdit: false, canDelete: false, canAct: false)
}

/// `TaskCompleteStep`: the complete step, from the task's real items only (never a row made from the title).
nonisolated struct TaskCompleteStepInfo: Hashable, Sendable {
    var total: Int
    var done: Int
    var remaining: Int
    var completeEnabled: Bool
    var hint: String?
    var showChecklist: Bool
}

@MainActor
enum TaskRulebook {
    private static let labelMemo = RulebookAnswerMemo<String, String>(limit: 64)
    private static let dueMemo = RulebookAnswerMemo<String, TaskDueText>(limit: 2048)
    private static let tabMemo = RulebookAnswerMemo<String, [String]>(limit: 2048)

    // MARK: Plain rows

    private static func ms(_ date: Date?) -> Any {
        guard let date else { return NSNull() }
        return (date.timeIntervalSince1970 * 1000).rounded()
    }

    private static func nowMs(_ now: Date) -> Double {
        (now.timeIntervalSince1970 * 1000).rounded()
    }

    /// The fields the §32 rules read from a task.
    static func row(_ task: ProjectTask) -> [String: Any] {
        [
            "id": task.id.uuidString,
            "title": task.title,
            "status": task.status.rawValue,
            "priority": task.priority.rawValue,
            "dueDate": ms(task.dueDate),
            "completedAt": ms(task.completedAt),
            "updatedAt": ms(task.updatedAt),
            "items": task.items.map { ["id": $0.id.uuidString, "title": $0.title] },
            "completedItemIds": task.completedItemIds.map(\.uuidString),
        ]
    }

    static func roleRow(_ role: CanonicalBusinessEngine.CanonicalStaffAccountRole?) -> Any {
        guard let role else { return NSNull() }
        return [
            "isSuperAdmin": role.isSuperAdmin,
            "isAdmin": role.isAdmin,
            "isManager": role.isManager,
            "isOperativeMode": role.isOperativeMode,
        ]
    }

    // MARK: Words

    /// `taskStatusLabel`: "To do" / "In progress" / "Completed" — never "Done" (bug B6).
    static func statusLabel(_ status: ProjectTask.Status) -> String {
        labelMemo.value(for: "s|\(status.rawValue)") {
            CanonicalBusinessEngine.callJSON("taskStatusLabel", arguments: [status.rawValue]) as? String
        } ?? status.rawValue
    }

    /// `taskPriorityLabel`: Low / Normal / High / Urgent — never "Medium" (bug B5).
    static func priorityLabel(_ priority: ProjectTask.Priority) -> String {
        labelMemo.value(for: "p|\(priority.rawValue)") {
            CanonicalBusinessEngine.callJSON("taskPriorityLabel", arguments: [priority.rawValue]) as? String
        } ?? priority.rawValue
    }

    /// `taskPriorityTone`: grey | blue | amber | red.
    static func priorityTone(_ priority: ProjectTask.Priority) -> String {
        labelMemo.value(for: "pt|\(priority.rawValue)") {
            CanonicalBusinessEngine.callJSON("taskPriorityTone", arguments: [priority.rawValue]) as? String
        } ?? "grey"
    }

    /// `taskDueLabel(task, nowMs, timeZone)` on the organisation day (never the phone's). Bug B10: "No due date".
    static func dueText(
        _ task: ProjectTask,
        now: Date = Date(),
        timeZone: String = OrganizationRulebookContext.timeZoneIdentifier
    ) -> TaskDueText {
        let today = OrganizationRulebookContext.dayKey(now)
        let key = "\(task.status.rawValue)|\(ms(task.dueDate))|\(ms(task.completedAt))|\(today)|\(timeZone)"
        let fallback = TaskDueText(label: task.dueDate == nil ? "No due date" : "", secondary: nil, tone: "grey", overdue: false)
        return dueMemo.value(for: key) {
            let input: [String: Any] = ["status": task.status.rawValue, "dueDate": ms(task.dueDate), "completedAt": ms(task.completedAt)]
            guard let answer = CanonicalBusinessEngine.callJSON("taskDueLabel", arguments: [input, nowMs(now), timeZone]) as? [String: Any],
                  let label = answer["label"] as? String else { return nil }
            return TaskDueText(
                label: label,
                secondary: answer["secondary"] as? String,
                tone: answer["tone"] as? String ?? "grey",
                overdue: (answer["overdue"] as? NSNumber)?.boolValue ?? false
            )
        } ?? fallback
    }

    // MARK: Tabs, counts, order

    /// `taskTabKeys`: an overdue task is under Active and Overdue.
    static func tabs(
        for task: ProjectTask,
        now: Date = Date(),
        timeZone: String = OrganizationRulebookContext.timeZoneIdentifier
    ) -> Set<TaskTab> {
        let today = OrganizationRulebookContext.dayKey(now)
        let key = "\(task.status.rawValue)|\(ms(task.dueDate))|\(today)|\(timeZone)"
        let keys = tabMemo.value(for: key) {
            let input: [String: Any] = ["status": task.status.rawValue, "dueDate": ms(task.dueDate)]
            return CanonicalBusinessEngine.callJSON("taskTabKeys", arguments: [input, nowMs(now), timeZone]) as? [String]
        } ?? []
        return Set(keys.compactMap(TaskTab.init(rawValue:)))
    }

    /// `taskTabCounts`: one count per tab (Active and Overdue overlap on purpose), the same definitions as Home and
    /// the job tile.
    static func tabCounts(_ tasks: [ProjectTask], now: Date = Date()) -> [TaskTab: Int] {
        var counts: [TaskTab: Int] = [.active: 0, .overdue: 0, .completed: 0]
        for task in tasks {
            for tab in tabs(for: task, now: now) { counts[tab, default: 0] += 1 }
        }
        return counts
    }

    /// `sortTasksForTab`: overdue first, then due date, then priority, then title; Completed newest first. The given
    /// tasks in the script's order (unchanged order when the script did not answer).
    static func sorted(
        _ tasks: [ProjectTask],
        tab: TaskTab,
        now: Date = Date(),
        timeZone: String = OrganizationRulebookContext.timeZoneIdentifier
    ) -> [ProjectTask] {
        guard tasks.count > 1 else { return tasks }
        let rows = tasks.map(row)
        guard let answer = CanonicalBusinessEngine.callJSON("sortTasksForTab", arguments: [rows, tab.rawValue, nowMs(now), timeZone]) as? [[String: Any]] else {
            return tasks
        }
        var byId: [String: ProjectTask] = [:]
        for task in tasks where byId[task.id.uuidString] == nil { byId[task.id.uuidString] = task }
        let ordered = answer.compactMap { ($0["id"] as? String).flatMap { byId[$0] } }
        return ordered.count == tasks.count ? ordered : tasks
    }

    // MARK: Actions

    /// `taskActions(status)`: To do → Start (and Complete); In progress → Complete; Completed → Reopen.
    static func actions(_ status: ProjectTask.Status) -> (primary: TaskActionKind, available: [TaskActionKind]) {
        if let answer = CanonicalBusinessEngine.callJSON("taskActions", arguments: [status.rawValue]) as? [String: Any],
           let primary = (answer["primary"] as? String).flatMap(TaskActionKind.init(rawValue:)) {
            let available = (answer["available"] as? [String] ?? []).compactMap(TaskActionKind.init(rawValue:))
            return (primary, available.isEmpty ? [primary] : available)
        }
        switch status {
        case .completed: return (.reopen, [.reopen])
        case .inProgress: return (.complete, [.complete])
        case .todo: return (.start, [.start, .complete])
        }
    }

    /// `TASK_ACTION_LABELS`: Start / Complete / Reopen.
    static func actionLabel(_ action: TaskActionKind) -> String {
        labelMemo.value(for: "a|\(action.rawValue)") {
            (CanonicalBusinessEngine.constant("TASK_ACTION_LABELS", as: [String: String].self))?[action.rawValue]
        } ?? action.rawValue.capitalized
    }

    /// `taskActionStatus`: the stored status an action moves to (Reopen → In progress).
    static func actionStatus(_ action: TaskActionKind) -> ProjectTask.Status {
        if let token = CanonicalBusinessEngine.callJSON("taskActionStatus", arguments: [action.rawValue]) as? String,
           let status = ProjectTask.Status(rawValue: token) {
            return status
        }
        return action == .complete ? .completed : .inProgress
    }

    /// `taskStatusChangeFields`: the status with who completed it and when (kept when already completed, set on
    /// completing, cleared on any other status — RULEBOOK 1.59.0 `taskCompletionFields`). Returns the task to save.
    static func applyingStatus(_ status: ProjectTask.Status, to task: ProjectTask, by name: String, now: Date = Date()) -> ProjectTask {
        var updated = task
        let completedBy: Any = task.completedBy.map { $0 as Any } ?? NSNull()
        let input: [String: Any] = ["completedAt": ms(task.completedAt), "completedBy": completedBy]
        let fields = CanonicalBusinessEngine.callJSON(
            "taskStatusChangeFields",
            arguments: [input, status.rawValue, ["completedBy": name, "now": nowMs(now)]]
        ) as? [String: Any]
        updated.status = (fields?["status"] as? String).flatMap(ProjectTask.Status.init(rawValue:)) ?? status
        if let fields {
            if let at = fields["completedAt"] as? NSNumber {
                updated.completedAt = Date(timeIntervalSince1970: at.doubleValue / 1000)
            } else {
                updated.completedAt = nil
            }
            updated.completedBy = fields["completedBy"] as? String
        } else if status == .completed {
            updated.completedAt = task.completedAt ?? now
            updated.completedBy = task.completedBy ?? name
        } else {
            updated.completedAt = nil
            updated.completedBy = nil
        }
        updated.updatedAt = now
        return updated
    }

    // MARK: Edit

    /// `TASK_EDIT_STATUS_OPTIONS`: Edit offers To do and In progress only (bug B7).
    static var editStatusOptions: [ProjectTask.Status] {
        let tokens = CanonicalBusinessEngine.constant("TASK_EDIT_STATUS_OPTIONS", as: [String].self) ?? []
        let statuses = tokens.compactMap(ProjectTask.Status.init(rawValue:))
        return statuses.isEmpty ? [.todo, .inProgress] : statuses
    }

    /// `taskEditStatus(stored, chosen)`: a completed task keeps Completed; otherwise the chosen status when Edit
    /// offers it.
    static func editStatus(stored: ProjectTask.Status, chosen: ProjectTask.Status) -> ProjectTask.Status {
        (CanonicalBusinessEngine.callJSON("taskEditStatus", arguments: [stored.rawValue, chosen.rawValue]) as? String)
            .flatMap(ProjectTask.Status.init(rawValue:)) ?? (stored == .completed ? .completed : chosen)
    }

    /// `taskChecklistAfterEdit`: the ticks kept after an edit (bug B4: an edit never resets ticks; ticks on removed
    /// items go).
    static func checklistAfterEdit(items: [ProjectTaskItem], completedItemIds: [UUID]) -> [UUID] {
        let input: [String: Any] = [
            "items": items.map { ["id": $0.id.uuidString] },
            "completedItemIds": completedItemIds.map(\.uuidString),
        ]
        guard let ids = CanonicalBusinessEngine.callJSON("taskChecklistAfterEdit", arguments: [input]) as? [String] else {
            let keep = Set(items.map(\.id))
            return completedItemIds.filter { keep.contains($0) }
        }
        return ids.compactMap(UUID.init(uuidString:))
    }

    // MARK: Complete step

    /// `taskCompleteStep`: Complete needs every real item ticked; Save progress is always offered.
    static func completeStep(items: [ProjectTaskItem], completedItemIds: [UUID]) -> TaskCompleteStepInfo {
        let input: [String: Any] = [
            "items": items.map { ["id": $0.id.uuidString] },
            "completedItemIds": completedItemIds.map(\.uuidString),
        ]
        if let answer = CanonicalBusinessEngine.callJSON("taskCompleteStep", arguments: [input]) as? [String: Any] {
            return TaskCompleteStepInfo(
                total: (answer["total"] as? NSNumber)?.intValue ?? items.count,
                done: (answer["done"] as? NSNumber)?.intValue ?? 0,
                remaining: (answer["remaining"] as? NSNumber)?.intValue ?? 0,
                completeEnabled: (answer["completeEnabled"] as? NSNumber)?.boolValue ?? false,
                hint: answer["hint"] as? String,
                showChecklist: (answer["showChecklist"] as? NSNumber)?.boolValue ?? !items.isEmpty
            )
        }
        // Script did not answer: never let Complete through.
        return TaskCompleteStepInfo(total: items.count, done: 0, remaining: items.count, completeEnabled: false, hint: nil, showChecklist: !items.isEmpty)
    }

    // MARK: Who may do what

    /// `taskAccess(role, { isAssignee })`: staff see every task and edit any; only admins delete; anyone creates;
    /// staff and assignees act.
    static func access(role: CanonicalBusinessEngine.CanonicalStaffAccountRole?, isAssignee: Bool = false) -> TaskRulebookAccess {
        guard let answer = CanonicalBusinessEngine.callJSON("taskAccess", arguments: [roleRow(role), ["isAssignee": isAssignee]]) as? [String: Any] else {
            return .none
        }
        func flag(_ key: String) -> Bool { (answer[key] as? NSNumber)?.boolValue ?? false }
        return TaskRulebookAccess(
            seesEveryone: flag("seesEveryone"),
            canCreate: flag("canCreate"),
            canEdit: flag("canEdit"),
            canDelete: flag("canDelete"),
            canAct: flag("canAct")
        )
    }

    /// `taskScopeFor(role, remembered)`: a remembered scope only when the viewer may have it; else the default for the
    /// role (`taskDefaultScope`: staff Everyone, operatives My tasks — bug B9).
    static func scope(role: CanonicalBusinessEngine.CanonicalStaffAccountRole?, remembered: String?) -> TaskScope {
        let rememberedValue: Any = remembered.map { $0 as Any } ?? NSNull()
        return (CanonicalBusinessEngine.callJSON("taskScopeFor", arguments: [roleRow(role), rememberedValue]) as? String)
            .flatMap(TaskScope.init(rawValue:)) ?? .mine
    }

    // MARK: Words on screen

    /// The `TASK_COPY` sections iOS reads (unknown sections are ignored).
    nonisolated private struct CopyFile: Decodable, Sendable {
        var form: [String: String]
        var detail: [String: String]
        var complete: [String: String]
        var delete: [String: String]
        var toasts: [String: String]
        var errors: [String: String]
    }

    private static var copyCache: [String: [String: String]]?

    /// `TASK_COPY[section][key]` (with `{name}`-style holes filled), the same words web shows.
    static func copy(_ section: String, _ key: String, values: [String: String] = [:], fallback: String) -> String {
        if copyCache == nil, let file = CanonicalBusinessEngine.constant("TASK_COPY", as: CopyFile.self) {
            copyCache = [
                "form": file.form, "detail": file.detail, "complete": file.complete,
                "delete": file.delete, "toasts": file.toasts, "errors": file.errors,
            ]
        }
        var text = copyCache?[section]?[key] ?? fallback
        for (name, value) in values { text = text.replacingOccurrences(of: "{\(name)}", with: value) }
        return text
    }

    // MARK: Assignees and attachments

    /// `TASK_REMOVED_USER_LABEL` (bug B11).
    static var removedUserLabel: String {
        CanonicalBusinessEngine.constant("TASK_REMOVED_USER_LABEL", as: String.self) ?? "Removed user"
    }

    /// `taskAssigneeDisplay(row)`: a missing row or an anonymised deleted profile reads "Removed user".
    static func assigneeDisplay(firstName: String?, lastName: String?, email: String?, exists: Bool) -> (name: String, removed: Bool) {
        let row: Any
        if exists {
            row = ["firstName": firstName ?? "", "lastName": lastName ?? "", "email": email ?? ""] as [String: Any]
        } else {
            row = NSNull()
        }
        if let answer = CanonicalBusinessEngine.callJSON("taskAssigneeDisplay", arguments: [row]) as? [String: Any],
           let name = answer["name"] as? String {
            return (name, (answer["removed"] as? NSNumber)?.boolValue ?? false)
        }
        return exists ? ("\(firstName ?? "") \(lastName ?? "")".trimmingCharacters(in: .whitespaces), false) : (removedUserLabel, true)
    }

    /// `taskAttachmentSources("ios")`: Take photo, Photo library, Files, Site audit.
    static var iosAttachmentSources: [String] {
        CanonicalBusinessEngine.callJSON("taskAttachmentSources", arguments: ["ios"]) as? [String] ?? []
    }
}
