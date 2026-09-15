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
        List {
            Section {
                Toggle(isOn: Binding(
                    get: { appSettings.settings.notifications.materialOrderCutOff },
                    set: { v in Task { await updateMaterial(v) } }
                )) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Material cut-off notification")
                        Text("Email all managers when materials still need ordering.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .tint(ProjectWorksRevampColors.blue)
            }

            Section {
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
                .disabled(!appSettings.settings.notifications.materialOrderCutOff)

                Toggle("Include Saturday", isOn: Binding(
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
                .disabled(!appSettings.settings.notifications.materialOrderCutOff)
                .tint(ProjectWorksRevampColors.blue)

                Toggle("Include Sunday", isOn: Binding(
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
                .disabled(!appSettings.settings.notifications.materialOrderCutOff)
                .tint(ProjectWorksRevampColors.blue)
            } header: {
                Text("Daily cut-off")
            } footer: {
                Text(footerText)
            }
        }
        .navigationTitle("Material cut-off")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var footerText: String {
        if !appSettings.settings.notifications.materialOrderCutOff {
            return "Turn on the notification to choose a time and whether weekend days are included."
        }
        return "Managers are reminded daily at \(materialCutOffTimeLabel(for: materialCutOffTimeValue))."
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
