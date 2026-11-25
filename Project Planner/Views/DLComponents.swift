//
//  DLComponents.swift
//  Project Planner — Deadlines
//
//  DROP-IN FILE. The components the Deadlines tab is built from.
//  Requires HSTheme.swift (tokens) and DLModels.swift. Reuses HSComponents
//  wherever one already exists — HSNavBar, HSSegmented, HSStatTile, HSBadge,
//  HSSearchField, HSChipRow, HSEmptyState, HSBottomBar, HSRowGroup, buttons.
//
//  Nothing here invents a colour. Every fill comes from the HS token set so
//  the Deadlines tab and the H&S section are visibly the same product.
//

import SwiftUI

// =====================================================================
// MARK: - 1. Countdown pill
// =====================================================================
//
// The single most-read element on the screen. Sits top-right of every card,
// always one line, always the urgency colour.

struct DLCountdownPill: View {
    /// The rulebook's short pill ("Today", "3d", "+2d", "Done") and tone (RULEBOOK 1.94.0 §23 `deadlineDisplay`).
    let text: String
    let tone: String

    var body: some View {
        Text(text)
            .font(.system(size: 12.5, weight: .bold))
            .foregroundStyle(DLTone.color(tone))
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(DLTone.tint(tone))
            .clipShape(Capsule())
            .overlay(Capsule().strokeBorder(DLTone.color(tone).opacity(0.22), lineWidth: 1))
            .fixedSize()
    }
}

// =====================================================================
// MARK: - 2. Critical path flag
// =====================================================================
//
// Deliberately monochrome rather than another colour — the urgency colours
// already own red/amber/green, and "critical" is a different axis entirely.
// HS.ink over HS.bg inverts cleanly in dark mode.

struct DLCriticalFlag: View {
    var text: String = "CRITICAL PATH"

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "flag.fill").font(.system(size: 8.5, weight: .black))
            Text(text).font(.system(size: 9.5, weight: .black)).tracking(0.6)
        }
        .foregroundStyle(HS.bg)
        .padding(.horizontal, 7)
        .padding(.vertical, 3.5)
        .background(HS.ink)
        .clipShape(Capsule())
        .fixedSize()
    }
}

// =====================================================================
// MARK: - 3. Meta chip (location / trade / company)
// =====================================================================

struct DLMetaChip: View {
    let icon: String
    let text: String
    var tint: Color = HS.slate

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: icon).font(.system(size: 9.5, weight: .bold))
            Text(text).font(.system(size: 11.5, weight: .semibold))
        }
        .foregroundStyle(tint)
        .lineLimit(1)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(tint.opacity(0.10))
        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        .fixedSize()
    }
}

// =====================================================================
// MARK: - 4. Pacing bar
// =====================================================================
//
// The cleverest thing in the tab, and the cheapest to build.
//
// A normal progress bar tells you 45% is done. It does not tell you whether
// 45% is good. This one draws a notch at where progress SHOULD be today if
// the work ran evenly from start date to due date. Fill short of the notch =
// behind pace, and the gap is visible from arm's length across a site office.

struct DLPacingBar: View {
    let progress: Double            // 0...1 actual
    var expected: Double? = nil     // 0...1 where we should be today
    var accent: Color = PPColor.brand
    var height: CGFloat = 8
    var showNotch: Bool = true

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            ZStack(alignment: .leading) {
                Capsule().fill(HS.fill)

                Capsule()
                    .fill(LinearGradient(colors: [accent.opacity(0.75), accent],
                                         startPoint: .leading, endPoint: .trailing))
                    .frame(width: max(0, min(progress, 1)) * w)

                if showNotch, let expected, expected > 0.02, expected < 0.99 {
                    // The "should be here" marker.
                    RoundedRectangle(cornerRadius: 1, style: .continuous)
                        .fill(HS.ink.opacity(0.55))
                        .frame(width: 2.5, height: height + 5)
                        .offset(x: min(max(expected, 0), 1) * w - 1.25)
                }
            }
        }
        .frame(height: height)
    }
}

/// Bar plus its caption line. Use this rather than the bare bar. Progress, the "should be here" tick and the pace
/// words ("25% · expected 64%") are the rulebook's (RULEBOOK 1.94.0 §23 `deadlineDisplay`).
struct DLPacingBlock: View {
    let item: DLDeadline
    var now: Date = Date()

