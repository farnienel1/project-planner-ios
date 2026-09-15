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
    let urgency: DLUrgency
    var compact: Bool = false

    var body: some View {
        Text(compact ? urgency.pillText : urgency.phrase)
            .font(.system(size: compact ? 12.5 : 12, weight: .bold))
            .foregroundStyle(urgency.accent)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .padding(.horizontal, compact ? 9 : 10)
            .padding(.vertical, compact ? 5 : 5.5)
            .background(urgency.tint)
            .clipShape(Capsule())
            .overlay(Capsule().strokeBorder(urgency.accent.opacity(0.22), lineWidth: 1))
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
    var accent: Color = HS.teal
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

/// Bar plus its caption line. Use this rather than the bare bar.
struct DLPacingBlock: View {
    let item: DLDeadline
    var now: Date = Date()

    var body: some View {
        let urgency = item.urgency(now: now)
        let expected = item.expectedProgress(now: now)
        let gap = item.pacingGap(now: now)

        VStack(alignment: .leading, spacing: 6) {
            DLPacingBar(progress: item.progress,
                        expected: expected,
                        accent: item.status == .complete ? HS.green : urgency.accent)

            HStack(spacing: 6) {
                Text("\(item.progressPercent)% complete")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(HS.slate)

                if let gap, gap >= 5, item.status != .complete {
                    Text("·").foregroundStyle(HS.slate2)
                    Text("\(gap)% behind pace")
                        .font(.system(size: 11.5, weight: .bold))
                        .foregroundStyle(HS.red)
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

    private var urgency: DLUrgency { item.urgency(now: now) }
    private var atRisk: Bool { item.isAtRisk(now: now) }

    // Press feedback without a wrapping Button — a Button here would swallow
    // taps on the "Update" pill nested inside it.
    @State private var pressed = false

    var body: some View {
            VStack(alignment: .leading, spacing: 11) {

                // Row 1 — flags
                if item.isCritical || atRisk || item.timesRescheduled > 0 {
                    HStack(spacing: 6) {
                        if item.isCritical { DLCriticalFlag() }
                        if atRisk {
                            HSBadge(text: "AT RISK", tone: .danger, icon: "exclamationmark.triangle.fill")
                        }
                        if item.timesRescheduled > 0 {
                            DLMetaChip(icon: "calendar.badge.exclamationmark",
                                       text: item.slippageDays > 0 ? "+\(item.slippageDays)d slip" : "moved",
                                       tint: HS.amber)
                        }
                        Spacer(minLength: 0)
                    }
                }

                // Row 2 — title owns the width; only the pill sits beside it
                HStack(alignment: .top, spacing: 10) {
                    Text(item.title)
                        .font(HSFont.cardTitle)
                        .foregroundStyle(HS.ink)
                        .hsNoClip(2)
                    Spacer(minLength: 6)
                    DLCountdownPill(urgency: urgency, compact: true)
                }

                // Row 3 — where and who
                HStack(spacing: 6) {
                    if showLocation, let location = item.location {
                        DLMetaChip(icon: "building.2.fill", text: location, tint: HS.inkSoft)
                    }
                    if let trade = item.trade {
                        DLMetaChip(icon: "wrench.and.screwdriver.fill", text: trade, tint: HS.blue)
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
                } else if item.status != .complete {
                    DLPacingBlock(item: item, now: now)
                }

                HSDivider(inset: 0)

                // Row 5 — footer: due date, people, action
                HStack(spacing: 10) {
                    HStack(spacing: 5) {
                        Image(systemName: item.status == .complete ? "checkmark.seal.fill" : "calendar")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(item.status == .complete ? HS.green : HS.slate2)
                        Text(item.status == .complete
                             ? "Done \(DLFormat.day(item.completedAt ?? item.due))"
                             : DLFormat.full(item.due))
                            .font(HSFont.meta)
                            .foregroundStyle(HS.slate)
                            .lineLimit(1)
                            .minimumScaleFactor(0.85)
                    }

                    Spacer(minLength: 6)

                    if !item.initialsForAssignees.isEmpty {
                        DLAssigneeStack(initials: item.initialsForAssignees, size: 24)
                    }

                    if let onUpdate, item.status != .complete {
                        Button {
                            HSHaptic.tap(); onUpdate()
                        } label: {
                            Text("Update")
                        }
                        .buttonStyle(HSPillButton(tone: .teal))
                    }
                }
            }
            .padding(.leading, 6)      // room for the spine
            .hsTappableCard()
            .overlay(alignment: .leading) {
                // Urgency spine — readable before a single word is.
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(urgency.accent)
                    .frame(width: 4)
                    .padding(.vertical, 14)
                    .padding(.leading, 7)
            }
            .opacity(item.status == .complete ? 0.72 : 1)
            .scaleEffect(pressed ? 0.985 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.75), value: pressed)
            .contentShape(RoundedRectangle(cornerRadius: HSMetric.cardRadius, style: .continuous))
            .onTapGesture {
                HSHaptic.tap(); onOpen()
            }
            .simultaneousGesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in if !pressed { pressed = true } }
                    .onEnded   { _ in pressed = false }
            )
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
                .font(HSFont.sectionLabel)
                .tracking(0.9)
                .foregroundStyle(accent ?? HS.slate2)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
            Text("\(count)")
                .font(.system(size: 10.5, weight: .black))
                .foregroundStyle(HS.slate)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(HS.fill)
                .clipShape(Capsule())
            Spacer(minLength: 0)
        }
    }
}

// =====================================================================
// MARK: - 8. Week rail
// =====================================================================
//
// Fourteen days of workload at a glance. The bar under each day is the
// number of deadlines landing that day, so a Thursday with four things due
// is obvious before anybody opens a list. Tap a day to filter to it.

struct DLWeekRail: View {
    let days: [Date]
    let load: (Date) -> Int
    let overdueOn: (Date) -> Bool
    @Binding var selected: Date?
    var now: Date = Date()

    private let cal = Calendar.current

    var body: some View {
        Color.clear
            .frame(height: 78)
            .frame(maxWidth: .infinity)
            .overlay(alignment: .leading) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 7) {
                        ForEach(days, id: \.timeIntervalSince1970) { day in
                            let n = load(day)
                            let isToday = cal.isDate(day, inSameDayAs: now)
                            let isSel = selected.map { cal.isDate($0, inSameDayAs: day) } ?? false
                            let bad = overdueOn(day)
                            let accent: Color = bad ? HS.red : (n > 0 ? HS.teal : HS.slate2)

                            Button {
                                HSHaptic.select()
                                selected = isSel ? nil : day
                            } label: {
                                VStack(spacing: 5) {
                                    Text(DLFormat.weekday(day))
                                        .font(.system(size: 10, weight: .bold))
                                        .foregroundStyle(isSel ? HS.onAccent : HS.slate2)
                                    Text(DLFormat.dayNum(day))
                                        .font(.system(size: 15, weight: isToday ? .black : .semibold))
                                        .foregroundStyle(isSel ? HS.onAccent : (isToday ? HS.teal : HS.ink))
                                    Capsule()
                                        .fill(n == 0 ? Color.clear : (isSel ? HS.onAccent : accent))
                                        .frame(width: 14, height: n == 0 ? 3 : CGFloat(min(n, 4)) * 3.5 + 2)
                                        .frame(height: 16, alignment: .bottom)
                                }
                                .frame(width: 40)
                                .padding(.vertical, 8)
                                .background(isSel ? HS.teal : (isToday ? HS.tealBg : Color.clear))
                                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                                        .strokeBorder(isToday && !isSel ? HS.teal.opacity(0.35) : Color.clear,
                                                      lineWidth: 1)
                                )
                            }
                            .buttonStyle(HSPressStyle())
                        }
                    }
                    .padding(.horizontal, HSMetric.screenPad)
                    .padding(.vertical, 2)
                }
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

    private let cal = Calendar.current

    private func offsetDays(_ date: Date) -> Double {
        Double(cal.dateComponents([.day], from: cal.startOfDay(for: windowStart),
                                  to: cal.startOfDay(for: date)).day ?? 0)
    }

    var body: some View {
        let urgency = item.urgency(now: now)
        let s = max(offsetDays(item.start ?? item.due), 0)
        let e = min(offsetDays(item.due) + 1, Double(windowDays))
        let span = max(e - s, 0.6)

        Button {
            HSHaptic.tap(); onOpen()
        } label: {
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 6) {
                    if item.isCritical {
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
                        .foregroundStyle(urgency.accent)
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
                            .fill(LinearGradient(colors: [urgency.accent.opacity(0.80), urgency.accent],
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
        .buttonStyle(HSPressStyle())
    }
}

/// Week ruler drawn above the timeline rows, plus the "today" line drawn over them.
struct DLTimelineScale: View {
    let windowStart: Date
    let windowDays: Int

    private let cal = Calendar.current

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
    var accent: Color = HS.teal

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
                .labelsHidden()
                .tint(tint)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }
}

// =====================================================================
// MARK: - 14. Risk banner
// =====================================================================
//
// Appears above the list only when there is something to say. An always-on
// banner becomes wallpaper within a week.

struct DLRiskBanner: View {
    let overdue: Int
    let atRisk: Int
    let criticalOpen: Int
    var onTap: () -> Void

    private var message: String? {
        if overdue > 0 && criticalOpen > 0 {
            return "\(overdue) overdue, \(criticalOpen) on the critical path"
        } else if overdue > 0 {
            return overdue == 1 ? "1 deadline is overdue" : "\(overdue) deadlines are overdue"
        } else if atRisk > 0 {
            return atRisk == 1 ? "1 deadline is behind pace" : "\(atRisk) deadlines are behind pace"
        }
        return nil
    }

    var body: some View {
        if let message {
            Button {
                HSHaptic.tap(); onTap()
            } label: {
                HStack(spacing: 11) {
                    Image(systemName: overdue > 0 ? "exclamationmark.triangle.fill" : "gauge.with.dots.needle.33percent")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(overdue > 0 ? HS.red : HS.amber)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(message)
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(HS.ink)
                            .hsNoClip(2)
                        Text("Tap to review")
                            .font(.system(size: 11.5))
                            .foregroundStyle(HS.slate)
                    }
                    Spacer(minLength: 6)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(HS.slate2)
                }
                .padding(13)
                .background(overdue > 0 ? HS.redBg : HS.amberBg)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder((overdue > 0 ? HS.red : HS.amber).opacity(0.25), lineWidth: 1)
                )
            }
            .buttonStyle(HSPressStyle())
        }
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
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: grouping.icon).font(.system(size: 10.5, weight: .bold))
                Text(grouping.label).font(.system(size: 12, weight: .bold))
                Image(systemName: "chevron.down").font(.system(size: 8.5, weight: .black))
            }
            .foregroundStyle(HS.teal)
            .lineLimit(1)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(HS.tealBg)
            .clipShape(Capsule())
            .fixedSize()
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
        let urgency = item.urgency(now: now)
        let expected = item.expectedProgress(now: now) ?? 0

        ZStack {
            Circle()
                .stroke(Color.white.opacity(0.18), lineWidth: 9)

            // Time elapsed, drawn faint.
            Circle()
                .trim(from: 0, to: min(max(expected, 0), 1))
                .stroke(Color.white.opacity(0.35), style: StrokeStyle(lineWidth: 9, lineCap: .round))
                .rotationEffect(.degrees(-90))

            // Work done, drawn solid.
            Circle()
                .trim(from: 0, to: min(max(item.progress, 0), 1))
                .stroke(Color.white, style: StrokeStyle(lineWidth: 9, lineCap: .round))
                .rotationEffect(.degrees(-90))

            VStack(spacing: 0) {
                Text(urgency.pillText)
                    .font(.system(size: 21, weight: .black))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                Text(urgency.isOverdue ? "over" : "to go")
                    .font(.system(size: 10.5, weight: .bold))
                    .foregroundStyle(.white.opacity(0.75))
            }
        }
        .frame(width: size, height: size)
    }
}

