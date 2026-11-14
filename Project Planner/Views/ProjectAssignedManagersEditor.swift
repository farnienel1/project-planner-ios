//
//  ProjectAssignedManagersEditor.swift
//  Project Planner
//

import SwiftUI

struct ProjectAssignedManagersEditor: View {
    @Binding var selectedManagers: [Manager]
    let availableManagersToAdd: [Manager]
    /// RULEBOOK 1.30.3 §11 `jobManagerAssignments`: the note beside a manager stored on the job who is no longer a
    /// `jobManagerCandidates` row (`JOB_MANAGER_FORMER_NOTES`), by manager id. Such a manager stays on the job until
    /// someone removes them here and saves.
    var formerNotes: [UUID: String] = [:]
    /// True when `jobManagerCandidates` has nobody at all (not just everyone added): shows
    /// `JOB_MANAGER_NO_CANDIDATES_MESSAGE`.
    var hasNoCandidates: Bool = false
    var onCreateManager: () -> Void
    var onEdited: () -> Void = {}

    @State private var showingPicker = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Managers")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(ProjectWorksRevampColors.ink)
                Spacer()
                // RULEBOOK 1.42.0 (owner decision 13 Nov): several managers per job, easily — a list that stays open,
                // tick as many as needed, then Done. Same candidates (`jobManagerCandidates`) and the same save.
                Button {
                    showingPicker = true
                } label: {
                    Label("Add", systemImage: "plus")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(ProjectWorksRevampColors.blue)
                }
                    .accessibilityIdentifier("projectAssignedManagersEditor.menu")
            }

            if selectedManagers.isEmpty {
                Text("No managers assigned")
                    .font(.system(size: 13))
                    .foregroundStyle(ProjectWorksRevampColors.placeholderInk)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 8)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(selectedManagers.enumerated()), id: \.element.id) { index, manager in
                        HStack(spacing: 12) {
                            Circle()
                                .fill(
                                    LinearGradient(
                                        colors: formerNotes[manager.id] != nil
                                            ? [Self.amber, Self.amber.opacity(0.75)]
                                            : [Color(red: 0.325, green: 0.29, blue: 0.718), Color(red: 0.5, green: 0.47, blue: 0.87)],
                                        startPoint: .topLeading,
                                        endPoint: .bottomTrailing
                                    )
                                )
                                .frame(width: 34, height: 34)
                                .overlay(
                                    Text(initials(for: manager))
                                        .font(.system(size: 11, weight: .medium))
                                        .foregroundStyle(.white)
                                )
                            VStack(alignment: .leading, spacing: 2) {
                                Text(manager.fullName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Assigned manager" : manager.fullName)
                                    .font(.system(size: 13, weight: .medium))
                                    .foregroundStyle(ProjectWorksRevampColors.ink)
                                if !manager.email.isEmpty {
                                    Text(manager.email)
                                        .font(.system(size: 11))
                                        .foregroundStyle(ProjectWorksRevampColors.muted)
                                }
                                if let note = formerNotes[manager.id] {
                                    Text(note)
                                        .font(.system(size: 11, weight: .medium))
                                        .foregroundStyle(Self.amber)
                                        .accessibilityIdentifier("projectAssignedManagersEditor.row.\(manager.id).former")
                                }
                            }
                            Spacer(minLength: 0)
                            Button {
                                selectedManagers.removeAll { $0.id == manager.id }
                                onEdited()
                            } label: {
                                Image(systemName: "minus.circle.fill")
                                    .font(.system(size: 18))
                                    .foregroundStyle(Color(red: 0.74, green: 0.2, blue: 0.2))
                            }
                            .accessibilityIdentifier("projectAssignedManagersEditor.row.\(manager.id).remove")
                            .buttonStyle(.plain)
                            .accessibilityLabel("Remove \(manager.fullName)")
                        }
                        .padding(.vertical, 10)
                        if index < selectedManagers.count - 1 {
                            Divider().overlay(ProjectWorksRevampColors.border)
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(ProjectWorksRevampColors.surface)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(ProjectWorksRevampColors.border, lineWidth: 0.5)
        )
        .sheet(isPresented: $showingPicker) {
            ProjectManagersMultiPickSheet(
                rows: Self.pickerRows(selected: selectedManagers, available: availableManagersToAdd),
                initiallyTicked: Set(selectedManagers.map(\.id)),
                formerNotes: formerNotes,
                hasNoCandidates: hasNoCandidates,
                onDone: { ticked in
                    let next = Self.applyingPicks(selected: selectedManagers, available: availableManagersToAdd, ticked: ticked)
                    if next.map(\.id) != selectedManagers.map(\.id) {
                        selectedManagers = next
                        onEdited()
                    }
                    showingPicker = false
                },
                onCancel: { showingPicker = false },
                onCreateManager: {
                    showingPicker = false
                    onCreateManager()
                }
            )
        }
    }

    /// The picker's rows: the managers already on the job first (current and former, in stored order), then the
    /// candidates not on it yet (`availableManagersToAdd`, from `jobManagerCandidates`). Each person once.
    static func pickerRows(selected: [Manager], available: [Manager]) -> [Manager] {
        var seen = Set<UUID>()
        return (selected + available).filter { seen.insert($0.id).inserted }
    }

    /// The managers after Done: those already on the job that stay ticked keep their place, then the newly ticked ones
    /// in list order. Unticking removes; nothing else changes (the save is unchanged).
    static func applyingPicks(selected: [Manager], available: [Manager], ticked: Set<UUID>) -> [Manager] {
        let kept = selected.filter { ticked.contains($0.id) }
        let keptIds = Set(kept.map(\.id))
        var seen = keptIds
        let added = available.filter { ticked.contains($0.id) && !keptIds.contains($0.id) && seen.insert($0.id).inserted }
        return kept + added
    }

    /// Amber for a former manager, as web shows them.
    static let amber = Color(red: 0.85, green: 0.47, blue: 0.02)

    private func initials(for manager: Manager) -> String {
        let f = manager.firstName.prefix(1)
        let l = manager.lastName.prefix(1)
        let value = "\(f)\(l)".uppercased()
        return value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "?" : value
    }
}

