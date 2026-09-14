//
//  HSComponents.swift
//  Project Planner — Health & Safety component library
//
//  DROP-IN FILE. Depends only on HSTheme.swift.
//  These are the ONLY building blocks the H&S screens should use.
//

import SwiftUI

// =====================================================================
// MARK: - 1. Section header
// =====================================================================

struct HSSectionHeader: View {
    let title: String
    var trailing: String? = nil
    var trailingAction: (() -> Void)? = nil

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title.uppercased())
                .font(HSFont.sectionLabel)
                .tracking(0.9)
                .foregroundStyle(HS.slate2)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
            Spacer(minLength: 8)
            if let trailing {
                Button {
                    HSHaptic.tap(); trailingAction?()
                } label: {
                    HStack(spacing: 3) {
                        Text(trailing).font(.system(size: 13, weight: .semibold))
                        Image(systemName: "chevron.right").font(.system(size: 10, weight: .bold))
                    }
                    .foregroundStyle(HS.blue)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.top, HSMetric.sectionGapTop)
        .padding(.bottom, HSMetric.sectionGapBot)
    }
}

// =====================================================================
// MARK: - 2. Status badge
// =====================================================================

struct HSBadge: View {
    enum Tone { case ok, warn, danger, info, brand, neutral, scheduled }
    let text: String
    var tone: Tone = .neutral
    var icon: String? = nil

    private var pair: (Color, Color) {
        switch tone {
        case .ok:        return (HS.green,  HS.greenBg)
        case .warn:      return (HS.amber,  HS.amberBg)
        case .danger:    return (HS.red,    HS.redBg)
        case .info:      return (HS.blue,   HS.blueBg)
        case .brand:     return (HS.teal,   HS.tealBg)
        case .scheduled: return (HS.violet, HS.violetBg)
        case .neutral:   return (HS.slate,  HS.neutralBg)
        }
    }

    var body: some View {
        HStack(spacing: 4) {
            if let icon {
                Image(systemName: icon).font(.system(size: 9, weight: .bold))
            }
            Text(text)
                .font(HSFont.badge)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
        }
        .foregroundStyle(pair.0)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(pair.1)
        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        .fixedSize()
    }
}

// =====================================================================
// MARK: - 3. Icon tile
// =====================================================================

struct HSIconTile: View {
    let systemName: String
    var tint: Color = HS.teal
    var size: CGFloat = 42

    var body: some View {
        RoundedRectangle(cornerRadius: HSMetric.tileRadius, style: .continuous)
            .fill(tint.opacity(0.12))
            .frame(width: size, height: size)
            .overlay(
                Image(systemName: systemName)
                    .font(.system(size: size * 0.42, weight: .semibold))
                    .foregroundStyle(tint)
            )
    }
}

// =====================================================================
// MARK: - 4. Buttons
// =====================================================================

struct HSFilledButton: ButtonStyle {
    enum Tone { case teal, blue, navy, danger }
    var tone: Tone = .teal
    var size: CGFloat = 15          // vertical padding
    var fullWidth: Bool = true

