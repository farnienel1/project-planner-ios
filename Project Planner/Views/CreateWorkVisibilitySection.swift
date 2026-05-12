//
//  CreateWorkVisibilitySection.swift
//  Project Planner
//
//  Shared “View” picker for new project / new small works: managers who will not see the job.
//

import SwiftUI

struct CreateWorkVisibilitySection: View {
    @EnvironmentObject var userStore: UserStore
    @Binding var hiddenManagerUserIds: Set<String>
    /// e.g. "project" or "small works job"
    let workKindNoun: String
    var palette: CreateWorkVisibilityPalette = .projects

    enum CreateWorkVisibilityPalette {
        case projects
        case smallWorks

        var border: Color {
            switch self {
            case .projects: return ProjectWorksRevampColors.border
            case .smallWorks: return ProjectWorksRevampColors.border
            }
        }

        var muted: Color { ProjectWorksRevampColors.muted }
        var ink: Color { ProjectWorksRevampColors.ink }
        var eyeBg: Color {
            switch self {
            case .projects: return Color(red: 0.902, green: 0.945, blue: 0.984)
            case .smallWorks: return Color(red: 1.0, green: 0.94, blue: 0.88)
            }
        }

        var eyeTint: Color {
            switch self {
            case .projects: return ProjectWorksRevampColors.blue
            case .smallWorks: return Color(red: 0.6, green: 0.235, blue: 0.114)
            }
        }
    }

    private var candidates: [AppUser] {
        userStore.organizationUsers
            .filter { $0.permissions.manager && !$0.permissions.operativeMode && !$0.isExcludedFromManagerVisibilityHiding }
            .sorted {
                ($0.fullName.isEmpty ? $0.email : $0.fullName) < ($1.fullName.isEmpty ? $1.email : $1.fullName)
            }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(palette.eyeBg)
                    .frame(width: 30, height: 30)
                    .overlay(Image(systemName: "eye.slash").font(.system(size: 15, weight: .medium)).foregroundStyle(palette.eyeTint))
                VStack(alignment: .leading, spacing: 4) {
                    Text("View")
                        .font(.system(size: 11))
                        .foregroundStyle(palette.muted)
                    Text("This feature can be used to select who will not be able to view the \(workKindNoun). Admins always have access.")
                        .font(.system(size: 12))
                        .foregroundStyle(palette.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if candidates.isEmpty {
                Text("No other managers are available to restrict.")
                    .font(.system(size: 12))
                    .foregroundStyle(palette.muted)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 8)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(candidates.enumerated()), id: \.element.id) { idx, user in
                        Button {
                            if hiddenManagerUserIds.contains(user.id) {
                                hiddenManagerUserIds.remove(user.id)
                            } else {
                                hiddenManagerUserIds.insert(user.id)
                            }
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(user.fullName.isEmpty ? user.email : user.fullName)
                                        .font(.system(size: 13, weight: .medium))
                                        .foregroundStyle(palette.ink)
                                    Text(user.email)
                                        .font(.system(size: 11))
                                        .foregroundStyle(palette.muted)
                                }
                                Spacer()
                                let hidden = hiddenManagerUserIds.contains(user.id)
                                Image(systemName: hidden ? "eye.slash.circle.fill" : "checkmark.circle.fill")
                                    .foregroundStyle(hidden ? Color.orange : ProjectWorksRevampColors.blue)
                            }
                            .padding(.vertical, 10)
                        }
                        .buttonStyle(.plain)
                        if idx < candidates.count - 1 {
                            Divider().overlay(palette.border)
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(Color.white)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(palette.border, lineWidth: 0.5))
    }
}
