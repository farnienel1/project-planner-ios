import SwiftUI

struct GeneralAppSettingsView: View {
    @EnvironmentObject var appSettings: AppSettingsStore
    
    var body: some View {
        List {
            Section("General") {
                NavigationLink {
                    MyScheduleGeneralOptionsView()
                        .environmentObject(appSettings)
                } label: {
                    Label("My Schedule", systemImage: "calendar.badge.clock")
                }
            }
        }
        .navigationTitle("General")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct MyScheduleGeneralOptionsView: View {
    @EnvironmentObject var appSettings: AppSettingsStore
    @State private var showingAddItemAlert = false
    @State private var newItemName = ""
    
    var body: some View {
        List {
            Section {
                Text("My Schedule: Add or remove admin/manager additional options within My Schedule. Office, Working From Home and Site Survey have been included as standard.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            
            Section("Additional Options") {
                Toggle("Office", isOn: Binding(
                    get: { appSettings.settings.myScheduleOptions.showOffice },
                    set: { newValue in
                        appSettings.settings.myScheduleOptions.showOffice = newValue
                        Task { await appSettings.updateMyScheduleOptions(appSettings.settings.myScheduleOptions) }
                    }
                ))
                Toggle("Working From Home", isOn: Binding(
                    get: { appSettings.settings.myScheduleOptions.showWorkingFromHome },
                    set: { newValue in
                        appSettings.settings.myScheduleOptions.showWorkingFromHome = newValue
                        Task { await appSettings.updateMyScheduleOptions(appSettings.settings.myScheduleOptions) }
                    }
                ))
                Toggle("Site Survey", isOn: Binding(
                    get: { appSettings.settings.myScheduleOptions.showSiteSurvey },
                    set: { newValue in
                        appSettings.settings.myScheduleOptions.showSiteSurvey = newValue
                        Task { await appSettings.updateMyScheduleOptions(appSettings.settings.myScheduleOptions) }
                    }
                ))
            }
            
            if !appSettings.settings.myScheduleOptions.customItems.isEmpty {
                Section("Custom Items") {
                    ForEach(appSettings.settings.myScheduleOptions.customItems, id: \.self) { item in
                        Text(item)
                    }
                    .onDelete(perform: deleteCustomItems)
                }
            }
        }
        .navigationTitle("My Schedule")
        .navigationBarTitleDisplayMode(.inline)
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
    
    private func deleteCustomItems(at offsets: IndexSet) {
        appSettings.settings.myScheduleOptions.customItems.remove(atOffsets: offsets)
        Task { await appSettings.updateMyScheduleOptions(appSettings.settings.myScheduleOptions) }
    }
}

