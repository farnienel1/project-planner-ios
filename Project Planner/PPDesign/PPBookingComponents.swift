//
//  PPBookingComponents.swift
//  Project Planner — Scheduling & Booking UI upgrade (UI ONLY)
//
//  Tokens and building blocks for the Scheduling week, Schedule booking, Schedule subcontractor, Edit booking /
//  Hours, Overtime rate and Unpaid break screens (docs/design/booking-ui/booking-ui-spec.md §2).
//  Colours reuse the Home look (PPColor / PPFamily), not the spec's sample hex values.
//  Labels, containers and styles only: no actions of their own, no data, no calculations, no navigation.
//

import SwiftUI

// MARK: - Tokens

/// Spec §2 tokens mapped onto the existing Home palette. Dark mode comes from PPColor / system colours.
enum PPBookingColor {
    /// Standard hours in bars and chips (`standard`).
    static let standard = PPColor.brand
    /// Overtime stripes (`overtime`): light and deep amber from the Home trade family.
    static let overtime = PPFamily.trade.top
    static let overtimeDeep = PPFamily.trade.bottom
    /// Annual leave (`leave`), the colour the week grid already used.
    static let leave = Color(ppHex: 0x9A5B27)
    /// Half day split (`halfDay`).
    static let halfDayLight = PPColor.brand.opacity(0.35)
    /// Selected chip / segment / "today" (`selectedNavy`). Navy in light mode, a lifted navy in dark mode.
    static let selected = Color.ppDynamic(light: 0x0E1A2E, dark: 0x3A5FA8)
    /// Inner tiles: time tiles, day cells (`fieldBg`).
    static let field = PPColor.well
    /// Project code on navy (`headerTint`).
    static let headerTint = PPColor.glow
    /// Hairline border on cards (`card` border).
    static let cardBorder = Color(.separator).opacity(0.5)
    /// Primary button fill (`primary`).
    static let primaryGradient = PPFamily.plan.gradient
}

enum PPChipTone {
    case blue, amber, green, red, neutral, onNavy

    var ink: Color {
        switch self {
        case .blue: return PPColor.brand
        case .amber: return Color.ppDynamic(light: 0x8A5300, dark: 0xFFC56B)
        case .green: return Color.ppDynamic(light: 0x0A7A5E, dark: 0x5FD8B4)
        case .red: return PPColor.danger
        case .neutral: return .secondary
        case .onNavy: return .white
        }
    }

    var background: Color {
        switch self {
        case .blue: return PPColor.brand.opacity(0.12)
        case .amber: return PPFamily.trade.top.opacity(0.18)
        case .green: return PPFamily.sites.top.opacity(0.16)
        case .red: return PPColor.danger.opacity(0.12)
        case .neutral: return PPColor.well
        case .onNavy: return PPColor.onNavyFill
        }
    }
}

// MARK: - Overtime stripes

/// Diagonal lines filling a rectangle; stroke it over a fill for the overtime stripe pattern.
struct PPDiagonalStripes: Shape {
    var spacing: CGFloat = 6

    func path(in rect: CGRect) -> Path {
        var path = Path()
        var x = -rect.height
        while x < rect.width {
            path.move(to: CGPoint(x: x, y: rect.height))
            path.addLine(to: CGPoint(x: x + rect.height, y: 0))
            x += spacing
        }
        return path
    }
}

/// Amber overtime fill with stripes (spec `overtime`).
struct PPOvertimeFill: View {
    var body: some View {
        ZStack {
            PPBookingColor.overtime
            PPDiagonalStripes(spacing: 6)
                .stroke(PPBookingColor.overtimeDeep.opacity(0.55), lineWidth: 2)
        }
        .clipped()
        .accessibilityHidden(true)
    }
}

// MARK: - Cards and section titles

extension View {
    /// White (dark: grouped) card with a hairline border (spec `card`, radius 16–18).
    func ppBookingCard(padding: CGFloat = 14, radius: CGFloat = 18) -> some View {
        self
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(PPColor.card, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(PPBookingColor.cardBorder, lineWidth: 0.5)
            )
    }
}

// MARK: - Booking action cards (Scheduling "Book people" / "Book a sub")