/// RULEBOOK 1.42.0: the multi-tick manager list for a project or small works (create and edit). Stays open while the
/// person ticks; Done applies every tick at once.
struct ProjectManagersMultiPickSheet: View {
    let rows: [Manager]
    let initiallyTicked: Set<UUID>
    var formerNotes: [UUID: String] = [:]
    var hasNoCandidates: Bool = false
    let onDone: (Set<UUID>) -> Void
    let onCancel: () -> Void
    let onCreateManager: () -> Void

    @State private var ticked: Set<UUID> = []
    @State private var search = ""
    @State private var seeded = false

    private var filtered: [Manager] {
        let needle = search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return rows }
        return rows.filter { $0.fullName.lowercased().contains(needle) || $0.email.lowercased().contains(needle) }
    }

    var body: some View {
        NavigationStack {
            List {
                if rows.isEmpty {
                    Text(hasNoCandidates ? CanonicalBusinessEngine.jobManagerNoCandidatesMessage : "All managers added")
                        .foregroundStyle(ProjectWorksRevampColors.muted)
                        .accessibilityIdentifier(hasNoCandidates ? "projectAssignedManagersEditor.noCandidates" : "projectAssignedManagersEditor.allManagersAdded")
                }
                ForEach(filtered, id: \.id) { manager in
                    Button {
                        if ticked.contains(manager.id) { ticked.remove(manager.id) } else { ticked.insert(manager.id) }
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: ticked.contains(manager.id) ? "checkmark.circle.fill" : "circle")
                                .font(.system(size: 20))
                                .foregroundStyle(ticked.contains(manager.id) ? ProjectWorksRevampColors.blue : ProjectWorksRevampColors.muted)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(manager.fullName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Assigned manager" : manager.fullName)
                                    .font(.system(size: 15, weight: .medium))
                                    .foregroundStyle(ProjectWorksRevampColors.ink)
                                if !manager.email.isEmpty {
                                    Text(manager.email)
                                        .font(.system(size: 12))
                                        .foregroundStyle(ProjectWorksRevampColors.muted)
                                }
                                if let note = formerNotes[manager.id] {
                                    Text(note)
                                        .font(.system(size: 12, weight: .medium))
                                        .foregroundStyle(ProjectAssignedManagersEditor.amber)
                                }
                            }
                            Spacer(minLength: 0)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("projectAssignedManagersEditor.row.\(manager.id)")
                    .accessibilityAddTraits(ticked.contains(manager.id) ? .isSelected : [])
                }
                Section {
                    Button("Create manager…") { onCreateManager() }
                        .accessibilityIdentifier("projectAssignedManagersEditor.createManager")
                }
            }
            .searchable(text: $search, prompt: "Search managers and admins")
            .navigationTitle(ticked.isEmpty ? "Managers" : "Managers (\(ticked.count))")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { onCancel() }
                        .accessibilityIdentifier("projectAssignedManagersEditor.cancel")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { onDone(ticked) }
                        .fontWeight(.semibold)
                        .accessibilityIdentifier("projectAssignedManagersEditor.done")
                }
            }
            .onAppear {
                guard !seeded else { return }
                ticked = initiallyTicked
                seeded = true
            }
        }
    }
}
