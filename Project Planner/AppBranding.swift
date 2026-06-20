//
//  AppBranding.swift
//  Project Planner
//

import SwiftUI
import UIKit

enum AppBranding {
    static let webAppBaseURL = "https://project-planner-f986c.web.app"
    static let organisationSetupURL = "\(webAppBaseURL)/setup"

    @MainActor
    static func openOrganisationSetup() {
        guard let url = URL(string: organisationSetupURL) else { return }
        UIApplication.shared.open(url)
    }
}

struct AppLaunchSplashView: View {
    var body: some View {
        ZStack {
            Color.white.ignoresSafeArea()
            VStack(spacing: 20) {
                Image("AppLogo")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 120, height: 120)
                    .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
                    .shadow(color: .black.opacity(0.08), radius: 12, x: 0, y: 4)
                ProgressView()
                    .controlSize(.regular)
            }
        }
    }
}
