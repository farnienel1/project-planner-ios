//
//  SiteAuditDesignSystem.swift
//  Project Planner
//
//  Visual tokens and reusable UI from site_audit_full_flow.html
//

import SwiftUI

enum SiteAuditColors {
    static let pageBackground = Color(red: 0.969, green: 0.973, blue: 0.980) // #F7F8FA
    static let card = Color.white
    static let text = Color(red: 0.043, green: 0.063, blue: 0.125) // #0B1020
    static let textSecondary = Color(red: 0.420, green: 0.447, blue: 0.502) // #6B7280
    static let textDisabled = Color(red: 0.773, green: 0.788, blue: 0.824) // #C5C9D2
    static let border = Color(red: 0.933, green: 0.941, blue: 0.953) // #EEF0F3
    static let borderStrong = Color(red: 0.898, green: 0.906, blue: 0.922) // #E5E7EB
    static let primary = Color(red: 0.094, green: 0.373, blue: 0.647) // #185FA5
    static let primaryTint = Color(red: 0.902, green: 0.945, blue: 0.984) // #E6F1FB
    static let success = Color(red: 0.059, green: 0.431, blue: 0.337) // #0F6E56
    static let successTint = Color(red: 0.882, green: 0.961, blue: 0.933) // #E1F5EE
    static let warn = Color(red: 0.522, green: 0.310, blue: 0.043) // #854F0B
    static let warnTint = Color(red: 0.980, green: 0.933, blue: 0.855) // #FAEEDA
    static let danger = Color(red: 0.639, green: 0.176, blue: 0.176) // #A32D2D
    static let dangerTint = Color(red: 0.988, green: 0.922, blue: 0.922) // #FCEBEB
    static let purple = Color(red: 0.325, green: 0.290, blue: 0.718) // #534AB7
    static let purpleTint = Color(red: 0.933, green: 0.929, blue: 0.996) // #EEEDFE
    static let pink = Color(red: 0.600, green: 0.208, blue: 0.337) // #993556
    static let pinkTint = Color(red: 0.984, green: 0.918, blue: 0.941) // #FBEAF0
    static let headerGradientStart = Color(red: 0.043, green: 0.063, blue: 0.125)
    static let headerGradientEnd = Color(red: 0.102, green: 0.141, blue: 0.278)
    static let heroGradientStart = Color(red: 0.094, green: 0.373, blue: 0.647)
    static let heroGradientEnd = Color(red: 0.216, green: 0.541, blue: 0.867)
}

enum SiteAuditTypeStyle {
    case preStart, general, variations, snags

    static func forType(_ type: SiteAuditType) -> SiteAuditTypeStyle {
        switch type {
        case .preStart: return .preStart
        case .general: return .general
        case .variations: return .variations
        case .snags: return .snags
        }
    }

    var accent: Color {
        switch self {
        case .preStart: return SiteAuditColors.warn
        case .general: return SiteAuditColors.primary
        case .variations: return SiteAuditColors.purple
        case .snags: return SiteAuditColors.danger
        }
    }

    var tint: Color {
        switch self {
        case .preStart: return SiteAuditColors.warnTint
        case .general: return SiteAuditColors.primaryTint
        case .variations: return SiteAuditColors.purpleTint
        case .snags: return SiteAuditColors.dangerTint
        }
    }

    var icon: String {
        switch self {
        case .preStart: return "checkmark.seal.fill"
        case .general: return "doc.text.fill"
        case .variations: return "book.fill"
        case .snags: return "exclamationmark.triangle.fill"
        }
    }

    var subtitle: String {
        switch self {
        case .preStart: return "Site state before work begins"
        case .general: return "Ad-hoc walkthrough"
        case .variations: return "Changes from spec"
        case .snags: return "Defects to fix"
        }
    }

    var pillLabel: String {
        switch self {
        case .preStart: return "Pre-Start"
        case .general: return "General"
        case .variations: return "Variations"
        case .snags: return "Snags"
        }
    }
}

struct SiteAuditPill: View {
    enum Style { case amber, blue, green, grey, red, purple, draft }