    var body: some View {
        let view = item.display(now: now)

        VStack(alignment: .leading, spacing: 6) {
            DLPacingBar(progress: Double(view.progressPercent) / 100,
                        expected: view.expectedPercent.map { Double($0) / 100 },
                        accent: DLTone.color(view.tone),
                        showNotch: !view.isCompleted)

            HStack(spacing: 6) {
                if let pace = view.paceText {
                    Text(pace)
                        .font(.system(size: 11.5, weight: .bold))
                        .foregroundStyle(HS.amber)
                } else {
                    Text("\(view.progressPercent)% complete")
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(HS.slate)
                }
                Spacer(minLength: 0)
            }
            .lineLimit(1)
            .minimumScaleFactor(0.85)
        }
    }
}

// =====================================================================
// MARK: - 5. Assignee stack
// =====================================================================

struct DLAssigneeStack: View {
    let initials: [String]
    var size: CGFloat = 24
    var tint: Color = HS.blue

    var body: some View {
        HStack(spacing: -size * 0.3) {
            ForEach(Array(initials.prefix(3).enumerated()), id: \.offset) { _, s in
                Text(s)
                    .font(.system(size: size * 0.38, weight: .bold))
                    .foregroundStyle(HS.onAccent)
                    .frame(width: size, height: size)
                    .background(Circle().fill(tint))
                    .overlay(Circle().strokeBorder(HS.card, lineWidth: 1.5))
            }
            if initials.count > 3 {
                Text("+\(initials.count - 3)")
                    .font(.system(size: size * 0.34, weight: .bold))
                    .foregroundStyle(HS.slate)
                    .frame(width: size, height: size)
                    .background(Circle().fill(HS.fill))
                    .overlay(Circle().strokeBorder(HS.card, lineWidth: 1.5))
            }
        }
        .fixedSize()
    }
}

// =====================================================================
// MARK: - 6. THE deadline card
// =====================================================================
//
// Layout rule inherited from the H&S brief: the title owns the full card
// width on its own row. Nothing shares a row with it except the countdown
// pill, which is `.fixedSize()` and short by construction. Actions live on
// their own row at the bottom. This is why nothing truncates.

struct DLDeadlineCard: View {
    let item: DLDeadline
    var now: Date = Date()
    var showLocation: Bool = true       // false when the list is grouped BY location
    var onOpen: () -> Void
    var onUpdate: (() -> Void)? = nil

    /// RULEBOOK 1.94.0 §23 `deadlineDisplay`: every word and colour on the card.
    private var view: RulebookDeadlineDisplay { item.display(now: now) }
    private var behindPace: Bool { view.status == "behindPace" }
    private var moved: String { item.movedNote }

    // No wrapping Button (it would swallow taps on the "Update" pill inside) and no press-shrink drag
    // gesture: a DragGesture(minimumDistance: 0) on every card took the finger before the ScrollView,
    // so the Deadlines list could not be scrolled by dragging on a card.

    /// Words first, then the day: "Due in 2 days · Fri 27 Nov 2026"; completed "Met on time" / "Done 3 days late".
    private var dueLine: String {
        if view.isCompleted || view.dueText.isEmpty { return view.dueText.isEmpty ? DLFormat.full(item.due) : view.dueText }
        let day = CanonicalBusinessEngine.deadlineDayText(item.due, withYear: true) ?? DLFormat.full(item.due)
        return "\(view.dueText) · \(day)"
    }

