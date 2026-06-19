//
//  SettingsHubSupportViews.swift
//  Project Planner
//
//  Detail screens for the two-layer settings hub (see DesignReference/project_planner_settings_two_layers.html).
//

import SwiftUI
import FirebaseAuth
import UIKit

// MARK: - Profile (read-only + account actions)

private struct SettingsProfileSheetsModifier: ViewModifier {
    @Binding var showingManualLinkSheet: Bool
    @Binding var manualLinkOrganizationId: String
    @Binding var isLinking: Bool
    @Binding var linkError: String?
    @Binding var showingProfilePhotoSourcePicker: Bool
    @Binding var profilePhotoPickerSource: UIImagePickerController.SourceType
    @Binding var showingProfileImagePicker: Bool
    @Binding var pickedProfileImage: UIImage?
    @Binding var profilePhotoUploadMessage: String?
    let onManualLink: () -> Void
    let onProfilePhotoPicked: (UIImage) -> Void

    func body(content: Content) -> some View {
        content
            .sheet(isPresented: $showingManualLinkSheet) {
                manualLinkSheet
            }
            .confirmationDialog("Profile photo", isPresented: $showingProfilePhotoSourcePicker, titleVisibility: .visible) {
                if UIImagePickerController.isSourceTypeAvailable(.camera) {
                    Button("Take Photo") {
                        profilePhotoPickerSource = .camera
                        showingProfileImagePicker = true
                    }
                }
                Button("Photo Library") {
                    profilePhotoPickerSource = .photoLibrary
                    showingProfileImagePicker = true
                }
                Button("Cancel", role: .cancel) {}
            }
            .sheet(isPresented: $showingProfileImagePicker) {
                ProfileImagePicker(image: $pickedProfileImage, sourceType: profilePhotoPickerSource)
            }
            .onChange(of: pickedProfileImage) { _, newImage in
                guard let newImage else { return }
                pickedProfileImage = nil
                onProfilePhotoPicked(newImage)
            }
            .alert("Profile photo", isPresented: profilePhotoUploadPresented) {
                Button("OK") { profilePhotoUploadMessage = nil }
            } message: {
                if let profilePhotoUploadMessage {
                    Text(profilePhotoUploadMessage)
                }
            }
    }

    private var profilePhotoUploadPresented: Binding<Bool> {
        Binding(
            get: { profilePhotoUploadMessage != nil },
            set: { if !$0 { profilePhotoUploadMessage = nil } }
        )
    }

