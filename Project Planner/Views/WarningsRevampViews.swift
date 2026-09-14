//
//  WarningsRevampViews.swift
//  Project Planner
//
//  Revamped warnings UI (warnings_three_priorities.html).
//

import SwiftUI

enum WarningsFilterChip: String, CaseIterable, Identifiable {
    case all = "All"
    case clashes = "Clashes"
    case unbooked = "Unbooked"
    case materials = "Materials"

    var id: String { rawValue }
}

struct WarningsHeroCard: View {
    let activeCount: Int
    let highCount: Int
    let mediumCount: Int
    let lowCount: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Active issues")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(Color.white.opacity(0.6))
                .textCase(.uppercase)
                .tracking(0.8)

            HStack(alignment: .center) {
                Text("\(activeCount) need attention")
                    .font(.system(size: 26, weight: .bold))
                    .foregroundStyle(.white)
                Spacer(minLength: 0)
                ZStack {
                    Circle()
                        .fill(Color.white.opacity(0.18))
                        .frame(width: 36, height: 36)
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.white)
                }
            }
            .padding(.top, 4)
            .padding(.bottom, 14)

            HStack(spacing: 8) {
                priorityStat(value: highCount, label: "High")
                priorityStat(value: mediumCount, label: "Medium")
                priorityStat(value: lowCount, label: "Low")
            }
            .padding(.bottom, 12)

            Text("High: operative clashes & unbooked labour · Medium: manager/admin overlaps (tick for weekly report) · Low: materials not ordered by 16:00")
                .font(.system(size: 11))
                .foregroundStyle(Color.white.opacity(0.55))
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .background(
            LinearGradient(
                colors: [
                    Color(red: 0.722, green: 0.196, blue: 0.196), // #B83232
                    Color(red: 0.620, green: 0.165, blue: 0.165)  // #9E2A2A
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private func priorityStat(value: Int, label: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("\(value)")
                .font(.system(size: 22, weight: .bold))
                .foregroundStyle(.white)
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Color.white.opacity(0.65))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(Color.white.opacity(0.14))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.white.opacity(0.12), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

struct WarningsFilterChipsRow: View {
    @Binding var selected: WarningsFilterChip
    let counts: [WarningsFilterChip: Int]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(WarningsFilterChip.allCases) { chip in
                    let count = counts[chip] ?? 0
                    let isOn = selected == chip
                    Button {
                        selected = chip
                    } label: {
                        Text("\(chip.rawValue) · \(count)")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(isOn ? Color.white : Color(red: 0.420, green: 0.447, blue: 0.502))
                            .padding(.horizontal, 13)
                            .padding(.vertical, 6)
                            .background(isOn ? Color(red: 0.110, green: 0.110, blue: 0.118) : Color.white)
                            .clipShape(Capsule())
                            .overlay(
                                Capsule()
                                    .stroke(Color.black.opacity(0.10), lineWidth: isOn ? 0 : 0.5)
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

struct WarningPriorityBadge: View {
    let severity: Warning.WarningSeverity

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 11, weight: .bold))
            Text(label)
                .font(.system(size: 11, weight: .bold))
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 11)
        .padding(.vertical, 4)
        .background(Color.white.opacity(0.18))
        .overlay(
            Capsule()
                .stroke(Color.white.opacity(0.28), lineWidth: 1)
        )
        .clipShape(Capsule())
    }

    private var label: String {
        switch severity {
        case .high: return "HIGH"
        case .medium: return "MEDIUM"
        case .low: return "LOW"
        }
    }
}

struct ClashTimelineDiagram: View {
    let personName: String
    let date: Date
    let entryA: Warning.ClashTimelineEntry
    let entryB: Warning.ClashTimelineEntry
    let overlapMinutes: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                HStack(spacing: 7) {
                    Text(PlannerUIInitials.from(personName))
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.white)
                        .frame(width: 24, height: 24)
                        .background(
                            LinearGradient(
                                colors: [ProjectWorksRevampColors.blue, ProjectWorksRevampColors.blueLight],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .clipShape(Circle())
                    Text(personName)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(ProjectWorksRevampColors.ink)
                }
                Spacer()
                Text(date, format: .dateTime.weekday(.abbreviated).day().month(.abbreviated))
                    .font(.system(size: 11))
                    .foregroundStyle(ProjectWorksRevampColors.muted)
            }
            .padding(.bottom, 14)

            timelineRow(entry: entryA)
            timelineRow(entry: entryB)
                .padding(.bottom, 11)

            clashIndicatorRow
                .padding(.bottom, 9)

            timeAxisRow
        }
        .padding(13)
        .background(Color(red: 0.969, green: 0.973, blue: 0.980))
        .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
    }

    private func timelineRow(entry: Warning.ClashTimelineEntry) -> some View {
        let bar = WarningTimelineMath.barFraction(start: entry.startMinutes, end: entry.endMinutes)
        let accent = entryAccent(entry)
        return HStack(spacing: 9) {
            HStack(spacing: 5) {
                ZStack {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(accent.background)
                        .frame(width: 20, height: 20)
                    Image(systemName: entry.isSmallWorks ? "hammer.fill" : "folder.fill")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(accent.foreground)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(entry.jobNumber ?? entry.locationLabel)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(accent.foreground)
                        .lineLimit(1)
                    if let siteName = entry.siteName, entry.jobNumber != nil {
                        Text(siteName)
                            .font(.system(size: 9))
                            .foregroundStyle(ProjectWorksRevampColors.muted)
                            .lineLimit(1)
                    }
                }
            }
            .frame(width: 68, alignment: .leading)

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(Color.white)
                        .overlay(
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .stroke(Color(red: 0.933, green: 0.941, blue: 0.953), lineWidth: 0.5)
                        )
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(accent.barGradient)
                        .frame(width: max(4, geo.size.width * bar.width))
                        .offset(x: geo.size.width * bar.left)
                }
            }
            .frame(height: 24)

            Text(entry.timeLabel)
                .font(.system(size: 11))
                .foregroundStyle(ProjectWorksRevampColors.muted)
                .frame(width: 84, alignment: .trailing)
                .lineLimit(1)
        }
        .padding(.bottom, 9)
    }

    private var clashIndicatorRow: some View {
        let a = (entryA.startMinutes, entryA.endMinutes)
        let b = (entryB.startMinutes, entryB.endMinutes)
        let overlapStart = max(a.0, b.0)
        let overlapEnd = min(a.1, b.1)
        let bar = WarningTimelineMath.barFraction(start: overlapStart, end: overlapEnd)
        let clashLabel: String
        if overlapMinutes >= WarningTimelineMath.dayMinutes - 30 {
            clashLabel = "CLASH · Full day"
        } else {
            let h = Double(max(0, overlapMinutes)) / 60.0
            clashLabel = h >= 1 ? String(format: "CLASH · %.0fh", h.rounded()) : "CLASH"
        }
        return HStack(spacing: 9) {
            Color.clear.frame(width: 68, height: 20)
            GeometryReader { geo in
                let w = max(4, geo.size.width * bar.width)
                let x = max(0, min(geo.size.width - w, geo.size.width * bar.left))
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .stroke(style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                        .foregroundStyle(Color(red: 0.639, green: 0.176, blue: 0.176))
                        .frame(width: w, height: 20)
                        .offset(x: x)
                    Text(clashLabel)
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(Color(red: 0.639, green: 0.176, blue: 0.176))
                        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                        .frame(width: w, height: 20, alignment: .center)
                        .offset(x: x)
                }
            }
            .frame(height: 20)
            Color.clear.frame(width: 84, height: 20)
        }
    }

    private var timeAxisRow: some View {
        HStack(spacing: 9) {
            Color.clear.frame(width: 68, height: 1)
            HStack {
                ForEach(["0", "6", "12", "18", "24"], id: \.self) { t in
                    Text(t)
                    if t != "24" { Spacer(minLength: 0) }
                }
            }
            .font(.system(size: 9))
            .foregroundStyle(ProjectWorksRevampColors.muted)
            Color.clear.frame(width: 84, height: 1)
        }
    }

    private struct EntryAccent {
        let foreground: Color
        let background: Color
        let barGradient: LinearGradient
    }

    private func entryAccent(_ entry: Warning.ClashTimelineEntry) -> EntryAccent {
        if entry.isSmallWorks {
            return EntryAccent(
                foreground: ProjectWorksRevampColors.upcomingAmber,
                background: Color(red: 0.98, green: 0.933, blue: 0.855),
                barGradient: LinearGradient(
                    colors: [ProjectWorksRevampColors.upcomingAmber, ProjectWorksRevampColors.upcomingAmber.opacity(0.75)],
                    startPoint: .leading,
                    endPoint: .trailing
                )
            )
        }
        if entry.jobNumber != nil {
            let green = Color(red: 0.059, green: 0.431, blue: 0.337)
            return EntryAccent(
                foreground: green,
                background: Color(red: 0.882, green: 0.961, blue: 0.933),
                barGradient: LinearGradient(
                    colors: [green, Color(red: 0.176, green: 0.639, blue: 0.490)],
                    startPoint: .leading,
                    endPoint: .trailing
                )
            )
        }
        let blue = ProjectWorksRevampColors.blue
        return EntryAccent(
            foreground: blue,
            background: Color(red: 0.902, green: 0.945, blue: 0.984),
            barGradient: LinearGradient(
                colors: [blue, ProjectWorksRevampColors.blueLight],
                startPoint: .leading,
                endPoint: .trailing
            )
        )
    }
}


