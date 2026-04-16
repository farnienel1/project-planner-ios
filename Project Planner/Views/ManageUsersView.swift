//
//  ManageUsersView.swift
//  Project Planner
//
//  Created by Assistant on 24/10/2025.
//

import SwiftUI
import FirebaseFirestore

struct ManageUsersView: View {
    @EnvironmentObject var userStore: UserStore
    @EnvironmentObject var bookingStore: BookingStore
    @EnvironmentObject var operativeStore: OperativeStore
    @EnvironmentObject var holidayStore: HolidayStore
    @Environment(\.dismiss) private var dismiss
    
    @State private var showingAddUser = false
    @State private var selectedUser: AppUser?
    @State private var showingEditUser = false
    @State private var userToDelete: AppUser?
    @State private var showingDeleteConfirmation = false
    @State private var selectedTab = 0 // 0: Admins, 1: Managers, 2: Operatives
    @State private var rosterSegment: UserRosterSegment = .active
    @State private var userToSendSignUpEmail: AppUser?
    @State private var isSendingSignUpEmail = false
    @State private var signUpEmailMessage: String?
    
    var initialTab: Int = 0
    var userToHighlight: AppUser? = nil

    private var isManagerOperativeManagement: Bool {
        guard let u = userStore.displayUser else { return false }
        if u.permissions.operativeMode { return false }
        if userStore.hasAdminAccess() { return false }
        return u.permissions.manager && u.permissions.operatives
    }
    
    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if !userStore.canManageUsers() {
                    if isManagerOperativeManagement {
                        // Managers with Operative Management can manage operatives only
                        VStack(spacing: 0) {
                            Picker("", selection: $rosterSegment) {
                                ForEach(UserRosterSegment.allCases) { seg in
                                    Text(seg.title).tag(seg)
                                }
                            }
                            .pickerStyle(SegmentedPickerStyle())
                            .padding(.horizontal, 20)
                            .padding(.vertical, 8)
                            .background(Color(.systemGroupedBackground))
                            
                            operativesList
                        }
                    } else {
                        // Only admins can manage users – hide content from everyone else
                        manageUsersAccessDeniedView
                    }
                } else if userStore.organizationUsers.isEmpty {
                    emptyStateView
                } else {
                    // Tab Selector
                    tabSelector
                    
                    // Active / Inactive / Pending filter for current tab
                    Picker("", selection: $rosterSegment) {
                        ForEach(UserRosterSegment.allCases) { segment in
                            Text(segment.title).tag(segment)
                        }
                    }
                    .pickerStyle(SegmentedPickerStyle())
                    .padding(.horizontal, 20)
                    .padding(.vertical, 8)
                    .background(Color(.systemGroupedBackground))
                    
                    // Tab Content
                    tabContent
                    
                    // Links to Operatives and Managers pages (same data, different tab)
                    HStack(spacing: 12) {
                        Button(action: {
                            dismiss()
                            NotificationCenter.default.post(
                                name: NSNotification.Name("dismissManageUsersAndSelectTab"),
                                object: nil,
                                userInfo: ["tab": 3]
                            )
                        }) {
                            Label("View on Operatives page", systemImage: "person.3.fill")
                                .font(.subheadline)
                        }
                        .buttonStyle(.bordered)
                        if userStore.hasAdminAccess() {
                            Button(action: {
                                dismiss()
                                NotificationCenter.default.post(
                                    name: NSNotification.Name("dismissManageUsersAndSelectTab"),
                                    object: nil,
                                    userInfo: ["tab": 4]
                                )
                            }) {
                                Label("View on Managers page", systemImage: "person.badge.key.fill")
                                    .font(.subheadline)
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 12)
                    .background(Color(.systemGroupedBackground))
                }
            }
            .navigationTitle(isManagerOperativeManagement && !userStore.canManageUsers() ? "Manage Operatives" : "Manage Users")
            .navigationBarTitleDisplayMode(.inline)
            .task {
                // Always load fresh from Firebase when opening so deleted-in-console users disappear
                await userStore.loadOrganizationUsers()
            }
            .refreshable {
                await userStore.loadOrganizationUsers()
            }
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Done") {
                        dismiss()
                    }
                }
                
                if userStore.canManageUsers() || isManagerOperativeManagement {
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button(isManagerOperativeManagement && !userStore.canManageUsers() ? "Add Operative" : "Add User") {
                            showingAddUser = true
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.indigo)
                    }
                }
            }
            .sheet(isPresented: $showingAddUser) {
                AddUserView(mode: (isManagerOperativeManagement && !userStore.canManageUsers()) ? .managerAddingOperative : .admin)
                    .environmentObject(userStore)
            }
            .sheet(item: $selectedUser) { user in
                EditUserView(user: user)
                    .environmentObject(userStore)
                    .environmentObject(bookingStore)
                    .environmentObject(operativeStore)
                    .environmentObject(holidayStore)
            }
            .alert("Delete User", isPresented: $showingDeleteConfirmation) {
                Button("Cancel", role: .cancel) {
                    userToDelete = nil
                }
                Button("Delete", role: .destructive) {
                    if let user = userToDelete {
                        if userStore.canDeleteUser(user) {
                            Task {
                                print("🔥🔥🔥 DEBUG: Delete button tapped for user: \(user.fullName)")
                                await userStore.deleteUser(user, bookingStore: bookingStore, operativeStore: operativeStore)
                                await userStore.loadOrganizationUsers()
                                await MainActor.run {
                                    userToDelete = nil
                                }
                            }
                        }
                    }
                }
            } message: {
                if let user = userToDelete {
                    if !userStore.canDeleteUser(user) {
                        Text("Cannot delete the organization creator.")
                    } else {
                        let isManager = user.permissions.manager || user.permissions.adminAccess
                        let isOperative = user.permissions.operativeMode
                        
                        if isManager {
                            let bookingCount = bookingStore.bookings.filter { $0.bookedBy == user.fullName }.count
                            if bookingCount > 0 {
                                Text("Are you sure you want to delete \(user.fullName)?\n\nThis manager has \(bookingCount) booking\(bookingCount == 1 ? "" : "s"). All bookings will be reassigned to the super admin.\n\nThis action cannot be undone.")
                            } else {
                                Text("Are you sure you want to delete \(user.fullName)? This action cannot be undone.")
                            }
                        } else if isOperative {
                            // Count bookings for this operative (by operativeId matching user email or name)
                            let operativeBookings = bookingStore.bookings.filter { booking in
                                // Try to match by finding operative with matching email
                                if let operative = operativeStore.operatives.first(where: { $0.email.lowercased() == user.email.lowercased() }) {
                                    return booking.operativeId == operative.id
                                }
                                return false
                            }
                            let bookingCount = operativeBookings.count
                            
                            if bookingCount > 0 {
                                Text("Are you sure you want to delete \(user.fullName)?\n\nThis operative has \(bookingCount) booking\(bookingCount == 1 ? "" : "s") that will be deleted.\n\nThis action cannot be undone.")
                            } else {
                                Text("Are you sure you want to delete \(user.fullName)?\n\nThis will delete the operative and all associated data.\n\nThis action cannot be undone.")
                            }
                        } else {
                            Text("Are you sure you want to delete \(user.fullName)? This action cannot be undone.")
                        }
                    }
                }
            }
        }
        .task {
            await userStore.loadOrganizationUsers()
            // Set initial tab if provided
            if initialTab >= 0 && initialTab <= 2 {
                selectedTab = initialTab
            }
            // Scroll to highlighted user if provided
            if let userToHighlight = userToHighlight {
                selectedUser = userToHighlight
                // Small delay to ensure list is rendered
                try? await Task.sleep(nanoseconds: 300_000_000) // 0.3 seconds
            }
        }
        .onAppear {
            // Set initial tab if provided
            if initialTab >= 0 && initialTab <= 2 {
                selectedTab = initialTab
            }
        }
        .onChange(of: selectedTab) { oldValue, newValue in
            rosterSegment = .active
        }
        .onChange(of: showingAddUser) { oldValue, newValue in
            // Reload users when add user sheet is dismissed
            if !newValue {
                Task {
                    print("🔥🔥🔥 DEBUG: Add user sheet dismissed, reloading users...")
                    await userStore.loadOrganizationUsers()
                }
            }
        }
        .refreshable {
            await userStore.loadOrganizationUsers()
        }
    }
    
    // MARK: - Access Denied (non-admins)
    
    private var manageUsersAccessDeniedView: some View {
        VStack(spacing: 24) {
            Spacer()
            Image(systemName: "lock.shield.fill")
                .font(.system(size: 56))
                .foregroundColor(.secondary)
            Text("Manage Users")
                .font(.title2)
                .fontWeight(.bold)
            Text("Only users with admin access can manage users. If you need access, ask an administrator.")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
            Spacer()
        }
        .padding(20)
    }
    
    // MARK: - Empty State
    
    private var emptyStateView: some View {
        VStack(spacing: 24) {
            Spacer()
            
            Image(systemName: "person.3")
                .font(.system(size: 60))
                .foregroundColor(.gray)
            
            VStack(spacing: 8) {
                Text("No Users Yet")
                    .font(.title2)
                    .fontWeight(.bold)
                
                Text("Add your first user to get started")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
            
            Button("Add First User") {
                showingAddUser = true
            }
            .buttonStyle(.borderedProminent)
            .tint(.indigo)
            
            Spacer()
        }
        .padding(20)
    }
    
    // MARK: - Tab Selector
    
    private var tabSelector: some View {
        HStack(spacing: 0) {
            TabButton(title: "Admins", isSelected: selectedTab == 0) {
                selectedTab = 0
            }
            
            TabButton(title: "Managers", isSelected: selectedTab == 1) {
                selectedTab = 1
            }
            
            TabButton(title: "Operatives", isSelected: selectedTab == 2) {
                selectedTab = 2
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(Color(.systemGroupedBackground))
    }
    
    // MARK: - Tab Content
    
    private var tabContent: some View {
        Group {
            switch selectedTab {
            case 0:
                adminsList
            case 1:
                managersList
            case 2:
                operativesList
            default:
                EmptyView()
            }
        }
    }
    
    // MARK: - Filtered Lists
    
    private var adminsList: some View {
        let admins = userStore.organizationUsers.filter { user in
            (user.permissions.adminAccess || user.isSuperAdmin) && rosterSegment.matches(user)
        }
        return List {
            ForEach(admins) { user in
                ManageUserRowView(user: user, showAdminBadge: false) {
                    selectedUser = user
                }
                .environmentObject(userStore)
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    if userStore.canDeleteUser(user) {
                        Button(role: .destructive, action: {
                            userToDelete = user
                            showingDeleteConfirmation = true
                        }) {
                            Label("Delete", systemImage: "trash")
                        }
                    }
                }
            }
        }
        .listStyle(PlainListStyle())
    }
    
    private var managersList: some View {
        let managers = userStore.organizationUsers.filter { user in
            let isManager = (user.permissions.adminAccess || user.isSuperAdmin) || user.permissions.manager
            return isManager && rosterSegment.matches(user)
        }
        return List {
            ForEach(managers) { user in
                ManageUserRowView(user: user, showAdminBadge: user.permissions.adminAccess || user.isSuperAdmin) {
                    selectedUser = user
                }
                .environmentObject(userStore)
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    if userStore.canDeleteUser(user) {
                        Button(role: .destructive, action: {
                            userToDelete = user
                            showingDeleteConfirmation = true
                        }) {
                            Label("Delete", systemImage: "trash")
                        }
                    }
                }
            }
        }
        .listStyle(PlainListStyle())
    }
    
    private var operativesList: some View {
        let operatives = userStore.organizationUsers.filter { user in
            user.permissions.operativeMode && rosterSegment.matches(user)
        }
        return List {
            ForEach(operatives) { user in
                ManageUserRowView(user: user, showAdminBadge: false) {
                    selectedUser = user
                }
                .environmentObject(userStore)
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    if userStore.canDeleteUser(user) {
                        Button(role: .destructive, action: {
                            userToDelete = user
                            showingDeleteConfirmation = true
                        }) {
                            Label("Delete", systemImage: "trash")
                        }
                    }
                }
            }
        }
        .listStyle(PlainListStyle())
    }
}

