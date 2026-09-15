//
//  AppearanceSettingsView.swift
//  Project Planner
//
//  Light / dark / system appearance for the signed-in app.
//

import SwiftUI

struct AppearanceSettingsView: View {
    @EnvironmentObject var appSettings: AppSettingsStore

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                SettingsHubChrome.sectionTitle("Colour mode")
                SettingsHubChrome.card {
                    ForEach(Array(ThemePreference.allCases.enumerated()), id: \.offset) { index, theme in
                        Button {
                            Task { await appSettings.updateTheme(theme) }
                        } label: {
                            HStack {
                                Text(theme.displayName)
                                    .font(.system(size: 13, weight: .medium))
                                    .foregroundStyle(ProjectWorksRevampColors.ink)
                                Spacer()
                                if appSettings.settings.theme == theme {
                                    Image(systemName: "checkmark")
                                        .fontWeight(.semibold)
                                        .foregroundStyle(ProjectWorksRevampColors.blue)
                                }
                            }
                            .padding(.vertical, 12)
                        }
                        .buttonStyle(.plain)
                        if index < ThemePreference.allCases.count - 1 {
                            Divider().overlay(ProjectWorksRevampColors.border)
                        }
                    }
                }
                SettingsHubChrome.footer("Light keeps the usual white screens. Dark uses black and white. Match system follows your iPhone appearance setting.")
            }
            .padding(16)
        }
        .background(ProjectWorksRevampColors.canvas.ignoresSafeArea())
        .navigationTitle("Appearance")
        .navigationBarTitleDisplayMode(.inline)
        .appChromeNavigationBarSurface()
    }
}
