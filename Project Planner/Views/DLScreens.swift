//
//  DLScreens.swift
//  Project Planner — Deadlines
//
//  REFERENCE LAYOUTS. Five screens, fully runnable against DLStore's sample
//  data so every #Preview at the bottom renders before you wire anything up.
//  Port each `body` into your own view and bind to your real source.
//
//  Requires: HSTheme.swift, HSComponents.swift, DLModels.swift, DLComponents.swift
//
//  Every screen works identically for a Project and a Small Work. The only
//  difference is the `contextKind` / `contextName` strings passed in.
//

import SwiftUI
import UniformTypeIdentifiers
import Combine

enum DLViewMode: Hashable { case list, timeline }

// =====================================================================
// MARK: - 1. DEADLINES TAB (the main screen)
// =====================================================================

struct DLDeadlinesScreen: View {

    @ObservedObject var store: DLStore

    var contextName: String = "BPR"
    var contextRef: String  = "C746"
    var contextKind: String = "Project"      // or "Small Work"
    var canManage: Bool = true
    var authorName: String = "Farnie Nel"
    var people: [DLPerson] = []
    var siteAudits: [DLSiteAuditRef] = []
    var tradeOptions: [String] = ["General", "Electrical", "Mechanical", "Plumbing & Gas",
                                  "Groundworks", "Scaffolding", "Brick & Block", "Joinery",
                                  "Drylining", "Painting", "Roofing", "Demolition",
                                  "Steel Fixing", "Plant"]
    var onCommit: ((DLDeadline, URL?) -> Void)? = nil
    var onBack: (() -> Void)? = nil
    var project: Project? = nil
    var jobSiteAudits: [SiteAudit] = []

    @State private var mode: DLViewMode = .list
    @State private var selectedDay: Date? = nil
    @State private var openItem: DLDeadline? = nil
    @State private var showingAdd = false

    private let cal = Calendar.current

    var body: some View {
        VStack(spacing: 0) {
            navBar

            ScrollView(showsIndicators: false) {
                VStack(spacing: 0) {
                    HSContextHero(title: contextName,
                                  reference: contextRef,
                                  kind: contextKind,
                                  progress: store.completionRatio,
                                  meta: "\(store.completeCount) of \(store.scopedItems.count) deadlines met")
                        .hsGutter()
                        .padding(.top, 6)

                    statGrid
                    riskBanner
                    weekRail
                    segments

                    if mode == .list {
                        listBody
                    } else {
                        timelineBody
                    }

                    Color.clear.frame(height: 26)
                }
            }
        }
        .hsScreen()
        .navigationBarHidden(true)
        .sheet(item: $openItem) { item in
            DLDeadlineDetailSheet(
                item: item,
                store: store,
                canManage: canManage,
                authorName: authorName,
                siteAudits: siteAudits,
                project: project,
                jobSiteAudits: jobSiteAudits,
                people: people,
                tradeOptions: tradeOptions,
                contextKind: contextKind,
                onCommit: onCommit
            )
        }
        .sheet(isPresented: $showingAdd) {
            DLEditDeadlineScreen(
                contextKind: contextKind,
                people: people,
                siteAudits: siteAudits,
                tradeOptions: tradeOptions,
                authorName: authorName,
                onSave: { deadline, fileURL in
                    if let onCommit {
                        onCommit(deadline, fileURL)
                    } else {
                        store.upsert(deadline)
                    }
                }
            )
        }
    }

    // MARK: Nav