    func makeBody(configuration: Configuration) -> some View {
        let (grad, glow): (LinearGradient, Color) = {
            switch tone {
            case .teal:   return (HS.heroTeal, HS.teal)
            case .blue:   return (HS.heroBlue, HS.blue)
            case .navy:   return (HS.heroNavy, HS.navy)
            case .danger: return (LinearGradient(colors: [hsDyn("#EF6257", "#E0564B"), HS.red],
                                                 startPoint: .topLeading, endPoint: .bottomTrailing), HS.red)
            }
        }()
        return configuration.label
            .font(HSFont.button)
            .foregroundStyle(.white)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .frame(maxWidth: fullWidth ? .infinity : nil)
            .padding(.horizontal, fullWidth ? 16 : 22)
            .padding(.vertical, size)
            .background(grad)
            .clipShape(RoundedRectangle(cornerRadius: HSMetric.controlRadius + 1, style: .continuous))
            .shadow(color: glow.opacity(0.30), radius: 12, x: 0, y: 8)
            .scaleEffect(configuration.isPressed ? 0.975 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

struct HSGhostButton: ButtonStyle {
    var tint: Color = HS.teal
    var fullWidth: Bool = true

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 15, weight: .bold))
            .foregroundStyle(tint)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .frame(maxWidth: fullWidth ? .infinity : nil)
            .padding(.horizontal, fullWidth ? 16 : 20)
            .padding(.vertical, 13)
            .background(HS.card)
            .clipShape(RoundedRectangle(cornerRadius: HSMetric.controlRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: HSMetric.controlRadius, style: .continuous)
                    .strokeBorder(tint.opacity(0.22), lineWidth: 1)
            )
            .scaleEffect(configuration.isPressed ? 0.975 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

/// Compact action used INSIDE a card row. Never full width — this is what
/// stops the trailing button from crushing the title.
struct HSPillButton: ButtonStyle {
    enum Tone { case teal, blue, green, amber, neutral }
    var tone: Tone = .teal
    var icon: String? = nil

    func makeBody(configuration: Configuration) -> some View {
        let (fg, bg): (Color, Color) = {
            switch tone {
            case .teal:    return (HS.onAccent, HS.teal)
            case .blue:    return (HS.onAccent, HS.blue)
            case .green:   return (HS.onAccent, HS.green)
            case .amber:   return (HS.onAccent, HS.amber)
            case .neutral: return (HS.inkSoft, HS.neutralBg)
            }
        }()
        return HStack(spacing: 5) {
            if let icon { Image(systemName: icon).font(.system(size: 11, weight: .bold)) }
            configuration.label.font(HSFont.buttonSm)
        }
        .foregroundStyle(fg)
        .lineLimit(1)
        .fixedSize()
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(bg)
        .clipShape(Capsule())
        .scaleEffect(configuration.isPressed ? 0.95 : 1)
        .animation(.spring(response: 0.22, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

// =====================================================================
// MARK: - 5. Screen header (replaces the truncating large nav title)
// =====================================================================

/// Inline, two-line-safe header. NEVER use .navigationBarTitleDisplayMode(.large)
/// in H&S — that is what truncates "Health & Safet…" and "Sign-off trackin…".
struct HSNavBar<Trailing: View>: View {
    let title: String
    var subtitle: String? = nil
    var onBack: (() -> Void)? = nil
    var backSymbol: String = "chevron.left"
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 12) {
            if let onBack {
                Button {
                    HSHaptic.tap(); onBack()
                } label: {
                    Image(systemName: backSymbol)
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(HS.inkSoft)
                        .frame(width: 36, height: 36)
                        .background(HS.card)
                        .clipShape(Circle())
                        .overlay(Circle().strokeBorder(HS.line, lineWidth: 1))
                }
                .buttonStyle(.plain)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(HSFont.screenTitle)
                    .foregroundStyle(HS.ink)
                    .hsNoClip(1, minScale: 0.7)
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(HS.slate2)
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                }
            }
            Spacer(minLength: 4)
            trailing
        }
        .frame(minHeight: 44)
        .hsGutter()
        .padding(.top, 6)
        .padding(.bottom, 10)
    }
}

extension HSNavBar where Trailing == EmptyView {
    init(title: String,
         subtitle: String? = nil,
         onBack: (() -> Void)? = nil,
         backSymbol: String = "chevron.left") {
        self.init(title: title,
                  subtitle: subtitle,
                  onBack: onBack,
                  backSymbol: backSymbol,
                  trailing: { EmptyView() })
    }
}

// =====================================================================
// MARK: - 6. Context hero (project / small work banner)
// =====================================================================

struct HSContextHero: View {
    let title: String            // "BPR" / "Lancelot Place"
    let reference: String        // "C746"
    let kind: String             // "Project" / "Small Work"
    var progress: Double? = nil  // 0...1, optional
    var meta: String? = nil      // "RED Construction · Farnie Nel"

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(HSFont.heroTitle)
                        .foregroundStyle(.white)
                        .hsNoClip(2, minScale: 0.75)
                    HStack(spacing: 6) {
                        Text(reference)
                        Text("·")
                        Text(kind)
                    }
                    .font(HSFont.heroSub)
                    .foregroundStyle(.white.opacity(0.88))   // readable, not 0.4
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                }
                Spacer(minLength: 8)
                Image(systemName: "shield.lefthalf.filled")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.9))
                    .frame(width: 40, height: 40)
                    .background(.white.opacity(0.16))
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }

            if let meta {
                Text(meta)
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.78))
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            }

            if let progress {
                VStack(alignment: .leading, spacing: 6) {
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(.white.opacity(0.25))
                            Capsule().fill(.white)
                                .frame(width: max(6, geo.size.width * progress))
                        }
                    }
                    .frame(height: 6)
                    Text("\(Int(progress * 100))% complete")
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.9))
                }
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(HS.heroBlue)
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .shadow(color: HS.blue.opacity(0.30), radius: 18, x: 0, y: 10)
    }
}

// =====================================================================
// MARK: - 7. Scrolling segmented control (never truncates)
// =====================================================================

struct HSSegmented<T: Hashable>: View {
    struct Item: Identifiable {
        let id: T
        let title: String
        var icon: String? = nil
        var count: Int? = nil
    }

    let items: [Item]
    @Binding var selection: T
    var tint: Color = HS.teal

    @Namespace private var ns

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(items) { item in
                        let active = item.id == selection
                        Button {
                            HSHaptic.select()
                            withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) {
                                selection = item.id
                                proxy.scrollTo(item.id, anchor: .center)
                            }
                        } label: {
                            HStack(spacing: 6) {
                                if let icon = item.icon {
                                    Image(systemName: icon).font(.system(size: 12, weight: .semibold))
                                }
                                Text(item.title)
                                    .font(.system(size: 14.5, weight: .semibold))
                                    .lineLimit(1)
                                    .fixedSize()
                                if let c = item.count, c > 0 {
                                    Text("\(c)")
                                        .font(.system(size: 11, weight: .bold))
                                        .foregroundStyle(active ? tint : HS.onAccent)
                                        .padding(.horizontal, 6).padding(.vertical, 2)
                                        .background(active ? HS.onAccent : tint)
                                        .clipShape(Capsule())
                                }
                            }
                            .foregroundStyle(active ? HS.onAccent : HS.slate)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 10)
                            .background {
                                if active {
                                    Capsule().fill(tint)
                                        .matchedGeometryEffect(id: "seg", in: ns)
                                        .shadow(color: tint.opacity(0.32), radius: 10, y: 5)
                                } else {
                                    Capsule().fill(HS.card)
                                        .overlay(Capsule().strokeBorder(HS.line, lineWidth: 1))
                                }
                            }
                        }
                        .buttonStyle(.plain)
                        .id(item.id)
                    }
                }
                .padding(.horizontal, HSMetric.screenPad)
                .padding(.vertical, 4)
            }
        }
    }
}

// =====================================================================
// MARK: - 8. Stat tile
// =====================================================================

struct HSStatTile: View {
    let value: String
    let label: String
    var accent: Color = HS.ink
    var icon: String? = nil
    var tapped: (() -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                if let icon {
                    Image(systemName: icon)
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(accent)
                }
                Text(value)
                    .font(HSFont.stat)
                    .foregroundStyle(accent)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
            }
            Text(label)
                .font(HSFont.statLabel)
                .foregroundStyle(HS.slate)
                .hsNoClip(2, minScale: 0.9)
                .frame(minHeight: 32, alignment: .top)   // reserves 2 lines so tiles align
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .hsCard(padding: 14, radius: 16)
        .contentShape(Rectangle())
        .onTapGesture { if let tapped { HSHaptic.tap(); tapped() } }
    }
}

// =====================================================================
// MARK: - 9. Toolbox talk card (Hub — "My toolbox talks" / "Assigned to me")
//
//  This layout is the fix for "Safe Isolation P…" wrapping over three lines.
//  Title gets the FULL card width. Action lives on its own row underneath.
// =====================================================================