// MARK: - User Row View

struct ManageUserRowView: View {
    @EnvironmentObject var userStore: UserStore
    
    let user: AppUser
    var showAdminBadge: Bool = false
    let onTap: () -> Void
    
    @State private var isSendingSignUpEmail = false
    @State private var isSendingResetPassword = false
    @State private var rowEmailFeedback: String?
    
    // Check if current user is admin/super admin
    private var canSendSignUpEmail: Bool {
        guard let currentUser = userStore.displayUser else { return false }
        return currentUser.isSuperAdmin || currentUser.permissions.adminAccess
    }
    
    // Check if this user is a manager or operative (not admin)
    private var isManagerOrOperative: Bool {
        return (user.permissions.manager || user.permissions.operativeMode) && !user.permissions.adminAccess && !user.isSuperAdmin
    }
    
    /// Password reset on the row: anyone who has completed signup, except only a super admin may reset another super admin.
    private var canShowPasswordResetOnRow: Bool {
        guard user.passwordSet else { return false }
        if user.isSuperAdmin {
            return userStore.currentUser?.isSuperAdmin == true
        }
        return true
    }
    
    var body: some View {
        HStack(spacing: 12) {
            // Avatar
            Circle()
                .fill(user.isActive ? Color.indigo : Color.gray)
                .frame(width: 50, height: 50)
                .overlay(
                    Text(user.firstName.prefix(1) + user.surname.prefix(1))
                        .font(.headline)
                        .foregroundColor(.white)
                )
            
            // User Info
            VStack(alignment: .leading, spacing: 4) {
                Text(user.fullName)
                    .font(.headline)
                    .foregroundColor(.primary)
                
                Text(user.email)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                
                HStack {
                    Text(user.role.displayName)
                        .font(.caption)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(roleColor.opacity(0.2))
                        .foregroundColor(roleColor)
                        .cornerRadius(8)
                    
                    if showAdminBadge {
                        Text("Admin")
                            .font(.caption)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Color.green.opacity(0.2))
                            .foregroundColor(.green)
                            .cornerRadius(8)
                    }
                    
                    if !user.isActive {
                        Text("Inactive")
                            .font(.caption)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Color.red.opacity(0.2))
                            .foregroundColor(.red)
                            .cornerRadius(8)
                    }
                    
                    if user.passwordSet {
                        Text("Verified")
                            .font(.caption)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Color.green.opacity(0.2))
                            .foregroundColor(.green)
                            .cornerRadius(8)
                    } else {
                        Text("Pending")
                            .font(.caption)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Color.orange.opacity(0.2))
                            .foregroundColor(.orange)
                            .cornerRadius(8)
                    }
                }
            }
            
            Spacer()
            
            // Pending: resend sign-up / verification only. Verified: password reset only (no conflicting actions).
            if canSendSignUpEmail && !user.passwordSet && isManagerOrOperative {
                Button(action: {
                    sendSignUpEmail()
                }) {
                    if isSendingSignUpEmail {
                        ProgressView()
                            .scaleEffect(0.8)
                    } else {
                        Image(systemName: "envelope.badge.fill")
                            .foregroundColor(.blue)
                            .font(.body)
                    }
                }
                .disabled(isSendingSignUpEmail || isSendingResetPassword)
                .padding(.trailing, 8)
                .accessibilityLabel("Resend sign-up email with verification code")
            } else if canSendSignUpEmail && canShowPasswordResetOnRow {
                Button(action: {
                    sendPasswordResetFromRow()
                }) {
                    if isSendingResetPassword {
                        ProgressView()
                            .scaleEffect(0.8)
                    } else {
                        Image(systemName: "key.fill")
                            .foregroundColor(.indigo)
                            .font(.body)
                    }
                }
                .disabled(isSendingResetPassword || isSendingSignUpEmail)
                .padding(.trailing, 8)
                .accessibilityLabel("Send password reset email")
            }
            
            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundColor(.gray)
        }
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .onTapGesture {
            onTap()
        }
        .alert("Email", isPresented: .constant(rowEmailFeedback != nil)) {
            Button("OK") {
                rowEmailFeedback = nil
            }
        } message: {
            if let message = rowEmailFeedback {
                Text(message)
            }
        }
    }
    
    private func sendSignUpEmail() {
        isSendingSignUpEmail = true
        rowEmailFeedback = nil

        Task {
            let db = Firestore.firestore()
            do {
                // Mark all existing invitations for this email as used so only the new link works
                let existing = try await db.collection("invitations")
                    .whereField("email", isEqualTo: user.email)
                    .getDocuments()
                for doc in existing.documents {
                    try? await doc.reference.updateData(["isUsed": true])
                }

                // Always create a brand new invitation (never reuse old link)
                let invitationId = UUID().uuidString
                var invitationData: [String: Any] = [
                    "email": user.email,
                    "organizationId": user.organizationId,
                    "invitedBy": userStore.currentUser?.email ?? "System",
                    "firstName": user.firstName,
                    "surname": user.surname,
                    "permissions": [
                        "adminAccess": user.permissions.adminAccess,
                        "manager": user.permissions.manager,
                        "operatives": user.permissions.operatives,
                        "skills": user.permissions.skills,
                        "qualifications": user.permissions.qualifications,
                        "projects": user.permissions.projects,
                        "smallWorks": user.permissions.smallWorks,
                        "operativeMode": user.permissions.operativeMode
                    ],
                    "createdAt": Timestamp(date: Date()),
                    "isUsed": false
                ]
                if let mobileNumber = user.mobileNumber {
                    invitationData["mobileNumber"] = mobileNumber
                }
                try await db.collection("invitations").document(invitationId).setData(invitationData)

                let success = await userStore.sendSignUpEmailWithVerification(
                    email: user.email,
                    firstName: user.firstName,
                    surname: user.surname,
                    invitationId: invitationId
                )

                await MainActor.run {
                    isSendingSignUpEmail = false
                    if success {
                        rowEmailFeedback = "✅ Sign-up email with verification code sent successfully to \(user.email)"
                    } else {
                        rowEmailFeedback = "❌ Failed to send sign-up email. Please try again."
                    }
                }
            } catch {
                await MainActor.run {
                    isSendingSignUpEmail = false
                    rowEmailFeedback = "❌ Error: \(error.localizedDescription)"
                }
            }
        }
    }
    
    private func sendPasswordResetFromRow() {
        isSendingResetPassword = true
        rowEmailFeedback = nil
        Task {
            let success = await userStore.sendPasswordResetEmail(to: user.email)
            await MainActor.run {
                isSendingResetPassword = false
                rowEmailFeedback = success
                    ? "✅ Password reset email sent to \(user.email)."
                    : "❌ Failed to send password reset email."
            }
        }
    }
    
    private var roleColor: Color {
        switch user.role {
        case .admin: return .red
        case .manager: return .blue
        case .operative: return .green
        case .viewer: return .gray
        case .basic: return .orange
        }
    }
}

