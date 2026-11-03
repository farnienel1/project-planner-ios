//
//  ForcedUpdateView.swift
//  Project Planner
//
//  The blocking "Update required" screen (`ForcedUpdateGate`). The App Store button shows only when the app has an
//  App Store id (`AppBranding.appStoreUpdateURL`).
//

import SwiftUI
import UIKit

struct ForcedUpdateView: View {
    var body: some View {
        VStack(spacing: 20) {
            Spacer()
            Image(systemName: "arrow.down.app")
                .font(.system(size: 48, weight: .regular))
                .foregroundStyle(ProjectWorksRevampColors.blue)
            Text("Update required")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(ProjectWorksRevampColors.ink)
                .accessibilityIdentifier("forcedUpdate.title")
            Text("This version of Project Planner is no longer supported. Update the app to keep using it.")
                .font(.system(size: 15))
                .foregroundStyle(ProjectWorksRevampColors.muted)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            if let url = AppBranding.appStoreUpdateURL {
                Button("Open the App Store") {
                    UIApplication.shared.open(url)
                }
                .accessibilityIdentifier("forcedUpdate.appStore")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(ProjectWorksRevampColors.blue)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            Spacer()
        }
        .padding(.horizontal, 24)
        .frame(maxWidth: 420)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(ProjectWorksRevampColors.canvas.ignoresSafeArea())
    }
}
