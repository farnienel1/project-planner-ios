//
//  HSTheme.swift
//  Project Planner — Health & Safety design system
//
//  Colour tokens with light and dark values, metrics, fonts, card surfaces,
//  and compatibility wrappers for existing H&S button/badge call sites.
//

import SwiftUI
import UIKit

// MARK: - Colour

extension Color {
    init(hex: String) {
        let s = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        var v: UInt64 = 0
        Scanner(string: s).scanHexInt64(&v)
        let r, g, b, a: Double
        switch s.count {
        case 8:
            r = Double((v >> 24) & 0xFF) / 255
            g = Double((v >> 16) & 0xFF) / 255
            b = Double((v >> 8) & 0xFF) / 255
            a = Double(v & 0xFF) / 255
        default:
            r = Double((v >> 16) & 0xFF) / 255
            g = Double((v >> 8) & 0xFF) / 255
            b = Double(v & 0xFF) / 255
            a = 1
        }
        self.init(.sRGB, red: r, green: g, blue: b, opacity: a)
    }
}

/// Builds a colour that resolves differently in light and dark mode.
func hsDyn(_ light: String, _ dark: String) -> Color {
    Color(UIColor { trait in
        UIColor(Color(hex: trait.userInterfaceStyle == .dark ? dark : light))
    })
}

/// The single source of truth for every colour in the H&S section.
enum HS {

    // Surfaces
    static let bg        = hsDyn("#F4F6FA", "#0B1017")
    static let bgDeep    = hsDyn("#EDF0F6", "#070B11")
    static let card      = hsDyn("#FFFFFF", "#151C26")
    static let line      = hsDyn("#E6EBF2", "#252F3D")
    static let fill      = hsDyn("#EFF2F7", "#1B2430")

    // Text
    static let ink       = hsDyn("#0E1726", "#F2F5F9")
    static let inkSoft   = hsDyn("#2A3646", "#D6DEE9")
    static let slate     = hsDyn("#667488", "#9AA7B8")
    static let slate2    = hsDyn("#8E9AAB", "#7C8898")

    // Brand
    static let blue      = hsDyn("#2F6BFF", "#6B95FF")
    static let blueDeep  = hsDyn("#1E4FD8", "#4A78F5")
    static let blue2     = blueDeep
    static let navy      = hsDyn("#12233C", "#0D1622")

    static let teal      = hsDyn("#0FAE9E", "#2BD3C1")
    static let tealLight = hsDyn("#19C4B3", "#4FE3D3")

    // Status
    static let green     = hsDyn("#12A46A", "#2ED18D")
    static let amber     = hsDyn("#E08A1E", "#F2AE45")
    static let red       = hsDyn("#E2493F", "#FF6F63")
    static let violet    = hsDyn("#6D5AE6", "#9585F5")

    static let greenBg   = hsDyn("#E3F6ED", "#12321F")
    static let amberBg   = hsDyn("#FDF3E3", "#382A12")
    static let redBg     = hsDyn("#FCEBEA", "#3A1E1B")
    static let blueBg    = hsDyn("#E9F0FF", "#16244A")
    static let tealBg    = hsDyn("#E2F6F4", "#0E3230")
    static let violetBg  = hsDyn("#EEEBFC", "#241F45")
    static let neutralBg = hsDyn("#EEF1F6", "#1C2531")

    static let onAccent = hsDyn("#FFFFFF", "#071019")

    static let shadowStrong = hsDyn("#0E17260F", "#00000073")
    static let shadowSoft   = hsDyn("#0E172608", "#00000040")

    static var heroBlue: LinearGradient {
        LinearGradient(colors: [hsDyn("#3F86FF", "#3A6FE0"),
                                hsDyn("#2F6BFF", "#2A55C4"),
                                hsDyn("#1E4FD8", "#1B3A93")],
                       startPoint: .topLeading, endPoint: .bottomTrailing)
    }
    static var heroTeal: LinearGradient {
        LinearGradient(colors: [hsDyn("#19C4B3", "#149387"),
                                hsDyn("#0FAE9E", "#0C7268")],
                       startPoint: .topLeading, endPoint: .bottomTrailing)
    }
    static var heroNavy: LinearGradient {
        LinearGradient(colors: [hsDyn("#1B2F4D", "#16243A"),
                                hsDyn("#12233C", "#0C1524")],
                       startPoint: .topLeading, endPoint: .bottomTrailing)
    }
}

// MARK: - Metrics

enum HSMetric {
    static let screenPad: CGFloat      = 18
    static let cardRadius: CGFloat     = 20
    static let cardPad: CGFloat        = 16
    static let rowGap: CGFloat         = 10
    static let sectionGapTop: CGFloat  = 22
    static let sectionGapBot: CGFloat  = 10
    static let controlRadius: CGFloat  = 14
    static let tileRadius: CGFloat     = 12
    static let minTap: CGFloat         = 44
}

// MARK: - Typography