    private var navBar: some View {
        HSNavBar(title: "Deadlines",
                 subtitle: "\(contextName) · \(contextRef)",
                 onBack: onBack) {
            HStack(spacing: 8) {
                Button {
                    HSHaptic.select()
                    mode = (mode == .list) ? .timeline : .list
                } label: {
                    Image(systemName: mode == .list ? "chart.bar.doc.horizontal" : "list.bullet")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(HS.teal)
                        .frame(width: 34, height: 34)
                        .background(HS.tealBg)
                        .clipShape(Circle())
                }
                if canManage {
                    Button {
                        HSHaptic.tap(); showingAdd = true
                    } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 15, weight: .bold))
                            .foregroundStyle(HS.onAccent)
                            .frame(width: 34, height: 34)
                            .background(HS.teal)
                            .clipShape(Circle())
                    }
                }
            }
        }
    }

    // MARK: Stats

    private var statGrid: some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: HSMetric.rowGap),
                            GridItem(.flexible(), spacing: HSMetric.rowGap)],
                  spacing: HSMetric.rowGap) {

            HSStatTile(value: "\(store.overdueCount)", label: "Overdue",
                       accent: HS.red, icon: "exclamationmark.triangle.fill") {
                HSHaptic.select(); store.filter = .overdue; mode = .list
            }
            HSStatTile(value: "\(store.thisWeekCount)", label: "Due this week",
                       accent: HS.amber, icon: "calendar") {
                HSHaptic.select(); store.filter = .thisWeek; mode = .list
            }
            HSStatTile(value: "\(store.atRiskCount)", label: "Behind pace",
                       accent: HS.violet, icon: "gauge.with.dots.needle.33percent") {
                HSHaptic.select(); store.filter = .atRisk; mode = .list
            }
            HSStatTile(value: "\(store.completeCount)", label: "Completed",
                       accent: HS.green, icon: "checkmark.seal.fill") {
                HSHaptic.select(); store.filter = .complete; mode = .list
            }
        }
        .hsGutter()
        .padding(.top, 14)
    }

    @ViewBuilder
    private var riskBanner: some View {
        if store.overdueCount > 0 || store.atRiskCount > 0 {
            DLRiskBanner(overdue: store.overdueCount,
                         atRisk: store.atRiskCount,
                         criticalOpen: store.criticalOpen) {
                store.filter = store.overdueCount > 0 ? .overdue : .atRisk
                mode = .list
            }
            .hsGutter()
            .padding(.top, 12)
        }
    }

    // MARK: Week rail

    private var railDays: [Date] {
        let start = cal.date(byAdding: .day, value: -3, to: cal.startOfDay(for: Date())) ?? Date()
        return (0..<21).compactMap { cal.date(byAdding: .day, value: $0, to: start) }
    }

    private var weekRail: some View {
        VStack(alignment: .leading, spacing: 8) {
            HSSectionHeader(title: "Next three weeks",
                            trailing: selectedDay == nil ? nil : "Clear") {
                selectedDay = nil
            }
            .hsGutter()

            DLWeekRail(days: railDays,
                       load: { store.load(on: $0) },
                       overdueOn: { store.hasOverdue(on: $0) },
                       selected: $selectedDay)
        }
        .padding(.top, HSMetric.sectionGapTop)
    }

    // MARK: Segments + filters

    private var segments: some View {
        VStack(spacing: 10) {
            HSSegmented(items: [
                .init(id: DLFilter.all,      title: "All",       count: store.scopedItems.count),
                .init(id: DLFilter.overdue,  title: "Overdue",   count: store.overdueCount),
                .init(id: DLFilter.thisWeek, title: "This week", count: store.thisWeekCount),
                .init(id: DLFilter.atRisk,   title: "At risk",   count: store.atRiskCount),
                .init(id: DLFilter.complete, title: "Complete",  count: store.completeCount)
            ], selection: $store.filter)

            HStack(spacing: 10) {
                HSSearchField(placeholder: "Search deadlines, floors, trades", text: $store.search)
                DLGroupingButton(grouping: $store.grouping)
            }
            .hsGutter()

            HSChipRow(chips: store.trades.map { .init(id: $0, title: $0) },
                      selection: $store.tradeFilter)
                .hsGutter()
        }
        .padding(.top, HSMetric.sectionGapTop)
    }

    // MARK: List

    private var visibleGroups: [DLGroup] {
        let groups = store.groups()
        guard let day = selectedDay else { return groups }
        return groups.compactMap { g in
            let filtered = g.items.filter { cal.isDate($0.due, inSameDayAs: day) }
            return filtered.isEmpty ? nil : DLGroup(id: g.id, title: g.title,
                                                    items: filtered, accent: g.accent)
        }
    }

    @ViewBuilder
    private var listBody: some View {
        let groups = visibleGroups

        if groups.isEmpty {
            HSEmptyState(icon: "calendar.badge.checkmark",
                         title: emptyTitle,
                         message: emptyMessage,
                         actionTitle: canManage && store.filter == .all ? "Add a deadline" : nil,
                         action: canManage && store.filter == .all ? { HSHaptic.tap(); showingAdd = true } : nil)
            .hsGutter()
            .padding(.top, 30)
        } else {
            LazyVStack(spacing: 0) {
                ForEach(groups) { group in
                    DLGroupHeader(title: group.title, count: group.items.count, accent: group.accent)
                        .hsGutter()
                        .padding(.top, HSMetric.sectionGapTop)
                        .padding(.bottom, HSMetric.sectionGapBot)

                    ForEach(group.items) { item in
                        DLDeadlineCard(item: item,
                                       showLocation: store.grouping != .location,
                                       onOpen: { openItem = item },
                                       onUpdate: canManage ? { openItem = item } : nil)
                            .hsGutter()
                            .padding(.bottom, HSMetric.rowGap)
                    }
                }
            }
        }
    }

    private var emptyTitle: String {
        switch store.filter {
        case .overdue:  return "Nothing overdue"
        case .atRisk:   return "Everything on pace"
        case .thisWeek: return "Nothing due this week"
        case .complete: return "Nothing completed yet"
        case .all:      return "No deadlines yet"
        }
    }

    private var emptyMessage: String {
        store.filter == .all
            ? (canManage
               ? "Add the key dates for this \(contextKind.lowercased()) — first fix, sign-offs, handovers — and they will show here in order of urgency."
               : "Deadlines assigned to you on this \(contextKind.lowercased()) will show here.")
            : "Nothing matches this filter right now. Switch back to All to see the full programme."
    }

    // MARK: Timeline

    private var timelineWindowStart: Date {
        cal.date(byAdding: .day, value: -7, to: cal.startOfDay(for: Date())) ?? Date()
    }

    @ViewBuilder
    private var timelineBody: some View {
        let items = store.timelineItems()
        let windowDays = 42

        VStack(alignment: .leading, spacing: 10) {
            HSSectionHeader(title: "Six week view")
                .hsGutter()

            if items.isEmpty {
                HSEmptyState(icon: "chart.bar.doc.horizontal",
                             title: "Nothing to plot",
                             message: "Open deadlines with a start and due date appear here as bars.")
                    .hsGutter()
                    .padding(.top, 20)
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    DLTimelineScale(windowStart: timelineWindowStart, windowDays: windowDays)
                        .padding(.horizontal, 12)
                        .padding(.top, 12)
                        .padding(.bottom, 4)

                    ForEach(Array(items.enumerated()), id: \.element.id) { idx, item in
                        DLTimelineRow(item: item,
                                      windowStart: timelineWindowStart,
                                      windowDays: windowDays,
                                      onOpen: { openItem = item })
                        if idx < items.count - 1 { HSDivider(inset: 12) }
                    }
                }
                .background(HS.card)
                .clipShape(RoundedRectangle(cornerRadius: HSMetric.cardRadius, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: HSMetric.cardRadius, style: .continuous)
                        .strokeBorder(HS.line, lineWidth: 1)
                )
                .overlay(alignment: .topLeading) {
                    // "Today" line drawn across every row.
                    GeometryReader { geo in
                        let usable = geo.size.width - 24
                        let x = 12 + usable * (7.0 / CGFloat(windowDays))
                        Rectangle()
                            .fill(HS.teal.opacity(0.55))
                            .frame(width: 1.5)
                            .offset(x: x, y: 26)
                    }
                }
                .shadow(color: HS.shadowStrong, radius: 14, x: 0, y: 6)
                .hsGutter()

                Text("Bars run start to due. The pale end of a bar is work still outstanding; the teal line is today.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(HS.slate2)
                    .hsNoClip(3)
                    .hsGutter()
                    .padding(.top, 8)
            }
        }
        .padding(.top, HSMetric.sectionGapTop)
    }
}

// =====================================================================
// MARK: - 2. DEADLINE DETAIL SHEET
// =====================================================================