/// Shared metrics for the side-by-side booking action cards, so the two cards cannot drift apart.
enum PPBookingActionCardMetrics {
    static let iconSize: CGFloat = 38
    static let padding: CGFloat = 12
    static let radius: CGFloat = 18
    /// Fixed card height floor: icon plus a one-line title and a two-line subtitle.
    static let minHeight: CGFloat = 72
    static let subtitleLines: Int = 2
}

/// Icon, bold title and a subtitle that always reserves two lines, so a one-line subtitle ("Subcontractors")
/// gives the same card height as a two-line one ("Operatives & managers"). Label only: no action, no data.
struct PPBookingActionCardLabel: View {
    let title: String
    let subtitle: String
    let symbol: String
    let family: PPFamily

    var body: some View {
        HStack(spacing: 10) {
            PPIconTile(symbol: symbol, family: family, size: PPBookingActionCardMetrics.iconSize, lifted: true)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(PPBookingActionCardMetrics.subtitleLines, reservesSpace: true)
                    .minimumScaleFactor(0.8)
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }
}

/// One card style for every booking action card: same padding, radius, border, minimum height and press effect,
/// and it fills the height its row offers (pair with `.fixedSize(horizontal: false, vertical: true)` on the row so
/// both cards take the taller card's height). Look only; the button's action is unchanged.
struct PPBookingActionCardButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(cornerRadius: PPBookingActionCardMetrics.radius, style: .continuous)
        return configuration.label
            .padding(PPBookingActionCardMetrics.padding)
            .frame(
                maxWidth: .infinity,
                minHeight: PPBookingActionCardMetrics.minHeight,
                maxHeight: .infinity,
                alignment: .leading
            )
            .background(PPColor.card, in: shape)
            .overlay(shape.strokeBorder(PPBookingColor.cardBorder, lineWidth: 0.5))
            .contentShape(shape)
            .ppPressEffect(configuration.isPressed)
    }
}

/// Section title on the light sheet with an optional trailing accessory ("N selected" chip, "+ Add people").
struct PPSheetSectionTitle<Trailing: View>: View {
    let title: String
    let trailing: Trailing

    init(_ title: String, @ViewBuilder trailing: () -> Trailing) {
        self.title = title
        self.trailing = trailing()
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title)
                .font(.system(.title3, design: .rounded))
                .fontWeight(.bold)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 8)
            trailing
        }
        .padding(.horizontal, 2)
        .padding(.top, 18)
        .padding(.bottom, 8)
    }
}

extension PPSheetSectionTitle where Trailing == EmptyView {
    init(_ title: String) {
        self.init(title) { EmptyView() }
    }
}

/// Small caps caption on navy ("BOOKING AT A GLANCE", "THE DAY").
struct PPOnNavyEyebrow: View {
    let text: String

    var body: some View {
        Text(text.uppercased())
            .font(.caption2.weight(.semibold))
            .tracking(1.1)
            .foregroundStyle(PPColor.onNavySecondary)
    }
}

/// "34h paid · 4 shifts" under an eyebrow, on navy.
struct PPGlanceHeadline: View {
    let eyebrow: String
    let primary: String
    var secondary: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            PPOnNavyEyebrow(text: eyebrow)
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(primary)
                    .foregroundStyle(.white)
                if let secondary, !secondary.isEmpty {
                    Text("·").foregroundStyle(PPColor.onNavySecondary)
                    Text(secondary).foregroundStyle(Color.white.opacity(0.7))
                }
            }
            .font(.system(.title2, design: .rounded))
            .fontWeight(.bold)
            .monospacedDigit()
            .lineLimit(2)
            .minimumScaleFactor(0.7)
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Stat row (StatRow)

struct PPStatItem: Identifiable {
    let id: String
    let value: String
    let label: String
    var detail: String? = nil
    var tint: Color = .white
}

