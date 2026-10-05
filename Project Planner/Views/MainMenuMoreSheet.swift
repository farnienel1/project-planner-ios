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
                    PPInlineSheetHeader("More") {
                        Button {
                            dismiss()
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .symbolRenderingMode(.hierarchical)
                        }
                        .accessibilityLabel("Close")
                        .ppGlassCircle()
                    }

                    if let editGroup = grouped.first(where: { $0.section == .editBar }) {
                        ForEach(editGroup.rows) { row in
                            editMenuBarRow(spec: row)
                        }
                    }

                    if MainMenuCatalog.showQuickCreateSection(userStore: userStore) {
                        PPGroupLabel(text: "Quick create")
                        moreQuickCreateCard
                    }

                    ForEach(grouped.filter { $0.section != .editBar }, id: \.section) { group in
                        PPGroupLabel(text: group.section.headerTitle)
                        moreGroupedCard(rows: group.rows)
                    }

                    if let signOut = MainMenuCatalog.visibleRows(
                        userStore: userStore,
                        projectStore: projectStore,
                        operativeStore: operativeStore
                    ).first(where: { $0.id == "sign_out" }) {
                        signOutButton(spec: signOut)
                    }

                    // TODO(UI): More sheet has no existing version string, so PPVersionFooter is not added.
                }
                .padding(.horizontal, 18)
                .padding(.top, 8)
                .padding(.bottom, 28)
            }
            .background(PPColor.page.ignoresSafeArea())
            .toolbar(.hidden, for: .navigationBar)
        }
        .presentationDragIndicator(.visible)
        .presentationCornerRadius(24)
    }

    private var moreQuickCreateCard: some View {
        PPGroupedCard {
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
            .padding(10)
        }
    }

    private func moreQuickPill(icon: String, title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            PPQuickCreateTileLabel(
                title: title,
                symbol: PPMidnightAppearance.quickCreateSymbol(title: title, fallback: icon),
                family: PPMidnightAppearance.quickCreateFamily(title: title),
                onNavy: false
            )
        }
        .buttonStyle(PPPressableButtonStyle())
    }

    private func moreGroupedCard(rows: [MainMenuRowSpec]) -> some View {
        let rowsSansSignOut = rows.filter { $0.id != "sign_out" }
        return PPGroupedCard {
            ForEach(Array(rowsSansSignOut.enumerated()), id: \.element.id) { idx, row in
                moreRow(for: row)
                if idx < rowsSansSignOut.count - 1 {
                    PPRowDivider()
                }
            }
        }
    }

    private func editMenuBarRow(spec: MainMenuRowSpec) -> some View {
        PPGroupedCard {
            Button {
                performAfterDismiss(spec.action)
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

    private func moreRow(for spec: MainMenuRowSpec) -> some View {
        let subtitle = MainMenuCatalog.subtitle(for: spec.id, projectStore: projectStore, operativeStore: operativeStore)
        let badge = MainMenuCatalog.toolBadge(for: spec.id, operativeStore: operativeStore)
        return Button {
            performAfterDismiss(spec.action)
        } label: {
            PPMenuRowLabel(
                title: MainMenuCatalog.displayTitle(for: spec, userStore: userStore),
                symbol: PPMidnightAppearance.menuSymbol(rowId: spec.id, fallback: spec.icon),
                family: PPMidnightAppearance.menuFamily(rowId: spec.id),
                detail: subtitle ?? badge
            )
        }
        .buttonStyle(PPMenuRowButtonStyle())
    }

    private func signOutButton(spec: MainMenuRowSpec) -> some View {
        Button {
            performAfterDismiss(spec.action)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: spec.icon)
                Text(MainMenuCatalog.displayTitle(for: spec, userStore: userStore))
            }
        }
        .buttonStyle(PPSignOutButtonStyle())
    }

    private func performAfterDismiss(_ action: MainMenuRowAction) {
        dismiss()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
            MainMenuCatalog.emit(action)
        }
    }
}