/// The gradient hero at the top of the detail sheet.
struct DLDetailHero: View {
    let item: DLDeadline
    var now: Date = Date()

    var body: some View {
        let urgency = item.urgency(now: now)

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

                Text(DLFormat.full(item.due))
                    .font(HSFont.heroSub)
                    .foregroundStyle(.white.opacity(0.88))
                    .hsNoClip(2)

                if item.slippageDays > 0 {
                    Text("Moved \(item.slippageDays) days from \(DLFormat.day(item.originalDue ?? item.due))")
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
        .background(heroGradient(for: urgency))
        .clipShape(RoundedRectangle(cornerRadius: HSMetric.cardRadius, style: .continuous))
        .shadow(color: urgency.accent.opacity(0.28), radius: 16, x: 0, y: 8)
    }

    private func heroGradient(for urgency: DLUrgency) -> LinearGradient {
        switch urgency {
        case .overdue:
            return LinearGradient(colors: [hsDyn("#EF6257", "#C3453B"), hsDyn("#D13B31", "#8E2C25")],
                                  startPoint: .topLeading, endPoint: .bottomTrailing)
        case .today, .tomorrow, .soon:
            return LinearGradient(colors: [hsDyn("#F0A03A", "#C07C21"), hsDyn("#D9821A", "#8E5A12")],
                                  startPoint: .topLeading, endPoint: .bottomTrailing)
        case .complete:
            return LinearGradient(colors: [hsDyn("#22B87C", "#178A5C"), hsDyn("#12A46A", "#0E6B46")],
                                  startPoint: .topLeading, endPoint: .bottomTrailing)
        case .blocked:
            return LinearGradient(colors: [hsDyn("#7E6DEB", "#5B4CB8"), hsDyn("#6D5AE6", "#433790")],
                                  startPoint: .topLeading, endPoint: .bottomTrailing)
        default:
            return HS.heroBlue
        }
    }
}
