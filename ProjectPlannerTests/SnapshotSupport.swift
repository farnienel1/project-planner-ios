//
//  SnapshotSupport.swift
//  ProjectPlannerTests
//
//  Simulator: iPhone 16e, iOS 26.2 (UDID 9250FFF9-6782-4AF9-96C3-8E2C04D880A4).
//  Snapshot layout: ViewImageConfig.iPhone13 portrait, 390×844 pt @3x, the same
//  point size as iPhone 16e. Record mode is off; later runs compare.
//

import SnapshotTesting
import SwiftUI
import UIKit
import XCTest

enum SnapshotPhone {
    /// Matches the iPhone 16e point size used to run these tests.
    static let layout = ViewImageConfig.iPhone13
}

@MainActor
func assertScreenModes<V: View>(
    _ view: V,
    file: StaticString = #filePath,
    testName: String = #function,
    line: UInt = #line
) {
    let cases: [(String, ColorScheme, DynamicTypeSize, UIUserInterfaceStyle, UIContentSizeCategory)] = [
        ("light", .light, .large, .light, .large),
        ("dark", .dark, .large, .dark, .large),
        ("accessibilityLarge", .light, .accessibility1, .light, .accessibilityLarge),
    ]

    for item in cases {
        let styled = view
            .environment(\.locale, Locale(identifier: "en_GB"))
            .environment(\.timeZone, TimeZone(secondsFromGMT: 0)!)
            .environment(\.colorScheme, item.1)
            .environment(\.dynamicTypeSize, item.2)
        let traits = UITraitCollection(traitsFrom: [
            UITraitCollection(userInterfaceStyle: item.3),
            UITraitCollection(preferredContentSizeCategory: item.4),
        ])
        assertSnapshot(
            of: styled,
            as: .image(layout: .device(config: SnapshotPhone.layout), traits: traits),
            named: item.0,
            file: file,
            testName: testName,
            line: line
        )
    }
}