    private var manualLinkSheet: some View {
        NavigationStack {
            Form {
                Section("Link to organisation") {
                    TextField("Organisation ID", text: $manualLinkOrganizationId)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    if let linkError {
                        Text(linkError).font(.caption).foregroundStyle(.red)
                    }
                    Button("Link", action: onManualLink)
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

struct SettingsProfileDetailView: View {
    @EnvironmentObject var firebaseBackend: FirebaseBackend
    @EnvironmentObject var userStore: UserStore
    @State private var showingManualLinkSheet = false
    @State private var manualLinkOrganizationId = ""
    @State private var isLinking = false
    @State private var linkError: String?
    @State private var isUpdatingUser = false
    @State private var showingProfilePhotoSourcePicker = false
    @State private var profilePhotoPickerSource: UIImagePickerController.SourceType = .photoLibrary
    @State private var showingProfileImagePicker = false
    @State private var pickedProfileImage: UIImage?
    @State private var isUploadingProfilePhoto = false
    @State private var profilePhotoUploadMessage: String?
    @State private var vatNumberDraft = ""
    @State private var utrNumberDraft = ""
    @State private var isSavingBillingDetails = false
    @State private var billingSaveMessage: String?

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
        profileList
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(ProjectWorksRevampColors.canvas.ignoresSafeArea())
            .navigationTitle("My profile")
            .navigationBarTitleDisplayMode(.inline)
            .appChromeNavigationBarSurface()
            .modifier(SettingsProfileSheetsModifier(
                showingManualLinkSheet: $showingManualLinkSheet,
                manualLinkOrganizationId: $manualLinkOrganizationId,
                isLinking: $isLinking,
                linkError: $linkError,
                showingProfilePhotoSourcePicker: $showingProfilePhotoSourcePicker,
                profilePhotoPickerSource: $profilePhotoPickerSource,
                showingProfileImagePicker: $showingProfileImagePicker,
                pickedProfileImage: $pickedProfileImage,
                profilePhotoUploadMessage: $profilePhotoUploadMessage,
                onManualLink: { Task { await manuallyLink() } },
                onProfilePhotoPicked: { image in
                    Task { await uploadPickedProfilePhoto(image) }
                }
            ))
            .onAppear(perform: syncBillingDraftsFromUser)
            .onChange(of: userStore.currentUser?.vatNumber) { _, newValue in
                if !isSavingBillingDetails {
                    vatNumberDraft = newValue ?? ""
                }
            }
            .onChange(of: userStore.currentUser?.utrNumber) { _, newValue in
                if !isSavingBillingDetails {
                    utrNumberDraft = newValue ?? ""
                }
            }
    }

    private var profileList: some View {
        List {
            profileImageSection
            profileInfoSection
            billingDetailsSection
            manualLinkSection
            debugNameSection
        }
    }

    private var profileImageSection: some View {
        Section("Profile image") {
            HStack(spacing: 12) {
                profileAvatar
                VStack(alignment: .leading, spacing: 4) {
                    Text("Profile photo")
                        .font(.body.weight(.semibold))
                    Text("Used across Home and Settings")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if isUploadingProfilePhoto {
                    ProgressView()
                } else {
                    Button("Change") {
                        showingProfilePhotoSourcePicker = true
                    }
                }
            }
        }
    }

    private var profileInfoSection: some View {
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
            if let dayRate = userStore.currentUser?.dayRate {
                HStack {
                    Text("Day rate")
                    Spacer()
                    Text(String(format: "£%.2f", dayRate))
                        .foregroundStyle(ProjectWorksRevampColors.muted)
                }
            }
        }
    }

    private var billingDetailsSection: some View {
        Section {
            TextField("VAT number (if registered)", text: $vatNumberDraft)
                .textInputAutocapitalization(.characters)
                .autocorrectionDisabled()
            TextField("UTR number", text: $utrNumberDraft)
                .textInputAutocapitalization(.characters)
                .autocorrectionDisabled()
            Button {
                Task { await saveBillingDetails() }
            } label: {
                HStack {
                    if isSavingBillingDetails { ProgressView().scaleEffect(0.85) }
                    Text(isSavingBillingDetails ? "Saving…" : "Save billing details")
                }
            }
            .disabled(isSavingBillingDetails)
            if let billingSaveMessage {
                Text(billingSaveMessage)
                    .font(.caption)
                    .foregroundStyle(billingSaveMessage.contains("saved") ? .green : .red)
            }
        } header: {
            Text("Billing details")
        } footer: {
            Text("VAT and UTR appear on generated invoices. UTR is recommended before you generate an invoice.")
        }
    }

    @ViewBuilder
    private var manualLinkSection: some View {
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
    }

    @ViewBuilder
    private var debugNameSection: some View {
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

    private func syncBillingDraftsFromUser() {
        vatNumberDraft = userStore.currentUser?.vatNumber ?? ""
        utrNumberDraft = userStore.currentUser?.utrNumber ?? ""
    }

    @ViewBuilder
    private var profileAvatar: some View {
        if let url = URL(string: userStore.currentUser?.profilePhotoURL ?? "") {
            AsyncImage(url: url) { phase in
                switch phase {
                case .success(let image):
                    image.resizable().scaledToFill()
                default:
                    Circle()
                        .fill(ProjectWorksRevampColors.blue.opacity(0.2))
                        .overlay(
                            Text(PlannerUIInitials.from(displayName))
                                .font(.headline)
                                .foregroundStyle(ProjectWorksRevampColors.blue)
                        )
                }
            }
            .frame(width: 52, height: 52)
            .clipShape(Circle())
        } else {
            Circle()
                .fill(ProjectWorksRevampColors.blue.opacity(0.2))
                .frame(width: 52, height: 52)
                .overlay(
                    Text(PlannerUIInitials.from(displayName))
                        .font(.headline)
                        .foregroundStyle(ProjectWorksRevampColors.blue)
                )
        }
    }

    private func saveBillingDetails() async {
        guard let userId = userStore.currentUser?.id else { return }
        await MainActor.run {
            isSavingBillingDetails = true
            billingSaveMessage = nil
        }
        let vat = vatNumberDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        let utr = utrNumberDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        let ok = await userStore.updateUserBillingProfile(
            userId: userId,
            vatNumber: vat.isEmpty ? nil : vat,
            utrNumber: utr.isEmpty ? nil : utr
        )
        await MainActor.run {
            isSavingBillingDetails = false
            billingSaveMessage = ok ? "Billing details saved." : (userStore.errorMessage ?? "Could not save billing details.")
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

    private func uploadPickedProfilePhoto(_ image: UIImage) async {
        guard let appUser = userStore.currentUser else { return }
        await MainActor.run { isUploadingProfilePhoto = true }
        let success = await userStore.updateUserProfilePhoto(for: appUser, image: image)
        await MainActor.run {
            isUploadingProfilePhoto = false
            profilePhotoUploadMessage = success ? "Profile photo updated." : (userStore.errorMessage ?? "Could not upload profile photo.")
        }
        if success {
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