// MARK: - Edit User View

struct EditUserView: View {
    @EnvironmentObject var userStore: UserStore
    @EnvironmentObject var bookingStore: BookingStore
    @EnvironmentObject var operativeStore: OperativeStore
    @EnvironmentObject var holidayStore: HolidayStore
    @Environment(\.dismiss) private var dismiss
    
    let user: AppUser
    @State private var permissions: UserPermissions
    @State private var isUpdating = false
    @State private var isActive: Bool
    @State private var showingDeleteConfirmation = false
    @State private var isResendingEmail = false
    @State private var resendEmailMessage: String?
    @State private var isSendingSignUpEmail = false
    @State private var signUpEmailMessage: String?
    @State private var isSendingResetPassword = false
    @State private var resetPasswordMessage: String?
    @State private var isTransferringSuperAdmin = false
    @State private var transferSuperAdminMessage: String?
    @State private var isUpdatingActiveStatus = false
    @State private var activeStatusMessage: String?
    @State private var showingHolidayReport = false
    
    init(user: AppUser) {
        self.user = user
        self._permissions = State(initialValue: user.permissions)
        self._isActive = State(initialValue: user.isActive)
    }
    
    // Check if current user is admin/super admin
    private var canEdit: Bool {
        guard let currentUser = userStore.displayUser else { return false }
        return currentUser.isSuperAdmin || currentUser.permissions.adminAccess
    }
    