struct DLDeadlineDetailSheet: View {

    let item: DLDeadline
    @ObservedObject var store: DLStore
    var canManage: Bool = true
    var authorName: String = "Farnie Nel"
    var siteAudits: [DLSiteAuditRef] = []
    var project: Project? = nil
    var jobSiteAudits: [SiteAudit] = []
    var people: [DLPerson] = []
    var tradeOptions: [String] = ["General"]
    var contextKind: String = "Project"
    var onCommit: ((DLDeadline, URL?) -> Void)? = nil

    @Environment(\.dismiss) private var dismiss
    @State private var showReschedule = false
    @State private var showingEdit = false
    @State private var percent: Int = 0
    @State private var confirmComplete = false
    @State private var preview: HSDocumentPreviewItem?
    @State private var openAudit: SiteAudit?

    private var live: DLDeadline { store.items.first(where: { $0.id == item.id }) ?? item }

    var body: some View {
        VStack(spacing: 0) {
            HSNavBar(title: "Deadline",
                     subtitle: live.location,
                     onBack: { dismiss() },
                     backSymbol: "xmark") {
                if canManage {
                    Button {
                        HSHaptic.tap()
                        showingEdit = true
                    } label: {
                        Image(systemName: "pencil")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(HS.teal)
                            .frame(width: 34, height: 34)
                            .background(HS.tealBg)
                            .clipShape(Circle())
                    }
                    .accessibilityLabel("Edit deadline")
                }
            }

            ScrollView(showsIndicators: false) {
                VStack(spacing: 0) {
                    DLDetailHero(item: live)
                        .hsGutter()
                        .padding(.top, 4)

                    progressCard
                    detailsCard
                    attachmentCard
                    dependenciesSection
                    notesCard
                    historySection

                    Color.clear.frame(height: 20)
                }
            }

            if canManage {
                HSBottomBar {
                    HStack(spacing: 10) {
                        Button {
                            HSHaptic.tap(); showReschedule = true
                        } label: {
                            Label("Reschedule", systemImage: "calendar.badge.clock")
                        }
                        .buttonStyle(HSGhostButton(tint: HS.amber))

                        if live.status != .complete {
                            Button {
                                HSHaptic.success()
                                store.complete(live, author: authorName)
                                confirmComplete = true
                            } label: {
                                Label("Mark complete", systemImage: "checkmark")
                            }
                            .buttonStyle(HSFilledButton(tone: .teal))
                        }
                    }
                }
            }
        }
        .hsScreen()
        .onAppear { percent = live.progressPercent }
        .sheet(isPresented: $showReschedule) {
            DLRescheduleSheet(item: live, store: store, authorName: authorName)
        }
        .sheet(isPresented: $showingEdit) {
            DLEditDeadlineScreen(
                contextKind: contextKind,
                existing: live,
                people: people,
                siteAudits: siteAudits,
                tradeOptions: tradeOptions,
                authorName: authorName,
                onSave: { deadline, fileURL in
                    if let onCommit {
                        onCommit(deadline, fileURL)
                    } else {
                        store.upsert(deadline)
                    }
                }
            )
        }
        .sheet(item: $preview) { item in
            InAppRemoteDocumentViewer(source: item.source, title: item.title, noun: item.noun)
        }
        .sheet(item: $openAudit) { audit in
            SiteAuditDetailView(audit: audit, project: project)
        }
    }

    // MARK: Progress

    private var progressCard: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack {
                Text("PROGRESS")
                    .font(HSFont.sectionLabel).tracking(0.9)
                    .foregroundStyle(HS.slate2)
                Spacer()
                HSBadge(text: live.status.label,
                        tone: badgeTone(for: live.status),
                        icon: live.status.icon)
            }

            DLPacingBlock(item: live)

            if canManage {
                DLProgressPicker(percent: $percent)

                if percent != live.progressPercent {
                    Button {
                        HSHaptic.success()
                        store.setProgress(live, to: percent, author: authorName)
                    } label: {
                        Text("Save progress")
                    }
                    .buttonStyle(HSFilledButton(tone: .teal, size: 12))
                }
            }

