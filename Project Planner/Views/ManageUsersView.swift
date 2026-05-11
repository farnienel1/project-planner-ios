//
//  ManageUsersView.swift
//  Project Planner
//
//  Created by Assistant on 24/10/2025.
//

import SwiftUI
import UIKit
import FirebaseAuth
import FirebaseFirestore

struct ManageUsersView: View {
    @EnvironmentObject var userStore: UserStore
    @EnvironmentObject var bookingStore: BookingStore
    @EnvironmentObject var operativeStore: OperativeStore
    @EnvironmentObject var holidayStore: HolidayStore
    @EnvironmentObject var firebaseBackend: FirebaseBackend
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

    /// Signed in with Firebase Auth but org user doc not in memory yet — show spinner instead of “access denied”.
    private var needsProfileBeforeManageUsersGate: Bool {
        Auth.auth().currentUser != nil && userStore.currentUser == nil
    }
    
    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if needsProfileBeforeManageUsersGate {
                    VStack(spacing: 16) {
                        ProgressView()
                        Text("Loading profile…")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .task {
                        await userStore.loadCurrentUser()
                    }
                } else if !userStore.canManageUsers() {
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
                    .environmentObject(firebaseBackend)
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
                                if let operative = operativeStore.allOperatives.first(where: { $0.email.lowercased() == user.email.lowercased() }) {
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
            if initialTab >= 0 && initialTab <= 2 {
                selectedTab = initialTab
            }
            if let userToHighlight {
                selectedUser = userToHighlight
                try? await Task.sleep(nanoseconds: 300_000_000)
            }
        }
        .onAppear {
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
            guard !user.permissions.operativeMode else { return false }
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
                        "materials": user.permissions.materials,
                        "projects": user.permissions.projects,
                        "smallWorks": user.permissions.smallWorks,
                        "operativeMode": user.permissions.operativeMode,
                        "weeklyReports": user.permissions.weeklyReports,
                        "subContractors": user.permissions.subContractors,
                        "siteAudit": user.permissions.siteAudit
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
    @EnvironmentObject var firebaseBackend: FirebaseBackend
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
    @State private var saveErrorMessage: String?
    @State private var selectedAssignedManagerUserId: String?
    @State private var dayRateText: String
    @State private var dayRateHistory: [OperativeDayRateHistoryEntry] = []
    @State private var showingQualificationsEditor = false
    @State private var tradePresetRaw: String
    @State private var tradeCustomText: String
    @State private var showingProfilePhotoSourcePicker = false
    @State private var profilePhotoPickerSource: UIImagePickerController.SourceType = .photoLibrary
    @State private var showingProfileImagePicker = false
    @State private var pickedProfileImage: UIImage?
    @State private var isUploadingProfilePhoto = false
    @State private var profilePhotoUploadMessage: String?
    @State private var showingChangeUserType = false
    @State private var changeUserTypeDraft: ManagedAccountKind = .operative
    @State private var managerSelfBookDraft = false
    @State private var managerTransitionOperatives = true
    @State private var managerTransitionSkills = true
    @State private var managerTransitionQualifications = true
    @State private var managerTransitionWeeklyReports = false
    @State private var managerTransitionSubContractors = false
    @State private var managerTransitionProjects = true
    @State private var managerTransitionSmallWorks = true
    @State private var operativeTransitionMaterials = false
    @State private var operativeTransitionSiteAudit = true
    @State private var isApplyingUserType = false
    @State private var userTypeChangeMessage: String?

    init(user: AppUser) {
        self.user = user
        self._permissions = State(initialValue: user.permissions)
        self._isActive = State(initialValue: user.isActive)
        self._selectedAssignedManagerUserId = State(initialValue: user.assignedManagerUserId)
        self._dayRateText = State(initialValue: user.dayRate.map { String(format: "%.2f", $0) } ?? "")
        self._tradePresetRaw = State(initialValue: user.tradeTypePreset ?? "")
        self._tradeCustomText = State(initialValue: user.tradeTypeCustom ?? "")
    }
    
    private var isManagerOperativeOnly: Bool {
        userStore.isActingManagerOperativeManagementOnly()
    }
    
    private var canEditPermissionsMatrix: Bool {
        userStore.canEditTargetUserPermissions(user)
    }
    
    /// Admin-level account tools (status, delete, some emails).
    private var canUseAdminAccountTools: Bool {
        userStore.hasAdminAccess()
    }
    
    /// Password / invitation actions also available to managers who only manage operatives.
    private var canShowCredentialActions: Bool {
        canUseAdminAccountTools || (isManagerOperativeOnly && (user.permissions.operativeMode || user.role == .operative))
    }
    
    private var linkedOperativeForUser: Operative? {
        operativeStore.allOperatives.first {
            $0.email.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) ==
            user.email.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }
    
    /// Fresh row from the store (e.g. after profile photo upload).
    private var displayedUser: AppUser {
        userStore.organizationUsers.first(where: { $0.id == user.id }) ?? user
    }
    
    private var canUploadProfilePhoto: Bool {
        canEditPermissionsMatrix
    }

    private var editNavigationTitle: String {
        permissions.operativeMode ? "Edit operative" : "Edit user"
    }

    private var showOperativeSetupCard: Bool {
        let eligible = permissions.operativeMode || permissions.manager
        return eligible && canEditPermissionsMatrix
    }

    private var lineManagerSummary: String {
        guard permissions.operativeMode else { return "" }
        guard let id = selectedAssignedManagerUserId?.trimmingCharacters(in: .whitespacesAndNewlines), !id.isEmpty else {
            return "Select manager…"
        }
        if let m = lineManagerCandidates.first(where: { $0.id == id }) {
            let name = m.fullName.trimmingCharacters(in: .whitespacesAndNewlines)
            return name.isEmpty ? m.email : name
        }
        return "Select manager…"
    }

    private var operativeSetupSectionTitle: String {
        permissions.manager && !permissions.operativeMode ? "Manager setup" : "Operative setup"
    }

    private var roleHeaderIconName: String {
        if permissions.operativeMode {
            return "wrench.and.screwdriver.fill"
        }
        if permissions.adminAccess {
            return "person.badge.key.fill"
        }
        return "person.fill"
    }

    private var changeUserTypeIsNoOp: Bool {
        let currentKind = UserRoleTransitionPolicy.kind(for: permissions)
        if changeUserTypeDraft != currentKind { return false }
        switch changeUserTypeDraft {
        case .operative:
            return operativeTransitionMaterials == permissions.materials
                && operativeTransitionSiteAudit == permissions.siteAudit
        case .manager:
            return managerSelfBookDraft == permissions.annualLeaveSelfBook
                && managerTransitionOperatives == permissions.operatives
                && managerTransitionSkills == permissions.skills
                && managerTransitionQualifications == permissions.qualifications
                && managerTransitionWeeklyReports == permissions.weeklyReports
                && managerTransitionSubContractors == permissions.subContractors
                && managerTransitionProjects == permissions.projects
                && managerTransitionSmallWorks == permissions.smallWorks
        case .administrator:
            return true
        }
    }

    private func applyDraftsForChangeUserTypeSelection() {
        if let m = UserRoleTransitionPolicy.managerConfigForSheet(current: permissions, selectedKind: changeUserTypeDraft) {
            managerSelfBookDraft = m.annualLeaveSelfBook
            managerTransitionOperatives = m.operatives
            managerTransitionSkills = m.skills
            managerTransitionQualifications = m.qualifications
            managerTransitionWeeklyReports = m.weeklyReports
            managerTransitionSubContractors = m.subContractors
            managerTransitionProjects = m.projects
            managerTransitionSmallWorks = m.smallWorks
        }
        if let o = UserRoleTransitionPolicy.operativeConfigForSheet(current: permissions, selectedKind: changeUserTypeDraft) {
            operativeTransitionMaterials = o.materials
            operativeTransitionSiteAudit = o.siteAudit
        }
    }

    private var displayRoleLabel: String {
        if permissions.adminAccess { return UserRole.admin.displayName }
        if permissions.manager && !permissions.operativeMode { return UserRole.manager.displayName }
        if permissions.operativeMode { return UserRole.operative.displayName }
        return user.role.displayName
    }
    
    // Check if any changes have been made
    private var hasChanges: Bool {
        if userStore.isOrganizationCreator(userId: user.id) {
            return false
        }
        let dayRateEligible = permissions.operativeMode || permissions.manager
        let trimmedTradeP = tradePresetRaw.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedTradeC = tradeCustomText.trimmingCharacters(in: .whitespacesAndNewlines)
        let origTradeP = user.tradeTypePreset?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let origTradeC = user.tradeTypeCustom?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let tradeChanged = dayRateEligible && (trimmedTradeP != origTradeP || trimmedTradeC != origTradeC)
        let operativeProfileChanged = permissions.operativeMode && (
            (selectedAssignedManagerUserId ?? "") != (user.assignedManagerUserId ?? "") ||
            parseDayRate(dayRateText) != user.dayRate
        )
        let managerDayRateChanged = permissions.manager && !permissions.operativeMode && parseDayRate(dayRateText) != user.dayRate
        if canUseAdminAccountTools {
            return permissions != user.permissions || isActive != user.isActive || operativeProfileChanged || managerDayRateChanged || tradeChanged
        }
        if canEditPermissionsMatrix && (operativeProfileChanged || tradeChanged) {
            return true
        }
        if isManagerOperativeOnly && (user.permissions.operativeMode || user.role == .operative) {
            return permissions.materials != user.permissions.materials ||
                permissions.siteAudit != user.permissions.siteAudit ||
                tradeChanged
        }
        return false
    }

    private var lineManagerCandidates: [AppUser] {
        userStore.organizationUsers
            .filter { candidate in
                !candidate.permissions.operativeMode &&
                (candidate.isSuperAdmin || candidate.permissions.adminAccess || candidate.permissions.manager) &&
                candidate.isActive &&
                candidate.passwordSet
            }
            .sorted { ($0.fullName.isEmpty ? $0.email : $0.fullName) < ($1.fullName.isEmpty ? $1.email : $1.fullName) }
    }
    
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    userInfoHeader
                    userDetailsChromeSection
                    if showOperativeSetupCard {
                        VStack(alignment: .leading, spacing: 8) {
                            ManageUserSectionTitle(text: operativeSetupSectionTitle)
                            operativeAndManagerSetupCard
                        }
                    }
                    if canUseAdminAccountTools && !userStore.isOrganizationCreator(userId: user.id) {
                        activeToggleChromeSection
                    }
                    permissionsSection
                    if canShowCredentialActions || canUseAdminAccountTools {
                        actionsChromeSection
                    }
                }
                .padding(.horizontal, 18)
                .padding(.bottom, 32)
            }
            .background(ManageUserProfilePalette.pageBackground.ignoresSafeArea())
            .navigationTitle(editNavigationTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") { dismiss() }
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(ManageUserProfilePalette.textPrimary)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 7)
                        .background(Capsule(style: .continuous).fill(Color.white))
                        .overlay(
                            Capsule(style: .continuous)
                                .stroke(Color(red: 0xE5 / 255, green: 0xE7 / 255, blue: 0xEB / 255), lineWidth: 0.5)
                        )
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    if canEditPermissionsMatrix {
                        Button("Save") { saveChanges() }
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(hasChanges ? Color.white : ManageUserProfilePalette.textSecondary)
                            .padding(.horizontal, 18)
                            .padding(.vertical, 7)
                            .background(
                                Capsule(style: .continuous)
                                    .fill(hasChanges ? ManageUserProfilePalette.primaryBlue : Color(.systemGray5))
                            )
                            .disabled(isUpdating || !hasChanges)
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
            .alert("Could Not Save", isPresented: .constant(saveErrorMessage != nil)) {
                Button("OK") { saveErrorMessage = nil }
            } message: {
                if let msg = saveErrorMessage {
                    Text(msg)
                }
            }
            .sheet(isPresented: $showingQualificationsEditor) {
                if let operative = linkedOperativeForUser {
                    OperativeQualificationsEditorView(
                        operative: operative,
                        title: "Skills & Qualifications",
                        canEditAssignments: canEditPermissionsMatrix && (user.permissions.operativeMode || user.role == .operative)
                    )
                    .environmentObject(operativeStore)
                    .environmentObject(firebaseBackend)
                }
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
                Task { await uploadPickedProfilePhoto(newImage) }
            }
            .alert("Profile photo", isPresented: Binding(
                get: { profilePhotoUploadMessage != nil },
                set: { if !$0 { profilePhotoUploadMessage = nil } }
            )) {
                Button("OK") { profilePhotoUploadMessage = nil }
            } message: {
                if let profilePhotoUploadMessage {
                    Text(profilePhotoUploadMessage)
                }
            }
        }
        .sheet(isPresented: $showingHolidayReport) {
            HolidayReportView(user: user)
                .environmentObject(holidayStore)
                .environmentObject(operativeStore)
        }
        .sheet(isPresented: $showingChangeUserType) {
            changeUserTypeSheet
        }
        .task {
            await loadDayRateHistory()
        }
    }

