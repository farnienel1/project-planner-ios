import SwiftUI

extension Color {
    init(hex: String) {
        let cleaned = hex.replacingOccurrences(of: "#", with: "")
        let scanner = Scanner(string: cleaned)
        var value: UInt64 = 0
        scanner.scanHexInt64(&value)
        self.init(
            .sRGB,
            red: Double((value >> 16) & 0xff) / 255.0,
            green: Double((value >> 8) & 0xff) / 255.0,
            blue: Double(value & 0xff) / 255.0,
            opacity: 1
        )
    }
}

enum HS {
    static let bg = Color(hex: "#f1f3f6")
    static let card = Color.white
    static let line = Color(hex: "#eef1f5")
    static let ink = Color(hex: "#16202e")
    static let slate = Color(hex: "#6b7888")
    static let slate2 = Color(hex: "#9aa6b4")
    static let blue = Color(hex: "#2F73F0")
    static let blue2 = Color(hex: "#2563eb")
    static let teal = Color(hex: "#0fae9e")
    static let green = Color(hex: "#1aa564")
    static let greenBg = Color(hex: "#e4f7ee")
    static let amber = Color(hex: "#e08a1e")
    static let amberBg = Color(hex: "#fdf2e0")
    static let red = Color(hex: "#e2493f")
    static let redBg = Color(hex: "#fdeaea")
}

extension View {
    func hsCard(padding: CGFloat = 16) -> some View {
        self
            .padding(padding)
            .background(HS.card)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .shadow(color: .black.opacity(0.05), radius: 9, x: 0, y: 6)
    }
}

struct FilledButtonStyle: ButtonStyle {
    enum Tone { case teal, blue }
    var tone: Tone = .teal
    var fixedWidth: CGFloat? = nil

    func makeBody(configuration: Configuration) -> some View {
        let gradientColors: [Color] = tone == .teal
            ? [Color(hex: "#19c4b3"), Color(hex: "#0fae9e")]
            : [Color(hex: "#3f86ff"), Color(hex: "#2563eb")]
        let shadowColor = tone == .teal ? HS.teal : HS.blue2
        let content = configuration.label
            .font(.system(size: 16, weight: .bold))
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 15)
            .background(LinearGradient(colors: gradientColors, startPoint: .topLeading, endPoint: .bottomTrailing))
            .clipShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
            .shadow(color: shadowColor.opacity(0.32), radius: 11, x: 0, y: 8)
            .scaleEffect(configuration.isPressed ? 0.98 : 1.0)
        if let fixedWidth {
            return AnyView(
                content
                    .frame(width: fixedWidth)
                    .fixedSize(horizontal: true, vertical: false)
                    .layoutPriority(10)
            )
        }
        return AnyView(content)
    }
}

struct GhostButtonStyle: ButtonStyle {
    var tint: Color = HS.teal

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 15, weight: .bold))
            .foregroundStyle(tint)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 13)
            .background(HS.card)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .shadow(color: .black.opacity(0.05), radius: 9, x: 0, y: 6)
            .scaleEffect(configuration.isPressed ? 0.98 : 1.0)
    }
}

struct HSStatusBadge: View {
    enum Tone { case ok, warn, danger, info, neutral }
    let text: String
    var tone: Tone = .ok

    var body: some View {
        let fg: Color
        let bg: Color
        switch tone {
        case .ok:
            fg = HS.green
            bg = HS.greenBg
        case .warn:
            fg = HS.amber
            bg = HS.amberBg
        case .danger:
            fg = HS.red
            bg = HS.redBg
        case .info:
            fg = HS.blue
            bg = Color(hex: "#e8f0ff")
        case .neutral:
            fg = HS.slate
            bg = Color(hex: "#eef1f5")
        }
        return Text(text)
            .font(.system(size: 11, weight: .bold))
            .foregroundStyle(fg)
            .padding(.horizontal, 9)
            .padding(.vertical, 3)
            .background(bg)
            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
    }
}
