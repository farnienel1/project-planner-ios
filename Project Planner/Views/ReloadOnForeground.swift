//
//  ReloadOnForeground.swift
//  Project Planner
//
//  RULEBOOK §1 live screens, for low-traffic collections that load when a screen opens (wholesalers, site
//  audits, H&S, deadlines, pay-rate history): while the screen is on display, returning to the app reloads it,
//  so a change made on web shows without closing and reopening it. One read per return, never a timer.
//

import SwiftUI
import UIKit

private struct ReloadOnForegroundModifier: ViewModifier {
    let action: @MainActor () async -> Void

    func body(content: Content) -> some View {
        content.onReceive(NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)) { _ in
            Task { @MainActor in await action() }
        }
    }
}

extension View {
    /// Runs `action` each time the app returns to the foreground while this view is on screen.
    func reloadsOnForeground(_ action: @escaping @MainActor () async -> Void) -> some View {
        modifier(ReloadOnForegroundModifier(action: action))
    }
}
