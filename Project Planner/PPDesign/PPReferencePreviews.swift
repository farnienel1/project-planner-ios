//
//  PPReferencePreviews.swift
//  Project Planner — Midnight UI upgrade (UI ONLY)
//
//  ⚠️ REFERENCE / XCODE CANVAS ONLY. NOT A REPLACEMENT FOR ANY REAL SCREEN.
//
//  These previews show how the PPDesign pieces fit together so you can see
//  the target look in the Xcode canvas. Every action here is an empty
//  closure `{}` with sample text. In the real app:
//    • keep the existing Buttons, NavigationLinks, sheets, actions, bindings,
//      view models, strings and order exactly as they are;
//    • only swap their labels / styles / containers for the PPDesign ones.
//  Wrapped in #if DEBUG so it never ships.
//

#if DEBUG
import SwiftUI

private struct SampleAction: Identifiable {
    let id = UUID()
    let title: String
    let symbol: String
    let family: PPFamily
}

private let sampleQuickActions: [SampleAction] = [
    .init(title: "Weekly Report",   symbol: "doc.text.fill",                       family: .plan),
    .init(title: "Daily Overview",  symbol: "calendar.badge.clock",                family: .plan),
    .init(title: "Tasks",           symbol: "checklist",                           family: .plan),
    .init(title: "Projects",        symbol: "folder.fill",                         family: .sites),
    .init(title: "Small Works",     symbol: "hammer.fill",                         family: .trade),
    .init(title: "Annual Leave",    symbol: "sun.max.fill",                        family: .plan),
    .init(title: "My Schedule",     symbol: "calendar",                            family: .plan),
    .init(title: "Site Audit",      symbol: "doc.viewfinder.fill",                 family: .sites),
    .init(title: "Managers",        symbol: "person.badge.shield.checkmark.fill",  family: .people),
    .init(title: "Operatives",      symbol: "person.3.fill",                       family: .people),
    .init(title: "Sub Contractors", symbol: "person.2.badge.gearshape.fill",       family: .people),
    .init(title: "Site Map",        symbol: "map.fill",                            family: .sites),
    .init(title: "Settings",        symbol: "gearshape.fill",                      family: .system),
    .init(title: "Timesheets",      symbol: "list.clipboard.fill",                 family: .plan),
]

// MARK: - Home reference

