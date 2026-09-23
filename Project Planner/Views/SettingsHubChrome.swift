//
//  SettingsHubChrome.swift
//  Project Planner
//
//  Shared card chrome for settings detail screens (matches Organisation Settings Hub).
//

import SwiftUI

enum SettingsHubChrome {
    static func sectionTitle(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(ProjectWorksRevampColors.muted)
            .tracking(0.4)
            .padding(.leading, 4)
            .padding(.top, 6)
            .padding(.bottom, 8)
    }

    static func card<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            content()
        }
        .padding(.horizontal, 14)
        .background(ProjectWorksRevampColors.card)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(ProjectWorksRevampColors.border, lineWidth: 0.5)
        )
        .padding(.bottom, 8)
    }

    static func footer(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(ProjectWorksRevampColors.muted)
            .padding(.horizontal, 4)
            .padding(.bottom, 12)
    }

    static func divider() -> some View {
        Divider().overlay(ProjectWorksRevampColors.border)
    }

    static func row(
        icon: String,
        iconBg: Color,
        iconFg: Color,
        title: String,
        subtitle: String
    ) -> some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(iconBg)
                    .frame(width: 36, height: 36)
                Image(systemName: icon)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(iconFg)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(ProjectWorksRevampColors.ink)
                Text(subtitle)
                    .font(.system(size: 11, weight: .regular))
                    .foregroundStyle(ProjectWorksRevampColors.muted)
            }
            Spacer(minLength: 8)
            Image(systemName: "chevron.right")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(ProjectWorksRevampColors.placeholderInk)
        }
        .padding(.vertical, 13)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }

    static func saveButton(_ title: String, isSaving: Bool = false, enabled: Bool = true, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                if isSaving {
                    ProgressView()
                        .progressViewStyle(CircularProgressViewStyle(tint: .white))
                        .scaleEffect(0.8)
                }
                Text(isSaving ? "Saving…" : title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(ProjectWorksRevampColors.blue)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(isSaving || !enabled)
        .opacity(enabled ? 1 : 0.6)
        .padding(.top, 8)
    }
}

private struct SettingsHubFormChromeModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .scrollContentBackground(.hidden)
            .background(ProjectWorksRevampColors.canvas.ignoresSafeArea())
            .navigationBarTitleDisplayMode(.inline)
            .appChromeNavigationBarSurface()
    }
}

extension View {
    func settingsHubFormChrome() -> some View {
        modifier(SettingsHubFormChromeModifier())
    }
}