            if let gap = live.pacingGap(), gap >= 5, live.status != .complete {
                Text("At the current rate this finishes around \(DLFormat.day(projectedFinish)). That is \(gap)% behind where the programme expects it to be today.")
                    .font(.system(size: 12.5))
                    .foregroundStyle(HS.inkSoft)
                    .hsNoClip(4)
                    .padding(11)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(HS.amberBg)
                    .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
            }
        }
        .hsCard()
        .hsGutter()
        .padding(.top, HSMetric.sectionGapTop)
    }

    /// Straight-line extrapolation from progress so far. Crude on purpose —
    /// it is a prompt to act, not a forecast anybody should plan around.
    private var projectedFinish: Date {
        guard let start = live.start, live.progress > 0.02 else { return live.due }
        let elapsed = Date().timeIntervalSince(start)
        let total = elapsed / live.progress
        return start.addingTimeInterval(total)
    }

    private func badgeTone(for status: DLStatus) -> HSBadge.Tone {
        switch status {
        case .complete:   return .ok
        case .blocked:    return .scheduled
        case .inProgress: return .brand
        case .notStarted: return .neutral
        }
    }

    // MARK: Details

    private var detailsCard: some View {
        VStack(spacing: 0) {
            HSRowGroup {
                DLFieldRow(icon: "building.2.fill", tint: HS.inkSoft, label: "Location") {
                    Text(live.location ?? "Not set")
                        .font(.system(size: 14.5, weight: .semibold))
                        .foregroundStyle(HS.ink).hsNoClip(2)
                }
                HSDivider(inset: 62)
                DLFieldRow(icon: "wrench.and.screwdriver.fill", tint: HS.blue, label: "Trade") {
                    Text(live.trade ?? "Not set")
                        .font(.system(size: 14.5, weight: .semibold))
                        .foregroundStyle(HS.ink).hsNoClip(2)
                }
                HSDivider(inset: 62)
                DLFieldRow(icon: "person.2.fill", tint: HS.violet, label: "Responsible") {
                    Text(live.assignees.isEmpty
                         ? "Unassigned"
                         : live.assignees.joined(separator: ", ")
                            + (live.company.map { " · \($0)" } ?? ""))
                        .font(.system(size: 14.5, weight: .semibold))
                        .foregroundStyle(HS.ink).hsNoClip(3)
                }
                HSDivider(inset: 62)
                DLFieldRow(icon: "bell.fill", tint: HS.amber, label: "Reminder") {
                    Text(live.reminderDaysBefore.map { "\($0) days before, and on the day" } ?? "None")
                        .font(.system(size: 14.5, weight: .semibold))
                        .foregroundStyle(HS.ink).hsNoClip(2)
                }
            }
            .hsGutter()
        }
        .padding(.top, HSMetric.rowGap)
    }

    @ViewBuilder
    private var attachmentCard: some View {
        let hasFile = (live.fileURL?.isEmpty == false) || (live.fileName?.isEmpty == false)
        let audit = siteAudits.first(where: { $0.id == live.siteAuditId })
        if hasFile || live.siteAuditId != nil {
            VStack(alignment: .leading, spacing: HSMetric.sectionGapBot) {
                HSSectionHeader(title: "Attached").hsGutter()
                HSRowGroup {
                    if hasFile {
                        Button {
                            HSHaptic.tap()
                            if let raw = live.fileURL, let url = URL(string: raw) {
                                preview = HSDocumentPreviewItem(title: live.fileName ?? live.title, remoteURL: url, noun: "file")
                            }
                        } label: {
                            DLFieldRow(icon: "doc.fill", tint: HS.blue, label: "File") {
                                Text(live.fileName ?? "Attached file")
                                    .font(.system(size: 14.5, weight: .semibold))
                                    .foregroundStyle(HS.ink).hsNoClip(2)
                            }
                        }
                        .buttonStyle(HSPressStyle())
                    }
                    if hasFile && live.siteAuditId != nil {
                        HSDivider(inset: 62)
                    }
                    if live.siteAuditId != nil {
                        Button {
                            HSHaptic.tap()
                            if let audit = jobSiteAudits.first(where: { $0.id == live.siteAuditId }) {
                                openAudit = audit
                            }
                        } label: {
                            DLFieldRow(icon: "clipboard.fill", tint: HS.teal, label: "Site audit") {
                                HStack(spacing: 6) {
                                    Text(audit?.title ?? live.siteAuditTitle ?? "Attached site audit")
                                        .font(.system(size: 14.5, weight: .semibold))
                                        .foregroundStyle(HS.ink)
                                        .hsNoClip(2)
                                    Image(systemName: "chevron.right")
                                        .font(.system(size: 11, weight: .bold))
                                        .foregroundStyle(HS.slate2)
                                }
                            }
                        }
                        .buttonStyle(HSPressStyle())
                        .disabled(jobSiteAudits.first(where: { $0.id == live.siteAuditId }) == nil)
                    }
                }
                .hsGutter()
            }
            .padding(.top, HSMetric.sectionGapTop)
        }
    }

    // MARK: Dependencies

    @ViewBuilder
    private var dependenciesSection: some View {
        let before = store.predecessors(of: live)
        let after  = store.dependents(of: live)

        if !before.isEmpty || !after.isEmpty {
            VStack(alignment: .leading, spacing: HSMetric.sectionGapBot) {
                HSSectionHeader(title: "Knock-on effects").hsGutter()

                HSRowGroup {
                    ForEach(Array(before.enumerated()), id: \.element.id) { idx, dep in
                        DLDependencyRow(item: dep, direction: .predecessor, onOpen: {})
                        if idx < before.count - 1 || !after.isEmpty { HSDivider(inset: 62) }
                    }
                    ForEach(Array(after.enumerated()), id: \.element.id) { idx, dep in
                        DLDependencyRow(item: dep, direction: .dependent, onOpen: {})
                        if idx < after.count - 1 { HSDivider(inset: 62) }
                    }
                }
                .hsGutter()
            }
            .padding(.top, HSMetric.sectionGapTop)
        }
    }

    // MARK: Notes

    @ViewBuilder
    private var notesCard: some View {
        if let detail = live.detail, !detail.isEmpty {
            VStack(alignment: .leading, spacing: HSMetric.sectionGapBot) {
                HSSectionHeader(title: "Scope").hsGutter()
                Text(detail)
                    .font(HSFont.body)
                    .foregroundStyle(HS.inkSoft)
                    .hsNoClip(8)
                    .hsCard()
                    .hsGutter()
            }
            .padding(.top, HSMetric.sectionGapTop)
        }
    }

    // MARK: History

    @ViewBuilder
    private var historySection: some View {
        if !live.history.isEmpty {
            VStack(alignment: .leading, spacing: HSMetric.sectionGapBot) {
                HSSectionHeader(title: "History").hsGutter()

                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(live.history.enumerated()), id: \.element.id) { idx, change in
                        DLHistoryRow(change: change, isLast: idx == live.history.count - 1)
                    }
                }
                .hsCard()
                .hsGutter()

                Text("Every date change is recorded with who moved it and why. This is the record you will want if the programme is ever disputed.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(HS.slate2)
                    .hsNoClip(3)
                    .hsGutter()
                    .padding(.top, 6)
            }
            .padding(.top, HSMetric.sectionGapTop)
        }
    }
}

// =====================================================================
// MARK: - 3. RESCHEDULE SHEET
// =====================================================================
//
// A date cannot be moved without a reason. That single constraint is what
// turns the deadline list into an audit trail instead of a wishlist.

struct DLRescheduleSheet: View {

    let item: DLDeadline
    @ObservedObject var store: DLStore
    var authorName: String = "Farnie Nel"

    @Environment(\.dismiss) private var dismiss
    @State private var newDate: Date
    @State private var reason: String = ""
    @State private var picked: String? = nil

    private let reasons = ["Materials", "Preceding trade", "Access", "Weather",
                           "Labour", "Client change", "Design change", "Inspection"]

    init(item: DLDeadline, store: DLStore, authorName: String = "Farnie Nel") {
        self.item = item
        _store = ObservedObject(wrappedValue: store)
        self.authorName = authorName
        _newDate = State(initialValue: item.due)
    }

