//
//  SettingsView.swift
//  Project Planner
//
//  Created by Assistant on 29/10/2025.
//

import SwiftUI
import UIKit
import FirebaseAuth
import FirebaseFirestore

struct SettingsView: View {
    @EnvironmentObject var firebaseBackend: FirebaseBackend
    @EnvironmentObject var projectStore: ProjectStore
    @EnvironmentObject var operativeStore: OperativeStore
    @EnvironmentObject var bookingStore: BookingStore
    @EnvironmentObject var taskStore: ProjectTaskStore
    @EnvironmentObject var appSettings: AppSettingsStore
    @EnvironmentObject var userStore: UserStore
    @EnvironmentObject var notificationService: NotificationService
    @EnvironmentObject var holidayStore: HolidayStore
    @Environment(\.dismiss) private var dismiss
    
    @State private var showingDiagnosticReport = false
    @State private var diagnosticReport = ""
    @State private var isDiagnosing = false
    @State private var isReloading = false
    @State private var showingManualLinkSheet = false
    @State private var manualLinkOrganizationId = ""
    @State private var isLinking = false
    @State private var linkError: String?
    @State private var showingSignOutAlert = false
    @State private var showingEmailTest = false
    @State private var testEmailAddress = ""
    @State private var isTestingEmail = false
    @State private var emailTestResult: String?
    @State private var showingDeleteAllOperativesConfirmation = false
    @State private var isDeletingAllOperatives = false
    @State private var showingNotificationTestAlert = false
    @State private var notificationTestMessage = ""
    @State private var isRunningPushDiagnostic = false
    @State private var deleteTestMessage = ""
    @State private var isTestingDelete = false
    @State private var isUpdatingUser = false
    @State private var isSeedingPlayground = false
    @State private var playgroundSeedMessage: String?
    private var canConfigureMaterialCutOffNotifications: Bool {
        guard let user = userStore.currentUser else { return false }
        if user.permissions.operativeMode { return false }
        return user.isSuperAdmin || user.permissions.adminAccess || user.permissions.manager || user.role == .manager || user.role == .admin
    }
    
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                settingsHubProfileCard
                    .padding(.top, 10)

                settingsHubSectionTitle("Personal")
                settingsHubPersonalGroup

                if userStore.hasAdminAccess(), firebaseBackend.currentOrganization != nil {
                    settingsHubSectionTitle("Company-wide")
                    settingsHubOrganisationPromoCard
                    Text("Tap to manage how \(firebaseBackend.currentOrganization?.name ?? "your organisation") runs — affects everyone in your team.")
                        .font(.system(size: 10, weight: .regular))
                        .foregroundStyle(ProjectWorksRevampColors.muted)
                        .padding(.horizontal, 4)
                        .padding(.top, 4)
                        .padding(.bottom, 20)
                }

                settingsHubSectionTitle("Support & legal")
                settingsHubSupportGroup

                settingsHubSignOut
                    .padding(.top, 6)

