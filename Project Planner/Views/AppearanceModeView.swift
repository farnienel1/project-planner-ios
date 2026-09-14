//
//  AppearanceModeView.swift
//  Project Planner
//
//  Settings › Personal › Choose Mode
//

import SwiftUI

struct AppearanceModeView: View {
    @EnvironmentObject var appSettings: AppSettingsStore
    @Environment(\.colorScheme) private var colorScheme

    private var selectedMode: ThemePreference {
        switch appSettings.settings.theme {
        case .dark: return .dark
        case .light: return .light
        case .system: return colorScheme == .dark ? .dark : .light
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text("CHOOSE MODE")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(ProjectWorksRevampColors.muted)
                    .tracking(0.4)
                    .padding(.leading, 4)
                    .padding(.top, 18)
                    .padding(.bottom, 10)

                VStack(spacing: 12) {
                    ForEach(ThemePreference.appearanceModes, id: \.self) { mode in
                        appearanceOptionCard(mode)
                    }
                }

                Text("Applies across the app. Dark mode uses a dim canvas with light text so cards, labels, and icons stay readable.")
                    .font(.system(size: 11, weight: .regular))
                    .foregroundStyle(ProjectWorksRevampColors.muted)
                    .padding(.horizontal, 4)
                    .padding(.top, 14)
            }
            .padding(.horizontal, 18)
            .padding(.bottom, 32)
        }
        .background(ProjectWorksRevampColors.canvas.ignoresSafeArea())
        .navigationTitle("Choose Mode")
        .navigationBarTitleDisplayMode(.inline)
        .appChromeNavigationBarSurface()
    }

    private func appearanceOptionCard(_ mode: ThemePreference) -> some View {
        let isSelected = selectedMode == mode
        return Button {
            Task { await appSettings.updateTheme(mode) }
        } label: {
            HStack(spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(modePreviewBackground(mode))
                        .frame(width: 52, height: 52)
                        .overlay(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .stroke(modePreviewBorder(mode), lineWidth: 1)
                        )
                    Image(systemName: mode.iconName)
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(modePreviewIcon(mode))
                }

                VStack(alignment: .leading, spacing: 3) {
                    Text(mode.displayName)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(ProjectWorksRevampColors.ink)
                    Text(mode == .dark ? "Dim canvas, light text" : "Bright canvas, original look")
                        .font(.system(size: 12, weight: .regular))
                        .foregroundStyle(ProjectWorksRevampColors.muted)
                }

                Spacer(minLength: 8)

                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(isSelected ? ProjectWorksRevampColors.blue : ProjectWorksRevampColors.placeholderInk)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .background(ProjectWorksRevampColors.surface)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(isSelected ? ProjectWorksRevampColors.blue : ProjectWorksRevampColors.border, lineWidth: isSelected ? 1.5 : 0.5)
            )
        }
        .buttonStyle(.plain)
        .animation(.easeInOut(duration: 0.18), value: isSelected)
    }

    private func modePreviewBackground(_ mode: ThemePreference) -> Color {
        mode == .dark
            ? Color(red: 0.110, green: 0.122, blue: 0.157)
            : Color(red: 0.969, green: 0.973, blue: 0.980)
    }

    private func modePreviewBorder(_ mode: ThemePreference) -> Color {
        mode == .dark
            ? Color(red: 0.220, green: 0.239, blue: 0.298)
            : Color(red: 0.898, green: 0.906, blue: 0.922)
    }

    private func modePreviewIcon(_ mode: ThemePreference) -> Color {
        mode == .dark
            ? Color(red: 0.380, green: 0.655, blue: 0.910)
            : Color(red: 0.094, green: 0.373, blue: 0.647)
    }
}