    private var movedDays: Int {
        Calendar.current.dateComponents([.day],
                                        from: Calendar.current.startOfDay(for: item.due),
                                        to: Calendar.current.startOfDay(for: newDate)).day ?? 0
    }

    private var canSave: Bool { movedDays != 0 && !(picked ?? reason).isEmpty }

    var body: some View {
        VStack(spacing: 0) {
            HSNavBar(title: "Reschedule",
                     subtitle: item.title,
                     onBack: { dismiss() },
                     backSymbol: "xmark") { EmptyView() }

            ScrollView(showsIndicators: false) {
                VStack(spacing: 0) {

                    // Current → new
                    HStack(spacing: 14) {
                        dateBlock(label: "CURRENTLY", date: item.due, tint: HS.slate)
                        Image(systemName: "arrow.right")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(HS.slate2)
                        dateBlock(label: "MOVING TO", date: newDate,
                                  tint: movedDays > 0 ? HS.red : (movedDays < 0 ? HS.green : HS.slate))
                    }
                    .hsCard()
                    .hsGutter()
                    .padding(.top, 8)

                    if movedDays != 0 {
                        Text(movedDays > 0
                             ? "Pushing back \(movedDays) day\(movedDays == 1 ? "" : "s")"
                             : "Pulling forward \(-movedDays) day\(movedDays == -1 ? "" : "s")")
                            .font(.system(size: 12.5, weight: .bold))
                            .foregroundStyle(movedDays > 0 ? HS.red : HS.green)
                            .hsGutter()
                            .padding(.top, 8)
                    }

                    DatePicker("", selection: $newDate, displayedComponents: .date)
                        .datePickerStyle(.graphical)
                        .tint(HS.teal)
                        .hsCard()
                        .hsGutter()
                        .padding(.top, HSMetric.rowGap)

                    impactWarning

                    // Reason
                    VStack(alignment: .leading, spacing: HSMetric.sectionGapBot) {
                        HSSectionHeader(title: "Reason — required").hsGutter()

                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                ForEach(reasons, id: \.self) { r in
                                    let active = picked == r
                                    Button {
                                        HSHaptic.select()
                                        picked = active ? nil : r
                                    } label: {
                                        Text(r)
                                            .font(.system(size: 13, weight: .semibold))
                                            .foregroundStyle(active ? HS.onAccent : HS.inkSoft)
                                            .lineLimit(1)
                                            .fixedSize()
                                            .padding(.horizontal, 13)
                                            .padding(.vertical, 8)
                                            .background(active ? HS.amber : HS.fill)
                                            .clipShape(Capsule())
                                    }
                                    .buttonStyle(HSPressStyle())
                                }
                            }
                            .hsGutter()
                        }

                        TextField("Add detail (optional)", text: $reason, axis: .vertical)
                            .font(HSFont.body)
                            .foregroundStyle(HS.ink)
                            .lineLimit(2...5)
                            .hsCard()
                            .hsGutter()
                    }
                    .padding(.top, HSMetric.sectionGapTop)

                    Color.clear.frame(height: 20)
                }
            }

            HSBottomBar {
                VStack(spacing: 8) {
                    if !canSave {
                        Text(movedDays == 0
                             ? "Pick a different date to continue"
                             : "Choose a reason to continue")
                            .font(.system(size: 12))
                            .foregroundStyle(HS.slate2)
                    }
                    Button {
                        HSHaptic.success()
                        let text = [picked, reason.isEmpty ? nil : reason]
                            .compactMap { $0 }.joined(separator: " — ")
                        store.reschedule(item, to: newDate, reason: text, author: authorName)
                        dismiss()
                    } label: {
                        Text("Confirm new date")
                    }
                    .buttonStyle(HSFilledButton(tone: .teal))
                    .disabled(!canSave)
                    .opacity(canSave ? 1 : 0.45)
                }
            }
        }
        .hsScreen()
    }

    private func dateBlock(label: String, date: Date, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(.system(size: 10, weight: .bold)).tracking(0.8)
                .foregroundStyle(HS.slate2)
            Text(DLFormat.day(date))
                .font(.system(size: 19, weight: .heavy))
                .foregroundStyle(tint)
                .lineLimit(1).minimumScaleFactor(0.7)
            Text(DLFormat.weekCommencing(date))
                .font(.system(size: 11))
                .foregroundStyle(HS.slate2)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var impactWarning: some View {
        let knockOn = store.dependents(of: item)
        if !knockOn.isEmpty && movedDays > 0 {
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.triangle.branch")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(HS.violet)
                    Text("\(knockOn.count) deadline\(knockOn.count == 1 ? "" : "s") depend\(knockOn.count == 1 ? "s" : "") on this")
                        .font(.system(size: 13.5, weight: .bold))
                        .foregroundStyle(HS.ink)
                        .hsNoClip(2)
                }
                ForEach(knockOn) { dep in
                    Text("· \(dep.title) — currently due \(DLFormat.day(dep.due))")
                        .font(.system(size: 12))
                        .foregroundStyle(HS.inkSoft)
                        .hsNoClip(2)
                }
                Text("They are not moved automatically. Review them after saving.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(HS.slate)
                    .hsNoClip(2)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(HS.violetBg)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .hsGutter()
            .padding(.top, HSMetric.rowGap)
        }
    }
}

// =====================================================================
// MARK: - 4. ADD / EDIT DEADLINE
// =====================================================================

struct DLEditDeadlineScreen: View {

    var contextKind: String = "Project"
    var existing: DLDeadline? = nil
    var people: [DLPerson] = []
    var siteAudits: [DLSiteAuditRef] = []
    var tradeOptions: [String] = ["General"]
    var authorName: String = "Farnie Nel"
    var createdByUserId: String = ""
    var projectId: UUID? = nil
    var pendingFileURL: URL? = nil
    var pendingFileName: String? = nil
    var onSave: ((DLDeadline, URL?) -> Void)? = nil

    @Environment(\.dismiss) private var dismiss