                Text("Project Planner · v\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—")")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(ProjectWorksRevampColors.placeholderInk)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 14)
            }
            .padding(.horizontal, 18)
            .padding(.bottom, 32)
        }
        .background(ProjectWorksRevampColors.canvas.ignoresSafeArea())
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button(action: {
                    NotificationCenter.default.post(name: NSNotification.Name("goBackToPreviousTab"), object: nil)
                }) {
                    Image(systemName: "chevron.left")
                        .foregroundStyle(ProjectWorksRevampColors.blue)
                        .font(.system(size: 17, weight: .semibold))
                }
            }
        }
        .navigationBarBackButtonHidden(true)
        .appChromeNavigationBarSurface()
        .alert("Sign Out", isPresented: $showingSignOutAlert) {
            Button("Cancel", role: .cancel) { }
            Button("Sign Out", role: .destructive) {
                userStore.clearOnSignOut()
                do {
                    try firebaseBackend.signOut()
                } catch {
                    print("🔥🔥🔥 DEBUG: Error signing out: \(error.localizedDescription)")
                }
            }
        } message: {
            Text("Are you sure you want to sign out?")
        }
    }

    // MARK: - Settings hub (HTML layer 1)

    private var settingsHubDisplayName: String {
        if let u = userStore.currentUser {
            let full = "\(u.firstName) \(u.surname)".trimmingCharacters(in: .whitespaces)
            if !full.isEmpty { return full }
        }
        if let e = firebaseBackend.currentUser?.email {
            return e.components(separatedBy: "@").first?.capitalized ?? e
        }
        return "Account"
    }

    private var settingsHubInitials: String {
        PlannerUIInitials.from(settingsHubDisplayName)
    }

    private var settingsHubOrgLine: String {
        firebaseBackend.currentOrganization?.name ?? "No organisation linked"
    }

    private var settingsHubRoleBadge: (text: String, fg: Color, bg: Color)? {
        let u = userStore.currentUser
        if u?.isSuperAdmin == true || userStore.hasAdminAccess() {
            return ("Admin", ProjectWorksRevampColors.requiredPillFg, ProjectWorksRevampColors.requiredPillBg)
        }
        if u?.permissions.manager == true {
            return ("Manager", ProjectWorksRevampColors.jobTypePillInk, ProjectWorksRevampColors.jobTypePillBg)
        }
        if u?.permissions.operativeMode == true {
            return ("Operative", ProjectWorksRevampColors.activeGreen, Color(red: 0.93, green: 0.98, blue: 0.95))
        }
        return nil
    }

    private func settingsHubSectionTitle(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(ProjectWorksRevampColors.muted)
            .tracking(0.4)
            .padding(.leading, 4)
            .padding(.top, 20)
            .padding(.bottom, 10)
    }

    private var settingsHubProfileCard: some View {
        HStack(alignment: .center, spacing: 14) {
            ZStack {
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [ProjectWorksRevampColors.pinRoseFg, Color(red: 0.76, green: 0.33, blue: 0.47)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 56, height: 56)
                Text(settingsHubInitials)
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(.white)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(settingsHubDisplayName)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(ProjectWorksRevampColors.ink)
                Text(settingsHubOrgLine)
                    .font(.system(size: 11, weight: .regular))
                    .foregroundStyle(ProjectWorksRevampColors.muted)
                if let badge = settingsHubRoleBadge {
                    HStack(spacing: 4) {
                        Image(systemName: "checkmark.shield.fill")
                            .font(.system(size: 10, weight: .medium))
                        Text(badge.text)
                            .font(.system(size: 10, weight: .medium))
                    }
                    .foregroundStyle(badge.fg)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(badge.bg)
                    .clipShape(Capsule())
                }
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .appChromeCardContainer(cornerRadius: 18)
    }

    private var settingsHubPersonalGroup: some View {
        VStack(spacing: 0) {
            NavigationLink {
                SettingsProfileDetailView()
                    .environmentObject(firebaseBackend)
                    .environmentObject(userStore)
            } label: {
                settingsHubRow(
                    icon: "person.fill",
                    iconBg: ProjectWorksRevampColors.blue.opacity(0.12),
                    iconFg: ProjectWorksRevampColors.blue,
                    title: "My profile",
                    subtitle: "Name, photo, contact details"
                )
            }
            .buttonStyle(.plain)
            Divider().background(ProjectWorksRevampColors.border).padding(.leading, 62)
            NavigationLink {
                ChangePasswordView()
                    .environmentObject(firebaseBackend)
            } label: {
                settingsHubRow(
                    icon: "key.fill",
                    iconBg: ProjectWorksRevampColors.jobTypePillBg,
                    iconFg: ProjectWorksRevampColors.jobTypePillInk,
                    title: "Sign-in & password",
                    subtitle: "Email, password, security"
                )
            }
            .buttonStyle(.plain)
            Divider().background(ProjectWorksRevampColors.border).padding(.leading, 62)
            NavigationLink {
                SettingsNotificationsHubView(canConfigureMaterialCutOff: canConfigureMaterialCutOffNotifications)
                    .environmentObject(appSettings)
                    .environmentObject(notificationService)
            } label: {
                settingsHubRow(
                    icon: "bell.fill",
                    iconBg: ProjectWorksRevampColors.pinRoseBg,
                    iconFg: ProjectWorksRevampColors.pinRoseFg,
                    title: "My notifications",
                    subtitle: "What you get pinged about"
                )
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 4)
        .appChromeCardContainer(cornerRadius: 18)
    }

    private func settingsHubRow(
        icon: String,
        iconBg: Color,
        iconFg: Color,
        title: String,
        subtitle: String
    ) -> some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(iconBg)
                    .frame(width: 36, height: 36)
                Image(systemName: icon)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(iconFg)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(ProjectWorksRevampColors.ink)
                Text(subtitle)
                    .font(.system(size: 11, weight: .regular))
                    .foregroundStyle(ProjectWorksRevampColors.muted)
            }
            Spacer(minLength: 8)
            Image(systemName: "chevron.right")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(ProjectWorksRevampColors.placeholderInk)
        }
        .padding(.vertical, 13)
    }

    private var settingsHubOrganisationPromoCard: some View {
        NavigationLink {
            OrganisationSettingsHubView()
                .environmentObject(firebaseBackend)
                .environmentObject(userStore)
                .environmentObject(appSettings)
                .environmentObject(notificationService)
                .environmentObject(holidayStore)
                .environmentObject(operativeStore)
                .environmentObject(bookingStore)
        } label: {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .top, spacing: 14) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(Color.white.opacity(0.18))
                            .frame(width: 42, height: 42)
                        Image(systemName: "building.2.fill")
                            .font(.system(size: 20, weight: .medium))
                            .foregroundStyle(.white)
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 8) {
                            Text("Organisation settings")
                                .font(.system(size: 15, weight: .medium))
                                .foregroundStyle(.white)
                            Text("Admin only")
                                .font(.system(size: 9, weight: .medium))
                                .foregroundStyle(.white.opacity(0.95))
                                .padding(.horizontal, 7)
                                .padding(.vertical, 2)
                                .background(Color.white.opacity(0.22))
                                .clipShape(Capsule())
                        }
                        Text("Hours, leave, schedule options & more for \(firebaseBackend.currentOrganization?.name ?? "your team").")
                            .font(.system(size: 11, weight: .regular))
                            .foregroundStyle(.white.opacity(0.88))
                            .fixedSize(horizontal: false, vertical: true)
                        HStack(spacing: 6) {
                            organisationPromoChip("clock", "Hours")
                            organisationPromoChip("beach.umbrella.fill", "Leave")
                            organisationPromoChip("calendar.badge.clock", "Schedule")
                            Text("+3 more")
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(.white.opacity(0.9))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(Color.white.opacity(0.18))
                                .clipShape(Capsule())
                        }
                        .padding(.top, 4)
                    }
                    Image(systemName: "chevron.right")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.7))
                        .padding(.top, 4)
                }
            }
            .padding(18)
            .background(
                LinearGradient(
                    colors: [ProjectWorksRevampColors.blue, ProjectWorksRevampColors.blueLight],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .shadow(color: ProjectWorksRevampColors.blue.opacity(0.22), radius: 16, x: 0, y: 8)
        }
        .buttonStyle(.plain)
    }

    private func organisationPromoChip(_ systemImage: String, _ label: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: systemImage)
                .font(.system(size: 10, weight: .medium))
            Text(label)
                .font(.system(size: 10, weight: .medium))
        }
        .foregroundStyle(.white.opacity(0.95))
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Color.white.opacity(0.18))
        .clipShape(Capsule())
    }

    private var settingsHubSupportGroup: some View {
        VStack(spacing: 0) {
            NavigationLink {
                HelpView()
                    .environmentObject(appSettings)
            } label: {
                settingsHubRow(
                    icon: "questionmark.circle.fill",
                    iconBg: ProjectWorksRevampColors.activeGreen.opacity(0.15),
                    iconFg: ProjectWorksRevampColors.activeGreen,
                    title: "Help & support",
                    subtitle: "Get in touch, browse FAQs"
                )
            }
            .buttonStyle(.plain)
            Divider().background(ProjectWorksRevampColors.border).padding(.leading, 62)
            NavigationLink {
                PrivacyPolicyView(isAcceptanceRequired: .constant(false))
            } label: {
                settingsHubRow(
                    icon: "doc.text.fill",
                    iconBg: Color(red: 0.95, green: 0.95, blue: 0.96),
                    iconFg: ProjectWorksRevampColors.muted,
                    title: "Privacy & terms",
                    subtitle: "Legal information"
                )
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 4)
        .appChromeCardContainer(cornerRadius: 18)
    }

    private var settingsHubSignOut: some View {
        Button {
            showingSignOutAlert = true
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "rectangle.portrait.and.arrow.right")
                    .font(.system(size: 15, weight: .medium))
                Text("Sign out")
                    .font(.system(size: 13, weight: .medium))
            }
            .foregroundStyle(ProjectWorksRevampColors.requiredPillFg)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 13)
            .background(Color.white)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(ProjectWorksRevampColors.requiredPillBg, lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
    }
    
    private var manualLinkSheet: some View {
        NavigationView {
            Form {
                Section("Link to Organization") {
                    TextField("Organization ID", text: $manualLinkOrganizationId)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    
                    if let linkError = linkError {
                        Text(linkError)
                            .foregroundColor(.red)
                            .font(.caption)
                    }
                    
                    Button(action: {
                        Task {
                            await manuallyLinkToOrganization()
                        }
                    }) {
                        HStack {
                            Spacer()
                            if isLinking {
                                ProgressView()
                                Text("Linking...")
                            } else {
                                Text("Link")
                            }
                            Spacer()
                        }
                    }
                    .disabled(isLinking || manualLinkOrganizationId.isEmpty)
                }
                
                Section {
                    Text("Enter the Organization ID to link your account. This should only be used for troubleshooting if automatic linking fails.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .navigationTitle("Manual Link")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Cancel") {
                        showingManualLinkSheet = false
                        manualLinkOrganizationId = ""
                        linkError = nil
                    }
                }
            }
        }
    }

    private var notificationTestingSection: some View {
        Section("Notification Testing") {
            Text("Test notifications will appear 3 seconds after tapping.")
                .font(.caption)
                .foregroundColor(.secondary)

            if userStore.hasAdminAccess() || userStore.displayUser?.permissions.manager == true {
                Button(action: {
                    Task { await runTemporaryPushDiagnostic() }
                }) {
                    HStack {
                        Text("TEMP: Remote Push Diagnostic")
                        Spacer()
                        if isRunningPushDiagnostic {
                            ProgressView()
                        } else {
                            Image(systemName: "antenna.radiowaves.left.and.right")
                        }
                    }
                }
                .disabled(isRunningPushDiagnostic)
            }

            notificationTestButton(
                title: "Test Local Notification",
                type: .bookingCreated,
                details: "Project Planner notification test."
            )
        }
        .alert("Notification Test", isPresented: $showingNotificationTestAlert) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(notificationTestMessage)
        }
    }

    private func notificationTestButton(
        title: String,
        type: AppNotification.NotificationType,
        details: String
    ) -> some View {
        Button(action: {
            Task {
                await LocalNotificationService.shared.scheduleTestNotification(type: type, details: details)
                notificationTestMessage = "✅ Test notification scheduled! It will appear in 3 seconds."
                showingNotificationTestAlert = true
            }
        }) {
            HStack {
                Text(title)
                Spacer()
                Image(systemName: "bell")
            }
        }
    }
    
    private func diagnoseData() async {
        isDiagnosing = true
        diagnosticReport = await firebaseBackend.diagnoseMissingData()
        isDiagnosing = false
        showingDiagnosticReport = true
    }
    
    private func forceReloadData() async {
        isReloading = true
        await firebaseBackend.forceReloadOrganization()
        
        // Reload all stores
        Task {
            projectStore.loadData()
        }
        Task {
            operativeStore.loadData()
        }
        Task {
            bookingStore.loadData()
        }
        
        isReloading = false
    }
    
    private func seedPlaygroundDemo() async {
        isSeedingPlayground = true
        playgroundSeedMessage = nil
        let name = userStore.currentUser?.fullName ?? firebaseBackend.currentUser?.email ?? "Demo"
        do {
            let msg = try await PlaygroundDemoSeeder.seedIfNeeded(
                projectStore: projectStore,
                taskStore: taskStore,
                bookingStore: bookingStore,
                operativeStore: operativeStore,
                firebaseBackend: firebaseBackend,
                createdByName: name
            )
            playgroundSeedMessage = msg
        } catch {
            playgroundSeedMessage = error.localizedDescription
        }
        isSeedingPlayground = false
    }
    
    private func manuallyLinkToOrganization() async {
        isLinking = true
        linkError = nil
        
        let success = await firebaseBackend.manuallyLinkToOrganization(organizationId: manualLinkOrganizationId)
        
        if success {
            showingManualLinkSheet = false
            manualLinkOrganizationId = ""
            
            // Reload all stores
            Task {
                projectStore.loadData()
            }
            Task {
                operativeStore.loadData()
            }
            Task {
                bookingStore.loadData()
            }
        } else {
            linkError = "Failed to link to organization. Please check the Organization ID and try again."
        }
        
        isLinking = false
    }
    
    private var emailTestSheet: some View {
        NavigationView {
            Form {
                Section("Test Email Sending") {
                    Text("This will send a test password setup email to verify SendGrid is working correctly.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    
                    TextField("Test Email Address", text: $testEmailAddress)
                        .keyboardType(.emailAddress)
                        .autocapitalization(.none)
                        .autocorrectionDisabled()
                    
                    if let result = emailTestResult {
                        Text(result)
                            .font(.caption)
                            .foregroundColor(result.contains("✅") ? .green : .red)
                    }
                    
                    Button(action: {
                        Task {
                            await testEmailSending()
                        }
                    }) {
                        HStack {
                            Spacer()
                            if isTestingEmail {
                                ProgressView()
                                Text("Sending...")
                            } else {
                                Text("Send Test Email")
                            }
                            Spacer()
                        }
                    }
                    .disabled(isTestingEmail || testEmailAddress.isEmpty)
                }
                
                Section("Debug Info") {
                    Text("Check the console/Xcode logs for detailed Resend error messages. Look for lines starting with '📧' or '❌'.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                
                Section("Domain Status") {
                    Text("Using verified domain: info@projectplanner.us")
                        .font(.caption)
                        .foregroundColor(.green)
                    
                    Text("If emails fail, check:\n1. Resend dashboard → Domains (verify domain status)\n2. Resend dashboard → Logs (check delivery status)\n3. DNS records are properly configured")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                
                Section("Note") {
                    Text("This tests Resend email sending. The current 'Permission denied' error when creating users is a Firestore rules issue, not an email issue.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .navigationTitle("Test Email")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") {
                        showingEmailTest = false
                        testEmailAddress = ""
                        emailTestResult = nil
                    }
                }
            }
        }
    }
    
    private func testEmailSending() async {
        isTestingEmail = true
        emailTestResult = nil
        
        print("📧 TEST: Starting email test to: \(testEmailAddress)")
        
        let resendService = ResendEmailService()
        let testCode = UUID().uuidString.prefix(8).uppercased()
        let fromName = firebaseBackend.currentOrganization?.name
        
        let success = await resendService.sendPasswordSetupEmail(
            to: testEmailAddress,
            firstName: "Test",
            surname: "User",
            invitationCode: String(testCode),
            fromName: fromName
        )
        
        // Get the error message after the attempt
        let errorMessage = resendService.errorMessage
        
        await MainActor.run {
            if success {
                emailTestResult = "✅ Test email sent successfully!\n\nCheck your inbox at \(testEmailAddress).\nAlso check Resend dashboard → Logs to verify delivery.\n\nIf email doesn't arrive:\n1. Check spam folder\n2. Verify info@projectplanner.us domain is verified in Resend\n3. Check Resend Logs for delivery status"
                print("📧 TEST: ✅ Email sent successfully")
            } else {
                var resultMessage = "❌ Failed to send test email.\n\n"
                
                if let errorMessage = errorMessage, !errorMessage.isEmpty {
                    resultMessage += "Error: \(errorMessage)\n\n"
                }
                
                resultMessage += "Common issues:\n"
                resultMessage += "• 401 Unauthorized: API key is invalid or expired\n"
                resultMessage += "• 403 Forbidden: API key lacks permissions\n"
                resultMessage += "• 422 Unprocessable: Invalid email address or content\n"
                resultMessage += "• Network error: Check internet connection\n\n"
                resultMessage += "Next steps:\n"
                resultMessage += "1. Check Resend dashboard → Logs for detailed errors\n"
                resultMessage += "2. Verify API key in ResendEmailService.swift\n"
                resultMessage += "3. Check console logs for detailed error messages\n"
                resultMessage += "4. Visit https://resend.com to check your account status"
                
                emailTestResult = resultMessage
                print("📧 TEST: ❌ Email failed - \(errorMessage ?? "Unknown error")")
            }
            isTestingEmail = false
        }
    }

    private func runTemporaryPushDiagnostic() async {
        await MainActor.run {
            isRunningPushDiagnostic = true
        }
        let result = await notificationService.sendTemporaryPushDiagnosticToCurrentUser()
        await MainActor.run {
            notificationTestMessage = result
            showingNotificationTestAlert = true
            isRunningPushDiagnostic = false
        }
    }

    private func updateMaterialCutOffNotificationPreference(_ enabled: Bool) async {
        var updated = appSettings.settings.notifications
        updated.materialOrderCutOff = enabled
        await appSettings.updateNotifications(updated)
        await notificationService.refreshDailyMaterialCutOffReminder()
    }
    
    private func deleteAllOperatives() async {
        await MainActor.run {
            isDeletingAllOperatives = true
        }
        
        // Get all operatives (make a copy to avoid mutation during iteration)
        let allOperatives = await MainActor.run { Array(operativeStore.operatives) }
        let operativeCount = allOperatives.count
        
        if operativeCount == 0 {
            await MainActor.run {
                isDeletingAllOperatives = false
            }
            return
        }
        
        print("🔥🔥🔥 DEBUG: ========== DELETE ALL OPERATIVES START ==========")
        print("🔥🔥🔥 DEBUG: Deleting all \(operativeCount) operatives...")
        
        // Delete all operatives using OperativeStore's delete method (which handles bookings and Firebase)
        // This ensures proper cleanup and thread safety
        for operative in allOperatives {
            await operativeStore.deleteOperative(operative, bookingStore: bookingStore)
        }
        
        // Reload data to refresh UI
        await MainActor.run {
            operativeStore.loadData()
            bookingStore.loadData()
            isDeletingAllOperatives = false
        }
        
        print("🔥🔥🔥 DEBUG: ✅ Deleted all \(operativeCount) operatives")
        print("🔥🔥🔥 DEBUG: ========== DELETE ALL OPERATIVES COMPLETE ==========")
    }
    
    // MARK: - Delete Test Functionality
    
    private func testDeleteFunctionality() async {
        await MainActor.run {
            isTestingDelete = true
            deleteTestMessage = "Testing delete functionality..."
        }
        
        print("🔥🔥🔥 DEBUG: ========== DELETE TEST START ==========")
        
        // Test 1: Check current user permissions
        guard let currentUser = userStore.currentUser else {
            await MainActor.run {
                deleteTestMessage = "❌ No current user found"
                isTestingDelete = false
            }
            return
        }
        
        let hasPermission = currentUser.isSuperAdmin || currentUser.permissions.adminAccess
        print("🔥🔥🔥 DEBUG: Current user: \(currentUser.fullName)")
        print("🔥🔥🔥 DEBUG: Is Super Admin: \(currentUser.isSuperAdmin)")
        print("🔥🔥🔥 DEBUG: Has Admin Access: \(currentUser.permissions.adminAccess)")
        print("🔥🔥🔥 DEBUG: Has Permission to Delete: \(hasPermission)")
        
        if !hasPermission {
            await MainActor.run {
                deleteTestMessage = "❌ Current user does not have permission to delete users (must be admin or super admin)"
                isTestingDelete = false
            }
            return
        }
        
        // Test 2: Check if there are any users to test with
        await userStore.loadOrganizationUsers()
        let allUsers = await MainActor.run { userStore.organizationUsers }
        let deletableUsers = allUsers.filter { !$0.isSuperAdmin }
        
        print("🔥🔥🔥 DEBUG: Total users: \(allUsers.count)")
        print("🔥🔥🔥 DEBUG: Deletable users (non-super admin): \(deletableUsers.count)")
        
        if deletableUsers.isEmpty {
            await MainActor.run {
                deleteTestMessage = "⚠️ No deletable users found (only super admin exists)"
                isTestingDelete = false
            }
            return
        }
        
        // Test 3: Check Firebase backend
        guard firebaseBackend.isAuthenticated else {
            await MainActor.run {
                deleteTestMessage = "❌ Not authenticated with Firebase"
                isTestingDelete = false
            }
            return
        }
        
        print("🔥🔥🔥 DEBUG: Firebase backend authenticated: ✅")
        
        // Test 4: Check organization
        guard let organization = firebaseBackend.currentOrganization else {
            await MainActor.run {
                deleteTestMessage = "❌ No organization found"
                isTestingDelete = false
            }
            return
        }
        
        print("🔥🔥🔥 DEBUG: Organization: \(organization.name) (ID: \(organization.id))")
        
        // Test 5: Check Firestore connection and permissions
        let db = Firestore.firestore()
        do {
            // Try to read a user document to test permissions
            if let testUser = deletableUsers.first {
                let userDoc = try await db.collection("users").document(testUser.id).getDocument()
                print("🔥🔥🔥 DEBUG: Can read user document: \(userDoc.exists ? "✅" : "⚠️ (document doesn't exist)")")
                
                // Test if we can delete (check permissions without actually deleting)
                print("🔥🔥🔥 DEBUG: Testing delete permissions for user: \(testUser.fullName) (ID: \(testUser.id))")
                
                // Check if user has bookings
                let bookings = await MainActor.run { bookingStore.bookings }
                var userBookings: [Booking] = []
                for booking in bookings {
                    if testUser.permissions.operativeMode {
                        // For operatives, check if there's a matching operative
                        let operative = await MainActor.run { operativeStore.operatives.first(where: { $0.email.lowercased() == testUser.email.lowercased() }) }
                        if let operative = operative, booking.operativeId == operative.id {
                            userBookings.append(booking)
                        }
                    } else if testUser.permissions.manager || testUser.permissions.adminAccess {
                        if booking.bookedBy == testUser.fullName {
                            userBookings.append(booking)
                        }
                    }
                }
                
                print("🔥🔥🔥 DEBUG: User has \(userBookings.count) booking(s)")
                
                // Check if operative exists in OperativeStore
                var hasOperative = false
                if testUser.permissions.operativeMode {
                    hasOperative = await MainActor.run {
                        operativeStore.operatives.contains { $0.email.lowercased() == testUser.email.lowercased() }
                    }
                    print("🔥🔥🔥 DEBUG: Matching operative in OperativeStore: \(hasOperative ? "✅ Found" : "⚠️ Not found")")
                }
                
                await MainActor.run {
                    var message = "✅ Delete test results:\n"
                    message += "• Current user has permission: ✅\n"
                    message += "• Firebase authenticated: ✅\n"
                    message += "• Organization: ✅\n"
                    message += "• Can read user documents: ✅\n"
                    message += "• Test user: \(testUser.fullName)\n"
                    message += "• User type: \(testUser.permissions.operativeMode ? "Operative" : testUser.permissions.manager ? "Manager" : "Other")\n"
                    message += "• Bookings: \(userBookings.count)\n"
                    if testUser.permissions.operativeMode {
                        message += "• Operative in OperativeStore: \(hasOperative ? "✅" : "⚠️")\n"
                    }
                    message += "\n💡 Try deleting this user from Manage Users to test."
                    deleteTestMessage = message
                    isTestingDelete = false
                }
            } else {
                await MainActor.run {
                    deleteTestMessage = "⚠️ No test user found"
                    isTestingDelete = false
                }
            }
        } catch {
            print("🔥🔥🔥 DEBUG: ❌ Error testing Firestore: \(error.localizedDescription)")
            await MainActor.run {
                deleteTestMessage = "❌ Firestore error: \(error.localizedDescription)"
                isTestingDelete = false
            }
        }
        
        print("🔥🔥🔥 DEBUG: ========== DELETE TEST COMPLETE ==========")
    }
    
    private func updateUserName() {
        Task {
            await MainActor.run {
                isUpdatingUser = true
            }
            
            guard let currentUser = userStore.currentUser,
                  currentUser.email == "farnienelyt@gmail.com" else {
                await MainActor.run {
                    isUpdatingUser = false
                }
                return
            }
            
            var updatedUser = currentUser
            updatedUser.firstName = "Farnie"
            updatedUser.surname = "Nel"
            
            do {
                try await firebaseBackend.saveUser(updatedUser)
                await userStore.loadCurrentUser() // Reload to refresh UI
                print("🔥🔥🔥 DEBUG: ✅ Updated user name to Farnie Nel")
            } catch {
                print("🔥🔥🔥 DEBUG: ❌ Failed to update user name: \(error.localizedDescription)")
            }
            
            await MainActor.run {
                isUpdatingUser = false
            }
        }
    }
}

#Preview {
    SettingsView()
        .environmentObject(FirebaseBackend())
        .environmentObject(ProjectStore())
        .environmentObject(OperativeStore())
        .environmentObject(BookingStore())
        .environmentObject(ProjectTaskStore())
        .environmentObject(NotificationService())
        .environmentObject(UserStore())
        .environmentObject(AppSettingsStore())
}
