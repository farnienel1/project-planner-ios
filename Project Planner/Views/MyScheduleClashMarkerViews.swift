//
//  MyScheduleClashMarkerViews.swift
//  Project Planner
//
//  RULEBOOK 1.39.0 §10 (owner answer 11 Nov): the small triangle on one of the viewer's own My Schedule bookings that
//  overlaps another of their bookings — red while the clash is not approved, grey once approved — and its popup in
//  the app's own style (not a stock alert). The texts, the colour and whether "Open Warnings" is offered all come from
//  `CanonicalBusinessEngine.myScheduleClashMarkers`; nothing is decided here and nothing is written. Web draws the same
//  (`components/schedule/MyScheduleClashMarker.tsx`).
//

import SwiftUI

struct MyScheduleClashMarkerButton: View {
    let marker: RulebookMyScheduleClashMarker
    @State private var showing = false

    private var tint: Color { marker.isApproved ? PPFamily.system.top : PPColor.danger }

    var body: some View {
        Button {
            showing = true
        } label: {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(tint)
                .frame(width: 32, height: 32)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(marker.title)
        .accessibilityIdentifier(marker.isApproved ? "myScheduleClashMarker.approved" : "myScheduleClashMarker.clash")
        .sheet(isPresented: $showing) {
            MyScheduleClashMarkerSheet(
                marker: marker,
                onClose: { showing = false },
                onOpenWarnings: {
                    showing = false
                    // Same route a Warnings notification opens (`NotificationDeepLink` "warnings").
                    NotificationCenter.default.post(
                        name: .mainMenuOpenSurface,
                        object: nil,
                        userInfo: ["route": MainMenuSurfaceRoute.warnings.rawValue]
                    )
                    NotificationCenter.default.post(name: NSNotification.Name("navigateToWarnings"), object: nil)
                }
            )
            .presentationDetents([.medium])
            .presentationDragIndicator(.visible)
        }
    }
}

private struct MyScheduleClashMarkerSheet: View {
    let marker: RulebookMyScheduleClashMarker
    let onClose: () -> Void
    let onOpenWarnings: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                PPIconTile(
                    symbol: "exclamationmark.triangle.fill",
                    family: marker.isApproved ? .system : .alert,
                    size: 44,
                    lifted: true
                )
                Text(marker.title)
                    .font(.system(.title2, design: .rounded))
                    .fontWeight(.bold)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
                Text(marker.message)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("myScheduleClashMarker.message")
                if let action = marker.actionLabel {
                    Button(action: onOpenWarnings) {
                        Text(action)
                            .font(.body.weight(.semibold))
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .background(PPColor.brand, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
                    .buttonStyle(PPPressableButtonStyle())
                    .accessibilityIdentifier("myScheduleClashMarker.openWarnings")
                }
                Button(action: onClose) {
                    Text("Close")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(PPColor.brand)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("myScheduleClashMarker.close")
            }
            .padding(PPMetrics.screenGutter)
            .padding(.top, 10)
        }
        .background(PPColor.page.ignoresSafeArea())
    }
}
