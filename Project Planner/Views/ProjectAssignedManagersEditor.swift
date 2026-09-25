//
//  ProjectAssignedManagersEditor.swift
//  Project Planner
//

import SwiftUI

struct ProjectAssignedManagersEditor: View {
    @Binding var selectedManagers: [Manager]
    let availableManagersToAdd: [Manager]
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
                    }
                    if availableManagersToAdd.isEmpty {
                        Button("All managers added") {}
                            .disabled(true)
                    }
                    Button("Create manager…") { onCreateManager() }
                } label: {
                    Label("Add", systemImage: "plus")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(ProjectWorksRevampColors.blue)
                }
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
                                        colors: [Color(red: 0.325, green: 0.29, blue: 0.718), Color(red: 0.5, green: 0.47, blue: 0.87)],
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

    private func initials(for manager: Manager) -> String {
        let f = manager.firstName.prefix(1)
        let l = manager.lastName.prefix(1)
        let value = "\(f)\(l)".uppercased()
        return value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "?" : value
    }
}
