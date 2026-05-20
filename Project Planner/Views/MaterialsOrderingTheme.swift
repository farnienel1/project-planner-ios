//
//  MaterialsOrderingTheme.swift
//  Project Planner
//
//  Design tokens from materials_ordering.html / materials_catalogue.html
//

import SwiftUI

enum MaterialsOrderingTheme {
    static let pageBackground = Color(red: 0.969, green: 0.973, blue: 0.980)
    static let cardBackground = Color.white
    static let ink = Color(red: 0.043, green: 0.063, blue: 0.125)
    static let muted = Color(red: 0.420, green: 0.451, blue: 0.502)
    static let disabled = Color(red: 0.773, green: 0.788, blue: 0.824)
    static let border = Color(red: 0.933, green: 0.941, blue: 0.953)
    static let primary = Color(red: 0.094, green: 0.373, blue: 0.647)
    static let primaryTint = Color(red: 0.902, green: 0.945, blue: 0.984)
    static let success = Color(red: 0.059, green: 0.431, blue: 0.337)
    static let successTint = Color(red: 0.882, green: 0.961, blue: 0.933)
    static let warn = Color(red: 0.522, green: 0.310, blue: 0.043)
    static let warnTint = Color(red: 0.980, green: 0.933, blue: 0.855)
    static let danger = Color(red: 0.639, green: 0.176, blue: 0.176)
    static let dangerTint = Color(red: 0.988, green: 0.922, blue: 0.922)

    static var primaryGradient: LinearGradient {
        LinearGradient(
            colors: [Color(red: 0.094, green: 0.373, blue: 0.647), Color(red: 0.216, green: 0.541, blue: 0.867)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    static var successGradient: LinearGradient {
        LinearGradient(
            colors: [Color(red: 0.059, green: 0.431, blue: 0.337), Color(red: 0.176, green: 0.639, blue: 0.490)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }
}

struct MaterialsStatusPill: View {
    let status: MaterialWorkflowStatus

    var body: some View {
        HStack(spacing: 4) {
            if status == .ordered {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 10))
            } else if status == .sentForQuote {
                Image(systemName: "doc.text.fill")
                    .font(.system(size: 10))
            } else {
                Circle()
                    .fill(dotColor)
                    .frame(width: 5, height: 5)
            }
            Text(status.displayLabel)
                .font(.system(size: 10, weight: .medium))
        }
        .foregroundStyle(foreground)
        .padding(.horizontal, 7)
        .padding(.vertical, 2)
        .background(background)
        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
    }

    private var background: Color {
        switch status {
        case .draft: return MaterialsOrderingTheme.primaryTint
        case .sentForQuote: return MaterialsOrderingTheme.warnTint
        case .ordered: return MaterialsOrderingTheme.successTint
        }
    }

    private var foreground: Color {
        switch status {
        case .draft: return MaterialsOrderingTheme.primary
        case .sentForQuote: return MaterialsOrderingTheme.warn
        case .ordered: return MaterialsOrderingTheme.success
        }
    }

    private var dotColor: Color {
        switch status {
        case .draft: return MaterialsOrderingTheme.primary
        case .sentForQuote: return MaterialsOrderingTheme.warn
        case .ordered: return MaterialsOrderingTheme.success
        }
    }
}

struct MaterialsQuantityBadge: View {
    let quantity: Int
    let unit: MaterialUnit

    var body: some View {
        Text("\(quantity) \(unit.quantityLabel(for: quantity))")
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(MaterialsOrderingTheme.ink)
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .background(Color(red: 0.949, green: 0.953, blue: 0.961))
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}