    var body: some View {
            VStack(alignment: .leading, spacing: 11) {

                // Row 1 — flags
                if item.isCritical || behindPace || !moved.isEmpty {
                    PPWrapLayout(spacing: 6) {
                        if item.isCritical { DLCriticalFlag() }
                        if behindPace {
                            HSBadge(text: view.statusLabel, tone: .warn, icon: "gauge.with.dots.needle.33percent")
                        }
                        if !moved.isEmpty {
                            DLMetaChip(icon: "calendar.badge.exclamationmark", text: moved, tint: HS.slate)
                        }
                    }
                }

                // Row 2 — title owns the width; only the pill sits beside it
                HStack(alignment: .top, spacing: 10) {
                    Text(item.title)
                        .font(HSFont.cardTitle)
                        .foregroundStyle(HS.ink)
                        .hsNoClip(2)
                    Spacer(minLength: 6)
                    DLCountdownPill(text: view.pill, tone: view.tone)
                }

                // Row 3 — where and who
                HStack(spacing: 6) {
                    if showLocation, let location = item.floorsText {
                        DLMetaChip(icon: "building.2.fill", text: location, tint: HS.slate)
                    }
                    if let trade = item.trade {
                        DLMetaChip(icon: "wrench.and.screwdriver.fill", text: trade, tint: HS.slate)
                    }
                    Spacer(minLength: 0)
                }

                // Row 4 — blocked reason replaces the pacing bar when held
                if item.status == .blocked, let reason = item.blockedReason {
                    HStack(alignment: .top, spacing: 7) {
                        Image(systemName: "exclamationmark.octagon.fill")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(HS.violet)
                        Text(reason)
                            .font(.system(size: 12.5))
                            .foregroundStyle(HS.inkSoft)
                            .hsNoClip(2)
                    }
                    .padding(9)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(HS.violetBg)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                } else if !view.isCompleted {
                    DLPacingBlock(item: item, now: now)
                }

                HSDivider(inset: 0)

                // Row 5 — footer: due date, people, action
                HStack(spacing: 10) {
                    HStack(spacing: 5) {
                        Image(systemName: view.isCompleted ? "checkmark.seal.fill" : "calendar")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(view.isCompleted ? DLTone.color(view.tone) : HS.slate2)
                        Text(dueLine)
                            .font(HSFont.meta)
                            .foregroundStyle(HS.slate)
                            .lineLimit(1)
                            .minimumScaleFactor(0.85)
                    }

                    Spacer(minLength: 6)

                    if !item.initialsForAssignees.isEmpty {
                        DLAssigneeStack(initials: item.initialsForAssignees, size: 24)
                    }

                    if let onUpdate, !view.isCompleted {
                        Button {
                            HSHaptic.tap(); onUpdate()
                        } label: {
                            Text("Update")
                        }
                        .accessibilityIdentifier("dlDeadlineCard.update")
                        .buttonStyle(HSPillButton(tone: .blue))
                    }
                }
            }
            .padding(.leading, 6)      // room for the spine
            .hsTappableCard()
            .overlay(alignment: .leading) {
                // Urgency spine — readable before a single word is.
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(DLTone.color(view.tone))
                    .frame(width: 4)
                    .padding(.vertical, 14)
                    .padding(.leading, 7)
            }
            .opacity(view.isCompleted ? 0.72 : 1)
            .contentShape(RoundedRectangle(cornerRadius: HSMetric.cardRadius, style: .continuous))
            
            .accessibilityIdentifier("dlDeadlineCard.tap").onTapGesture {
                HSHaptic.tap(); onOpen()
            }
    }
}

// =====================================================================
// MARK: - 7. Group header
// =====================================================================

struct DLGroupHeader: View {
    let title: String
    let count: Int
    var accent: Color? = nil

    var body: some View {
        HStack(spacing: 7) {
            if let accent {
                Circle().fill(accent).frame(width: 7, height: 7)
            }
            Text(title.uppercased())
                .font(.footnote.weight(.semibold))
                .tracking(0.8)
                .foregroundStyle(accent ?? Color.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
            Text("\(count)")
                .font(.caption2.weight(.bold))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .background(PPColor.well)
                .clipShape(Capsule())
            Spacer(minLength: 0)
        }
    }
}

// =====================================================================
// MARK: - 9. Timeline row (the Gantt-lite view)
// =====================================================================
//
// Not a full Gantt — a full Gantt is unusable on a phone. One row per
// deadline, a bar spanning start→due positioned on a shared 6-week scale,
// today marked with a vertical line across the whole view.

struct DLTimelineRow: View {
    let item: DLDeadline
    let windowStart: Date
    let windowDays: Int
    var now: Date = Date()
    var onOpen: () -> Void

    private let cal = OrganizationRulebookContext.calendar

