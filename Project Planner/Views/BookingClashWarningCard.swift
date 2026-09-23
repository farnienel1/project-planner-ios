//
//  BookingClashWarningCard.swift
//  Project Planner
//
//  Warnings clash card — strip + list (booking-clash-card.html / BookingClashCard.tsx).
//  One card per person, with operative / manager / admin titles.
//

import SwiftUI

struct OperativeClashWarningCard: View {
    let warning: Warning
    let onRemove: (Warning.ClashTimelineEntry) -> Void
    let onApprove: () -> Void
    let onOpenDay: () -> Void
    let onRemoveWarning: () -> Void

    var body: some View {
        BookingClashWarningCard(
            warning: warning,
            onRemove: onRemove,
            onApprove: onApprove,
            onOpenDay: onOpenDay,
            onRemoveWarning: onRemoveWarning
        )
    }
}

struct ManagerClashWarningCard: View {
    let warning: Warning
    let onRemove: (Warning.ClashTimelineEntry) -> Void
    let onApprove: () -> Void
    let onOpenDay: () -> Void
    let onRemoveWarning: () -> Void

    var body: some View {
        BookingClashWarningCard(
            warning: warning,
            onRemove: onRemove,
            onApprove: onApprove,
            onOpenDay: onOpenDay,
            onRemoveWarning: onRemoveWarning
        )
    }
}

struct BookingClashWarningCard: View {
    let warning: Warning
    let onRemove: (Warning.ClashTimelineEntry) -> Void
    let onApprove: () -> Void
    let onOpenDay: () -> Void
    let onRemoveWarning: () -> Void

    @State private var timelineOpen = false

    private var entries: [Warning.ClashTimelineEntry] { warning.clashEntries }
    private var personName: String { warning.clashPersonName ?? "" }
    private var date: Date { warning.clashDate ?? Date() }
    private var personKind: Warning.ClashPersonKind {
        warning.clashPersonKind ?? .operative
    }

    private var window: WarningTimelineMath.ClashWindow {
        WarningTimelineMath.fitWindow(entries: entries)
    }

    private var analysis: WarningTimelineMath.ClashAnalysis {
        WarningTimelineMath.analyse(entries: entries, window: window)
    }

    private var dateLabel: String {
        date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
    }