private struct PPHomeReference: View {
    var body: some View {
        ScrollView {
            VStack(spacing: 0) {

                // ── NAVY HEADER ───────────────────────────────────────────
                VStack(alignment: .leading, spacing: 0) {
                    HStack {
                        PPGreetingLabel(dateText: "Monday 5 Oct", greeting: "Hi, Test")
                        Spacer()
                        HStack(spacing: 8) {
                            Button {} label: { Image(systemName: "arrow.clockwise") }
                                .accessibilityIdentifier("ppHomeReference.refresh")
                                .buttonStyle(PPOnNavyCircleButtonStyle())
                            Button {} label: { Image(systemName: "bell.fill") }
                                .accessibilityIdentifier("ppHomeReference.notifications")
                                .buttonStyle(PPOnNavyCircleButtonStyle())
                                .overlay(alignment: .topTrailing) { PPBellDot() }
                            // Existing avatar view goes here unchanged (40pt).
                            Circle().fill(PPColor.brand).frame(width: 40, height: 40)
                                .overlay(Text("TA").font(.system(.subheadline, design: .rounded)).bold().foregroundStyle(.white))
                        }
                    }
                    .padding(.bottom, 22)

                    HStack(alignment: .top) {
                        PPOverviewTitle(eyebrow: "Today's overview", count: "8", countLabel: "active projects")
                        Spacer(minLength: 8)
                        HStack(spacing: 6) {
                            Button {} label: { Image(systemName: "gearshape.fill") }
                                .accessibilityIdentifier("ppHomeReference.settings")
                                .buttonStyle(PPOnNavyCircleButtonStyle(size: PPMetrics.smallHeaderButton))
                            Button("Heads up") {}
                                .accessibilityIdentifier("ppHomeReference.headsUp")
                                .buttonStyle(PPHeadsUpButtonStyle())
                        }
                    }

                    HStack(alignment: .top, spacing: 12) {
                        PPStat(value: "0", label: "Tasks Due Today")
                        PPStatDivider()
                        PPStat(value: "0", label: "Tasks Due This Week")
                        PPStatDivider()
                        PPStat(value: "9", label: "Warnings", highlight: true)
                    }
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 16)

                    HStack(spacing: 8) {
                        Button {} label: {
                            PPStatusChipLabel(symbol: "exclamationmark.triangle.fill", family: .alert,
                                              title: "Warnings", value: "9", unit: "active")
                        }
                        .accessibilityIdentifier("ppHomeReference.exclamationmarkTriangleFill")
                        .buttonStyle(PPOnNavyChipButtonStyle())
                        Button {} label: {
                            PPStatusChipLabel(symbol: "checklist", family: .plan,
                                              title: "Tasks", value: "0", unit: "pending")
                        }
                        .accessibilityIdentifier("ppHomeReference.checklist")
                        .buttonStyle(PPOnNavyChipButtonStyle())
                    }
                    .padding(.top, 18)
                }
                .padding(.horizontal, PPMetrics.screenGutter)
                .padding(.top, 8)
                .padding(.bottom, PPMetrics.headerBottomPadding)
                .ppNavyHeader()

                // ── LIGHT CONTENT SHEET ───────────────────────────────────
                VStack(alignment: .leading, spacing: 0) {
                    PPSectionHeader("Quick actions") {
                        Button {} label: {
                            Label("Main Menu", systemImage: "arrow.up.left.and.arrow.down.right")
                        }
                        .accessibilityIdentifier("ppHomeReference.mainMenu")
                        .tint(PPColor.brand)
                        Button("Customise") {}
                            .accessibilityIdentifier("ppHomeReference.customise")
                            .fontWeight(.medium)
                            .tint(.secondary)
                    }

                    LazyVGrid(columns: PPQuickActionGrid.columns,
                              spacing: PPQuickActionGrid.rowSpacing) {
                        ForEach(sampleQuickActions) { item in
                            Button {} label: {
                                PPQuickActionLabel(title: item.title, symbol: item.symbol, family: item.family)
                            }
                            .accessibilityIdentifier("ppHomeReference.row.\(item.id)")
                            .buttonStyle(PPPressableButtonStyle())
                        }
                    }

                    PPSectionHeader("Up next") {
                        Button("See all") {}
                            .accessibilityIdentifier("ppHomeReference.seeAll").tint(PPColor.brand)
                    }
                    PPDayHeading(text: "Tuesday 6th October")
                    Button {} label: {
                        PPUpNextRowLabel(weekday: "Tue", day: "6", title: "71 Broadwick Street",
                                         time: "07:30", tag: "FULL DAY")
                    }
                    .accessibilityIdentifier("ppHomeReference.tue")
                    .buttonStyle(PPPressableButtonStyle())
                    PPDayHeading(text: "Thursday 8th October")
                    Button {} label: {
                        PPUpNextRowLabel(weekday: "Thu", day: "8", title: "71 Broadwick Street",
                                         time: "07:30", tag: "C984")
                    }
                    .accessibilityIdentifier("ppHomeReference.thu")
                    .buttonStyle(PPPressableButtonStyle())

                    PPComingSoonCard(title: "Maintenance", subtitle: "Coming in a future update", badge: "Soon")
                        .padding(.top, 12)
                        .padding(.bottom, 120)
                }
                .ppContentSheet()
            }
        }
        .background(PPColor.page)
    }
}

// MARK: - Menu reference (shared lists)

private struct PPMenuListsReference: View {
    var body: some View {
        VStack(spacing: 0) {
            PPGroupLabel(text: "Navigate")
            PPGroupedCard {
                row("Clients", "briefcase.fill", .sites, detail: "5 on file"); PPRowDivider()
                row("Projects", "folder.fill", .sites, detail: "1 in progress"); PPRowDivider()
                row("Small works", "hammer.fill", .trade, detail: "0 open"); PPRowDivider()
                row("Operatives", "person.3.fill", .people, detail: "5 team members"); PPRowDivider()
                row("Managers", "person.badge.shield.checkmark.fill", .people, detail: "3 active"); PPRowDivider()
                row("Annual Leave", "sun.max.fill", .plan); PPRowDivider()
                row("Site map", "map.fill", .sites); PPRowDivider()
                row("Site audit", "doc.viewfinder.fill", .sites); PPRowDivider()
                row("Timesheets", "list.clipboard.fill", .plan)
            }
            PPGroupLabel(text: "Tools")
            PPGroupedCard {
                row("Qualifications", "graduationcap.fill", .trade); PPRowDivider()
                row("Job types", "square.grid.2x2.fill", .trade); PPRowDivider()
                row("Wholesalers", "building.2.fill", .trade); PPRowDivider()
                row("Material catalogue", "shippingbox.fill", .trade); PPRowDivider()
                row("Sub contractors", "person.2.badge.gearshape.fill", .people)
            }
            PPGroupLabel(text: "Team")
            PPGroupedCard {
                row("Add user", "person.fill.badge.plus", .people); PPRowDivider()
                row("Manage users", "person.2.fill", .people)
            }
            PPGroupLabel(text: "App & Account")
            PPGroupedCard {
                row("Settings", "gearshape.fill", .system); PPRowDivider()
                row("Help & support", "questionmark.circle.fill", .sites); PPRowDivider()
                row("Reset password", "key.fill", .system)
            }
            Button {} label: {
                Label("Sign out", systemImage: "rectangle.portrait.and.arrow.right")
            }
            .accessibilityIdentifier("ppMenuListsReference.signOut")
            .buttonStyle(PPSignOutButtonStyle())
            PPVersionFooter(text: "Project Planner · v1.0")
        }
    }