    let text: String
    var style: Style = .blue

    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(foreground)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(background)
            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
    }

    private var foreground: Color {
        switch style {
        case .amber: return SiteAuditColors.warn
        case .blue: return SiteAuditColors.primary
        case .green: return SiteAuditColors.success
        case .grey: return SiteAuditColors.textSecondary
        case .red: return SiteAuditColors.danger
        case .purple: return SiteAuditColors.purple
        case .draft: return SiteAuditColors.primary
        }
    }

    private var background: Color {
        switch style {
        case .amber: return SiteAuditColors.warnTint
        case .blue: return SiteAuditColors.primaryTint
        case .green: return SiteAuditColors.successTint
        case .grey: return Color(red: 0.949, green: 0.953, blue: 0.961)
        case .red: return SiteAuditColors.dangerTint
        case .purple: return SiteAuditColors.purpleTint
        case .draft: return SiteAuditColors.primaryTint
        }
    }
}

struct SiteAuditIconCircleButton: View {
    let systemName: String
    var primary = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: primary ? 16 : 17, weight: .medium))
                .foregroundStyle(primary ? Color.white : SiteAuditColors.text)
                .frame(width: 34, height: 34)
                .background(primary ? SiteAuditColors.primary : Color.white)
                .clipShape(Circle())
                .overlay(
                    Circle()
                        .strokeBorder(primary ? Color.clear : SiteAuditColors.borderStrong, lineWidth: 0.5)
                )
        }
        .buttonStyle(.plain)
    }
}

struct SiteAuditToolbarPill: View {
    let title: String
    var filled = false
    var disabled = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(disabled ? SiteAuditColors.textDisabled : (filled ? .white : SiteAuditColors.text))
                .padding(.horizontal, filled ? 14 : 12)
                .padding(.vertical, 6)
                .background {
                    if filled {
                        Capsule().fill(disabled ? SiteAuditColors.textDisabled : SiteAuditColors.primary)
                    } else {
                        Capsule()
                            .fill(Color.white)
                            .overlay(Capsule().strokeBorder(SiteAuditColors.borderStrong, lineWidth: 0.5))
                    }
                }
        }
        .buttonStyle(.plain)
        .disabled(disabled)
    }
}

struct SiteAuditSectionLabel: View {
    let title: String
    var suffix: String?

    var body: some View {
        HStack(spacing: 0) {
            Text(title.uppercased())
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(SiteAuditColors.textSecondary)
                .tracking(0.4)
            if let suffix {
                Text(" \(suffix)")
                    .font(.system(size: 11, weight: .regular))
                    .foregroundStyle(SiteAuditColors.textDisabled)
                    .textCase(nil)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.leading, 4)
        .padding(.bottom, 7)
    }
}

struct SiteAuditCard<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        content
            .background(SiteAuditColors.card)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(SiteAuditColors.border, lineWidth: 0.5)
            )
    }
}

/// Keeps large camera-roll photos inside explicit bounds so ScrollViews do not expand off-screen.
struct SiteAuditBoundedImage: View {
    let image: UIImage
    var aspectRatio: CGFloat = 4 / 3
    var cornerRadius: CGFloat = 14

    var body: some View {
        Color.clear
            .aspectRatio(aspectRatio, contentMode: .fit)
            .frame(maxWidth: .infinity)
            .overlay {
                GeometryReader { proxy in
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: proxy.size.width, height: proxy.size.height)
                        .clipped()
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }
}

struct SiteAuditBoundedThumbnail: View {
    let image: UIImage
    var size: CGFloat = 56
    var cornerRadius: CGFloat = 10

    var body: some View {
        Image(uiImage: image)
            .resizable()
            .scaledToFill()
            .frame(width: size, height: size)
            .clipped()
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }
}

struct SiteAuditProjectHero: View {
    let auditCount: Int
    let photoCount: Int
    let lastSubmittedLine: String?

