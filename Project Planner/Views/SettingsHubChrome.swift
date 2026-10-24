//
//  SettingsHubChrome.swift
//  Project Planner
//
//  Shared card chrome for settings detail screens (matches Organisation Settings Hub).
//

import SwiftUI
import UIKit

enum SettingsHubChrome {
    static func sectionTitle(_ text: String, sentenceCase: Bool = false) -> some View {
        Text(sentenceCase ? text : text.uppercased())
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
        .accessibilityIdentifier("settingsHubChrome.saving")
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

    /// Sticky Save plus a Back that asks before leaving a dirty nested editor.
    func settingsUnsavedLeave(isDirty: Bool, onLeave: @escaping () -> Void) -> some View {
        modifier(SettingsUnsavedLeaveModifier(isDirty: isDirty, onLeave: onLeave))
    }
}

/// Grey until the draft differs from the last loaded document. Blue once it does.
struct SettingsStickySaveBar: View {
    var title: String = "Save"
    var isDirty: Bool
    var isSaving: Bool
    var action: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(isDirty
                 ? "Save your changes, or they will be lost if you leave."
                 : "Changes are only saved when you press Save.")
                .font(.system(size: 12.5))
                .foregroundStyle(ProjectWorksRevampColors.muted)
                .fixedSize(horizontal: false, vertical: true)
            Button(action: action) {
                HStack(spacing: 8) {
                    if isSaving {
                        ProgressView()
                            .progressViewStyle(CircularProgressViewStyle(tint: isDirty ? .white : saveInk))
                    }
                    Text(isSaving ? "Saving…" : title)
                        .font(.system(size: 15, weight: .semibold))
                }
                .foregroundStyle(isDirty ? Color.white : saveInk)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(isDirty ? ProjectWorksRevampColors.blue : saveFill)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            .buttonStyle(.plain)
            .disabled(!isDirty || isSaving)
            .accessibilityIdentifier("settingsStickySaveBar.save")
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 12)
        .background(.ultraThinMaterial)
    }

    private var saveFill: Color {
        Color(red: 0.82, green: 0.84, blue: 0.87)
    }

    private var saveInk: Color {
        Color(red: 0.42, green: 0.45, blue: 0.50)
    }
}

struct SettingsSwipeBackGuard: UIViewControllerRepresentable {
    var disabled: Bool

    func makeUIViewController(context: Context) -> Controller { Controller() }

    func updateUIViewController(_ controller: Controller, context: Context) {
        controller.disabled = disabled
        controller.apply()
    }

    final class Controller: UIViewController {
        var disabled = false

        override func didMove(toParent parent: UIViewController?) {
            super.didMove(toParent: parent)
            apply()
        }

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            apply()
        }

        override func viewWillDisappear(_ animated: Bool) {
            super.viewWillDisappear(animated)
            navigationController?.interactivePopGestureRecognizer?.isEnabled = true
        }

        func apply() {
            navigationController?.interactivePopGestureRecognizer?.isEnabled = !disabled
        }
    }
}

private struct SettingsUnsavedLeaveModifier: ViewModifier {
    let isDirty: Bool
    let onLeave: () -> Void
    @State private var showingConfirm = false

    func body(content: Content) -> some View {
        content
            .navigationBarBackButtonHidden(true)
            .background(SettingsSwipeBackGuard(disabled: isDirty))
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(action: requestLeave) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(ProjectWorksRevampColors.blue)
                    }
                    .accessibilityIdentifier("settingsUnsavedLeave.back")
                }
            }
            .alert("Unsaved changes", isPresented: $showingConfirm) {
                Button("Cancel", role: .cancel) {}
                    .accessibilityIdentifier("settingsUnsavedLeave.cancel")
                Button("Continue", action: onLeave)
                    .accessibilityIdentifier("settingsUnsavedLeave.continue")
            } message: {
                Text("You have changes that have not been saved. Leave this page and discard them?")
            }
    }

    private func requestLeave() {
        if isDirty {
            showingConfirm = true
        } else {
            onLeave()
        }
    }
}