    private func row(_ title: String, _ symbol: String, _ family: PPFamily, detail: String? = nil) -> some View {
        Button {} label: {
            PPMenuRowLabel(title: title, symbol: symbol, family: family, detail: detail)
        }
        .accessibilityIdentifier("ppMenuListsReference.\(AccessibilityID.token(title))")
        .buttonStyle(PPMenuRowButtonStyle())
    }
}

private let quickCreate: [SampleAction] = [
    .init(title: "Project",    symbol: "folder.fill.badge.plus", family: .sites),
    .init(title: "Small work", symbol: "hammer.fill",            family: .trade),
    .init(title: "User",       symbol: "person.fill.badge.plus", family: .people),
    .init(title: "Task",       symbol: "checklist",              family: .plan),
]

private struct PPEditBarRow: View {
    var body: some View {
        PPGroupedCard {
            Button {} label: {
                PPMenuRowLabel(title: "Edit main menu bar",
                               symbol: "dock.arrow.down.rectangle",
                               family: .system,
                               subtitle: "Icons jiggle — drag onto a slot in the bar below to reorder.")
            }
            .accessibilityIdentifier("ppEditBar.editTabBar")
            .buttonStyle(PPMenuRowButtonStyle())
        }
    }
}

private struct PPMainMenuReference: View {
    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                PPLargeSheetHeader("Main Menu") {
                    Button("Done") {}
                        .accessibilityIdentifier("ppMainMenuReference.done").ppProminentCapsule()
                }
                PPQuickCreateCard(eyebrow: "Quick create", title: "Start something new") {
                    Button {} label: { Image(systemName: "sparkles") }
                        .accessibilityIdentifier("ppMainMenuReference.sparkles")
                        .buttonStyle(PPOnNavyCircleButtonStyle(size: 36))
                } tiles: {
                    ForEach(quickCreate) { item in
                        Button {} label: {
                            PPQuickCreateTileLabel(title: item.title, symbol: item.symbol,
                                                   family: item.family, onNavy: true)
                        }
                        .accessibilityIdentifier("ppMainMenuReference.row.\(item.id)")
                        .buttonStyle(PPPressableButtonStyle())
                    }
                }
                PPEditBarRow().padding(.top, 14)
                PPMenuListsReference()
            }
            .padding(.horizontal, PPMetrics.screenGutter)
            .padding(.bottom, 40)
        }
        .background(PPColor.page)
    }
}

private struct PPMoreReference: View {
    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                PPInlineSheetHeader("More") {
                    Button {} label: { Image(systemName: "xmark") }
                        .accessibilityIdentifier("ppMoreReference.close").ppGlassCircle()
                }
                PPEditBarRow()
                PPGroupLabel(text: "Quick create")
                PPGroupedCard {
                    HStack(spacing: 8) {
                        ForEach(quickCreate) { item in
                            Button {} label: {
                                PPQuickCreateTileLabel(title: item.title, symbol: item.symbol, family: item.family)
                            }
                            .accessibilityIdentifier("ppMoreReference.row.\(item.id)")
                            .buttonStyle(PPPressableButtonStyle())
                        }
                    }
                    .padding(10)
                }
                PPMenuListsReference()
            }
            .padding(.horizontal, PPMetrics.screenGutter)
            .padding(.bottom, 40)
        }
        .background(PPColor.page)
    }
}

#Preview("Home — Midnight") { PPHomeReference() }
#Preview("Home — Midnight (dark)") { PPHomeReference().preferredColorScheme(.dark) }
#Preview("Main Menu — Midnight") { PPMainMenuReference() }
#Preview("More — Midnight") { PPMoreReference() }
#endif
