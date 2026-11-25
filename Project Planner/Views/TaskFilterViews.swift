//
//  TaskFilterViews.swift
//  Project Planner
//
//  RULEBOOK 1.91.0 §34 (owner 25 Nov, decision B): the Tasks filter sheet (project, small works, who assigned it,
//  assigned to, priority, due) and the active-filter chips with ✕ and Clear all. The options and counts come from
//  `taskFilterOptions`; the filtering from `filterTasks` (TaskViewingRulebook). Layout only.
//

import SwiftUI

struct TaskFilterSheet: View {
    @Binding var filters: TaskFilterSet
    let options: (projects: [TaskFilterChoice], smallWorks: [TaskFilterChoice], creators: [TaskFilterChoice])
    /// A job's own Tasks tab has no project / small works filter.
    var showsJobFilters: Bool = true
    var assignees: [TaskFilterChoice] = []

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                if showsJobFilters {
                    choicePicker("Project", selection: $filters.projectId, choices: options.projects, anyLabel: "All projects")
                    choicePicker("Small works", selection: $filters.smallWorksId, choices: options.smallWorks, anyLabel: "All small works")
                }
                choicePicker("Assigned by", selection: $filters.creatorKey, choices: options.creators, anyLabel: "Anyone")
                choicePicker("Assigned to", selection: $filters.assigneeKey, choices: assignees, anyLabel: "Anyone")
                Section("Priority") {
                    Picker("Priority", selection: $filters.priority) {
                        Text("Any priority").tag("")
                        ForEach(ProjectTask.Priority.allCases, id: \.self) { priority in
                            Text(TaskRulebook.priorityLabel(priority)).tag(priority.rawValue)
                        }
                    }
                    .accessibilityIdentifier("taskFilter.priority")
                }
                Section("Due") {
                    Picker("Due", selection: $filters.due) {
                        Text("Any time").tag("")
                        ForEach(TaskViewingRulebook.dueFilterChoices(), id: \.choice) { row in
                            Text(row.label).tag(row.choice.rawValue)
                        }
                    }
                    .accessibilityIdentifier("taskFilter.due")
                }
                if TaskViewingRulebook.activeFilterCount(filters) > 0 {
                    Section {
                        Button("Clear all", role: .destructive) { filters = .none }
                            .accessibilityIdentifier("taskFilter.clearAll")
                    }
                }
            }
            .navigationTitle("Filters")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .accessibilityIdentifier("taskFilter.done")
                }
            }
        }
    }

    @ViewBuilder
    private func choicePicker(_ title: String, selection: Binding<String>, choices: [TaskFilterChoice], anyLabel: String) -> some View {
        Section(title) {
            Picker(title, selection: selection) {
                Text(anyLabel).tag("")
                // A remembered value that is still valid but has no task in view stays listed (count 0), never "All".
                if !selection.wrappedValue.isEmpty, !choices.contains(where: { $0.value == selection.wrappedValue }) {
                    Text("Selected (0)").tag(selection.wrappedValue)
                }
                ForEach(choices) { choice in
                    Text("\(choice.label) (\(choice.count))").tag(choice.value)
                }
            }
        }
    }
}

/// The filters that are on, each with ✕, and Clear all.
struct TaskFilterChips: View {
    @Binding var filters: TaskFilterSet
    let options: (projects: [TaskFilterChoice], smallWorks: [TaskFilterChoice], creators: [TaskFilterChoice])
    var assignees: [TaskFilterChoice] = []

    private func label(_ value: String, in choices: [TaskFilterChoice], prefix: String) -> String {
        let name = choices.first { $0.value == value }?.label ?? "Selected"
        return "\(prefix): \(name)"
    }