    private func offsetDays(_ date: Date) -> Double {
        Double(cal.dateComponents([.day], from: cal.startOfDay(for: windowStart),
                                  to: cal.startOfDay(for: date)).day ?? 0)
    }

    var body: some View {
        let tone = DLTone.color(item.display(now: now).tone)
        // Clamped to the six-week window, so a deadline before or after it still draws at the edge.
        let s = min(max(offsetDays(item.start ?? item.due), 0), Double(windowDays) - 0.6)
        let e = min(offsetDays(item.due) + 1, Double(windowDays))
        let span = max(e - s, 0.6)

        Button {
            HSHaptic.tap(); onOpen()
        } label: {
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 6) {
                    if item.status == .complete {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(HS.green)
                            .accessibilityLabel("Complete")
                    } else if item.isCritical {
                        Image(systemName: "flag.fill")
                            .font(.system(size: 9, weight: .black))
                            .foregroundStyle(HS.ink)
                    }
                    Text(item.title)
                        .font(.system(size: 13.5, weight: .semibold))
                        .foregroundStyle(HS.ink)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                    Spacer(minLength: 6)
                    Text(DLFormat.day(item.due))
                        .font(.system(size: 11.5, weight: .bold))
                        .foregroundStyle(tone)
                        .fixedSize()
                }

                GeometryReader { geo in
                    let unit = geo.size.width / CGFloat(windowDays)
                    ZStack(alignment: .leading) {
                        // Track
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .fill(HS.fill)
                            .frame(height: 18)

                        // The bar
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .fill(LinearGradient(colors: [tone.opacity(0.80), tone],
                                                 startPoint: .leading, endPoint: .trailing))
                            .frame(width: max(unit * CGFloat(span), 10), height: 18)
                            .overlay(alignment: .leading) {
                                // Progress shading inside the bar
                                RoundedRectangle(cornerRadius: 5, style: .continuous)
                                    .fill(HS.onAccent.opacity(0.28))
                                    .frame(width: max(unit * CGFloat(span), 10) * (1 - item.progress))
                                    .frame(maxWidth: .infinity, alignment: .trailing)
                            }
                            .offset(x: unit * CGFloat(s))
                    }
                }
                .frame(height: 18)
            }
            .padding(.vertical, 9)
            .padding(.horizontal, 12)
        }
        .accessibilityIdentifier("dlTimeline.flagFill")
        .buttonStyle(HSPressStyle())
    }
}

/// Week ruler drawn above the timeline rows, plus the "today" line drawn over them.
struct DLTimelineScale: View {
    let windowStart: Date
    let windowDays: Int

    private let cal = OrganizationRulebookContext.calendar

    var body: some View {
        GeometryReader { geo in
            let unit = geo.size.width / CGFloat(windowDays)
            HStack(spacing: 0) {
                ForEach(0..<(windowDays / 7), id: \.self) { w in
                    let date = cal.date(byAdding: .day, value: w * 7, to: windowStart) ?? windowStart
                    Text(DLFormat.day(date))
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(HS.slate2)
                        .frame(width: unit * 7, alignment: .leading)
                }
            }
        }
        .frame(height: 14)
    }
}

// =====================================================================
// MARK: - 10. Dependency row
// =====================================================================

struct DLDependencyRow: View {
    let item: DLDeadline
    var direction: Direction = .predecessor
    var now: Date = Date()
    var onOpen: () -> Void

    enum Direction { case predecessor, dependent }

    var body: some View {
        Button {
            HSHaptic.tap(); onOpen()
        } label: {
            HStack(spacing: 11) {
                HSIconTile(systemName: direction == .predecessor
                           ? "arrow.turn.left.up" : "arrow.turn.right.down",
                           tint: direction == .predecessor ? HS.violet : HS.blue,
                           size: 36)
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.title)
                        .font(.system(size: 14.5, weight: .semibold))
                        .foregroundStyle(HS.ink)
                        .hsNoClip(2)
                    Text(direction == .predecessor
                         ? "Must finish first · \(item.urgency(now: now).phrase)"
                         : "Waits on this · due \(DLFormat.day(item.due))")
                        .font(.system(size: 12))
                        .foregroundStyle(HS.slate)
                        .hsNoClip(2)
                }
                Spacer(minLength: 6)
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(HS.slate2)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .contentShape(Rectangle())
        }
        .accessibilityIdentifier("dlDependency.arrowTurnLeftUp")
        .buttonStyle(HSPressStyle())
    }
}

