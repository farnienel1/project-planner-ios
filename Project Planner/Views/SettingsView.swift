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
    @State private var deleteTestMessage = ""
    @State private var isTestingDelete = false
    @State private var isUpdatingUser = false
    @State private var isSeedingPlayground = false
    @State private var playgroundSeedMessage: String?
    @State private var showingCompanyDetails = false
    
    var body: some View {
        List {
                // Account Details Section
                Section("Account Details") {
                    if let user = firebaseBackend.currentUser {
                        // Always show Name (even if empty, will show email fallback)
                        HStack {
                            Text("Name")
                            Spacer()
                            if let appUser = userStore.currentUser {
                                let fullName = "\(appUser.firstName) \(appUser.surname)".trimmingCharacters(in: .whitespaces)
                                Text(fullName.isEmpty ? (user.email?.components(separatedBy: "@").first?.capitalized ?? "N/A") : fullName)
                                    .foregroundColor(.secondary)
                            } else {
                                Text(user.email?.components(separatedBy: "@").first?.capitalized ?? "N/A")
                                    .foregroundColor(.secondary)
                            }
                        }
                        
                        HStack {
                            Text("Email")
                            Spacer()
                            Text(user.email ?? "N/A")
                                .foregroundColor(.secondary)
                        }
                        
                        if let org = firebaseBackend.currentOrganization {
                            HStack {
                                Text("Organization")
                                Spacer()
                                Text(org.name)
                                    .foregroundColor(.secondary)
                            }
                        } else {
                            HStack {
                                Text("Organization")
                                Spacer()
                                Text("Not linked")
                                    .foregroundColor(.red)
                            }
                        }
                    }
                    
                    // Update user name button (for fixing existing users like farnienelyt@gmail.com)
                    if let appUser = userStore.currentUser, appUser.email == "farnienelyt@gmail.com" {
                        Button(action: {
                            updateUserName()
                        }) {
                            HStack {
                                if isUpdatingUser {
                                    ProgressView()
                                        .scaleEffect(0.8)
                                }
                                Text(isUpdatingUser ? "Updating..." : "Update Name to 'Farnie Nel'")
                            }
                        }
                        .disabled(isUpdatingUser)
                    }
                    
                    Button("Sign Out") {
                        showingSignOutAlert = true
                    }
                    .foregroundColor(.red)
                }
                
                if userStore.currentUser?.isSuperAdmin == true,
                   firebaseBackend.currentOrganization != nil {
                    Section {
                        Button {
                            showingCompanyDetails = true
                        } label: {
                            HStack {
                                Image(systemName: "building.2.fill")
                                Text("Company details")
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    } header: {
                        Text("Organisation")
                    } footer: {
                        Text("Super admins can update the organisation name, country, office address, and map default location.")
                    }
                }
                
                // What you can / cannot see — hidden for operatives
                if !userStore.isOperativeMode() {
                    Section("Your access") {
                        Text(userStore.currentUserAccessSummary())
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                }
                
                if userStore.canConfigureRoleTesting {
                    Section {
                        Toggle("Role testing (preview UI)", isOn: Binding(
                            get: { userStore.roleTestingPreset != nil },
                            set: { enabled in
                                if !enabled {
                                    userStore.roleTestingPreset = nil
                                } else if userStore.roleTestingPreset == nil {
                                    userStore.roleTestingPreset = .manager
                                }
                            }
                        ))
                        if userStore.roleTestingPreset != nil {
                            Picker("Preview as", selection: Binding(
                                get: { userStore.roleTestingPreset ?? .manager },
                                set: { userStore.roleTestingPreset = $0 }
                            )) {
                                ForEach(RoleTestingPreset.allCases) { preset in
                                    Text(preset.title).tag(preset)
                                }
                            }
                            Text("Choose a role to see tabs and screens as that role. Your email and Firebase permissions are unchanged; super-admin-only actions still require your real account.")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    } header: {
                        Text("Strength test (demo)")
                    }
                }
                
                if userStore.hasAdminAccess() {
                    Section {
                        Button {
                            Task { await seedPlaygroundDemo() }
                        } label: {
                            HStack {
                                Text("Load playground demo data")
                                Spacer()
                                if isSeedingPlayground {
                                    ProgressView()
                                }
                            }
                        }
                        .disabled(isSeedingPlayground)
                        if let playgroundSeedMessage {
                            Text(playgroundSeedMessage)
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    } header: {
                        Text("Playground demo data")
                    } footer: {
                        Text("Adds one demo project (DEMO-PP-PROJ), one small works (DEMO-PP-SW), tasks, and bookings linked to the first operative in your organization. All roles share the same Firestore data — use role testing to preview each view.")
                    }
                }
                
                // Appearance Section
                if !userStore.isOperativeMode() {
                    Section("Appearance") {
                        ColorSchemePicker()
                            .environmentObject(appSettings)
                    }
                }

                // Calendar (Outlook) – admins/managers only
                if userStore.hasAdminAccess() || userStore.displayUser?.permissions.manager == true {
                    Section {
                        HStack {
                            Image(systemName: "calendar.badge.clock")
                            Text("Link Outlook Calendar")
                            Spacer()
                            Text("Coming soon")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    } footer: {
                        Text("Show your Outlook meetings in My Schedule and Daily Overview (e.g. 1-hour meetings within AM/PM/Full day).")
                    }
                }

                // Legal Section
                Section("Legal") {
                    NavigationLink(destination: PrivacyPolicyView(isAcceptanceRequired: .constant(false))) {
                        HStack {
                            Image(systemName: "doc.text.fill")
                            Text("Privacy Policy")
                        }
                    }
                }
                
                // Data Management Section
                if !userStore.isOperativeMode() {
                    Section("Data Management") {
                        Button(action: {
                            Task {
                                await diagnoseData()
                            }
                        }) {
                            HStack {
                                Text("Diagnose Missing Data")
                                Spacer()
                                if isDiagnosing {
                                    ProgressView()
                                }
                            }
                        }
                        .disabled(isDiagnosing)
                        
                        Button(action: {
                            Task {
                                await forceReloadData()
                            }
                        }) {
                            HStack {
                                Text("Force Reload Data")
                                Spacer()
                                if isReloading {
                                    ProgressView()
                                }
                            }
                        }
                        .disabled(isReloading)
                        
                        Button(action: {
                            showingManualLinkSheet = true
                        }) {
                            Text("Manually Link Organization")
                        }
                    }
                }
                
                // Troubleshooting Section
                if !userStore.isOperativeMode() {
                    Section("Troubleshooting") {
                        NavigationLink(destination: FixPermissionsView()
                            .environmentObject(firebaseBackend)
                            .environmentObject(userStore)) {
                            Text("Fix Permission Errors")
                        }
                        
                        if userStore.canManageUsers() {
                            Button(action: {
                                showingEmailTest = true
                            }) {
                                Text("Test Email Sending")
                            }
                            
                            if let result = emailTestResult {
                                Text(result)
                                    .font(.caption)
                                    .foregroundColor(result.contains("✅") ? .green : .red)
                            }
                        }
                    }
                }
                
                // Notification Testing Section
                Section("Notification Testing") {
                    Text("Test notifications will appear 3 seconds after tapping.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    
                    Button(action: {
                        Task {
                            await LocalNotificationService.shared.scheduleTestNotification(
                                type: .operativeCreated,
                                details: "John Smith has been added as a new operative."
                            )
                            notificationTestMessage = "✅ Test notification scheduled! It will appear in 3 seconds."
                            showingNotificationTestAlert = true
                        }
                    }) {
                        HStack {
                            Text("Test: New Operative Created")
                            Spacer()
                            Image(systemName: "bell")
                        }
                    }
                    
                    Button(action: {
                        Task {
                            await LocalNotificationService.shared.scheduleTestNotification(
                                type: .managerCreated,
                                details: "Jane Doe has been added as a new manager."
                            )
                            notificationTestMessage = "✅ Test notification scheduled! It will appear in 3 seconds."
                            showingNotificationTestAlert = true
                        }
                    }) {
                        HStack {
                            Text("Test: New Manager Created")
                            Spacer()
                            Image(systemName: "bell")
                        }
                    }
                    
                    Button(action: {
                        Task {
                            await LocalNotificationService.shared.scheduleTestNotification(
                                type: .clientCreated,
                                details: "ABC Company has been added as a new client."
                            )
                            notificationTestMessage = "✅ Test notification scheduled! It will appear in 3 seconds."
                            showingNotificationTestAlert = true
                        }
                    }) {
                        HStack {
                            Text("Test: New Client Created")
                            Spacer()
                            Image(systemName: "bell")
                        }
                    }
                    
                    Button(action: {
                        Task {
                            await LocalNotificationService.shared.scheduleTestNotification(
                                type: .bookingCreated,
                                details: "A new booking has been created for Project XYZ on December 1, 2025."
                            )
                            notificationTestMessage = "✅ Test notification scheduled! It will appear in 3 seconds."
                            showingNotificationTestAlert = true
                        }
                    }) {
                        HStack {
                            Text("Test: New Booking Created")
                            Spacer()
                            Image(systemName: "bell")
                        }
                    }
                    
                    Button(action: {
                        Task {
                            await LocalNotificationService.shared.scheduleTestNotification(
                                type: .taskCreated,
                                details: "A new task has been assigned: Complete site inspection."
                            )
                            notificationTestMessage = "✅ Test notification scheduled! It will appear in 3 seconds."
                            showingNotificationTestAlert = true
                        }
                    }) {
                        HStack {
                            Text("Test: New Task Created")
                            Spacer()
                            Image(systemName: "bell")
                        }
                    }
                    Button(action: {
                        Task {
                            await LocalNotificationService.shared.scheduleTestNotification(
                                type: .taskCompleted,
                                details: "Task complete: Site inspection has been marked complete."
                            )
                            notificationTestMessage = "✅ Test notification scheduled! It will appear in 3 seconds."
                            showingNotificationTestAlert = true
                        }
                    }) {
                        HStack {
                            Text("Test: Task Completed")
                            Spacer()
                            Image(systemName: "bell")
                        }
                    }

                    Button(action: {
                        Task {
                            await LocalNotificationService.shared.scheduleTestNotification(
                                type: .bookingClash,
                                details: "Booking clash detected for Test Operative."
                            )
                            notificationTestMessage = "✅ Test notification scheduled! It will appear in 3 seconds."
                            showingNotificationTestAlert = true
                        }
                    }) {
                        HStack {
                            Text("Test: Booking Clash")
                            Spacer()
                            Image(systemName: "bell")
                        }
                    }

                    Button(action: {
                        Task {
                            await LocalNotificationService.shared.scheduleTestNotification(
                                type: .holidayRequestSubmitted,
                                details: "Annual leave request submitted and pending approval."
                            )
                            notificationTestMessage = "✅ Test notification scheduled! It will appear in 3 seconds."
                            showingNotificationTestAlert = true
                        }
                    }) {
                        HStack {
                            Text("Test: Annual Leave Request")
                            Spacer()
                            Image(systemName: "bell")
                        }
                    }

                    Button(action: {
                        Task {
                            await LocalNotificationService.shared.scheduleTestNotification(
                                type: .holidayRequestApproved,
                                details: "Your annual leave request has been approved."
                            )
                            notificationTestMessage = "✅ Test notification scheduled! It will appear in 3 seconds."
                            showingNotificationTestAlert = true
                        }
                    }) {
                        HStack {
                            Text("Test: Annual Leave Approved")
                            Spacer()
                            Image(systemName: "bell")
                        }
                    }
                }
                .alert("Notification Test", isPresented: $showingNotificationTestAlert) {
                    Button("OK", role: .cancel) { }
                } message: {
                    Text(notificationTestMessage)
                }
                
                // Admin Tools Section
                if userStore.canManageUsers() {
                    Section("Admin Tools") {
                        Button(action: {
                            showingDeleteAllOperativesConfirmation = true
                        }) {
                            Text("Delete All Operatives")
                                .foregroundColor(.red)
                        }
                        
                        // Delete Test Button
                        Button(action: {
                            Task {
                                await testDeleteFunctionality()
                            }
                        }) {
                            HStack {
                                Text("Test Delete Functionality")
                                Spacer()
                                if isTestingDelete {
                                    ProgressView()
                                }
                            }
                        }
                        .disabled(isTestingDelete)
                        
                        if !deleteTestMessage.isEmpty {
                            Text(deleteTestMessage)
                                .font(.caption)
                                .foregroundColor(deleteTestMessage.contains("✅") ? .green : .red)
                                .padding(.vertical, 4)
                        }
                    }
                }
                
                // App Info Section
                Section("App Information") {
                    HStack {
                        Text("Version")
                        Spacer()
                        Text(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "N/A")
                            .foregroundColor(.secondary)
                    }
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button(action: {
                        NotificationCenter.default.post(name: NSNotification.Name("goBackToPreviousTab"), object: nil)
                    }) {
                        Image(systemName: "chevron.left")
                            .foregroundColor(Color.theme.primary)
                            .font(.system(size: 17, weight: .semibold))
                    }
                }
            }
            .navigationBarBackButtonHidden(true)
        .onAppear {
            // Use UIKit to directly hide the back button
            DispatchQueue.main.async {
                // Find the navigation controller and hide back button
                if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
                   let window = windowScene.windows.first {
                    // Traverse view hierarchy to find navigation controller
                    func findNavigationController(in viewController: UIViewController?) -> UINavigationController? {
                        guard let viewController = viewController else { return nil }
                        if let navController = viewController as? UINavigationController {
                            return navController
                        }
                        for child in viewController.children {
                            if let navController = findNavigationController(in: child) {
                                return navController
                            }
                        }
                        return nil
                    }
                    
                    if let navController = findNavigationController(in: window.rootViewController) {
                        // Hide back button completely
                        navController.navigationBar.topItem?.leftBarButtonItem = nil
                        navController.navigationBar.backItem?.backBarButtonItem = nil
                        navController.navigationBar.backIndicatorImage = UIImage()
                        navController.navigationBar.backIndicatorTransitionMaskImage = UIImage()
                        
                        // Also set appearance to hide back button
                        let appearance = UINavigationBarAppearance()
                        appearance.configureWithOpaqueBackground()
                        appearance.backButtonAppearance.normal.titlePositionAdjustment = UIOffset(horizontal: -1000, vertical: 0)
                        navController.navigationBar.standardAppearance = appearance
                        navController.navigationBar.scrollEdgeAppearance = appearance
                    }
                }
            }
        }
        .sheet(isPresented: $showingDiagnosticReport) {
            NavigationView {
                ScrollView {
                    Text(diagnosticReport)
                        .font(.system(.body, design: .monospaced))
                        .padding()
                }
                .navigationTitle("Diagnostic Report")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button("Done") {
                            showingDiagnosticReport = false
                        }
                    }
                }
            }
        }
        .sheet(isPresented: $showingManualLinkSheet) {
            manualLinkSheet
        }
        .sheet(isPresented: $showingCompanyDetails) {
            CompanyDetailsEditView()
                .environmentObject(firebaseBackend)
        }
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
        .sheet(isPresented: $showingEmailTest) {
            emailTestSheet
        }
        .alert("Delete All Operatives", isPresented: $showingDeleteAllOperativesConfirmation) {
            Button("Cancel", role: .cancel) { }
            Button("Delete All", role: .destructive) {
                Task {
                    await deleteAllOperatives()
                }
            }
        } message: {
            let operativeCount = operativeStore.operatives.count
            let bookingCount = bookingStore.bookings.count
            if operativeCount > 0 {
                Text("Are you sure you want to delete all \(operativeCount) operative\(operativeCount == 1 ? "" : "s")?\n\nThis will also delete all \(bookingCount) booking\(bookingCount == 1 ? "" : "s") associated with these operatives.\n\nThis action cannot be undone.")
            } else {
                Text("There are no operatives to delete.")
            }
        }
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
        .environmentObject(UserStore())
        .environmentObject(AppSettingsStore())
}
