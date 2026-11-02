//
//  SiteAuditDesignSystem.swift
//  Project Planner
//
//  Visual tokens and reusable UI from site_audit_full_flow.html
//

import SwiftUI

enum SiteAuditColors {
    // UI surfaces and text follow the app's PP (Midnight) look. None of these tokens are
    // used by SiteAuditPDFBuilder, which draws with its own UIColors, so the PDF is unchanged.
    static let pageBackground = PPColor.page
    static let card = PPColor.card
    static let text = Color.primary
    static let textSecondary = Color.secondary
    static let textDisabled = Color(.tertiaryLabel)
    static let border = Color(.separator)
    static let borderStrong = Color(.separator)
    static let primary = PPColor.brand
    static let primaryTint = AppAdaptiveColor.dynamic(
        light: AppAdaptiveColor.rgb(0.902, 0.945, 0.984),
        dark: AppAdaptiveColor.rgb(0.110, 0.173, 0.247)
    )
    static let success = ProjectWorksRevampColors.activeGreen
    static let successTint = AppAdaptiveColor.dynamic(
        light: AppAdaptiveColor.rgb(0.882, 0.961, 0.933),
        dark: AppAdaptiveColor.rgb(0.090, 0.220, 0.165)
    )
    static let warn = ProjectWorksRevampColors.upcomingAmber
    static let warnTint = AppAdaptiveColor.dynamic(
        light: AppAdaptiveColor.rgb(0.980, 0.933, 0.855),
        dark: AppAdaptiveColor.rgb(0.239, 0.180, 0.090)
    )
    static let danger = ProjectWorksRevampColors.requiredPillFg
    static let dangerTint = ProjectWorksRevampColors.requiredPillBg
    static let purple = ProjectWorksRevampColors.jobTypePillInk
    static let purpleTint = ProjectWorksRevampColors.jobTypePillBg
    static let pink = ProjectWorksRevampColors.pinRoseFg
    static let pinkTint = ProjectWorksRevampColors.pinRoseBg
    static let headerGradientStart = Color(red: 0.043, green: 0.063, blue: 0.125)
    static let headerGradientEnd = Color(red: 0.102, green: 0.141, blue: 0.278)
    static let heroGradientStart = ProjectWorksRevampColors.blue
    static let heroGradientEnd = ProjectWorksRevampColors.blueLight
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
            .font(.caption2.weight(.semibold))
            .foregroundStyle(foreground)
            .lineLimit(1)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(background)
            .clipShape(Capsule())
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
        case .grey: return PPColor.well
        case .red: return SiteAuditColors.dangerTint
        case .purple: return SiteAuditColors.purpleTint
        case .draft: return SiteAuditColors.primaryTint
        }
    }
}

struct SiteAuditIconCircleButton: View {
    let systemName: String
    var primary = false
    /// True when the button sits in a navy (`ppNavyNavigationBar`) toolbar. Look only.
    var onNavy = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            label
        }
        .accessibilityIdentifier("siteAuditIconCircle.\(AccessibilityID.token(systemName))")
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var label: some View {
        if onNavy {
            Image(systemName: systemName)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Color.white)
                .frame(width: 36, height: 36)
                .background(Circle().fill(primary ? PPColor.brand : PPColor.onNavyFill))
                .overlay(Circle().strokeBorder(Color.white.opacity(0.22), lineWidth: 0.5))
                .contentShape(Circle())
        } else {
            Image(systemName: systemName)
                .font(.system(size: primary ? 16 : 17, weight: .medium))
                .foregroundStyle(primary ? Color.white : SiteAuditColors.text)
                .frame(width: 34, height: 34)
                .background(primary ? SiteAuditColors.primary : PPColor.card)
                .clipShape(Circle())
                .overlay(
                    Circle()
                        .strokeBorder(primary ? Color.clear : SiteAuditColors.borderStrong, lineWidth: 0.5)
                )
        }
    }
}

struct SiteAuditToolbarPill: View {
    let title: String
    var filled = false
    var disabled = false
    /// True when the pill sits in a navy (`ppNavyNavigationBar`) toolbar. Look only.
    var onNavy = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            if onNavy {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.white.opacity(disabled ? 0.45 : 1))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7)
                    .background {
                        if filled {
                            Capsule().fill(disabled ? PPColor.onNavyFill : PPColor.brand)
                        } else {
                            Capsule()
                                .fill(PPColor.onNavyFill)
                                .overlay(Capsule().strokeBorder(PPColor.onNavyStroke, lineWidth: 0.5))
                        }
                    }
            } else {
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
                                .fill(SiteAuditColors.card)
                                .overlay(Capsule().strokeBorder(SiteAuditColors.borderStrong, lineWidth: 0.5))
                        }
                    }
            }
        }
        .accessibilityIdentifier("siteAuditToolbarPill.\(AccessibilityID.token(title))")
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
                .font(.footnote.weight(.semibold))
                .foregroundStyle(SiteAuditColors.textSecondary)
                .tracking(0.8)
            if let suffix {
                Text(" \(suffix)")
                    .font(.footnote)
                    .foregroundStyle(SiteAuditColors.textDisabled)
                    .textCase(nil)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.leading, 4)
        .padding(.top, 6)
        .padding(.bottom, 2)
    }
}

