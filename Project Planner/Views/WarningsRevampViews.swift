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
    case materials = "Materials"
    case expiring = "Expiring"

    var id: String { rawValue }
}

struct WarningsHeroCard: View {
    let activeCount: Int
    let highCount: Int
    let mediumCount: Int
    let lowCount: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("ACTIVE ISSUES")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Color.white.opacity(0.85))
                        .tracking(0.4)
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text("\(activeCount)")
                            .font(.system(size: 24, weight: .medium))
                        Text("need attention")
                            .font(.system(size: 14, weight: .regular))
                            .opacity(0.85)
                    }
                    .foregroundStyle(.white)
                }
                Spacer(minLength: 0)
                ZStack {
                    Circle()
                        .fill(Color.white.opacity(0.18))
                        .frame(width: 42, height: 42)
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 20))
                        .foregroundStyle(.white)
                }
            }
            HStack(spacing: 8) {
                priorityStat(value: highCount, label: "High")
                priorityStat(value: mediumCount, label: "Medium")
                priorityStat(value: lowCount, label: "Low")
            }
            Text("High: operative clashes & unbooked labour · Medium: manager/admin overlaps (tick for weekly report) · Low: materials not ordered by 16:00")
                .font(.system(size: 10))
                .foregroundStyle(.white.opacity(0.8))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(18)
        .background(
            LinearGradient(
                colors: [Color(red: 0.639, green: 0.176, blue: 0.176), Color(red: 0.753, green: 0.282, blue: 0.282)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    private func priorityStat(value: Int, label: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("\(value)")
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(.white)
            Text(label)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.white.opacity(0.85))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(Color.white.opacity(0.14))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

struct WarningsFilterChipsRow: View {
    @Binding var selected: WarningsFilterChip
    let counts: [WarningsFilterChip: Int]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 7) {
                ForEach(WarningsFilterChip.allCases) { chip in
                    let count = counts[chip] ?? 0
                    let isOn = selected == chip
                    Button {
                        selected = chip
                    } label: {
                        Text("\(chip.rawValue) · \(count)")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(isOn ? Color.white : ProjectWorksRevampColors.muted)
                            .padding(.horizontal, 13)
                            .padding(.vertical, 6)
                            .background(isOn ? ProjectWorksRevampColors.blue : Color.white)
                            .clipShape(Capsule())
                            .overlay(
                                Capsule()
                                    .stroke(ProjectWorksRevampColors.border, lineWidth: isOn ? 0 : 0.5)
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
        HStack(spacing: 3) {
            Image(systemName: iconName)
                .font(.system(size: 9, weight: .bold))
            Text(label)
                .font(.system(size: 10, weight: .medium))
        }
        .foregroundStyle(foreground)
        .padding(.horizontal, 7)
        .padding(.vertical, 2)
        .background(background)
        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
    }

    private var label: String {
        switch severity {
        case .high: return "High"
        case .medium: return "Medium"
        case .low: return "Low"
        }
    }

    private var iconName: String {
        switch severity {
        case .high: return "exclamationmark.circle.fill"
        case .medium: return "exclamationmark.triangle.fill"
        case .low: return "info.circle.fill"
        }
    }

    private var background: Color {
        switch severity {
        case .high: return Color(red: 0.988, green: 0.922, blue: 0.922)
        case .medium: return Color(red: 0.98, green: 0.933, blue: 0.855)
        case .low: return Color(red: 0.949, green: 0.953, blue: 0.961)
        }
    }

    private var foreground: Color {
        switch severity {
        case .high: return Color(red: 0.639, green: 0.176, blue: 0.176)
        case .medium: return Color(red: 0.522, green: 0.310, blue: 0.043)
        case .low: return ProjectWorksRevampColors.muted
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
                Text(entry.jobNumber ?? entry.locationLabel)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(accent.foreground)
                    .lineLimit(1)
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
        let bar = (
            left: CGFloat(overlapStart) / CGFloat(WarningTimelineMath.dayMinutes),
            width: CGFloat(max(0, overlapEnd - overlapStart)) / CGFloat(WarningTimelineMath.dayMinutes)
        )
        let clashLabel: String
        if overlapMinutes >= WarningTimelineMath.dayMinutes - 30 {
            clashLabel = "CLASH · Full day"
        } else {
            let h = Double(overlapMinutes) / 60.0
            clashLabel = h >= 1 ? String(format: "CLASH · %.0fh", h.rounded()) : "CLASH"
        }
        return HStack(spacing: 9) {
            Color.clear.frame(width: 68, height: 20)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    let w = max(4, geo.size.width * bar.width)
                    let x = geo.size.width * bar.left
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
                        .position(x: x + w / 2, y: 10)
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
                onOpenDay: onOpenDay
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
                onOpenDay: onOpenDay
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

    var body: some View {
        clashCard
    }

    private var clashCard: some View {
        let border: Color = severity == .high
            ? Color(red: 0.988, green: 0.922, blue: 0.922)
            : Color(red: 0.98, green: 0.933, blue: 0.855)
        return VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(severity == .high ? Color(red: 0.988, green: 0.922, blue: 0.922) : Color(red: 0.98, green: 0.933, blue: 0.855))
                        .frame(width: 36, height: 36)
                    Image(systemName: "calendar.badge.exclamationmark")
                        .font(.system(size: 16))
                        .foregroundStyle(severity == .high ? Color(red: 0.639, green: 0.176, blue: 0.176) : Color(red: 0.522, green: 0.310, blue: 0.043))
                }
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 7) {
                        Text(title)
                            .font(.system(size: 14, weight: .medium))
                        WarningPriorityBadge(severity: severity)
                    }
                    Text(subtitle)
                        .font(.system(size: 12))
                        .foregroundStyle(ProjectWorksRevampColors.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

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
                    .foregroundStyle(severity == .high ? Color(red: 0.639, green: 0.176, blue: 0.176) : Color(red: 0.522, green: 0.310, blue: 0.043))
                VStack(alignment: .leading, spacing: 2) {
                    Text(overlapSummary)
                        .font(.system(size: 12, weight: .medium))
                    Text(overlapDetail)
                        .font(.system(size: 11))
                        .opacity(0.85)
                }
                .foregroundStyle(severity == .high ? Color(red: 0.639, green: 0.176, blue: 0.176) : Color(red: 0.522, green: 0.310, blue: 0.043))
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(severity == .high ? Color(red: 0.988, green: 0.922, blue: 0.922) : Color(red: 0.98, green: 0.933, blue: 0.855))
            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))

            Text("Bookings involved:")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(ProjectWorksRevampColors.muted)
                .padding(.leading, 4)

            VStack(spacing: 0) {
                bookingInvolvedRow(entry: entryA)
                Divider().overlay(ProjectWorksRevampColors.border)
                bookingInvolvedRow(entry: entryB)
            }
            .padding(.horizontal, 14)
            .background(Color.white)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(Color(red: 0.933, green: 0.941, blue: 0.953), lineWidth: 0.5)
            )

            Text("Choose how to resolve:")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(ProjectWorksRevampColors.muted)
                .padding(.leading, 4)

            HStack(spacing: 8) {
                resolveButton(title: removeALabel, icon: "trash", action: onRemoveA)
                resolveButton(title: removeBLabel, icon: "trash", action: onRemoveB)
            }
            if showsApproveForWeeklyReport {
                approveButton(title: "Approve for weekly report", action: onApprove)
            }
            secondaryButton(title: "Open day to edit manually", icon: "square.and.pencil", action: onOpenDay)
        }
        .padding(16)
        .background(Color.white)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(border, lineWidth: 0.5)
        )
        .shadow(color: border.opacity(0.35), radius: 0, x: 0, y: 0)
    }

    private func bookingInvolvedRow(entry: Warning.ClashTimelineEntry) -> some View {
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(entry.isSmallWorks ? ProjectWorksRevampColors.upcomingAmber.opacity(0.15) : Color(red: 0.882, green: 0.961, blue: 0.933))
                .frame(width: 28, height: 28)
                .overlay(
                    Image(systemName: entry.isSmallWorks ? "hammer.fill" : "folder.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(entry.isSmallWorks ? ProjectWorksRevampColors.upcomingAmber : Color(red: 0.059, green: 0.431, blue: 0.337))
                )
            VStack(alignment: .leading, spacing: 2) {
                if let num = entry.jobNumber, let site = entry.siteName {
                    HStack(spacing: 6) {
                        Text(num)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(entry.isSmallWorks ? ProjectWorksRevampColors.upcomingAmber : ProjectWorksRevampColors.blue)
                        Text(site)
                            .font(.system(size: 12, weight: .medium))
                            .lineLimit(1)
                    }
                } else {
                    Text(entry.locationLabel)
                        .font(.system(size: 12, weight: .medium))
                }
                Text("\(entry.timeLabel) · \(entry.hoursLabel)")
                    .font(.system(size: 10))
                    .foregroundStyle(ProjectWorksRevampColors.muted)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 10)
    }

    private func resolveButton(title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.system(size: 13))
                    .foregroundStyle(Color(red: 0.639, green: 0.176, blue: 0.176))
                Text(title)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
            }
            .foregroundStyle(ProjectWorksRevampColors.ink)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 9)
            .background(Color.white)
            .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .stroke(ProjectWorksRevampColors.border, lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
    }

    private func approveButton(title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: "checkmark.circle")
                    .font(.system(size: 14, weight: .medium))
                Text(title)
                    .font(.system(size: 12, weight: .medium))
            }
            .foregroundStyle(Color(red: 0.059, green: 0.431, blue: 0.337))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 9)
            .background(Color(red: 0.882, green: 0.961, blue: 0.933))
            .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .stroke(Color(red: 0.059, green: 0.431, blue: 0.337), lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
    }

    private func secondaryButton(title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 13))
                Text(title)
                    .font(.system(size: 12, weight: .medium))
            }
            .foregroundStyle(ProjectWorksRevampColors.muted)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 9)
            .background(Color(red: 0.969, green: 0.973, blue: 0.980))
            .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .stroke(Color(red: 0.933, green: 0.941, blue: 0.953), lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
    }
}