/// 2 or 3 big figures with hairline dividers, on navy. Values are passed in; nothing is calculated here.
struct PPStatRow: View {
    let items: [PPStatItem]

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                if index > 0 {
                    PPStatDivider()
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(item.value)
                        .font(.system(.title2, design: .rounded))
                        .fontWeight(.bold)
                        .monospacedDigit()
                        .foregroundStyle(item.tint)
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                    Text(item.label)
                        .font(.caption)
                        .foregroundStyle(PPColor.onNavyCaption)
                        .fixedSize(horizontal: false, vertical: true)
                    if let detail = item.detail, !detail.isEmpty {
                        Text(detail)
                            .font(.caption2.weight(.semibold))
                            .monospacedDigit()
                            .foregroundStyle(item.tint.opacity(0.9))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityElement(children: .combine)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - Day timeline (DayTimelineBar)

/// "00 06 12 18 24" under a 24-hour bar.
struct PPTimelineAxis: View {
    var color: Color = .secondary

    var body: some View {
        HStack(spacing: 0) {
            ForEach(["00", "06", "12", "18", "24"], id: \.self) { label in
                Text(label)
                    .font(.caption2)
                    .monospacedDigit()
                    .foregroundStyle(color)
                if label != "24" { Spacer(minLength: 0) }
            }
        }
        .accessibilityHidden(true)
    }
}

/// The existing `ScheduleHoursTimelineBar` (standard window, overtime, unpaid-break stripe from
/// `ScheduleHoursTimelineSupport.breakRange`) on a 00–24 axis. A wrapper only: the bar's rules are unchanged.
struct PPDayTimelineBar: View {
    let day: Date
    let policy: OrgPayrollTimePolicy
    let workStart: String
    let workEnd: String
    var breakIncluded: Bool = true
    var centerLabel: String? = nil
    var barHeight: CGFloat = 26
    var showsAxis: Bool = true
    var axisColor: Color = .secondary

    var body: some View {
        VStack(spacing: 4) {
            ScheduleHoursTimelineBar(
                day: day,
                policy: policy,
                workIntervals: [],
                workStart: workStart,
                workEnd: workEnd,
                breakIncluded: breakIncluded,
                centerLabel: centerLabel,
                clipLo: 0,
                clipHi: 24 * 60,
                barHeight: barHeight
            )
            if showsAxis {
                PPTimelineAxis(color: axisColor)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Day timeline, \(workStart) to \(workEnd)")
    }
}

/// Legend under a day timeline: Standard, Overtime, Break.
struct PPTimelineLegend: View {
    var showsBreak: Bool = true
    var textColor: Color = .secondary

    var body: some View {
        HStack(spacing: 12) {
            item("Standard") {
                RoundedRectangle(cornerRadius: 3, style: .continuous).fill(PPBookingColor.standard)
            }
            item("Overtime") {
                PPOvertimeFill().clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
            }
            if showsBreak {
                item("Break") {
                    RoundedRectangle(cornerRadius: 3, style: .continuous).fill(Color(red: 0.98, green: 0.65, blue: 0.15))
                }
            }
            Spacer(minLength: 0)
        }
        .font(.caption2.weight(.semibold))
        .foregroundStyle(textColor)
        .accessibilityHidden(true)
    }

    private func item<Swatch: View>(_ title: String, @ViewBuilder swatch: () -> Swatch) -> some View {
        HStack(spacing: 4) {
            swatch().frame(width: 10, height: 10)
            Text(title)
        }
    }
}

// MARK: - Time tile (TimeTile)

/// LABEL for an EXISTING time control: "START 07:00". The button decides what opens (the existing wheel picker).
struct PPTimeTileLabel: View {
    let title: String
    let value: String
    var isActive: Bool = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
        VStack(alignment: .leading, spacing: 2) {
            Text(title.uppercased())
                .font(.caption2.weight(.semibold))
                .tracking(0.8)
                .foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline) {
                Text(value)
                    .font(.system(.title2, design: .rounded))
                    .fontWeight(.semibold)
                    .monospacedDigit()
                    .foregroundStyle(.primary)
                Spacer(minLength: 0)
                Image(systemName: "chevron.down")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(isActive ? 180 : 0))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(PPBookingColor.field, in: shape)
        .overlay(shape.strokeBorder(isActive ? PPColor.brand : Color.clear, lineWidth: 1.5))
        .contentShape(shape)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title) \(value)")
    }
}

// MARK: - Chips (ChipRow)

struct PPChip: View {
    let text: String
    var symbol: String? = nil
    var tone: PPChipTone = .neutral

    var body: some View {
        HStack(spacing: 4) {
            if let symbol {
                Image(systemName: symbol)
                    .font(.caption2.weight(.bold))
            }
            Text(text)
                .font(.caption.weight(.semibold))
                .monospacedDigit()
                .lineLimit(1)
        }
        .foregroundStyle(tone.ink)
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(tone.background, in: Capsule())
    }
}

/// One line of chips that scrolls sideways when Dynamic Type makes it wider than the screen.
struct PPChipRow<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) { content }
                .padding(.vertical, 1)
        }
    }
}

