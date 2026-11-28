//
//  StatusBarOverlap.swift
//  Project Planner
//
//  The app's root fills the whole window and ignores the safe area (Project_PlannerApp), so a SwiftUI view drawn at
//  the very top sits under the status bar / Dynamic Island unless it adds the inset itself. This measures how much of
//  a view's top edge lies under the window's top safe area and gives that as padding — 0 when the view already sits
//  below it (so it never adds a second gap). UI only.
//

import SwiftUI
import UIKit

enum StatusBarOverlap {
    /// Points of padding a view whose top edge is at `viewMinY` (window coordinates) needs to clear a top safe area of
    /// `windowTopInset`. Never negative; rounded to whole points so layout never jitters between near values.
    static func padding(windowTopInset: CGFloat, viewMinY: CGFloat) -> CGFloat {
        guard windowTopInset.isFinite, viewMinY.isFinite else { return 0 }
        let overlap = windowTopInset - max(0, viewMinY)
        return overlap > 0.5 ? overlap.rounded(.up) : 0
    }

    /// The status bar / Dynamic Island height: the largest top safe-area inset of the app's windows (the same read
    /// Home used before; an overlay window such as the app lock may report 0).
    @MainActor
    static func windowTopInset() -> CGFloat {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .filter { $0.bounds.width > 1 && $0.bounds.height > 1 }
            .map(\.safeAreaInsets.top)
            .max() ?? 0
    }
}

private struct StatusBarOverlapReader: ViewModifier {
    @Binding var padding: CGFloat

    func body(content: Content) -> some View {
        content.background(
            GeometryReader { proxy in
                let frame = proxy.frame(in: .global)
                Color.clear
                    .onAppear { update(minY: frame.minY) }
                    .onChange(of: frame) { _, newFrame in update(minY: newFrame.minY) }
            }
        )
        .onReceive(NotificationCenter.default.publisher(for: UIDevice.orientationDidChangeNotification)) { _ in
            // Rotation changes the inset; the frame change usually follows, but read again to be sure.
            DispatchQueue.main.async { padding = StatusBarOverlap.padding(windowTopInset: StatusBarOverlap.windowTopInset(), viewMinY: lastMinY) }
        }
    }

    @State private var lastMinY: CGFloat = 0

    private func update(minY: CGFloat) {
        lastMinY = minY
        let next = StatusBarOverlap.padding(windowTopInset: StatusBarOverlap.windowTopInset(), viewMinY: minY)
        if next != padding { padding = next }
    }
}

extension View {
    /// Reports into `padding` how far this view's top edge lies under the status bar. Apply the padding INSIDE the
    /// measured view (it changes the view's height, never its top edge), so the measurement cannot feed back.
    func measuresStatusBarOverlap(_ padding: Binding<CGFloat>) -> some View {
        modifier(StatusBarOverlapReader(padding: padding))
    }
}
