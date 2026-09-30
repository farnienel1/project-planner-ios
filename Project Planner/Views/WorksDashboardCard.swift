//
//  WorksDashboardCard.swift
//  Project Planner
//
//  Shared Projects and Small works list presentation.
//  Look-and-feel: projects-ios-redesign.html. Rows, taps, and filters stay as they are.
//

import SwiftUI

enum WorksDashboardPalette {
    static let bg = AppAdaptiveColor.dynamic(
        light: AppAdaptiveColor.rgb(0.949, 0.961, 0.980),
        dark: AppAdaptiveColor.rgb(0.043, 0.071, 0.125)
    )
    static let card = AppAdaptiveColor.dynamic(
        light: .white,
        dark: AppAdaptiveColor.rgb(0.075, 0.110, 0.180)
    )
    static let soft = AppAdaptiveColor.dynamic(
        light: AppAdaptiveColor.rgb(0.933, 0.953, 0.976),
        dark: AppAdaptiveColor.rgb(0.090, 0.133, 0.220)
    )
    static let soft2 = AppAdaptiveColor.dynamic(
        light: AppAdaptiveColor.rgb(0.890, 0.918, 0.957),
        dark: AppAdaptiveColor.rgb(0.118, 0.165, 0.267)
    )
    static let line = AppAdaptiveColor.dynamic(
        light: AppAdaptiveColor.rgb(0.886, 0.910, 0.949),
        dark: AppAdaptiveColor.rgb(0.141, 0.192, 0.294)
    )
    static let ink = AppAdaptiveColor.dynamic(
        light: AppAdaptiveColor.rgb(0.055, 0.090, 0.149),
        dark: AppAdaptiveColor.rgb(0.918, 0.941, 0.973)
    )
    static let ink2 = AppAdaptiveColor.dynamic(
        light: AppAdaptiveColor.rgb(0.275, 0.333, 0.420),
        dark: AppAdaptiveColor.rgb(0.686, 0.733, 0.808)
    )
    static let ink3 = AppAdaptiveColor.dynamic(
        light: AppAdaptiveColor.rgb(0.478, 0.529, 0.608),
        dark: AppAdaptiveColor.rgb(0.494, 0.549, 0.647)
    )
    static let blue = AppAdaptiveColor.dynamic(
        light: AppAdaptiveColor.rgb(0.145, 0.388, 0.788),
        dark: AppAdaptiveColor.rgb(0.298, 0.545, 0.902)
    )
    static let blueTint = AppAdaptiveColor.dynamic(
        light: AppAdaptiveColor.rgb(0.902, 0.937, 0.988),
        dark: AppAdaptiveColor.rgb(0.090, 0.173, 0.302)
    )
    static let proj = AppAdaptiveColor.dynamic(
        light: AppAdaptiveColor.rgb(0.055, 0.663, 0.486),
        dark: AppAdaptiveColor.rgb(0.231, 0.796, 0.596)
    )
    static let projTint = AppAdaptiveColor.dynamic(
        light: AppAdaptiveColor.rgb(0.882, 0.969, 0.937),
        dark: AppAdaptiveColor.rgb(0.067, 0.196, 0.165)
    )
    static let sw = AppAdaptiveColor.dynamic(
        light: AppAdaptiveColor.rgb(0.878, 0.482, 0.133),
        dark: AppAdaptiveColor.rgb(0.961, 0.604, 0.271)
    )
    static let swTint = AppAdaptiveColor.dynamic(
        light: AppAdaptiveColor.rgb(0.988, 0.933, 0.882),
        dark: AppAdaptiveColor.rgb(0.227, 0.145, 0.071)
    )
    static let amber = AppAdaptiveColor.dynamic(
        light: AppAdaptiveColor.rgb(0.788, 0.518, 0.000),
        dark: AppAdaptiveColor.rgb(0.961, 0.725, 0.227)
    )
    static let amberTint = AppAdaptiveColor.dynamic(
        light: AppAdaptiveColor.rgb(0.988, 0.953, 0.855),
        dark: AppAdaptiveColor.rgb(0.227, 0.173, 0.047)
    )
    static let red = AppAdaptiveColor.dynamic(
        light: AppAdaptiveColor.rgb(0.827, 0.271, 0.247),
        dark: AppAdaptiveColor.rgb(1.000, 0.420, 0.420)
    )
    static let redTint = AppAdaptiveColor.dynamic(
        light: AppAdaptiveColor.rgb(0.984, 0.910, 0.906),
        dark: AppAdaptiveColor.rgb(0.239, 0.090, 0.090)
    )
    static let violet = AppAdaptiveColor.dynamic(
        light: AppAdaptiveColor.rgb(0.478, 0.357, 0.941),
        dark: AppAdaptiveColor.rgb(0.655, 0.545, 1.000)
    )
    static let violetTint = AppAdaptiveColor.dynamic(
        light: AppAdaptiveColor.rgb(0.933, 0.918, 0.996),
        dark: AppAdaptiveColor.rgb(0.141, 0.110, 0.290)
    )
    static let teal = AppAdaptiveColor.dynamic(
        light: AppAdaptiveColor.rgb(0.071, 0.639, 0.604),
        dark: AppAdaptiveColor.rgb(0.204, 0.804, 0.733)
    )
    static let tealTint = AppAdaptiveColor.dynamic(
        light: AppAdaptiveColor.rgb(0.878, 0.961, 0.953),
        dark: AppAdaptiveColor.rgb(0.055, 0.200, 0.188)
    )
    static let slate = AppAdaptiveColor.dynamic(
        light: AppAdaptiveColor.rgb(0.392, 0.455, 0.545),
        dark: AppAdaptiveColor.rgb(0.580, 0.639, 0.722)
    )
    static let slateTint = AppAdaptiveColor.dynamic(
        light: AppAdaptiveColor.rgb(0.929, 0.945, 0.965),
        dark: AppAdaptiveColor.rgb(0.106, 0.141, 0.212)
    )
}