struct HSTalkCard: View {
    let title: String
    let reference: String?        // "TBT-ELE-001"
    let trade: String?            // "Electrical"
    let weekCommencing: String?   // "W/C 20 Jun 2026"
    let status: Status
    var signedProgress: (signed: Int, total: Int)? = nil
    var primaryTitle: String
    var primaryTone: HSPillButton.Tone
    var primaryAction: () -> Void
    var secondaryTitle: String? = nil
    var secondaryAction: (() -> Void)? = nil
    var onOpen: (() -> Void)? = nil

    enum Status {
        case signed, awaiting, overdue, scheduled, draft
        var badge: (String, HSBadge.Tone, String) {
            switch self {
            case .signed:    return ("Signed",    .ok,        "checkmark.seal.fill")
            case .awaiting:  return ("Awaiting",  .warn,      "clock.fill")
            case .overdue:   return ("Overdue",   .danger,    "exclamationmark.triangle.fill")
            case .scheduled: return ("Scheduled", .scheduled, "calendar")
            case .draft:     return ("Draft",     .neutral,   "pencil")
            }
        }
        var tint: Color {
            switch self {
            case .signed: return HS.green
            case .awaiting: return HS.amber
            case .overdue: return HS.red
            case .scheduled: return HS.violet
            case .draft: return HS.slate
            }
        }
        var icon: String {
            switch self {
            case .signed: return "checkmark.seal.fill"
            case .awaiting: return "doc.text.fill"
            case .overdue: return "exclamationmark.triangle.fill"
            case .scheduled: return "calendar.badge.clock"
            case .draft: return "pencil.and.outline"
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {

            // Row 1 — icon + title block + badge. Title spans the card.
            HStack(alignment: .top, spacing: 12) {
                HSIconTile(systemName: status.icon, tint: status.tint, size: 40)

                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(HSFont.cardTitle)
                        .foregroundStyle(HS.ink)
                        .hsNoClip(2)                       // full width, 2 lines, no ellipsis
                    if let weekCommencing {
                        Text(weekCommencing)
                            .font(HSFont.meta)
                            .foregroundStyle(HS.slate2)
                            .lineLimit(1)
                            .minimumScaleFactor(0.85)
                    }
                }
                Spacer(minLength: 6)
                HSBadge(text: status.badge.0, tone: status.badge.1, icon: status.badge.2)
            }

            // Row 2 — reference / trade chips
            if reference != nil || trade != nil {
                HStack(spacing: 6) {
                    if let reference { HSBadge(text: reference, tone: .neutral) }
                    if let trade { HSBadge(text: trade, tone: .info) }
                    Spacer(minLength: 0)
                }
            }

            // Row 3 — sign-off progress
            if let p = signedProgress, p.total > 0 {
                VStack(alignment: .leading, spacing: 5) {
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(HS.neutralBg)
                            Capsule().fill(p.signed == p.total ? HS.green : HS.amber)
                                .frame(width: max(4, geo.size.width * (Double(p.signed) / Double(p.total))))
                        }
                    }
                    .frame(height: 5)
                    Text("\(p.signed) of \(p.total) operatives signed")
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(p.signed == p.total ? HS.green : HS.amber)
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                }
            }

            // Row 4 — actions, right aligned, compact pills
            HStack(spacing: 8) {
                Spacer(minLength: 0)
                if let secondaryTitle, let secondaryAction {
                    Button(secondaryTitle) { HSHaptic.tap(); secondaryAction() }
                        .buttonStyle(HSPillButton(tone: .neutral))
                }
                Button(primaryTitle) { HSHaptic.tap(); primaryAction() }
                    .buttonStyle(HSPillButton(tone: primaryTone))
            }
        }
        .hsCard()
        .contentShape(RoundedRectangle(cornerRadius: HSMetric.cardRadius, style: .continuous))
        .onTapGesture { if let onOpen { HSHaptic.tap(); onOpen() } }
    }
}

// =====================================================================
// MARK: - 10. Library row
// =====================================================================

