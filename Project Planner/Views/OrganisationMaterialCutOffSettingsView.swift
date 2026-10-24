//
//  OrganisationMaterialCutOffSettingsView.swift
//  Project Planner
//
//  Company-wide material order cut-off time and weekend reminders.
//

import SwiftUI

struct OrganisationMaterialCutOffSettingsView: View {
    @EnvironmentObject var appSettings: AppSettingsStore
    @EnvironmentObject var firebaseBackend: FirebaseBackend
    @EnvironmentObject var notificationService: NotificationService
    @Environment(\.dismiss) private var dismiss

    private struct CutOffDraft: Equatable {
        var enabled: Bool
        var minutes: Int
        var saturday: Bool
        var sunday: Bool
    }

    @State private var draft = CutOffDraft(enabled: true, minutes: 0, saturday: false, sunday: false)
    @State private var baseline = CutOffDraft(enabled: true, minutes: 0, saturday: false, sunday: false)
    @State private var optionLabels: [Int: String] = [:]
    @State private var isSaving = false
    @State private var didLoad = false

    private var isDirty: Bool { didLoad && draft != baseline }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text("Remind all managers when materials still need ordering before the daily cut-off.")
                    .font(.system(size: 13))
                    .foregroundStyle(ProjectWorksRevampColors.muted)
                    .padding(.horizontal, 4)
                    .padding(.top, 8)
                    .padding(.bottom, 16)

                sectionTitle("Notification")
                settingsCard {
                    settingsRow(
                        icon: "bell.badge.fill",
                        iconBg: ProjectWorksRevampColors.upcomingAmber.opacity(0.18),
                        iconFg: ProjectWorksRevampColors.upcomingAmber,
                        title: "Material cut-off notification",
                        subtitle: "Email all managers"
                    ) {
                        Toggle("", isOn: $draft.enabled)
                        .accessibilityIdentifier("organisationMaterialCutOffSettings.toggle")
                        .labelsHidden()
                        .tint(ProjectWorksRevampColors.blue)
                    }
                }

                sectionTitle("Daily cut-off")
                settingsCard {
                    HStack(spacing: 12) {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(ProjectWorksRevampColors.blue.opacity(0.12))
                            .frame(width: 30, height: 30)
                            .overlay(
                                Image(systemName: "clock.fill")
                                    .font(.system(size: 14, weight: .medium))
                                    .foregroundStyle(ProjectWorksRevampColors.blue)
                            )
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Cut-off time")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(ProjectWorksRevampColors.ink)
                            Text(footerText)
                                .font(.system(size: 11, weight: .regular))
                                .foregroundStyle(ProjectWorksRevampColors.muted)
                        }
                        Spacer(minLength: 8)
                        Picker(
                            "Cut-off time",
                            selection: $draft.minutes
                        ) {
                            ForEach(materialCutOffTimeOptions, id: \.self) { value in
                                Text(materialCutOffTimeLabel(for: value)).tag(value)
                            }
                        }
                        .accessibilityIdentifier("organisationMaterialCutOffSettings.cutOffTime")
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .disabled(!draft.enabled || !didLoad)
                    }
                    .padding(.vertical, 11)

                    Divider().overlay(ProjectWorksRevampColors.border).padding(.leading, 42)

                    settingsRow(
                        icon: "calendar",
                        iconBg: ProjectWorksRevampColors.jobTypePillBg,
                        iconFg: ProjectWorksRevampColors.jobTypePillInk,
                        title: "Include Saturday",
                        subtitle: "Send the reminder on Saturdays"
                    ) {
                        Toggle("", isOn: $draft.saturday)
                        .accessibilityIdentifier("organisationMaterialCutOffSettings.toggle2")
                        .labelsHidden()
                        .tint(ProjectWorksRevampColors.blue)
                        .disabled(!draft.enabled)
                    }

                    Divider().overlay(ProjectWorksRevampColors.border).padding(.leading, 42)

