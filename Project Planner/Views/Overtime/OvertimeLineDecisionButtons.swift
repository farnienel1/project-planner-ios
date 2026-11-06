//
//  OvertimeLineDecisionButtons.swift
//  Project Planner
//
//  The ✕ / ✓ / ⚙ buttons on an overtime line (the person's own lines and the line manager's review lines). Look only:
//  which choice is shown as picked comes from what the screen already holds (the unsent proposal, the sent request
//  line, the decider's decision, or the rulebook's line state). The taps, what they write and when the buttons are
//  enabled stay with `OvertimeLinesView`, unchanged.
//

import SwiftUI

/// The choice a line shows as picked: ✓ tick, ✕ cross, ⚙ cog (changed hours or rate).
enum OvertimeLineChoice: Hashable, Sendable {
    case tick
    case cross
    case cog

    /// How one button draws for the picked choice.
    enum Look: Hashable, Sendable {
        /// Nothing decided, or ✓ / ✕ after a ⚙ change: an outlined circle in the button's colour.
        case outlined
        /// The picked choice: a filled circle with a white symbol.
        case filled
        /// Another choice is picked: a grey outlined circle. Still tappable, so the choice can be changed.
        case greyed
    }

    /// The choice an action stands for (`.keep` and `.approve` are both a tick).
    init(_ action: OvertimeAction) {
        switch action {
        case .keep, .approve: self = .tick
        case .strike: self = .cross
        case .edit: self = .cog
        }
    }

    /// The choice of a sent request line's `action` (`keep` | `strike` | `edit`), nil for anything else.
    init?(requestAction: String) {
        switch requestAction {
        case "keep": self = .tick
        case "strike": self = .cross
        case "edit": self = .cog
        default: return nil
        }
    }

    /// How `button` draws when `chosen` is picked. A ⚙ change leaves ✓ and ✕ outlined (still to be decided); a ✓ or
    /// ✕ greys the other two.
    static func look(of button: OvertimeLineChoice, chosen: OvertimeLineChoice?) -> Look {
        guard let chosen else { return .outlined }
        if button == chosen { return .filled }
        return chosen == .cog ? .outlined : .greyed
    }

    /// Whether the line's overtime figure is struck through: ✕ (crossed) and ⚙ (the new figure goes under it).
    static func strikesFigure(_ chosen: OvertimeLineChoice?) -> Bool {
        chosen == .cross || chosen == .cog
    }
}

/// ✕ ✓ ⚙ as circles. The caller sets `.disabled(...)` exactly as before; greyed buttons stay tappable.
struct OvertimeLineDecisionButtons: View {
    let chosen: OvertimeLineChoice?
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
        chosen: OvertimeLineChoice?,
        crossLabel: String,
        tickLabel: String,
        cogLabel: String,
        identifierPrefix: String,
        onCross: @escaping () -> Void,
        onTick: @escaping () -> Void,
        onCog: @escaping () -> Void
    ) {
        self.chosen = chosen
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
            circle(.cross, symbol: "xmark", tint: PPColor.danger, label: crossLabel, id: "cross", action: onCross)
            circle(.tick, symbol: "checkmark", tint: OvertimeLineDecisionStyle.tickGreen, label: tickLabel, id: "tick", action: onTick)
            circle(.cog, symbol: "gearshape.fill", tint: PPColor.brand, label: cogLabel, id: "cog", action: onCog)
        }
    }

    private func circle(
        _ kind: OvertimeLineChoice,
        symbol: String,
        tint: Color,
        label: String,
        id: String,
        action: @escaping () -> Void
    ) -> some View {
        let look = OvertimeLineChoice.look(of: kind, chosen: chosen)
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

/// A line's overtime figure: the current figure, struck through when crossed or changed, and the new one on its own
/// line under it (never side by side, so nothing overlaps on a phone).
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
