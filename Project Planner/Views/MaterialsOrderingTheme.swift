import SwiftUI
import UIKit

enum MaterialsOrderingTheme {
    /// PP brand blue (same token as Home and Settings).
    static let primary = PPColor.brand
    static let primaryTint = AppAdaptiveColor.dynamic(
        light: AppAdaptiveColor.rgb(0.890, 0.949, 0.996),
        dark: AppAdaptiveColor.rgb(0.110, 0.173, 0.247)
    )
    static let pageBackground = PPColor.page
    static let cardBackground = PPColor.card
    static let border = ProjectWorksRevampColors.border
    static let muted = ProjectWorksRevampColors.muted
    static let disabled = ProjectWorksRevampColors.placeholderInk
    static let ink = ProjectWorksRevampColors.ink

    static let success = ProjectWorksRevampColors.activeGreen
    static let successTint = AppAdaptiveColor.dynamic(
        light: AppAdaptiveColor.rgb(0.886, 0.965, 0.918),
        dark: AppAdaptiveColor.rgb(0.090, 0.220, 0.165)
    )
    static let danger = ProjectWorksRevampColors.requiredPillFg
    static let warn = ProjectWorksRevampColors.upcomingAmber
    static let warnTint = UIColor { trait in
        trait.userInterfaceStyle == .dark
            ? UIColor(red: 0.239, green: 0.180, blue: 0.090, alpha: 1)
            : UIColor(red: 0.984, green: 0.949, blue: 0.886, alpha: 1)
    }

    /// PP "plan" family gradient (blue icon tiles).
    static let primaryGradient = PPFamily.plan.gradient
}
