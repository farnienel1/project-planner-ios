//
//  AppBranding.swift
//  Project Planner
//

import SwiftUI
import UIKit

enum AppBranding {
    static let webAppBaseURL = "https://www.projectplanner.us"
    static let privacyPolicyURL = "https://www.projectplanner.us/privacy"
    static let termsOfServiceURL = "https://www.projectplanner.us/terms"
    static let processorsURL = "https://www.projectplanner.us/processors"

    /// The App Store id of this app, once it has one (the forced-update screen links to it). Nil until then: the
    /// "Update required" screen shows the message only.
    static let appStoreId: String? = nil

    /// `itms-apps://itunes.apple.com/app/id{appStoreId}`, or nil without an App Store id.
    static var appStoreUpdateURL: URL? {
        guard let id = appStoreId?.trimmingCharacters(in: .whitespacesAndNewlines), !id.isEmpty else { return nil }
        return URL(string: "itms-apps://itunes.apple.com/app/id\(id)")
    }

    @MainActor
    static func openPrivacyPolicy() {
        open(privacyPolicyURL)
    }

    @MainActor
    static func openTermsOfService() {
        open(termsOfServiceURL)
    }

    @MainActor
    static func openProcessors() {
        open(processorsURL)
    }

    @MainActor
    private static func open(_ urlString: String) {
        guard let url = URL(string: urlString) else { return }
        UIApplication.shared.open(url)
    }
}

struct AppLaunchSplashView: View {
    var body: some View {
        VStack(spacing: 20) {
            Image("AppLogo")
                .resizable()
                .scaledToFit()
                .frame(width: 120, height: 120)
                .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
                .shadow(color: .black.opacity(0.08), radius: 12, x: 0, y: 4)
            ProgressView()
                .controlSize(.regular)
            Text("Loading your jobs")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Color.black.opacity(0.55))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.white)
    }
}