struct WorksDashboardListStyle {
    let title: String
    let subtitle: String
    let systemImage: String
    let accent: Color
    let accentTint: Color
    let searchPlaceholder: String
    let emptyCreatePrompt: String

    static let projects = WorksDashboardListStyle(
        title: "Projects",
        subtitle: "Main project pipeline",
        systemImage: "folder",
        accent: WorksDashboardPalette.proj,
        accentTint: WorksDashboardPalette.projTint,
        searchPlaceholder: "Search projects, addresses",
        emptyCreatePrompt: "Nothing here right now. Tap + to start a project."
    )

    static let smallWorks = WorksDashboardListStyle(
        title: "Small works",
        subtitle: "Reactive and ad-hoc jobs",
        systemImage: "wrench.and.screwdriver",
        accent: WorksDashboardPalette.sw,
        accentTint: WorksDashboardPalette.swTint,
        searchPlaceholder: "Search small works, addresses",
        emptyCreatePrompt: "Nothing here right now. Tap + to start a small works job."
    )
}

enum WorksDashboardJobTypeStyle {
    struct Swatch {
        let color: Color
        let tint: Color
    }

    /// Colour for the chip, left rail, and ring. Names come from `JobType` and the
    /// organisation job-type labels already shown on the card. Anything else is slate.
    static func swatch(forDisplayLabel label: String) -> Swatch {
        switch normalized(label) {
        case "CAT A":
            return Swatch(color: WorksDashboardPalette.proj, tint: WorksDashboardPalette.projTint)
        case "CAT B":
            return Swatch(color: WorksDashboardPalette.blue, tint: WorksDashboardPalette.blueTint)
        case "DE CARBONISATION", "DECARBONISATION":
            return Swatch(color: WorksDashboardPalette.teal, tint: WorksDashboardPalette.tealTint)
        case "MAINTENANCE":
            return Swatch(color: WorksDashboardPalette.amber, tint: WorksDashboardPalette.amberTint)
        case "NEW BUILD":
            return Swatch(color: WorksDashboardPalette.violet, tint: WorksDashboardPalette.violetTint)
        case "SMALL WORKS":
            return Swatch(color: WorksDashboardPalette.sw, tint: WorksDashboardPalette.swTint)
        default:
            return Swatch(color: WorksDashboardPalette.slate, tint: WorksDashboardPalette.slateTint)
        }
    }

    static func displayLabel(for project: Project) -> String {
        if let custom = project.customJobType?.trimmingCharacters(in: .whitespacesAndNewlines), !custom.isEmpty {
            return custom.uppercased()
        }
        return project.jobType.rawValue.uppercased()
    }

    private static func normalized(_ label: String) -> String {
        label
            .uppercased()
            .replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: "_", with: " ")
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }
}

enum WorksDashboardDeadline {
    case hidden
    case completed
    case remaining(Int)
    case overdue(Int)

