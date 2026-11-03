import SwiftUI
import UIKit
import XCTest
@testable import Project_Planner

/// UI only. Locks that the theme tokens used for buttons, chips, cards and their text
/// change between light and dark mode, so a light fill never sits under light text.
@MainActor
final class DarkModeThemeTokenTests: XCTestCase {
    private var light: UITraitCollection { UITraitCollection(userInterfaceStyle: .light) }
    private var dark: UITraitCollection { UITraitCollection(userInterfaceStyle: .dark) }

    private func rgba(_ color: Color, _ traits: UITraitCollection) -> [CGFloat] {
        let resolved = UIColor(color).resolvedColor(with: traits)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        XCTAssertTrue(resolved.getRed(&r, green: &g, blue: &b, alpha: &a))
        return [r, g, b, a]
    }

    /// WCAG relative luminance, enough to compare "light" against "dark".
    private func luminance(_ c: [CGFloat]) -> CGFloat {
        func channel(_ v: CGFloat) -> CGFloat {
            v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel(c[0]) + 0.7152 * channel(c[1]) + 0.0722 * channel(c[2])
    }

    private func contrast(_ a: [CGFloat], _ b: [CGFloat]) -> CGFloat {
        let la = luminance(a), lb = luminance(b)
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }

    private func assertDiffersByMode(_ name: String, _ color: Color, file: StaticString = #filePath, line: UInt = #line) {
        let l = rgba(color, light)
        let d = rgba(color, dark)
        XCTAssertNotEqual(l, d, "\(name) resolves to the same colour in light and dark mode", file: file, line: line)
    }

    func testSurfaceAndTintTokensHaveDarkVariants() {
        let tokens: [(String, Color)] = [
            ("canvas", ProjectWorksRevampColors.canvas),
            ("surface", ProjectWorksRevampColors.surface),
            ("chipSurface", ProjectWorksRevampColors.chipSurface),
            ("blueTint", ProjectWorksRevampColors.blueTint),
            ("greenTint", ProjectWorksRevampColors.greenTint),
            ("amberTint", ProjectWorksRevampColors.amberTint),
            ("amberTintStrong", ProjectWorksRevampColors.amberTintStrong),
            ("grayTint", ProjectWorksRevampColors.grayTint),
            ("wellFill", ProjectWorksRevampColors.wellFill),
            ("disabledFill", ProjectWorksRevampColors.disabledFill),
            ("successTint", ProjectWorksRevampColors.successTint),
            ("requiredPillBg", ProjectWorksRevampColors.requiredPillBg),
            ("leaveHeroWarm", ProjectWorksRevampColors.leaveHeroWarm),
            ("leaveHeroCool", ProjectWorksRevampColors.leaveHeroCool),
            ("blueFill", ProjectWorksRevampColors.blueFill),
            ("PPColor.page", PPColor.page),
            ("PPColor.card", PPColor.card),
            ("PPColor.brand", PPColor.brand),
        ]
        for (name, color) in tokens {
            assertDiffersByMode(name, color)
        }
    }

    func testTextTokensHaveDarkVariants() {
        let tokens: [(String, Color)] = [
            ("ink", ProjectWorksRevampColors.ink),
            ("muted", ProjectWorksRevampColors.muted),
            ("blue", ProjectWorksRevampColors.blue),
            ("activeGreen", ProjectWorksRevampColors.activeGreen),
            ("upcomingAmber", ProjectWorksRevampColors.upcomingAmber),
            ("requiredPillFg", ProjectWorksRevampColors.requiredPillFg),
        ]
        for (name, color) in tokens {
            assertDiffersByMode(name, color)
        }
    }

    /// The owner's bug: an unselected schedule chip had a white fill and `ink` text, which is
    /// near-white in dark mode. The chip fill must be dark in dark mode and keep the text readable.
    func testUnselectedChipTextIsReadableInBothModes() {
        for traits in [light, dark] {
            let fill = rgba(ProjectWorksRevampColors.chipSurface, traits)
            for (name, text) in [
                ("ink", ProjectWorksRevampColors.ink),
                ("blue", ProjectWorksRevampColors.blue),
                ("requiredPillFg", ProjectWorksRevampColors.requiredPillFg),
            ] {
                let ratio = contrast(fill, rgba(text, traits))
                XCTAssertGreaterThanOrEqual(ratio, 3.0, "\(name) on chipSurface has contrast \(ratio) in \(traits.userInterfaceStyle == .dark ? "dark" : "light") mode")
            }
        }
        XCTAssertLessThan(luminance(rgba(ProjectWorksRevampColors.chipSurface, dark)), 0.1)
    }

    /// Selected chips and primary buttons put white text on `blueFill`.
    func testWhiteTextIsReadableOnBlueFillInBothModes() {
        let white: [CGFloat] = [1, 1, 1, 1]
        for traits in [light, dark] {
            let ratio = contrast(rgba(ProjectWorksRevampColors.blueFill, traits), white)
            XCTAssertGreaterThanOrEqual(ratio, 4.5, "white on blueFill has contrast \(ratio)")
        }
    }

    /// Tinted pills keep their coloured text readable in dark mode.
    func testTintPillPairsAreReadableInDarkMode() {
        let pairs: [(String, Color, Color)] = [
            ("blue on blueTint", ProjectWorksRevampColors.blue, ProjectWorksRevampColors.blueTint),
            ("green on greenTint", ProjectWorksRevampColors.activeGreen, ProjectWorksRevampColors.greenTint),
            ("amber on amberTint", ProjectWorksRevampColors.upcomingAmber, ProjectWorksRevampColors.amberTint),
            ("muted on grayTint", ProjectWorksRevampColors.muted, ProjectWorksRevampColors.grayTint),
            ("red on requiredPillBg", ProjectWorksRevampColors.requiredPillFg, ProjectWorksRevampColors.requiredPillBg),
        ]
        for (name, text, fill) in pairs {
            let ratio = contrast(rgba(text, dark), rgba(fill, dark))
            XCTAssertGreaterThanOrEqual(ratio, 3.0, "\(name) has contrast \(ratio) in dark mode")
        }
    }
}
