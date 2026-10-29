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
                                    .font(.subheadline.weight(.medium))
                                    .foregroundStyle(Color.primary)
                                Spacer()
                                if appSettings.settings.theme == theme {
                                    Image(systemName: "checkmark")
                                        .fontWeight(.semibold)
                                        .foregroundStyle(PPColor.brand)
                                }
                            }
                            .padding(.vertical, 12)
                        }
                        .accessibilityIdentifier("appearanceSettings.row.\(index).checkmark")
                        .buttonStyle(.plain)
                        if index < ThemePreference.allCases.count - 1 {
                            Divider().overlay(Color(.separator))
                        }
                    }
                }
                SettingsHubChrome.footer("Light keeps the usual white screens. Dark uses black and white. Match system follows your iPhone appearance setting.")
            }
            .padding(16)
        }
        .background(PPColor.page.ignoresSafeArea())
        .navigationTitle("Appearance")
        .navigationBarTitleDisplayMode(.inline)
        .ppNavyNavigationBar()
    }
}