    /// Derived at render time. `Project.endDate` is required; a day count that cannot
    /// be formed shows nothing rather than a placeholder.
    static func from(project: Project, now: Date = Date(), calendar: Calendar = .current) -> WorksDashboardDeadline {
        if project.status == .completed { return .completed }
        let start = calendar.startOfDay(for: now)
        let end = calendar.startOfDay(for: project.endDate)
        guard let days = calendar.dateComponents([.day], from: start, to: end).day else {
            return .hidden
        }
        if days < 0 { return .overdue(-days) }
        return .remaining(days)
    }

    var label: String? {
        switch self {
        case .hidden:
            return nil
        case .completed:
            return "Completed"
        case .remaining(let days):
            return days == 1 ? "1 day left" : "\(days) days left"
        case .overdue(let days):
            return days == 1 ? "1 day over" : "\(days) days over"
        }
    }

    var color: Color {
        switch self {
        case .hidden:
            return WorksDashboardPalette.ink3
        case .completed:
            return WorksDashboardPalette.slate
        case .remaining(let days):
            return days > 14 ? WorksDashboardPalette.proj : WorksDashboardPalette.amber
        case .overdue:
            return WorksDashboardPalette.red
        }
    }

    var tint: Color {
        switch self {
        case .hidden:
            return WorksDashboardPalette.soft
        case .completed:
            return WorksDashboardPalette.slateTint
        case .remaining(let days):
            return days > 14 ? WorksDashboardPalette.projTint : WorksDashboardPalette.amberTint
        case .overdue:
            return WorksDashboardPalette.redTint
        }
    }
}

struct WorksDashboardHero: View {
    let style: WorksDashboardListStyle

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: style.systemImage)
                .font(.title3.weight(.semibold))
                .foregroundStyle(style.accent)
                .frame(width: 46, height: 46)
                .background(style.accentTint)
                .clipShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
            VStack(alignment: .leading, spacing: 3) {
                Text(style.title)
                    .font(.largeTitle.weight(.heavy))
                    .foregroundStyle(WorksDashboardPalette.ink)
                    .accessibilityAddTraits(.isHeader)
                Text(style.subtitle)
                    .font(.subheadline)
                    .foregroundStyle(WorksDashboardPalette.ink3)
            }
            Spacer(minLength: 0)
        }
        .padding(.bottom, 14)
    }
}

struct WorksDashboardStatsRow: View {
    let counts: WorksListStatusCounts
    @Binding var selectedStatus: ProjectStatus?
    @State private var selectionTick = 0

    var body: some View {
        HStack(spacing: 9) {
            tile(status: .active, value: counts.active, label: "Active", color: WorksDashboardPalette.proj, tint: WorksDashboardPalette.projTint)
            tile(status: .upcoming, value: counts.upcoming, label: "Upcoming", color: WorksDashboardPalette.blue, tint: WorksDashboardPalette.blueTint)
            tile(status: .completed, value: counts.completed, label: "Completed", color: WorksDashboardPalette.slate, tint: WorksDashboardPalette.slateTint)
        }
        .sensoryFeedback(.selection, trigger: selectionTick)
    }

    private func tile(status: ProjectStatus, value: Int, label: String, color: Color, tint: Color) -> some View {
        let isSelected = selectedStatus == status
        return Button {
            selectedStatus = isSelected ? nil : status
            selectionTick += 1
        } label: {
            HStack(spacing: 0) {
                Rectangle()
                    .fill(color)
                    .frame(width: 4)
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(value)")
                        .font(.title.weight(.heavy))
                        .foregroundStyle(color)
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                    Text(label)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(WorksDashboardPalette.ink2)
                        .lineLimit(2)
                        .minimumScaleFactor(0.8)
                }
                .padding(.vertical, 13)
                .padding(.horizontal, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(isSelected ? tint : WorksDashboardPalette.card)
            .clipShape(RoundedRectangle(cornerRadius: 19, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 19, style: .continuous)
                    .stroke(isSelected ? color.opacity(0.32) : WorksDashboardPalette.line, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(label), \(value)")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityHint(isSelected ? "Clears the filter" : "Filters the list")
    }
}

struct WorksDashboardSearchRow<FilterMenu: View>: View {
    @Binding var text: String
    var placeholder: String
    @ViewBuilder var filterMenu: () -> FilterMenu

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.body.weight(.medium))
                .foregroundStyle(WorksDashboardPalette.ink3)
            TextField(placeholder, text: $text)
                .font(.callout)
                .foregroundStyle(WorksDashboardPalette.ink)
            filterMenu()
        }
        .padding(.horizontal, 15)
        .padding(.vertical, 13)
        .background(WorksDashboardPalette.card)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(WorksDashboardPalette.line, lineWidth: 1)
        )
    }
}

