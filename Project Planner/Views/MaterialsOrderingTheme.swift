import SwiftUI

enum MaterialsOrderingTheme {
    static let primary = Color(red: 0.102, green: 0.431, blue: 0.761)
    static let primaryTint = Color(red: 0.890, green: 0.949, blue: 0.996)
    static let pageBackground = Color(red: 0.965, green: 0.973, blue: 0.984)
    static let cardBackground = Color.white
    static let border = Color(red: 0.886, green: 0.910, blue: 0.941)
    static let muted = Color(red: 0.404, green: 0.459, blue: 0.541)
    static let disabled = Color(red: 0.710, green: 0.741, blue: 0.792)
    static let ink = Color(red: 0.078, green: 0.109, blue: 0.184)

    static let success = Color(red: 0.145, green: 0.573, blue: 0.322)
    static let successTint = Color(red: 0.886, green: 0.965, blue: 0.918)
    static let danger = Color(red: 0.757, green: 0.235, blue: 0.235)
    static let warn = Color(red: 0.729, green: 0.471, blue: 0.153)
    static let warnTint = UIColor(red: 0.984, green: 0.949, blue: 0.886, alpha: 1)

    static let primaryGradient = LinearGradient(
        colors: [Color(red: 0.102, green: 0.431, blue: 0.761), Color(red: 0.184, green: 0.565, blue: 0.902)],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )
}