    private var changeUserTypeSheet: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text("Choose how this account should behave in the app. Permissions are aligned with the Add user flows so Firestore stays consistent. Approved annual leave is kept. Pending approval requests are removed when the person can book their own leave (manager with self-book, or administrator).")
                        .font(.subheadline)
                        .foregroundStyle(ManageUserProfilePalette.textSecondary)

                    Picker("Account type", selection: $changeUserTypeDraft) {
                        ForEach(ManagedAccountKind.allCases) { kind in
                            Text(kind.title).tag(kind)
                        }
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: changeUserTypeDraft) { oldKind, newKind in
                        guard oldKind != newKind else { return }
                        applyDraftsForChangeUserTypeSelection()
                    }

                    if changeUserTypeDraft == .manager {
                        Text("Manager access")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(ManageUserProfilePalette.textPrimary)

                        VStack(spacing: 0) {
                            ManageUserPermissionToggleRow(
                                iconName: "person.crop.rectangle.stack.fill",
                                iconBackground: ManageUserProfilePalette.chipPurpleBg,
                                iconForeground: ManageUserProfilePalette.chipPurpleFg,
                                title: "Operatives",
                                subtitle: "Can manage operatives and view their details. If turned off, the user can still assign operatives to projects and small works, but will not see the Operatives tab or full operative profiles.",
                                isOn: $managerTransitionOperatives
                            )
                            ManageUserCardDivider()
                            ManageUserPermissionToggleRow(
                                iconName: "beach.umbrella.fill",
                                iconBackground: ManageUserProfilePalette.chipBlueBg,
                                iconForeground: ManageUserProfilePalette.chipBlueFg,
                                title: "Annual Leave",
                                subtitle: "Can book their own annual leave. If off, this manager requests leave for approval.",
                                isOn: $managerSelfBookDraft
                            )
                            ManageUserCardDivider()
                            ManageUserPermissionToggleRow(
                                iconName: "doc.text.fill",
                                iconBackground: ManageUserProfilePalette.chipTealBg,
                                iconForeground: ManageUserProfilePalette.chipTealFg,
                                title: "Weekly Report",
                                subtitle: "Will be able to pull weekly reports.",
                                isOn: $managerTransitionWeeklyReports
                            )
                            ManageUserCardDivider()
                            ManageUserPermissionToggleRow(
                                iconName: "person.2.wave.2.fill",
                                iconBackground: ManageUserProfilePalette.chipTealBg,
                                iconForeground: ManageUserProfilePalette.chipTealFg,
                                title: "Sub Contractors",
                                subtitle: "Can add and manage sub contractors. If unselected they will be unable to manage them, they will only be able to book them in.",
                                isOn: $managerTransitionSubContractors
                            )
                            ManageUserCardDivider()
                            ManageUserPermissionToggleRow(
                                iconName: "wrench.and.screwdriver.fill",
                                iconBackground: ManageUserProfilePalette.chipPinkBg,
                                iconForeground: ManageUserProfilePalette.chipPinkFg,
                                title: "Skills",
                                subtitle: "Can create and alter existing skills.",
                                isOn: $managerTransitionSkills
                            )
                            ManageUserCardDivider()
                            ManageUserPermissionToggleRow(
                                iconName: "rosette",
                                iconBackground: ManageUserProfilePalette.chipPinkBg,
                                iconForeground: ManageUserProfilePalette.chipPinkFg,
                                title: "Qualifications",
                                subtitle: "Can create and alter existing qualifications.",
                                isOn: $managerTransitionQualifications
                            )
                            ManageUserCardDivider()
                            ManageUserPermissionToggleRow(
                                iconName: "folder.fill",
                                iconBackground: ManageUserProfilePalette.chipBlueBg,
                                iconForeground: ManageUserProfilePalette.chipBlueFg,
                                title: "Projects",
                                subtitle: "Can create and manage projects.",
                                isOn: $managerTransitionProjects,
                                isDisabled: false
                            )
                            ManageUserCardDivider()
                            ManageUserPermissionToggleRow(
                                iconName: "hammer.fill",
                                iconBackground: ManageUserProfilePalette.chipBlueBg,
                                iconForeground: ManageUserProfilePalette.chipBlueFg,
                                title: "Small Works",
                                subtitle: "Can create and manage small works.",
                                isOn: $managerTransitionSmallWorks,
                                isDisabled: false
                            )
                        }
                        .background(Color.white)
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .stroke(Color(red: 0xE5 / 255, green: 0xE7 / 255, blue: 0xEB / 255), lineWidth: 0.5)
                        )

