//
//  PPTheme.swift
//  Project Planner — Midnight UI upgrade (UI ONLY)
//
//  Colours, icon colour families, sizes and small shared helpers.
//  This file contains NO business logic, NO data access and NO navigation.
//  Requires iOS 17+. iOS 26 Liquid Glass APIs are guarded with #available.
//

import SwiftUI
import UIKit

// MARK: - Hex helpers

extension UIColor {
    convenience init(ppHex hex: UInt32, alpha: CGFloat = 1) {
        self.init(
            red: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: alpha
        )
    }
}

extension Color {
    init(ppHex hex: UInt32, opacity: Double = 1) {
        self.init(uiColor: UIColor(ppHex: hex, alpha: CGFloat(opacity)))
    }

    /// A colour that switches automatically between light and dark mode.
    static func ppDynamic(light: UInt32, dark: UInt32) -> Color {
        Color(uiColor: UIColor { traits in
            traits.userInterfaceStyle == .dark ? UIColor(ppHex: dark) : UIColor(ppHex: light)
        })
    }
}

// MARK: - Colour tokens

enum PPColor {
    // Midnight navy header (same in light and dark mode)
    static let navy        = Color(ppHex: 0x0E1A2E)
    static let navyRaised  = Color(ppHex: 0x16284A)
    static let glow        = Color(ppHex: 0x4B87FF)

    // Text and fills that sit ON the navy
    static let onNavySecondary = Color.white.opacity(0.62)
    static let onNavyCaption   = Color.white.opacity(0.66)
    static let onNavyHairline  = Color.white.opacity(0.12)
    static let onNavyFill      = Color.white.opacity(0.10)
    static let onNavyStroke    = Color.white.opacity(0.18)

    // Accents
    static let brand        = Color.ppDynamic(light: 0x2457D6, dark: 0x5A8BFF)
    static let warningAmber = Color(ppHex: 0xFFB547)   // "9 Warnings" number on navy
    static let hiVis        = Color(ppHex: 0xFFD43B)   // Heads up pill ONLY
    static let hiVisInk     = Color(ppHex: 0x14171C)   // text on hi-vis
    static let danger       = Color.ppDynamic(light: 0xD93A3F, dark: 0xFF6369)

    // Surfaces (system colours so dark mode is automatic)
    static let page = Color(.systemGroupedBackground)
    static let card = Color(.secondarySystemGroupedBackground)
    static let well = Color(.tertiarySystemFill)
}

// MARK: - Icon colour families
//
// Every icon tile in Home, Main Menu and More uses exactly one family.
// See the Symbol & Family Map in the guide.

enum PPFamily {
    case plan     // blue     — planning & time
    case sites    // green    — jobs & sites
    case people   // indigo   — people
    case trade    // amber    — small works & trade library
    case system   // graphite — app & system
    case alert    // red      — warnings only

    var top: Color {
        switch self {
        case .plan:   return Color(ppHex: 0x4B87FF)
        case .sites:  return Color(ppHex: 0x25B894)
        case .people: return Color(ppHex: 0x7A73F0)
        case .trade:  return Color(ppHex: 0xF4A640)
        case .system: return Color(ppHex: 0x8F96A6)
        case .alert:  return Color(ppHex: 0xF2676B)
        }
    }

    var bottom: Color {
        switch self {
        case .plan:   return Color(ppHex: 0x2257D9)
        case .sites:  return Color(ppHex: 0x0A8A6B)
        case .people: return Color(ppHex: 0x4A43C6)
        case .trade:  return Color(ppHex: 0xD2760B)
        case .system: return Color(ppHex: 0x5C6374)
        case .alert:  return Color(ppHex: 0xD12F35)
        }
    }

    var gradient: LinearGradient {
        LinearGradient(colors: [top, bottom], startPoint: .top, endPoint: .bottom)
    }
}

// MARK: - Sizes

enum PPMetrics {
    static let screenGutter: CGFloat       = 16
    static let headerBottomPadding: CGFloat = 44   // navy space under the Warnings/Tasks chips
    static let contentOverlap: CGFloat     = 24    // how far the light content sheet overlaps the navy
    static let contentCornerRadius: CGFloat = 28

    static let quickActionIcon: CGFloat    = 58
    static let quickActionColumns: Int     = 4
    static let quickActionRowSpacing: CGFloat = 18
    static let quickActionColumnSpacing: CGFloat = 6

    static let menuIcon: CGFloat           = 31
    static let quickCreateIcon: CGFloat    = 36
    static let chipIcon: CGFloat           = 30

    static let cardRadius: CGFloat         = 22
    static let rowCardRadius: CGFloat      = 20
    static let headerButton: CGFloat       = 40
    static let smallHeaderButton: CGFloat  = 32
}

// MARK: - Press feedback

extension View {
    /// Subtle spring "press in" used by every tappable tile and card.
    func ppPressEffect(_ isPressed: Bool) -> some View {
        self
            .scaleEffect(isPressed ? 0.95 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: isPressed)
    }
}

/// Generic button style that only adds the press effect.
/// Use on quick-action tiles, Up next rows and cards. Does not change behaviour.
struct PPPressableButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .contentShape(Rectangle())
            .ppPressEffect(configuration.isPressed)
    }
}

// MARK: - Liquid Glass helpers (iOS 26, with fallbacks)

extension View {
    /// Prominent capsule button (e.g. Main Menu "Done").
    @ViewBuilder
    func ppProminentCapsule() -> some View {
        if #available(iOS 26.0, *) {
            self.buttonStyle(.glassProminent)
                .buttonBorderShape(.capsule)
                .tint(PPColor.brand)
        } else {
            self.buttonStyle(.borderedProminent)
                .buttonBorderShape(.capsule)
                .tint(PPColor.brand)
        }
    }

    /// Round glass button on light/dark surfaces (e.g. More sheet close "X").
    @ViewBuilder
    func ppGlassCircle() -> some View {
        if #available(iOS 26.0, *) {
            self.buttonStyle(.glass)
                .buttonBorderShape(.circle)
        } else {
            self.buttonStyle(.bordered)
                .buttonBorderShape(.circle)
                .tint(.secondary)
        }
    }

    /// Apply once to the existing TabView. Tint only; tabs are untouched.
    @ViewBuilder
    func ppTabBarStyle() -> some View {
        if #available(iOS 26.0, *) {
            self.tint(PPColor.brand)
                .tabBarMinimizeBehavior(.never)   // never hides any tab
        } else {
            self.tint(PPColor.brand)
        }
    }
}
