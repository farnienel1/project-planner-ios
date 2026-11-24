import XCTest
@testable import Project_Planner

/// RULEBOOK 1.89.0 §34 (the owner's Tasks pack, bugs B4–B11 and F1–F25): every task word, tab, action and permission on
/// iOS comes from the packed script (`TaskRulebook`), and the screens keep no copy of their own. The rules themselves
/// are tested on web (`lib/canonical/taskRules.test.ts`) and in the shared parity fixture ("Tasks 1.89.0:" cases, run
/// here by `CanonicalParityFixtureTests`); these tests check the Swift mapping in and out.
@MainActor
final class TasksRulebookTests: XCTestCase {
    private let london = "Europe/London"

    private func day(_ key: String) -> Date {
        let parts = key.split(separator: "-").compactMap { Int($0) }
        var components = DateComponents()
        components.year = parts[0]
        components.month = parts[1]
        components.day = parts[2]
        components.hour = 12
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: london)!
        return calendar.date(from: components)!
    }

    private func task(
        status: ProjectTask.Status = .todo,
        priority: ProjectTask.Priority = .normal,
        due: String? = nil,
        title: String = "Fit board",
        items: [ProjectTaskItem] = [],
        ticked: [UUID] = []
    ) -> ProjectTask {
        ProjectTask(
            projectId: UUID(),
            title: title,
            createdBy: "Test Admin",
            dueDate: due.map(day),
            priority: priority,
            status: status,
            items: items,
            completedItemIds: ticked
        )
    }

    private let admin = CanonicalBusinessEngine.CanonicalStaffAccountRole(isSuperAdmin: false, isAdmin: true, isManager: false, isOperativeMode: false)
    private let manager = CanonicalBusinessEngine.CanonicalStaffAccountRole(isSuperAdmin: false, isAdmin: false, isManager: true, isOperativeMode: false)
    private let operative = CanonicalBusinessEngine.CanonicalStaffAccountRole(isSuperAdmin: false, isAdmin: false, isManager: false, isOperativeMode: true)

    // B5, B6: one set of words.
    func testStatusAndPriorityWords() {
        XCTAssertEqual(TaskRulebook.statusLabel(.todo), "To do")
        XCTAssertEqual(TaskRulebook.statusLabel(.inProgress), "In progress")
        XCTAssertEqual(TaskRulebook.statusLabel(.completed), "Completed")
        XCTAssertEqual(TaskRulebook.priorityLabel(.normal), "Normal")
        XCTAssertEqual(TaskRulebook.priorityLabel(.urgent), "Urgent")
    }

    // B10, F6: due dates in words on the organisation day.
    func testDueWords() {
        let now = day("2026-11-24")
        XCTAssertEqual(TaskRulebook.dueText(task(), now: now, timeZone: london).label, "No due date")
        let late = TaskRulebook.dueText(task(due: "2026-11-21"), now: now, timeZone: london)
        XCTAssertEqual(late.label, "3 days overdue")
        XCTAssertTrue(late.overdue)
        XCTAssertEqual(late.tone, "red")
        XCTAssertEqual(TaskRulebook.dueText(task(due: "2026-11-24"), now: now, timeZone: london).label, "Due today")
        XCTAssertFalse(TaskRulebook.dueText(task(status: .completed, due: "2026-11-01"), now: now, timeZone: london).overdue)
    }

    // B13, F5: tabs and counts (an overdue task is also active).
    func testTabsAndCounts() {
        let now = day("2026-11-24")
        let rows = [
            task(due: "2026-11-21"),
            task(status: .inProgress, due: "2026-12-01"),
            task(status: .completed, due: "2026-11-01"),
        ]
        XCTAssertEqual(TaskRulebook.tabs(for: rows[0], now: now, timeZone: london), [.active, .overdue])
        let counts = TaskRulebook.tabCounts(rows, now: now)
        XCTAssertEqual(counts[.active], 2)
        XCTAssertEqual(counts[.completed], 1)
    }

    // F18: overdue first, then due date.
    func testActiveOrder() {
        let now = day("2026-11-24")
        let later = task(due: "2026-12-10", title: "Later")
        let soon = task(due: "2026-11-25", title: "Soon")
        let late = task(due: "2026-11-01", title: "Late")
        let none = task(title: "None")
        let sorted = TaskRulebook.sorted([later, none, soon, late], tab: .active, now: now, timeZone: london)
        XCTAssertEqual(sorted.map(\.title), ["Late", "Soon", "Later", "None"])
    }

    // F1, F3: Start / Complete / Reopen; Reopen goes to In progress.
    func testActions() {
        XCTAssertEqual(TaskRulebook.actions(.todo)?.primary, .start)
        XCTAssertEqual(TaskRulebook.actions(.todo)?.available, [.start, .complete])
        XCTAssertEqual(TaskRulebook.actions(.inProgress)?.primary, .complete)
        XCTAssertEqual(TaskRulebook.actions(.completed)?.primary, .reopen)
        XCTAssertEqual(TaskRulebook.actionStatus(.reopen), .inProgress)
        XCTAssertEqual(TaskRulebook.actionLabel(.start), "Start")
    }

    // 1.59 `taskCompletionFields`: completing sets who and when; reopening clears them.
    func testStatusChangeFields() throws {
        let now = day("2026-11-24")
        let done = try XCTUnwrap(TaskRulebook.applyingStatus(.completed, to: task(), by: "Sam", now: now))
        XCTAssertEqual(done.status, .completed)
        XCTAssertEqual(done.completedBy, "Sam")
        XCTAssertNotNil(done.completedAt)
        let reopened = try XCTUnwrap(TaskRulebook.applyingStatus(.inProgress, to: done, by: "Sam", now: now))
        XCTAssertEqual(reopened.status, .inProgress)
        XCTAssertNil(reopened.completedBy)
        XCTAssertNil(reopened.completedAt)
    }

    // B7: Edit offers To do / In progress only; a completed task stays completed.
    func testEditStatus() {
        XCTAssertEqual(TaskRulebook.editStatusOptions, [.todo, .inProgress])
        XCTAssertEqual(TaskRulebook.editStatus(stored: .todo, chosen: .completed), .todo)
        XCTAssertEqual(TaskRulebook.editStatus(stored: .completed, chosen: .todo), .completed)
        XCTAssertEqual(TaskRulebook.editStatus(stored: .todo, chosen: .inProgress), .inProgress)
    }

    // B4: an edit keeps ticks; ticks on removed items go; the pre-1.89 title-row id is kept.
    func testChecklistAfterEdit() {
        let a = ProjectTaskItem(title: "A")
        let b = ProjectTaskItem(title: "B")
        let gone = UUID()
        let kept = TaskRulebook.checklistAfterEdit(
            items: [a, b],
            completedItemIds: [a.id, gone, ProjectTask.primaryEffectiveLineItemId]
        )
        XCTAssertEqual(Set(kept), [a.id, ProjectTask.primaryEffectiveLineItemId])
    }

    // F2, F25: the complete step reads real items only; no row from the title.
    func testCompleteStep() {
        let none = TaskRulebook.completeStep(items: [], completedItemIds: [ProjectTask.primaryEffectiveLineItemId])
        XCTAssertFalse(none.showChecklist)
        XCTAssertTrue(none.completeEnabled)
        let a = ProjectTaskItem(title: "A")
        let b = ProjectTaskItem(title: "B")
        let half = TaskRulebook.completeStep(items: [a, b], completedItemIds: [a.id])
        XCTAssertFalse(half.completeEnabled)
        XCTAssertEqual(half.hint, "Tick 1 more to complete")
        XCTAssertTrue(TaskRulebook.completeStep(items: [a, b], completedItemIds: [a.id, b.id]).completeEnabled)
        // The model's checklist is the real items only (F25).
        let titled = task(title: "Replace fuse board")
        XCTAssertTrue(titled.effectiveItems.isEmpty)
        XCTAssertTrue(titled.allItemsTicked)
    }

    // B9 and permissions as today: staff see everyone; only admins delete; operatives act on their own tasks.
    func testAccessAndScope() {
        XCTAssertTrue(TaskRulebook.access(role: admin).canDelete)
        XCTAssertFalse(TaskRulebook.access(role: manager).canDelete)
        XCTAssertTrue(TaskRulebook.access(role: manager).canEdit)
        XCTAssertTrue(TaskRulebook.access(role: manager).seesEveryone)
        XCTAssertFalse(TaskRulebook.access(role: operative).canEdit)
        XCTAssertFalse(TaskRulebook.access(role: operative).canAct)
        XCTAssertTrue(TaskRulebook.access(role: operative, isAssignee: true).canAct)
        XCTAssertEqual(TaskRulebook.scope(role: manager, remembered: nil), .everyone)
        XCTAssertEqual(TaskRulebook.scope(role: manager, remembered: "mine"), .mine)
        XCTAssertEqual(TaskRulebook.scope(role: operative, remembered: "everyone"), .mine)
    }

    // Review of #299 (guardrail 3): the role comes from the person's level, so a legacy user with no level flag is a
    // manager and keeps seeing every task; an admin with a stray operative-mode flag stays an admin.
    func testViewerRoleFromLevel() throws {
        let legacy = AppUser(id: "u1", email: "old@x.co", organizationId: "ORG", role: .basic, permissions: UserPermissions())
        let role = try XCTUnwrap(TaskRulebook.viewerRole(legacy))
        XCTAssertTrue(role.isManager)
        XCTAssertFalse(role.isOperativeMode)
        XCTAssertTrue(TaskRulebook.access(role: role).seesEveryone)
        XCTAssertNil(TaskRulebook.viewerRole(nil))
    }

    // Review of #299: the task limits (10 files, one PDF) are the rulebook's, as on web.
    func testAttachmentLimits() {
        XCTAssertNil(TaskRulebook.attachmentRefusal(name: "a.pdf", mime: "application/pdf", sizeBytes: 1000, existingFiles: 0, existingDocuments: 0))
        XCTAssertNotNil(TaskRulebook.attachmentRefusal(name: "b.pdf", mime: "application/pdf", sizeBytes: 1000, existingFiles: 1, existingDocuments: 1))
        XCTAssertNotNil(TaskRulebook.attachmentRefusal(name: "c.jpg", mime: "image/jpeg", sizeBytes: 0, existingFiles: 10, existingDocuments: 0))
        let limit = TaskRulebook.photosAllowed(12, existingFiles: 0, existingDocuments: 0)
        XCTAssertEqual(limit.allowed, 10)
        XCTAssertNotNil(limit.refusal)
        let rules = TaskRulebook.uploadRules
        XCTAssertEqual(rules?.maxFiles, 10)
        XCTAssertEqual(rules?.upload.stallTimeoutSeconds, 45)
        XCTAssertEqual(TaskRulebook.attachmentMime(fileName: "Plan.PDF"), "application/pdf")
    }

    // B11: a missing or anonymised person reads "Removed user".
    func testRemovedUser() {
        XCTAssertEqual(TaskRulebook.assigneeDisplay(firstName: nil, lastName: nil, email: nil, exists: false).name, "Removed user")
        XCTAssertTrue(TaskRulebook.assigneeDisplay(firstName: "Deleted user", lastName: nil, email: "", exists: true).removed)
        XCTAssertEqual(TaskRulebook.assigneeDisplay(firstName: "Sam Jones", lastName: nil, email: "sam@x.co", exists: true).name, "Sam Jones")
    }

    // Issue 2: iOS keeps the camera; web has none (checked on web).
    func testAttachmentSources() {
        XCTAssertEqual(TaskRulebook.iosAttachmentSources, ["camera", "library", "files", "site_audit"])
    }

    // The words on screen come from `TASK_COPY`.
    func testCopy() {
        XCTAssertEqual(TaskRulebook.copy("complete", "saveProgress", fallback: ""), "Save progress")
        XCTAssertEqual(TaskRulebook.copy("delete", "title", values: ["title": "Fit board"], fallback: ""), "Delete Fit board?")
    }

    /// The task screens use the rulebook and no longer say "Carry out", "Done" for a status or "Medium".
    func testScreensUseTheRulebook() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let detail = try String(contentsOf: root.appendingPathComponent("Project Planner/Views/ProjectDetailView.swift"), encoding: .utf8)
        let hub = try String(contentsOf: root.appendingPathComponent("Project Planner/Views/TasksDetailView.swift"), encoding: .utf8)
        for text in [detail, hub] {
            XCTAssertFalse(text.contains("Text(\"Carry out"))
            XCTAssertFalse(text.contains("statusCapsule(text: \"Done\""))
            XCTAssertFalse(text.contains("return (\"Done\""))
            XCTAssertFalse(text.contains("return \"Medium\""))
            XCTAssertFalse(text.contains("\"No date\""))
        }
        XCTAssertTrue(detail.contains("TaskRulebook.editStatusOptions"))
        XCTAssertTrue(detail.contains("TaskRulebook.checklistAfterEdit("))
        XCTAssertTrue(detail.contains("TaskAttachmentViewerItem("))
        XCTAssertTrue(hub.contains("TaskRulebook.tabCounts("))
        // Review of #299: the role is the rulebook's (`taskViewerRole`), read from the person as shown.
        for text in [detail, hub] {
            XCTAssertFalse(text.contains("UserStore.staffAccountRole(for:)"))
        }
        let store = try String(contentsOf: root.appendingPathComponent("Project Planner/Core/ProjectTaskStore.swift"), encoding: .utf8)
        XCTAssertFalse(store.contains("func toggleTaskStatus"))
        let backend = try String(contentsOf: root.appendingPathComponent("Project Planner/FirebaseBackend.swift"), encoding: .utf8)
        XCTAssertTrue(backend.contains("putTaskData(prepared.data, path: imagePath"))
    }
}