// MARK: - Bottom action bar (BottomActionBar)

/// Chips over one primary button. Disabled, the button says what is missing in readable grey (spec §5).
/// The button runs `action` exactly as the old button did.
struct PPBottomActionBar<Chips: View>: View {
    let title: String
    var trailingValue: String? = nil
    let isEnabled: Bool
    var disabledTitle: String? = nil
    var isBusy: Bool = false
    let accessibilityIdentifier: String
    let action: () -> Void
    let chips: Chips

    init(
        title: String,
        trailingValue: String? = nil,
        isEnabled: Bool,
        disabledTitle: String? = nil,
        isBusy: Bool = false,
        accessibilityIdentifier: String,
        action: @escaping () -> Void,
        @ViewBuilder chips: () -> Chips
    ) {
        self.title = title
        self.trailingValue = trailingValue
        self.isEnabled = isEnabled
        self.disabledTitle = disabledTitle
        self.isBusy = isBusy
        self.accessibilityIdentifier = accessibilityIdentifier
        self.action = action
        self.chips = chips()
    }

    private var shownTitle: String {
        isEnabled ? title : (disabledTitle ?? title)
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 15, style: .continuous)
        VStack(spacing: 10) {
            chips
            Button(action: action) {
                HStack(spacing: 8) {
                    if isBusy {
                        ProgressView()
                            .tint(isEnabled ? .white : .secondary)
                    }
                    if isEnabled, let trailingValue, !trailingValue.isEmpty {
                        Text(shownTitle)
                        Spacer(minLength: 8)
                        Text(trailingValue).monospacedDigit()
                    } else {
                        Text(shownTitle)
                            .frame(maxWidth: .infinity)
                    }
                }
                .font(.headline)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .foregroundStyle(isEnabled ? Color.white : Color.secondary)
                .padding(.horizontal, 18)
                .padding(.vertical, 12)
                .frame(maxWidth: .infinity, minHeight: 52)
                .background {
                    if isEnabled {
                        shape.fill(PPBookingColor.primaryGradient)
                    } else {
                        shape.fill(PPColor.well)
                    }
                }
                .contentShape(shape)
            }
            .buttonStyle(PPPressableButtonStyle())
            .disabled(!isEnabled)
            .accessibilityIdentifier(accessibilityIdentifier)
        }
        .padding(.horizontal, PPMetrics.screenGutter)
        .padding(.top, 10)
        .padding(.bottom, 8)
        .background(.regularMaterial)
        .overlay(alignment: .top) {
            Divider()
        }
    }
}

extension PPBottomActionBar where Chips == EmptyView {
    init(
        title: String,
        trailingValue: String? = nil,
        isEnabled: Bool,
        disabledTitle: String? = nil,
        isBusy: Bool = false,
        accessibilityIdentifier: String,
        action: @escaping () -> Void
    ) {
        self.init(
            title: title,
            trailingValue: trailingValue,
            isEnabled: isEnabled,
            disabledTitle: disabledTitle,
            isBusy: isBusy,
            accessibilityIdentifier: accessibilityIdentifier,
            action: action
        ) { EmptyView() }
    }
}

// MARK: - Segmented pills (SegmentedPills)

/// One option. A hidden option is simply left out of the list; a disabled one is shown greyed and cannot be tapped.
struct PPSegmentItem<ID: Hashable>: Identifiable {
    let id: ID
    let title: String
    var isEnabled: Bool = true
    let accessibilityIdentifier: String
}

/// AM | PM | Full day | Custom. Selection and taps are the caller's existing state and actions.
struct PPSegmentedPills<ID: Hashable>: View {
    let items: [PPSegmentItem<ID>]
    let isSelected: (ID) -> Bool
    let onSelect: (ID) -> Void

