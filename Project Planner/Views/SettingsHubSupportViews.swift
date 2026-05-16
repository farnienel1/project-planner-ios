//
//  SettingsHubSupportViews.swift
//  Project Planner
//
//  Detail screens for the two-layer settings hub (see DesignReference/project_planner_settings_two_layers.html).
//

import SwiftUI
import FirebaseAuth

// MARK: - Profile (read-only + account actions)

struct SettingsProfileDetailView: View {
    @EnvironmentObject var firebaseBackend: FirebaseBackend
    @EnvironmentObject var userStore: UserStore
    @State private var showingManualLinkSheet = false
    @State private var manualLinkOrganizationId = ""
    @State private var isLinking = false
    @State private var linkError: String?
    @State private var isUpdatingUser = false

    private var displayName: String {
        if let u = userStore.currentUser {
            let full = "\(u.firstName) \(u.surname)".trimmingCharacters(in: .whitespaces)
            if !full.isEmpty { return full }
        }
        if let e = firebaseBackend.currentUser?.email {
            return e.components(separatedBy: "@").first?.capitalized ?? e
        }
        return "Account"
    }

    var body: some View {
        List {
            Section {
                HStack {
                    Text("Name")
                    Spacer()
                    Text(displayName)
                        .foregroundStyle(ProjectWorksRevampColors.muted)
                }
                if let email = firebaseBackend.currentUser?.email {
                    HStack {
                        Text("Email")
                        Spacer()
                        Text(email)
                            .foregroundStyle(ProjectWorksRevampColors.muted)
                    }
                }
                if let org = firebaseBackend.currentOrganization {
                    HStack {
                        Text("Organisation")
                        Spacer()
                        Text(org.name)
                            .foregroundStyle(ProjectWorksRevampColors.muted)
                    }
                } else {
                    HStack {
                        Text("Organisation")
                        Spacer()
                        Text("Not linked")
                            .foregroundStyle(ProjectWorksRevampColors.requiredPillFg)
                    }
                }
            }

            if firebaseBackend.currentOrganization == nil {
                Section {
                    Button("Link organisation manually") {
                        showingManualLinkSheet = true
                    }
                    .foregroundStyle(ProjectWorksRevampColors.blue)
                } footer: {
                    Text("Use only if automatic linking failed.")
                }
            }

            if let appUser = userStore.currentUser, appUser.email == "farnienelyt@gmail.com" {
                Section {
                    Button {
                        updateUserName()
                    } label: {
                        HStack {
                            if isUpdatingUser { ProgressView().scaleEffect(0.85) }
                            Text(isUpdatingUser ? "Updating…" : "Set display name to Farnie Nel")
                        }
                    }
                    .disabled(isUpdatingUser)
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(ProjectWorksRevampColors.canvas.ignoresSafeArea())
        .navigationTitle("My profile")
        .navigationBarTitleDisplayMode(.inline)
        .appChromeNavigationBarSurface()
        .sheet(isPresented: $showingManualLinkSheet) {
            NavigationStack {
                Form {
                    Section("Link to organisation") {
                        TextField("Organisation ID", text: $manualLinkOrganizationId)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        if let linkError {
                            Text(linkError).font(.caption).foregroundStyle(.red)
                        }
                        Button("Link") {
                            Task { await manuallyLink() }
                        }
                        .disabled(isLinking || manualLinkOrganizationId.isEmpty)
                    }
                }
                .navigationTitle("Manual link")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") {
                            showingManualLinkSheet = false
                            manualLinkOrganizationId = ""
                            linkError = nil
                        }
                    }
                }
            }
        }
    }

    private func manuallyLink() async {
        isLinking = true
        linkError = nil
        let ok = await firebaseBackend.manuallyLinkToOrganization(organizationId: manualLinkOrganizationId)
        await MainActor.run {
            isLinking = false
            if ok {
                showingManualLinkSheet = false
                manualLinkOrganizationId = ""
            } else {
                linkError = "Could not link. Check the organisation ID."
            }
        }
    }

    private func updateUserName() {
        Task {
            isUpdatingUser = true
            defer { isUpdatingUser = false }
            guard var u = userStore.currentUser, u.email == "farnienelyt@gmail.com" else { return }
            u.firstName = "Farnie"
            u.surname = "Nel"
            try? await firebaseBackend.saveUser(u)
            await userStore.loadCurrentUser()
        }
    }
}

// MARK: - Notifications + schedule-related pings

struct SettingsNotificationsHubView: View {
    @EnvironmentObject var appSettings: AppSettingsStore
    @EnvironmentObject var notificationService: NotificationService
    let canConfigureMaterialCutOff: Bool

    var body: some View {
        List {
            Section {
                NavigationLink {
                    GeneralAppSettingsView()
                        .environmentObject(appSettings)
                } label: {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("General app options")
                            Text("My schedule list on this device")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: "calendar.badge.clock")
                            .foregroundStyle(ProjectWorksRevampColors.blue)
                    }
                }
            } footer: {
                Text("Controls extra rows in My Schedule (office, WFH, custom labels).")
            }

            if canConfigureMaterialCutOff {
                Section {
                    Toggle("Material order cut-off (4:00 PM daily)", isOn: Binding(
                        get: { appSettings.settings.notifications.materialOrderCutOff },
                        set: { enabled in
                            Task { await updateMaterial(enabled) }
                        }
                    ))
                } footer: {
                    Text("Sends a daily reminder at 4:00 PM for admins and managers.")
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(ProjectWorksRevampColors.canvas.ignoresSafeArea())
        .navigationTitle("My notifications")
        .navigationBarTitleDisplayMode(.inline)
        .appChromeNavigationBarSurface()
    }

    private func updateMaterial(_ enabled: Bool) async {
        var updated = appSettings.settings.notifications
        updated.materialOrderCutOff = enabled
        await appSettings.updateNotifications(updated)
        await notificationService.refreshDailyMaterialCutOffReminder()
    }
}
