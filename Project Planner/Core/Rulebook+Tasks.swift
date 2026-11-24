//
//  Rulebook+Tasks.swift
//  Project Planner
//
//  RULEBOOK 1.89.0 §34 "Tasks: words, tabs, actions, the popup and uploads" (web `lib/canonical/taskRules.ts`, the
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
    private static let accessMemo = RulebookAnswerMemo<String, TaskRulebookAccess>(limit: 64)
    private static let sortMemo = RulebookAnswerMemo<String, [String]>(limit: 64)
    private static let roleMemo = RulebookAnswerMemo<String, CanonicalBusinessEngine.CanonicalStaffAccountRole>(limit: 64)

    // MARK: Plain rows

    private static func ms(_ date: Date?) -> Any {
        guard let date else { return NSNull() }
        return (date.timeIntervalSince1970 * 1000).rounded()
    }

    private static func nowMs(_ now: Date) -> Double {
        (now.timeIntervalSince1970 * 1000).rounded()
    }

    /// The fields the §34 rules read from a task.
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

    /// `taskViewerRole(user)` (review of #299, guardrail 3): the role from the person's level (`permissionLevelOf`,
    /// §11) — a legacy user with no level flag is a manager and keeps seeing every task. Read from the person as shown
    /// (`UserStore.displayUser`). Nil when the script did not answer (every task rule then allows nothing).
    static func viewerRole(_ user: AppUser?) -> CanonicalBusinessEngine.CanonicalStaffAccountRole? {
        guard let user else { return nil }
        let subject = user.permissionSubject
        guard let key = CanonicalBusinessEngine.rulebookMemoKey(subject) else { return nil }
        return roleMemo.value(for: key) {
            guard let answer = CanonicalBusinessEngine.callJSON("taskViewerRole", arguments: [subject]) as? [String: Any] else { return nil }
            func flag(_ name: String) -> Bool { (answer[name] as? NSNumber)?.boolValue ?? false }
            return CanonicalBusinessEngine.CanonicalStaffAccountRole(
                isSuperAdmin: flag("isSuperAdmin"),
                isAdmin: flag("isAdmin"),
                isManager: flag("isManager"),
                isOperativeMode: flag("isOperativeMode")
            )
        }
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
        // Script did not answer: no words (never a second copy of the rule).
        let fallback = TaskDueText(label: "", secondary: nil, tone: "grey", overdue: false)
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
        let arguments: [Any] = [rows, tab.rawValue, nowMs(now), timeZone]
        // Memoised by the exact input of the redraw (the day, not the instant, so a redraw a second later hits it).
        let memoInput: [Any] = [rows, tab.rawValue, OrganizationRulebookContext.dayKey(now), timeZone]
        guard let key = CanonicalBusinessEngine.rulebookMemoKey(memoInput),
              let ids = sortMemo.value(for: key, compute: {
                  (CanonicalBusinessEngine.callJSON("sortTasksForTab", arguments: arguments) as? [[String: Any]])?
                      .compactMap { $0["id"] as? String }
              }) else {
            return tasks
        }
        var byId: [String: ProjectTask] = [:]
        for task in tasks where byId[task.id.uuidString] == nil { byId[task.id.uuidString] = task }
        let ordered = ids.compactMap { byId[$0] }
        return ordered.count == tasks.count ? ordered : tasks
    }

    // MARK: Actions

    /// `taskActions(status)`: To do → Start (and Complete); In progress → Complete; Completed → Reopen. Nil when the
    /// script did not answer (no action is offered).
    static func actions(_ status: ProjectTask.Status) -> (primary: TaskActionKind, available: [TaskActionKind])? {
        guard let answer = CanonicalBusinessEngine.callJSON("taskActions", arguments: [status.rawValue]) as? [String: Any],
              let primary = (answer["primary"] as? String).flatMap(TaskActionKind.init(rawValue:)) else { return nil }
        let available = (answer["available"] as? [String] ?? []).compactMap(TaskActionKind.init(rawValue:))
        return (primary, available.isEmpty ? [primary] : available)
    }

    /// `TASK_ACTION_LABELS`: Start / Complete / Reopen.
    static func actionLabel(_ action: TaskActionKind) -> String {
        labelMemo.value(for: "a|\(action.rawValue)") {
            (CanonicalBusinessEngine.constant("TASK_ACTION_LABELS", as: [String: String].self))?[action.rawValue]
        } ?? action.rawValue.capitalized
    }

    /// `taskActionStatus`: the stored status an action moves to (Reopen → In progress). Nil when the script did not
    /// answer (nothing is saved).
    static func actionStatus(_ action: TaskActionKind) -> ProjectTask.Status? {
        (CanonicalBusinessEngine.callJSON("taskActionStatus", arguments: [action.rawValue]) as? String)
            .flatMap(ProjectTask.Status.init(rawValue:))
    }

    /// `taskStatusChangeFields`: the status with who completed it and when (kept when already completed, set on
    /// completing, cleared on any other status — RULEBOOK 1.59.0 `taskCompletionFields`). Returns the task to save, or
    /// nil when the script did not answer (the caller saves nothing and says so).
    static func applyingStatus(_ status: ProjectTask.Status, to task: ProjectTask, by name: String, now: Date = Date()) -> ProjectTask? {
        let completedBy: Any = task.completedBy.map { $0 as Any } ?? NSNull()
        let input: [String: Any] = ["completedAt": ms(task.completedAt), "completedBy": completedBy]
        guard let fields = CanonicalBusinessEngine.callJSON(
            "taskStatusChangeFields",
            arguments: [input, status.rawValue, ["completedBy": name, "now": nowMs(now)]]
        ) as? [String: Any],
            let next = (fields["status"] as? String).flatMap(ProjectTask.Status.init(rawValue:)) else { return nil }
        var updated = task
        updated.status = next
        updated.completedAt = (fields["completedAt"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue / 1000) }
        updated.completedBy = fields["completedBy"] as? String
        updated.updatedAt = now
        return updated
    }

    // MARK: Edit

    /// `TASK_EDIT_STATUS_OPTIONS`: Edit offers To do and In progress only (bug B7).
    static var editStatusOptions: [ProjectTask.Status] {
        // Script did not answer: no choice is offered (the status stays as stored).
        let tokens = CanonicalBusinessEngine.constant("TASK_EDIT_STATUS_OPTIONS", as: [String].self) ?? []
        return tokens.compactMap(ProjectTask.Status.init(rawValue:))
    }

    /// `taskEditStatus(stored, chosen)`: a completed task keeps Completed; otherwise the chosen status when Edit
    /// offers it. The stored status when the script did not answer.
    static func editStatus(stored: ProjectTask.Status, chosen: ProjectTask.Status) -> ProjectTask.Status {
        (CanonicalBusinessEngine.callJSON("taskEditStatus", arguments: [stored.rawValue, chosen.rawValue]) as? String)
            .flatMap(ProjectTask.Status.init(rawValue:)) ?? stored
    }

    /// `taskChecklistAfterEdit`: the ticks kept after an edit (bug B4: an edit never resets ticks; ticks on removed
    /// items go).
    static func checklistAfterEdit(items: [ProjectTaskItem], completedItemIds: [UUID]) -> [UUID] {
        let input: [String: Any] = [
            "items": items.map { ["id": $0.id.uuidString] },
            "completedItemIds": completedItemIds.map(\.uuidString),
        ]
        // Script did not answer: the ticks stay exactly as stored (never lost).
        guard let ids = CanonicalBusinessEngine.callJSON("taskChecklistAfterEdit", arguments: [input]) as? [String] else {
            return completedItemIds
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
                total: (answer["total"] as? NSNumber)?.intValue ?? 0,
                done: (answer["done"] as? NSNumber)?.intValue ?? 0,
                remaining: (answer["remaining"] as? NSNumber)?.intValue ?? 0,
                completeEnabled: (answer["completeEnabled"] as? NSNumber)?.boolValue ?? false,
                hint: answer["hint"] as? String,
                showChecklist: (answer["showChecklist"] as? NSNumber)?.boolValue ?? false
            )
        }
        // Script did not answer: never let Complete through.
        return TaskCompleteStepInfo(total: 0, done: 0, remaining: 0, completeEnabled: false, hint: nil, showChecklist: false)
    }

    // MARK: Who may do what

    /// `taskAccess(role, { isAssignee })`: staff see every task and edit any; only admins delete; anyone creates;
    /// staff and assignees act.
    static func access(role: CanonicalBusinessEngine.CanonicalStaffAccountRole?, isAssignee: Bool = false) -> TaskRulebookAccess {
        let key = role.map { "\($0.isSuperAdmin)|\($0.isAdmin)|\($0.isManager)|\($0.isOperativeMode)|\(isAssignee)" } ?? "none|\(isAssignee)"
        return accessMemo.value(for: key) {
            guard let answer = CanonicalBusinessEngine.callJSON("taskAccess", arguments: [roleRow(role), ["isAssignee": isAssignee]]) as? [String: Any] else {
                return nil
            }
            func flag(_ key: String) -> Bool { (answer[key] as? NSNumber)?.boolValue ?? false }
            return TaskRulebookAccess(
                seesEveryone: flag("seesEveryone"),
                canCreate: flag("canCreate"),
                canEdit: flag("canEdit"),
                canDelete: flag("canDelete"),
                canAct: flag("canAct")
            )
        } ?? .none
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
        // Script did not answer: no name (never a second copy of the rule).
        return ("", false)
    }

    // MARK: Attachment limits and uploads (issue 1, review of #299)

    /// The parts of `TASK_ATTACHMENT_RULES` iOS reads.
    nonisolated struct UploadRules: Decodable, Sendable {
        nonisolated struct Upload: Decodable, Sendable {
            var parallel: Int
            var stallTimeoutSeconds: Double
            var maxRetries: Int
        }

        var maxFiles: Int
        var maxDocuments: Int
        var upload: Upload
    }

    /// `TASK_ATTACHMENT_RULES`. Nil when the script did not answer (uploads are then refused, never guessed).
    nonisolated static var uploadRules: UploadRules? {
        CanonicalBusinessEngine.constant("TASK_ATTACHMENT_RULES", as: UploadRules.self)
    }

    nonisolated static let rulesNotLoadedMessage = "The app's rules did not load. Close and reopen the app, then try again."

    /// `taskAttachmentCheck`: one file against the task limits (count, type, one PDF, size). The message, or nil when
    /// the file may be added. Refused when the script did not answer.
    static func attachmentRefusal(name: String, mime: String, sizeBytes: Int, existingFiles: Int, existingDocuments: Int) -> String? {
        let input: [String: Any] = [
            "name": name,
            "mime": mime,
            "sizeBytes": sizeBytes,
            "existingFiles": existingFiles,
            "existingDocuments": existingDocuments,
        ]
        guard let answer = CanonicalBusinessEngine.callJSON("taskAttachmentCheck", arguments: [input]) as? [String: Any],
              let result = answer["result"] as? String else { return rulesNotLoadedMessage }
        return result == "ok" ? nil : (answer["message"] as? String ?? rulesNotLoadedMessage)
    }

    /// The type `taskAttachmentCheck` reads for a picked file (from its extension).
    static func attachmentMime(fileName: String) -> String {
        switch (fileName as NSString).pathExtension.lowercased() {
        case "pdf": return "application/pdf"
        case "png": return "image/png"
        case "webp": return "image/webp"
        case "heic", "heif": return "image/heic"
        case "jpg", "jpeg": return "image/jpeg"
        default: return ""
        }
    }

    /// How many of `photos` new photos may be added next to the files already there (each checked in turn with
    /// `taskAttachmentCheck`), and the refusal for the first one that may not.
    static func photosAllowed(_ photos: Int, existingFiles: Int, existingDocuments: Int) -> (allowed: Int, refusal: String?) {
        for index in 0..<photos {
            if let message = attachmentRefusal(
                name: "Photo \(index + 1)",
                mime: "image/jpeg",
                sizeBytes: 0,
                existingFiles: existingFiles + index,
                existingDocuments: existingDocuments
            ) {
                return (index, message)
            }
        }
        return (photos, nil)
    }

    /// `taskAttachmentSources("ios")`: Take photo, Photo library, Files, Site audit.
    static var iosAttachmentSources: [String] {
        CanonicalBusinessEngine.callJSON("taskAttachmentSources", arguments: ["ios"]) as? [String] ?? []
    }
}

/// A task upload made no progress for `TASK_ATTACHMENT_RULES.upload.stallTimeoutSeconds` and was cancelled (plumbing
/// for `FirebaseBackend.putTaskData`'s retry; not a rule).
nonisolated struct TaskUploadStalled: Error, Sendable {}
