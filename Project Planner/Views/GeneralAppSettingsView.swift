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
                        HStack(spacing: 13) {
                            PPIconTile(symbol: "calendar.badge.clock", family: .plan)
                            Text("My Schedule")
                                .font(.body)
                                .foregroundStyle(Color.primary)
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(.tertiary)
                        }
                        .padding(.vertical, 11)
                        .frame(minHeight: 54)
                        .contentShape(Rectangle())
                    }
                    .accessibilityIdentifier("generalAppSettings.calendarBadgeClock")
                    .buttonStyle(.plain)
                }
            }
            .padding(16)
        }
        .background(PPColor.page.ignoresSafeArea())
        .navigationTitle("General")
        .navigationBarTitleDisplayMode(.inline)
        .scrollContentBackground(.hidden)
        .background(PPColor.page.ignoresSafeArea())
        .ppNavyNavigationBar()
    }
}

struct MyScheduleGeneralOptionsView: View {
    @EnvironmentObject var appSettings: AppSettingsStore
    @Environment(\.dismiss) private var dismiss
    @State private var showingAddItemAlert = false
    @State private var newItemName = ""
    @State private var draft = MyScheduleOptions()
    @State private var baseline = MyScheduleOptions()
    @State private var isSaving = false
    @State private var didLoad = false

    private var isDirty: Bool { didLoad && draft != baseline }
    
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                SettingsHubChrome.card {
                    Text("My Schedule: Add or remove admin/manager additional options within My Schedule. Office, Working From Home and Site Survey have been included as standard.")
                        .font(.subheadline)
                        .foregroundStyle(Color.secondary)
                        .padding(.vertical, 12)
                }

                SettingsHubChrome.sectionTitle("Additional Options")
                SettingsHubChrome.card {
                    scheduleToggle("Office", isOn: $draft.showOffice)
                    SettingsHubChrome.divider()
                    scheduleToggle("Working From Home", isOn: $draft.showWorkingFromHome)
                    SettingsHubChrome.divider()
                    scheduleToggle("Site Survey", isOn: $draft.showSiteSurvey)
                }
                
                if !draft.customItems.isEmpty {
                    SettingsHubChrome.sectionTitle("Custom Items")
                    SettingsHubChrome.card {
                        ForEach(Array(draft.customItems.enumerated()), id: \.offset) { index, item in
                            HStack {
                                Text(item)
                                    .font(.subheadline.weight(.medium))
                                    .foregroundStyle(Color.primary)
                                Spacer()
                                Button(role: .destructive) {
                                    deleteCustomItem(at: index)
                                } label: {
                                    Image(systemName: "trash")
                                        .font(.subheadline)
                                        .foregroundStyle(PPColor.danger)
                                }
                                .accessibilityIdentifier("myScheduleGeneralOptions.row.\(index).delete")
                                .buttonStyle(.plain)
                            }
                            .padding(.vertical, 12)
                            if index < draft.customItems.count - 1 {
                                SettingsHubChrome.divider()
                            }
                        }
                    }
                }
            }
            .padding(16)
        }
        .background(PPColor.page.ignoresSafeArea())
        .navigationTitle("My Schedule")
        .navigationBarTitleDisplayMode(.inline)
        .scrollContentBackground(.hidden)
        .background(PPColor.page.ignoresSafeArea())
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
        .onAppear {
            guard !didLoad else { return }
            draft = appSettings.settings.myScheduleOptions
            baseline = draft
            didLoad = true
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    newItemName = ""
                    showingAddItemAlert = true
                } label: {
                    Image(systemName: "plus")
                }
                    .buttonStyle(PPOnNavyCircleButtonStyle(size: 36))
                    .accessibilityIdentifier("myScheduleGeneralOptions.add")
            }
        }
        .alert("Add My Schedule Item", isPresented: $showingAddItemAlert) {
            TextField("Item name", text: $newItemName)
                .accessibilityIdentifier("myScheduleGeneralOptions.itemName")
            Button("Cancel", role: .cancel) { }
                .accessibilityIdentifier("myScheduleGeneralOptions.cancel")
            Button("Add") { addCustomItem() }
                .accessibilityIdentifier("myScheduleGeneralOptions.add2")
        } message: {
            Text("Create an extra booking option for admin/manager My Schedule.")
        }
    }

    private func scheduleToggle(_ title: String, isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn) {
            Text(title)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(Color.primary)
        }
        .accessibilityIdentifier("myScheduleGeneralOptions.\(AccessibilityID.token(title))")
        .tint(PPColor.brand)
        .padding(.vertical, 11)
    }
    
    private func addCustomItem() {
        let trimmed = newItemName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard !draft.customItems.contains(where: {
            $0.caseInsensitiveCompare(trimmed) == .orderedSame
        }) else { return }
        draft.customItems.append(trimmed)
        draft.customItems.sort()
        draft.customItemEnabled[trimmed] = true
    }

    private func deleteCustomItem(at index: Int) {
        guard draft.customItems.indices.contains(index) else { return }
        let name = draft.customItems.remove(at: index)
        draft.customItemEnabled.removeValue(forKey: name)
    }

    private func save() async {
        guard !isSaving else { return }
        isSaving = true
        defer { isSaving = false }
        await appSettings.updateMyScheduleOptions(draft)
        baseline = draft
    }
}