    @State private var title = ""
    @State private var location = ""
    @State private var locationIsCustom = false
    @State private var trade = "General"
    @State private var due = Date()
    @State private var start = Date()
    @State private var hasStart = true
    @State private var selectedPersonIds: Set<String> = []
    @State private var extraSearch = ""
    @State private var isCritical = false
    @State private var reminder = true
    @State private var detail = ""
    @State private var selectedAuditId: UUID?
    @State private var showingAuditPicker = false
    @State private var showingFilePicker = false
    @State private var pickedFileURL: URL?
    @State private var pickedFileName: String?

    private let locationPresets = ["Ground Floor", "1st Floor", "2nd Floor", "3rd Floor",
                                   "Roof", "Risers", "External", "Basement"]

    private var canSave: Bool { !title.trimmingCharacters(in: .whitespaces).isEmpty }

    private var livePeople: [DLPerson] { people.filter(\.isLive) }
    private var extraPeople: [DLPerson] {
        let q = extraSearch.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return people.filter { person in
            guard !person.isLive else { return false }
            if q.isEmpty { return true }
            return person.name.lowercased().contains(q) || person.subtitle.lowercased().contains(q)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HSNavBar(title: existing == nil ? "New deadline" : "Edit deadline",
                     subtitle: contextKind,
                     onBack: { dismiss() },
                     backSymbol: "xmark") { EmptyView() }

            ScrollView(showsIndicators: false) {
                VStack(spacing: 0) {
                    whatSection
                    whereSection
                    whenSection
                    whoSection
                    attachSection
                    flagsSection
                    Color.clear.frame(height: 20)
                }
            }

            HSBottomBar {
                VStack(spacing: 8) {
                    if !canSave {
                        Text("Give the deadline a title to continue")
                            .font(.system(size: 12))
                            .foregroundStyle(HS.slate2)
                    }
                    Button {
                        HSHaptic.success()
                        onSave?(builtDeadline(), pickedFileURL)
                        dismiss()
                    } label: {
                        Text(existing == nil ? "Add deadline" : "Save changes")
                    }
                    .buttonStyle(HSFilledButton(tone: .teal))
                    .disabled(!canSave)
                    .opacity(canSave ? 1 : 0.45)
                }
            }
        }
        .hsScreen()
        .sheet(isPresented: $showingAuditPicker) {
            DLSiteAuditAttachSheet(
                audits: siteAudits,
                selectedId: $selectedAuditId
            )
        }
        .fileImporter(
            isPresented: $showingFilePicker,
            allowedContentTypes: [.item, .pdf, .image, .data],
            allowsMultipleSelection: false
        ) { result in
            if case .success(let urls) = result, let url = urls.first, let persisted = HSImportedFile.persist(url) {
                pickedFileURL = persisted.url
                pickedFileName = persisted.name
            }
        }
        .onAppear { hydrateFromExisting() }
    }

    private var whatSection: some View {
        VStack(alignment: .leading, spacing: HSMetric.sectionGapBot) {
            HSSectionHeader(title: "What is due").hsGutter()
            VStack(alignment: .leading, spacing: 10) {
                TextField("e.g. 3rd Floor WC 1st Fix", text: $title)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(HS.ink)
                HSDivider(inset: 0)
                TextField("Scope detail (optional)", text: $detail, axis: .vertical)
                    .font(HSFont.body)
                    .foregroundStyle(HS.inkSoft)
                    .lineLimit(2...5)
            }
            .hsCard()
            .hsGutter()
        }
        .padding(.top, 8)
    }

    private var whereSection: some View {
        VStack(alignment: .leading, spacing: HSMetric.sectionGapBot) {
            HSSectionHeader(title: "Where").hsGutter()

            Color.clear
                .frame(height: 38)
                .frame(maxWidth: .infinity)
                .overlay(alignment: .leading) {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            locationChip(title: "Custom", selected: locationIsCustom) {
                                HSHaptic.select()
                                if !locationIsCustom {
                                    if locationPresets.contains(location) {
                                        location = ""
                                    }
                                    locationIsCustom = true
                                }
                            }
                            ForEach(locationPresets, id: \.self) { area in
                                locationChip(title: area, selected: !locationIsCustom && location == area) {
                                    HSHaptic.select()
                                    locationIsCustom = false
                                    location = area
                                }
                            }
                        }
                        .hsGutter()
                    }
                }

            if locationIsCustom {
                TextField("Type floor or area", text: $location)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(HS.ink)
                    .hsCard()
                    .hsGutter()
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(.top, HSMetric.sectionGapTop)
        .animation(.easeOut(duration: 0.18), value: locationIsCustom)
    }