                    settingsRow(
                        icon: "calendar",
                        iconBg: ProjectWorksRevampColors.endDateBg,
                        iconFg: ProjectWorksRevampColors.endDateFg,
                        title: "Include Sunday",
                        subtitle: "Send the reminder on Sundays"
                    ) {
                        Toggle("", isOn: $draft.sunday)
                        .accessibilityIdentifier("organisationMaterialCutOffSettings.toggle3")
                        .labelsHidden()
                        .tint(ProjectWorksRevampColors.blue)
                        .disabled(!draft.enabled)
                    }
                }
            }
            .padding(.horizontal, 18)
            .padding(.bottom, 28)
        }
        .background(ProjectWorksRevampColors.canvas.ignoresSafeArea())
        .navigationTitle("Material cut-off")
        .navigationBarTitleDisplayMode(.inline)
        .appChromeNavigationBarSurface()
        .safeAreaInset(edge: .bottom) {
            SettingsStickySaveBar(isDirty: isDirty, isSaving: isSaving) {
                Task { await save() }
            }
        }
        .settingsUnsavedLeave(isDirty: isDirty) {
            draft = baseline
            dismiss()
        }
        .onAppear { loadDraft() }
        .onChange(of: firebaseBackend.currentOrganization?.settings.materialCutOff) { _, _ in
            guard !isDirty else { return }
            loadDraft(force: true)
        }
    }

    private var footerText: String {
        if !didLoad {
            return "Loading the organisation cut-off"
        }
        if !draft.enabled {
            return "Turn on the notification to choose a time"
        }
        return "Managers are reminded daily at \(materialCutOffTimeLabel(for: draft.minutes))"
    }

    private var materialCutOffTimeOptions: [Int] {
        stride(from: 0, through: 23 * 60 + 30, by: 30).map { $0 }
    }

    private func materialCutOffTimeLabel(for value: Int) -> String {
        if let label = optionLabels[value] { return label }
        let clock = CanonicalBusinessEngine.CanonicalMaterialCutOffClock(
            materialOrderCutOff: true,
            materialCutOffHour: value / 60,
            materialCutOffMinute: value % 60,
            materialCutOffOnSaturday: false,
            materialCutOffOnSunday: false
        )
        return CanonicalBusinessEngine.formatMaterialCutOffClock(clock) ?? ""
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(ProjectWorksRevampColors.muted)
            .tracking(0.4)
            .padding(.leading, 4)
            .padding(.top, 6)
            .padding(.bottom, 8)
    }

    private func settingsCard(@ViewBuilder content: () -> some View) -> some View {
        VStack(spacing: 0) {
            content()
        }
        .padding(.horizontal, 14)
        .background(Color.white)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(ProjectWorksRevampColors.border, lineWidth: 0.5)
        )
        .padding(.bottom, 8)
    }

    private func settingsRow(
        icon: String,
        iconBg: Color,
        iconFg: Color,
        title: String,
        subtitle: String,
        @ViewBuilder trailing: () -> some View
    ) -> some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(iconBg)
                .frame(width: 30, height: 30)
                .overlay(
                    Image(systemName: icon)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(iconFg)
                )
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(ProjectWorksRevampColors.ink)
                Text(subtitle)
                    .font(.system(size: 11, weight: .regular))
                    .foregroundStyle(ProjectWorksRevampColors.muted)
            }
            Spacer(minLength: 8)
            trailing()
        }
        .padding(.vertical, 11)
    }

    private func loadDraft(force: Bool = false) {
        guard force || !didLoad else { return }
        refreshOptionLabels()
        guard let clock = OrgMaterialCutOff.resolve(
            stored: firebaseBackend.currentOrganization?.settings.materialCutOff,
            organizationLoaded: firebaseBackend.currentOrganization != nil
        ), let minutes = CanonicalBusinessEngine.materialCutOffClockMinutes(clock) else { return }
        let loaded = CutOffDraft(
            enabled: clock.materialOrderCutOff,
            minutes: minutes,
            saturday: clock.materialCutOffOnSaturday,
            sunday: clock.materialCutOffOnSunday
        )
        draft = loaded
        baseline = loaded
        didLoad = true
    }

    private func refreshOptionLabels() {
        var labels: [Int: String] = [:]
        for value in materialCutOffTimeOptions {
            let clock = CanonicalBusinessEngine.CanonicalMaterialCutOffClock(
                materialOrderCutOff: true,
                materialCutOffHour: value / 60,
                materialCutOffMinute: value % 60,
                materialCutOffOnSaturday: false,
                materialCutOffOnSunday: false
            )
            if let label = CanonicalBusinessEngine.formatMaterialCutOffClock(clock) {
                labels[value] = label
            }
        }
        optionLabels = labels
    }

    private func save() async {
        guard !isSaving, didLoad else { return }
        isSaving = true
        defer { isSaving = false }
        let cutOff = OrgMaterialCutOff(
            materialOrderCutOff: draft.enabled,
            materialCutOffHour: draft.minutes / 60,
            materialCutOffMinute: draft.minutes % 60,
            materialCutOffOnSaturday: draft.saturday,
            materialCutOffOnSunday: draft.sunday
        )
        do {
            try await firebaseBackend.updateOrganizationMaterialCutOff(cutOff)
        } catch {
            appSettings.errorMessage = "Failed to save material cut-off: \(error.localizedDescription)"
            return
        }
        await notificationService.refreshDailyMaterialCutOffReminder()
        baseline = draft
    }
}