    private var placeWord: String { WarningTimelineMath.placeWord(entries.count) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            VStack(alignment: .leading, spacing: 12) {
                lede
                personRow
                summaryRow
                microStrip
                bookingList
                if timelineOpen {
                    fullTimeline
                }
                approveButton
            }
            .padding(.horizontal, 14)
            .padding(.top, 13)
            .padding(.bottom, 14)

            footer
        }
        .background(Color.white)
        .clipShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 15, style: .continuous)
                .stroke(Color.black.opacity(0.07), lineWidth: 0.5)
        )
        .shadow(color: Color.black.opacity(0.08), radius: 8, x: 0, y: 2)
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 10) {
            Text(warning.title)
                .font(.system(size: 16.5, weight: .semibold))
                .foregroundStyle(.white)
                .tracking(-0.15)
                .frame(maxWidth: .infinity, alignment: .leading)
            WarningPriorityBadge(severity: warning.severity)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .background(
            LinearGradient(
                colors: headerColors,
                startPoint: .top,
                endPoint: .bottom
            )
        )
    }

    private var headerColors: [Color] {
        switch warning.severity {
        case .high:
            return [Color(red: 0.702, green: 0.149, blue: 0.118), Color(red: 0.549, green: 0.102, blue: 0.078)]
        case .medium:
            return [Color(red: 0.784, green: 0.416, blue: 0.086), Color(red: 0.635, green: 0.306, blue: 0.047)]
        case .low:
            return [Color(red: 0.290, green: 0.396, blue: 0.447), Color(red: 0.200, green: 0.278, blue: 0.310)]
        }
    }

    private var lede: some View {
        VStack(alignment: .leading, spacing: 4) {
            (Text(personName).fontWeight(.semibold) + Text(" is booked in \(placeWord) places on \(dateLabel)."))
                .font(.system(size: 14.5))
                .foregroundStyle(Color(red: 0.071, green: 0.106, blue: 0.137))
                .fixedSize(horizontal: false, vertical: true)
            Text("Approve if it’s intentional and it’ll be noted on the weekly report.")
                .font(.system(size: 13.5))
                .foregroundStyle(Color(red: 0.424, green: 0.424, blue: 0.447))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var personRow: some View {
        HStack(spacing: 9) {
            Text(PlannerUIInitials.from(personName))
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 30, height: 30)
                .background(Color(red: 0.180, green: 0.522, blue: 0.910))
                .clipShape(Circle())
            Text(personName)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Color(red: 0.071, green: 0.106, blue: 0.137))
                .lineLimit(2)
            Spacer(minLength: 8)
            Text(dateLabel)
                .font(.system(size: 13, weight: .regular).monospacedDigit())
                .foregroundStyle(Color(red: 0.424, green: 0.424, blue: 0.447))
        }
    }

    private var summaryRow: some View {
        let clash = Color(red: 0.702, green: 0.149, blue: 0.118)
        return HStack(spacing: 8) {
            Text("\(WarningTimelineMath.formatDuration(minutes: analysis.minutes)) overlap")
                .font(.system(size: 14.5, weight: .semibold).monospacedDigit())
                .foregroundStyle(clash)
            if let start = analysis.startMinutes, let end = analysis.endMinutes {
                Text("·")
                    .foregroundStyle(Color(red: 0.604, green: 0.604, blue: 0.627))
                Text("\(WarningTimelineMath.formatClock(start))–\(WarningTimelineMath.formatClock(end))")
                    .font(.system(size: 13).monospacedDigit())
                    .foregroundStyle(Color(red: 0.424, green: 0.424, blue: 0.447))
            }
            if analysis.peak > 2 {
                Text("·")
                    .foregroundStyle(Color(red: 0.604, green: 0.604, blue: 0.627))
                Text("up to \(analysis.peak) at once")
                    .font(.system(size: 13).monospacedDigit())
                    .foregroundStyle(Color(red: 0.424, green: 0.424, blue: 0.447))
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 8)
        .background(clash.opacity(0.09))
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .stroke(clash.opacity(0.30), lineWidth: 0.5)
        )
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
    }

    private var microStrip: some View {
        VStack(spacing: 3) {
            ForEach(Array(entries.enumerated()), id: \.element.rowId) { index, entry in
                clashLane(entry: entry, palette: palette(at: index), height: 9, corner: 3)
            }
            axisRow
        }
        .padding(.horizontal, 12)
        .padding(.top, 11)
        .padding(.bottom, 7)
        .background(Color(red: 0.945, green: 0.949, blue: 0.965))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var bookingList: some View {
        VStack(spacing: 0) {
            ForEach(Array(entries.enumerated()), id: \.element.rowId) { index, entry in
                if index > 0 {
                    Rectangle().fill(Color.black.opacity(0.08)).frame(height: 0.5)
                }
                bookingRow(entry: entry, palette: palette(at: index))
            }
            Rectangle().fill(Color.black.opacity(0.08)).frame(height: 0.5)
            Button {
                withAnimation(.easeInOut(duration: 0.18)) { timelineOpen.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Text(timelineOpen ? "Hide full timeline" : "Show full timeline")
                    Image(systemName: "chevron.down")
                        .font(.system(size: 11, weight: .semibold))
                        .rotationEffect(.degrees(timelineOpen ? 180 : 0))
                }
                .font(.system(size: 13.5, weight: .medium))
                .foregroundStyle(Color(red: 0.039, green: 0.400, blue: 0.839))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 11)
                .frame(minHeight: 44)
            }
            .buttonStyle(.plain)
        }
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.black.opacity(0.08), lineWidth: 0.5)
        )
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func bookingRow(entry: Warning.ClashTimelineEntry, palette: ClashBarPalette) -> some View {
        let mine = WarningTimelineMath.clashMinutes(for: entry, window: window, analysis: analysis)
        return HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(palette.soft)
                Image(systemName: entry.jobNumber == nil ? "house" : "building.2")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(palette.ink)
            }
            .frame(width: 30, height: 30)

            VStack(alignment: .leading, spacing: 1) {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    if let code = entry.jobNumber {
                        Text(code)
                            .font(.system(size: 14.5, weight: .bold))
                            .foregroundStyle(palette.ink)
                    }
                    Text(entry.displayTitle)
                        .font(.system(size: 14.5, weight: .semibold))
                        .foregroundStyle(Color(red: 0.071, green: 0.106, blue: 0.137))
                }
                .fixedSize(horizontal: false, vertical: true)

                (
                    Text(timeText(entry))
                    + Text(subtitle(for: entry).map { " · \($0)" } ?? "")
                    + Text(" · ")
                    + Text("\(WarningTimelineMath.formatDuration(minutes: mine)) clashing")
                        .fontWeight(.semibold)
                        .foregroundColor(Color(red: 0.702, green: 0.149, blue: 0.118))
                )
                .font(.system(size: 12.5).monospacedDigit())
                .foregroundStyle(Color(red: 0.424, green: 0.424, blue: 0.447))
                .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Button {
                onRemove(entry)
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Color(red: 0.702, green: 0.149, blue: 0.118))
                    .frame(width: 34, height: 34)
                    .background(Color(red: 0.937, green: 0.937, blue: 0.957))
                    .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Remove \(entry.jobNumber.map { "\($0) " } ?? "")\(entry.displayTitle)")
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 10)
        .frame(minHeight: 46)
    }

    private var fullTimeline: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(entries.enumerated()), id: \.element.rowId) { index, entry in
                if index > 0 {
                    Rectangle().fill(Color.black.opacity(0.08)).frame(height: 0.5)
                }
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .firstTextBaseline, spacing: 7) {
                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                            .fill(palette(at: index).ink)
                            .frame(width: 9, height: 9)
                        if let code = entry.jobNumber {
                            Text(code)
                                .font(.system(size: 14, weight: .bold))
                                .foregroundStyle(palette(at: index).ink)
                        }
                        Text(entry.displayTitle)
                            .font(.system(size: 13.5))
                            .foregroundStyle(Color(red: 0.071, green: 0.106, blue: 0.137))
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text(timeText(entry))
                            .font(.system(size: 12.5, weight: .semibold).monospacedDigit())
                            .foregroundStyle(Color(red: 0.424, green: 0.424, blue: 0.447))
                    }
                    clashLane(entry: entry, palette: palette(at: index), height: 14, corner: 5)
                }
            }
            axisRow
        }
        .padding(.horizontal, 12)
        .padding(.top, 12)
        .padding(.bottom, 8)
        .background(Color(red: 0.945, green: 0.949, blue: 0.965))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var approveButton: some View {
        Button(action: onApprove) {
            HStack(spacing: 8) {
                Image(systemName: "checkmark")
                    .font(.system(size: 15, weight: .bold))
                Text("Approve for weekly report")
                    .font(.system(size: 15.5, weight: .semibold))
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 13)
            .frame(minHeight: 46)
            .background(
                LinearGradient(
                    colors: [Color(red: 0.118, green: 0.541, blue: 0.369), Color(red: 0.078, green: 0.388, blue: 0.255)],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
        }
        .buttonStyle(.plain)
        .padding(.top, 1)
    }

    private var footer: some View {
        HStack(spacing: 0) {
            Button(action: onOpenDay) {
                Text("Open daily overview")
                    .font(.system(size: 14.5, weight: .medium))
                    .foregroundStyle(Color(red: 0.039, green: 0.400, blue: 0.839))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 13)
                    .frame(minHeight: 46)
            }
            .buttonStyle(.plain)
            Rectangle()
                .fill(Color.black.opacity(0.10))
                .frame(width: 0.5)
            Button(action: onRemoveWarning) {
                Text("Dismiss")
                    .font(.system(size: 14.5, weight: .medium))
                    .foregroundStyle(Color(red: 0.424, green: 0.424, blue: 0.447))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 13)
                    .frame(minHeight: 46)
            }
            .buttonStyle(.plain)
        }
        .overlay(alignment: .top) {
            Rectangle().fill(Color.black.opacity(0.08)).frame(height: 0.5)
        }
    }

    private func clashLane(entry: Warning.ClashTimelineEntry, palette: ClashBarPalette, height: CGFloat, corner: CGFloat) -> some View {
        GeometryReader { geo in
            let w = geo.size.width
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: corner, style: .continuous)
                    .fill(Color(red: 0.937, green: 0.937, blue: 0.957))
                ForEach(Array(analysis.regions.enumerated()), id: \.offset) { _, region in
                    let left = max(0, WarningTimelineMath.fraction(in: window, minutes: region.startMinutes)) * w
                    let right = min(1, WarningTimelineMath.fraction(in: window, minutes: region.endMinutes)) * w
                    Rectangle()
                        .fill(Color(red: 0.702, green: 0.149, blue: 0.118).opacity(0.12))
                        .frame(width: max(1, right - left))
                        .offset(x: left)
                }
                let iv = WarningTimelineMath.interval(of: entry, window: window)
                let left = max(0, WarningTimelineMath.fraction(in: window, minutes: max(iv.0, window.startMinutes))) * w
                let right = min(1, WarningTimelineMath.fraction(in: window, minutes: min(iv.1, window.endMinutes))) * w
                let barW = max(3, right - left)
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: corner, style: .continuous)
                        .fill(palette.bar)
                    if entry.treatsAsAllDay {
                        ClashHatchOverlay(spacing: 9, opacity: 0.30)
                            .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
                    } else {
                        ForEach(Array(analysis.regions.enumerated()), id: \.offset) { _, region in
                            let s = max(region.startMinutes, iv.0)
                            let e = min(region.endMinutes, iv.1)
                            if e > s {
                                let span = max(1, iv.1 - iv.0)
                                let ol = CGFloat(s - iv.0) / CGFloat(span) * barW
                                let ow = CGFloat(e - s) / CGFloat(span) * barW
                                ClashHatchOverlay(spacing: 7, opacity: 0.34)
                                    .frame(width: max(1, ow))
                                    .offset(x: ol)
                            }
                        }
                    }
                }
                .frame(width: barW)
                .offset(x: left)
            }
            .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
        }
        .frame(height: height)
    }

    private var axisRow: some View {
        let ticks = WarningTimelineMath.axisTicks(window)
        return GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                ForEach(Array(ticks.enumerated()), id: \.offset) { index, tick in
                    let x = WarningTimelineMath.fraction(in: window, minutes: tick) * geo.size.width
                    Text(WarningTimelineMath.formatClock(tick))
                        .font(.system(size: 10).monospacedDigit())
                        .foregroundStyle(Color(red: 0.604, green: 0.604, blue: 0.627))
                        .offset(x: axisOffset(x: x, index: index, last: index == ticks.count - 1, width: geo.size.width))
                }
            }
        }
        .frame(height: 13)
        .padding(.top, 5)
    }

    private func axisOffset(x: CGFloat, index: Int, last: Bool, width: CGFloat) -> CGFloat {
        if index == 0 { return x }
        if last { return x - 36 }
        return x - 18
    }

    private func timeText(_ entry: Warning.ClashTimelineEntry) -> String {
        if entry.treatsAsAllDay { return "All day" }
        return "\(WarningTimelineMath.formatClock(entry.startMinutes))–\(WarningTimelineMath.formatClock(entry.endMinutes))"
    }

    private func subtitle(for entry: Warning.ClashTimelineEntry) -> String? {
        guard entry.jobNumber == nil else { return nil }
        switch personKind {
        case .admin: return "Admins"
        case .manager: return "Managers"
        case .operative: return "Operatives"
        }
    }

    private func palette(at index: Int) -> ClashBarPalette {
        ClashBarPalette.allCases[index % ClashBarPalette.allCases.count]
    }
}

