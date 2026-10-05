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

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
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
                        PPGroupLabel(text: group.section.headerTitle)
                        PPGroupedCard {
                            let rowsSansSignOut = group.rows.filter { $0.id != "sign_out" }
                            ForEach(Array(rowsSansSignOut.enumerated()), id: \.element.id) { index, spec in
                                catalogRowView(spec: spec)
                                if index < rowsSansSignOut.count - 1 {
                                    PPRowDivider()
                                }
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

                    PPVersionFooter(text: appVersionLine)
                }
                .padding(.horizontal, 18)
                .padding(.bottom, 24)
            }
            .background(PPColor.page.ignoresSafeArea())
            .toolbar(.hidden, for: .navigationBar)
        }
    }

    private var headerRow: some View {
        PPLargeSheetHeader("Main Menu") {
            Button("Done") { dismiss() }
                .ppProminentCapsule()
        }
    }

    private var quickCreateCard: some View {
        PPQuickCreateCard(eyebrow: "Quick create", title: "Start something new") {
            // TODO(UI): Quick create sparkle is not a button, so PPOnNavyCircleButtonStyle is not applied.
            Image(systemName: "sparkles")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 36, height: 36)
                .background(Circle().fill(Color.white.opacity(0.12)))
                .overlay(Circle().strokeBorder(Color.white.opacity(0.22), lineWidth: 0.5))
        } tiles: {
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

    private func quickCreatePillButton(icon: String, title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            PPQuickCreateTileLabel(
                title: title,
                symbol: PPMidnightAppearance.quickCreateSymbol(title: title, fallback: icon),
                family: PPMidnightAppearance.quickCreateFamily(title: title),
                onNavy: true
            )
        }
        .buttonStyle(PPPressableButtonStyle())
    }

    private func editBarProminentRow(spec: MainMenuRowSpec) -> some View {
        PPGroupedCard {
            Button {
                dismissAfterEmit(spec.action)
            } label: {
                PPMenuRowLabel(
                    title: MainMenuCatalog.displayTitle(for: spec, userStore: userStore),
                    symbol: PPMidnightAppearance.menuSymbol(rowId: spec.id, fallback: spec.icon),
                    family: PPMidnightAppearance.menuFamily(rowId: spec.id),
                    subtitle: spec.detail
                )
            }
            .buttonStyle(PPMenuRowButtonStyle())
        }
        .padding(.top, 14)
    }

    @ViewBuilder
    private func catalogRowView(spec: MainMenuRowSpec) -> some View {
        let subtitle = MainMenuCatalog.subtitle(for: spec.id, projectStore: projectStore, operativeStore: operativeStore)
        let badge = MainMenuCatalog.toolBadge(for: spec.id, operativeStore: operativeStore)
        let rowLabel = PPMenuRowLabel(
            title: MainMenuCatalog.displayTitle(for: spec, userStore: userStore),
            symbol: PPMidnightAppearance.menuSymbol(rowId: spec.id, fallback: spec.icon),
            family: PPMidnightAppearance.menuFamily(rowId: spec.id),
            detail: subtitle ?? badge
        )
        if spec.id == "general_app" {
            NavigationLink {
                GeneralAppSettingsView()
                    .environmentObject(appSettings)
            } label: {
                rowLabel
            }
            .buttonStyle(.plain)
        } else {
            Button {
                dismissAfterEmit(spec.action)
            } label: {
                rowLabel
            }
            .buttonStyle(PPMenuRowButtonStyle())
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
                        Text(MainMenuCatalog.displayTitle(for: spec, userStore: userStore))
                    }
                }
                .buttonStyle(PPSignOutButtonStyle())
            }
        }
    }

    private var appVersionLine: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
        return "Project Planner · v\(v)"
    }

    private func dismissAfterEmit(_ action: MainMenuRowAction) {
        dismiss()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            MainMenuCatalog.emit(action)
        }
    }
}