// =====================================================================
// MARK: - 11. History / audit row
// =====================================================================

struct DLHistoryRow: View {
    let change: DLChange
    var isLast: Bool = false

    var body: some View {
        HStack(alignment: .top, spacing: 11) {
            VStack(spacing: 0) {
                Circle()
                    .fill(change.tint.opacity(0.14))
                    .frame(width: 26, height: 26)
                    .overlay(
                        Image(systemName: change.icon)
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(change.tint)
                    )
                if !isLast {
                    Rectangle().fill(HS.line).frame(width: 1.5).frame(maxHeight: .infinity)
                }
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(change.line)
                    .font(.system(size: 13.5, weight: .medium))
                    .foregroundStyle(HS.inkSoft)
                    .hsNoClip(3)
                Text("\(change.author) · \(DLFormat.stamp(change.at))")
                    .font(.system(size: 11.5))
                    .foregroundStyle(HS.slate2)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            }
            .padding(.bottom, isLast ? 0 : 14)
            Spacer(minLength: 0)
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}

// =====================================================================
// MARK: - 12. Quick progress setter
// =====================================================================
//
// Five taps, no keyboard, no drag. Nobody types "62%" wearing gloves.

struct DLProgressPicker: View {
    @Binding var percent: Int
    var accent: Color = PPColor.brand

    private let steps = [0, 25, 50, 75, 100]

    var body: some View {
        HStack(spacing: 8) {
            ForEach(steps, id: \.self) { s in
                let active = percent == s
                Button {
                    HSHaptic.select(); percent = s
                } label: {
                    Text("\(s)%")
                        .font(.system(size: 13.5, weight: .bold))
                        .foregroundStyle(active ? HS.onAccent : HS.slate)
                        .frame(maxWidth: .infinity)
                        .frame(height: 40)
                        .background(active ? accent : HS.fill)
                        .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
                }
                .accessibilityIdentifier("dlProgressPicker.row.\(s)")
                .buttonStyle(HSPressStyle())
            }
        }
    }
}

// =====================================================================
// MARK: - 13. Field rows for the add / edit screen
// =====================================================================

struct DLFieldRow<Content: View>: View {
    let icon: String
    let tint: Color
    let label: String
    @ViewBuilder var content: Content

    var body: some View {
        HStack(spacing: 12) {
            HSIconTile(systemName: icon, tint: tint, size: 36)
            VStack(alignment: .leading, spacing: 3) {
                Text(label.uppercased())
                    .font(.system(size: 10, weight: .bold))
                    .tracking(0.8)
                    .foregroundStyle(HS.slate2)
                content
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }
}

struct DLToggleRow: View {
    let icon: String
    let tint: Color
    let title: String
    let subtitle: String
    @Binding var isOn: Bool

    var body: some View {
        HStack(spacing: 12) {
            HSIconTile(systemName: icon, tint: tint, size: 36)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 14.5, weight: .semibold))
                    .foregroundStyle(HS.ink)
                    .hsNoClip(2)
                Text(subtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(HS.slate)
                    .hsNoClip(2)
            }
            Spacer(minLength: 8)
            Toggle("", isOn: $isOn)
                .accessibilityIdentifier("dlToggle.toggle")
                .labelsHidden()
                .tint(tint)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }
}

// =====================================================================
// MARK: - 15. Grouping menu button
// =====================================================================

struct DLGroupingButton: View {
    @Binding var grouping: DLGrouping

    var body: some View {
        Menu {
            ForEach(DLGrouping.allCases) { g in
                Button {
                    HSHaptic.select(); grouping = g
                } label: {
                    Label(g.label, systemImage: g.icon)
                }
                    .accessibilityIdentifier("dlGrouping.row.\(g.id)")
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: grouping.icon).font(.system(size: 10.5, weight: .bold))
                Text(grouping.label).font(.system(size: 12, weight: .bold))
                Image(systemName: "chevron.down").font(.system(size: 8.5, weight: .black))
            }
            .foregroundStyle(PPColor.brand)
            .lineLimit(1)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(HS.blueBg)
            .clipShape(Capsule())
            .fixedSize()
        }
            .accessibilityIdentifier("dlGrouping.chevronDown")
    }
}

/// The "Filter" pill under the band, with the number of filters on.
struct DLFilterButton: View {
    let activeCount: Int
    let action: () -> Void

    var body: some View {
        Button {
            HSHaptic.select(); action()
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "line.3.horizontal.decrease").font(.system(size: 10.5, weight: .bold))
                Text("Filter").font(.system(size: 12, weight: .bold))
                if activeCount > 0 {
                    Text("\(activeCount)")
                        .font(.system(size: 10.5, weight: .heavy))
                        .foregroundStyle(Color.white)
                        .padding(.horizontal, 5)
                        .frame(minWidth: 16, minHeight: 16)
                        .background(PPColor.brand, in: Capsule())
                }
            }
            .foregroundStyle(PPColor.brand)
            .lineLimit(1)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(HS.blueBg)
            .clipShape(Capsule())
            .fixedSize()
        }
        .buttonStyle(.plain)
        .accessibilityLabel(activeCount > 0 ? "Filter, \(activeCount) on" : "Filter")
        .accessibilityIdentifier("dlDeadlinesScreen.filter")
    }
}

