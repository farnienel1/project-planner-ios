import SwiftUI

struct GeneralAppSettingsView: View {
    @EnvironmentObject var appSettings: AppSettingsStore
    
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                SettingsHubChrome.sectionTitle("General")
                SettingsHubChrome.card {
                    NavigationLink {
                        MyScheduleGeneralOptionsView()
                            .environmentObject(appSettings)
                    } label: {
                        HStack(spacing: 12) {
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(ProjectWorksRevampColors.blue.opacity(0.12))
                                .frame(width: 30, height: 30)
                                .overlay(
                                    Image(systemName: "calendar.badge.clock")
                                        .font(.system(size: 14, weight: .medium))
                                        .foregroundStyle(ProjectWorksRevampColors.blue)
                                )
                            Text("My Schedule")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(ProjectWorksRevampColors.ink)
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(ProjectWorksRevampColors.muted)
                        }
                        .padding(.vertical, 11)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(16)
        }
        .background(ProjectWorksRevampColors.canvas.ignoresSafeArea())
        .navigationTitle("General")
        .navigationBarTitleDisplayMode(.inline)
        .appChromeNavigationBarSurface()
    }
}

struct MyScheduleGeneralOptionsView: View {
    @EnvironmentObject var appSettings: AppSettingsStore
    @State private var showingAddItemAlert = false
    @State private var newItemName = ""
    
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                SettingsHubChrome.card {
                    Text("My Schedule: Add or remove admin/manager additional options within My Schedule. Office, Working From Home and Site Survey have been included as standard.")
                        .font(.system(size: 13))
                        .foregroundStyle(ProjectWorksRevampColors.muted)
                        .padding(.vertical, 12)
                }

                SettingsHubChrome.sectionTitle("Additional Options")
                SettingsHubChrome.card {
                    scheduleToggle("Office", isOn: Binding(
                        get: { appSettings.settings.myScheduleOptions.showOffice },
                        set: { newValue in
                            appSettings.settings.myScheduleOptions.showOffice = newValue
                            Task { await appSettings.updateMyScheduleOptions(appSettings.settings.myScheduleOptions) }
                        }
                    ))
                    SettingsHubChrome.divider()
                    scheduleToggle("Working From Home", isOn: Binding(
                        get: { appSettings.settings.myScheduleOptions.showWorkingFromHome },
                        set: { newValue in
                            appSettings.settings.myScheduleOptions.showWorkingFromHome = newValue
                            Task { await appSettings.updateMyScheduleOptions(appSettings.settings.myScheduleOptions) }
                        }
                    ))
                    SettingsHubChrome.divider()
                    scheduleToggle("Site Survey", isOn: Binding(
                        get: { appSettings.settings.myScheduleOptions.showSiteSurvey },
                        set: { newValue in
                            appSettings.settings.myScheduleOptions.showSiteSurvey = newValue
                            Task { await appSettings.updateMyScheduleOptions(appSettings.settings.myScheduleOptions) }
                        }
                    ))
                }
                
                if !appSettings.settings.myScheduleOptions.customItems.isEmpty {
                    SettingsHubChrome.sectionTitle("Custom Items")
                    SettingsHubChrome.card {
                        ForEach(Array(appSettings.settings.myScheduleOptions.customItems.enumerated()), id: \.offset) { index, item in
                            HStack {
                                Text(item)
                                    .font(.system(size: 13, weight: .medium))
                                    .foregroundStyle(ProjectWorksRevampColors.ink)
                                Spacer()
                                Button(role: .destructive) {
                                    deleteCustomItem(at: index)
                                } label: {
                                    Image(systemName: "trash")
                                        .font(.system(size: 13))
                                        .foregroundStyle(ProjectWorksRevampColors.requiredPillFg)
                                }
                                .buttonStyle(.plain)
                            }
                            .padding(.vertical, 12)
                            if index < appSettings.settings.myScheduleOptions.customItems.count - 1 {
                                SettingsHubChrome.divider()
                            }
                        }
                    }
                }
            }
            .padding(16)
        }
        .background(ProjectWorksRevampColors.canvas.ignoresSafeArea())
        .navigationTitle("My Schedule")
        .navigationBarTitleDisplayMode(.inline)
        .appChromeNavigationBarSurface()
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    newItemName = ""
                    showingAddItemAlert = true
                } label: {
                    Image(systemName: "plus")
                }
            }
        }
        .alert("Add My Schedule Item", isPresented: $showingAddItemAlert) {
            TextField("Item name", text: $newItemName)
            Button("Cancel", role: .cancel) { }
            Button("Add") { addCustomItem() }
        } message: {
            Text("Create an extra booking option for admin/manager My Schedule.")
        }
    }

    private func scheduleToggle(_ title: String, isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn) {
            Text(title)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(ProjectWorksRevampColors.ink)
        }
        .tint(ProjectWorksRevampColors.blue)
        .padding(.vertical, 11)
    }
    
    private func addCustomItem() {
        let trimmed = newItemName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard !appSettings.settings.myScheduleOptions.customItems.contains(where: {
            $0.caseInsensitiveCompare(trimmed) == .orderedSame
        }) else { return }
        appSettings.settings.myScheduleOptions.customItems.append(trimmed)
        appSettings.settings.myScheduleOptions.customItems.sort()
        Task { await appSettings.updateMyScheduleOptions(appSettings.settings.myScheduleOptions) }
    }

    private func deleteCustomItem(at index: Int) {
        guard appSettings.settings.myScheduleOptions.customItems.indices.contains(index) else { return }
        let name = appSettings.settings.myScheduleOptions.customItems.remove(at: index)
        appSettings.settings.myScheduleOptions.customItemEnabled.removeValue(forKey: name)
        Task { await appSettings.updateMyScheduleOptions(appSettings.settings.myScheduleOptions) }
    }
}
