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

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Managers")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(ProjectWorksRevampColors.ink)
                Spacer()
                Menu {
                    ForEach(availableManagersToAdd, id: \.id) { manager in
                        Button("\(manager.firstName) \(manager.lastName)") {
                            selectedManagers.append(manager)
                            onEdited()
                        }
                            .accessibilityIdentifier("projectAssignedManagersEditor.row.\(manager.id)")
                    }
                    if availableManagersToAdd.isEmpty && hasNoCandidates {
                        Button(CanonicalBusinessEngine.jobManagerNoCandidatesMessage) {}
                            .accessibilityIdentifier("projectAssignedManagersEditor.noCandidates")
                            .disabled(true)
                    } else if availableManagersToAdd.isEmpty {
                        Button("All managers added") {}
                            .accessibilityIdentifier("projectAssignedManagersEditor.allManagersAdded")
                            .disabled(true)
                    }
                    Button("Create manager…") { onCreateManager() }
                        .accessibilityIdentifier("projectAssignedManagersEditor.createManager")
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