struct WorksDashboardCard: View {
    let project: Project
    let listAccent: Color
    var showsClientAndManager: Bool = true

    @EnvironmentObject private var operativeStore: OperativeStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var drawnFraction: Double = 0

    private var typeLabel: String { WorksDashboardJobTypeStyle.displayLabel(for: project) }
    private var typeSwatch: WorksDashboardJobTypeStyle.Swatch {
        WorksDashboardJobTypeStyle.swatch(forDisplayLabel: typeLabel)
    }
    private var progressFraction: Double {
        min(max(WorksListProgress.fraction(for: project), 0), 1)
    }
    private var progressPercent: Int { WorksListProgress.percentDisplay(for: project) }
    private var deadline: WorksDashboardDeadline { WorksDashboardDeadline.from(project: project) }

    private var isPastEnd: Bool {
        let calendar = Calendar.current
        return calendar.startOfDay(for: Date()) > calendar.startOfDay(for: project.endDate)
    }

    private var ringColor: Color {
        if project.status == .completed { return WorksDashboardPalette.slate }
        if project.isLive && isPastEnd { return WorksDashboardPalette.red }
        return typeSwatch.color
    }

    var body: some View {
        HStack(spacing: 0) {
            Rectangle()
                .fill(typeSwatch.color)
                .frame(width: 6)
            VStack(alignment: .leading, spacing: 13) {
                HStack(alignment: .top, spacing: 13) {
                    infoColumn
                    progressRing
                }
                footer
            }
            .padding(EdgeInsets(top: 16, leading: 16, bottom: 14, trailing: 16))
        }
        .background(WorksDashboardPalette.card)
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(WorksDashboardPalette.line, lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.06), radius: 10, x: 0, y: 6)
        .opacity(project.status == .completed ? 0.72 : 1)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilitySummary)
        .accessibilityAddTraits(.isButton)
        .onAppear {
            drawnFraction = reduceMotion ? progressFraction : 0
            guard !reduceMotion else { return }
            withAnimation(.easeOut(duration: 0.4)) {
                drawnFraction = progressFraction
            }
        }
        .onChange(of: progressFraction) { _, newValue in
            if reduceMotion {
                drawnFraction = newValue
            } else {
                withAnimation(.easeOut(duration: 0.4)) {
                    drawnFraction = newValue
                }
            }
        }
    }

    private var infoColumn: some View {
        VStack(alignment: .leading, spacing: 0) {
            WorksDashboardWrap(spacing: 8) {
                Text(project.jobNumber)
                    .font(.title3.weight(.heavy))
                    .foregroundStyle(WorksDashboardPalette.ink)
                    .lineLimit(1)
                Text(typeLabel)
                    .font(.subheadline.weight(.heavy))
                    .foregroundStyle(typeSwatch.color)
                    .lineLimit(1)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 3)
                    .background(typeSwatch.tint)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            Text(project.siteName)
                .font(.title3.weight(.bold))
                .foregroundStyle(WorksDashboardPalette.ink)
                .lineLimit(1)
                .truncationMode(.tail)
                .padding(.top, 5)

            VStack(alignment: .leading, spacing: 4) {
                if showsClientAndManager {
                    metaRow(systemImage: "building.2", text: project.client.name, emphasize: true)
                }
                if !project.siteAddress.isEmpty {
                    metaRow(systemImage: "mappin.and.ellipse", text: project.siteAddress, emphasize: false)
                }
                if showsClientAndManager, !managerDisplayName.isEmpty {
                    metaRow(systemImage: "person", text: managerDisplayName, emphasize: true)
                }
                metaRow(systemImage: "calendar", text: dateRangeDisplay, emphasize: false)
            }
            .padding(.top, 8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var progressRing: some View {
        ZStack {
            Circle()
                .stroke(WorksDashboardPalette.soft2, lineWidth: 7)
            Circle()
                .trim(from: 0, to: drawnFraction)
                .stroke(ringColor, style: StrokeStyle(lineWidth: 7, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Text("\(progressPercent)%")
                .font(.title3.weight(.heavy))
                .foregroundStyle(ringColor)
                .minimumScaleFactor(0.5)
                .lineLimit(1)
                .dynamicTypeSize(.xSmall ... .accessibility1)
                .padding(8)
        }
        .frame(width: 74, height: 74)
        .accessibilityHidden(true)
    }

    private var footer: some View {
        HStack(alignment: .top, spacing: 8) {
            WorksDashboardWrap(spacing: 8) {
                if let label = deadline.label {
                    tag(label, color: deadline.color, tint: deadline.tint)
                }
                tag(statusTitle, color: statusColor, tint: statusTint)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text("Open ›")
                .font(.subheadline.weight(.bold))
                .foregroundStyle(listAccent)
                .fixedSize()
                .padding(.top, 5)
        }
        .padding(.top, 12)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(WorksDashboardPalette.line)
                .frame(height: 1)
        }
    }

    private func tag(_ title: String, color: Color, tint: Color) -> some View {
        HStack(spacing: 6) {
            Circle()
                .fill(color)
                .frame(width: 7, height: 7)
            Text(title)
                .font(.subheadline.weight(.bold))
                .foregroundStyle(color)
                .lineLimit(1)
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 5)
        .background(tint)
        .clipShape(Capsule())
    }

    private func metaRow(systemImage: String, text: String, emphasize: Bool) -> some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage)
                .font(.subheadline)
                .foregroundStyle(WorksDashboardPalette.ink3)
                .frame(width: 15)
            Text(text)
                .font(.subheadline.weight(emphasize ? .semibold : .regular))
                .foregroundStyle(emphasize ? WorksDashboardPalette.ink : WorksDashboardPalette.ink2)
                .lineLimit(1)
                .truncationMode(.tail)
        }
    }

    private var managerDisplayName: String {
        if let managerId = project.managerId,
           let manager = operativeStore.allManagers.first(where: { $0.id == managerId }) {
            return "\(manager.firstName) \(manager.lastName)".trimmingCharacters(in: .whitespaces)
        }
        return project.manager.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var dateRangeDisplay: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "d MMM yyyy"
        return "\(formatter.string(from: project.startDate)) – \(formatter.string(from: project.endDate))"
    }

    private var statusTitle: String { project.status.rawValue }

    private var statusColor: Color {
        switch project.status {
        case .active: return WorksDashboardPalette.proj
        case .upcoming: return WorksDashboardPalette.blue
        case .completed, .inactive: return WorksDashboardPalette.slate
        }
    }

    private var statusTint: Color {
        switch project.status {
        case .active: return WorksDashboardPalette.projTint
        case .upcoming: return WorksDashboardPalette.blueTint
        case .completed, .inactive: return WorksDashboardPalette.slateTint
        }
    }

    private var accessibilitySummary: String {
        var parts = [project.jobNumber, project.siteName, typeLabel, "\(progressPercent) percent complete"]
        if let label = deadline.label {
            parts.append(label)
        }
        parts.append(project.status.rawValue.lowercased())
        return parts.joined(separator: ", ")
    }
}

/// Tags stay on one row until they no longer fit, then wrap instead of clipping.
private struct WorksDashboardWrap: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .greatestFiniteMagnitude
        let rows = rows(maxWidth: maxWidth, subviews: subviews)
        let height = rows.reduce(0) { $0 + $1.height } + spacing * CGFloat(max(rows.count - 1, 0))
        return CGSize(width: maxWidth == .greatestFiniteMagnitude ? (rows.map(\.width).max() ?? 0) : maxWidth, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let rows = rows(maxWidth: bounds.width, subviews: subviews)
        var y = bounds.minY
        var index = 0
        for row in rows {
            var x = bounds.minX
            for size in row.sizes {
                subviews[index].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width + spacing
                index += 1
            }
            y += row.height + spacing
        }
    }

    private struct Row {
        var sizes: [CGSize] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func rows(maxWidth: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = []
        var current = Row()
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            let nextWidth = current.sizes.isEmpty ? size.width : current.width + spacing + size.width
            if !current.sizes.isEmpty && nextWidth > maxWidth {
                rows.append(current)
                current = Row()
            }
            current.sizes.append(size)
            current.width = current.sizes.count == 1 ? size.width : current.width + spacing + size.width
            current.height = max(current.height, size.height)
        }
        if !current.sizes.isEmpty { rows.append(current) }
        return rows
    }
}