/// The Filter sheet: Trade, Location, Responsible, Critical path only and Sort (the web toolbar's choices). It
/// narrows the list and timeline only; the summary and tab counts keep reading every deadline the viewer sees.
struct DLFilterSheet: View {
    @ObservedObject var store: DLStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let trades = store.trades
        let locations = store.locationOptions
        let people = store.responsibleOptions
        NavigationStack {
            Form {
                Section("Trade") {
                    Picker("Trade", selection: $store.tradeFilter) {
                        ForEach(trades, id: \.self) { Text($0).tag($0) }
                        // A chosen trade no deadline uses any more stays listed, never silently "All trades".
                        if !trades.contains(store.tradeFilter) { Text(store.tradeFilter).tag(store.tradeFilter) }
                    }
                    .accessibilityIdentifier("dlFilter.trade")
                }
                Section("Location") {
                    Picker("Location", selection: $store.locationFilter) {
                        Text("All locations").tag("")
                        ForEach(locations, id: \.self) { Text($0).tag($0) }
                        if !store.locationFilter.isEmpty, !locations.contains(store.locationFilter) {
                            Text(store.locationFilter).tag(store.locationFilter)
                        }
                    }
                    .accessibilityIdentifier("dlFilter.location")
                }
                Section("Responsible") {
                    Picker("Responsible", selection: $store.responsibleFilter) {
                        Text("Anyone").tag("")
                        ForEach(people) { Text($0.name).tag($0.id) }
                        if !store.responsibleFilter.isEmpty, !people.contains(where: { $0.id == store.responsibleFilter }) {
                            Text("Selected").tag(store.responsibleFilter)
                        }
                    }
                    .accessibilityIdentifier("dlFilter.responsible")
                }
                Section {
                    Toggle("Critical path only", isOn: $store.criticalOnly)
                        .tint(PPColor.brand)
                        .accessibilityIdentifier("dlFilter.criticalOnly")
                }
                Section("Sort") {
                    Picker("Sort", selection: $store.sort) {
                        ForEach(DLSort.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                    .accessibilityIdentifier("dlFilter.sort")
                }
                if store.isNarrowed {
                    Section {
                        Button("Clear filters", role: .destructive) {
                            HSHaptic.select(); store.clearFilters()
                        }
                        .accessibilityIdentifier("dlFilter.clear")
                    }
                }
            }
            .tint(PPColor.brand)
            .navigationTitle("Filter")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .accessibilityIdentifier("dlFilter.done")
                }
            }
        }
    }
}

// =====================================================================
// MARK: - 16. Countdown ring (detail sheet hero)
// =====================================================================

struct DLCountdownRing: View {
    let item: DLDeadline
    var now: Date = Date()
    var size: CGFloat = 96