                        Text("If annual leave self-book is turned on, pending approval requests are cleared.")
                            .font(.caption)
                            .foregroundStyle(ManageUserProfilePalette.textSecondary)
                    }

                    if changeUserTypeDraft == .operative {
                        Text("Operative access")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(ManageUserProfilePalette.textPrimary)

                        VStack(spacing: 0) {
                            ManageUserPermissionToggleRow(
                                iconName: "shippingbox.fill",
                                iconBackground: ManageUserProfilePalette.chipAmberBg,
                                iconForeground: ManageUserProfilePalette.chipAmberFg,
                                title: "Materials",
                                subtitle: "Order & track stock",
                                isOn: $operativeTransitionMaterials
                            )
                            ManageUserCardDivider()
                            ManageUserPermissionToggleRow(
                                iconName: "checklist",
                                iconBackground: ManageUserProfilePalette.chipTealBg,
                                iconForeground: ManageUserProfilePalette.chipTealFg,
                                title: "Site audit",
                                subtitle: "Submit safety checks",
                                isOn: $operativeTransitionSiteAudit
                            )
                        }
                        .background(Color.white)
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .stroke(Color(red: 0xE5 / 255, green: 0xE7 / 255, blue: 0xEB / 255), lineWidth: 0.5)
                        )

                        Text("These match the optional extras when adding an operative. Line manager and day rate can be set after the type change on the main edit screen.")
                            .font(.caption)
                            .foregroundStyle(ManageUserProfilePalette.textSecondary)
                    }

                    if let userTypeChangeMessage {
                        Text(userTypeChangeMessage)
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }

                    Button {
                        Task { await applyChangeUserType() }
                    } label: {
                        if isApplyingUserType {
                            ProgressView()
                                .frame(maxWidth: .infinity)
                        } else {
                            Text("Apply")
                                .font(.system(size: 15, weight: .semibold))
                                .frame(maxWidth: .infinity)
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(ManageUserProfilePalette.primaryBlue)
                    .disabled(isApplyingUserType || changeUserTypeIsNoOp)
                }
                .padding(20)
            }
            .background(ManageUserProfilePalette.pageBackground.ignoresSafeArea())
            .navigationTitle("Change user type")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") {
                        showingChangeUserType = false
                        userTypeChangeMessage = nil
                    }
                }
            }
        }
    }

    private func applyChangeUserType() async {
        await MainActor.run {
            isApplyingUserType = true
            userTypeChangeMessage = nil
        }
        let managerConfig: ManagerUserTypeTransitionConfig? = changeUserTypeDraft == .manager
            ? ManagerUserTypeTransitionConfig(
                annualLeaveSelfBook: managerSelfBookDraft,
                operatives: managerTransitionOperatives,
                skills: managerTransitionSkills,
                qualifications: managerTransitionQualifications,
                weeklyReports: managerTransitionWeeklyReports,
                subContractors: managerTransitionSubContractors,
                projects: managerTransitionProjects,
                smallWorks: managerTransitionSmallWorks
            )
            : nil
        let operativeConfig: OperativeUserTypeTransitionConfig? = changeUserTypeDraft == .operative
            ? OperativeUserTypeTransitionConfig(materials: operativeTransitionMaterials, siteAudit: operativeTransitionSiteAudit)
            : nil
        let newPerms = UserRoleTransitionPolicy.permissions(
            for: changeUserTypeDraft,
            carryingFrom: permissions,
            manager: managerConfig,
            operative: operativeConfig
        )
        let ok = await userStore.updateUserPermissions(
            userId: user.id,
            permissions: newPerms,
            holidayStore: holidayStore,
            linkedOperativeUUID: linkedOperativeForUser?.id
        )
        await MainActor.run { isApplyingUserType = false }
        if ok {
            await userStore.loadOrganizationUsers()
            await holidayStore.loadData()
            await MainActor.run {
                if let fresh = userStore.organizationUsers.first(where: { $0.id == user.id }) {
                    permissions = fresh.permissions
                    selectedAssignedManagerUserId = fresh.assignedManagerUserId
                    isActive = fresh.isActive
                }
                if permissions.operativeMode {
                    Task { await loadDayRateHistory() }
                } else {
                    dayRateHistory = []
                }
                showingChangeUserType = false
            }
        } else {
            await MainActor.run {
                userTypeChangeMessage = userStore.errorMessage ?? "Could not update account type."
            }
        }
    }
    
    private var userInfoHeader: some View {
        ManageUserCard {
            VStack(spacing: 12) {
                ZStack(alignment: .bottomTrailing) {
                    ZStack {
                        if let urlString = displayedUser.profilePhotoURL,
                           let url = URL(string: urlString) {
                            AsyncImage(url: url) { phase in
                                switch phase {
                                case .empty:
                                    ProgressView()
                                        .tint(.white)
                                case .success(let image):
                                    image
                                        .resizable()
                                        .scaledToFill()
                                case .failure:
                                    profileInitialsPlaceholder
                                @unknown default:
                                    profileInitialsPlaceholder
                                }
                            }
                        } else {
                            profileInitialsPlaceholder
                        }
                    }
                    .frame(width: 84, height: 84)
                    .clipShape(Circle())

                    if canUploadProfilePhoto {
                        Button {
                            showingProfilePhotoSourcePicker = true
                        } label: {
                            Image(systemName: "camera.fill")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(.white)
                                .frame(width: 28, height: 28)
                                .background(ManageUserProfilePalette.primaryBlue)
                                .clipShape(Circle())
                                .overlay(Circle().stroke(Color.white, lineWidth: 2.5))
                        }
                        .buttonStyle(.plain)
                        .disabled(isUploadingProfilePhoto)
                        .offset(x: 2, y: 2)
                    }
                }
                .overlay {
                    if isUploadingProfilePhoto {
                        ProgressView()
                            .padding(8)
                            .background(.ultraThinMaterial, in: Circle())
                    }
                }

                VStack(spacing: 4) {
                    Text(user.fullName)
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(ManageUserProfilePalette.textPrimary)

                    Text(user.email)
                        .font(.system(size: 13))
                        .foregroundStyle(ManageUserProfilePalette.textSecondary)

                    HStack(spacing: 6) {
                        roleStatusChip(
                            text: displayRoleLabel,
                            systemImage: roleHeaderIconName,
                            foreground: ManageUserProfilePalette.operativeChipLabel,
                            background: ManageUserProfilePalette.chipPurpleBg
                        )
                        if user.passwordSet {
                            roleStatusChip(
                                text: "Verified",
                                systemImage: "checkmark.circle.fill",
                                foreground: ManageUserProfilePalette.chipTealFg,
                                background: ManageUserProfilePalette.chipTealBg
                            )
                        } else {
                            roleStatusChip(
                                text: "Pending",
                                systemImage: "clock.fill",
                                foreground: ManageUserProfilePalette.chipAmberFg,
                                background: ManageUserProfilePalette.chipAmberBg
                            )
                        }
                        roleStatusChip(
                            text: user.isActive ? "Active" : "Inactive",
                            systemImage: "smallcircle.filled.circle.fill",
                            foreground: ManageUserProfilePalette.chipBlueFg,
                            background: ManageUserProfilePalette.chipBlueBg
                        )
                    }
                    .padding(.top, 4)
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity)
        }
    }

    private func roleStatusChip(text: String, systemImage: String, foreground: Color, background: Color) -> some View {
        HStack(spacing: 4) {
            Image(systemName: systemImage)
                .font(.system(size: 11, weight: .semibold))
            Text(text)
                .font(.system(size: 11, weight: .medium))
        }
        .foregroundStyle(foreground)
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(background)
        .clipShape(Capsule(style: .continuous))
    }

    private var profileInitialsPlaceholder: some View {
        Circle()
            .fill(
                LinearGradient(
                    colors: [
                        ManageUserProfilePalette.avatarGradientTop,
                        ManageUserProfilePalette.avatarGradientBottom,
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .overlay(
                Text("\(String(displayedUser.firstName.prefix(1)))\(String(displayedUser.surname.prefix(1)))".uppercased())
                    .font(.system(size: 26, weight: .medium))
                    .foregroundStyle(.white)
                    .tracking(0.5)
            )
            .opacity(displayedUser.isActive ? 1 : 0.45)
    }

    private var userDetailsChromeSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            ManageUserSectionTitle(text: "User details")
            ManageUserCard {
                VStack(spacing: 0) {
                    ManageUserDetailStaticRow(
                        iconName: "envelope.fill",
                        iconBackground: ManageUserProfilePalette.chipBlueBg,
                        iconForeground: ManageUserProfilePalette.chipBlueFg,
                        label: "Email",
                        value: user.email
                    )
                    ManageUserCardDivider()
                    ManageUserDetailStaticRow(
                        iconName: "phone.fill",
                        iconBackground: ManageUserProfilePalette.chipTealBg,
                        iconForeground: ManageUserProfilePalette.chipTealFg,
                        label: "Mobile number",
                        value: {
                            if let mobileNumber = user.mobileNumber, !mobileNumber.isEmpty { return mobileNumber }
                            return "—"
                        }()
                    )
                    ManageUserCardDivider()
                    ManageUserDetailStaticRow(
                        iconName: "calendar",
                        iconBackground: ManageUserProfilePalette.chipAmberBg,
                        iconForeground: ManageUserProfilePalette.chipAmberFg,
                        label: "Last active",
                        value: "—"
                    )
                }
            }
        }
    }

    private var operativeAndManagerSetupCard: some View {
        ManageUserCard {
            VStack(spacing: 0) {
                if permissions.operativeMode {
                    lineManagerPickRow
                    ManageUserCardDivider()
                }
                ManageUserDayRateEditRow(dayRateText: $dayRateText, currencySymbol: localeCurrencySymbol())
                ManageUserCardDivider()
                tradeTypePickSection
                if permissions.operativeMode && !dayRateHistory.isEmpty {
                    ManageUserCardDivider()
                    dayRateHistoryChromeBlock
                }
                if permissions.operativeMode, linkedOperativeForUser != nil, canEditPermissionsMatrix {
                    ManageUserCardDivider()
                    ManageUserNavigationSubtitleRow(
                        iconName: "graduationcap.fill",
                        iconBackground: ManageUserProfilePalette.chipBlueBg,
                        iconForeground: ManageUserProfilePalette.chipBlueFg,
                        title: "Skills & qualifications",
                        subtitle: "Manage certifications",
                        action: { showingQualificationsEditor = true }
                    )
                }
            }
        }
    }

    private var lineManagerPickRow: some View {
        Menu {
            Button("Unassigned") { selectedAssignedManagerUserId = nil }
            ForEach(lineManagerCandidates, id: \.id) { manager in
                Button(manager.fullName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? manager.email : manager.fullName) {
                    selectedAssignedManagerUserId = manager.id
                }
            }
        } label: {
            ManageUserChevronRow(
                iconName: "person.badge.plus",
                iconBackground: ManageUserProfilePalette.chipPurpleBg,
                iconForeground: ManageUserProfilePalette.chipPurpleFg,
                label: "Line manager",
                value: lineManagerSummary
            )
        }
        .buttonStyle(.plain)
    }

    private var tradeTypePickSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            Menu {
                ForEach(StaffTradeType.pickerCases) { trade in
                    Button(trade.rawValue) {
                        tradePresetRaw = trade.rawValue
                        if trade != .other {
                            tradeCustomText = ""
                        }
                    }
                }
            } label: {
                ManageUserChevronRow(
                    iconName: "bolt.fill",
                    iconBackground: ManageUserProfilePalette.chipPinkBg,
                    iconForeground: ManageUserProfilePalette.chipPinkFg,
                    label: "Trade type",
                    value: StaffTradeType.displayLabel(presetRaw: tradePresetRaw, custom: tradeCustomText)
                )
            }
            .buttonStyle(.plain)

            if tradePresetRaw == StaffTradeType.other.rawValue {
                TextField("Enter trade name", text: $tradeCustomText)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(ManageUserProfilePalette.textPrimary)
                    .padding(.horizontal, 14)
                    .padding(.leading, ManageUserProfilePalette.iconChipSize + 24)
                    .padding(.bottom, 12)
            }
        }
    }

    private var dayRateHistoryChromeBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Previous day rates")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(ManageUserProfilePalette.textSecondary)
                .padding(.horizontal, 14)
                .padding(.top, 8)
            ForEach(dayRateHistory) { entry in
                HStack {
                    Text(entry.effectiveAt.formatted(date: .abbreviated, time: .omitted))
                        .font(.system(size: 11))
                        .foregroundStyle(ManageUserProfilePalette.textSecondary)
                    Spacer()
                    Text("\(localeCurrencySymbol())\(String(format: "%.2f", entry.dayRate))")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(ManageUserProfilePalette.textPrimary)
                }
                .padding(.horizontal, 14)
            }
            .padding(.bottom, 8)
        }
    }
    
    private func uploadPickedProfilePhoto(_ image: UIImage) async {
        await MainActor.run { isUploadingProfilePhoto = true }
        let subject = displayedUser
        let success = await userStore.updateUserProfilePhoto(for: subject, image: image)
        await MainActor.run {
            isUploadingProfilePhoto = false
            if success {
                profilePhotoUploadMessage = "Profile photo updated."
            } else {
                profilePhotoUploadMessage = userStore.errorMessage ?? "Could not upload profile photo."
            }
        }
    }
    
    private func loadDayRateHistory() async {
        guard permissions.operativeMode else {
            dayRateHistory = []
            return
        }
        guard let orgId = firebaseBackend.currentOrganization?.firestoreDocumentId else { return }
        let all = (try? await firebaseBackend.loadOperativeDayRateHistory(organizationId: orgId)) ?? [:]
        dayRateHistory = (all[user.id] ?? []).sorted(by: { $0.effectiveAt > $1.effectiveAt })
    }
    
    private var activeToggleChromeSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            ManageUserSectionTitle(text: "Account status")
            ManageUserCard {
                ManageUserPermissionToggleRow(
                    iconName: "smallcircle.filled.circle.fill",
                    iconBackground: ManageUserProfilePalette.chipBlueBg,
                    iconForeground: ManageUserProfilePalette.chipBlueFg,
                    title: "Active",
                    subtitle: "User can sign in and use the app",
                    isOn: $isActive
                )
            }
        }
    }

    /// Verified users: password reset only. Pending users: resend sign-up / invitation only (no Firebase reset — avoids clashing flows).
    private var actionsChromeSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            ManageUserSectionTitle(text: "Account actions")
            VStack(spacing: 8) {
                if canShowCredentialActions {
                    if user.passwordSet {
                        ManageUserAccountActionButton(
                            iconName: "key.fill",
                            iconBackground: ManageUserProfilePalette.chipBlueBg,
                            iconForeground: ManageUserProfilePalette.chipBlueFg,
                            title: "Send password reset",
                            action: { sendResetPasswordEmail() },
                            isBusy: isSendingResetPassword
                        )
                    } else {
                        let isPendingManagerOrOperative = (user.permissions.manager || user.permissions.operativeMode) &&
                            !user.permissions.adminAccess && !user.isSuperAdmin
                        ManageUserAccountActionButton(
                            iconName: isPendingManagerOrOperative ? "envelope.badge.fill" : "envelope.fill",
                            iconBackground: ManageUserProfilePalette.chipBlueBg,
                            iconForeground: ManageUserProfilePalette.chipBlueFg,
                            title: isPendingManagerOrOperative
                                ? "Resend sign-up email (verification code)"
                                : "Resend verification email",
                            action: { resendVerificationEmail() },
                            isBusy: isResendingEmail || isSendingSignUpEmail
                        )
                        Text("They have not finished setting a password yet. Resend the invitation email so they receive a new code and setup link.")
                            .font(.system(size: 11))
                            .foregroundStyle(ManageUserProfilePalette.textSecondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.leading, 4)
                    }

                    if let message = resetPasswordMessage ?? resendEmailMessage ?? signUpEmailMessage {
                        Text(message)
                            .font(.caption)
                            .foregroundStyle(ManageUserProfilePalette.textSecondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.leading, 4)
                    }
                }

                if canUseAdminAccountTools,
                   userStore.currentUser?.isSuperAdmin == true,
                   !user.isSuperAdmin,
                   !user.permissions.operativeMode,
                   (user.permissions.adminAccess || user.role == .admin) {
                    ManageUserAccountActionButton(
                        iconName: "crown.fill",
                        iconBackground: ManageUserProfilePalette.chipPurpleBg,
                        iconForeground: ManageUserProfilePalette.chipPurpleFg,
                        title: "Make Super Admin",
                        action: { transferSuperAdmin() },
                        isBusy: isTransferringSuperAdmin
                    )
                }

                if let message = transferSuperAdminMessage {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(ManageUserProfilePalette.textSecondary)
                        .padding(.leading, 4)
                }

                if userStore.hasAdminAccess(),
                   !user.isSuperAdmin,
                   !user.permissions.adminAccess,
                   (user.permissions.manager || user.permissions.operativeMode) {
                    ManageUserAccountActionButton(
                        iconName: "chart.line.uptrend.xyaxis",
                        iconBackground: ManageUserProfilePalette.chipPurpleBg,
                        iconForeground: ManageUserProfilePalette.chipPurpleFg,
                        title: "Holiday report",
                        action: { showingHolidayReport = true }
                    )
                }

                if canUseAdminAccountTools,
                   canEditPermissionsMatrix,
                   !userStore.isOrganizationCreator(userId: user.id) {
                    ManageUserAccountActionButton(
                        iconName: "person.crop.circle.badge.arrow.left.and.arrow.right",
                        iconBackground: ManageUserProfilePalette.chipPurpleBg,
                        iconForeground: ManageUserProfilePalette.chipPurpleFg,
                        title: "Change user type",
                        subtitle: "Switch between operative, manager, or administrator",
                        action: {
                            changeUserTypeDraft = UserRoleTransitionPolicy.kind(for: permissions)
                            applyDraftsForChangeUserTypeSelection()
                            userTypeChangeMessage = nil
                            showingChangeUserType = true
                        }
                    )
                }

                if canUseAdminAccountTools,
                   !userStore.isOrganizationCreator(userId: user.id) {
                    ManageUserAccountActionButton(
                        iconName: "pause.circle.fill",
                        iconBackground: ManageUserProfilePalette.chipAmberBg,
                        iconForeground: ManageUserProfilePalette.chipAmberFg,
                        title: isActive ? "Deactivate user" : "Reactivate user",
                        subtitle: "Suspend access, keep history",
                        titleColor: ManageUserProfilePalette.chipAmberFg,
                        borderColor: ManageUserProfilePalette.chipAmberBg,
                        showsChevron: false,
                        action: { toggleActiveStatus() },
                        isBusy: isUpdatingActiveStatus
                    )

                    if let message = activeStatusMessage {
                        Text(message)
                            .font(.caption)
                            .foregroundStyle(ManageUserProfilePalette.textSecondary)
                            .padding(.leading, 4)
                    }
                }

                if canUseAdminAccountTools,
                   userStore.canDeleteUser(user),
                   !userStore.isOrganizationCreator(userId: user.id) {
                    ManageUserAccountActionButton(
                        iconName: "trash.fill",
                        iconBackground: ManageUserProfilePalette.chipRedBg,
                        iconForeground: ManageUserProfilePalette.chipRedFg,
                        title: "Delete user",
                        subtitle: "Permanently remove account",
                        titleColor: ManageUserProfilePalette.chipRedFg,
                        borderColor: ManageUserProfilePalette.chipRedBg,
                        showsChevron: false,
                        action: { showingDeleteConfirmation = true }
                    )
                }
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
        VStack(alignment: .leading, spacing: 12) {
            if userStore.isOrganizationCreator(userId: user.id) {
                ManageUserSectionTitle(text: "Permissions")
                ManageUserCard {
                    HStack(alignment: .top, spacing: 12) {
                        ManageUserIconChip(
                            systemName: "lock.fill",
                            background: Color.orange.opacity(0.12),
                            foreground: Color.orange
                        )
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Super Admin")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(Color.orange)
                            Text("This user is the organization creator. Their permissions cannot be changed.")
                                .font(.system(size: 11))
                                .foregroundStyle(ManageUserProfilePalette.textSecondary)
                        }
                    }
                    .padding(16)
                }
            } else if !canEditPermissionsMatrix {
                Text("You do not have permission to change access for this user. Ask an organisation admin.")
                    .font(.subheadline)
                    .foregroundStyle(ManageUserProfilePalette.textSecondary)
                    .padding(.top, 4)
            } else if isManagerOperativeOnly && (user.permissions.operativeMode || user.role == .operative) {
                VStack(alignment: .leading, spacing: 8) {
                    ManageUserSectionTitle(text: "Permissions")
                    Text("You can adjust materials access for this operative. Other permissions are managed by an admin.")
                        .font(.system(size: 11))
                        .foregroundStyle(ManageUserProfilePalette.textSecondary)
                        .padding(.leading, 4)
                    ManageUserCard {
                        operativeMaterialsAndSiteAuditRows
                    }
                }
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    ManageUserSectionTitle(text: "Permissions")
                    if canUseAdminAccountTools && permissions.operativeMode {
                        ManageUserCard {
                            operativeMaterialsAndSiteAuditRows
                        }
                    } else {
                        ManageUserCard {
                            fullAdminPermissionMatrixRows
                        }
                    }
                }
            }
        }
    }

    private var operativeMaterialsAndSiteAuditRows: some View {
        VStack(spacing: 0) {
            ManageUserPermissionToggleRow(
                iconName: "shippingbox.fill",
                iconBackground: ManageUserProfilePalette.chipAmberBg,
                iconForeground: ManageUserProfilePalette.chipAmberFg,
                title: "Materials",
                subtitle: "Order & track stock",
                isOn: $permissions.materials
            )
            ManageUserCardDivider()
            ManageUserPermissionToggleRow(
                iconName: "checklist",
                iconBackground: ManageUserProfilePalette.chipTealBg,
                iconForeground: ManageUserProfilePalette.chipTealFg,
                title: "Site audit",
                subtitle: "Submit safety checks",
                isOn: $permissions.siteAudit
            )
        }
    }

    private var fullAdminPermissionMatrixRows: some View {
        Group {
            Group {
                ManageUserPermissionToggleRow(
                    iconName: "person.badge.key.fill",
                    iconBackground: ManageUserProfilePalette.chipPurpleBg,
                    iconForeground: ManageUserProfilePalette.chipPurpleFg,
                    title: "Admin Access",
                    subtitle: "Can add and manage users.",
                    isOn: $permissions.adminAccess,
                    isDisabled: false
                )
            }
            .onChange(of: permissions.adminAccess) { _, newValue in
                if newValue {
                    permissions.manager = true
                    permissions.projects = true
                    permissions.smallWorks = true
                }
            }

            ManageUserCardDivider()

            ManageUserPermissionToggleRow(
                iconName: "person.3.fill",
                iconBackground: ManageUserProfilePalette.chipPurpleBg,
                iconForeground: ManageUserProfilePalette.chipPurpleFg,
                title: "Manager",
                subtitle: "Managers will be able to schedule operatives, create new clients, skills, and qualifications, view warnings and manage tasks.",
                isOn: $permissions.manager,
                isDisabled: permissions.adminAccess
            )

            ManageUserCardDivider()

            ManageUserPermissionToggleRow(
                iconName: "folder.fill",
                iconBackground: ManageUserProfilePalette.chipBlueBg,
                iconForeground: ManageUserProfilePalette.chipBlueFg,
                title: "Projects",
                subtitle: "Can create and manage projects.",
                isOn: $permissions.projects,
                isDisabled: !permissions.manager && !permissions.adminAccess
            )

            ManageUserCardDivider()

            ManageUserPermissionToggleRow(
                iconName: "hammer.fill",
                iconBackground: ManageUserProfilePalette.chipBlueBg,
                iconForeground: ManageUserProfilePalette.chipBlueFg,
                title: "Small Works",
                subtitle: "Can create and manage small works.",
                isOn: $permissions.smallWorks,
                isDisabled: !permissions.manager && !permissions.adminAccess
            )

            ManageUserCardDivider()

            ManageUserPermissionToggleRow(
                iconName: "doc.text.fill",
                iconBackground: ManageUserProfilePalette.chipTealBg,
                iconForeground: ManageUserProfilePalette.chipTealFg,
                title: "Weekly Report",
                subtitle: "Will be able to pull weekly reports.",
                isOn: $permissions.weeklyReports,
                isDisabled: !permissions.manager && !permissions.adminAccess
            )

            ManageUserCardDivider()

            ManageUserPermissionToggleRow(
                iconName: "person.2.wave.2.fill",
                iconBackground: ManageUserProfilePalette.chipTealBg,
                iconForeground: ManageUserProfilePalette.chipTealFg,
                title: "Sub Contractors",
                subtitle: "Can add and manage sub contractors. If unselected they will be unable to manage them, they will only be able to book them in.",
                isOn: $permissions.subContractors,
                isDisabled: !permissions.manager && !permissions.adminAccess
            )

            if permissions.manager && !permissions.adminAccess {
                ManageUserCardDivider()
                ManageUserPermissionToggleRow(
                    iconName: "beach.umbrella.fill",
                    iconBackground: ManageUserProfilePalette.chipBlueBg,
                    iconForeground: ManageUserProfilePalette.chipBlueFg,
                    title: "Annual Leave",
                    subtitle: "Can book their own annual leave. If off, this manager requests leave for approval.",
                    isOn: $permissions.annualLeaveSelfBook,
                    isDisabled: false
                )
            }

            ManageUserCardDivider()

            ManageUserPermissionToggleRow(
                iconName: "person.crop.rectangle.stack.fill",
                iconBackground: ManageUserProfilePalette.chipPurpleBg,
                iconForeground: ManageUserProfilePalette.chipPurpleFg,
                title: "Operatives",
                subtitle: "Can manage operatives and view their details. If turned off, the user can still assign operatives to projects and small works, but will not see the Operatives tab or full operative profiles.",
                isOn: $permissions.operatives,
                isDisabled: false
            )

            ManageUserCardDivider()

            ManageUserPermissionToggleRow(
                iconName: "wrench.and.screwdriver.fill",
                iconBackground: ManageUserProfilePalette.chipPinkBg,
                iconForeground: ManageUserProfilePalette.chipPinkFg,
                title: "Skills",
                subtitle: "Can create and alter existing skills.",
                isOn: $permissions.skills,
                isDisabled: false
            )

            ManageUserCardDivider()

            ManageUserPermissionToggleRow(
                iconName: "rosette",
                iconBackground: ManageUserProfilePalette.chipPinkBg,
                iconForeground: ManageUserProfilePalette.chipPinkFg,
                title: "Qualifications",
                subtitle: "Can create and alter existing qualifications.",
                isOn: $permissions.qualifications,
                isDisabled: false
            )

            ManageUserCardDivider()

            ManageUserPermissionToggleRow(
                iconName: "shippingbox.fill",
                iconBackground: ManageUserProfilePalette.chipAmberBg,
                iconForeground: ManageUserProfilePalette.chipAmberFg,
                title: "Materials",
                subtitle: "For operatives: can view/use materials in assigned projects and small works.",
                isOn: $permissions.materials,
                isDisabled: true
            )

            ManageUserCardDivider()

            ManageUserPermissionToggleRow(
                iconName: "checklist",
                iconBackground: ManageUserProfilePalette.chipTealBg,
                iconForeground: ManageUserProfilePalette.chipTealFg,
                title: "Site Audit",
                subtitle: "For operatives: can open Site Audits in assigned projects and small works.",
                isOn: $permissions.siteAudit,
                isDisabled: true
            )
        }
    }
    
    private func saveChanges() {
        isUpdating = true
        
        Task {
            let dayRateEligible = permissions.operativeMode || permissions.manager
            if canEditPermissionsMatrix && dayRateEligible && !StaffTradeTypeFormSection.isValid(presetRaw: tradePresetRaw, customText: tradeCustomText) {
                await MainActor.run {
                    isUpdating = false
                    saveErrorMessage = "Please choose a trade type. If you select Other, enter the trade name."
                }
                return
            }
            
            var permissionsSuccess = true
            var didPersistPermissions = false
            if canEditPermissionsMatrix && !userStore.isOrganizationCreator(userId: user.id) {
                if canUseAdminAccountTools && permissions != user.permissions {
                    didPersistPermissions = true
                    permissionsSuccess = await userStore.updateUserPermissions(
                        userId: user.id,
                        permissions: permissions,
                        holidayStore: holidayStore,
                        linkedOperativeUUID: linkedOperativeForUser?.id
                    )
                } else if isManagerOperativeOnly && (user.permissions.operativeMode || user.role == .operative),
                          (permissions.materials != user.permissions.materials || permissions.siteAudit != user.permissions.siteAudit) {
                    didPersistPermissions = true
                    var merged = user.permissions
                    merged.materials = permissions.materials
                    merged.siteAudit = permissions.siteAudit
                    permissionsSuccess = await userStore.updateUserPermissions(
                        userId: user.id,
                        permissions: merged,
                        holidayStore: holidayStore,
                        linkedOperativeUUID: linkedOperativeForUser?.id
                    )
                }
            }
            
            var activeSuccess = true
            if canUseAdminAccountTools && isActive != user.isActive {
                activeSuccess = await userStore.updateUserActiveStatus(for: user, isActive: isActive)
            }

            var operativeDetailsSuccess = true
            let operativeProfileChanged = permissions.operativeMode && (
                (selectedAssignedManagerUserId ?? "") != (user.assignedManagerUserId ?? "") ||
                parseDayRate(dayRateText) != user.dayRate
            )
            if canEditPermissionsMatrix && operativeProfileChanged {
                let parsedDayRate = parseDayRate(dayRateText)
                operativeDetailsSuccess = await userStore.updateOperativeProfileFields(
                    for: user,
                    assignedManagerUserId: selectedAssignedManagerUserId,
                    dayRate: parsedDayRate,
                    operativeStore: operativeStore
                )
            }
            
            var managerDayRateSuccess = true
            let managerDayRateChanged = permissions.manager && !permissions.operativeMode && parseDayRate(dayRateText) != user.dayRate
            if canEditPermissionsMatrix && managerDayRateChanged {
                managerDayRateSuccess = await userStore.updateManagerDayRate(for: user, dayRate: parseDayRate(dayRateText))
            }
            
            var tradeSuccess = true
            let trimmedP = tradePresetRaw.trimmingCharacters(in: .whitespacesAndNewlines)
            let trimmedC = tradeCustomText.trimmingCharacters(in: .whitespacesAndNewlines)
            let origP = user.tradeTypePreset?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let origC = user.tradeTypeCustom?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let tradeDirty = dayRateEligible && (trimmedP != origP || trimmedC != origC)
            if canEditPermissionsMatrix && tradeDirty {
                tradeSuccess = await userStore.updateUserStaffTrade(
                    for: user,
                    tradeTypePreset: trimmedP.isEmpty ? nil : trimmedP,
                    tradeTypeCustom: trimmedC.isEmpty ? nil : trimmedC,
                    operativeStore: operativeStore
                )
            }

            if didPersistPermissions && permissionsSuccess {
                await holidayStore.loadData()
            }
            
            await MainActor.run {
                isUpdating = false
                if permissionsSuccess && activeSuccess && operativeDetailsSuccess && managerDayRateSuccess && tradeSuccess {
                    dismiss()
                } else {
                    saveErrorMessage = userStore.errorMessage ?? "Could not save these user changes. Please try again."
                }
            }
        }
    }

    private func parseDayRate(_ input: String) -> Double? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let normalized = trimmed
            .replacingOccurrences(of: ",", with: ".")
            .replacingOccurrences(of: localeCurrencySymbol(), with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return Double(normalized)
    }

    private func localeCurrencySymbol() -> String {
        if #available(iOS 16.0, *) {
            return Locale.current.currency?.identifier == nil ? (Locale.current.currencySymbol ?? "£") : (Locale.current.currencySymbol ?? "£")
        }
        return Locale.current.currencySymbol ?? "£"
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
                "materials": permissions.materials,
                "projects": permissions.projects,
                "smallWorks": permissions.smallWorks,
                "operativeMode": permissions.operativeMode,
                "weeklyReports": permissions.weeklyReports,
                "subContractors": permissions.subContractors,
                "siteAudit": permissions.siteAudit
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
                        "materials": user.permissions.materials,
                        "projects": user.permissions.projects,
                        "smallWorks": user.permissions.smallWorks,
                        "operativeMode": user.permissions.operativeMode,
                        "weeklyReports": user.permissions.weeklyReports,
                        "subContractors": user.permissions.subContractors,
                        "siteAudit": user.permissions.siteAudit
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
        .environmentObject(BookingStore())
        .environmentObject(OperativeStore())
        .environmentObject(HolidayStore())
        .environmentObject(FirebaseBackend())
}