struct HSLibraryRow: View {
    let title: String
    let reference: String
    let purpose: String
    let trade: String
    var approved: Bool = true
    var isCustom: Bool = false
    var onOpen: () -> Void
    var onIssue: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack(alignment: .top, spacing: 12) {
                HSIconTile(systemName: isCustom ? "arrow.up.doc.fill" : "doc.text.fill",
                           tint: isCustom ? HS.violet : HS.teal, size: 42)

                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(HSFont.cardTitle)
                        .foregroundStyle(HS.ink)
                        .hsNoClip(2)
                    Text(purpose)
                        .font(.system(size: 12.5))
                        .foregroundStyle(HS.slate)
                        .hsNoClip(2, minScale: 1.0)
                }
                Spacer(minLength: 6)
                HSBadge(text: approved ? "Approved" : "Draft",
                        tone: approved ? .ok : .warn,
                        icon: approved ? "checkmark.circle.fill" : "pencil")
            }

            HStack(spacing: 6) {
                HSBadge(text: reference, tone: .neutral)
                HSBadge(text: trade, tone: .info)
                if isCustom { HSBadge(text: "Your upload", tone: .scheduled) }
                Spacer(minLength: 4)
                Button("Issue") { HSHaptic.tap(); onIssue() }
                    .buttonStyle(HSPillButton(tone: .teal, icon: "paperplane.fill"))
            }
        }
        .hsCard(padding: 14)
        .contentShape(RoundedRectangle(cornerRadius: HSMetric.cardRadius, style: .continuous))
        .onTapGesture { HSHaptic.tap(); onOpen() }
    }
}

// =====================================================================
// MARK: - 11. Quick action row
// =====================================================================

struct HSActionRow: View {
    let icon: String
    let tint: Color
    let title: String
    let subtitle: String
    var badge: String? = nil
    var action: () -> Void

    var body: some View {
        Button { HSHaptic.tap(); action() } label: {
            HStack(spacing: 13) {
                HSIconTile(systemName: icon, tint: tint, size: 42)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.system(size: 15.5, weight: .semibold))
                        .foregroundStyle(HS.ink)
                        .hsNoClip(1, minScale: 0.85)
                    Text(subtitle)
                        .font(.system(size: 12.5))
                        .foregroundStyle(HS.slate)
                        .hsNoClip(2, minScale: 1.0)
                }
                Spacer(minLength: 6)
                if let badge { HSBadge(text: badge, tone: .warn) }
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(HS.slate2.opacity(0.7))
            }
            .hsCard(padding: 14)
        }
        .buttonStyle(HSPressStyle())
    }
}

/// Subtle press feedback for whole-card buttons.
struct HSPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
            .opacity(configuration.isPressed ? 0.92 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.75), value: configuration.isPressed)
    }
}

// =====================================================================
// MARK: - 12. Sign-off hero (teal progress card)
// =====================================================================

struct HSSignOffHero: View {
    let signed: Int
    let total: Int
    var talkTitle: String? = nil

    private var pct: Int { total == 0 ? 0 : Int((Double(signed) / Double(total)) * 100) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let talkTitle {
                Text(talkTitle)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.92))
                    .hsNoClip(2, minScale: 0.85)
            }
            HStack(alignment: .bottom) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("SIGN-OFF PROGRESS")
                        .font(.system(size: 11, weight: .bold)).tracking(0.9)
                        .foregroundStyle(.white.opacity(0.88))
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                    Text("\(pct)%")
                        .font(.system(size: 42, weight: .heavy))
                        .foregroundStyle(.white)
                        .lineLimit(1).minimumScaleFactor(0.6)
                }
                Spacer(minLength: 8)
                VStack(alignment: .trailing, spacing: 1) {
                    Text("\(signed)/\(total)")
                        .font(.system(size: 24, weight: .heavy))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                    Text("signed")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white.opacity(0.88))
                }
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.26))
                    Capsule().fill(.white)
                        .frame(width: max(6, geo.size.width * (total == 0 ? 0 : Double(signed) / Double(total))))
                }
            }
            .frame(height: 8)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(HS.heroTeal)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .shadow(color: HS.teal.opacity(0.30), radius: 16, x: 0, y: 9)
    }
}