struct OperativeClashWarningCard: View {
    let warning: Warning
    let onRemoveA: () -> Void
    let onRemoveB: () -> Void
    let onOpenDay: () -> Void
    let onRemoveWarning: () -> Void

    var body: some View {
        if let clash = warning.operativeClash {
            BookingClashWarningCard(
                title: warning.title,
                subtitle: warning.message,
                severity: warning.severity,
                personName: clash.operativeName,
                date: clash.date,
                entryA: clash.entryA,
                entryB: clash.entryB,
                overlapMinutes: clash.overlapMinutes,
                overlapSummary: clash.overlapSummary,
                overlapDetail: clash.overlapDetail,
                removeALabel: removeLabel(for: clash.entryA),
                removeBLabel: removeLabel(for: clash.entryB),
                showsApproveForWeeklyReport: false,
                onRemoveA: onRemoveA,
                onRemoveB: onRemoveB,
                onApprove: {},
                onOpenDay: onOpenDay,
                onRemoveWarning: onRemoveWarning
            )
        }
    }

    private func removeLabel(for entry: Warning.ClashTimelineEntry) -> String {
        if let num = entry.jobNumber { return "Remove \(num)" }
        return "Remove booking"
    }
}

struct ManagerClashWarningCard: View {
    let warning: Warning
    let onRemoveA: () -> Void
    let onRemoveB: () -> Void
    let onApprove: () -> Void
    let onOpenDay: () -> Void
    let onRemoveWarning: () -> Void