    private func locationChip(title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(selected ? HS.onAccent : HS.slate)
                .fixedSize()
                .padding(.horizontal, 12).padding(.vertical, 7)
                .background(selected ? HS.teal : HS.fill)
                .clipShape(Capsule())
        }
        .buttonStyle(HSPressStyle())
    }

    private var whenSection: some View {
        VStack(alignment: .leading, spacing: HSMetric.sectionGapBot) {
            HSSectionHeader(title: "When").hsGutter()
            HSRowGroup {
                DLToggleRow(icon: "play.circle.fill", tint: HS.blue,
                            title: "Has a start date",
                            subtitle: "Needed for pace tracking and the timeline",
                            isOn: $hasStart)
                if hasStart {
                    HSDivider(inset: 62)
                    DLFieldRow(icon: "calendar", tint: HS.blue, label: "Starts") {
                        DatePicker("", selection: $start, displayedComponents: .date)
                            .labelsHidden().tint(HS.teal)
                    }
                }
                HSDivider(inset: 62)
                DLFieldRow(icon: "flag.checkered", tint: HS.teal, label: "Due") {
                    DatePicker("", selection: $due, displayedComponents: .date)
                        .labelsHidden().tint(HS.teal)
                }
            }
            .hsGutter()
        }
        .padding(.top, HSMetric.sectionGapTop)
    }

    private var whoSection: some View {
        VStack(alignment: .leading, spacing: HSMetric.sectionGapBot) {
            HStack {
                HSSectionHeader(title: "Who")
                Spacer()
                if !livePeople.isEmpty {
                    Button {
                        HSHaptic.select()
                        if livePeople.allSatisfy({ selectedPersonIds.contains($0.id) }) {
                            selectedPersonIds.subtract(livePeople.map(\.id))
                        } else {
                            selectedPersonIds.formUnion(livePeople.map(\.id))
                        }
                    } label: {
                        Text(livePeople.allSatisfy({ selectedPersonIds.contains($0.id) }) ? "Clear live" : "Select all live users")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(HS.teal)
                    }
                    .buttonStyle(HSPressStyle())
                }
            }
            .hsGutter()

            if livePeople.isEmpty && extraPeople.isEmpty {
                Text("No people available to assign yet.")
                    .font(.system(size: 13.5))
                    .foregroundStyle(HS.slate)
                    .hsCard()
                    .hsGutter()
            } else {
                if !livePeople.isEmpty {
                    Text("Booked or tasked on this job")
                        .font(.system(size: 11.5, weight: .bold))
                        .foregroundStyle(HS.slate2)
                        .hsGutter()
                    peopleList(livePeople)
                }
                if !people.filter({ !$0.isLive }).isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Add extra people")
                            .font(.system(size: 11.5, weight: .bold))
                            .foregroundStyle(HS.slate2)
                        HSSearchField(placeholder: "Search everyone else", text: $extraSearch)
                    }
                    .hsGutter()
                    .padding(.top, 8)
                    peopleList(extraPeople)
                }
            }

            HSRowGroup {
                DLFieldRow(icon: "wrench.and.screwdriver.fill", tint: HS.blue, label: "Trade") {
                    Menu {
                        ForEach(tradeOptions, id: \.self) { t in
                            Button(t) { HSHaptic.select(); trade = t }
                        }
                    } label: {
                        HStack(spacing: 5) {
                            Text(trade)
                                .font(.system(size: 14.5, weight: .semibold))
                                .foregroundStyle(HS.ink)
                            Image(systemName: "chevron.down")
                                .font(.system(size: 9, weight: .black))
                                .foregroundStyle(HS.slate2)
                        }
                    }
                }
            }
            .hsGutter()
            .padding(.top, 8)
        }
        .padding(.top, HSMetric.sectionGapTop)
    }

    private func peopleList(_ list: [DLPerson]) -> some View {
        HSRowGroup {
            ForEach(Array(list.enumerated()), id: \.element.id) { idx, person in
                Button {
                    HSHaptic.select()
                    if selectedPersonIds.contains(person.id) {
                        selectedPersonIds.remove(person.id)
                    } else {
                        selectedPersonIds.insert(person.id)
                    }
                } label: {
                    HStack(spacing: 12) {
                        HSIconTile(systemName: selectedPersonIds.contains(person.id) ? "checkmark.circle.fill" : "circle",
                                   tint: selectedPersonIds.contains(person.id) ? HS.teal : HS.slate2,
                                   size: 32)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(person.name)
                                .font(.system(size: 14.5, weight: .semibold))
                                .foregroundStyle(HS.ink)
                                .hsNoClip(2)
                            Text(person.subtitle)
                                .font(.system(size: 12))
                                .foregroundStyle(HS.slate)
                                .hsNoClip(1)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .contentShape(Rectangle())
                }
                .buttonStyle(HSPressStyle())
                if idx < list.count - 1 { HSDivider(inset: 58) }
            }
        }
        .hsGutter()
    }

    private var attachSection: some View {
        VStack(alignment: .leading, spacing: HSMetric.sectionGapBot) {
            HSSectionHeader(title: "Attach").hsGutter()
            HSRowGroup {
                Button {
                    HSHaptic.tap()
                    showingFilePicker = true
                } label: {
                    DLFieldRow(icon: "paperclip", tint: HS.blue, label: "File") {
                        Text(displayedFileName)
                            .font(.system(size: 14.5, weight: .semibold))
                            .foregroundStyle(HS.ink)
                            .hsNoClip(2)
                    }
                }
                .buttonStyle(HSPressStyle())
                HSDivider(inset: 62)
                Button {
                    HSHaptic.tap()
                    showingAuditPicker = true
                } label: {
                    DLFieldRow(icon: "clipboard.fill", tint: HS.teal, label: "Site audit") {
                        Text(selectedAudit?.title ?? "None — tap to attach one")
                            .font(.system(size: 14.5, weight: .semibold))
                            .foregroundStyle(HS.ink)
                            .hsNoClip(2)
                    }
                }
                .buttonStyle(HSPressStyle())
            }
            .hsGutter()
        }
        .padding(.top, HSMetric.sectionGapTop)
    }

    private var flagsSection: some View {
        VStack(alignment: .leading, spacing: HSMetric.sectionGapBot) {
            HSSectionHeader(title: "Priority and reminders").hsGutter()
            HSRowGroup {
                DLToggleRow(icon: "flag.fill", tint: HS.red,
                            title: "On the critical path",
                            subtitle: "Slipping this pushes the whole programme",
                            isOn: $isCritical)
                HSDivider(inset: 62)
                DLToggleRow(icon: "bell.fill", tint: HS.amber,
                            title: "Remind me",
                            subtitle: "Two days before, and again on the day",
                            isOn: $reminder)
            }
            .hsGutter()
        }
        .padding(.top, HSMetric.sectionGapTop)
    }

    private var displayedFileName: String {
        if let pickedFileName, !pickedFileName.isEmpty { return pickedFileName }
        if let pendingFileName, !pendingFileName.isEmpty { return pendingFileName }
        if let existingName = existing?.fileName, !existingName.isEmpty { return existingName }
        return "None — tap to upload"
    }

    private var selectedAudit: DLSiteAuditRef? {
        siteAudits.first(where: { $0.id == selectedAuditId })
    }

    private func hydrateFromExisting() {
        guard let e = existing else { return }
        title = e.title
        location = e.location ?? ""
        locationIsCustom = {
            guard let loc = e.location, !loc.isEmpty else { return false }
            return !locationPresets.contains(loc)
        }()
        trade = e.trade ?? (tradeOptions.first ?? "General")
        due = e.due
        hasStart = e.start != nil
        start = e.start ?? Date()
        selectedPersonIds = Set(e.assigneeUserIds)
        isCritical = e.isCritical
        reminder = e.reminderDaysBefore != nil
        detail = e.detail ?? ""
        selectedAuditId = e.siteAuditId
        pickedFileName = e.fileName
    }

    private func builtDeadline() -> DLDeadline {
        var d = existing ?? DLDeadline(title: title, due: due)
        d.title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        d.location = location.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : location
        d.trade = trade
        d.detail = detail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : detail
        d.start = hasStart ? start : nil
        d.due = due
        d.isCritical = isCritical
        d.reminderDaysBefore = reminder ? 2 : nil
        d.contextKind = contextKind
        d.projectId = projectId ?? d.projectId
        if d.createdByUserId.isEmpty { d.createdByUserId = createdByUserId }
        let chosen = people.filter { selectedPersonIds.contains($0.id) }
        d.assigneeUserIds = chosen.map(\.id)
        d.assignees = chosen.map(\.name)
        d.siteAuditId = selectedAuditId
        d.siteAuditTitle = selectedAudit?.title
        if let pickedFileName {
            d.fileName = pickedFileName
        }
        if existing == nil {
            var history: [DLChange] = [
                DLChange(at: Date(), author: authorName, kind: .created(due: due))
            ]
            if !chosen.isEmpty {
                history.insert(DLChange(at: Date(), author: authorName, kind: .assigned(to: chosen.map(\.name).joined(separator: ", "))), at: 0)
            }
            d.history = history
        } else if let existing, Set(existing.assigneeUserIds) != selectedPersonIds, !chosen.isEmpty {
            d.history.insert(DLChange(at: Date(), author: authorName, kind: .assigned(to: chosen.map(\.name).joined(separator: ", "))), at: 0)
        }
        if let audit = selectedAudit, existing?.siteAuditId != selectedAuditId {
            d.history.insert(DLChange(at: Date(), author: authorName, kind: .siteAuditAttached(name: audit.title)), at: 0)
        }
        return d
    }
}

