//
//  MainMenuMoreSheet.swift
//  Project Planner
//
//  Bottom “More” menu — same eligible entries as Main Menu (`MainMenuCatalog`).
//

import SwiftUI

struct MainMenuMoreSheet: View {
    @EnvironmentObject var userStore: UserStore
    @EnvironmentObject var projectStore: ProjectStore
    @EnvironmentObject var operativeStore: OperativeStore
    @Environment(\.dismiss) private var dismiss

    private let sheetBg = Color(red: 0.97, green: 0.973, blue: 0.98)
    private let cardBg = Color(red: 0.97, green: 0.973, blue: 0.98)
    private let ink = Color(red: 0.043, green: 0.063, blue: 0.125)
    private let muted = Color(red: 0.42, green: 0.447, blue: 0.502)
    private let border = Color(red: 0.933, green: 0.941, blue: 0.953)

    private var grouped: [(section: MainMenuShellSection, rows: [MainMenuRowSpec])] {
        MainMenuCatalog.groupedVisibleRows(
            userStore: userStore,
            projectStore: projectStore,
            operativeStore: operativeStore
        )
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if let editGroup = grouped.first(where: { $0.section == .editBar }) {
                        ForEach(editGroup.rows) { row in
                            editMenuBarRow(spec: row)
                        }
                    }

                    if MainMenuCatalog.showQuickCreateSection(userStore: userStore) {
                        sectionHeader("Quick create")
                        moreQuickCreateCard
                    }

                    ForEach(grouped.filter { $0.section != .editBar }, id: \.section) { group in
                        sectionHeader(group.section.headerTitle)
                        moreGroupedCard(rows: group.rows)
                    }

                    if let signOut = MainMenuCatalog.visibleRows(
                        userStore: userStore,
                        projectStore: projectStore,
                        operativeStore: operativeStore
                    ).first(where: { $0.id == "sign_out" }) {
                        signOutButton(spec: signOut)
                    }
                }
                .padding(.horizontal, 18)
                .padding(.top, 8)
                .padding(.bottom, 28)
            }
            .background(sheetBg.ignoresSafeArea())
            .navigationTitle("More")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .symbolRenderingMode(.hierarchical)
                            .foregroundStyle(muted)
                    }
                    .accessibilityLabel("Close")
                }
            }
        }
        .presentationDragIndicator(.visible)
        .presentationCornerRadius(24)
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(muted)
            .tracking(0.4)
            .padding(.leading, 4)
    }

    private var moreQuickCreateCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                if MainMenuCatalog.canCreateProject(userStore: userStore) {
                    moreQuickPill(icon: "folder.badge.plus", title: "Project") {
                        performAfterDismiss(.openSurface(.createProject))
                    }
                }
                if MainMenuCatalog.canCreateSmallWorks(userStore: userStore) {
                    moreQuickPill(icon: "hammer.fill", title: "Small work") {
                        performAfterDismiss(.openSurface(.createSmallWorks))
                    }
                }
                if MainMenuCatalog.canAddUserQuick(userStore: userStore) {
                    moreQuickPill(icon: "person.badge.plus", title: "User") {
                        performAfterDismiss(.openSurface(.addUser))
                    }
                }
                moreQuickPill(icon: "plus.rectangle.on.rectangle", title: "Task") {
                    performAfterDismiss(.openSurface(.tasksDetail))
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(border, lineWidth: 0.5))
    }

    private func moreQuickPill(icon: String, title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(Color(red: 0.09, green: 0.373, blue: 0.647))
                Text(title)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(ink)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .padding(.horizontal, 4)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color(red: 0.902, green: 0.945, blue: 0.984).opacity(0.55))
            )
        }
        .buttonStyle(.plain)
    }

    private func moreGroupedCard(rows: [MainMenuRowSpec]) -> some View {
        let rowsSansSignOut = rows.filter { $0.id != "sign_out" }
        return VStack(spacing: 0) {
            ForEach(Array(rowsSansSignOut.enumerated()), id: \.element.id) { idx, row in
                moreRow(for: row)
                if idx < rowsSansSignOut.count - 1 {
                    Divider().overlay(border)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .background(cardBg)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(border, lineWidth: 0.5))
    }

    private func editMenuBarRow(spec: MainMenuRowSpec) -> some View {
        Button {
            performAfterDismiss(spec.action)
        } label: {
            HStack(spacing: 12) {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(spec.iconBackground)
                    .frame(width: 32, height: 32)
                    .overlay(
                        Image(systemName: spec.icon)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(spec.iconTint)
                    )
                VStack(alignment: .leading, spacing: 2) {
                    Text(MainMenuCatalog.displayTitle(for: spec, userStore: userStore))
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(ink)
                    if let detail = spec.detail {
                        Text(detail)
                            .font(.system(size: 11))
                            .foregroundStyle(muted)
                    }
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color(red: 0.77, green: 0.79, blue: 0.82))
            }
            .padding(.vertical, 12)
            .padding(.horizontal, 12)
            .background(Color.white)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(border, lineWidth: 0.5))
        }
        .buttonStyle(.plain)
    }

    private func moreRow(for spec: MainMenuRowSpec) -> some View {
        Button {
            performAfterDismiss(spec.action)
        } label: {
            HStack(spacing: 12) {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(spec.iconBackground)
                    .frame(width: 32, height: 32)
                    .overlay(
                        Image(systemName: spec.icon)
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(spec.iconTint)
                    )
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(MainMenuCatalog.displayTitle(for: spec, userStore: userStore))
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(ink)
                        if let badge = MainMenuCatalog.toolBadge(for: spec.id, operativeStore: operativeStore) {
                            Text(badge)
                                .font(.system(size: 9, weight: .medium))
                                .foregroundStyle(Color(red: 0.639, green: 0.176, blue: 0.176))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color(red: 0.988, green: 0.922, blue: 0.922))
                                .clipShape(Capsule())
                        }
                    }
                    if let sub = MainMenuCatalog.subtitle(for: spec.id, projectStore: projectStore, operativeStore: operativeStore) {
                        Text(sub)
                            .font(.system(size: 11))
                            .foregroundStyle(muted)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "chevron.right")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color(red: 0.77, green: 0.79, blue: 0.82))
            }
            .padding(.vertical, 11)
        }
        .buttonStyle(.plain)
    }

    private func signOutButton(spec: MainMenuRowSpec) -> some View {
        Button {
            performAfterDismiss(spec.action)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: spec.icon)
                    .font(.system(size: 16, weight: .medium))
                Text(MainMenuCatalog.displayTitle(for: spec, userStore: userStore))
                    .font(.system(size: 13, weight: .medium))
            }
            .foregroundStyle(spec.iconTint)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 13)
            .background(Color.white)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(Color(red: 0.988, green: 0.922, blue: 0.922), lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
    }

    private func performAfterDismiss(_ action: MainMenuRowAction) {
        dismiss()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
            MainMenuCatalog.emit(action)
        }
    }
}