    // Check if any changes have been made
    private var hasChanges: Bool {
        permissions != user.permissions || isActive != user.isActive
    }
    
    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 0) {
                    // User Info Header
                    userInfoHeader
                    
                    // User Details Section
                    userDetailsSection
                    
                    // Active/Inactive — all admin-editable accounts (admins were missing this before)
                    if canEdit {
                        activeToggleSection
                    }
                    
                    // Permissions
                    permissionsSection
                    
                    // Reset password / Send sign-up (no "Verification" heading) + Delete user
                    if canEdit {
                        actionsSection
                    }
                }
            }
            .navigationTitle("Edit User")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
                
                ToolbarItem(placement: .navigationBarTrailing) {
                    if canEdit {
                        Button("Save") {
                            saveChanges()
                        }
                        .disabled(isUpdating || !hasChanges)
                        .foregroundColor(hasChanges ? .blue : .gray)
                    }
                }
            }
            .alert("Delete User", isPresented: $showingDeleteConfirmation) {
                Button("Cancel", role: .cancel) { }
                Button("Delete", role: .destructive) {
                    deleteUser()
                }
            } message: {
                let isManager = user.permissions.manager || user.permissions.adminAccess
                if isManager {
                    let bookingCount = bookingStore.bookings.filter { $0.bookedBy == user.fullName }.count
                    if bookingCount > 0 {
                        Text("Are you sure you want to delete \(user.fullName)?\n\nThis manager has \(bookingCount) booking\(bookingCount == 1 ? "" : "s"). All bookings will be reassigned to the super admin.\n\nThis action cannot be undone.")
                    } else {
                        Text("Are you sure you want to delete \(user.fullName)? This action cannot be undone.")
                    }
                } else {
                    Text("Are you sure you want to delete \(user.fullName)? This action cannot be undone.")
                }
            }
        }
        .sheet(isPresented: $showingHolidayReport) {
            HolidayReportView(user: user)
                .environmentObject(holidayStore)
                .environmentObject(operativeStore)
        }
    }
    
    private var userInfoHeader: some View {
        VStack(spacing: 16) {
            Circle()
                .fill(user.isActive ? Color.indigo : Color.gray)
                .frame(width: 80, height: 80)
                .overlay(
                    Text(user.firstName.prefix(1) + user.surname.prefix(1))
                        .font(.title)
                        .foregroundColor(.white)
                )
            
            VStack(spacing: 4) {
                Text(user.fullName)
                    .font(.title2)
                    .fontWeight(.bold)
                
                Text(user.email)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                
                HStack(spacing: 8) {
                    Text(user.role.displayName)
                        .font(.caption)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Color.indigo.opacity(0.2))
                        .foregroundColor(.indigo)
                        .cornerRadius(12)
                    
                    // Pending/Verified Status
                    if !user.passwordSet {
                        Text("Pending")
                            .font(.caption)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(Color.orange.opacity(0.2))
                            .foregroundColor(.orange)
                            .cornerRadius(12)
                    } else {
                        Text("Verified")
                            .font(.caption)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(Color.green.opacity(0.2))
                            .foregroundColor(.green)
                            .cornerRadius(12)
                    }
                }
            }
        }
        .padding(20)
        .background(Color(.systemGroupedBackground))
    }
    
    private var userDetailsSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("User Details")
                .font(.headline)
                .padding(.horizontal, 20)
                .padding(.top, 20)
            
            VStack(spacing: 12) {
                DetailRow(label: "Email", value: user.email)
                if let mobileNumber = user.mobileNumber, !mobileNumber.isEmpty {
                    DetailRow(label: "Mobile Number", value: mobileNumber)
                }
                DetailRow(label: "Status", value: user.isActive ? "Active" : "Inactive")
            }
            .padding(.horizontal, 20)
        }
    }
    
    private var activeToggleSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Account Status")
                .font(.headline)
                .padding(.horizontal, 20)
                .padding(.top, 20)
            
            HStack {
                Text("Active")
                    .font(.body)
                Spacer()
                Toggle("", isOn: $isActive)
                    .labelsHidden()
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .background(Color(.systemBackground))
            .cornerRadius(12)
            .padding(.horizontal, 20)
        }
    }
    
    /// Verified users: password reset only. Pending users: resend sign-up / invitation only (no Firebase reset — avoids clashing flows).
    private var actionsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Group {
                if user.passwordSet {
                    Button(action: { sendResetPasswordEmail() }) {
                        HStack {
                            Image(systemName: "key.fill")
                            Text("Send password reset email")
                            Spacer()
                            if isSendingResetPassword {
                                ProgressView()
                            }
                        }
                        .foregroundColor(.white)
                        .padding()
                        .background(Color.blue)
                        .cornerRadius(12)
                    }
                    .disabled(isSendingResetPassword)
                } else {
                    let isPendingManagerOrOperative = (user.permissions.manager || user.permissions.operativeMode) &&
                        !user.permissions.adminAccess && !user.isSuperAdmin
                    Button(action: { resendVerificationEmail() }) {
                        HStack {
                            Image(systemName: isPendingManagerOrOperative ? "envelope.badge.fill" : "envelope.fill")
                            Text(isPendingManagerOrOperative
                                 ? "Resend sign-up email (verification code)"
                                 : "Resend verification email")
                            Spacer()
                            if isResendingEmail || isSendingSignUpEmail {
                                ProgressView()
                            }
                        }
                        .foregroundColor(.white)
                        .padding()
                        .background(isPendingManagerOrOperative ? Color.blue : Color.orange)
                        .cornerRadius(12)
                    }
                    .disabled(isResendingEmail || isSendingSignUpEmail)
                    
                    Text("They have not finished setting a password yet. Resend the invitation email so they receive a new code and setup link.")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 4)
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 20)
            
            if let message = resetPasswordMessage ?? resendEmailMessage ?? signUpEmailMessage {
                Text(message)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 20)
            }

            // Super Admin transfer (organization ownership)
            if userStore.currentUser?.isSuperAdmin == true,
               !user.isSuperAdmin,
               !user.permissions.operativeMode,
               (user.permissions.adminAccess || user.role == .admin) {
                Button(action: { transferSuperAdmin() }) {
                    HStack {
                        Image(systemName: "crown.fill")
                        Text("Make Super Admin")
                        Spacer()
                        if isTransferringSuperAdmin {
                            ProgressView()
                        }
                    }
                    .foregroundColor(.white)
                    .padding()
                    .background(Color.purple)
                    .cornerRadius(12)
                }
                .disabled(isTransferringSuperAdmin)
                .padding(.horizontal, 20)
                .padding(.top, 8)
            }

            if let message = transferSuperAdminMessage {
                Text(message)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 20)
            }

            if userStore.hasAdminAccess(),
               !user.isSuperAdmin,
               !user.permissions.adminAccess,
               (user.permissions.manager || user.permissions.operativeMode) {
                Button(action: { showingHolidayReport = true }) {
                    HStack {
                        Image(systemName: "calendar")
                        Text("Holiday Report")
                        Spacer()
                    }
                    .foregroundColor(.white)
                    .padding()
                    .background(Color.indigo)
                    .cornerRadius(12)
                }
                .padding(.horizontal, 20)
                .padding(.top, 8)
            }

            // Deactivate / Reactivate (admin + super admin only)
            if !userStore.isOrganizationCreator(userId: user.id) {
                Button(action: { toggleActiveStatus() }) {
                    HStack {
                        Image(systemName: isActive ? "pause.circle.fill" : "play.circle.fill")
                        Text(isActive ? "Deactivate User" : "Reactivate User")
                        Spacer()
                        if isUpdatingActiveStatus {
                            ProgressView()
                        }
                    }
                    .foregroundColor(.white)
                    .padding()
                    .background(isActive ? Color.gray : Color.green)
                    .cornerRadius(12)
                }
                .disabled(isUpdatingActiveStatus)
                .padding(.horizontal, 20)
                .padding(.top, 8)

                if let message = activeStatusMessage {
                    Text(message)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 20)
                }
            }
            
            if !user.isSuperAdmin {
                Button(action: { showingDeleteConfirmation = true }) {
                    HStack {
                        Image(systemName: "trash.fill")
                        Text("Delete User")
                        Spacer()
                    }
                    .foregroundColor(.white)
                    .padding()
                    .background(Color.red)
                    .cornerRadius(12)
                }
                .padding(.horizontal, 20)
                .padding(.top, 8)
                .padding(.bottom, 40)
            }
        }
    }

    private func transferSuperAdmin() {
        isTransferringSuperAdmin = true
        transferSuperAdminMessage = nil
        Task {
            let success = await userStore.transferSuperAdmin(to: user.id)
            await MainActor.run {
                isTransferringSuperAdmin = false
                transferSuperAdminMessage = success
                    ? "✅ Ownership transferred. \(user.fullName) is now Super Admin."
                    : (userStore.errorMessage ?? "❌ Failed to transfer ownership.")
                if success { dismiss() }
            }
        }
    }

    private func toggleActiveStatus() {
        isUpdatingActiveStatus = true
        activeStatusMessage = nil
        let newValue = !isActive
        Task {
            let ok = await userStore.updateUserActiveStatus(for: user, isActive: newValue)
            await MainActor.run {
                isUpdatingActiveStatus = false
                if ok {
                    isActive = newValue
                    activeStatusMessage = newValue ? "✅ User reactivated." : "✅ User deactivated."
                    dismiss()
                } else {
                    activeStatusMessage = userStore.errorMessage ?? "❌ Could not update status. Check connection or Firestore rules."
                }
            }
        }
    }
    
    private var permissionsSection: some View {
        VStack(alignment: .leading, spacing: 20) {
            if user.isSuperAdmin {
                VStack(spacing: 12) {
                    HStack {
                        Image(systemName: "lock.fill")
                            .foregroundColor(.orange)
                        Text("Super Admin")
                            .font(.headline)
                            .foregroundColor(.orange)
                    }
                    Text("This user is the organization creator. Their permissions cannot be changed.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .padding()
                .background(Color.orange.opacity(0.1))
                .cornerRadius(12)
                .padding(.horizontal, 20)
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Permissions")
                        .font(.headline)
                        .padding(.horizontal, 20)
                    
                    VStack(spacing: 12) {
                        PermissionToggle(
                            title: "Admin Access",
                            description: "Can add and manage users.",
                            isOn: $permissions.adminAccess
                        )
                        .disabled(permissions.operativeMode)
                        .onChange(of: permissions.adminAccess) { oldValue, newValue in
                            if newValue && !permissions.operativeMode {
                                permissions.manager = true
                                permissions.projects = true
                                permissions.smallWorks = true
                            }
                        }
                        
                        PermissionToggle(
                            title: "Manager",
                            description: "Managers will be able to schedule operatives, create new clients, skills, and qualifications, view warnings and manage tasks.",
                            isOn: $permissions.manager
                        )
                        .disabled(permissions.adminAccess || permissions.operativeMode)
                        .onChange(of: permissions.manager) { oldValue, newValue in
                            if newValue && !permissions.operativeMode {
                                permissions.projects = true
                                permissions.smallWorks = true
                            }
                        }
                        
                        PermissionToggle(
                            title: "Projects",
                            description: "Can create and manage projects.",
                            isOn: $permissions.projects
                        )
                        .disabled((!permissions.manager && !permissions.adminAccess) || permissions.operativeMode)
                        
                        PermissionToggle(
                            title: "Small Works",
                            description: "Can create and manage small works.",
                            isOn: $permissions.smallWorks
                        )
                        .disabled((!permissions.manager && !permissions.adminAccess) || permissions.operativeMode)
                        
                        PermissionToggle(
                            title: "Operatives",
                            description: "Can manage operatives and view their details. If un-selected the user will only be able to assign operatives to projects and small works.",
                            isOn: $permissions.operatives
                        )
                        .disabled(permissions.operativeMode)
                        
                        PermissionToggle(
                            title: "Skills",
                            description: "Can create and alter existing skills.",
                            isOn: $permissions.skills
                        )
                        .disabled(permissions.operativeMode)
                        
                        PermissionToggle(
                            title: "Qualifications",
                            description: "Can create and alter existing qualifications.",
                            isOn: $permissions.qualifications
                        )
                        .disabled(permissions.operativeMode)
                        
                        Divider()
                            .padding(.vertical, 8)
                        
                        PermissionToggle(
                            title: "Operative Mode",
                            description: "Limited view for operatives: only projects/small works assigned to them, their tasks, and My Schedule. No manager or admin features.",
                            isOn: $permissions.operativeMode
                        )
                        .onChange(of: permissions.operativeMode) { oldValue, newValue in
                            if newValue {
                                permissions.adminAccess = false
                                permissions.manager = false
                                permissions.projects = false
                                permissions.smallWorks = false
                                permissions.operatives = false
                                permissions.skills = false
                                permissions.qualifications = false
                            }
                        }
                    }
                    .padding(.horizontal, 20)
                }
            }
        }
    }
    
    private func saveChanges() {
        isUpdating = true
        
        Task {
            var permissionsSuccess = true
            if !user.isSuperAdmin && permissions != user.permissions {
                permissionsSuccess = await userStore.updateUserPermissions(
                    userId: user.id,
                    permissions: permissions
                )
            }
            
            var activeSuccess = true
            if isActive != user.isActive {
                activeSuccess = await userStore.updateUserActiveStatus(for: user, isActive: isActive)
            }
            
            await MainActor.run {
                isUpdating = false
                if permissionsSuccess && activeSuccess {
                    dismiss()
                }
            }
        }
    }
    
    private func sendResetPasswordEmail() {
        isSendingResetPassword = true
        resetPasswordMessage = nil
        Task {
            let success = await userStore.sendPasswordResetEmail(to: user.email)
            await MainActor.run {
                isSendingResetPassword = false
                resetPasswordMessage = success
                    ? "✅ Password reset email sent to \(user.email). They should use the link in that email to choose a new password."
                    : "❌ Failed to send password reset email."
            }
        }
    }
    
    private func resendVerificationEmail() {
        isResendingEmail = true
        resendEmailMessage = nil
        
        // Pending managers/operatives get sign-up email with verification code (always fresh link)
        let isPendingManagerOrOperative = !user.passwordSet &&
                                         (user.permissions.manager || user.permissions.operativeMode) &&
                                         !user.permissions.adminAccess &&
                                         !user.isSuperAdmin
        
        if isPendingManagerOrOperative {
            sendSignUpEmailToUser()
            return
        }
        
        // Other pending users: always create a brand new invitation and send (never reuse old link)
        Task {
            await createNewInvitation()
        }
    }
    
    private func createNewInvitation() async {
        let db = Firestore.firestore()
        do {
            // Mark all existing invitations for this email as used so only the new link works
            let existing = try await db.collection("invitations")
                .whereField("email", isEqualTo: user.email)
                .getDocuments()
            for doc in existing.documents {
                try? await doc.reference.updateData(["isUsed": true])
            }
        } catch {
            // Continue anyway; we'll create a new invitation
        }

        let invitationId = UUID().uuidString
        var invitationData: [String: Any] = [
            "email": user.email,
            "organizationId": user.organizationId,
            "invitedBy": userStore.currentUser?.email ?? "System",
            "firstName": user.firstName,
            "surname": user.surname,
            "permissions": [
                "adminAccess": permissions.adminAccess,
                "manager": permissions.manager,
                "operatives": permissions.operatives,
                "skills": permissions.skills,
                "qualifications": permissions.qualifications,
                "projects": permissions.projects,
                "smallWorks": permissions.smallWorks,
                "operativeMode": permissions.operativeMode
            ],
            "createdAt": Timestamp(date: Date()),
            "isUsed": false
        ]
        
        if let mobileNumber = user.mobileNumber {
            invitationData["mobileNumber"] = mobileNumber
        }
        
        do {
            try await db.collection("invitations").document(invitationId).setData(invitationData)

            await userStore.resendInvitationEmail(
                email: user.email,
                firstName: user.firstName,
                surname: user.surname,
                invitationId: invitationId
            )

            await MainActor.run {
                resendEmailMessage = "✅ Verification email sent successfully to \(user.email)"
                isResendingEmail = false
            }
        } catch {
            await MainActor.run {
                resendEmailMessage = "❌ Failed to create invitation: \(error.localizedDescription)"
                isResendingEmail = false
            }
        }
    }

    private func sendSignUpEmailToUser() {
        if !isSendingSignUpEmail {
            isSendingSignUpEmail = true
        }
        signUpEmailMessage = nil

        Task {
            let db = Firestore.firestore()
            do {
                // Mark all existing invitations for this email as used so only the new link works
                let existing = try await db.collection("invitations")
                    .whereField("email", isEqualTo: user.email)
                    .getDocuments()
                for doc in existing.documents {
                    try? await doc.reference.updateData(["isUsed": true])
                }

                // Always create a brand new invitation (never reuse old link)
                let invitationId = UUID().uuidString
                var invitationData: [String: Any] = [
                    "email": user.email,
                    "organizationId": user.organizationId,
                    "invitedBy": userStore.currentUser?.email ?? "System",
                    "firstName": user.firstName,
                    "surname": user.surname,
                    "permissions": [
                        "adminAccess": user.permissions.adminAccess,
                        "manager": user.permissions.manager,
                        "operatives": user.permissions.operatives,
                        "skills": user.permissions.skills,
                        "qualifications": user.permissions.qualifications,
                        "projects": user.permissions.projects,
                        "smallWorks": user.permissions.smallWorks,
                        "operativeMode": user.permissions.operativeMode
                    ],
                    "createdAt": Timestamp(date: Date()),
                    "isUsed": false
                ]
                if let mobileNumber = user.mobileNumber {
                    invitationData["mobileNumber"] = mobileNumber
                }
                try await db.collection("invitations").document(invitationId).setData(invitationData)

                let success = await userStore.sendSignUpEmailWithVerification(
                    email: user.email,
                    firstName: user.firstName,
                    surname: user.surname,
                    invitationId: invitationId
                )

                await MainActor.run {
                    isSendingSignUpEmail = false
                    isResendingEmail = false
                    if success {
                        signUpEmailMessage = "✅ Sign-up email with verification code sent successfully to \(user.email)"
                        resendEmailMessage = "✅ Sign-up email with verification code sent successfully to \(user.email)"
                    } else {
                        signUpEmailMessage = "❌ Failed to send sign-up email. Please try again."
                        resendEmailMessage = "❌ Failed to send sign-up email. Please try again."
                    }
                }
            } catch {
                await MainActor.run {
                    isSendingSignUpEmail = false
                    isResendingEmail = false
                    signUpEmailMessage = "❌ Error: \(error.localizedDescription)"
                    resendEmailMessage = "❌ Error: \(error.localizedDescription)"
                }
            }
        }
    }
    
    private func deleteUser() {
        print("🔥🔥🔥 DEBUG: Delete user function called for: \(user.fullName)")
        Task {
            await userStore.deleteUser(user, bookingStore: bookingStore, operativeStore: operativeStore)
            // Reload users after deletion
            await userStore.loadOrganizationUsers()
            await MainActor.run {
                dismiss()
            }
        }
    }
}

// MARK: - Detail Row Helper

struct DetailRow: View {
    let label: String
    let value: String
    
    var body: some View {
        HStack {
            Text(label)
                .font(.subheadline)
                .foregroundColor(.secondary)
            Spacer()
            Text(value)
                .font(.body)
                .foregroundColor(.primary)
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 16)
        .background(Color(.systemBackground))
        .cornerRadius(12)
    }
}

// MARK: - Tab Button

struct TabButton: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Text(title)
                    .font(.headline)
                    .foregroundColor(isSelected ? .indigo : .secondary)
                
                Rectangle()
                    .fill(isSelected ? Color.indigo : Color.clear)
                    .frame(height: 2)
            }
        }
        .frame(maxWidth: .infinity)
    }
}

#Preview {
    ManageUsersView()
        .environmentObject(UserStore())
}