    var body: some View {
        if let clash = warning.managerClash {
            BookingClashWarningCard(
                title: warning.title,
                subtitle: warning.message,
                severity: warning.severity,
                personName: clash.personName,
                date: clash.date,
                entryA: clash.entryA,
                entryB: clash.entryB,
                overlapMinutes: clash.overlapMinutes,
                overlapSummary: clash.overlapSummary,
                overlapDetail: clash.overlapDetail,
                removeALabel: "Remove \(clash.entryA.locationLabel)",
                removeBLabel: "Remove \(clash.entryB.locationLabel)",
                showsApproveForWeeklyReport: true,
                onRemoveA: onRemoveA,
                onRemoveB: onRemoveB,
                onApprove: onApprove,
                onOpenDay: onOpenDay,
                onRemoveWarning: onRemoveWarning
            )
        }
    }
}

private struct BookingClashWarningCard: View {
    let title: String
    let subtitle: String
    let severity: Warning.WarningSeverity
    let personName: String
    let date: Date
    let entryA: Warning.ClashTimelineEntry
    let entryB: Warning.ClashTimelineEntry
    let overlapMinutes: Int
    let overlapSummary: String
    let overlapDetail: String
    let removeALabel: String
    let removeBLabel: String
    let showsApproveForWeeklyReport: Bool
    let onRemoveA: () -> Void
    let onRemoveB: () -> Void
    let onApprove: () -> Void
    let onOpenDay: () -> Void
    let onRemoveWarning: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(title)
                    .font(.system(size: 17, weight: .heavy))
                    .foregroundStyle(.white)
                    .tracking(-0.2)
                Spacer(minLength: 8)
                WarningPriorityBadge(severity: severity)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 15)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                LinearGradient(colors: headerColors, startPoint: .topLeading, endPoint: .bottomTrailing)
            )

            VStack(alignment: .leading, spacing: 14) {
                Text(subtitle)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color(red: 0.216, green: 0.255, blue: 0.318))
                    .fixedSize(horizontal: false, vertical: true)

                ClashTimelineDiagram(
                    personName: personName,
                    date: date,
                    entryA: entryA,
                    entryB: entryB,
                    overlapMinutes: overlapMinutes
                )

                HStack(spacing: 9) {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .font(.system(size: 14))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(overlapSummary)
                            .font(.system(size: 12, weight: .semibold))
                        Text(overlapDetail)
                            .font(.system(size: 11))
                            .opacity(0.85)
                    }
                }
                .foregroundStyle(severity == .high
                    ? Color(red: 0.639, green: 0.176, blue: 0.176)
                    : Color(red: 0.522, green: 0.310, blue: 0.043))
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(severity == .high
                    ? Color(red: 0.988, green: 0.922, blue: 0.922)
                    : Color(red: 0.98, green: 0.933, blue: 0.855))
                .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            }
            .padding(.horizontal, 16)
            .padding(.top, 15)
            .padding(.bottom, 4)

            VStack(spacing: 9) {
                HStack(spacing: 8) {
                    resolveButton(title: removeALabel, action: onRemoveA)
                    resolveButton(title: removeBLabel, action: onRemoveB)
                }
                if showsApproveForWeeklyReport {
                    Button(action: onApprove) {
                        HStack(spacing: 8) {
                            Image(systemName: "checkmark.circle.fill")
                            Text("Approve for weekly report")
                                .font(.system(size: 15, weight: .bold))
                        }
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 15)
                        .background(
                            LinearGradient(
                                colors: [Color(red: 0.059, green: 0.431, blue: 0.337), Color(red: 0.086, green: 0.520, blue: 0.400)],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
                HStack(spacing: 0) {
                    Button(action: onOpenDay) {
                        Text("Open daily overview")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Color(red: 0.145, green: 0.388, blue: 0.922))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                    }
                    .buttonStyle(.plain)
                    Rectangle()
                        .fill(Color.black.opacity(0.10))
                        .frame(width: 0.5)
                        .padding(.vertical, 8)
                    Button(action: onRemoveWarning) {
                        Text("Dismiss")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Color(red: 0.420, green: 0.447, blue: 0.502))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                    }
                    .buttonStyle(.plain)
                }
                .background(Color.white)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(Color.black.opacity(0.10), lineWidth: 0.5)
                )
            }
            .padding(.horizontal, 14)
            .padding(.top, 13)
            .padding(.bottom, 14)
            .background(Color(red: 0.980, green: 0.980, blue: 0.980))
            .overlay(alignment: .top) {
                Rectangle().fill(Color.black.opacity(0.07)).frame(height: 0.5)
            }
        }
        .background(Color.white)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color.black.opacity(0.07), lineWidth: 0.5)
        )
        .shadow(color: Color.black.opacity(0.06), radius: 8, x: 0, y: 2)
    }

    private var headerColors: [Color] {
        switch severity {
        case .high:
            return [
                Color(red: 0.498, green: 0.114, blue: 0.114),
                Color(red: 0.600, green: 0.106, blue: 0.106),
                Color(red: 0.725, green: 0.110, blue: 0.110)
            ]
        case .medium:
            return [
                Color(red: 0.573, green: 0.251, blue: 0.055),
                Color(red: 0.702, green: 0.337, blue: 0.078),
                Color(red: 0.820, green: 0.420, blue: 0.120)
            ]
        case .low:
            return [
                Color(red: 0.216, green: 0.255, blue: 0.318),
                Color(red: 0.290, green: 0.333, blue: 0.408),
                Color(red: 0.420, green: 0.447, blue: 0.502)
            ]
        }
    }

    private func resolveButton(title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: "trash")
                    .font(.system(size: 13))
                    .foregroundStyle(Color(red: 0.639, green: 0.176, blue: 0.176))
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
            }
            .foregroundStyle(Color(red: 0.110, green: 0.110, blue: 0.118))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(Color.white)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(Color.black.opacity(0.10), lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
    }
}

struct WarningRemoveButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text("Dismiss")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color(red: 0.420, green: 0.447, blue: 0.502))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
        }
        .buttonStyle(.plain)
    }
}