    private var chips: [(id: String, text: String, clear: () -> Void)] {
        var out: [(id: String, text: String, clear: () -> Void)] = []
        if !filters.projectId.isEmpty {
            out.append(("project", label(filters.projectId, in: options.projects, prefix: "Project"), { filters.projectId = "" }))
        }
        if !filters.smallWorksId.isEmpty {
            out.append(("smallWorks", label(filters.smallWorksId, in: options.smallWorks, prefix: "Small works"), { filters.smallWorksId = "" }))
        }
        if !filters.creatorKey.isEmpty {
            out.append(("creator", label(filters.creatorKey, in: options.creators, prefix: "Assigned by"), { filters.creatorKey = "" }))
        }
        if !filters.assigneeKey.isEmpty {
            out.append(("assignee", label(filters.assigneeKey, in: assignees, prefix: "Assigned to"), { filters.assigneeKey = "" }))
        }
        if !filters.priority.isEmpty {
            let priority = ProjectTask.Priority(rawValue: filters.priority).map(TaskRulebook.priorityLabel) ?? filters.priority
            out.append(("priority", "Priority: \(priority)", { filters.priority = "" }))
        }
        if !filters.due.isEmpty {
            let name = TaskViewingRulebook.dueFilterChoices().first { $0.choice.rawValue == filters.due }?.label ?? filters.due
            out.append(("due", name, { filters.due = "" }))
        }
        return out
    }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(chips, id: \.id) { chip in
                    Button(action: chip.clear) {
                        HStack(spacing: 4) {
                            Text(chip.text).font(.caption.weight(.semibold))
                            Image(systemName: "xmark").font(.system(size: 9, weight: .bold))
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(ProjectWorksRevampColors.blueLight, in: Capsule())
                        .foregroundStyle(ProjectWorksRevampColors.blue)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Remove filter \(chip.text)")
                }
                Button("Clear all") { filters = .none }
                    .font(.caption.weight(.semibold))
                    .accessibilityIdentifier("taskFilter.chips.clearAll")
            }
        }
    }
}

/// Filters (n), Sort, and the active filter chips — one bar for the main Tasks screen and a job's Tasks tab (web
/// `TaskList` modes `main` and `location`). On a job's tab the job is fixed, so its sheet has no project / small works
/// filter. The chips show only once everything has loaded (web review of #459).
struct TaskFilterSortBar: View {
    @Binding var filters: TaskFilterSet
    @Binding var sort: TaskSortChoice
    let tab: TaskTab
    let ready: Bool
    let options: (projects: [TaskFilterChoice], smallWorks: [TaskFilterChoice], creators: [TaskFilterChoice])
    let assignees: [TaskFilterChoice]
    /// Accessibility identifier prefix ("tasksDetail" on the main screen, "projectDetail" on a job's tab).
    let identifierPrefix: String
    let onShowFilters: () -> Void

    var body: some View {
        let count = TaskViewingRulebook.activeFilterCount(filters)
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Button(action: onShowFilters) {
                    Label(count > 0 ? "Filters (\(count))" : "Filters", systemImage: "line.3.horizontal.decrease.circle")
                        .font(.subheadline.weight(.semibold))
                }
                .accessibilityIdentifier("\(identifierPrefix).filters")
                Spacer()
                Menu {
                    ForEach(TaskViewingRulebook.sortChoices(tab: tab), id: \.choice) { row in
                        Button {
                            sort = row.choice
                        } label: {
                            if row.choice == sort { Label(row.label, systemImage: "checkmark") } else { Text(row.label) }
                        }
                    }
                } label: {
                    Label(TaskViewingRulebook.sortLabel(sort, tab: tab), systemImage: "arrow.up.arrow.down")
                        .font(.subheadline)
                }
                .accessibilityIdentifier("\(identifierPrefix).sort")
            }
            if count > 0, ready {
                TaskFilterChips(filters: $filters, options: options, assignees: assignees)
            }
        }
    }
}

/// The people a task can be filtered by ("Assigned to"): one choice per person over the given tasks, named from the
/// assignee names (`TaskPeopleRulebook.assigneeNames`), keyed by `taskPersonKeys` (web `TaskList` assignee options).
enum TaskAssigneeFilterChoices {
    static func build(_ tasks: [ProjectTask], keys: [String: String], index: TaskPersonIndex) -> [TaskFilterChoice] {
        var seen: [String: TaskFilterChoice] = [:]
        func add(_ kind: TaskPersonKind, _ id: UUID, stored: String, counted: inout Set<String>) {
            let key = keys[stored.lowercased()] ?? "id:\(stored.lowercased())"
            guard counted.insert(key).inserted else { return }
            let name = TaskPeopleRulebook.assigneeNames(
                managerIds: kind == .manager ? [id] : [],
                operativeIds: kind == .operative ? [id] : [],
                index: index
            ).first?.name ?? TaskRulebook.removedUserLabel
            var choice = seen[key] ?? TaskFilterChoice(value: key, label: name, count: 0)
            choice.count += 1
            seen[key] = choice
        }
        for task in tasks {
            var counted = Set<String>()
            for id in task.allAssignedManagerIds { add(.manager, id, stored: id.uuidString, counted: &counted) }
            for id in task.allAssignedOperativeIds { add(.operative, id, stored: Booking.operativeMatchKey(for: id), counted: &counted) }
        }
        return seen.values.sorted { $0.label.localizedCaseInsensitiveCompare($1.label) == .orderedAscending }
    }
}
