//
//  PPNavyPageComponents.swift
//  Project Planner — Midnight UI upgrade (UI ONLY)
//
//  Home's navy header and light content sheet, reused on pushed pages
//  (Project / Small Works detail, Settings, Organisation Settings Hub).
//  Labels, containers and styles only — no actions, no navigation, no data.
//

import SwiftUI

// MARK: - Navigation bar on navy pages

extension View {
    /// Solid navy bar with white title and buttons, so the bar runs straight into the navy header below it.
    func ppNavyNavigationBar() -> some View {
        self
            .toolbarBackground(PPColor.navy, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
    }
}

// MARK: - Header text and pills

/// Large rounded title on navy (Home greeting style) with an optional caption line above it.
struct PPNavyPageTitle: View {
    var eyebrow: String? = nil
    let title: String
    var subtitle: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if let eyebrow, !eyebrow.isEmpty {
                Text(eyebrow.uppercased())
                    .font(.caption2.weight(.semibold))
                    .tracking(1.1)
                    .foregroundStyle(PPColor.onNavySecondary)
            }
            Text(title)
                .font(.system(.largeTitle, design: .rounded))
                .fontWeight(.bold)
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            if let subtitle, !subtitle.isEmpty {
                Text(subtitle)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(PPColor.onNavySecondary)
                    .lineLimit(2)
            }
        }
    }
}

/// Small glass pill on navy ("Active", "Admin", "DECARBONISATION", "Since Oct '26").
struct PPOnNavyPill: View {
    let text: String
    var symbol: String? = nil
    var showsDot: Bool = false

    var body: some View {
        HStack(spacing: 5) {
            if showsDot {
                Circle().fill(Color.white).frame(width: 6, height: 6)
            }
            if let symbol {
                Image(systemName: symbol)
                    .font(.caption2.weight(.semibold))
            }
            Text(text)
                .font(.caption.weight(.semibold))
                .lineLimit(1)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 10)
        .frame(height: 26)
        .background(Capsule().fill(PPColor.onNavyFill))
        .overlay(Capsule().strokeBorder(PPColor.onNavyStroke, lineWidth: 0.5))
    }
}

/// Thin progress track on navy. `fraction` is 0…1.
struct PPOnNavyProgressBar: View {
    let fraction: Double

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(PPColor.onNavyFill)
                Capsule()
                    .fill(LinearGradient(colors: [PPColor.glow, .white], startPoint: .leading, endPoint: .trailing))
                    .frame(width: max(6, geo.size.width * CGFloat(min(max(fraction, 0), 1))))
            }
        }
        .frame(height: 6)
        .accessibilityHidden(true)
    }
}

// MARK: - Manage grid (Home quick-action style)

/// LABEL for each EXISTING Manage tile Button. Home's quick-action icon with an optional count badge.
struct PPManageTileLabel: View {
    let title: String
    let symbol: String
    let family: PPFamily
    var badge: Int? = nil
    var badgeColor: Color = PPColor.brand

    @ScaledMetric(relativeTo: .caption) private var labelSize: CGFloat = 12.5

    var body: some View {
        VStack(spacing: 7) {
            PPIconTile(symbol: symbol, family: family, size: PPMetrics.quickActionIcon, lifted: true)
                .overlay(alignment: .topTrailing) {
                    if let badge, badge > 0 {
                        Text("\(badge)")
                            .font(.caption2.weight(.bold))
                            .monospacedDigit()
                            .foregroundStyle(.white)
                            .padding(.horizontal, 5)
                            .frame(minWidth: 20, minHeight: 20)
                            .background(Capsule().fill(badgeColor))
                            .overlay(Capsule().strokeBorder(PPColor.page, lineWidth: 2))
                            .offset(x: 6, y: -6)
                    }
                }
            Text(title)
                .font(.system(size: labelSize, weight: .semibold))
                .foregroundStyle(.primary)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .minimumScaleFactor(0.85)
                .frame(maxWidth: 82)
        }
        .frame(maxWidth: .infinity, alignment: .top)
    }
}

// MARK: - Detail rows (icon tile + caption + value)

/// LABEL for a read-only detail row inside a PPGroupedCard ("Client", "Manager", "Timeline").
struct PPDetailRowLabel: View {
    let title: String
    let value: String
    let symbol: String
    let family: PPFamily
    var valueColor: Color = .primary
    var multiline: Bool = false
    var showsChevron: Bool = false

    var body: some View {
        HStack(alignment: multiline ? .top : .center, spacing: 13) {
            PPIconTile(symbol: symbol, family: family, size: PPMetrics.menuIcon)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Text(value)
                    .font(.body)
                    .foregroundStyle(valueColor)
                    .lineLimit(multiline ? nil : 2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            if showsChevron {
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .frame(minHeight: 60)
        .contentShape(Rectangle())
    }
}