struct SiteAuditCard<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        content
            .background(SiteAuditColors.card)
            .clipShape(RoundedRectangle(cornerRadius: PPMetrics.rowCardRadius, style: .continuous))
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

/// Navy header for a project's audit list: job number, site name and the audit and photo
/// counts the list already computes. Drawn with Home's navy backdrop (`ppNavyHeader`).
struct SiteAuditProjectHero: View {
    var jobNumber: String = ""
    var siteName: String = ""
    let auditCount: Int
    let photoCount: Int
    let lastSubmittedLine: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PPNavyPageTitle(
                eyebrow: "This project",
                title: jobNumber,
                subtitle: siteName
            )
            HStack(alignment: .top, spacing: 12) {
                PPStat(value: "\(auditCount)", label: "Audits")
                PPStatDivider()
                PPStat(value: "\(photoCount)", label: "Photos")
            }
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, 16)
            if let lastSubmittedLine {
                Label(lastSubmittedLine, systemImage: "clock")
                    .font(.footnote)
                    .foregroundStyle(PPColor.onNavySecondary)
                    .lineLimit(2)
                    .padding(.top, 14)
            }
        }
        .padding(.horizontal, PPMetrics.screenGutter)
        .padding(.top, 12)
        .padding(.bottom, PPMetrics.headerBottomPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .ppNavyHeader()
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
                            .font(.subheadline.weight(.semibold))
                            .monospacedDigit()
                            .foregroundStyle(selected ? Color.white : Color.primary)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .background(selected ? PPColor.brand : PPColor.card)
                            .clipShape(Capsule())
                            .overlay(
                                Capsule()
                                    .strokeBorder(Color(.separator), lineWidth: selected ? 0 : 0.5)
                            )
                    }
                    .accessibilityIdentifier("siteAuditFilterChips.row.\(index)")
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
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
            ForEach(SiteAuditType.allCases) { type in
                let style = SiteAuditTypeStyle.forType(type)
                let isSelected = selected == type
                Button {
                    selected = type
                } label: {
                    VStack(alignment: .leading, spacing: 6) {
                        SiteAuditRowIconChip(systemName: style.icon, tint: style.accent, background: style.tint, size: PPMetrics.menuIcon)
                        Text(type.rawValue)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(isSelected ? style.accent : SiteAuditColors.text)
                        Text(style.subtitle)
                            .font(.caption)
                            .foregroundStyle(isSelected ? style.accent.opacity(0.8) : SiteAuditColors.textSecondary)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .background(isSelected ? style.tint : SiteAuditColors.card)
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .strokeBorder(isSelected ? style.accent : Color.clear, lineWidth: 1.5)
                    )
                }
                .accessibilityIdentifier("siteAuditTypePickerGrid.row.\(type.id)")
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
                        .font(.subheadline.weight(.semibold))
                }
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 13)
            .foregroundStyle(foreground)
            .background(background)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay {
                if style == .outline {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(SiteAuditColors.primary, lineWidth: 1)
                } else if style == .dashed {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(SiteAuditColors.textDisabled, style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
                }
            }
        }
        .accessibilityIdentifier("siteAuditPrimary.\(AccessibilityID.token(title))")
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
        case .outline, .dashed: PPColor.card
        case .secondary: PPColor.card
        case .greyFilled: Color(.systemGray)
        }
    }
}

struct SiteAuditRowIconChip: View {
    let systemName: String
    let tint: Color
    let background: Color
    var size: CGFloat = 30

    var body: some View {
        // Solid tile with a white glyph, like PPIconTile. `background` is kept for callers but no longer drawn.
        let shape = RoundedRectangle(cornerRadius: size * 0.29, style: .continuous)
        Image(systemName: systemName)
            .font(.system(size: size * 0.44, weight: .semibold))
            .symbolRenderingMode(.monochrome)
            .foregroundStyle(Color.white)
            .frame(width: size, height: size)
            .background(tint, in: shape)
            .overlay(shape.strokeBorder(Color.white.opacity(0.22), lineWidth: 0.5))
    }
}

extension View {
    func siteAuditScreenBackground() -> some View {
        background(SiteAuditColors.pageBackground.ignoresSafeArea())
    }
}
