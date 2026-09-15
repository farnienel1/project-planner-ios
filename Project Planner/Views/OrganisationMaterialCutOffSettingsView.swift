//
//  OrganisationMaterialCutOffSettingsView.swift
//  Project Planner
//
//  Company-wide material order cut-off time and weekend reminders.
//

import SwiftUI

struct OrganisationMaterialCutOffSettingsView: View {
    @EnvironmentObject var appSettings: AppSettingsStore
    @EnvironmentObject var notificationService: NotificationService

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
                        Toggle("", isOn: Binding(
                            get: { appSettings.settings.notifications.materialOrderCutOff },
                            set: { v in Task { await updateMaterial(v) } }
                        ))
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
                            selection: Binding(
                                get: { materialCutOffTimeValue },
                                set: { v in Task { await updateMaterialCutOffTime(v) } }
                            )
                        ) {
                            ForEach(materialCutOffTimeOptions, id: \.self) { value in
                                Text(materialCutOffTimeLabel(for: value)).tag(value)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .disabled(!appSettings.settings.notifications.materialOrderCutOff)
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
                        Toggle("", isOn: Binding(
                            get: { appSettings.settings.notifications.materialCutOffOnSaturday },
                            set: { v in
                                Task {
                                    await updateMaterialWeekendSettings(
                                        includeSaturday: v,
                                        includeSunday: appSettings.settings.notifications.materialCutOffOnSunday
                                    )
                                }
                            }
                        ))
                        .labelsHidden()
                        .tint(ProjectWorksRevampColors.blue)
                        .disabled(!appSettings.settings.notifications.materialOrderCutOff)
                    }

                    Divider().overlay(ProjectWorksRevampColors.border).padding(.leading, 42)

                    settingsRow(
                        icon: "calendar",
                        iconBg: ProjectWorksRevampColors.endDateBg,
                        iconFg: ProjectWorksRevampColors.endDateFg,
                        title: "Include Sunday",
                        subtitle: "Send the reminder on Sundays"
                    ) {
                        Toggle("", isOn: Binding(
                            get: { appSettings.settings.notifications.materialCutOffOnSunday },
                            set: { v in
                                Task {
                                    await updateMaterialWeekendSettings(
                                        includeSaturday: appSettings.settings.notifications.materialCutOffOnSaturday,
                                        includeSunday: v
                                    )
                                }
                            }
                        ))
                        .labelsHidden()
                        .tint(ProjectWorksRevampColors.blue)
                        .disabled(!appSettings.settings.notifications.materialOrderCutOff)
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
    }

    private var footerText: String {
        if !appSettings.settings.notifications.materialOrderCutOff {
            return "Turn on the notification to choose a time"
        }
        return "Managers are reminded daily at \(materialCutOffTimeLabel(for: materialCutOffTimeValue))"
    }

    private var materialCutOffTimeOptions: [Int] {
        stride(from: 0, through: 23 * 60 + 30, by: 30).map { $0 }
    }

    private var materialCutOffTimeValue: Int {
        (appSettings.settings.notifications.materialCutOffHour * 60) + appSettings.settings.notifications.materialCutOffMinute
    }

    private func materialCutOffTimeLabel(for value: Int) -> String {
        let hour24 = max(0, min(23, value / 60))
        let minute = max(0, min(59, value % 60))
        let hour12 = hour24 == 0 ? 12 : (hour24 > 12 ? hour24 - 12 : hour24)
        let suffix = hour24 >= 12 ? "PM" : "AM"
        return String(format: "%d:%02d %@", hour12, minute, suffix)
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

    private func updateMaterial(_ enabled: Bool) async {
        var updated = appSettings.settings.notifications
        updated.materialOrderCutOff = enabled
        await appSettings.updateNotifications(updated)
        await notificationService.refreshDailyMaterialCutOffReminder()
    }

    private func updateMaterialCutOffTime(_ totalMinutes: Int) async {
        var updated = appSettings.settings.notifications
        updated.materialCutOffHour = max(0, min(23, totalMinutes / 60))
        updated.materialCutOffMinute = max(0, min(59, totalMinutes % 60))
        await appSettings.updateNotifications(updated)
        await notificationService.refreshDailyMaterialCutOffReminder()
    }

    private func updateMaterialWeekendSettings(includeSaturday: Bool, includeSunday: Bool) async {
        var updated = appSettings.settings.notifications
        updated.materialCutOffOnSaturday = includeSaturday
        updated.materialCutOffOnSunday = includeSunday
        await appSettings.updateNotifications(updated)
        await notificationService.refreshDailyMaterialCutOffReminder()
    }
}
