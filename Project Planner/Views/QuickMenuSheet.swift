//
//  QuickMenuSheet.swift
//  Project Planner
//
//  Home “Main Menu” — same eligible entries as More (`MainMenuCatalog`).
//

import SwiftUI

struct QuickMenuSheet: View {
    @EnvironmentObject var userStore: UserStore
    @EnvironmentObject var firebaseBackend: FirebaseBackend
    @EnvironmentObject var appSettings: AppSettingsStore
    @EnvironmentObject var projectStore: ProjectStore
    @EnvironmentObject var operativeStore: OperativeStore
    @Environment(\.dismiss) private var dismiss

    private var grouped: [(section: MainMenuShellSection, rows: [MainMenuRowSpec])] {
        MainMenuCatalog.groupedVisibleRows(
            userStore: userStore,
            projectStore: projectStore,
            operativeStore: operativeStore
        )
    }

    private var quickCreateGradient: LinearGradient {
        LinearGradient(
            colors: [
                Color.theme.primary(for: appSettings.settings.colorScheme),
                ProjectWorksRevampColors.blueLight
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    headerRow

                    if MainMenuCatalog.showQuickCreateSection(userStore: userStore) {
                        quickCreateCard
                    }

                    if let editGroup = grouped.first(where: { $0.section == .editBar }) {
                        ForEach(editGroup.rows) { row in
                            editBarProminentRow(spec: row)
                        }
                    }

                    ForEach(grouped.filter { $0.section != .editBar }, id: \.section) { group in
                        menuSectionTitle(group.section.headerTitle)
                        menuGroupedCard {
                            let rowsSansSignOut = group.rows.filter { $0.id != "sign_out" }
                            ForEach(Array(rowsSansSignOut.enumerated()), id: \.element.id) { _, spec in
                                catalogRowView(spec: spec)
                            }
                        }
                    }

                    if MainMenuCatalog.visibleRows(
                        userStore: userStore,
                        projectStore: projectStore,
                        operativeStore: operativeStore
                    ).first(where: { $0.id == "sign_out" }) != nil {
                        signOutArea
                    }

                    Text(appVersionLine)
                        .font(.system(size: 10, weight: .regular))
                        .foregroundStyle(Color(red: 0.773, green: 0.788, blue: 0.824))
                        .frame(maxWidth: .infinity)
                        .padding(.top, 4)
                }
                .padding(.horizontal, 18)
                .padding(.bottom, 24)
            }
            .background(ProjectWorksRevampColors.canvas.ignoresSafeArea())
            .toolbar(.hidden, for: .navigationBar)
        }
    }

    private var headerRow: some View {
        HStack(alignment: .center) {
            Text("Main Menu")
                .font(.system(size: 22, weight: .medium))
                .foregroundStyle(ProjectWorksRevampColors.ink)
                .tracking(-0.3)
            Spacer(minLength: 12)
            Button("Done") { dismiss() }
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white)
                .padding(.horizontal, 18)
                .padding(.vertical, 7)
                .background(ProjectWorksRevampColors.blue)
                .clipShape(Capsule())
        }
        .padding(.top, 4)
    }

    private var quickCreateCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Quick create")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white.opacity(0.85))
                        .tracking(0.3)
                    Text("Start something new")
                        .font(.system(size: 13, weight: .regular))
                        .foregroundStyle(.white.opacity(0.85))
                }
                Spacer(minLength: 8)
                Image(systemName: "sparkles")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(.white)
                    .frame(width: 32, height: 32)
                    .background(Color.white.opacity(0.18))
                    .clipShape(Circle())
            }
            HStack(spacing: 8) {
                if MainMenuCatalog.canCreateProject(userStore: userStore) {
                    quickCreatePillButton(icon: "folder.badge.plus", title: "Project") {
                        dismissAfterEmit(.openSurface(.createProject))
                    }
                }
                if MainMenuCatalog.canCreateSmallWorks(userStore: userStore) {
                    quickCreatePillButton(icon: "hammer.fill", title: "Small work") {
                        dismissAfterEmit(.openSurface(.createSmallWorks))
                    }
                }
                if MainMenuCatalog.canAddUserQuick(userStore: userStore) {
                    quickCreatePillButton(icon: "person.badge.plus", title: "User") {
                        dismissAfterEmit(.openSurface(.addUser))
                    }
                }
                quickCreatePillButton(icon: "plus.rectangle.on.rectangle", title: "Task") {
                    dismissAfterEmit(.openSurface(.tasksDetail))
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(quickCreateGradient)
        )
    }

    private func quickCreatePillButton(icon: String, title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(.white)
                Text(title)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .padding(.horizontal, 4)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.white.opacity(0.14))
            )
        }
        .buttonStyle(.plain)
    }

    private func editBarProminentRow(spec: MainMenuRowSpec) -> some View {
        Button {
            dismissAfterEmit(spec.action)
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
                        .foregroundStyle(ProjectWorksRevampColors.ink)
                    if let detail = spec.detail {
                        Text(detail)
                            .font(.system(size: 11))
                            .foregroundStyle(ProjectWorksRevampColors.muted)
                    }
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color(red: 0.773, green: 0.788, blue: 0.824))
            }
            .padding(.vertical, 12)
            .padding(.horizontal, 14)
            .background(Color.white)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(ProjectWorksRevampColors.border, lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func catalogRowView(spec: MainMenuRowSpec) -> some View {
        let subtitle = MainMenuCatalog.subtitle(for: spec.id, projectStore: projectStore, operativeStore: operativeStore)
        let badge = MainMenuCatalog.toolBadge(for: spec.id, operativeStore: operativeStore)
        if spec.section == .navigate, let sub = subtitle, !sub.isEmpty {
            polishedNavigateRow(
                icon: spec.icon,
                iconBackground: spec.iconBackground,
                iconTint: spec.iconTint,
                title: MainMenuCatalog.displayTitle(for: spec, userStore: userStore),
                subtitle: sub
            ) {
                dismissAfterEmit(spec.action)
            }
        } else if spec.id == "general_app" {
            NavigationLink {
                GeneralAppSettingsView()
                    .environmentObject(appSettings)
            } label: {
                polishedToolRowLabel(
                    icon: spec.icon,
                    iconBackground: spec.iconBackground,
                    iconTint: spec.iconTint,
                    title: MainMenuCatalog.displayTitle(for: spec, userStore: userStore),
                    badge: badge
                )
            }
            .buttonStyle(.plain)
            Divider().overlay(ProjectWorksRevampColors.border)
        } else {
            polishedToolRow(
                icon: spec.icon,
                iconBackground: spec.iconBackground,
                iconTint: spec.iconTint,
                title: MainMenuCatalog.displayTitle(for: spec, userStore: userStore),
                badge: badge,
                showsDivider: true
            ) {
                dismissAfterEmit(spec.action)
            }
        }
    }

    private var signOutArea: some View {
        Group {
            if let spec = MainMenuCatalog.visibleRows(
                userStore: userStore,
                projectStore: projectStore,
                operativeStore: operativeStore
            ).first(where: { $0.id == "sign_out" }) {
                Button {
                    dismissAfterEmit(spec.action)
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
        }
    }

    private var appVersionLine: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
        return "Project Planner · v\(v)"
    }

    private func menuSectionTitle(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(ProjectWorksRevampColors.muted)
            .tracking(0.4)
            .padding(.leading, 4)
    }

    private func menuGroupedCard<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(spacing: 0) {
            content()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 4)
        .background(Color.white)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(ProjectWorksRevampColors.border, lineWidth: 0.5)
        )
    }

    private func polishedNavigateRow(
        icon: String,
        iconBackground: Color,
        iconTint: Color,
        title: String,
        subtitle: String,
        action: @escaping () -> Void
    ) -> some View {
        VStack(spacing: 0) {
            Button(action: action) {
                HStack(spacing: 12) {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(iconBackground)
                        .frame(width: 32, height: 32)
                        .overlay(
                            Image(systemName: icon)
                                .font(.system(size: 16, weight: .medium))
                                .foregroundStyle(iconTint)
                        )
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(ProjectWorksRevampColors.ink)
                        Text(subtitle)
                            .font(.system(size: 11))
                            .foregroundStyle(ProjectWorksRevampColors.muted)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Color(red: 0.773, green: 0.788, blue: 0.824))
                }
                .padding(.vertical, 11)
            }
            .buttonStyle(.plain)
            Divider().overlay(ProjectWorksRevampColors.border)
        }
    }

    private func polishedToolRow(
        icon: String,
        iconBackground: Color,
        iconTint: Color,
        title: String,
        badge: String?,
        showsDivider: Bool = true,
        action: @escaping () -> Void
    ) -> some View {
        VStack(spacing: 0) {
            Button(action: action) {
                polishedToolRowLabel(
                    icon: icon,
                    iconBackground: iconBackground,
                    iconTint: iconTint,
                    title: title,
                    badge: badge
                )
            }
            .buttonStyle(.plain)
            if showsDivider {
                Divider().overlay(ProjectWorksRevampColors.border)
            }
        }
    }

    private func polishedToolRowLabel(
        icon: String,
        iconBackground: Color,
        iconTint: Color,
        title: String,
        badge: String?
    ) -> some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(iconBackground)
                .frame(width: 32, height: 32)
                .overlay(
                    Image(systemName: icon)
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(iconTint)
                )
            HStack(spacing: 6) {
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(ProjectWorksRevampColors.ink)
                if let badge {
                    Text(badge)
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(Color(red: 0.639, green: 0.176, blue: 0.176))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color(red: 0.988, green: 0.922, blue: 0.922))
                        .clipShape(Capsule())
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Image(systemName: "chevron.right")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Color(red: 0.773, green: 0.788, blue: 0.824))
        }
        .padding(.vertical, 11)
    }

    private func dismissAfterEmit(_ action: MainMenuRowAction) {
        dismiss()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            MainMenuCatalog.emit(action)
        }
    }
}