    var body: some View {
        // RULEBOOK 1.94.0 §23 `deadlineDisplay`: the pill words, progress and where progress should be by today.
        let view = item.display(now: now)
        let expected = Double(view.expectedPercent ?? 0) / 100

        ZStack {
            Circle()
                .stroke(Color.white.opacity(0.18), lineWidth: 9)

            // Time elapsed, drawn faint.
            Circle()
                .trim(from: 0, to: view.isCompleted ? 0 : min(max(expected, 0), 1))
                .stroke(Color.white.opacity(0.35), style: StrokeStyle(lineWidth: 9, lineCap: .round))
                .rotationEffect(.degrees(-90))

            // Work done, drawn solid.
            Circle()
                .trim(from: 0, to: min(max(Double(view.progressPercent) / 100, 0), 1))
                .stroke(Color.white, style: StrokeStyle(lineWidth: 9, lineCap: .round))
                .rotationEffect(.degrees(-90))

            VStack(spacing: 0) {
                Text(view.pill)
                    .font(.system(size: 21, weight: .black))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                if !caption(view).isEmpty {
                    Text(caption(view))
                        .font(.system(size: 10.5, weight: .bold))
                        .foregroundStyle(.white.opacity(0.75))
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
            }
        }
        .frame(width: size, height: size)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(view.dueText)
    }

    /// The small word under the pill: "on time" / "late" once completed, "overdue", "due" (today) or "to go".
    private func caption(_ view: RulebookDeadlineDisplay) -> String {
        if view.isCompleted { return view.status == "late" ? "late" : "on time" }
        guard let days = view.daysRemaining else { return "" }
        if days < 0 { return "overdue" }
        return days == 0 ? "due" : "to go"
    }
}

/// The gradient hero at the top of the detail sheet, coloured by the rulebook tone.
struct DLDetailHero: View {
    let item: DLDeadline
    var now: Date = Date()

    var body: some View {
        let view = item.display(now: now)
        let moved = item.movedNote
        let day = CanonicalBusinessEngine.deadlineDayText(item.due, withYear: true) ?? DLFormat.full(item.due)

        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 7) {
                if item.isCritical {
                    HStack(spacing: 4) {
                        Image(systemName: "flag.fill").font(.system(size: 8.5, weight: .black))
                        Text("CRITICAL PATH").font(.system(size: 9.5, weight: .black)).tracking(0.6)
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 7).padding(.vertical, 3.5)
                    .background(Color.white.opacity(0.22))
                    .clipShape(Capsule())
                }

                Text(item.title)
                    .font(HSFont.heroTitle)
                    .foregroundStyle(.white)
                    .hsNoClip(3, minScale: 0.7)

                Text(view.dueText.isEmpty ? day : "\(view.dueText) · \(day)")
                    .font(HSFont.heroSub)
                    .foregroundStyle(.white.opacity(0.88))
                    .hsNoClip(2)

                if !moved.isEmpty {
                    Text(moved)
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.80))
                        .hsNoClip(2)
                }
            }

            Spacer(minLength: 0)

            DLCountdownRing(item: item, now: now, size: 92)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(heroGradient(for: view.tone))
        .clipShape(RoundedRectangle(cornerRadius: HSMetric.cardRadius, style: .continuous))
        .shadow(color: DLTone.color(view.tone).opacity(0.28), radius: 16, x: 0, y: 8)
    }

    private func heroGradient(for tone: String) -> LinearGradient {
        switch tone {
        case "red":
            return LinearGradient(colors: [hsDyn("#EF6257", "#C3453B"), hsDyn("#D13B31", "#8E2C25")],
                                  startPoint: .topLeading, endPoint: .bottomTrailing)
        case "amber":
            return LinearGradient(colors: [hsDyn("#F0A03A", "#C07C21"), hsDyn("#D9821A", "#8E5A12")],
                                  startPoint: .topLeading, endPoint: .bottomTrailing)
        case "green":
            return LinearGradient(colors: [hsDyn("#22B87C", "#178A5C"), hsDyn("#12A46A", "#0E6B46")],
                                  startPoint: .topLeading, endPoint: .bottomTrailing)
        case "grey":
            return LinearGradient(colors: [hsDyn("#7D8A9C", "#5A6676"), hsDyn("#667488", "#434D5B")],
                                  startPoint: .topLeading, endPoint: .bottomTrailing)
        default:
            return HS.heroBlue
        }
    }
}
