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
        List {
            Section {
                ForEach(ThemePreference.allCases, id: \.self) { theme in
                    Button {
                        Task { await appSettings.updateTheme(theme) }
                    } label: {
                        HStack {
                            Text(theme.displayName)
                                .foregroundStyle(.primary)
                            Spacer()
                            if appSettings.settings.theme == theme {
                                Image(systemName: "checkmark")
                                    .fontWeight(.semibold)
                                    .foregroundStyle(ProjectWorksRevampColors.blue)
                            }
                        }
                    }
                }
            } header: {
                Text("Colour mode")
            } footer: {
                Text("Light keeps the usual white screens. Dark uses black and white. Match system follows your iPhone appearance setting.")
            }
        }
        .navigationTitle("Appearance")
        .navigationBarTitleDisplayMode(.inline)
    }
}