enum HSFont {
    static let screenTitle  = Font.system(size: 20, weight: .bold)
    static let heroTitle    = Font.system(size: 24, weight: .bold)
    static let heroSub      = Font.system(size: 13, weight: .medium)
    static let sectionLabel = Font.system(size: 11.5, weight: .bold)
    static let cardTitle    = Font.system(size: 16, weight: .semibold)
    static let cardTitleLg  = Font.system(size: 17, weight: .bold)
    static let body         = Font.system(size: 14)
    static let meta         = Font.system(size: 12.5, weight: .medium)
    static let badge        = Font.system(size: 11, weight: .bold)
    static let stat         = Font.system(size: 28, weight: .heavy)
    static let statLabel    = Font.system(size: 12, weight: .medium)
    static let button       = Font.system(size: 16, weight: .bold)
    static let buttonSm     = Font.system(size: 13.5, weight: .bold)
}

// MARK: - Shadows

enum HSShadow {
    static func card<V: View>(_ v: V) -> some View {
        v.shadow(color: HS.shadowStrong, radius: 14, x: 0, y: 6)
         .shadow(color: HS.shadowSoft,   radius: 2,  x: 0, y: 1)
    }
}

// MARK: - Core view modifiers

extension View {

    func hsCard(padding: CGFloat = HSMetric.cardPad,
                radius: CGFloat = HSMetric.cardRadius) -> some View {
        self.padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(HS.card)
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(HS.line, lineWidth: 1)
            )
            .modifier(HSCardShadow())
    }

    func hsTappableCard(padding: CGFloat = HSMetric.cardPad,
                        radius: CGFloat = HSMetric.cardRadius) -> some View {
        self.hsCard(padding: padding, radius: radius)
            .contentShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
    }

    func hsScreen() -> some View {
        self.background(HS.bg.ignoresSafeArea())
    }

    func hsGutter() -> some View {
        self.padding(.horizontal, HSMetric.screenPad)
    }

    func hsNoClip(_ lines: Int = 2, minScale: CGFloat = 0.85) -> some View {
        self.lineLimit(lines)
            .minimumScaleFactor(minScale)
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
    }
}

private struct HSCardShadow: ViewModifier {
    func body(content: Content) -> some View {
        content
            .shadow(color: HS.shadowStrong, radius: 14, x: 0, y: 6)
            .shadow(color: HS.shadowSoft,   radius: 2,  x: 0, y: 1)
    }
}

// MARK: - Haptics

enum HSHaptic {
    static func tap()     { UIImpactFeedbackGenerator(style: .light).impactOccurred() }
    static func select()  { UISelectionFeedbackGenerator().selectionChanged() }
    static func success() { UINotificationFeedbackGenerator().notificationOccurred(.success) }
    static func warn()    { UINotificationFeedbackGenerator().notificationOccurred(.warning) }
}

// MARK: - Compatibility wrappers (existing H&S call sites)

struct FilledButtonStyle: ButtonStyle {
    enum Tone { case teal, blue }
    var tone: Tone = .teal
    var fixedWidth: CGFloat? = nil

    func makeBody(configuration: Configuration) -> some View {
        let wrapped = configuration.label
            .font(HSFont.button)
            .foregroundStyle(.white)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .frame(maxWidth: fixedWidth == nil ? .infinity : nil)
            .frame(width: fixedWidth)
            .padding(.horizontal, 16)
            .padding(.vertical, 15)
            .background(tone == .teal ? HS.heroTeal : HS.heroBlue)
            .clipShape(RoundedRectangle(cornerRadius: HSMetric.controlRadius + 1, style: .continuous))
            .shadow(color: (tone == .teal ? HS.teal : HS.blue).opacity(0.30), radius: 12, x: 0, y: 8)
            .scaleEffect(configuration.isPressed ? 0.975 : 1)
        return wrapped
    }
}

struct GhostButtonStyle: ButtonStyle {
    var tint: Color = HS.teal

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 15, weight: .bold))
            .foregroundStyle(tint)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 13)
            .background(HS.card)
            .clipShape(RoundedRectangle(cornerRadius: HSMetric.controlRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: HSMetric.controlRadius, style: .continuous)
                    .strokeBorder(tint.opacity(0.22), lineWidth: 1)
            )
            .scaleEffect(configuration.isPressed ? 0.975 : 1)
    }
}

struct HSStatusBadge: View {
    enum Tone { case ok, warn, danger, info, neutral }
    let text: String
    var tone: Tone = .ok

    var body: some View {
        let mapped: HSBadge.Tone
        switch tone {
        case .ok: mapped = .ok
        case .warn: mapped = .warn
        case .danger: mapped = .danger
        case .info: mapped = .info
        case .neutral: mapped = .neutral
        }
        return HSBadge(text: text, tone: mapped)
    }
}

nonisolated func drawOrganizationDocumentBadgePDF(text: String, in rect: CGRect) {
    let path = UIBezierPath(roundedRect: rect, cornerRadius: 8)
    UIColor(red: 0.094, green: 0.373, blue: 0.647, alpha: 1).setFill()
    path.fill()
    let fontSize: CGFloat = text.count >= 3 ? 12 : 14
    let attrs: [NSAttributedString.Key: Any] = [
        .font: UIFont.systemFont(ofSize: fontSize, weight: .bold),
        .foregroundColor: UIColor.white
    ]
    let size = (text as NSString).size(withAttributes: attrs)
    (text as NSString).draw(
        at: CGPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2),
        withAttributes: attrs
    )
}