private enum ClashBarPalette: CaseIterable {
    case green, blue, indigo, amber

    var ink: Color {
        switch self {
        case .green: return Color(red: 0.090, green: 0.447, blue: 0.290)
        case .blue: return Color(red: 0.039, green: 0.373, blue: 0.753)
        case .indigo: return Color(red: 0.290, green: 0.247, blue: 0.753)
        case .amber: return Color(red: 0.604, green: 0.357, blue: 0.031)
        }
    }

    var soft: Color {
        switch self {
        case .green: return Color(red: 0.875, green: 0.945, blue: 0.910)
        case .blue: return Color(red: 0.886, green: 0.933, blue: 0.984)
        case .indigo: return Color(red: 0.906, green: 0.898, blue: 0.984)
        case .amber: return Color(red: 0.984, green: 0.937, blue: 0.863)
        }
    }

    var bar: LinearGradient {
        switch self {
        case .green:
            return LinearGradient(colors: [Color(red: 0.165, green: 0.627, blue: 0.420), Color(red: 0.090, green: 0.447, blue: 0.290)], startPoint: .top, endPoint: .bottom)
        case .blue:
            return LinearGradient(colors: [Color(red: 0.180, green: 0.522, blue: 0.910), Color(red: 0.039, green: 0.373, blue: 0.753)], startPoint: .top, endPoint: .bottom)
        case .indigo:
            return LinearGradient(colors: [Color(red: 0.486, green: 0.435, blue: 0.910), Color(red: 0.290, green: 0.247, blue: 0.753)], startPoint: .top, endPoint: .bottom)
        case .amber:
            return LinearGradient(colors: [Color(red: 0.816, green: 0.541, blue: 0.110), Color(red: 0.604, green: 0.357, blue: 0.031)], startPoint: .top, endPoint: .bottom)
        }
    }
}

private struct ClashHatchOverlay: View {
    var spacing: CGFloat
    var opacity: Double

    var body: some View {
        Canvas { context, size in
            var x: CGFloat = -size.height
            while x < size.width + size.height {
                var path = Path()
                path.move(to: CGPoint(x: x, y: size.height))
                path.addLine(to: CGPoint(x: x + size.height, y: 0))
                context.stroke(path, with: .color(.white.opacity(opacity)), lineWidth: 2)
                x += spacing
            }
        }
        .allowsHitTesting(false)
    }
}
