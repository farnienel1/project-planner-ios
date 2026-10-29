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
                    .font(.subheadline)
                    .foregroundStyle(Color.secondary)
                    .padding(.horizontal, 4)
                    .padding(.top, 8)
                    .padding(.bottom, 16)

                sectionTitle("Notification")
                settingsCard {
                    settingsRow(
                        icon: "bell.badge.fill",
                        family: .trade,
                        title: "Material cut-off notification",
                        subtitle: "Email all managers"
                    ) {
                        Toggle("", isOn: $draft.enabled)
                        .accessibilityIdentifier("organisationMaterialCutOffSettings.toggle")
                        .labelsHidden()
                        .tint(PPColor.brand)
                    }
                }

                sectionTitle("Daily cut-off")
                settingsCard {
                    HStack(spacing: 13) {
                        PPIconTile(symbol: "clock.fill", family: .plan)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Cut-off time")
                                .font(.body)
                                .foregroundStyle(Color.primary)
                            Text(footerText)
                                .font(.footnote)
                                .foregroundStyle(Color.secondary)
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

                    Divider().overlay(Color(.separator)).padding(.leading, PPMetrics.menuIcon + 13)

                    settingsRow(
                        icon: "calendar",
                        family: .plan,
                        title: "Include Saturday",
                        subtitle: "Send the reminder on Saturdays"
                    ) {
                        Toggle("", isOn: $draft.saturday)
                        .accessibilityIdentifier("organisationMaterialCutOffSettings.toggle2")
                        .labelsHidden()
                        .tint(PPColor.brand)
                        .disabled(!draft.enabled)
                    }

                    Divider().overlay(Color(.separator)).padding(.leading, PPMetrics.menuIcon + 13)

                    settingsRow(
                        icon: "calendar",
                        family: .plan,
                        title: "Include Sunday",
                        subtitle: "Send the reminder on Sundays"
                    ) {
                        Toggle("", isOn: $draft.sunday)
                        .accessibilityIdentifier("organisationMaterialCutOffSettings.toggle3")
                        .labelsHidden()
                        .tint(PPColor.brand)
                        .disabled(!draft.enabled)
                    }
                }
            }
            .padding(.horizontal, PPMetrics.screenGutter)
            .padding(.bottom, 28)
        }
        .background(PPColor.page.ignoresSafeArea())
        .navigationTitle("Material cut-off")
        .navigationBarTitleDisplayMode(.inline)
        .ppNavyNavigationBar()
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
            .font(.footnote.weight(.semibold))
            .foregroundStyle(Color.secondary)
            .tracking(0.8)
            .padding(.leading, 4)
            .padding(.top, 14)
            .padding(.bottom, 8)
    }

    private func settingsCard(@ViewBuilder content: () -> some View) -> some View {
        VStack(spacing: 0) {
            content()
        }
        .padding(.horizontal, 14)
        .background(PPColor.card)
        .clipShape(RoundedRectangle(cornerRadius: PPMetrics.cardRadius, style: .continuous))
        .padding(.bottom, 8)
    }

    private func settingsRow(
        icon: String,
        family: PPFamily,
        title: String,
        subtitle: String,
        @ViewBuilder trailing: () -> some View
    ) -> some View {
        HStack(spacing: 13) {
            PPIconTile(symbol: icon, family: family)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.body)
                    .foregroundStyle(Color.primary)
                Text(subtitle)
                    .font(.footnote)
                    .foregroundStyle(Color.secondary)
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
