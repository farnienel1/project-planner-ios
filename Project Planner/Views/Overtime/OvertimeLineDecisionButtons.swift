//
//  OvertimeLineDecisionButtons.swift
//  Project Planner
//
//  The ✕ / ✓ / ⚙ buttons on an overtime line (the person's own lines and the line manager's review lines). Look only:
//  RULEBOOK 1.33.0 — how each button draws (`filled` / `grey` / `idle`) is `overtimeChoiceView` (`OvertimeChoiceLook`);
//  the taps go through `overtimeChoiceAfter` in `OvertimeLinesView`. Nothing is decided here.
//

import SwiftUI

/// How one circle draws for the rulebook's look (`overtimeChoiceView` → `filled` | `grey` | `idle`).
enum OvertimeButtonLook: Hashable, Sendable {
    /// Nothing chosen on this button: an outlined circle in the button's colour.
    case outlined
    /// The chosen button: a filled circle with a white symbol.
    case filled
    /// Another choice is set: a grey outlined circle. Still tappable, so the choice can be changed.
    case greyed

    /// The rulebook's word for the look.
    init(rulebook value: String) {
        switch value {
        case "filled": self = .filled
        case "grey": self = .greyed
        default: self = .outlined
        }
    }
}

/// ✕ ✓ ⚙ as circles drawn from `overtimeChoiceView`. The caller sets `.disabled(...)`; greyed buttons stay tappable.
struct OvertimeLineDecisionButtons: View {
    let look: OvertimeChoiceLook
    let crossLabel: String
    let tickLabel: String
    let cogLabel: String
    /// Identifier prefix, e.g. `overtime.line` → `overtime.line.cross` / `.tick` / `.cog`.
    let identifierPrefix: String
    let onCross: () -> Void
    let onTick: () -> Void
    let onCog: () -> Void

    @ScaledMetric(relativeTo: .body) private var diameter: CGFloat = 34

    init(
        look: OvertimeChoiceLook,
        crossLabel: String,
        tickLabel: String,
        cogLabel: String,
        identifierPrefix: String,
        onCross: @escaping () -> Void,
        onTick: @escaping () -> Void,
        onCog: @escaping () -> Void
    ) {
        self.look = look
        self.crossLabel = crossLabel
        self.tickLabel = tickLabel
        self.cogLabel = cogLabel
        self.identifierPrefix = identifierPrefix
        self.onCross = onCross
        self.onTick = onTick
        self.onCog = onCog
    }

    var body: some View {
        HStack(spacing: 6) {
            circle(OvertimeButtonLook(rulebook: look.cross), symbol: "xmark", tint: PPColor.danger, label: crossLabel, id: "cross", action: onCross)
            circle(OvertimeButtonLook(rulebook: look.tick), symbol: "checkmark", tint: OvertimeLineDecisionStyle.tickGreen, label: tickLabel, id: "tick", action: onTick)
            circle(OvertimeButtonLook(rulebook: look.cog), symbol: "gearshape.fill", tint: PPColor.brand, label: cogLabel, id: "cog", action: onCog)
        }
    }

    private func circle(
        _ look: OvertimeButtonLook,
        symbol: String,
        tint: Color,
        label: String,
        id: String,
        action: @escaping () -> Void
    ) -> some View {
        let stroke: Color
        let symbolColor: Color
        let fill: Color
        switch look {
        case .filled:
            fill = tint
            stroke = tint
            symbolColor = Color.white
        case .outlined:
            fill = Color.clear
            stroke = tint.opacity(0.85)
            symbolColor = tint
        case .greyed:
            fill = Color.clear
            stroke = Color.secondary.opacity(0.35)
            symbolColor = Color.secondary.opacity(0.55)
        }
        return Button(action: action) {
            ZStack {
                Circle().fill(fill)
                Circle().strokeBorder(stroke, lineWidth: 1.5)
                Image(systemName: symbol)
                    .font(.system(size: diameter * 0.42, weight: .bold))
                    .foregroundStyle(symbolColor)
            }
            .frame(width: diameter, height: diameter)
            .frame(minWidth: 44, minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .animation(.easeOut(duration: 0.15), value: look)
        .accessibilityLabel(label)
        .accessibilityAddTraits(look == .filled ? .isSelected : [])
        .accessibilityIdentifier("\(identifierPrefix).\(id)")
    }
}

enum OvertimeLineDecisionStyle {
    /// The filled ✓: the deep green of the jobs & sites family, white tick readable in light and dark mode.
    static let tickGreen = PPFamily.sites.bottom
}

/// A line's overtime figure: the current figure, struck through when crossed or changed (`figureStruck`), and the new
/// one (`newFigure`) on its own line under it (never side by side, so nothing overlaps on a phone).
struct OvertimeLineFigureStack: View {
    let current: String?
    let struck: Bool
    let replacement: String?

    var body: some View {
        VStack(alignment: .trailing, spacing: 2) {
            if let current {
                Text(current)
                    .font(.subheadline.monospacedDigit())
                    .strikethrough(struck)
                    .foregroundStyle(struck ? Color.secondary : Color.primary)
                    .multilineTextAlignment(.trailing)
            }
            if let replacement {
                Text(replacement)
                    .font(.subheadline.weight(.bold).monospacedDigit())
                    .foregroundStyle(Color.primary)
                    .multilineTextAlignment(.trailing)
            }
        }
    }
}