    var body: some View {
        ZStack(alignment: .topTrailing) {
            LinearGradient(
                colors: [SiteAuditColors.heroGradientStart, SiteAuditColors.heroGradientEnd],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            Circle()
                .fill(
                    RadialGradient(
                        colors: [Color.white.opacity(0.12), Color.clear],
                        center: .center,
                        startRadius: 0,
                        endRadius: 60
                    )
                )
                .frame(width: 120, height: 120)
                .offset(x: 30, y: -30)

            VStack(alignment: .leading, spacing: 6) {
                Text("This project")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.85))
                    .textCase(.uppercase)
                    .tracking(0.3)
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text("\(auditCount)")
                        .font(.system(size: 22, weight: .medium))
                    Text("audits · \(photoCount) photos")
                        .font(.system(size: 12, weight: .regular))
                        .opacity(0.85)
                }
                .foregroundStyle(.white)
                if let lastSubmittedLine {
                    Text(lastSubmittedLine)
                        .font(.system(size: 11))
                        .foregroundStyle(Color.white.opacity(0.85))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
        }
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

struct SiteAuditFilterChipsRow: View {
    let chips: [(label: String, count: Int?)]
    @Binding var selectedIndex: Int

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(Array(chips.enumerated()), id: \.offset) { index, chip in
                    let selected = index == selectedIndex
                    Button {
                        selectedIndex = index
                    } label: {
                        Text(chip.count.map { "\(chip.label) · \($0)" } ?? chip.label)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(selected ? Color.white : SiteAuditColors.textSecondary)
                            .padding(.horizontal, 11)
                            .padding(.vertical, 5)
                            .background(selected ? SiteAuditColors.primary : Color.white)
                            .clipShape(Capsule())
                            .overlay(
                                Capsule()
                                    .strokeBorder(SiteAuditColors.borderStrong, lineWidth: selected ? 0 : 0.5)
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.bottom, 2)
        }
    }
}

struct SiteAuditTypePickerGrid: View {
    @Binding var selected: SiteAuditType

    var body: some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 7) {
            ForEach(SiteAuditType.allCases) { type in
                let style = SiteAuditTypeStyle.forType(type)
                let isSelected = selected == type
                Button {
                    selected = type
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Image(systemName: style.icon)
                            .font(.system(size: 16))
                            .foregroundStyle(isSelected ? style.accent : style.accent.opacity(0.9))
                        Text(type.rawValue)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(isSelected ? style.accent : SiteAuditColors.text)
                        Text(style.subtitle)
                            .font(.system(size: 9))
                            .foregroundStyle(isSelected ? style.accent.opacity(0.75) : SiteAuditColors.textSecondary)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(isSelected ? style.tint : SiteAuditColors.card)
                    .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 11, style: .continuous)
                            .strokeBorder(isSelected ? style.accent : SiteAuditColors.borderStrong, lineWidth: isSelected ? 1.5 : 0.5)
                    )
                }
                .buttonStyle(.plain)
            }
        }
    }
}

struct SiteAuditPrimaryButton: View {
    let title: String
    var systemImage: String?
    var style: Style = .primary
    var disabled = false
    let action: () -> Void

    enum Style { case primary, success, outline, dashed, secondary, greyFilled }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: 13, weight: .medium))
                }
                Text(title)
                    .font(.system(size: style == .secondary ? 12 : 13, weight: .medium))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, style == .secondary ? 10 : 11)
            .foregroundStyle(foreground)
            .background(background)
            .clipShape(RoundedRectangle(cornerRadius: style == .secondary ? 11 : 12, style: .continuous))
            .overlay {
                if style == .outline {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(SiteAuditColors.primary, lineWidth: 1)
                } else if style == .dashed {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(SiteAuditColors.textDisabled, style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
                } else if style == .secondary {
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .strokeBorder(SiteAuditColors.border, lineWidth: 0.5)
                }
            }
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .opacity(disabled ? 0.55 : 1)
    }

    private var foreground: Color {
        switch style {
        case .primary, .success: return .white
        case .outline, .dashed: return SiteAuditColors.primary
        case .secondary: return SiteAuditColors.textSecondary
        case .greyFilled: return .white
        }
    }

    @ViewBuilder
    private var background: some View {
        switch style {
        case .primary: SiteAuditColors.primary
        case .success: SiteAuditColors.success
        case .outline, .dashed: Color.white
        case .secondary: SiteAuditColors.pageBackground
        case .greyFilled: SiteAuditColors.textSecondary
        }
    }
}

struct SiteAuditRowIconChip: View {
    let systemName: String
    let tint: Color
    let background: Color
    var size: CGFloat = 30

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: size * 0.5))
            .foregroundStyle(tint)
            .frame(width: size, height: size)
            .background(background)
            .clipShape(RoundedRectangle(cornerRadius: size * 0.3, style: .continuous))
    }
}

extension View {
    func siteAuditScreenBackground() -> some View {
        background(SiteAuditColors.pageBackground.ignoresSafeArea())
    }
}