// =====================================================================
// MARK: - 13. Operative row (recipients + sign-off list)
// =====================================================================

struct HSOperativeRow: View {
    let name: String
    let trade: String
    var detail: String? = nil          // "Signed 14 Sep, 08:12"
    var state: State = .plain
    var selected: Bool = false
    var onTap: (() -> Void)? = nil

    enum State { case plain, signed, pending, selectable }

    private var initials: String {
        name.split(separator: " ").prefix(2).compactMap { $0.first.map(String.init) }.joined().uppercased()
    }

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle().fill(selected ? HS.teal : HS.neutralBg)
                Text(initials)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(selected ? HS.onAccent : HS.slate)
            }
            .frame(width: 40, height: 40)

            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(HS.ink)
                    .hsNoClip(1, minScale: 0.85)
                Text(detail ?? trade)
                    .font(.system(size: 12.5))
                    .foregroundStyle(HS.slate)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            }
            Spacer(minLength: 6)

            switch state {
            case .signed:
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 21))
                    .foregroundStyle(HS.green)
            case .pending:
                HSBadge(text: "Pending", tone: .warn, icon: "clock.fill")
            case .selectable:
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 21))
                    .foregroundStyle(selected ? HS.teal : HS.slate2.opacity(0.5))
            case .plain:
                EmptyView()
            }
        }
        .padding(.vertical, 11)
        .padding(.horizontal, 14)
        .contentShape(Rectangle())
        .onTapGesture { if let onTap { HSHaptic.select(); onTap() } }
    }
}

/// Groups operative rows into one card with hairline dividers.
struct HSRowGroup<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        VStack(spacing: 0) { content }
            .background(HS.card)
            .clipShape(RoundedRectangle(cornerRadius: HSMetric.cardRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: HSMetric.cardRadius, style: .continuous)
                    .strokeBorder(HS.line, lineWidth: 1)
            )
            .shadow(color: HS.shadowStrong, radius: 14, x: 0, y: 6)
    }
}

struct HSDivider: View {
    var inset: CGFloat = 66
    var body: some View {
        Rectangle().fill(HS.line).frame(height: 1).padding(.leading, inset)
    }
}

// =====================================================================
// MARK: - 14. Search field
// =====================================================================

struct HSSearchField: View {
    let placeholder: String
    @Binding var text: String

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(HS.slate2)
            TextField(placeholder, text: $text)
                .font(.system(size: 15))
                .foregroundStyle(HS.ink)
                .autocorrectionDisabled()
                .submitLabel(.search)
            if !text.isEmpty {
                Button {
                    HSHaptic.tap(); text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 15))
                        .foregroundStyle(HS.slate2)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(HS.card)
        .clipShape(RoundedRectangle(cornerRadius: HSMetric.controlRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: HSMetric.controlRadius, style: .continuous)
                .strokeBorder(HS.line, lineWidth: 1)
        )
    }
}

// =====================================================================
// MARK: - 15. Filter chips (trade filters)
// =====================================================================

struct HSChipRow<T: Hashable>: View {
    struct Chip: Identifiable {
        let id: T
        let title: String
        var count: Int? = nil
    }
    let chips: [Chip]
    @Binding var selection: T
    var tint: Color = HS.teal

    var body: some View {
        // Overlay keeps this row the width of the parent. A bare horizontal
        // ScrollView inside a vertical ScrollView otherwise expands the page
        // to fit every chip (All / General / My uploads were stretching H&S).
        Color.clear
            .frame(height: 40)
            .frame(maxWidth: .infinity)
            .overlay(alignment: .leading) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(chips) { chip in
                            let active = chip.id == selection
                            Button {
                                HSHaptic.select()
                                withAnimation(.easeOut(duration: 0.18)) { selection = chip.id }
                            } label: {
                                HStack(spacing: 5) {
                                    Text(chip.title)
                                        .font(.system(size: 13.5, weight: .semibold))
                                        .lineLimit(1)
                                        .fixedSize()
                                    if let c = chip.count {
                                        Text("\(c)").font(.system(size: 11, weight: .bold))
                                            .opacity(0.75)
                                    }
                                }
                                .foregroundStyle(active ? HS.onAccent : HS.slate)
                                .padding(.horizontal, 13).padding(.vertical, 8)
                                .background(active ? tint : HS.card)
                                .clipShape(Capsule())
                                .overlay(Capsule().strokeBorder(active ? .clear : HS.line, lineWidth: 1))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.vertical, 3)
                }
            }
    }
}

