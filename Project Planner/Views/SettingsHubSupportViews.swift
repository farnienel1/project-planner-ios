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
        profileScroll
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

    private var profileScroll: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                SettingsHubChrome.sectionTitle("Profile image")
                SettingsHubChrome.card {
                    HStack(spacing: 12) {
                        profileAvatar
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Profile photo")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(ProjectWorksRevampColors.ink)
                            Text("Used across Home and Settings")
                                .font(.system(size: 11))
                                .foregroundStyle(ProjectWorksRevampColors.muted)
                        }
                        Spacer()
                        if isUploadingProfilePhoto {
                            ProgressView()
                        } else {
                            Button("Change") {
                                showingProfilePhotoSourcePicker = true
                            }
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(ProjectWorksRevampColors.blue)
                        }
                    }
                    .padding(.vertical, 12)
                }

                SettingsHubChrome.card {
                    profileValueRow("Name", displayName)
                    SettingsHubChrome.divider()
                    if let email = firebaseBackend.currentUser?.email {
                        profileValueRow("Email", email)
                        SettingsHubChrome.divider()
                    }
                    if let org = firebaseBackend.currentOrganization {
                        profileValueRow("Organisation", org.name)
                    } else {
                        profileValueRow("Organisation", "Not linked", valueColor: ProjectWorksRevampColors.requiredPillFg)
                    }
                    if let dayRate = userStore.currentUser?.dayRate {
                        SettingsHubChrome.divider()
                        profileValueRow("Day rate", String(format: "£%.2f", dayRate))
                    } else if let hourly = userStore.currentUser?.hourlyRate {
                        SettingsHubChrome.divider()
                        profileValueRow("Hourly rate", String(format: "£%.2f", hourly))
                    }
                }

                SettingsHubChrome.sectionTitle("Billing details")
                SettingsHubChrome.card {
                    VStack(alignment: .leading, spacing: 8) {
                        TextField("VAT number (if registered)", text: $vatNumberDraft)
                            .textInputAutocapitalization(.characters)
                            .autocorrectionDisabled()
                            .font(.system(size: 13, weight: .medium))
                            .padding(.top, 12)
                        SettingsHubChrome.divider()
                        TextField("UTR number", text: $utrNumberDraft)
                            .textInputAutocapitalization(.characters)
                            .autocorrectionDisabled()
                            .font(.system(size: 13, weight: .medium))
                        SettingsHubChrome.divider()
                        Button {
                            Task { await saveBillingDetails() }
                        } label: {
                            HStack {
                                if isSavingBillingDetails { ProgressView().scaleEffect(0.85) }
                                Text(isSavingBillingDetails ? "Saving…" : "Save billing details")
                                    .font(.system(size: 13, weight: .semibold))
                            }
                            .foregroundStyle(ProjectWorksRevampColors.blue)
                            .padding(.vertical, 12)
                        }
                        .disabled(isSavingBillingDetails)
                        .buttonStyle(.plain)
                        if let billingSaveMessage {
                            Text(billingSaveMessage)
                                .font(.system(size: 11))
                                .foregroundStyle(billingSaveMessage.contains("saved") ? ProjectWorksRevampColors.activeGreen : ProjectWorksRevampColors.requiredPillFg)
                                .padding(.bottom, 8)
                        }
                    }
                }
                SettingsHubChrome.footer("VAT and UTR appear on generated invoices. UTR is recommended before you generate an invoice.")

                if firebaseBackend.currentOrganization == nil {
                    SettingsHubChrome.card {
                        Button("Link organisation manually") {
                            showingManualLinkSheet = true
                        }
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(ProjectWorksRevampColors.blue)
                        .padding(.vertical, 12)
                        .buttonStyle(.plain)
                    }
                    SettingsHubChrome.footer("Use only if automatic linking failed.")
                }
            }
            .padding(16)
        }
    }

    private func profileValueRow(_ title: String, _ value: String, valueColor: Color = ProjectWorksRevampColors.muted) -> some View {
        HStack {
            Text(title)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(ProjectWorksRevampColors.ink)
            Spacer()
            Text(value)
                .font(.system(size: 13))
                .foregroundStyle(valueColor)
                .multilineTextAlignment(.trailing)
        }
        .padding(.vertical, 12)
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
    @EnvironmentObject var userStore: UserStore
    let canConfigureMaterialCutOff: Bool

    private var visibleToggles: [UserNotificationToggle] {
        guard let user = userStore.currentUser else { return [] }
        return UserNotificationToggle.visible(for: user).filter { key in
            if key == .materialOrderCutOff { return canConfigureMaterialCutOff }
            return true
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                SettingsHubChrome.sectionTitle("Notifications")
                if visibleToggles.isEmpty {
                    SettingsHubChrome.card {
                        Text("Notification options for this account are managed by your organisation.")
                            .font(.system(size: 13))
                            .foregroundStyle(ProjectWorksRevampColors.muted)
                            .padding(.vertical, 12)
                    }
                } else {
                    SettingsHubChrome.card {
                        ForEach(Array(visibleToggles.enumerated()), id: \.element.id) { index, key in
                            HStack(alignment: .top, spacing: 12) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(key.title)
                                        .font(.system(size: 13, weight: .medium))
                                        .foregroundStyle(ProjectWorksRevampColors.ink)
                                    Text(key.subtitle)
                                        .font(.system(size: 11))
                                        .foregroundStyle(ProjectWorksRevampColors.muted)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                Spacer(minLength: 8)
                                Toggle("", isOn: Binding(
                                    get: { appSettings.settings.notifications.isEnabled(key) },
                                    set: { enabled in
                                        Task { await updateToggle(key, enabled: enabled) }
                                    }
                                ))
                                .labelsHidden()
                                .tint(ProjectWorksRevampColors.blue)
                            }
                            .padding(.vertical, 11)
                            if index < visibleToggles.count - 1 {
                                SettingsHubChrome.divider()
                            }
                        }
                    }
                    SettingsHubChrome.footer("Turn off any reminder you do not want. Organisation cut-off time is set in organisation settings. My Schedule extra locations are managed in Organisation Settings Hub → Schedule options.")
                }
            }
            .padding(16)
        }
        .background(ProjectWorksRevampColors.canvas.ignoresSafeArea())
        .navigationTitle("My notifications")
        .navigationBarTitleDisplayMode(.inline)
        .appChromeNavigationBarSurface()
    }

    private func updateToggle(_ key: UserNotificationToggle, enabled: Bool) async {
        var updated = appSettings.settings.notifications
        updated.set(key, enabled: enabled)
        await appSettings.updateNotifications(updated)
        if key == .materialOrderCutOff {
            await notificationService.refreshDailyMaterialCutOffReminder()
        }
        if key == .qualificationExpiry {
            await notificationService.refreshQualificationExpiryReminders()
        }
    }
}
