//
//  PPIconTile.swift
//  Project Planner — Midnight UI upgrade (UI ONLY)
//
//  Solid rounded square with a white SF Symbol (iOS Settings style).
//  Replaces the old pastel square + coloured glyph everywhere on
//  Home, Main Menu and More. Purely visual.
//

import SwiftUI

struct PPIconTile: View {
    let symbol: String
    let family: PPFamily
    var size: CGFloat = PPMetrics.menuIcon
    /// Soft coloured drop shadow. Used for the big Home quick-action icons only.
    var lifted: Bool = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: size * 0.29, style: .continuous)

        Image(systemName: symbol)
            .font(.system(size: size * 0.44, weight: .semibold))
            .symbolRenderingMode(.monochrome)
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(family.gradient, in: shape)
            .overlay(shape.strokeBorder(Color.white.opacity(0.22), lineWidth: 0.5))
            .shadow(color: lifted ? family.bottom.opacity(0.35) : .clear, radius: 7, x: 0, y: 5)
            .accessibilityHidden(true)
    }
}

/// Small "+" badge used on Quick create tiles.
struct PPPlusBadge: View {
    var body: some View {
        Image(systemName: "plus")
            .font(.system(size: 8, weight: .heavy))
            .foregroundStyle(.primary)
            .frame(width: 16, height: 16)
            .background(PPColor.card, in: Circle())
            .overlay(Circle().strokeBorder(Color(.separator), lineWidth: 0.5))
            .offset(x: 4, y: 4)
            .accessibilityHidden(true)
    }
}
