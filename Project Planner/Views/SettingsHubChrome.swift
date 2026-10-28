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
            .font(.footnote.weight(.semibold))
            .tracking(sentenceCase ? 0 : 0.8)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 4)
            .padding(.top, 14)
            .padding(.bottom, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    static func card<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            content()
        }
        .padding(.horizontal, 14)
        .background(PPColor.card)
        .clipShape(RoundedRectangle(cornerRadius: PPMetrics.cardRadius, style: .continuous))
        .padding(.bottom, 8)
    }

    static func footer(_ text: String) -> some View {
        Text(text)
            .font(.footnote)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 4)
            .padding(.bottom, 12)
    }

    static func divider() -> some View {
        Rectangle()
            .fill(Color(.separator))
            .frame(height: 0.5)
            .accessibilityHidden(true)
    }

    static func row(
        icon: String,
        iconBg: Color,
        iconFg: Color,
        title: String,
        subtitle: String
    ) -> some View {
        HStack(spacing: 13) {
            Image(systemName: icon)
                .font(.system(size: PPMetrics.menuIcon * 0.44, weight: .semibold))
                .symbolRenderingMode(.monochrome)
                .foregroundStyle(.white)
                .frame(width: PPMetrics.menuIcon, height: PPMetrics.menuIcon)
                .background(
                    LinearGradient(colors: [iconFg.opacity(0.82), iconFg], startPoint: .top, endPoint: .bottom),
                    in: RoundedRectangle(cornerRadius: PPMetrics.menuIcon * 0.29, style: .continuous)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: PPMetrics.menuIcon * 0.29, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.22), lineWidth: 0.5)
                )
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.body)
                    .foregroundStyle(.primary)
                Text(subtitle)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Image(systemName: "chevron.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 11)
        .frame(maxWidth: .infinity, minHeight: 60, alignment: .leading)
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
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.white)
            }
            .frame(maxWidth: .infinity, minHeight: 52)
            .background(PPColor.brand)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
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
            .background(PPColor.page.ignoresSafeArea())
            .navigationBarTitleDisplayMode(.inline)
            .ppNavyNavigationBar()
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
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button(action: action) {
                HStack(spacing: 8) {
                    if isSaving {
                        ProgressView()
                            .progressViewStyle(CircularProgressViewStyle(tint: isDirty ? .white : saveInk))
                    }
                    Text(isSaving ? "Saving…" : title)
                        .font(.body.weight(.semibold))
                }
                .foregroundStyle(isDirty ? Color.white : saveInk)
                .frame(maxWidth: .infinity, minHeight: 52)
                .background(isDirty ? PPColor.brand : saveFill)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
            .buttonStyle(.plain)
            .disabled(!isDirty || isSaving)
            .accessibilityIdentifier("settingsStickySaveBar.save")
        }
        .padding(.horizontal, PPMetrics.screenGutter)
        .padding(.top, 10)
        .padding(.bottom, 12)
        .background(.ultraThinMaterial)
    }

    private var saveFill: Color {
        PPColor.well
    }

    private var saveInk: Color {
        Color(.secondaryLabel)
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
                    }
                    .buttonStyle(PPOnNavyCircleButtonStyle(size: 36))
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
