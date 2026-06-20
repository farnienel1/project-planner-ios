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
    @EnvironmentObject var notificationService: NotificationService
    @Environment(\.dismiss) private var dismiss
    
    @State private var showingAddUser = false
    @State private var selectedUser: AppUser?
    @State private var showingEditUser = false
    @State private var userToDelete: AppUser?
    @State private var showingDeleteConfirmation = false
    @State private var selectedTab = 0 // 0: Admins, 1: Managers, 2: Operatives
    @State private var rosterSegment: UserRosterSegment = .active
    @State private var searchText = ""
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
                        ScrollView {
                            manageUsersScrollContent
                        }
                        .background(ManageUserProfilePalette.pageBackground.ignoresSafeArea())
                    } else {
                        // Only admins can manage users – hide content from everyone else
                        manageUsersAccessDeniedView
                    }
                } else if userStore.organizationUsers.isEmpty {
                    emptyStateView
                } else {
                    ScrollView {
                        manageUsersScrollContent
                    }
                    .background(ManageUserProfilePalette.pageBackground.ignoresSafeArea())
                    .refreshable {
                        await userStore.loadOrganizationUsers()
                    }
                }
            }
            .background(ManageUserProfilePalette.pageBackground.ignoresSafeArea())
            .navigationTitle(isManagerOperativeManagement && !userStore.canManageUsers() ? "Manage Operatives" : "Manage Users")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Done") {
                        dismiss()
                    }
                    .font(.system(size: 17))
                    .foregroundStyle(ManageUserProfilePalette.listBlue)
                }
                
                if userStore.canManageUsers() || isManagerOperativeManagement {
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button(isManagerOperativeManagement && !userStore.canManageUsers() ? "Add Operative" : "Add") {
                            showingAddUser = true
                        }
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(ManageUserProfilePalette.listBlue)
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
                    .environmentObject(notificationService)
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
        .onChange(of: selectedTab) { _, _ in
            rosterSegment = .active
            searchText = ""
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

    // MARK: - Revamped list (matches manage-users-iphone.html / ManageUsers.tsx)

    private var manageUsersScrollContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            if userStore.canManageUsers() {
                manageUsersRoleSegment
            }
            manageUsersStatusChips
            manageUsersSearchBar
            manageUsersListHeader
            manageUsersCardList
            if userStore.canManageUsers() {
                manageUsersFooterLinks
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 40)
    }

    private var manageUsersRoleSegment: some View {
        HStack(spacing: 0) {
            manageUsersRoleButton(title: "Admins", tab: 0)
            manageUsersRoleButton(title: "Managers", tab: 1)
            manageUsersRoleButton(title: "Operatives", tab: 2)
        }
        .padding(2)
        .background(ManageUserProfilePalette.segmentedBackground)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func manageUsersRoleButton(title: String, tab: Int) -> some View {
        Button {
            withAnimation(.easeInOut(duration: 0.2)) { selectedTab = tab }
        } label: {
            Text(title)
                .font(.system(size: 13.5, weight: .semibold))
                .foregroundStyle(selectedTab == tab ? ManageUserProfilePalette.textPrimary : ManageUserProfilePalette.textPrimary.opacity(0.8))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(selectedTab == tab ? Color.white : Color.clear)
                        .shadow(color: selectedTab == tab ? Color.black.opacity(0.08) : .clear, radius: 2, y: 1)
                )
        }
        .buttonStyle(.plain)
    }

    private var manageUsersStatusChips: some View {
        HStack(spacing: 8) {
            ForEach(UserRosterSegment.allCases) { segment in
                let selected = rosterSegment == segment
                let count = rosterCount(for: segment)
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) { rosterSegment = segment }
                } label: {
                    HStack(spacing: 6) {
                        Text(segment.title)
                        Text("\(count)")
                            .font(.system(size: 11, weight: .bold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(
                                Capsule(style: .continuous)
                                    .fill(selected ? Color.white.opacity(0.25) : Color.black.opacity(0.07))
                            )
                    }
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(selected ? Color.white : ManageUserProfilePalette.textSecondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(selected ? ManageUserProfilePalette.listBlue : Color.white)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(selected ? ManageUserProfilePalette.listBlue : Color(red: 0xE5 / 255, green: 0xE7 / 255, blue: 0xEB / 255), lineWidth: 1)
                    )
                    .shadow(color: selected ? ManageUserProfilePalette.listBlue.opacity(0.25) : .clear, radius: 4, y: 2)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var manageUsersSearchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(ManageUserProfilePalette.textSecondary)
            TextField("Search", text: $searchText)
                .font(.system(size: 16))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(ManageUserProfilePalette.searchBackground)
        .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
    }

    private var manageUsersListHeader: some View {
        HStack {
            Text(roleSectionTitle.uppercased())
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(ManageUserProfilePalette.textSecondary)
                .tracking(0.5)
            Spacer()
            if !filteredUsers.isEmpty {
                Text("\(filteredUsers.count) \(filteredUsers.count == 1 ? "person" : "people")")
                    .font(.system(size: 13))
                    .foregroundStyle(ManageUserProfilePalette.textSecondary)
            }
        }
        .padding(.horizontal, 4)
    }

    @ViewBuilder
    private var manageUsersCardList: some View {
        if filteredUsers.isEmpty {
            manageUsersEmptyCard
        } else {
            LazyVStack(spacing: 11) {
                ForEach(filteredUsers) { user in
                    ManageUserRowView(user: user, showAdminBadge: selectedTab == 1 && (user.permissions.adminAccess || user.isSuperAdmin)) {
                        selectedUser = user
                    }
                    .environmentObject(userStore)
                    .contextMenu {
                        if userStore.canDeleteUser(user) {
                            Button(role: .destructive) {
                                userToDelete = user
                                showingDeleteConfirmation = true
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                    }
                }
            }
        }
    }

    private var manageUsersEmptyCard: some View {
        VStack(spacing: 16) {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(Color.white)
                .frame(width: 64, height: 64)
                .overlay {
                    Image(systemName: "person.3.fill")
                        .font(.system(size: 28))
                        .foregroundStyle(ManageUserProfilePalette.textSecondary.opacity(0.45))
                }
                .shadow(color: Color.black.opacity(0.05), radius: 3, y: 1)
            Text("No \(rosterSegment.title.lowercased()) \(roleSectionTitle.lowercased())")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(ManageUserProfilePalette.textSecondary)
            Text("There are no \(rosterSegment.title.lowercased()) \(roleSectionTitle.lowercased()) right now. Try another filter or add someone new.")
                .font(.system(size: 13.5))
                .foregroundStyle(ManageUserProfilePalette.textSecondary.opacity(0.75))
                .multilineTextAlignment(.center)
                .frame(maxWidth: 260)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 56)
    }

    private var manageUsersFooterLinks: some View {
        VStack(spacing: 10) {
            Button {
                dismiss()
                NotificationCenter.default.post(
                    name: NSNotification.Name("dismissManageUsersAndSelectTab"),
                    object: nil,
                    userInfo: ["tab": 3]
                )
            } label: {
                Label("View on Operatives page", systemImage: "person.3.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 13)
            }
            .buttonStyle(.plain)
            .foregroundStyle(ManageUserProfilePalette.chipPurpleFg)
            .background(ManageUserProfilePalette.chipPurpleBg)
            .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))

            if userStore.hasAdminAccess() {
                Button {
                    dismiss()
                    NotificationCenter.default.post(
                        name: NSNotification.Name("dismissManageUsersAndSelectTab"),
                        object: nil,
                        userInfo: ["tab": 4]
                    )
                } label: {
                    Label("View on Managers page", systemImage: "person.badge.key.fill")
                        .font(.system(size: 14, weight: .semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 13)
                }
                .buttonStyle(.plain)
                .foregroundStyle(ManageUserProfilePalette.chipPurpleFg)
                .background(ManageUserProfilePalette.chipPurpleBg)
                .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
            }
        }
        .padding(.top, 8)
    }

    private var roleSectionTitle: String {
        switch selectedTab {
        case 0: return "Administrators"
        case 1: return "Managers"
        default: return "Operatives"
        }
    }

    private func usersForRoleTab(_ tab: Int) -> [AppUser] {
        switch tab {
        case 0:
            return userStore.organizationUsers.filter { $0.permissions.adminAccess || $0.isSuperAdmin }
        case 1:
            return userStore.organizationUsers.filter { user in
                guard !user.permissions.operativeMode else { return false }
                return user.permissions.adminAccess || user.isSuperAdmin || user.permissions.manager
            }
        default:
            return userStore.organizationUsers.filter { $0.permissions.operativeMode }
        }
    }

    private var filteredUsers: [AppUser] {
        let tab = userStore.canManageUsers() ? selectedTab : 2
        var users = usersForRoleTab(tab).filter { rosterSegment.matches($0) }
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if !query.isEmpty {
            users = users.filter {
                $0.fullName.lowercased().contains(query) || $0.email.lowercased().contains(query)
            }
        }
        return users.sorted {
            ($0.fullName.isEmpty ? $0.email : $0.fullName).localizedCaseInsensitiveCompare($1.fullName.isEmpty ? $1.email : $1.fullName) == .orderedAscending
        }
    }

    private func rosterCount(for segment: UserRosterSegment) -> Int {
        let tab = userStore.canManageUsers() ? selectedTab : 2
        return usersForRoleTab(tab).filter { segment.matches($0) }.count
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

// MARK: - Badge flow (matches manage-users-iphone.html flex-wrap badges)

private struct ManageUserBadgeFlow: View {
    struct Badge: Identifiable {
        let id = UUID()
        let label: String
        let foreground: Color
        let background: Color
        let border: Color?

        init(label: String, foreground: Color, background: Color, border: Color?) {
            self.label = label
            self.foreground = foreground
            self.background = background
            self.border = border
        }
    }

    let badges: [Badge]

    var body: some View {
        FlowLayout(spacing: 6) {
            ForEach(badges) { badge in
                Text(badge.label)
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(badge.foreground)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(badge.background)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay {
                        if let border = badge.border {
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .stroke(border, lineWidth: 1)
                        }
                    }
            }
        }
    }
}

/// Simple left-to-right wrapping layout for badge chips.
private struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > maxWidth {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            rowHeight = max(rowHeight, size.height)
            x += size.width + spacing
        }
        return CGSize(width: maxWidth, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
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
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 13) {
                    avatarView
                    VStack(alignment: .leading, spacing: 2) {
                        Text(user.fullName.isEmpty ? user.email : user.fullName)
                            .font(.system(size: 16, weight: .bold))
                            .foregroundStyle(ManageUserProfilePalette.textPrimary)
                            .lineLimit(1)
                        Text(user.email)
                            .font(.system(size: 13))
                            .foregroundStyle(ManageUserProfilePalette.textSecondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    HStack(spacing: 9) {
                        if user.passwordSet && canShowPasswordResetOnRow {
                            keyActionButton
                        } else if canSendSignUpEmail && !user.passwordSet && isManagerOrOperative {
                            signUpActionButton
                        }
                        Image(systemName: "chevron.right")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(Color(red: 0xC4 / 255, green: 0xC4 / 255, blue: 0xCC / 255))
                    }
                }
                if !badges.isEmpty {
                    ManageUserBadgeFlow(badges: badges.map {
                        ManageUserBadgeFlow.Badge(label: $0.label, foreground: $0.foreground, background: $0.background, border: $0.border)
                    })
                        .padding(.top, 12)
                }
            }
            .padding(15)
            .background(Color.white)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(Color.black.opacity(0.02), lineWidth: 0.5)
            )
            .shadow(color: Color.black.opacity(0.04), radius: 2, y: 1)
        }
        .buttonStyle(.plain)
        .alert("Email", isPresented: Binding(
            get: { rowEmailFeedback != nil },
            set: { if !$0 { rowEmailFeedback = nil } }
        )) {
            Button("OK") { rowEmailFeedback = nil }
        } message: {
            if let message = rowEmailFeedback {
                Text(message)
            }
        }
    }

    private var avatarView: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: avatarGradientColors,
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .frame(width: 46, height: 46)
            Text(userInitials)
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(.white)
        }
    }

    private var userInitials: String {
        let f = user.firstName.prefix(1)
        let s = user.surname.prefix(1)
        let combined = "\(f)\(s)".uppercased()
        if combined.trimmingCharacters(in: .whitespaces).isEmpty {
            return String(user.email.prefix(2)).uppercased()
        }
        return combined
    }

    private var avatarGradientColors: [Color] {
        if user.permissions.operativeMode {
            return [Color(red: 0x16 / 255, green: 0xA3 / 255, blue: 0x4A / 255), Color(red: 0x0D / 255, green: 0x94 / 255, blue: 0x88 / 255)]
        }
        if user.permissions.adminAccess || user.isSuperAdmin {
            return [Color(red: 0x4F / 255, green: 0x46 / 255, blue: 0xE5 / 255), Color(red: 0x25 / 255, green: 0x63 / 255, blue: 0xEB / 255)]
        }
        return [Color(red: 0x25 / 255, green: 0x63 / 255, blue: 0xEB / 255), Color(red: 0x3B / 255, green: 0x82 / 255, blue: 0xF6 / 255)]
    }

    private struct RowBadge: Identifiable {
        let id = UUID()
        let label: String
        let foreground: Color
        let background: Color
        let border: Color?
    }

    private var badges: [RowBadge] {
        var items: [RowBadge] = []
        if user.isSuperAdmin || user.permissions.adminAccess {
            items.append(.init(label: "Administrator", foreground: Color(red: 0xE1 / 255, green: 0x1D / 255, blue: 0x48 / 255), background: Color(red: 0xFD / 255, green: 0xEC / 255, blue: 0xF1 / 255), border: nil))
        } else if user.permissions.manager {
            items.append(.init(label: "Manager", foreground: ManageUserProfilePalette.listBlue, background: ManageUserProfilePalette.chipBlueBg, border: nil))
        } else if user.permissions.operativeMode {
            items.append(.init(label: "Operative", foreground: Color(red: 0x15 / 255, green: 0xA3 / 255, blue: 0x4A / 255), background: Color(red: 0xE9 / 255, green: 0xF9 / 255, blue: 0xEF / 255), border: nil))
        }
        if let trade = tradeBadgeLabel {
            items.append(.init(label: trade, foreground: ManageUserProfilePalette.textSecondary, background: Color(red: 0xF9 / 255, green: 0xF9 / 255, blue: 0xFB / 255), border: Color(red: 0xE5 / 255, green: 0xE7 / 255, blue: 0xEB / 255)))
        }
        if !user.isActive && user.passwordSet {
            items.append(.init(label: "Inactive", foreground: ManageUserProfilePalette.textSecondary, background: Color(red: 0xEC / 255, green: 0xEC / 255, blue: 0xEF / 255), border: nil))
        } else if user.passwordSet {
            items.append(.init(label: "Verified", foreground: Color(red: 0x15 / 255, green: 0xA3 / 255, blue: 0x4A / 255), background: Color(red: 0xE9 / 255, green: 0xF9 / 255, blue: 0xEF / 255), border: nil))
        } else {
            items.append(.init(label: "Pending invite", foreground: Color(red: 0xE0 / 255, green: 0x86 / 255, blue: 0x00 / 255), background: Color(red: 0xFF / 255, green: 0xF5 / 255, blue: 0xE6 / 255), border: nil))
        }
        if showAdminBadge && !items.contains(where: { $0.label == "Administrator" }) {
            items.insert(.init(label: "Admin", foreground: Color(red: 0xE1 / 255, green: 0x1D / 255, blue: 0x48 / 255), background: Color(red: 0xFD / 255, green: 0xEC / 255, blue: 0xF1 / 255), border: nil), at: 0)
        }
        return items
    }

    private var tradeBadgeLabel: String? {
        if let custom = user.tradeTypeCustom?.trimmingCharacters(in: .whitespacesAndNewlines), !custom.isEmpty {
            return custom
        }
        if let preset = user.tradeTypePreset?.trimmingCharacters(in: .whitespacesAndNewlines), !preset.isEmpty, preset != "Other" {
            return preset
        }
        return nil
    }

    @ViewBuilder
    private var keyActionButton: some View {
        Button(action: { sendPasswordResetFromRow() }) {
            Group {
                if isSendingResetPassword {
                    ProgressView().scaleEffect(0.75)
                } else {
                    Image(systemName: "key.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(ManageUserProfilePalette.chipPurpleFg)
                }
            }
            .frame(width: 30, height: 30)
            .background(ManageUserProfilePalette.chipPurpleBg)
            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(isSendingResetPassword || isSendingSignUpEmail)
        .accessibilityLabel("Send password reset email")
    }

    @ViewBuilder
    private var signUpActionButton: some View {
        Button(action: { sendSignUpEmail() }) {
            Group {
                if isSendingSignUpEmail {
                    ProgressView().scaleEffect(0.75)
                } else {
                    Image(systemName: "envelope.badge.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(ManageUserProfilePalette.listBlue)
                }
            }
            .frame(width: 30, height: 30)
            .background(ManageUserProfilePalette.chipBlueBg)
            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(isSendingSignUpEmail || isSendingResetPassword)
        .accessibilityLabel("Resend sign-up email with verification code")
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
                        "dailyOverview": user.permissions.dailyOverview,
                        "subContractors": user.permissions.subContractors,
                        "siteAudit": user.permissions.siteAudit,
                        "wholesalersOrderHistory": user.permissions.wholesalersOrderHistory
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
}

// MARK: - Edit user dialogs (split out to keep EditUserView type-checkable)

private struct EditUserDialogModifier: ViewModifier {
    let user: AppUser
    let bookingStore: BookingStore
    @Binding var showingDeleteConfirmation: Bool
    @Binding var showingDeactivateConfirmation: Bool
    @Binding var saveErrorMessage: String?
    @Binding var showingEmploymentTypeConfirmation: Bool
    @Binding var employmentTypeConfirmationAccepted: Bool
    @Binding var showingEmploymentTypeEffectiveDatePicker: Bool
    @Binding var employmentTypeEffectiveDate: Date
    let employmentTypeDraft: EmploymentType
    @Binding var showingPayeDayRateWarning: Bool
    @Binding var pendingPayeDayRateText: String?
    @Binding var showingDayRateEffectiveChoice: Bool
    @Binding var showingQualificationsEditor: Bool
    @Binding var operativeForSkillsEditor: Operative?
    let linkedOperative: Operative?
    let canEditPermissionsMatrix: Bool
    let operativeStore: OperativeStore
    let firebaseBackend: FirebaseBackend
    @Binding var showingProfilePhotoSourcePicker: Bool
    @Binding var profilePhotoPickerSource: UIImagePickerController.SourceType
    @Binding var showingProfileImagePicker: Bool
    @Binding var pickedProfileImage: UIImage?
    @Binding var profilePhotoUploadMessage: String?
    let onDelete: () -> Void
    let onDeactivate: () -> Void
    let onPersistEdits: (Date?, Date?) -> Void
    let onUploadProfilePhoto: (UIImage) -> Void
    let calendarStartOfDay: (Date) -> Date
    let calendarStartOfTomorrow: () -> Date

    func body(content: Content) -> some View {
        content
            .alert("Delete user?", isPresented: $showingDeleteConfirmation) {
                Button("Cancel", role: .cancel) { }
                Button("Delete", role: .destructive, action: onDelete)
            } message: {
                deleteUserAlertMessage
            }
            .alert("Deactivate user?", isPresented: $showingDeactivateConfirmation) {
                Button("Cancel", role: .cancel) { }
                Button("Deactivate", role: .destructive, action: onDeactivate)
            } message: {
                Text("Are you sure you want to deactivate \(user.fullName)? They will not be able to sign in until an administrator reactivates them.")
            }
            .alert("Could Not Save", isPresented: saveErrorPresented) {
                Button("OK") { saveErrorMessage = nil }
            } message: {
                if let msg = saveErrorMessage {
                    Text(msg)
                }
            }
            .alert("Change Employment Type?", isPresented: $showingEmploymentTypeConfirmation) {
                Button("Cancel", role: .cancel) {
                    employmentTypeConfirmationAccepted = false
                }
                Button("Confirm Change") {
                    employmentTypeConfirmationAccepted = true
                    employmentTypeEffectiveDate = calendarStartOfDay(Date())
                    showingEmploymentTypeEffectiveDatePicker = true
                }
            } message: {
                Text("You are changing employment type to \(employmentTypeDraft.title). This affects timesheet access and day-rate handling.")
            }
            .alert("PAYE day rate", isPresented: $showingPayeDayRateWarning) {
                Button("OK", role: .cancel) {
                    pendingPayeDayRateText = nil
                }
            } message: {
                Text("This user is currently set as PAYE. If you add a day rate, then their rate will appear on the weekly report, as well as their timesheet.")
            }
            .sheet(isPresented: $showingEmploymentTypeEffectiveDatePicker) {
                employmentTypeEffectiveDateSheet
            }
            .confirmationDialog(
                "Day rate change",
                isPresented: $showingDayRateEffectiveChoice,
                titleVisibility: .visible
            ) {
                Button("Today") {
                    onPersistEdits(calendarStartOfDay(Date()), nil)
                }
                Button("Tomorrow") {
                    onPersistEdits(calendarStartOfTomorrow(), nil)
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("When the day rate is changed, the weekly report and invoicing (invoicing will be available in a future update) use the new rate from the working day you choose. If you want the new rate to apply from tomorrow, choose Tomorrow.")
            }
            .sheet(isPresented: $showingQualificationsEditor, onDismiss: { operativeForSkillsEditor = nil }) {
                if let operative = operativeForSkillsEditor ?? linkedOperative {
                    OperativeQualificationsEditorView(
                        operative: operative,
                        title: "Skills & Qualifications",
                        canEditAssignments: canEditPermissionsMatrix
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
                onUploadProfilePhoto(newImage)
            }
            .alert("Profile photo", isPresented: profilePhotoUploadPresented) {
                Button("OK") { profilePhotoUploadMessage = nil }
            } message: {
                if let profilePhotoUploadMessage {
                    Text(profilePhotoUploadMessage)
                }
            }
    }

    private var saveErrorPresented: Binding<Bool> {
        Binding(
            get: { saveErrorMessage != nil },
            set: { if !$0 { saveErrorMessage = nil } }
        )
    }

    private var profilePhotoUploadPresented: Binding<Bool> {
        Binding(
            get: { profilePhotoUploadMessage != nil },
            set: { if !$0 { profilePhotoUploadMessage = nil } }
        )
    }

    @ViewBuilder
    private var deleteUserAlertMessage: some View {
        let isManager = user.permissions.manager || user.permissions.adminAccess
        if isManager {
            let bookingCount = bookingStore.bookings.filter { $0.bookedBy == user.fullName }.count
            if bookingCount > 0 {
                Text("Are you sure you want to permanently delete \(user.fullName)? This cannot be undone.\n\nThis manager has \(bookingCount) booking\(bookingCount == 1 ? "" : "s"). All bookings will be reassigned to the super admin.")
            } else {
                Text("Are you sure you want to permanently delete \(user.fullName)? This cannot be undone.")
            }
        } else {
            Text("Are you sure you want to permanently delete \(user.fullName)? This cannot be undone.")
        }
    }

    private var employmentTypeEffectiveDateSheet: some View {
        NavigationStack {
            Form {
                Section("Employment type starts from") {
                    DatePicker(
                        employmentTypeDraft == .selfEmployed
                            ? "Select the date this user starts as Self-Employed"
                            : "Select the date this user starts as PAYE",
                        selection: $employmentTypeEffectiveDate,
                        in: ...Date.distantFuture,
                        displayedComponents: .date
                    )
                }
                Section {
                    Text("Timesheets and day-rate application use this date. Days before this date follow the previous employment type.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Employment Type Date")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        employmentTypeConfirmationAccepted = false
                        showingEmploymentTypeEffectiveDatePicker = false
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        let selected = calendarStartOfDay(employmentTypeEffectiveDate)
                        showingEmploymentTypeEffectiveDatePicker = false
                        onPersistEdits(nil, selected)
                    }
                }
            }
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
    @EnvironmentObject var notificationService: NotificationService
    @Environment(\.dismiss) private var dismiss
    
    let user: AppUser
    /// When `true` (e.g. opened from the Managers roster shortcut), hide **Admin Access** — grant admin only via Change user type in full Manage Users.
    let suppressAdminAccessToggle: Bool
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
    @State private var selectedLineManagerUserIds: Set<String> = []
    @State private var hasNoLineManagerDraft = false
    @State private var showingLineManagerPicker = false
    @State private var showingSelfBookOffConfirmation = false
    @State private var selfBookOffConfirmationAccepted = false
    @State private var dayRateText: String
    @State private var dayRateHistory: [OperativeDayRateHistoryEntry] = []
    @State private var showingQualificationsEditor = false
    @State private var operativeForSkillsEditor: Operative?
    @State private var openingSkillsEditor = false
    @State private var showingDayRateEffectiveChoice = false
    @State private var tradePresetRaw: String
    @State private var tradeCustomText: String
    @State private var editFirstName: String
    @State private var editSurname: String
    @State private var editEmail: String
    @State private var editMobile: String
    @State private var showingProfilePhotoSourcePicker = false
    @State private var profilePhotoPickerSource: UIImagePickerController.SourceType = .photoLibrary
    @State private var showingProfileImagePicker = false
    @State private var pickedProfileImage: UIImage?
    @State private var isUploadingProfilePhoto = false
    @State private var profilePhotoUploadMessage: String?
    @State private var showingChangeUserType = false
    @State private var changeUserTypeDraft: ManagedAccountKind = .operative
    @State private var managerSelfBookDraft = false
    @State private var managerTransitionOperatives = false
    @State private var managerTransitionSkills = true
    @State private var managerTransitionQualifications = true
    @State private var managerTransitionWeeklyReports = false
    @State private var managerTransitionDailyOverview = true
    @State private var managerTransitionSubContractors = false
    @State private var managerTransitionProjects = false
    @State private var managerTransitionSmallWorks = false
    @State private var operativeTransitionMaterials = false
    @State private var operativeTransitionSiteAudit = true
    @State private var isApplyingUserType = false
    @State private var userTypeChangeMessage: String?
    @State private var showingDeactivateConfirmation = false
    @State private var annualLeaveDaysText: String
    @State private var annualLeaveStartMonth: Int
    @State private var annualLeaveEndMonth: Int
    @State private var annualLeaveCarriesOver: Bool
    @State private var annualLeaveEnabledDraft: Bool
    @State private var employmentTypeDraft: EmploymentType
    @State private var showingEmploymentTypeConfirmation = false
    @State private var employmentTypeConfirmationAccepted = false
    @State private var showingEmploymentTypeEffectiveDatePicker = false
    @State private var employmentTypeEffectiveDate = Date()
    @State private var timesheetsEnabledDraft: Bool
    @State private var vatNumberDraft: String
    @State private var utrNumberDraft: String
    @State private var showingPayeDayRateWarning = false
    @State private var pendingPayeDayRateText: String?

    init(user: AppUser, suppressAdminAccessToggle: Bool = false) {
        self.user = user
        self.suppressAdminAccessToggle = suppressAdminAccessToggle
        self._permissions = State(initialValue: user.permissions)
        self._isActive = State(initialValue: user.isActive)
        self._selectedAssignedManagerUserId = State(initialValue: user.assignedManagerUserId)
        self._selectedLineManagerUserIds = State(initialValue: Set(user.lineManagerUserIds))
        self._hasNoLineManagerDraft = State(initialValue: user.hasNoLineManager)
        self._managerSelfBookDraft = State(initialValue: user.permissions.annualLeaveSelfBook)
        self._dayRateText = State(initialValue: Self.formatPayrollRateText(dayRate: user.dayRate, hourlyRate: user.hourlyRate))
        self._tradePresetRaw = State(initialValue: user.tradeTypePreset ?? "")
        self._tradeCustomText = State(initialValue: user.tradeTypeCustom ?? "")
        self._editFirstName = State(initialValue: user.firstName)
        self._editSurname = State(initialValue: user.surname)
        self._editEmail = State(initialValue: user.email)
        self._editMobile = State(initialValue: user.mobileNumber ?? "")
        self._annualLeaveDaysText = State(initialValue: EditUserView.formatAnnualLeaveDaysText(user.annualLeaveDaysPerYear))
        self._annualLeaveStartMonth = State(initialValue: user.annualLeaveYearStartMonth)
        self._annualLeaveEndMonth = State(initialValue: user.annualLeaveYearEndMonth)
        self._annualLeaveCarriesOver = State(initialValue: user.annualLeaveCarriesOver)
        self._annualLeaveEnabledDraft = State(initialValue: user.annualLeaveEnabled)
        self._employmentTypeDraft = State(initialValue: user.employmentType)
        self._timesheetsEnabledDraft = State(initialValue: user.timesheetsEnabled)
        self._vatNumberDraft = State(initialValue: user.vatNumber ?? "")
        self._utrNumberDraft = State(initialValue: user.utrNumber ?? "")
    }

    private static func formatAnnualLeaveDaysText(_ days: Double) -> String {
        let rounded = (days * 10).rounded() / 10
        if abs(rounded - Double(Int(rounded))) < 0.001 {
            return String(Int(rounded))
        }
        return String(format: "%.1f", rounded)
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
        let key: String
        if canEditIdentityDetails {
            let emailKey = editEmail.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
            let fallback = displayedUser.email.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
            key = emailKey.isEmpty ? fallback : emailKey
        } else {
            key = displayedUser.email.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return operativeStore.allOperatives.first {
            $0.email.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) == key
        }
    }
    
    /// Fresh row from the store (e.g. after profile photo upload).
    private var displayedUser: AppUser {
        userStore.organizationUsers.first(where: { $0.id == user.id }) ?? user
    }
    
    private var canUploadProfilePhoto: Bool {
        canEditPermissionsMatrix
    }

    private var canEditIdentityDetails: Bool {
        canEditPermissionsMatrix && !userStore.isOrganizationCreator(userId: user.id)
    }

    private var identityDirty: Bool {
        guard canEditIdentityDetails else { return false }
        let f = editFirstName.trimmingCharacters(in: .whitespacesAndNewlines)
        let s = editSurname.trimmingCharacters(in: .whitespacesAndNewlines)
        let e = editEmail.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let m = editMobile.trimmingCharacters(in: .whitespacesAndNewlines)
        let origM = user.mobileNumber?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return f != user.firstName.trimmingCharacters(in: .whitespacesAndNewlines) ||
            s != user.surname.trimmingCharacters(in: .whitespacesAndNewlines) ||
            e != user.email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ||
            m != origM
    }

    private var shouldShowAnnualLeaveAccessToggle: Bool {
        if userStore.isOrganizationCreator(userId: user.id) { return false }
        guard userStore.canEditTargetUserPermissions(displayedUser) else { return false }
        return permissions.operativeMode || user.role == .operative || permissions.manager || permissions.adminAccess
    }

    private var annualLeaveAccessDirty: Bool {
        guard shouldShowAnnualLeaveAccessToggle else { return false }
        return annualLeaveEnabledDraft != displayedUser.annualLeaveEnabled
    }

    private var annualLeaveAccessSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            ManageUserSectionTitle(text: "Annual leave in app")
            ManageUserCard {
                ManageUserPermissionToggleRow(
                    iconName: "calendar.badge.clock",
                    iconBackground: ManageUserProfilePalette.chipBlueBg,
                    iconForeground: ManageUserProfilePalette.chipBlueFg,
                    title: "Annual leave enabled",
                    subtitle: "Turn off for self-employed staff who do not use paid annual leave",
                    isOn: $annualLeaveEnabledDraft,
                    isDisabled: !canEditPermissionsMatrix
                )
                Text("When turned off, their Annual leave tab and annual leave entry points are hidden until this is turned back on here.")
                    .font(.caption)
                    .foregroundStyle(ManageUserProfilePalette.textSecondary)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 12)
            }
        }
    }

    private var shouldShowAnnualLeaveEntitlementSection: Bool {
        if userStore.isOrganizationCreator(userId: user.id) { return false }
        guard userStore.canEditTargetUserPermissions(displayedUser) else { return false }
        guard annualLeaveEnabledDraft else { return false }
        return permissions.operativeMode || user.role == .operative || permissions.manager
    }

    private func parsedAnnualLeaveDaysForSave() -> Double? {
        let t = annualLeaveDaysText.replacingOccurrences(of: ",", with: ".").trimmingCharacters(in: .whitespacesAndNewlines)
        guard let d = Double(t), d > 0 else { return nil }
        return AnnualLeavePolicy.clampDaysPerYear(d)
    }

    private var annualLeaveEntitlementDirty: Bool {
        guard shouldShowAnnualLeaveEntitlementSection else { return false }
        let s = userStore.organizationUsers.first(where: { $0.id == user.id }) ?? user
        guard let p = parsedAnnualLeaveDaysForSave() else { return true }
        return abs(p - s.annualLeaveDaysPerYear) > 0.0001
            || annualLeaveStartMonth != s.annualLeaveYearStartMonth
            || annualLeaveEndMonth != s.annualLeaveYearEndMonth
            || annualLeaveCarriesOver != s.annualLeaveCarriesOver
    }

    private var annualLeaveEntitlementSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            ManageUserSectionTitle(text: "Annual leave")
            ManageUserCard {
                AnnualLeaveEntitlementEditor(
                    daysText: $annualLeaveDaysText,
                    startMonth: $annualLeaveStartMonth,
                    endMonth: $annualLeaveEndMonth,
                    carriesOver: $annualLeaveCarriesOver,
                    isEnabled: canEditPermissionsMatrix
                )
                .padding(14)
            }
        }
    }

    private var headerDisplayName: String {
        guard canEditIdentityDetails else { return displayedUser.fullName }
        let combined = "\(editFirstName) \(editSurname)".trimmingCharacters(in: .whitespacesAndNewlines)
        return combined.isEmpty ? displayedUser.fullName : combined
    }

    private var profileInitialsLetters: String {
        let f = canEditIdentityDetails ? editFirstName : displayedUser.firstName
        let s = canEditIdentityDetails ? editSurname : displayedUser.surname
        let a = String(f.prefix(1)).uppercased()
        let b = String(s.prefix(1)).uppercased()
        if a.isEmpty && b.isEmpty {
            return "\(String(displayedUser.firstName.prefix(1)))\(String(displayedUser.surname.prefix(1)))".uppercased()
        }
        return "\(a)\(b)"
    }

    private func isValidEmail(_ raw: String) -> Bool {
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, t.contains("@"), t.contains(".") else { return false }
        return true
    }

    private var editNavigationTitle: String {
        permissions.operativeMode ? "Edit operative" : "Edit user"
    }

    private var showOperativeSetupCard: Bool {
        let eligible = permissions.operativeMode || permissions.manager || permissions.adminAccess
        return eligible && canEditPermissionsMatrix
    }

    private var lineManagerSummary: String {
        guard permissions.operativeMode || permissions.manager || permissions.adminAccess else { return "" }
        if hasNoLineManagerDraft { return "No line manager" }
        if selectedLineManagerUserIds.isEmpty { return "Select manager(s)…" }
        let names = lineManagerCandidates
            .filter { selectedLineManagerUserIds.contains($0.id) }
            .map { $0.fullName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? $0.email : $0.fullName }
        if names.count == 1 { return names[0] }
        return "\(names.first ?? "Manager") +\(names.count - 1) more"
    }

    private var operativeSetupSectionTitle: String {
        if permissions.operativeMode { return "Operative setup" }
        if permissions.manager { return "Manager setup" }
        if permissions.adminAccess { return "Administrator setup" }
        return "User setup"
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
                && managerTransitionDailyOverview == permissions.dailyOverview
                && managerTransitionSubContractors == permissions.subContractors
                && managerTransitionProjects == permissions.projects
                && managerTransitionSmallWorks == permissions.smallWorks
        case .administrator:
            return managerSelfBookDraft == permissions.annualLeaveSelfBook
        }
    }

    private func applyDraftsForChangeUserTypeSelection() {
        if let m = UserRoleTransitionPolicy.managerConfigForSheet(current: permissions, selectedKind: changeUserTypeDraft) {
            managerSelfBookDraft = m.annualLeaveSelfBook
            managerTransitionOperatives = m.operatives
            managerTransitionSkills = m.skills
            managerTransitionQualifications = m.qualifications
            managerTransitionWeeklyReports = m.weeklyReports
            managerTransitionDailyOverview = m.dailyOverview
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

    private var employmentTypeChanged: Bool {
        employmentTypeDraft != displayedUser.employmentType
    }

    private var shouldConfirmEmploymentTypeChange: Bool {
        guard employmentTypeChanged else { return false }
        guard let actingUser = userStore.currentUser else { return false }
        if actingUser.permissions.operativeMode { return false }
        return actingUser.isSuperAdmin || actingUser.permissions.adminAccess || actingUser.permissions.manager
    }

    private var employmentTransitionSummary: String {
        guard let from = displayedUser.employmentTypeTransitionFrom,
              let effective = displayedUser.employmentTypeEffectiveAt else {
            return "Effective immediately"
        }
        let dateText = effective.formatted(date: .abbreviated, time: .omitted)
        return "\(from.title) until \(dateText), then \(displayedUser.employmentType.title)"
    }
    
    // Check if any changes have been made
    private var hasChanges: Bool {
        if userStore.isOrganizationCreator(userId: user.id) {
            return permissions.annualLeaveSelfBook != user.permissions.annualLeaveSelfBook
        }
        let dayRateEligible = permissions.operativeMode || permissions.manager || permissions.adminAccess
        let trimmedTradeP = tradePresetRaw.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedTradeC = tradeCustomText.trimmingCharacters(in: .whitespacesAndNewlines)
        let origTradeP = user.tradeTypePreset?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let origTradeC = user.tradeTypeCustom?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let tradeChanged = dayRateEligible && (trimmedTradeP != origTradeP || trimmedTradeC != origTradeC)
        let billingChanged = normalizedVATDraft != displayedUser.vatNumber || normalizedUTRDraft != displayedUser.utrNumber
        let timesheetsChanged = timesheetsEnabledDraft != displayedUser.timesheetsEnabled
        let operativeProfileChanged = (permissions.operativeMode || permissions.manager || permissions.adminAccess) && (
            Set(selectedLineManagerUserIds) != Set(user.lineManagerUserIds) ||
            hasNoLineManagerDraft != user.hasNoLineManager ||
            parseDayRate(dayRateText) != user.dayRate
        )
        let staffDayRateChanged = !permissions.operativeMode && (permissions.manager || permissions.adminAccess)
            && parseDayRate(dayRateText) != user.dayRate
        if canUseAdminAccountTools {
            return identityDirty ||
                permissions != user.permissions ||
                isActive != user.isActive ||
                operativeProfileChanged ||
                staffDayRateChanged ||
                tradeChanged ||
                employmentTypeChanged ||
                annualLeaveAccessDirty ||
                annualLeaveEntitlementDirty ||
                billingChanged ||
                timesheetsChanged
        }
        if canEditPermissionsMatrix && (identityDirty || operativeProfileChanged || tradeChanged || staffDayRateChanged || employmentTypeChanged || annualLeaveAccessDirty || annualLeaveEntitlementDirty || billingChanged || timesheetsChanged) {
            return true
        }
        if isManagerOperativeOnly && (user.permissions.operativeMode || user.role == .operative) {
            return identityDirty ||
                permissions.materials != user.permissions.materials ||
                permissions.siteAudit != user.permissions.siteAudit ||
                tradeChanged ||
                employmentTypeChanged ||
                annualLeaveAccessDirty ||
                annualLeaveEntitlementDirty ||
                billingChanged ||
                timesheetsChanged
        }
        return false
    }

    private var normalizedVATDraft: String? {
        let trimmed = vatNumberDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private var normalizedUTRDraft: String? {
        let trimmed = utrNumberDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private var draftUserForAnnualLeaveValidation: AppUser {
        var draft = displayedUser
        draft.permissions = permissions
        draft.hasNoLineManager = hasNoLineManagerDraft
        return draft
    }

    private var lineManagerRoutingBlocked: Bool {
        guard canEditPermissionsMatrix else { return false }
        if permissions.operativeMode {
            return selectedLineManagerUserIds.isEmpty
        }
        if permissions.manager || permissions.adminAccess {
            if AnnualLeaveSelfBookPolicy.requiresLineManagerForAnnualLeaveRouting(for: draftUserForAnnualLeaveValidation) {
                return selectedLineManagerUserIds.isEmpty
            }
            return selectedLineManagerUserIds.isEmpty && !hasNoLineManagerDraft
        }
        return false
    }

    private var lineManagerValidationMessage: String? {
        guard lineManagerRoutingBlocked else { return nil }
        if AnnualLeaveSelfBookPolicy.requiresLineManagerForAnnualLeaveRouting(for: draftUserForAnnualLeaveValidation) {
            return "This user requires a Line Manager to Approve/Decline annual leave requests. Please set their line manager above."
        }
        if permissions.operativeMode {
            return "Line manager is required for operatives."
        }
        return "Please assign a line manager or choose No line manager."
    }

    private var willDisableAnnualLeaveSelfBookOnSave: Bool {
        let subject = displayedUser
        let oldDraft = AppUser(
            id: subject.id,
            email: subject.email,
            organizationId: subject.organizationId,
            role: subject.role,
            permissions: subject.permissions,
            hasNoLineManager: subject.hasNoLineManager
        )
        return AnnualLeaveSelfBookPolicy.canSelfBookAnnualLeave(for: oldDraft)
            && !AnnualLeaveSelfBookPolicy.canSelfBookAnnualLeave(for: draftUserForAnnualLeaveValidation)
    }

    private var lineManagerCandidates: [AppUser] {
        userStore.organizationUsers
            .filter { candidate in
                candidate.id != user.id &&
                !candidate.permissions.operativeMode &&
                (candidate.isSuperAdmin || candidate.permissions.adminAccess || candidate.permissions.manager) &&
                candidate.isActive &&
                candidate.passwordSet
            }
            .sorted { ($0.fullName.isEmpty ? $0.email : $0.fullName) < ($1.fullName.isEmpty ? $1.email : $1.fullName) }
    }
    
    var body: some View {
        editUserNavigationStack
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

    private var editUserNavigationStack: some View {
        NavigationStack {
            editUserScrollView
        }
        .modifier(EditUserDialogModifier(
            user: user,
            bookingStore: bookingStore,
            showingDeleteConfirmation: $showingDeleteConfirmation,
            showingDeactivateConfirmation: $showingDeactivateConfirmation,
            saveErrorMessage: $saveErrorMessage,
            showingEmploymentTypeConfirmation: $showingEmploymentTypeConfirmation,
            employmentTypeConfirmationAccepted: $employmentTypeConfirmationAccepted,
            showingEmploymentTypeEffectiveDatePicker: $showingEmploymentTypeEffectiveDatePicker,
            employmentTypeEffectiveDate: $employmentTypeEffectiveDate,
            employmentTypeDraft: employmentTypeDraft,
            showingPayeDayRateWarning: $showingPayeDayRateWarning,
            pendingPayeDayRateText: $pendingPayeDayRateText,
            showingDayRateEffectiveChoice: $showingDayRateEffectiveChoice,
            showingQualificationsEditor: $showingQualificationsEditor,
            operativeForSkillsEditor: $operativeForSkillsEditor,
            linkedOperative: linkedOperativeForUser,
            canEditPermissionsMatrix: canEditPermissionsMatrix,
            operativeStore: operativeStore,
            firebaseBackend: firebaseBackend,
            showingProfilePhotoSourcePicker: $showingProfilePhotoSourcePicker,
            profilePhotoPickerSource: $profilePhotoPickerSource,
            showingProfileImagePicker: $showingProfileImagePicker,
            pickedProfileImage: $pickedProfileImage,
            profilePhotoUploadMessage: $profilePhotoUploadMessage,
            onDelete: deleteUser,
            onDeactivate: toggleActiveStatus,
            onPersistEdits: { dayRateAt, employmentAt in
                Task { await runPersistUserEdits(dayRateEffectiveAt: dayRateAt, employmentTypeEffectiveAt: employmentAt) }
            },
            onUploadProfilePhoto: { image in
                Task { await uploadPickedProfilePhoto(image) }
            },
            calendarStartOfDay: { calendarStartOfDay($0) },
            calendarStartOfTomorrow: calendarStartOfTomorrow
        ))
        .alert("Turn off Annual Leave Management?", isPresented: $showingSelfBookOffConfirmation) {
            Button("Cancel", role: .cancel) {
                selfBookOffConfirmationAccepted = false
            }
            Button("Continue") {
                selfBookOffConfirmationAccepted = true
                saveChanges()
            }
        } message: {
            Text("Any annual leave that this user had booked in themselves, will disappear. They will be notified about this and will need to request annual leave bookings moving forward.")
        }
    }

    private var editUserScrollView: some View {
        ScrollView {
            editUserFormSections
        }
        .onAppear(perform: syncEditUserDraftsFromStore)
        .background(ManageUserProfilePalette.pageBackground.ignoresSafeArea())
        .navigationTitle(editNavigationTitle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { editUserToolbarContent }
    }

    @ViewBuilder
    private var editUserFormSections: some View {
        VStack(spacing: 18) {
            userInfoHeader
            userDetailsChromeSection
            if showOperativeSetupCard {
                VStack(alignment: .leading, spacing: 8) {
                    ManageUserSectionTitle(text: operativeSetupSectionTitle)
                    operativeAndManagerSetupCard
                }
            }
            editUserBillingAndTimesheetsSections
            if shouldShowAnnualLeaveAccessToggle {
                annualLeaveAccessSection
            }
            if shouldShowAnnualLeaveEntitlementSection {
                annualLeaveEntitlementSection
            }
            if canUseAdminAccountTools && !userStore.isOrganizationCreator(userId: user.id) {
                activeToggleChromeSection
            }
            permissionsSection
            if let lineManagerValidationMessage {
                Text(lineManagerValidationMessage)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .padding(.horizontal, 4)
            }
            if canShowCredentialActions || canUseAdminAccountTools {
                actionsChromeSection
            }
        }
        .padding(.horizontal, 18)
        .padding(.bottom, 32)
    }

    @ViewBuilder
    private var editUserBillingAndTimesheetsSections: some View {
        if canEditPermissionsMatrix {
            VStack(alignment: .leading, spacing: 8) {
                ManageUserSectionTitle(text: "Billing details")
                billingDetailsCard
            }
            VStack(alignment: .leading, spacing: 8) {
                ManageUserSectionTitle(text: "Timesheets access")
                timesheetsAccessCard
            }
        }
    }

    @ToolbarContentBuilder
    private var editUserToolbarContent: some ToolbarContent {
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
                    .disabled(isUpdating || !hasChanges || lineManagerRoutingBlocked)
            }
        }
    }

    private func syncEditUserDraftsFromStore() {
        let u = userStore.organizationUsers.first(where: { $0.id == user.id }) ?? user
        editFirstName = u.firstName
        editSurname = u.surname
        editEmail = u.email
        editMobile = u.mobileNumber ?? ""
        annualLeaveDaysText = EditUserView.formatAnnualLeaveDaysText(u.annualLeaveDaysPerYear)
        annualLeaveStartMonth = u.annualLeaveYearStartMonth
        annualLeaveEndMonth = u.annualLeaveYearEndMonth
        annualLeaveCarriesOver = u.annualLeaveCarriesOver
        annualLeaveEnabledDraft = u.annualLeaveEnabled
        employmentTypeDraft = u.employmentType
        timesheetsEnabledDraft = u.timesheetsEnabled
        vatNumberDraft = u.vatNumber ?? ""
        utrNumberDraft = u.utrNumber ?? ""
        hasNoLineManagerDraft = u.hasNoLineManager
        selectedLineManagerUserIds = Set(u.lineManagerUserIds)
        selectedAssignedManagerUserId = u.assignedManagerUserId
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
                            ManageUserExpandablePermissionToggleRow(
                                iconName: "person.crop.rectangle.stack.fill",
                                iconBackground: ManageUserProfilePalette.chipPurpleBg,
                                iconForeground: ManageUserProfilePalette.chipPurpleFg,
                                title: "Operatives",
                                description: "Can manage operatives and view their details. If turned off, the user can still assign operatives to projects and small works, but will not see the Manage Operatives screen or full operative profiles.",
                                isOn: $managerTransitionOperatives
                            )
                            ManageUserCardDivider()
                            ManageUserExpandablePermissionToggleRow(
                                iconName: "beach.umbrella.fill",
                                iconBackground: ManageUserProfilePalette.chipBlueBg,
                                iconForeground: ManageUserProfilePalette.chipBlueFg,
                                title: "Annual Leave Management",
                                description: "Can book their own annual leave. If off, this manager requests leave for approval.",
                                isOn: $managerSelfBookDraft
                            )
                            ManageUserCardDivider()
                            ManageUserExpandablePermissionToggleRow(
                                iconName: "doc.text.fill",
                                iconBackground: ManageUserProfilePalette.chipTealBg,
                                iconForeground: ManageUserProfilePalette.chipTealFg,
                                title: "Weekly Report",
                                description: "Can open and pull weekly reports.",
                                isOn: $managerTransitionWeeklyReports
                            )
                            ManageUserCardDivider()
                            ManageUserExpandablePermissionToggleRow(
                                iconName: "calendar.badge.clock",
                                iconBackground: ManageUserProfilePalette.chipTealBg,
                                iconForeground: ManageUserProfilePalette.chipTealFg,
                                title: "Daily Overview",
                                description: "Can open daily overview from the home screen and menus.",
                                isOn: $managerTransitionDailyOverview
                            )
                            ManageUserCardDivider()
                            ManageUserExpandablePermissionToggleRow(
                                iconName: "person.2.wave.2.fill",
                                iconBackground: ManageUserProfilePalette.chipTealBg,
                                iconForeground: ManageUserProfilePalette.chipTealFg,
                                title: "Sub Contractors",
                                description: "Can add and manage sub contractors. If unselected they can still book sub contractors in, but not manage their records.",
                                isOn: $managerTransitionSubContractors
                            )
                            ManageUserCardDivider()
                            ManageUserExpandablePermissionToggleRow(
                                iconName: "wrench.and.screwdriver.fill",
                                iconBackground: ManageUserProfilePalette.chipPinkBg,
                                iconForeground: ManageUserProfilePalette.chipPinkFg,
                                title: "Skills",
                                description: "Can create and alter existing skills.",
                                isOn: $managerTransitionSkills
                            )
                            ManageUserCardDivider()
                            ManageUserExpandablePermissionToggleRow(
                                iconName: "rosette",
                                iconBackground: ManageUserProfilePalette.chipPinkBg,
                                iconForeground: ManageUserProfilePalette.chipPinkFg,
                                title: "Qualifications",
                                description: "Can create and alter existing qualifications.",
                                isOn: $managerTransitionQualifications
                            )
                            ManageUserCardDivider()
                            ManageUserExpandablePermissionToggleRow(
                                iconName: "folder.fill",
                                iconBackground: ManageUserProfilePalette.chipBlueBg,
                                iconForeground: ManageUserProfilePalette.chipBlueFg,
                                title: "Projects",
                                description: "Can create and manage projects. If unselected, this manager can still schedule operatives and sub contractors.",
                                isOn: $managerTransitionProjects
                            )
                            ManageUserCardDivider()
                            ManageUserExpandablePermissionToggleRow(
                                iconName: "hammer.fill",
                                iconBackground: ManageUserProfilePalette.chipBlueBg,
                                iconForeground: ManageUserProfilePalette.chipBlueFg,
                                title: "Small Works",
                                description: "Can create and manage small works. If unselected, this manager can still schedule operatives and sub contractors.",
                                isOn: $managerTransitionSmallWorks
                            )
                        }
                        .background(Color.white)
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .stroke(Color(red: 0xE5 / 255, green: 0xE7 / 255, blue: 0xEB / 255), lineWidth: 0.5)
                        )

                        Text("If Annual Leave Management is turned on, pending approval requests are cleared.")
                            .font(.caption)
                            .foregroundStyle(ManageUserProfilePalette.textSecondary)
                    }

                    if changeUserTypeDraft == .administrator {
                        Text("Administrator access")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(ManageUserProfilePalette.textPrimary)

                        ManageUserCard {
                            ManageUserExpandablePermissionToggleRow(
                                iconName: "beach.umbrella.fill",
                                iconBackground: ManageUserProfilePalette.chipBlueBg,
                                iconForeground: ManageUserProfilePalette.chipBlueFg,
                                title: "Annual Leave Management",
                                description: "Can book their own annual leave. If off, this administrator requests leave for approval.",
                                isOn: $managerSelfBookDraft
                            )
                        }

                        Text("Other administrator permissions are granted automatically.")
                            .font(.caption)
                            .foregroundStyle(ManageUserProfilePalette.textSecondary)
                    }

                    if changeUserTypeDraft == .operative {
                        Text("Operative access")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(ManageUserProfilePalette.textPrimary)

                        VStack(spacing: 0) {
                            ManageUserExpandablePermissionToggleRow(
                                iconName: "shippingbox.fill",
                                iconBackground: ManageUserProfilePalette.chipAmberBg,
                                iconForeground: ManageUserProfilePalette.chipAmberFg,
                                title: "Materials",
                                description: "Can access material lists in projects and small works. They will not be able to send quotes or place orders.",
                                isOn: $operativeTransitionMaterials
                            )
                            ManageUserCardDivider()
                            ManageUserExpandablePermissionToggleRow(
                                iconName: "checklist",
                                iconBackground: ManageUserProfilePalette.chipTealBg,
                                iconForeground: ManageUserProfilePalette.chipTealFg,
                                title: "Site audit",
                                description: "Can view and submit site audits.",
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
        let managerConfig: ManagerUserTypeTransitionConfig? = (changeUserTypeDraft == .manager || changeUserTypeDraft == .administrator)
            ? (changeUserTypeDraft == .manager
                ? ManagerUserTypeTransitionConfig(
                    annualLeaveSelfBook: managerSelfBookDraft,
                    operatives: managerTransitionOperatives,
                    skills: managerTransitionSkills,
                    qualifications: managerTransitionQualifications,
                    weeklyReports: managerTransitionWeeklyReports,
                    dailyOverview: managerTransitionDailyOverview,
                    subContractors: managerTransitionSubContractors,
                    projects: managerTransitionProjects,
                    smallWorks: managerTransitionSmallWorks
                )
                : ManagerUserTypeTransitionConfig(
                    annualLeaveSelfBook: managerSelfBookDraft,
                    operatives: permissions.operatives,
                    skills: permissions.skills,
                    qualifications: permissions.qualifications,
                    weeklyReports: permissions.weeklyReports,
                    dailyOverview: permissions.dailyOverview,
                    subContractors: permissions.subContractors,
                    projects: permissions.projects,
                    smallWorks: permissions.smallWorks
                ))
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
                    selectedLineManagerUserIds = Set(fresh.lineManagerUserIds)
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
                    Text(headerDisplayName)
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(ManageUserProfilePalette.textPrimary)

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
                Text(profileInitialsLetters)
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
                    if canEditIdentityDetails {
                        ManageUserNameEditRow(firstName: $editFirstName, surname: $editSurname)
                        ManageUserCardDivider()
                        ManageUserDetailTextFieldRow(
                            iconName: "envelope.fill",
                            iconBackground: ManageUserProfilePalette.chipBlueBg,
                            iconForeground: ManageUserProfilePalette.chipBlueFg,
                            label: "Email",
                            placeholder: "name@company.com",
                            text: $editEmail,
                            keyboard: .emailAddress,
                            contentType: .emailAddress,
                            autocapitalization: .never
                        )
                        ManageUserCardDivider()
                        ManageUserDetailTextFieldRow(
                            iconName: "phone.fill",
                            iconBackground: ManageUserProfilePalette.chipTealBg,
                            iconForeground: ManageUserProfilePalette.chipTealFg,
                            label: "Mobile number",
                            placeholder: "Optional",
                            text: $editMobile,
                            keyboard: .phonePad,
                            contentType: .telephoneNumber,
                            autocapitalization: .never
                        )
                    } else {
                        ManageUserDetailStaticRow(
                            iconName: "person.fill",
                            iconBackground: ManageUserProfilePalette.chipPurpleBg,
                            iconForeground: ManageUserProfilePalette.chipPurpleFg,
                            label: "Name",
                            value: displayedUser.fullName
                        )
                        ManageUserCardDivider()
                        ManageUserDetailStaticRow(
                            iconName: "envelope.fill",
                            iconBackground: ManageUserProfilePalette.chipBlueBg,
                            iconForeground: ManageUserProfilePalette.chipBlueFg,
                            label: "Email",
                            value: displayedUser.email
                        )
                        ManageUserCardDivider()
                        ManageUserDetailStaticRow(
                            iconName: "phone.fill",
                            iconBackground: ManageUserProfilePalette.chipTealBg,
                            iconForeground: ManageUserProfilePalette.chipTealFg,
                            label: "Mobile number",
                            value: {
                                if let mobileNumber = displayedUser.mobileNumber, !mobileNumber.isEmpty { return mobileNumber }
                                return "—"
                            }()
                        )
                    }
                    ManageUserCardDivider()
                    ManageUserDetailStaticRow(
                        iconName: "calendar",
                        iconBackground: ManageUserProfilePalette.chipAmberBg,
                        iconForeground: ManageUserProfilePalette.chipAmberFg,
                        label: "Last active",
                        value: lastSeenDisplay(for: displayedUser)
                    )
                    ManageUserCardDivider()
                    if canEditPermissionsMatrix {
                        Menu {
                            ForEach(EmploymentType.allCases) { type in
                                Button(type.title) {
                                    employmentTypeDraft = type
                                    employmentTypeConfirmationAccepted = false
                                }
                            }
                        } label: {
                            ManageUserChevronRow(
                                iconName: "briefcase.fill",
                                iconBackground: ManageUserProfilePalette.chipBlueBg,
                                iconForeground: ManageUserProfilePalette.chipBlueFg,
                                label: "Employment type",
                                value: employmentTypeDraft.title
                            )
                        }
                        .buttonStyle(.plain)
                    } else {
                        ManageUserDetailStaticRow(
                            iconName: "briefcase.fill",
                            iconBackground: ManageUserProfilePalette.chipBlueBg,
                            iconForeground: ManageUserProfilePalette.chipBlueFg,
                            label: "Employment type",
                            value: employmentTypeDraft.title
                        )
                    }
                    ManageUserCardDivider()
                    ManageUserDetailStaticRow(
                        iconName: "calendar",
                        iconBackground: ManageUserProfilePalette.chipAmberBg,
                        iconForeground: ManageUserProfilePalette.chipAmberFg,
                        label: "Employment transition date",
                        value: employmentTransitionSummary
                    )
                }
            }
        }
    }

    private var operativeAndManagerSetupCard: some View {
        ManageUserCard {
            VStack(spacing: 0) {
                if permissions.operativeMode || permissions.manager || permissions.adminAccess {
                    lineManagerPickRow
                    ManageUserCardDivider()
                }
                ManageUserDayRateEditRow(dayRateText: $dayRateText, currencySymbol: localeCurrencySymbol())
                    .onChange(of: dayRateText) { _, newValue in
                        guard employmentTypeDraft == .paye else { return }
                        guard parseDayRate(newValue) != nil else { return }
                        guard parseDayRate(newValue) != displayedUser.dayRate else { return }
                        pendingPayeDayRateText = newValue
                        showingPayeDayRateWarning = true
                    }
                Text("Payroll uses either a day rate or an hourly rate, not both. Saving updates here applies the organisation rule: setting one clears the other on the account.")
                    .font(.caption2)
                    .foregroundStyle(ManageUserProfilePalette.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 6)
                ManageUserCardDivider()
                tradeTypePickSection
                if (permissions.operativeMode || permissions.manager || permissions.adminAccess) && !dayRateHistory.isEmpty {
                    ManageUserCardDivider()
                    dayRateHistoryChromeBlock
                }
                if canEditPermissionsMatrix,
                   permissions.operativeMode || permissions.manager || permissions.adminAccess {
                    ManageUserCardDivider()
                    ManageUserNavigationSubtitleRow(
                        iconName: "graduationcap.fill",
                        iconBackground: ManageUserProfilePalette.chipBlueBg,
                        iconForeground: ManageUserProfilePalette.chipBlueFg,
                        title: "Skills & qualifications",
                        subtitle: openingSkillsEditor ? "Opening…" : "Manage certifications",
                        action: { openSkillsAndQualifications() }
                    )
                    .disabled(openingSkillsEditor)
                }
            }
        }
    }

    private var billingDetailsCard: some View {
        ManageUserCard {
            VStack(spacing: 0) {
                ManageUserDetailTextFieldRow(
                    iconName: "doc.text.fill",
                    iconBackground: ManageUserProfilePalette.chipPurpleBg,
                    iconForeground: ManageUserProfilePalette.chipPurpleFg,
                    label: "VAT number",
                    placeholder: "If VAT registered",
                    text: $vatNumberDraft,
                    autocapitalization: .characters
                )
                ManageUserCardDivider()
                ManageUserDetailTextFieldRow(
                    iconName: "number",
                    iconBackground: ManageUserProfilePalette.chipAmberBg,
                    iconForeground: ManageUserProfilePalette.chipAmberFg,
                    label: "UTR number",
                    placeholder: "Unique Taxpayer Reference",
                    text: $utrNumberDraft,
                    autocapitalization: .characters
                )
            }
        }
    }

    private var timesheetsAccessCard: some View {
        ManageUserCard {
            ManageUserExpandablePermissionToggleRow(
                iconName: "clock.fill",
                iconBackground: ManageUserProfilePalette.chipTealBg,
                iconForeground: ManageUserProfilePalette.chipTealFg,
                title: "Timesheets",
                description: "When on, schedule feeds into timesheets and payroll sign-off applies. Operatives default to on; managers and admins default to off.",
                isOn: $timesheetsEnabledDraft
            )
            .onChange(of: permissions.operativeMode) { _, isOperative in
                syncTimesheetsToggleForOperativeMode(isOperative)
            }
            .onChange(of: permissions.adminAccess) { _, isAdmin in
                syncTimesheetsToggleForAdminAccess(isAdmin)
            }
            .onChange(of: permissions.manager) { _, isManager in
                syncTimesheetsToggleForManagerFlag(isManager)
            }
        }
    }

    private func syncTimesheetsToggleForOperativeMode(_ isOperative: Bool) {
        if isOperative && !timesheetsEnabledDraft {
            timesheetsEnabledDraft = true
        }
    }

    private func syncTimesheetsToggleForAdminAccess(_ isAdmin: Bool) {
        if isAdmin {
            timesheetsEnabledDraft = false
        }
    }

    private func syncTimesheetsToggleForManagerFlag(_ isManager: Bool) {
        if isManager && !permissions.operativeMode && !permissions.adminAccess {
            timesheetsEnabledDraft = false
        }
    }

    private var lineManagerPickRow: some View {
        Button {
            showingLineManagerPicker = true
        } label: {
            ManageUserChevronRow(
                iconName: "person.badge.plus",
                iconBackground: ManageUserProfilePalette.chipPurpleBg,
                iconForeground: ManageUserProfilePalette.chipPurpleFg,
                label: "Line manager(s)",
                value: lineManagerSummary
            )
        }
        .buttonStyle(.plain)
        .sheet(isPresented: $showingLineManagerPicker) {
            LineManagersMultiSelectSheet(
                candidates: lineManagerCandidates.filter { $0.id != user.id },
                selectedIds: $selectedLineManagerUserIds,
                allowNoLineManager: !permissions.operativeMode && (permissions.manager || permissions.adminAccess),
                hasNoLineManager: $hasNoLineManagerDraft
            )
        }
        .onChange(of: selectedLineManagerUserIds) { _, newIds in
            if !newIds.isEmpty { hasNoLineManagerDraft = false }
        }
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
        guard permissions.operativeMode || permissions.manager || permissions.adminAccess else {
            dayRateHistory = []
            return
        }
        guard let orgId = firebaseBackend.currentOrganization?.firestoreDocumentId else { return }
        let collection = (try? await firebaseBackend.loadOperativeDayRateHistory(organizationId: orgId)) ?? .empty
        dayRateHistory = collection
            .mergedEntries(userId: user.id, operativeId: linkedOperativeForUser?.id)
            .sorted(by: { $0.effectiveAt > $1.effectiveAt })
    }

    private func lastSeenDisplay(for u: AppUser) -> String {
        guard userStore.canManageUsers() else { return "—" }
        guard let t = u.lastSeenAt else { return "Never recorded" }
        return t.formatted(date: .abbreviated, time: .shortened)
    }

    private func calendarStartOfDay(_ date: Date) -> Date {
        Calendar.current.startOfDay(for: date)
    }

    private func calendarStartOfTomorrow() -> Date {
        let cal = Calendar.current
        let tomorrow = cal.date(byAdding: .day, value: 1, to: Date()) ?? Date()
        return cal.startOfDay(for: tomorrow)
    }

    private func shouldPromptDayRateEffectiveChoice(subjectUser: AppUser) -> Bool {
        guard canEditPermissionsMatrix else { return false }
        guard parseDayRate(dayRateText) != subjectUser.dayRate else { return false }
        if permissions.operativeMode { return true }
        if !permissions.operativeMode && (permissions.manager || permissions.adminAccess) { return true }
        return false
    }

    private func openSkillsAndQualifications() {
        guard canEditPermissionsMatrix else { return }
        openingSkillsEditor = true
        Task {
            let subject = userStore.organizationUsers.first(where: { $0.id == user.id }) ?? user
            let op: Operative?
            if let linked = linkedOperativeForUser {
                op = linked
            } else {
                op = await userStore.ensureOperativeProfileForAppUser(subject, operativeStore: operativeStore)
            }
            await MainActor.run {
                openingSkillsEditor = false
                operativeForSkillsEditor = op
                if op != nil {
                    showingQualificationsEditor = true
                } else {
                    saveErrorMessage = "Could not create a linked operative profile for skills. Check email and try again."
                }
            }
        }
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
                        title: "Annual leave report",
                        action: { showingHolidayReport = true }
                    )
                }

                if canUseAdminAccountTools,
                   canEditPermissionsMatrix,
                   !userStore.isOrganizationCreator(userId: user.id) {
                    ManageUserAccountActionButton(
                        iconName: "arrow.left.arrow.right.circle.fill",
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
                        action: {
                            if isActive {
                                showingDeactivateConfirmation = true
                            } else {
                                toggleActiveStatus()
                            }
                        },
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
        let target = userStore.organizationUsers.first(where: { $0.id == user.id }) ?? user
        Task {
            let ok = await userStore.updateUserActiveStatus(for: target, isActive: newValue)
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
                            Text("This user is the organization creator. Core permissions cannot be changed.")
                                .font(.system(size: 11))
                                .foregroundStyle(ManageUserProfilePalette.textSecondary)
                        }
                    }
                    .padding(16)
                }
                if permissions.manager || permissions.adminAccess {
                    ManageUserCard {
                        ManageUserExpandablePermissionToggleRow(
                            iconName: "beach.umbrella.fill",
                            iconBackground: ManageUserProfilePalette.chipBlueBg,
                            iconForeground: ManageUserProfilePalette.chipBlueFg,
                            title: "Annual Leave Management",
                            description: "Can book their own annual leave. If off, this user requests leave for approval.",
                            isOn: $permissions.annualLeaveSelfBook,
                            isDisabled: hasNoLineManagerDraft
                        )
                        .onChange(of: permissions.annualLeaveSelfBook) { oldValue, newValue in
                            if oldValue && !newValue && !hasNoLineManagerDraft {
                                selfBookOffConfirmationAccepted = false
                            }
                        }
                        if hasNoLineManagerDraft {
                            Text("No line manager is selected, so this user books their own annual leave without approval routing.")
                                .font(.caption)
                                .foregroundStyle(ManageUserProfilePalette.textSecondary)
                                .padding(.horizontal, 14)
                                .padding(.bottom, 8)
                        }
                    }
                }
            } else if !canEditPermissionsMatrix {
                Text("You do not have permission to change access for this user. Ask an organisation admin.")
                    .font(.subheadline)
                    .foregroundStyle(ManageUserProfilePalette.textSecondary)
                    .padding(.top, 4)
            } else if isManagerOperativeOnly && (user.permissions.operativeMode || user.role == .operative) {
                VStack(alignment: .leading, spacing: 8) {
                    ManageUserSectionTitle(text: "Permissions")
                    Text("You can adjust materials and site audit for this operative. Other permissions are managed by an admin.")
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
                    ManageUserCard {
                        VStack(spacing: 0) {
                            if permissions.operativeMode {
                                operativeMaterialsAndSiteAuditRows
                            } else {
                                adminAndManagerCapabilityPermissionRows
                                if !permissions.adminAccess {
                                    ManageUserCardDivider()
                                    nonOperativeMaterialsAndSiteAuditSummaryRows
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private var operativeMaterialsAndSiteAuditRows: some View {
        VStack(spacing: 0) {
            ManageUserExpandablePermissionToggleRow(
                iconName: "shippingbox.fill",
                iconBackground: ManageUserProfilePalette.chipAmberBg,
                iconForeground: ManageUserProfilePalette.chipAmberFg,
                title: "Materials",
                description: "Can access material lists in projects and small works. They will not be able to send quotes or place orders.",
                isOn: $permissions.materials
            )
            ManageUserCardDivider()
            ManageUserExpandablePermissionToggleRow(
                iconName: "checklist",
                iconBackground: ManageUserProfilePalette.chipTealBg,
                iconForeground: ManageUserProfilePalette.chipTealFg,
                title: "Site audit",
                description: "Can view and submit site audits.",
                isOn: $permissions.siteAudit
            )
        }
    }

    /// Core admin / manager flags (shown for every non–super-admin editable user). Materials & site audit for non-operatives are separate.
    private var adminAndManagerCapabilityPermissionRows: some View {
        Group {
            if !suppressAdminAccessToggle {
                Group {
                    ManageUserExpandablePermissionToggleRow(
                        iconName: "person.badge.key.fill",
                        iconBackground: ManageUserProfilePalette.chipPurpleBg,
                        iconForeground: ManageUserProfilePalette.chipPurpleFg,
                        title: "Admin Access",
                        description: "Can add and manage users.",
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
            }

            ManageUserExpandablePermissionToggleRow(
                iconName: "folder.fill",
                iconBackground: ManageUserProfilePalette.chipBlueBg,
                iconForeground: ManageUserProfilePalette.chipBlueFg,
                title: "Projects",
                description: "Can create and manage projects. If unselected, this manager can still schedule operatives and sub contractors.",
                isOn: $permissions.projects,
                isDisabled: false
            )

            ManageUserCardDivider()

            ManageUserExpandablePermissionToggleRow(
                iconName: "hammer.fill",
                iconBackground: ManageUserProfilePalette.chipBlueBg,
                iconForeground: ManageUserProfilePalette.chipBlueFg,
                title: "Small Works",
                description: "Can create and manage small works. If unselected, this manager can still schedule operatives and sub contractors.",
                isOn: $permissions.smallWorks,
                isDisabled: false
            )

            ManageUserCardDivider()

            ManageUserExpandablePermissionToggleRow(
                iconName: "doc.text.fill",
                iconBackground: ManageUserProfilePalette.chipTealBg,
                iconForeground: ManageUserProfilePalette.chipTealFg,
                title: "Weekly Report",
                description: "Can open and pull weekly reports.",
                isOn: $permissions.weeklyReports,
                isDisabled: false
            )

            ManageUserCardDivider()

            ManageUserExpandablePermissionToggleRow(
                iconName: "calendar.badge.clock",
                iconBackground: ManageUserProfilePalette.chipTealBg,
                iconForeground: ManageUserProfilePalette.chipTealFg,
                title: "Daily Overview",
                description: "Can open daily overview from the home screen and menus.",
                isOn: $permissions.dailyOverview,
                isDisabled: false
            )

            ManageUserCardDivider()

            ManageUserExpandablePermissionToggleRow(
                iconName: "person.2.wave.2.fill",
                iconBackground: ManageUserProfilePalette.chipTealBg,
                iconForeground: ManageUserProfilePalette.chipTealFg,
                title: "Sub Contractors",
                description: "Can add and manage sub contractors. If unselected they can still book sub contractors in, but not manage their records.",
                isOn: $permissions.subContractors,
                isDisabled: false
            )

            if (permissions.manager || permissions.adminAccess) && !permissions.operativeMode {
                ManageUserCardDivider()
                ManageUserExpandablePermissionToggleRow(
                    iconName: "beach.umbrella.fill",
                    iconBackground: ManageUserProfilePalette.chipBlueBg,
                    iconForeground: ManageUserProfilePalette.chipBlueFg,
                    title: "Annual Leave Management",
                    description: "Can book their own annual leave. If off, this user requests leave for approval.",
                    isOn: $permissions.annualLeaveSelfBook,
                    isDisabled: hasNoLineManagerDraft
                )
                .onChange(of: permissions.annualLeaveSelfBook) { oldValue, newValue in
                    if oldValue && !newValue && !hasNoLineManagerDraft {
                        selfBookOffConfirmationAccepted = false
                    }
                }
                if hasNoLineManagerDraft {
                    Text("No line manager is selected, so this user books their own annual leave without approval routing.")
                        .font(.caption)
                        .foregroundStyle(ManageUserProfilePalette.textSecondary)
                        .padding(.horizontal, 14)
                        .padding(.bottom, 8)
                }
            }

            ManageUserCardDivider()

            ManageUserExpandablePermissionToggleRow(
                iconName: "person.crop.rectangle.stack.fill",
                iconBackground: ManageUserProfilePalette.chipPurpleBg,
                iconForeground: ManageUserProfilePalette.chipPurpleFg,
                title: "Operatives",
                description: "Can manage operatives and view their details. If turned off, the user can still assign operatives to projects and small works, but will not see the Manage Operatives screen or full operative profiles.",
                isOn: $permissions.operatives,
                isDisabled: false
            )

            ManageUserCardDivider()

            ManageUserExpandablePermissionToggleRow(
                iconName: "wrench.and.screwdriver.fill",
                iconBackground: ManageUserProfilePalette.chipPinkBg,
                iconForeground: ManageUserProfilePalette.chipPinkFg,
                title: "Skills",
                description: "Can create and alter existing skills.",
                isOn: $permissions.skills,
                isDisabled: false
            )

            ManageUserCardDivider()

            ManageUserExpandablePermissionToggleRow(
                iconName: "rosette",
                iconBackground: ManageUserProfilePalette.chipPinkBg,
                iconForeground: ManageUserProfilePalette.chipPinkFg,
                title: "Qualifications",
                description: "Can create and alter existing qualifications.",
                isOn: $permissions.qualifications,
                isDisabled: false
            )

            ManageUserCardDivider()

            ManageUserExpandablePermissionToggleRow(
                iconName: "building.2.fill",
                iconBackground: ManageUserProfilePalette.chipAmberBg,
                iconForeground: ManageUserProfilePalette.chipAmberFg,
                title: "Wholesalers (order & quote history)",
                description: "Can view quote and order history in Wholesalers and on project materials. Wholesaler directory editing remains available to all managers.",
                isOn: $permissions.wholesalersOrderHistory,
                isDisabled: false
            )
        }
    }

    /// Read-only view of operative-only flags when editing a manager/admin account (not in operative mode).
    private var nonOperativeMaterialsAndSiteAuditSummaryRows: some View {
        Group {
            ManageUserExpandablePermissionToggleRow(
                iconName: "shippingbox.fill",
                iconBackground: ManageUserProfilePalette.chipAmberBg,
                iconForeground: ManageUserProfilePalette.chipAmberFg,
                title: "Materials (operative)",
                description: "Shown for reference on this account. Turn on operative mode to edit, or use Change user type.",
                isOn: $permissions.materials,
                isDisabled: true
            )
            ManageUserCardDivider()
            ManageUserExpandablePermissionToggleRow(
                iconName: "checklist",
                iconBackground: ManageUserProfilePalette.chipTealBg,
                iconForeground: ManageUserProfilePalette.chipTealFg,
                title: "Site Audit (operative)",
                description: "Shown for reference on this account. Turn on operative mode to edit, or use Change user type.",
                isOn: $permissions.siteAudit,
                isDisabled: true
            )
        }
    }
    
    private func saveChanges() {
        isUpdating = true
        Task {
            if lineManagerRoutingBlocked {
                await MainActor.run {
                    isUpdating = false
                    saveErrorMessage = lineManagerValidationMessage
                }
                return
            }
            if willDisableAnnualLeaveSelfBookOnSave && !selfBookOffConfirmationAccepted {
                await MainActor.run {
                    isUpdating = false
                    showingSelfBookOffConfirmation = true
                }
                return
            }
            if shouldConfirmEmploymentTypeChange && !employmentTypeConfirmationAccepted {
                await MainActor.run {
                    isUpdating = false
                    showingEmploymentTypeConfirmation = true
                }
                return
            }
            if employmentTypeChanged && employmentTypeConfirmationAccepted {
                await MainActor.run {
                    isUpdating = false
                    employmentTypeEffectiveDate = calendarStartOfDay(Date())
                    showingEmploymentTypeEffectiveDatePicker = true
                }
                return
            }
            if canEditIdentityDetails && identityDirty {
                guard isValidEmail(editEmail) else {
                    await MainActor.run {
                        isUpdating = false
                        saveErrorMessage = "Please enter a valid email address."
                    }
                    return
                }
            }

            let rateSubject = userStore.organizationUsers.first(where: { $0.id == user.id }) ?? user
            if shouldPromptDayRateEffectiveChoice(subjectUser: rateSubject) {
                await MainActor.run {
                    isUpdating = false
                    showingDayRateEffectiveChoice = true
                }
                return
            }

            await runPersistUserEdits(dayRateEffectiveAt: nil, employmentTypeEffectiveAt: nil)
        }
    }

    /// Persists edit-user changes. When `dayRateEffectiveAt` is non-nil, day-rate history uses that calendar day as the effective start (weekly report / future invoicing).
    private func runPersistUserEdits(dayRateEffectiveAt: Date?, employmentTypeEffectiveAt: Date?) async {
        await MainActor.run { isUpdating = true }

        var identitySuccess = true
        if canEditIdentityDetails && identityDirty {
            identitySuccess = await userStore.updateUserIdentityProfile(
                userId: user.id,
                firstName: editFirstName,
                surname: editSurname,
                email: editEmail,
                mobileNumber: editMobile.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? nil
                    : editMobile.trimmingCharacters(in: .whitespacesAndNewlines),
                operativeStore: operativeStore
            )
        }

        let subjectUser = userStore.organizationUsers.first(where: { $0.id == user.id }) ?? user
        let linkedOpId = operativeStore.allOperatives.first(where: {
            $0.email.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) ==
            subjectUser.email.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        })?.id

        let dayRateEligible = permissions.operativeMode || permissions.manager || permissions.adminAccess
        let trimmedP = tradePresetRaw.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedC = tradeCustomText.trimmingCharacters(in: .whitespacesAndNewlines)
        let origP = subjectUser.tradeTypePreset?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let origC = subjectUser.tradeTypeCustom?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let tradeDirty = dayRateEligible && (trimmedP != origP || trimmedC != origC)
        if canEditPermissionsMatrix && tradeDirty && !StaffTradeTypeFormSection.isValid(presetRaw: tradePresetRaw, customText: tradeCustomText) {
            await MainActor.run {
                isUpdating = false
                saveErrorMessage = "Please choose a trade type. If you select Other, enter the trade name."
            }
            return
        }

        var permissionsSuccess = true
        var didPersistPermissions = false
        let previousPermissions = subjectUser.permissions
        let previousHasNoLineManager = subjectUser.hasNoLineManager
        if canEditPermissionsMatrix && userStore.isOrganizationCreator(userId: user.id) {
            if permissions.annualLeaveSelfBook != subjectUser.permissions.annualLeaveSelfBook {
                didPersistPermissions = true
                var outgoing = subjectUser.permissions
                outgoing.annualLeaveSelfBook = permissions.annualLeaveSelfBook
                permissionsSuccess = await userStore.updateUserPermissions(
                    userId: user.id,
                    permissions: outgoing,
                    holidayStore: holidayStore,
                    linkedOperativeUUID: linkedOpId
                )
            }
        } else if canEditPermissionsMatrix && !userStore.isOrganizationCreator(userId: user.id) {
            if canUseAdminAccountTools && permissions != subjectUser.permissions {
                didPersistPermissions = true
                var outgoing = permissions
                if !outgoing.adminAccess && !outgoing.operativeMode {
                    outgoing.manager = true
                }
                permissionsSuccess = await userStore.updateUserPermissions(
                    userId: user.id,
                    permissions: outgoing,
                    holidayStore: holidayStore,
                    linkedOperativeUUID: linkedOpId
                )
            } else if isManagerOperativeOnly && (subjectUser.permissions.operativeMode || subjectUser.role == .operative),
                      (permissions.materials != subjectUser.permissions.materials || permissions.siteAudit != subjectUser.permissions.siteAudit) {
                didPersistPermissions = true
                var merged = subjectUser.permissions
                merged.materials = permissions.materials
                merged.siteAudit = permissions.siteAudit
                permissionsSuccess = await userStore.updateUserPermissions(
                    userId: user.id,
                    permissions: merged,
                    holidayStore: holidayStore,
                    linkedOperativeUUID: linkedOpId
                )
            }
        }

        var activeSuccess = true
        if canUseAdminAccountTools && isActive != subjectUser.isActive {
            activeSuccess = await userStore.updateUserActiveStatus(for: subjectUser, isActive: isActive)
        }

        var operativeDetailsSuccess = true
        let managerAssignmentChanged = Set(selectedLineManagerUserIds) != Set(subjectUser.lineManagerUserIds)
        let hasNoLineManagerChanged = hasNoLineManagerDraft != subjectUser.hasNoLineManager
        let operativeDayRateChanged = parseDayRate(dayRateText) != subjectUser.dayRate
        let operativeProfileChanged =
            (permissions.operativeMode && (managerAssignmentChanged || operativeDayRateChanged || hasNoLineManagerChanged))
            || ((permissions.manager || permissions.adminAccess) && (managerAssignmentChanged || hasNoLineManagerChanged))
        if canEditPermissionsMatrix && lineManagerRoutingBlocked {
            await MainActor.run {
                isUpdating = false
                saveErrorMessage = lineManagerValidationMessage
            }
            return
        }
        if canEditPermissionsMatrix && operativeProfileChanged {
            if selectedLineManagerUserIds.contains(subjectUser.id) {
                await MainActor.run {
                    isUpdating = false
                    saveErrorMessage = "A user cannot be their own line manager."
                }
                return
            }
        }
        if canEditPermissionsMatrix && operativeProfileChanged {
            let parsedDayRate = parseDayRate(dayRateText)
            let effectiveForHistory: Date? = operativeDayRateChanged ? (dayRateEffectiveAt ?? calendarStartOfDay(Date())) : nil
            let rateToPersist = operativeDayRateChanged ? parsedDayRate : subjectUser.dayRate
            let managerIds = hasNoLineManagerDraft ? [] : Array(selectedLineManagerUserIds)
            operativeDetailsSuccess = await userStore.updateOperativeProfileFields(
                for: subjectUser,
                assignedManagerUserId: managerIds.first,
                assignedManagerUserIds: managerIds,
                hasNoLineManager: hasNoLineManagerDraft,
                dayRate: permissions.operativeMode ? rateToPersist : subjectUser.dayRate,
                operativeStore: operativeStore,
                dayRateEffectiveAt: effectiveForHistory,
                updateDayRate: operativeDayRateChanged
            )
        }

        var managerDayRateSuccess = true
        let staffDayRateChanged = !permissions.operativeMode && (permissions.manager || permissions.adminAccess)
            && parseDayRate(dayRateText) != subjectUser.dayRate
        if canEditPermissionsMatrix && staffDayRateChanged {
            let parsed = parseDayRate(dayRateText)
            let effective = dayRateEffectiveAt ?? calendarStartOfDay(Date())
            managerDayRateSuccess = await userStore.updateManagerDayRate(
                for: subjectUser,
                dayRate: parsed,
                effectiveAt: effective,
                operativeStore: operativeStore
            )
        }

        var tradeSuccess = true
        if canEditPermissionsMatrix && tradeDirty {
            tradeSuccess = await userStore.updateUserStaffTrade(
                for: subjectUser,
                tradeTypePreset: trimmedP.isEmpty ? nil : trimmedP,
                tradeTypeCustom: trimmedC.isEmpty ? nil : trimmedC,
                operativeStore: operativeStore
            )
        }

        var employmentTypeSuccess = true
        if canEditPermissionsMatrix && employmentTypeChanged {
            employmentTypeSuccess = await userStore.updateUserEmploymentType(
                userId: user.id,
                employmentType: employmentTypeDraft,
                effectiveAt: employmentTypeEffectiveAt
            )
        }

        var annualLeaveEnabledSuccess = true
        if canEditPermissionsMatrix && annualLeaveAccessDirty {
            annualLeaveEnabledSuccess = await userStore.updateUserAnnualLeaveEnabled(userId: user.id, enabled: annualLeaveEnabledDraft)
        }

        var annualLeaveSuccess = true
        if canEditPermissionsMatrix && annualLeaveEntitlementDirty {
            guard let days = parsedAnnualLeaveDaysForSave() else {
                await MainActor.run {
                    isUpdating = false
                    saveErrorMessage = "Enter a valid annual leave allowance (a positive number of days)."
                }
                return
            }
            annualLeaveSuccess = await userStore.updateUserAnnualLeaveEntitlement(
                userId: user.id,
                daysPerYear: days,
                startMonth: annualLeaveStartMonth,
                endMonth: annualLeaveEndMonth,
                carriesOver: annualLeaveCarriesOver
            )
        }

        var billingSuccess = true
        if canEditPermissionsMatrix && (normalizedVATDraft != subjectUser.vatNumber || normalizedUTRDraft != subjectUser.utrNumber) {
            billingSuccess = await userStore.updateUserBillingProfile(
                userId: user.id,
                vatNumber: normalizedVATDraft,
                utrNumber: normalizedUTRDraft
            )
        }

        var timesheetsSuccess = true
        if canEditPermissionsMatrix && timesheetsEnabledDraft != subjectUser.timesheetsEnabled {
            timesheetsSuccess = await userStore.updateUserTimesheetsEnabled(
                userId: user.id,
                enabled: timesheetsEnabledDraft
            )
        }

        if didPersistPermissions && permissionsSuccess {
            await holidayStore.loadData()
        }

        let finalPermissions = didPersistPermissions ? permissions : subjectUser.permissions
        let finalHasNoLineManager = hasNoLineManagerChanged ? hasNoLineManagerDraft : subjectUser.hasNoLineManager
        let needsSelfBookClear = UserRoleTransitionPolicy.shouldClearSelfBookedAnnualLeave(
            old: previousPermissions,
            new: finalPermissions,
            oldHasNoLineManager: previousHasNoLineManager,
            newHasNoLineManager: finalHasNoLineManager
        )
        if needsSelfBookClear && permissionsSuccess && operativeDetailsSuccess {
            await holidayStore.deleteSelfBookedApprovedHolidaysFor(userId: user.id)
            await notificationService.notifyAnnualLeaveSelfBookDisabled(userId: user.id)
            await holidayStore.loadData()
        }

        await MainActor.run {
            isUpdating = false
            showingDayRateEffectiveChoice = false
            employmentTypeConfirmationAccepted = false
            showingEmploymentTypeEffectiveDatePicker = false
            selfBookOffConfirmationAccepted = false
            if identitySuccess && permissionsSuccess && activeSuccess && operativeDetailsSuccess && managerDayRateSuccess && tradeSuccess && employmentTypeSuccess && annualLeaveEnabledSuccess && annualLeaveSuccess && billingSuccess && timesheetsSuccess {
                dismiss()
            } else {
                saveErrorMessage = userStore.errorMessage ?? "Could not save these user changes. Please try again."
            }
        }
    }

    private static func formatPayrollRateText(dayRate: Double?, hourlyRate: Double?) -> String {
        if let dayRate, dayRate > 0 { return String(format: "%.2f", dayRate) }
        if let hourlyRate, hourlyRate > 0 { return String(format: "%.2f", hourlyRate) }
        return ""
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
                "dailyOverview": permissions.dailyOverview,
                "subContractors": permissions.subContractors,
                "siteAudit": permissions.siteAudit,
                "wholesalersOrderHistory": permissions.wholesalersOrderHistory
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
                        "dailyOverview": user.permissions.dailyOverview,
                        "subContractors": user.permissions.subContractors,
                        "siteAudit": user.permissions.siteAudit,
                        "wholesalersOrderHistory": user.permissions.wholesalersOrderHistory
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