struct DLSiteAuditAttachSheet: View {
    let audits: [DLSiteAuditRef]
    @Binding var selectedId: UUID?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HSNavBar(title: "Attach site audit",
                     subtitle: "One per deadline",
                     onBack: { dismiss() },
                     backSymbol: "xmark") { EmptyView() }

            if audits.isEmpty {
                HSEmptyState(icon: "clipboard",
                             title: "No site audits yet",
                             message: "Create a site audit on this job first, then attach it here.")
                    .hsGutter()
                    .padding(.top, 24)
                Spacer()
            } else {
                ScrollView(showsIndicators: false) {
                    VStack(spacing: 10) {
                        ForEach(audits) { audit in
                            let selected = selectedId == audit.id
                            HStack(alignment: .center, spacing: 10) {
                                VStack(alignment: .leading, spacing: 4) {
                                    HStack(spacing: 6) {
                                        Text(audit.typeLabel)
                                            .font(.system(size: 13, weight: .semibold))
                                            .foregroundStyle(HS.ink)
                                        Text(audit.title)
                                            .font(.system(size: 13, weight: .bold))
                                            .foregroundStyle(HS.ink)
                                            .hsNoClip(2)
                                    }
                                    Text(audit.jobLine)
                                        .font(.system(size: 12))
                                        .foregroundStyle(HS.slate)
                                        .hsNoClip(1)
                                    Text("\(audit.authorName) · \(audit.itemCount) items · \(DLFormat.day(audit.date))")
                                        .font(.system(size: 11.5))
                                        .foregroundStyle(HS.slate2)
                                        .hsNoClip(1)
                                }
                                Spacer(minLength: 8)
                                Button {
                                    HSHaptic.select()
                                    selectedId = selected ? nil : audit.id
                                } label: {
                                    Image(systemName: selected ? "checkmark.circle.fill" : "plus.circle.fill")
                                        .font(.system(size: 28, weight: .semibold))
                                        .foregroundStyle(selected ? HS.teal : HS.slate2)
                                }
                                .buttonStyle(HSPressStyle())
                                .accessibilityLabel(selected ? "Remove site audit" : "Attach site audit")
                            }
                            .hsCard()
                        }
                    }
                    .hsGutter()
                    .padding(.top, 8)
                    .padding(.bottom, 24)
                }
            }

            HSBottomBar {
                Button {
                    HSHaptic.success()
                    dismiss()
                } label: {
                    Text(selectedId == nil ? "Done" : "Use this site audit")
                }
                .buttonStyle(HSFilledButton(tone: .teal))
            }
        }
        .hsScreen()
    }
}

// =====================================================================
// MARK: - Previews
// =====================================================================

#if DEBUG

/// Holds a live store so the sheet previews get a real object to mutate.
private struct DLPreviewHost<Content: View>: View {
    @StateObject private var store = DLStore()
    let build: (DLStore) -> Content
    var body: some View { build(store) }
}

#Preview("Deadlines — list") {
    DLPreviewHost { store in
        DLDeadlinesScreen(store: store)
    }
}

#Preview("Deadlines — dark") {
    DLPreviewHost { store in
        DLDeadlinesScreen(store: store)
            .preferredColorScheme(.dark)
    }
}

#Preview("Deadlines — Small Work") {
    DLPreviewHost { store in
        DLDeadlinesScreen(store: store,
                          contextName: "Lancelot Place",
                          contextRef: "SW118",
                          contextKind: "Small Work")
    }
}

#Preview("Detail sheet") {
    DLPreviewHost { store in
        DLDeadlineDetailSheet(item: store.items[0], store: store)
    }
}

#Preview("Reschedule") {
    DLPreviewHost { store in
        DLRescheduleSheet(item: store.items[2], store: store)
    }
}

#Preview("New deadline") {
    DLEditDeadlineScreen(people: [
        DLPerson(id: "1", name: "Dan Whelan", subtitle: "Booked · Plumbing", isLive: true),
        DLPerson(id: "2", name: "Marek Kowal", subtitle: "Tasked · Plumbing", isLive: true),
        DLPerson(id: "3", name: "Ellie Marsh", subtitle: "Manager", isLive: false)
    ])
}
#endif