// =====================================================================
// MARK: - 16. Empty state
// =====================================================================

struct HSEmptyState: View {
    let icon: String
    let title: String
    let message: String
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: 12) {
            HSIconTile(systemName: icon, tint: HS.slate2, size: 54)
            Text(title)
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(HS.ink)
                .multilineTextAlignment(.center)
            Text(message)
                .font(.system(size: 13.5))
                .foregroundStyle(HS.slate)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            if let actionTitle, let action {
                Button(actionTitle) { HSHaptic.tap(); action() }
                    .buttonStyle(HSGhostButton(fullWidth: false))
                    .padding(.top, 2)
            }
        }
        .padding(.vertical, 28)
        .padding(.horizontal, 22)
        .frame(maxWidth: .infinity)
        .hsCard(padding: 0)
    }
}

// =====================================================================
// MARK: - 17. Sticky bottom action bar
// =====================================================================

struct HSBottomBar<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        VStack(spacing: 0) {
            Rectangle().fill(HS.line).frame(height: 1)
            content
                .padding(.horizontal, HSMetric.screenPad)
                .padding(.top, 12)
                .padding(.bottom, 8)
        }
        .background(.ultraThinMaterial)
    }
}

// =====================================================================
// MARK: - 18. Signature pad
// =====================================================================

struct HSStrokeSignaturePad: View {
    @Binding var strokes: [[CGPoint]]
    @State private var current: [CGPoint] = []

    var isEmpty: Bool { strokes.isEmpty && current.isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("SIGNATURE")
                    .font(HSFont.sectionLabel).tracking(0.9)
                    .foregroundStyle(HS.slate2)
                Spacer()
                Button {
                    HSHaptic.tap()
                    withAnimation(.easeOut(duration: 0.2)) { strokes = []; current = [] }
                } label: {
                    Text("Clear").font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(isEmpty ? HS.slate2.opacity(0.5) : HS.red)
                }
                .buttonStyle(.plain)
                .disabled(isEmpty)
            }

            ZStack {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(HS.bgDeep.opacity(0.6))
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [6, 5]))
                    .foregroundStyle(isEmpty ? HS.slate2.opacity(0.45) : HS.teal.opacity(0.5))

                if isEmpty {
                    VStack(spacing: 6) {
                        Image(systemName: "signature")
                            .font(.system(size: 22))
                            .foregroundStyle(HS.slate2.opacity(0.7))
                        Text("Sign with your finger")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(HS.slate2)
                    }
                }

                // The stroke uses HS.ink so it stays legible in dark mode too.
                // NOTE for the PDF renderer: it draws from the stored points, so
                // render the signature in a FIXED dark ink there — never HS.ink —
                // or a signature captured in dark mode comes out white on paper.
                Canvas { ctx, _ in
                    for s in strokes + [current] where s.count > 1 {
                        var p = Path()
                        p.addLines(s)
                        ctx.stroke(p, with: .color(HS.ink),
                                   style: StrokeStyle(lineWidth: 2.4, lineCap: .round, lineJoin: .round))
                    }
                }

                // Baseline
                VStack {
                    Spacer()
                    Rectangle().fill(HS.slate2.opacity(0.25))
                        .frame(height: 1)
                        .padding(.horizontal, 22)
                        .padding(.bottom, 22)
                }
            }
            .frame(height: 170)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { current.append($0.location) }
                    .onEnded { _ in
                        if current.count > 1 { strokes.append(current) }
                        current = []
                        HSHaptic.tap()
                    }
            )
        }
        .hsCard()
    }
}