    var body: some View {
        HStack(spacing: 4) {
            ForEach(items) { item in
                let selected = isSelected(item.id)
                Button {
                    onSelect(item.id)
                } label: {
                    Text(item.title)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 9)
                        .foregroundStyle(selected ? Color.white : (item.isEnabled ? Color.primary : Color.secondary.opacity(0.6)))
                        .background {
                            if selected {
                                Capsule().fill(PPBookingColor.selected)
                            }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .disabled(!item.isEnabled)
                .accessibilityIdentifier(item.accessibilityIdentifier)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .padding(4)
        .background(PPBookingColor.field, in: Capsule())
    }
}

// MARK: - Header pieces on navy

/// Cancel / Delete pill on the navy header (spec `headerControl`, radius 20).
struct PPOnNavyPillButtonStyle: ButtonStyle {
    var tint: Color = .white

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(tint)
            // Never truncate in a toolbar ("Cancel" was showing as "C"): keep the label on one line at its full
            // width and give it priority over the navigation title.
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .padding(.horizontal, 14)
            .frame(minHeight: 34)
            .background(Capsule().fill(Color.white.opacity(configuration.isPressed ? 0.22 : 0.14)))
            .fixedSize()
            .layoutPriority(1)
            .ppPressEffect(configuration.isPressed)
    }
}

/// Job block at the top of the booking headers: green tile for a project, amber for small works (owner decision 8),
/// code + name, then a detail line and the address.
struct PPJobHeaderBlock: View {
    let code: String
    let name: String
    var detail: String? = nil
    var address: String? = nil
    let isSmallWorks: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 12) {
                PPIconTile(
                    symbol: isSmallWorks ? "hammer.fill" : "building.2.fill",
                    family: isSmallWorks ? .trade : .sites,
                    size: 44,
                    lifted: true
                )
                VStack(alignment: .leading, spacing: 1) {
                    Text(code)
                        .font(.footnote.weight(.bold))
                        .foregroundStyle(PPBookingColor.headerTint)
                    Text(name)
                        .font(.system(.title3, design: .rounded))
                        .fontWeight(.bold)
                        .foregroundStyle(.white)
                        .lineLimit(2)
                }
            }
            if let detail, !detail.isEmpty {
                Text(detail)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(PPColor.onNavySecondary)
                    .lineLimit(2)
            }
            if let address, !address.isEmpty {
                Label(address, systemImage: "mappin.and.ellipse")
                    .font(.footnote)
                    .foregroundStyle(PPColor.onNavySecondary)
                    .lineLimit(2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

struct PPStepTrackerItem: Identifiable {
    let id: Int
    let title: String
    let isDone: Bool
    let isCurrent: Bool
}

/// Dates · Hours · Operatives tracker: done steps get a check, the current step an amber striped bar.
struct PPStepTracker: View {
    let steps: [PPStepTrackerItem]
    /// Done-step tick and bar. Booking keeps green; Add User passes `PPAddUserColor.stepDone` (add-user-ui-spec §3).
    var doneColor: Color = PPFamily.sites.top

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            ForEach(steps) { step in
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 5) {
                        Image(systemName: step.isDone ? "checkmark.circle.fill" : "\(step.id).circle")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(step.isDone ? doneColor : (step.isCurrent ? Color.white : PPColor.onNavySecondary))
                        Text(step.title)
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(step.isDone || step.isCurrent ? Color.white : PPColor.onNavySecondary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                    }
                    Group {
                        if step.isCurrent {
                            PPOvertimeFill()
                        } else if step.isDone {
                            doneColor
                        } else {
                            PPColor.onNavyFill
                        }
                    }
                    .frame(height: 4)
                    .clipShape(Capsule())
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityElement(children: .combine)
                .accessibilityValue(step.isDone ? "Done" : (step.isCurrent ? "Current step" : "Not started"))
            }
        }
    }
}

/// Initials in a coloured circle (person rows).
struct PPInitialsAvatar: View {
    let initials: String
    var family: PPFamily = .plan
    var size: CGFloat = 34

    var body: some View {
        Text(initials)
            .font(.system(size: size * 0.36, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(family.gradient, in: Circle())
            .accessibilityHidden(true)
    }
}
