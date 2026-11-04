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
    @EnvironmentObject private var smartCache: SmartCacheService
    @Environment(\.dismiss) private var dismiss
    
    @State private var showingAddUser = false
    @State private var selectedUser: AppUser?
    @State private var showingEditUser = false
    @State private var userToDelete: AppUser?
    @State private var showingDeleteConfirmation = false
    /// A refused delete (RULEBOOK 1.31.0 `lineManagerChangeBlock` lists the reports; `userDeleteRefusal`).
    @State private var deleteErrorMessage: String?
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
        if userStore.hasAdminAccess() { return false }
        return CanonicalBusinessEngine.canManageOperatives(u.permissionSubject)
    }

    /// Signed in with Firebase Auth but org user doc not in memory yet — show spinner instead of “access denied”.
    private var needsProfileBeforeManageUsersGate: Bool {
        Auth.auth().currentUser != nil && userStore.currentUser == nil
    }

    private func openPendingUserEdit() {
        guard let userId = WorkCatalogueDeepLink.pendingEditUserId else { return }
        guard let user = userStore.organizationUsers.first(where: { $0.id == userId })
                ?? (userStore.currentUser?.id == userId ? userStore.currentUser : nil) else { return }
        WorkCatalogueDeepLink.pendingEditUserId = nil
        selectedUser = user
    }
    
    /// Always a pushed full page in the caller's navigation stack, with the system back button
    /// (no Done button, no nested NavigationStack). Home and the Settings hub both push it.
    var body: some View {
        Group {
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
                        .background(PPColor.page.ignoresSafeArea())
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
                    .background(PPColor.page.ignoresSafeArea())
                    .refreshable {
                        await userStore.loadOrganizationUsers()
                    }
                }
            }
            .background(PPColor.page.ignoresSafeArea())
            .navigationTitle(isManagerOperativeManagement && !userStore.canManageUsers() ? "Manage Operatives" : "Manage Users")
            .navigationBarTitleDisplayMode(.inline)
            .ppNavyNavigationBar()
            .toolbar {
                if userStore.canManageUsers() {
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button("Add") {
                            showingAddUser = true
                        }
                        .accessibilityIdentifier("manageUsers.add")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(.white)
                        // RULEBOOK §2: invites are online only.
                        .disabled(!smartCache.isOnline)
                    }
                }
            }
            .sheet(isPresented: $showingAddUser) {
                AddUserView(mode: .admin)
                    .environmentObject(userStore)
                    .environmentObject(firebaseBackend)
                    .environmentObject(smartCache)
            }
            .onAppear {
                openPendingUserEdit()
            }
            .onChange(of: userStore.organizationUsers.count) { _, _ in
                openPendingUserEdit()
            }
            .sheet(item: $selectedUser) { user in
                NavigationStack {
                    EditUserView(user: user)
                }
                .environmentObject(userStore)
                .environmentObject(bookingStore)
                .environmentObject(operativeStore)
                .environmentObject(holidayStore)
                .environmentObject(firebaseBackend)
                .environmentObject(notificationService)
                .environmentObject(smartCache)
            }
            .alert(
                "Could not delete",
                isPresented: Binding(get: { deleteErrorMessage != nil }, set: { if !$0 { deleteErrorMessage = nil } })
            ) {
                Button("OK") { deleteErrorMessage = nil }
            } message: {
                Text(deleteErrorMessage ?? "")
            }
            .alert("Delete User", isPresented: $showingDeleteConfirmation) {
                Button("Cancel", role: .cancel) {
                    userToDelete = nil
                }
                    .accessibilityIdentifier("manageUsers.cancel")
                Button("Delete", role: .destructive) {
                    if let user = userToDelete {
                        if userStore.canDeleteUser(user) {
                            Task {
                                print("🔥🔥🔥 DEBUG: Delete button tapped for user: \(user.fullName)")
                                userStore.errorMessage = nil
                                await userStore.deleteUser(user, bookingStore: bookingStore, operativeStore: operativeStore)
                                await userStore.loadOrganizationUsers()
                                await MainActor.run {
                                    userToDelete = nil
                                    if userStore.rosterRow(for: user.id) != nil, let message = userStore.errorMessage {
                                        deleteErrorMessage = message
                                    }
                                }
                            }
                        }
                    }
                }
                    .accessibilityIdentifier("manageUsers.delete")
                    .disabled(!smartCache.isOnline)
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
            if let userToHighlight, userToHighlight.isStoredUserDocument {
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
        .alert("Check your email", isPresented: Binding(
            get: { userStore.selfEmailChangeNotice != nil },
            set: { if !$0 { userStore.selfEmailChangeNotice = nil } }
        )) {
            Button("OK") { userStore.selfEmailChangeNotice = nil }
                .accessibilityIdentifier("manageUsers.selfEmailChange.ok")
        } message: {
            Text(userStore.selfEmailChangeNotice ?? "")
        }
    }

    // MARK: - Revamped list (matches manage-users-iphone.html / ManageUsers.tsx)

    private var manageUsersScrollContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            manageUsersNavyHeader

            VStack(alignment: .leading, spacing: 14) {
                if !smartCache.isOnline {
                    // RULEBOOK §2: every Manage Users change is online only.
                    Label(OfflinePolicy.onlineOnlyMessage, systemImage: "wifi.slash")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 4)
                        .accessibilityIdentifier("offlinePolicy.onlineOnlyMessage")
                }
                if userStore.hasAdminAccess() && !usersMissingLineManager.isEmpty {
                    usersMissingLineManagerNotice
                }
                if userStore.hasAdminAccess() && !usersMissingPayRate.isEmpty {
                    usersMissingPayRateNotice
                }
                if userStore.hasAdminAccess() && !usersWithAccountTypeOutOfSync.isEmpty {
                    accountTypeOutOfSyncNotice
                }
                if userStore.hasAdminAccess() && !usersMissingLevel.isEmpty {
                    usersMissingLevelNotice
                }
                manageUsersListHeader
                manageUsersCardList
            }
            .padding(.top, 18)
            .padding(.bottom, 40)
            .ppContentSheet()
        }
    }

    /// `usersMissingLineManager` over the loaded roster: operatives and managers saved before the line-manager
    /// requirement, and (RULEBOOK 1.28.0) admins with no line manager whose self-manage toggles are not both on
    /// (§8, §11). Their timesheets and requests reach every other active admin meanwhile.
    private var usersMissingLineManager: [AppUser] {
        AnnualLeaveApproval.usersMissingLineManager(userStore.organizationUsers)
    }

    /// RULEBOOK 1.14.0 §8, §11 `usersMissingPayRate`: active self-employed people saved before the pay-rate rule with no
    /// rate above 0 (a missing employment type reads as self-employed). Admins only, like web.
    private var usersMissingPayRate: [AppUser] {
        PayRateRequiredRulebook.usersMissingPayRate(rosterListed(userStore.organizationUsers, segment: .active))
    }

    private var usersMissingPayRateNotice: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(
                usersMissingPayRate.count == 1
                    ? "1 self-employed person needs a pay rate"
                    : "\(usersMissingPayRate.count) self-employed people need a pay rate",
                systemImage: "banknote"
            )
            .font(.subheadline.weight(.semibold))
            Text(CanonicalBusinessEngine.payRateRequiredMessage)
                .font(.caption)
                .foregroundStyle(.secondary)
            ForEach(usersMissingPayRate, id: \.id) { person in
                Button {
                    selectedUser = person
                } label: {
                    Text(person.fullName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? person.email : person.fullName)
                        .font(.footnote)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.blue)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .padding(.horizontal, 4)
        .accessibilityIdentifier("manageUsers.usersMissingPayRate")
    }

    /// RULEBOOK 1.12.2 §11 `accountTypeSyncState`: active people whose user type was only partly saved (users
    /// document vs the live `members.{uid}`). Opening the person and pressing Save finishes it on every record.
    private var usersWithAccountTypeOutOfSync: [AppUser] {
        rosterListed(userStore.organizationUsers, segment: .active).filter { person in
            person.accountTypeSyncState(in: firebaseBackend)?.inSync == false
        }
    }

    /// RULEBOOK 1.23.1 §11 `CanonicalBusinessEngine` `usersMissingLevel(roster)`: people with no user level (web lists
    /// them in Settings → Data health; iOS has no Data health screen, so admins see them here, where Change user type
    /// sets the level). Each row opens the person.
    private var usersMissingLevel: [AppUser] {
        RulebookRosterLists.usersMissingLevel(userStore.organizationUsers)
    }

    private var usersMissingLevelNotice: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(
                usersMissingLevel.count == 1 ? "1 person has no user level" : "\(usersMissingLevel.count) people have no user level",
                systemImage: "person.crop.circle.badge.questionmark"
            )
            .font(.subheadline.weight(.semibold))
            Text(RulebookRosterLists.missingLevelMessage)
                .font(.caption)
                .foregroundStyle(.secondary)
            ForEach(usersMissingLevel, id: \.id) { person in
                Button {
                    selectedUser = person
                } label: {
                    Text(person.fullName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? person.email : person.fullName)
                        .font(.footnote)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.blue)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .padding(.horizontal, 4)
        .accessibilityIdentifier("manageUsers.usersMissingLevel")
    }

    private var accountTypeOutOfSyncNotice: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(CanonicalBusinessEngine.accountTypeOutOfSyncMessage, systemImage: "exclamationmark.triangle.fill")
                .font(.subheadline.weight(.semibold))
            ForEach(usersWithAccountTypeOutOfSync, id: \.id) { person in
                Button {
                    selectedUser = person
                } label: {
                    Text(person.fullName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? person.email : person.fullName)
                        .font(.footnote)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.blue)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .padding(.horizontal, 4)
        .accessibilityIdentifier("manageUsers.accountTypeOutOfSync")
    }

    private var usersMissingLineManagerNotice: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(
                usersMissingLineManager.count == 1
                    ? "1 person needs a line manager for timesheet and annual leave approval."
                    : "\(usersMissingLineManager.count) people need a line manager for timesheet and annual leave approval.",
                systemImage: "person.crop.circle.badge.exclamationmark"
            )
            .font(.subheadline.weight(.semibold))
            ForEach(usersMissingLineManager, id: \.id) { person in
                Button {
                    selectedUser = person
                } label: {
                    Text(person.fullName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? person.email : person.fullName)
                        .font(.footnote)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.blue)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .padding(.horizontal, 4)
        .accessibilityIdentifier("manageUsers.usersMissingLineManager")
    }

    /// Home-style navy header: the people count the list already shows, then the existing role tabs, status chips and search.
    private var manageUsersNavyHeader: some View {
        VStack(alignment: .leading, spacing: 14) {
            PPOverviewTitle(
                eyebrow: manageUsersHeaderEyebrow,
                count: "\(filteredUsers.count)",
                countLabel: rosterSegment.title.lowercased()
            )
            .padding(.bottom, 4)

            if userStore.canManageUsers() {
                manageUsersRoleSegment
                manageUsersStatusChips
                manageUsersSearchBar
            } else {
                // Manage Operatives: search first for fast filtering.
                manageUsersSearchBar
                manageUsersStatusChips
            }
        }
        .padding(.horizontal, PPMetrics.screenGutter)
        .padding(.top, 14)
        .padding(.bottom, PPMetrics.headerBottomPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .ppNavyHeader()
    }

    /// Header caption only. Manage Operatives always lists operatives (same tab rule as `filteredUsers`).
    private var manageUsersHeaderEyebrow: String {
        userStore.canManageUsers() ? roleSectionTitle : "Operatives"
    }

    private var manageUsersRoleSegment: some View {
        HStack(spacing: 4) {
            manageUsersRoleButton(title: "Admins", tab: 0)
            manageUsersRoleButton(title: "Managers", tab: 1)
            manageUsersRoleButton(title: "Operatives", tab: 2)
        }
        .padding(4)
        .background(Capsule(style: .continuous).fill(PPColor.onNavyFill))
        .overlay(Capsule(style: .continuous).strokeBorder(PPColor.onNavyStroke, lineWidth: 0.5))
    }

    private func manageUsersRoleButton(title: String, tab: Int) -> some View {
        Button {
            withAnimation(.easeInOut(duration: 0.2)) { selectedTab = tab }
        } label: {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(selectedTab == tab ? PPColor.navy : Color.white.opacity(0.82))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 9)
                .background(
                    Capsule(style: .continuous)
                        .fill(selectedTab == tab ? Color.white : Color.clear)
                )
                .contentShape(Capsule(style: .continuous))
        }
        .accessibilityIdentifier("manageUsers.\(AccessibilityID.token(title))")
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
                            .font(.caption2.weight(.bold))
                            .monospacedDigit()
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(
                                Capsule(style: .continuous)
                                    .fill(selected ? PPColor.navy.opacity(0.10) : Color.white.opacity(0.12))
                            )
                    }
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(selected ? PPColor.navy : Color.white.opacity(0.85))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(selected ? Color.white : PPColor.onNavyFill)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(selected ? Color.clear : PPColor.onNavyStroke, lineWidth: 0.5)
                    )
                }
                .accessibilityIdentifier("manageUsers.row.\(segment.id)")
                .buttonStyle(.plain)
            }
        }
    }

    private var manageUsersSearchBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(PPColor.onNavySecondary)
            TextField(searchPlaceholder, text: $searchText)
                .accessibilityIdentifier("manageUsers.\(AccessibilityID.token(searchPlaceholder))")
                .font(.system(size: 16))
                .textInputAutocapitalization(.words)
                .autocorrectionDisabled()
                .submitLabel(.search)
            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 16))
                        .foregroundStyle(PPColor.onNavySecondary)
                }
                .accessibilityIdentifier("manageUsers.clearSearch")
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .foregroundStyle(.white)
        .background(PPColor.onNavyFill, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(PPColor.onNavyStroke, lineWidth: 0.5)
        )
    }

    private var searchPlaceholder: String {
        if isManagerOperativeManagement && !userStore.canManageUsers() {
            return "Search operatives by name"
        }
        switch selectedTab {
        case 0: return "Search admins by name"
        case 1: return "Search managers by name"
        default: return "Search operatives by name"
        }
    }

    private var manageUsersListHeader: some View {
        HStack {
            Text(roleSectionTitle.uppercased())
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
                .tracking(0.8)
            Spacer()
            if !filteredUsers.isEmpty {
                Text("\(filteredUsers.count) \(filteredUsers.count == 1 ? "person" : "people")")
                    .font(.footnote)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 4)
    }

    @ViewBuilder
    private var manageUsersCardList: some View {
        if filteredUsers.isEmpty {
            manageUsersEmptyCard
        } else {
            LazyVStack(spacing: 10) {
                ForEach(filteredUsers) { user in
                    ManageUserRowView(user: user, showAdminBadge: selectedTab == 1 && (user.permissions.adminAccess || user.isSuperAdmin)) {
                        guard user.isStoredUserDocument else { return }
                        selectedUser = user
                    }
                    .environmentObject(userStore)
                    .contextMenu {
                        if userStore.canDeleteUser(user) && smartCache.isOnline {
                            Button(role: .destructive) {
                                userToDelete = user
                                showingDeleteConfirmation = true
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                                .accessibilityIdentifier("manageUsers.row.\(user.id).delete")
                        }
                    }
                }
            }
        }
    }

    private var manageUsersEmptyCard: some View {
        VStack(spacing: 14) {
            PPIconTile(
                symbol: searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "person.3.fill" : "magnifyingglass",
                family: .people,
                size: PPMetrics.quickActionIcon,
                lifted: true
            )
            if !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text("No matches for “\(searchText.trimmingCharacters(in: .whitespacesAndNewlines))”")
                    .font(.system(.title3, design: .rounded))
                    .fontWeight(.semibold)
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.center)
                Text("Try another spelling, first name, surname, or email.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 260)
            } else {
                Text("No \(rosterSegment.title.lowercased()) \(roleSectionTitle.lowercased())")
                    .font(.system(.title3, design: .rounded))
                    .fontWeight(.semibold)
                    .foregroundStyle(.primary)
                Text(
                    userStore.canManageUsers()
                    ? "There are no \(rosterSegment.title.lowercased()) \(roleSectionTitle.lowercased()) right now. Try another filter or add someone new."
                    : "There are no \(rosterSegment.title.lowercased()) \(roleSectionTitle.lowercased()) right now. Ask an admin if someone is missing."
                )
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 260)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 36)
        .padding(.horizontal, 20)
        .background(PPColor.card, in: RoundedRectangle(cornerRadius: PPMetrics.cardRadius, style: .continuous))
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
            return userStore.rosterList(.admins)
        case 1:
            return userStore.rosterList(.managers)
        default:
            return userStore.rosterList(.operatives)
        }
    }

    private var filteredUsers: [AppUser] {
        let tab = userStore.canManageUsers() ? selectedTab : 2
        var users = rosterListed(usersForRoleTab(tab), segment: rosterSegment)
        users = users.filter { ManageOperativesSearch.matches(user: $0, query: searchText) }
        return ManageOperativesSearch.sorted(users, query: searchText)
    }

    private func rosterCount(for segment: UserRosterSegment) -> Int {
        let tab = userStore.canManageUsers() ? selectedTab : 2
        return rosterListed(usersForRoleTab(tab), segment: segment).count
    }

    /// People on this tab. The claim set is `organizations/{orgId}/userEmails` document ids.
    private func rosterListed(_ users: [AppUser], segment: UserRosterSegment) -> [AppUser] {
        let listed = CanonicalBusinessEngine.listedRosterUsers(
            users,
            claimedEmails: userStore.organizationUserEmailClaims
        ) ?? []
        return listed.filter { CanonicalBusinessEngine.rosterSegment($0) == segment.canonicalSegment }
    }
    
    // MARK: - Access Denied (non-admins)
    
    private var manageUsersAccessDeniedView: some View {
        VStack(spacing: 18) {
            Spacer()
            PPIconTile(symbol: "lock.shield.fill", family: .system, size: PPMetrics.quickActionIcon, lifted: true)
            Text("Manage Users")
                .font(.system(.title2, design: .rounded))
                .fontWeight(.bold)
            Text("Only users with admin access can manage users. If you need access, ask an administrator.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
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
            
            PPIconTile(symbol: "person.3.fill", family: .people, size: PPMetrics.quickActionIcon, lifted: true)
            
            VStack(spacing: 8) {
                Text("No Users Yet")
                    .font(.system(.title2, design: .rounded))
                    .fontWeight(.bold)
                
                Text("Add your first user to get started")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            
            if userStore.canManageUsers() {
            Button("Add First User") {
                showingAddUser = true
            }
            .accessibilityIdentifier("manageUsers.addFirstUser")
            .ppProminentCapsule()
            .onlineOnly(isOnline: smartCache.isOnline)
            }
            
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
        let admins = rosterListed(
            userStore.rosterList(.admins),
            segment: rosterSegment
        )
        return List {
            ForEach(admins) { user in
                ManageUserRowView(user: user, showAdminBadge: false) {
                    guard user.isStoredUserDocument else { return }
                    selectedUser = user
                }
                .environmentObject(userStore)
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    if userStore.canDeleteUser(user) && smartCache.isOnline {
                        Button(role: .destructive, action: {
                            userToDelete = user
                            showingDeleteConfirmation = true
                        }) {
                            Label("Delete", systemImage: "trash")
                        }
                            .accessibilityIdentifier("manageUsers.row.\(user.id).delete2")
                    }
                }
            }
        }
        .listStyle(PlainListStyle())
    }
    
    private var managersList: some View {
        let managers = rosterListed(
            userStore.rosterList(.managers),
            segment: rosterSegment
        )
        return List {
            ForEach(managers) { user in
                ManageUserRowView(user: user, showAdminBadge: user.permissions.adminAccess || user.isSuperAdmin) {
                    guard user.isStoredUserDocument else { return }
                    selectedUser = user
                }
                .environmentObject(userStore)
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    if userStore.canDeleteUser(user) && smartCache.isOnline {
                        Button(role: .destructive, action: {
                            userToDelete = user
                            showingDeleteConfirmation = true
                        }) {
                            Label("Delete", systemImage: "trash")
                        }
                            .accessibilityIdentifier("manageUsers.row.\(user.id).delete3")
                    }
                }
            }
        }
        .listStyle(PlainListStyle())
    }
    
    private var operativesList: some View {
        let operatives = rosterListed(
            userStore.rosterList(.operatives),
            segment: rosterSegment
        )
        return List {
            ForEach(operatives) { user in
                ManageUserRowView(user: user, showAdminBadge: false) {
                    guard user.isStoredUserDocument else { return }
                    selectedUser = user
                }
                .environmentObject(userStore)
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    if userStore.canDeleteUser(user) && smartCache.isOnline {
                        Button(role: .destructive, action: {
                            userToDelete = user
                            showingDeleteConfirmation = true
                        }) {
                            Label("Delete", systemImage: "trash")
                        }
                            .accessibilityIdentifier("manageUsers.row.\(user.id).delete4")
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
    @EnvironmentObject private var smartCache: SmartCacheService
    
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
                            .font(.body.weight(.semibold))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        Text(user.email)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
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
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.tertiary)
                    }
                }
                if !badges.isEmpty {
                    ManageUserBadgeFlow(badges: badges.map {
                        ManageUserBadgeFlow.Badge(label: $0.label, foreground: $0.foreground, background: $0.background, border: $0.border)
                    })
                        .padding(.top, 12)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 13)
            .background(PPColor.card, in: RoundedRectangle(cornerRadius: PPMetrics.rowCardRadius, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: PPMetrics.rowCardRadius, style: .continuous))
        }
        .accessibilityIdentifier("manageUserRow.chevronRight")
        .buttonStyle(.plain)
        .alert("Email", isPresented: Binding(
            get: { rowEmailFeedback != nil },
            set: { if !$0 { rowEmailFeedback = nil } }
        )) {
            Button("OK") { rowEmailFeedback = nil }
                .accessibilityIdentifier("manageUserRow.ok")
        } message: {
            if let message = rowEmailFeedback {
                Text(message)
            }
        }
    }

    private var avatarView: some View {
        Text(userInitials)
            .font(.system(size: 16, weight: .bold, design: .rounded))
            .foregroundStyle(.white)
            .frame(width: 46, height: 46)
            .background(avatarFamily.gradient, in: Circle())
            .overlay(Circle().strokeBorder(Color.white.opacity(0.22), lineWidth: 0.5))
    }

    /// Same role order as the old avatar colours: operative, then admin, then everyone else.
    private var avatarFamily: PPFamily {
        if user.permissions.operativeMode { return .sites }
        if user.permissions.adminAccess || user.isSuperAdmin { return .people }
        return .plan
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
            items.append(.init(label: trade, foreground: ManageUserProfilePalette.textSecondary, background: ProjectWorksRevampColors.grayTint, border: ProjectWorksRevampColors.searchBorder))
        }
        if user.rosterSegment == .inactive {
            items.append(.init(label: "Inactive", foreground: ManageUserProfilePalette.textSecondary, background: ProjectWorksRevampColors.grayTint, border: nil))
        } else if user.rosterSegment == .pending {
            items.append(.init(label: "Pending invite", foreground: Color(red: 0xE0 / 255, green: 0x86 / 255, blue: 0x00 / 255), background: Color(red: 0xFF / 255, green: 0xF5 / 255, blue: 0xE6 / 255), border: nil))
        } else if user.passwordSet {
            items.append(.init(label: "Verified", foreground: Color(red: 0x15 / 255, green: 0xA3 / 255, blue: 0x4A / 255), background: Color(red: 0xE9 / 255, green: 0xF9 / 255, blue: 0xEF / 255), border: nil))
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
        .accessibilityIdentifier("manageUserRow.sendPasswordReset")
        .buttonStyle(.plain)
        .disabled(isSendingResetPassword || isSendingSignUpEmail || !smartCache.isOnline)
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
        .accessibilityIdentifier("manageUserRow.resendSignUp")
        .buttonStyle(.plain)
        .disabled(isSendingSignUpEmail || isSendingResetPassword || !smartCache.isOnline)
        .accessibilityLabel("Resend sign-up email with verification code")
    }
    
    private func sendSignUpEmail() {
        isSendingSignUpEmail = true
        rowEmailFeedback = nil
        // RULEBOOK 1.12.0 §11 `invitationIsOperativeOnly`: refused here, before the old link is marked used.
        if let refusal = InvitationDocument.resendRefusal(subject: user, inviter: userStore.currentUser) {
            isSendingSignUpEmail = false
            rowEmailFeedback = "❌ \(refusal)"
            return
        }

        Task {
            let db = Firestore.firestore()
            do {
                // Mark all existing invitations for this email as used so only the new link works
                let existing = try await db.collection("invitations")
                    .whereField("email", isEqualTo: user.email)
                    .getDocuments()
                for doc in existing.documents {
                    try? await doc.reference.updateData(InvitationDocument.usedFields())
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
                        "skills": false,
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
                invitationData["employmentType"] = user.employmentType.rawValue
                // RULEBOOK 1.9.0 §11: created once with `invitationCreateFields`.
                // RULEBOOK 1.23.1 §11 `CanonicalBusinessEngine` `userMissingLevel`: never an invite without a user level.
                try RulebookRosterLists.requireInviteLevel(invitationData)
                try await db.collection("invitations").document(invitationId).setData(InvitationDocument.createFields(from: invitationData))

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
    @EnvironmentObject var notificationService: NotificationService
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
    @Binding var operativeForQualificationsEditor: Operative?
    let linkedOperative: Operative?
    let canEditPermissionsMatrix: Bool
    let operativeStore: OperativeStore
    let firebaseBackend: FirebaseBackend
    let userStore: UserStore
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
                    .accessibilityIdentifier("editUserDialogModifier.cancel")
                Button("Delete", role: .destructive, action: onDelete)
                    .accessibilityIdentifier("editUserDialogModifier.delete")
            } message: {
                deleteUserAlertMessage
            }
            .alert("Deactivate user?", isPresented: $showingDeactivateConfirmation) {
                Button("Cancel", role: .cancel) { }
                    .accessibilityIdentifier("editUserDialogModifier.cancel2")
                Button("Deactivate", role: .destructive, action: onDeactivate)
                    .accessibilityIdentifier("editUserDialogModifier.deactivate")
            } message: {
                Text("Are you sure you want to deactivate \(user.fullName)? They will not be able to sign in until an administrator reactivates them.")
            }
            .alert("Could Not Save", isPresented: saveErrorPresented) {
                Button("OK") { saveErrorMessage = nil }
                    .accessibilityIdentifier("editUserDialogModifier.ok")
            } message: {
                if let msg = saveErrorMessage {
                    Text(msg)
                }
            }
            .alert("Change Employment Type?", isPresented: $showingEmploymentTypeConfirmation) {
                Button("Cancel", role: .cancel) {
                    employmentTypeConfirmationAccepted = false
                }
                    .accessibilityIdentifier("editUserDialogModifier.cancel3")
                Button("Confirm Change") {
                    employmentTypeConfirmationAccepted = true
                    employmentTypeEffectiveDate = calendarStartOfDay(Date())
                    showingEmploymentTypeEffectiveDatePicker = true
                }
                    .accessibilityIdentifier("editUserDialogModifier.confirmChange")
            } message: {
                Text("You are changing employment type to \(employmentTypeDraft.title). This affects timesheet access and day-rate handling.")
            }
            .alert("PAYE day rate", isPresented: $showingPayeDayRateWarning) {
                Button("OK", role: .cancel) {
                    pendingPayeDayRateText = nil
                }
                    .accessibilityIdentifier("editUserDialogModifier.ok2")
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
                    .accessibilityIdentifier("editUserDialogModifier.today")
                Button("Tomorrow") {
                    onPersistEdits(calendarStartOfTomorrow(), nil)
                }
                    .accessibilityIdentifier("editUserDialogModifier.tomorrow")
                Button("Cancel", role: .cancel) {}
                    .accessibilityIdentifier("editUserDialogModifier.cancel4")
            } message: {
                Text("When the day rate is changed, the weekly report and invoicing (invoicing will be available in a future update) use the new rate from the working day you choose. If you want the new rate to apply from tomorrow, choose Tomorrow.")
            }
            .sheet(isPresented: $showingQualificationsEditor, onDismiss: { operativeForQualificationsEditor = nil }) {
                qualificationsEditorSheet
            }
            .confirmationDialog("Profile photo", isPresented: $showingProfilePhotoSourcePicker, titleVisibility: .visible) {
                if UIImagePickerController.isSourceTypeAvailable(.camera) {
                    Button("Take Photo") {
                        profilePhotoPickerSource = .camera
                        showingProfileImagePicker = true
                    }
                        .accessibilityIdentifier("editUserDialogModifier.takePhoto")
                }
                Button("Photo Library") {
                    profilePhotoPickerSource = .photoLibrary
                    showingProfileImagePicker = true
                }
                    .accessibilityIdentifier("editUserDialogModifier.photoLibrary")
                Button("Cancel", role: .cancel) {}
                    .accessibilityIdentifier("editUserDialogModifier.cancel5")
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
                    .accessibilityIdentifier("editUserDialogModifier.ok3")
            } message: {
                if let profilePhotoUploadMessage {
                    Text(profilePhotoUploadMessage)
                }
            }
    }

    @ViewBuilder
    private var qualificationsEditorSheet: some View {
        if let operative = operativeForQualificationsEditor ?? linkedOperative {
            OperativeQualificationsEditorView(
                operative: operative,
                title: "Qualifications",
                canEditAssignments: canEditPermissionsMatrix
            )
            .environmentObject(operativeStore)
            .environmentObject(firebaseBackend)
            .environmentObject(notificationService)
            .environmentObject(userStore)
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
        let london = CanonicalBusinessEngine.businessCalendar
        let today = london.startOfDay(for: Date())
        let tomorrow = london.date(byAdding: .day, value: 1, to: today) ?? today
        return NavigationStack {
            Form {
                Section {
                    Text("When should \(employmentTypeDraft.title) start? Timesheets and the weekly report use the type that applies on each working day.")
                        .font(.subheadline)
                }
                Section {
                    Button("Today") {
                        showingEmploymentTypeEffectiveDatePicker = false
                        onPersistEdits(nil, today)
                    }
                    .accessibilityIdentifier("editUser.employmentEffective.today")
                    Button("Tomorrow") {
                        showingEmploymentTypeEffectiveDatePicker = false
                        onPersistEdits(nil, tomorrow)
                    }
                    .accessibilityIdentifier("editUser.employmentEffective.tomorrow")
                }
                Section("Or pick a working day") {
                    DatePicker(
                        "Employment date",
                        selection: $employmentTypeEffectiveDate,
                        displayedComponents: .date
                    )
                    .accessibilityIdentifier("editUserDialogModifier.selectTheDateThisUserStarts")
                    Button("Use this date") {
                        let selected = london.startOfDay(for: employmentTypeEffectiveDate)
                        showingEmploymentTypeEffectiveDatePicker = false
                        onPersistEdits(nil, selected)
                    }
                    .accessibilityIdentifier("editUserDialogModifier.save")
                }
            }
            .navigationTitle("Employment type")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        employmentTypeConfirmationAccepted = false
                        showingEmploymentTypeEffectiveDatePicker = false
                    }
                    .accessibilityIdentifier("editUserDialogModifier.cancel6")
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
    @EnvironmentObject private var smartCache: SmartCacheService
    @Environment(\.dismiss) private var dismiss
    
    let user: AppUser
    /// When `true` (e.g. opened from the Managers roster shortcut), hide **Admin Access** — grant admin only via Change user type in full Manage Users.
    let suppressAdminAccessToggle: Bool
    @State private var permissions: UserPermissions
    /// The stored permissions the editor's draft started from. A save writes only the flags changed against this,
    /// and the draft follows the live row while nothing has been changed (RULEBOOK §1 partial writes).
    @State private var permissionsBaseline: UserPermissions
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
    @State private var showingChangeSuperAdminPicker = false
    @State private var showingChangeSuperAdminConfirmation = false
    @State private var pendingSuperAdminUserId: String?
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
    /// RULEBOOK 1.26.1 §8: the pay editor's record (`UserStore.payEditorRecord`, `CanonicalBusinessEngine`
    /// `payEditorStartingValues`) — the starting value AND the save baseline. Nil until read; while `privatePay` is off
    /// it is never read and the stored document is used, as before.
    @State private var payRecord: AppUser?
    /// RULEBOOK 1.26.1 §8: read again when the security switches change while the editor is open (`PayEditorLoadGate`).
    @State private var payLoadGate = PayEditorLoadGate()
    /// The record the pay drafts were last seeded from; an untouched draft follows a re-read (nil: the opened row).
    @State private var payDraftSeed: AppUser?
    /// RULEBOOK 1.14.0 `payRateRequiredError`, shown under the rate field after a refused save.
    @State private var payRateFieldError: String?
    @State private var dayRateHistory: [OperativeDayRateHistoryEntry] = []
    @State private var showingQualificationsEditor = false
    @State private var operativeForQualificationsEditor: Operative?
    @State private var openingQualificationsEditor = false
    @State private var showingDayRateEffectiveChoice = false
    @State private var tradePresetRaw: String
    @State private var tradeCustomText: String
    @State private var editFirstName: String
    @State private var editSurname: String
    @State private var editEmail: String
    @State private var editMobile: String
    @State private var didSyncIdentityDrafts = false
    @State private var showingAdminAccessLockedMessage = false
    /// The message for a locked permission row (`ADMIN_LOCKED_PERMISSION_MESSAGE` for an admin's locked toggles).
    @State private var lockedPermissionMessage = UserRoleTransitionPolicy.adminAccessLockedUntilAccountTypeChanges
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
    @State private var showingPromoteToAdminConfirmation = false
    @State private var showingDeactivateConfirmation = false
    @State private var annualLeaveDaysText: String
    @State private var annualLeaveStartMonth: Int
    @State private var annualLeaveEndMonth: Int
    @State private var annualLeaveCarriesOver: Bool
    /// `users/{uid}.employmentStartDate` draft (`YYYY-MM-DD`, empty = none). RULEBOOK 1.13.0 §4.4, admins only.
    @State private var employmentStartDateDraft: String
    @State private var annualLeaveEnabledDraft: Bool
    @State private var remainingLeaveText = ""
    @State private var baselineRemainingText = ""
    @State private var employmentTypeDraft: EmploymentType
    @State private var showingEmploymentTypeConfirmation = false
    @State private var employmentTypeConfirmationAccepted = false
    @State private var showingEmploymentTypeEffectiveDatePicker = false
    @State private var employmentTypeEffectiveDate = Date()
    @State private var vatDraft = SensitiveFieldDraft()
    @State private var utrDraft = SensitiveFieldDraft()
    @State private var isLoadingTaxIds = false
    @State private var showingPayeDayRateWarning = false
    @State private var pendingPayeDayRateText: String?

    init(user: AppUser, suppressAdminAccessToggle: Bool = false) {
        self.user = user
        self.suppressAdminAccessToggle = suppressAdminAccessToggle
        self._permissions = State(initialValue: user.permissions)
        self._permissionsBaseline = State(initialValue: user.permissions)
        self._isActive = State(initialValue: user.isActive)
        self._selectedAssignedManagerUserId = State(initialValue: user.assignedManagerUserId)
        // The stored ids until `syncEditUserDraftsFromStore` (onAppear) maps them with `lineManagerSelectedIds`.
        self._selectedLineManagerUserIds = State(initialValue: Set(user.lineManagerUserIds))
        self._hasNoLineManagerDraft = State(initialValue: user.hasNoLineManager)
        self._managerSelfBookDraft = State(initialValue: user.permissions.annualLeaveSelfBook)
        self._dayRateText = State(initialValue: Self.formatPayrollRateText(user: user))
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
        self._employmentStartDateDraft = State(initialValue: user.employmentStartDate ?? "")
        self._annualLeaveEnabledDraft = State(initialValue: user.annualLeaveEnabled)
        self._employmentTypeDraft = State(initialValue: user.employmentType)
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
        // RULEBOOK 1.31.0: the Super Admin edits their own profile (photo, name, contact); their permissions stay
        // locked (the save skips them on a Super Admin profile). Nobody else edits the Super Admin.
        if isViewingSuperAdminProfile { return viewerIsEditedPerson && userStore.canEditTargetUserPermissions(displayedUser) }
        return userStore.canEditTargetUserPermissions(displayedUser)
    }

    /// Super Admin profile: the flag, or the organisation creator when those ids have drifted apart.
    private var isViewingSuperAdminProfile: Bool {
        user.isSuperAdmin || displayedUser.isSuperAdmin || userStore.isOrganizationCreator(userId: user.id)
    }

    /// Change Super Admin is only on the signed-in Super Admin's own profile.
    /// Being the organisation creator is not enough once that role has been passed on.
    private var canOfferChangeSuperAdmin: Bool {
        guard let me = userStore.currentUser, me.isSuperAdmin else { return false }
        return me.id == user.id || me.id == displayedUser.id
    }

    private var superAdminTransferCandidates: [AppUser] {
        userStore.organizationUsers
            .filter { candidate in
                candidate.isStoredUserDocument &&
                candidate.id != user.id &&
                candidate.id != displayedUser.id &&
                !candidate.permissions.operativeMode &&
                (candidate.permissions.adminAccess || candidate.role == .admin) &&
                candidate.passwordSet &&
                candidate.isActive
            }
            .sorted {
                let left = $0.fullName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? $0.email : $0.fullName
                let right = $1.fullName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? $1.email : $1.fullName
                return left.localizedCaseInsensitiveCompare(right) == .orderedAscending
            }
    }

    private var pendingSuperAdminCandidate: AppUser? {
        guard let pendingSuperAdminUserId else { return nil }
        return superAdminTransferCandidates.first(where: { $0.id == pendingSuperAdminUserId })
            ?? userStore.organizationUsers.first(where: { $0.id == pendingSuperAdminUserId })
    }

    private var pendingSuperAdminConfirmationMessage: String {
        let name = pendingSuperAdminCandidate?.fullName.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let display = name.isEmpty ? (pendingSuperAdminCandidate?.email ?? "This administrator") : name
        return "\(display) will become the Super Admin. You will stay an administrator. Other permission toggles stay as they are."
    }

    private func rosterDisplayName(_ candidate: AppUser) -> String {
        let name = candidate.fullName.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? candidate.email : name
    }
    
    /// Admin-level account tools (status, delete, some emails).
    private var canUseAdminAccountTools: Bool {
        userStore.hasAdminAccess()
    }
    
    /// RULEBOOK 1.31.0 (owner decision 7): a manager with the Operatives permission deactivates and deletes operatives
    /// (operative level only); `userDeleteRefusal` / the security rules still decide each write.
    private var canManageThisOperative: Bool {
        guard userStore.actorManagesOperativesOnly else { return false }
        let role = UserStore.staffAccountRole(for: displayedUser)
        return role.isOperativeMode && !role.isManager && !role.isAdmin && !role.isSuperAdmin
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
        userStore.rosterRow(for: user.id) ?? user
    }
    
    private var canUploadProfilePhoto: Bool {
        canEditPermissionsMatrix
    }

    private var canEditIdentityDetails: Bool {
        canEditPermissionsMatrix && (!userStore.isOrganizationCreator(userId: user.id) || viewerIsEditedPerson)
    }

    private var identityDirty: Bool {
        guard canEditIdentityDetails else { return false }
        let baseline = displayedUser
        let f = editFirstName.trimmingCharacters(in: .whitespacesAndNewlines)
        let s = editSurname.trimmingCharacters(in: .whitespacesAndNewlines)
        let e = editEmail.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let m = editMobile.trimmingCharacters(in: .whitespacesAndNewlines)
        let origM = baseline.mobileNumber?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return f != baseline.firstName.trimmingCharacters(in: .whitespacesAndNewlines) ||
            s != baseline.surname.trimmingCharacters(in: .whitespacesAndNewlines) ||
            e != baseline.email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ||
            m != origM
    }

    /// Manager accounts turn Admin Access on through Change user type, not this switch.
    private var isManagerLevelAccount: Bool {
        if user.isSuperAdmin || displayedUser.isSuperAdmin { return false }
        if permissions.adminAccess || user.role == .admin || displayedUser.role == .admin { return false }
        if permissions.operativeMode { return false }
        return permissions.manager || user.role == .manager || displayedUser.role == .manager
    }

    private var shouldShowAnnualLeaveAccessToggle: Bool {
        if isViewingSuperAdminProfile { return false }
        guard userStore.canEditTargetUserPermissions(displayedUser) else { return false }
        return permissions.operativeMode || user.role == .operative || permissions.manager || permissions.adminAccess
    }

    private var annualLeaveAccessDirty: Bool {
        guard shouldShowAnnualLeaveAccessToggle else { return false }
        return annualLeaveEnabledDraft != displayedUser.annualLeaveEnabled
    }

    private var annualLeaveAllowanceCopy: CanonicalBusinessEngine.CanonicalAnnualLeaveAllowanceCopy {
        CanonicalBusinessEngine.annualLeaveAllowanceCopy() ?? CanonicalBusinessEngine.CanonicalAnnualLeaveAllowanceCopy(
            toggleTitle: "Annual leave allowance",
            toggleDescription: "Turn off annual leave allowances using this toggle. This is generally used for self-employed staff who do not get paid annual leave, therefore they do not have a set number of days per year.",
            toggleNote: "When off, this person can still book and see annual leave. They see days taken in the company leave year, not a remaining balance or days per year.",
            remainingTitle: "Manually adjust this user's remaining annual leave allowance for this year",
            remainingNote: "This number will reset to the Days per year figure at the end of your company year."
        )
    }

    private var annualLeaveAccessSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            ManageUserSectionTitle(text: annualLeaveAllowanceCopy.toggleTitle)
            ManageUserCard {
                ManageUserPermissionToggleRow(
                    iconName: "calendar.badge.clock",
                    iconBackground: ManageUserProfilePalette.chipBlueBg,
                    iconForeground: ManageUserProfilePalette.chipBlueFg,
                    title: annualLeaveAllowanceCopy.toggleTitle,
                    subtitle: annualLeaveAllowanceCopy.toggleDescription,
                    isOn: $annualLeaveEnabledDraft,
                    isDisabled: !canEditPermissionsMatrix
                )
                Text(annualLeaveAllowanceCopy.toggleNote)
                    .font(.caption)
                    .foregroundStyle(ManageUserProfilePalette.textSecondary)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 12)
            }
        }
    }

    private var shouldShowAnnualLeaveEntitlementSection: Bool {
        if isViewingSuperAdminProfile { return false }
        guard userStore.canEditTargetUserPermissions(displayedUser) else { return false }
        guard annualLeaveEnabledDraft else { return false }
        return permissions.operativeMode || user.role == .operative || permissions.manager
    }

    private func currentRemainingDays(for subject: AppUser) -> Double {
        let org = firebaseBackend.currentOrganization?.settings.annualLeaveDefaults ?? .default
        let summary = AnnualLeavePolicy.usageSummary(
            bookings: holidayStore.myBookings(account: subject, operatives: operativeStore.allOperatives),
            daysPerYear: subject.annualLeaveDaysPerYear,
            startMonth: subject.annualLeaveYearStartMonth,
            endMonth: subject.annualLeaveYearEndMonth,
            carriesOver: subject.annualLeaveCarriesOver,
            annualLeaveEnabled: true,
            orgDaysPerYear: org.daysPerYear,
            orgStartMonth: org.startMonth,
            orgEndMonth: org.endMonth,
            yearAllowance: subject.annualLeaveYearAllowance,
            yearAllowanceKey: subject.annualLeaveYearAllowanceKey,
            employmentStartDayKey: subject.employmentStartDate
        )
        return summary.remainingDays ?? 0
    }

    private func parsedRemainingForSave() -> Double? {
        let t = remainingLeaveText.replacingOccurrences(of: ",", with: ".").trimmingCharacters(in: .whitespacesAndNewlines)
        guard let d = Double(t), d >= 0 else { return nil }
        return CanonicalBusinessEngine.snapLeaveDays(d)
    }

    private func parsedAnnualLeaveDaysForSave() -> Double? {
        let t = annualLeaveDaysText.replacingOccurrences(of: ",", with: ".").trimmingCharacters(in: .whitespacesAndNewlines)
        guard let d = Double(t), d > 0 else { return nil }
        return AnnualLeavePolicy.clampDaysPerYear(d)
    }

    private var annualLeaveEntitlementDirty: Bool {
        guard shouldShowAnnualLeaveEntitlementSection else { return false }
        let s = userStore.rosterRow(for: user.id) ?? user
        guard let p = parsedAnnualLeaveDaysForSave() else { return true }
        return abs(p - s.annualLeaveDaysPerYear) > 0.0001
            || annualLeaveStartMonth != s.annualLeaveYearStartMonth
            || annualLeaveEndMonth != s.annualLeaveYearEndMonth
            || annualLeaveCarriesOver != s.annualLeaveCarriesOver
            || remainingLeaveText != baselineRemainingText
    }

    /// RULEBOOK 1.13.0 §4.4: an admin changed the start date the leave year joined is pro rata from.
    private var employmentStartDateDirty: Bool {
        guard canUseAdminAccountTools else { return false }
        let stored = (userStore.rosterRow(for: user.id) ?? user).employmentStartDate ?? ""
        return employmentStartDateDraft != stored
    }

    private var employmentStartDateBinding: Binding<Date> {
        Binding(
            get: { OrganizationRulebookContext.date(fromDayKey: employmentStartDateDraft) ?? OrganizationRulebookContext.calendar.startOfDay(for: Date()) },
            set: { employmentStartDateDraft = OrganizationRulebookContext.dayKey($0) }
        )
    }

    @ViewBuilder
    private var employmentStartDateRow: some View {
        if canUseAdminAccountTools {
            VStack(alignment: .leading, spacing: 6) {
                Text("Start date")
                    .font(.subheadline.weight(.semibold))
                if employmentStartDateDraft.isEmpty {
                    Button("Set start date") {
                        employmentStartDateDraft = OrganizationRulebookContext.dayKey(Date())
                    }
                    .accessibilityIdentifier("editUser.employmentStartDate.set")
                } else {
                    HStack {
                        DatePicker("Start date", selection: employmentStartDateBinding, displayedComponents: .date)
                            .labelsHidden()
                            .environment(\.timeZone, OrganizationRulebookContext.timeZone)
                            .accessibilityIdentifier("editUser.employmentStartDate")
                        Spacer()
                        Button("Clear") { employmentStartDateDraft = "" }
                            .accessibilityIdentifier("editUser.employmentStartDate.clear")
                    }
                }
                Text("The day this person started. Their allowance for that leave year is pro rata from it. Leave blank for a full allowance.")
                    .font(.caption)
                    .foregroundStyle(ManageUserProfilePalette.textSecondary)
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 14)
        }
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
                VStack(alignment: .leading, spacing: 6) {
                    Text(annualLeaveAllowanceCopy.remainingTitle)
                        .font(.subheadline.weight(.semibold))
                    TextField("Remaining", text: $remainingLeaveText)
                        .keyboardType(.decimalPad)
                        .textFieldStyle(.roundedBorder)
                        .disabled(!canEditPermissionsMatrix)
                    Text(annualLeaveAllowanceCopy.remainingNote)
                        .font(.caption)
                        .foregroundStyle(ManageUserProfilePalette.textSecondary)
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 14)
                employmentStartDateRow
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
        // RULEBOOK 1.11.0 §11: `lineManagerSummary(person, roster)`.
        return LineManagerRulebook.summary(
            for: draftUserForAnnualLeaveValidation,
            selectedIds: selectedLineManagerUserIds,
            hasNoLineManager: hasNoLineManagerDraft,
            roster: userStore.organizationUsers
        )
    }

    private var operativeSetupSectionTitle: String {
        if displayedUser.isSuperAdmin { return "Super Admin setup" }
        switch accountKind {
        case "operative": return "Operative setup"
        case "admin": return "Administrator setup"
        default: return "Manager setup"
        }
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

    private var isPromotingToAdministrator: Bool {
        let currentKind = UserRoleTransitionPolicy.kind(for: permissions)
        return changeUserTypeDraft == .administrator && (currentKind == .manager || currentKind == .operative)
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
        // RULEBOOK 1.15.0 §11 `accountTypePermissions`: the sheet opens on the person's saved toggles for the new type
        // (only the level flags change), never a preset.
        let level: RulebookPermissionLevel = changeUserTypeDraft == .administrator ? .admin
            : changeUserTypeDraft == .manager ? .manager : .operative
        let stored = userStore.rosterRow(for: user.id) ?? user
        if let kept = CanonicalBusinessEngine.accountTypePermissions(
            kind: level,
            previous: CanonicalBusinessEngine.permissionSubject(
                permissions: stored.permissions,
                role: stored.role.rawValue,
                isSuperAdmin: stored.isSuperAdmin
            )
        ) {
            managerSelfBookDraft = kept["annualLeaveSelfBook"] ?? managerSelfBookDraft
            managerTransitionOperatives = kept["operatives"] ?? managerTransitionOperatives
            managerTransitionQualifications = kept["qualifications"] ?? managerTransitionQualifications
            managerTransitionWeeklyReports = kept["weeklyReports"] ?? managerTransitionWeeklyReports
            managerTransitionDailyOverview = kept["dailyOverview"] ?? managerTransitionDailyOverview
            managerTransitionSubContractors = kept["subContractors"] ?? managerTransitionSubContractors
            managerTransitionProjects = kept["projects"] ?? managerTransitionProjects
            managerTransitionSmallWorks = kept["smallWorks"] ?? managerTransitionSmallWorks
            operativeTransitionMaterials = kept["materials"] ?? operativeTransitionMaterials
            operativeTransitionSiteAudit = kept["siteAudit"] ?? operativeTransitionSiteAudit
            return
        }
        if let m = UserRoleTransitionPolicy.managerConfigForSheet(current: permissions, selectedKind: changeUserTypeDraft) {
            managerSelfBookDraft = m.annualLeaveSelfBook
            managerTransitionOperatives = m.operatives
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

    /// Account kind of the stored row from the rulebook (`accountKindFromFlags`: super admin, then admin flag or
    /// role, then operative mode), so the Change user type sheet opens on the type the header shows.
    private func storedAccountKind(of subject: AppUser) -> ManagedAccountKind {
        switch CanonicalBusinessEngine.accountKindFromFlags(
            isSuperAdmin: subject.isSuperAdmin,
            role: subject.role.rawValue,
            adminAccess: subject.permissions.adminAccess,
            manager: subject.permissions.manager,
            operativeMode: subject.permissions.operativeMode
        ) ?? "" {
        case "admin": return .administrator
        case "operative": return .operative
        case "manager": return .manager
        default: return UserRoleTransitionPolicy.kind(for: subject.permissions)
        }
    }

    /// While nothing has been changed on this screen, the draft follows the stored row (live roster, read-back).
    private func followStoredPermissionsIfDraftUnchanged() {
        let stored = displayedUser.permissions
        guard permissions == permissionsBaseline, stored != permissionsBaseline else { return }
        permissions = stored
        permissionsBaseline = stored
    }

    private var displayRoleLabel: String {
        switch accountKind {
        case "operative": return UserRole.operative.displayName
        case "admin": return UserRole.admin.displayName
        case "manager": return UserRole.manager.displayName
        default: return user.role.displayName
        }
    }

    private var accountKind: String {
        CanonicalBusinessEngine.accountKindFromFlags(
            isSuperAdmin: displayedUser.isSuperAdmin,
            role: displayedUser.role.rawValue,
            adminAccess: permissions.adminAccess,
            manager: permissions.manager,
            operativeMode: permissions.operativeMode
        ) ?? "manager"
    }

    private var employmentTypeChanged: Bool {
        employmentTypeDraft != payBaselineUser.employmentType
    }

    private var shouldConfirmEmploymentTypeChange: Bool {
        guard employmentTypeChanged else { return false }
        guard let actingUser = userStore.currentUser else { return false }
        if actingUser.permissions.operativeMode { return false }
        return actingUser.isSuperAdmin || actingUser.permissions.adminAccess || actingUser.permissions.manager
    }

    private var employmentTransitionSummary: String {
        CanonicalBusinessEngine.employmentEffectiveLabel(
            employmentType: displayedUser.employmentType.rawValue,
            transitionFrom: displayedUser.employmentTypeTransitionFrom?.rawValue,
            effectiveAt: displayedUser.employmentTypeEffectiveAt
        ) ?? "Effective immediately"
    }
    
    // Check if any changes have been made
    /// RULEBOOK 1.12.2 §11 `accountTypeSyncState(...).repair`: the level to finish on every record, nil when the user
    /// type is the same on the users document and `members.{uid}`.
    private var accountTypeRepair: RulebookPermissionLevel? {
        let stored = userStore.rosterRow(for: user.id) ?? user
        return stored.accountTypeSyncState(in: firebaseBackend)?.repair
    }

    private var hasChanges: Bool {
        if canUseAdminAccountTools && !isViewingSuperAdminProfile && accountTypeRepair != nil { return true }
        if employmentStartDateDirty { return true }
        let dayRateEligible = permissions.operativeMode || permissions.manager || permissions.adminAccess
        let trimmedTradeP = tradePresetRaw.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedTradeC = tradeCustomText.trimmingCharacters(in: .whitespacesAndNewlines)
        let origTradeP = user.tradeTypePreset?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let origTradeC = user.tradeTypeCustom?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let tradeChanged = dayRateEligible && (trimmedTradeP != origTradeP || trimmedTradeC != origTradeC)
        let billingChanged = canViewTaxIds && (vatDraft.isDirty || utrDraft.isDirty)
        // RULEBOOK 1.26.1 §8: against the editor's record while `privatePay` is on; the opened row as before while off.
        let payrollRateDirty = isPayrollRateDirty(versus: payRecord.map { user.withPayFields(of: $0) } ?? user)
        let operativeProfileChanged = (permissions.operativeMode || permissions.manager || permissions.adminAccess) && (
            LineManagerRulebook.selectionChanged(selectedLineManagerUserIds, from: user, roster: userStore.organizationUsers) ||
            hasNoLineManagerDraft != user.hasNoLineManager ||
            payrollRateDirty
        )
        let staffDayRateChanged = !permissions.operativeMode && (permissions.manager || permissions.adminAccess)
            && payrollRateDirty
        let permissionsDirty = !isViewingSuperAdminProfile && permissions != user.permissions
        if canUseAdminAccountTools {
            return identityDirty ||
                permissionsDirty ||
                isActive != user.isActive ||
                operativeProfileChanged ||
                staffDayRateChanged ||
                tradeChanged ||
                employmentTypeChanged ||
                annualLeaveAccessDirty ||
                annualLeaveEntitlementDirty ||
                billingChanged
        }
        if canEditPermissionsMatrix && (identityDirty || operativeProfileChanged || tradeChanged || staffDayRateChanged || employmentTypeChanged || annualLeaveAccessDirty || annualLeaveEntitlementDirty || billingChanged) {
            return true
        }
        if isManagerOperativeOnly && !isViewingSuperAdminProfile && (user.permissions.operativeMode || user.role == .operative) {
            return identityDirty ||
                permissions.materials != user.permissions.materials ||
                permissions.siteAudit != user.permissions.siteAudit ||
                tradeChanged ||
                employmentTypeChanged ||
                annualLeaveAccessDirty ||
                annualLeaveEntitlementDirty ||
                billingChanged
        }
        return false
    }

    /// Rulebook `canViewSensitiveProfile` for this subject. False shows "Held by admin" and reads nothing.
    private var canViewTaxIds: Bool {
        userStore.canViewSensitiveProfile(of: user.id)
    }

    private func loadTaxIds() async {
        guard canViewTaxIds else { return }
        isLoadingTaxIds = true
        let profile = await userStore.loadSensitiveProfile(for: displayedUser)
        isLoadingTaxIds = false
        guard !vatDraft.isDirty, !utrDraft.isDirty else { return }
        vatDraft.reset(saved: profile?.vatNumber ?? "")
        utrDraft.reset(saved: profile?.utrNumber ?? "")
    }

    private var draftUserForAnnualLeaveValidation: AppUser {
        var draft = displayedUser
        draft.permissions = permissions
        draft.hasNoLineManager = hasNoLineManagerDraft
        draft.setLineManagerUserIds(Array(selectedLineManagerUserIds).sorted())
        if !selectedLineManagerUserIds.isEmpty { draft.hasNoLineManager = false }
        draft.annualLeaveEnabled = annualLeaveEnabledDraft
        draft.isActive = isActive
        return draft
    }

    /// `lineManagerRequiredError` for the user as it will be saved (RULEBOOK §8, §11).
    private var lineManagerRequiredMessage: String? {
        guard canEditPermissionsMatrix else { return nil }
        return AnnualLeaveApproval.lineManagerRequiredError(
            for: draftUserForAnnualLeaveValidation,
            users: userStore.organizationUsers
        )
    }

    private var lineManagerRoutingBlocked: Bool {
        lineManagerRequiredMessage != nil
    }

    private var lineManagerValidationMessage: String? {
        lineManagerRequiredMessage
    }

    /// `CanonicalBusinessEngine.canSelfBookAnnualLeave(user, roster)` before and after this save (RULEBOOK §9).
    private var willDisableAnnualLeaveSelfBookOnSave: Bool {
        let roster = userStore.organizationUsers
        return AnnualLeaveSelfBookPolicy.canSelfBookAnnualLeave(for: displayedUser, users: roster)
            && !AnnualLeaveSelfBookPolicy.canSelfBookAnnualLeave(for: draftUserForAnnualLeaveValidation, users: roster)
    }

    /// RULEBOOK 1.11.0 §11: `lineManagerCandidates(person, roster)`.
    private var lineManagerCandidates: [AppUser] {
        LineManagerRulebook.candidates(for: draftUserForAnnualLeaveValidation, roster: userStore.organizationUsers)
    }
    
    var body: some View {
        editUserNavigationStack
            .sheet(isPresented: $showingHolidayReport) {
                HolidayReportView(user: user)
                    .environmentObject(holidayStore)
                    .environmentObject(operativeStore)
                    .environmentObject(userStore)
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
            operativeForQualificationsEditor: $operativeForQualificationsEditor,
            linkedOperative: linkedOperativeForUser,
            canEditPermissionsMatrix: canEditPermissionsMatrix,
            operativeStore: operativeStore,
            firebaseBackend: firebaseBackend,
            userStore: userStore,
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
            .sheet(isPresented: $showingChangeSuperAdminPicker, onDismiss: {
                if pendingSuperAdminUserId != nil {
                    showingChangeSuperAdminConfirmation = true
                }
            }) {
                changeSuperAdminPicker
            }
            .alert("Change Super Admin?", isPresented: $showingChangeSuperAdminConfirmation) {
                Button("Cancel", role: .cancel) {
                    pendingSuperAdminUserId = nil
                }
                    .accessibilityIdentifier("editUser.cancel")
                Button("Change Super Admin") {
                    if let candidate = pendingSuperAdminCandidate {
                        transferSuperAdmin(to: candidate)
                    }
                }
                    .accessibilityIdentifier("editUser.changeSuperAdmin")
            } message: {
                Text(pendingSuperAdminConfirmationMessage)
            }
            .alert("Turn off Annual Leave Management?", isPresented: $showingSelfBookOffConfirmation) {
            Button("Cancel", role: .cancel) {
                selfBookOffConfirmationAccepted = false
            }
                .accessibilityIdentifier("editUser.cancel2")
            Button("Continue") {
                selfBookOffConfirmationAccepted = true
                saveChanges()
            }
                .accessibilityIdentifier("editUser.continue")
        } message: {
            Text(ManageUsersLeaveCopy.selfBookOffMessage)
        }
    }

    private var editUserScrollView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if !smartCache.isOnline {
                    // RULEBOOK §2: every Manage Users change is online only.
                    Label(OfflinePolicy.onlineOnlyMessage, systemImage: "wifi.slash")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, PPMetrics.screenGutter)
                        .padding(.top, 12)
                        .accessibilityIdentifier("offlinePolicy.onlineOnlyMessage")
                }
                if canUseAdminAccountTools && accountTypeRepair != nil && !showingChangeUserType {
                    // RULEBOOK 1.12.2 §11 `accountTypeSyncState`: Save finishes the partly saved user type.
                    Label(CanonicalBusinessEngine.accountTypeOutOfSyncMessage, systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(Color.orange)
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.orange.opacity(0.12))
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .padding(.horizontal, PPMetrics.screenGutter)
                        .padding(.top, 12)
                        .accessibilityIdentifier("editUser.accountTypeOutOfSync")
                }
                if payRecordLoading {
                    // RULEBOOK 1.26.1 §8: with `privatePay` on, nothing is edited or saved before the starting record.
                    HStack(spacing: 8) {
                        ProgressView()
                        Text("Loading pay…")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, PPMetrics.screenGutter)
                    .padding(.top, 12)
                    .accessibilityIdentifier("editUser.payLoading")
                }
                editUserFormSections
                    .disabled(payRecordLoading)
            }
        }
        .onAppear(perform: syncEditUserDraftsFromStore)
        .onAppear(perform: followStoredPermissionsIfDraftUnchanged)
        .task(id: "\(user.id)#\(payLoadGate.generation)") { await refreshPayFromPayProfile() }
        // RULEBOOK 1.26.1 §8: a switch change re-reads the `CanonicalBusinessEngine.payEditorStartingValues` record.
        .onReceive(NotificationCenter.default.publisher(for: .securitySwitchesDidChange)) { _ in
            payLoadGate.switchChanged()
        }
        .onChange(of: displayedUser.permissions) { _, _ in
            followStoredPermissionsIfDraftUnchanged()
        }
        .alert("Admin Access", isPresented: $showingAdminAccessLockedMessage) {
            Button("OK", role: .cancel) { }
                .accessibilityIdentifier("editUser.ok")
        } message: {
            Text(lockedPermissionMessage)
        }
        .background(PPColor.page.ignoresSafeArea())
        .navigationTitle(editNavigationTitle)
        .navigationBarTitleDisplayMode(.inline)
        .ppNavyNavigationBar()
        .toolbar { editUserToolbarContent }
        .safeAreaInset(edge: .bottom) { editUserSaveFooter }
    }

    /// Why Save will not go through, in red directly above a Save button at the foot of the form (the toolbar Save
    /// stays): a refused save's message, else the rule refusing this save as it stands (`lineManagerRequiredError`,
    /// LINE_MANAGER_REQUIRED_MESSAGE), else the pay-rate refusal. Web shows the same message above its Save.
    private var editUserSaveBlockingMessage: String? {
        if let saveErrorMessage, !saveErrorMessage.isEmpty { return saveErrorMessage }
        if let lineManagerRequiredMessage { return lineManagerRequiredMessage }
        if let payRateFieldError, !payRateFieldError.isEmpty { return payRateFieldError }
        return nil
    }

    @ViewBuilder
    private var editUserSaveFooter: some View {
        if canEditPermissionsMatrix, hasChanges || editUserSaveBlockingMessage != nil {
            VStack(alignment: .leading, spacing: 8) {
                if let message = editUserSaveBlockingMessage {
                    Text(message)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityIdentifier("editUser.saveBlockingMessage")
                }
                Button {
                    saveChanges()
                } label: {
                    Text(isUpdating ? "Saving…" : "Save")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 13)
                        .background(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .fill(ManageUserProfilePalette.primaryBlue)
                        )
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("editUser.saveFooter")
                .disabled(isUpdating || !hasChanges || lineManagerRoutingBlocked || !smartCache.isOnline || payRecordLoading)
                .opacity((isUpdating || !hasChanges || lineManagerRoutingBlocked || !smartCache.isOnline || payRecordLoading) ? 0.55 : 1)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(ProjectWorksRevampColors.surface)
            .overlay(alignment: .top) { Divider() }
        }
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
            if shouldShowAnnualLeaveAccessToggle {
                annualLeaveAccessSection
            }
            if shouldShowAnnualLeaveEntitlementSection {
                annualLeaveEntitlementSection
            }
            editUserBillingAndTimesheetsSections
            if canUseAdminAccountTools && !isViewingSuperAdminProfile {
                activeToggleChromeSection
            }
            permissionsSection
            if let lineManagerValidationMessage {
                Text(lineManagerValidationMessage)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .padding(.horizontal, 4)
            }
            if canShowCredentialActions || canUseAdminAccountTools || canOfferChangeSuperAdmin {
                actionsChromeSection
            }
        }
        .padding(.horizontal, 18)
        .padding(.bottom, 32)
    }

    @ViewBuilder
    private var editUserBillingAndTimesheetsSections: some View {
        if canEditPermissionsMatrix || canViewTaxIds {
            VStack(alignment: .leading, spacing: 8) {
                ManageUserSectionTitle(text: "Employment & timesheets")
                billingDetailsCard
            }
        }
    }

    @ToolbarContentBuilder
    private var editUserToolbarContent: some ToolbarContent {
        ToolbarItem(placement: .navigationBarLeading) {
            Button("Cancel") { dismiss() }
                .accessibilityIdentifier("editUser.cancel3")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(ManageUserProfilePalette.textPrimary)
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .background(Capsule(style: .continuous).fill(ProjectWorksRevampColors.surface))
                .overlay(
                    Capsule(style: .continuous)
                        .stroke(ProjectWorksRevampColors.searchBorder, lineWidth: 0.5)
                )
        }
        ToolbarItem(placement: .navigationBarTrailing) {
            if canEditPermissionsMatrix {
                Button("Save") { saveChanges() }
                    .accessibilityIdentifier("editUser.save")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(hasChanges ? Color.white : ManageUserProfilePalette.textSecondary)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 7)
                    .background(
                        Capsule(style: .continuous)
                            .fill(hasChanges ? ManageUserProfilePalette.primaryBlue : Color(.systemGray5))
                    )
                    .disabled(isUpdating || !hasChanges || lineManagerRoutingBlocked || !smartCache.isOnline || payRecordLoading)
            }
        }
    }

    private func syncEditUserDraftsFromStore() {
        guard !didSyncIdentityDrafts else { return }
        didSyncIdentityDrafts = true
        let u = userStore.rosterRow(for: user.id) ?? user
        editFirstName = u.firstName
        editSurname = u.surname
        editEmail = u.email
        editMobile = u.mobileNumber ?? ""
        annualLeaveDaysText = EditUserView.formatAnnualLeaveDaysText(u.annualLeaveDaysPerYear)
        annualLeaveStartMonth = u.annualLeaveYearStartMonth
        annualLeaveEndMonth = u.annualLeaveYearEndMonth
        annualLeaveCarriesOver = u.annualLeaveCarriesOver
        annualLeaveEnabledDraft = u.annualLeaveEnabled
        let remaining = EditUserView.formatAnnualLeaveDaysText(currentRemainingDays(for: u))
        remainingLeaveText = remaining
        baselineRemainingText = remaining
        employmentTypeDraft = u.employmentType
        vatDraft.reset(saved: vatDraft.saved)
        utrDraft.reset(saved: utrDraft.saved)
        hasNoLineManagerDraft = u.hasNoLineManager
        // RULEBOOK 1.14.0 §11 `lineManagerSelectedIds`: a stored id on the other users document of the same person
        // selects that person's one picker option.
        selectedLineManagerUserIds = LineManagerRulebook.selectedIds(for: u, roster: userStore.organizationUsers)
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
                    .accessibilityIdentifier("editUser.accountType")
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
                                description: "Can open Weekly Report from Home. If off, that tile is hidden.",
                                isOn: $managerTransitionWeeklyReports
                            )
                            ManageUserCardDivider()
                            ManageUserExpandablePermissionToggleRow(
                                iconName: "calendar.badge.clock",
                                iconBackground: ManageUserProfilePalette.chipTealBg,
                                iconForeground: ManageUserProfilePalette.chipTealFg,
                                title: "Daily Overview",
                                description: "Can open Daily Overview from Home. If off, that tile is hidden.",
                                isOn: $managerTransitionDailyOverview
                            )
                            ManageUserCardDivider()
                            ManageUserExpandablePermissionToggleRow(
                                iconName: "person.2.wave.2.fill",
                                iconBackground: ManageUserProfilePalette.chipTealBg,
                                iconForeground: ManageUserProfilePalette.chipTealFg,
                                title: "Sub Contractors",
                                description: "Can add and manage sub contractor records. If off, Sub Contractors is hidden on Home and menus. They can still book existing subcontractors on jobs.",
                                isOn: $managerTransitionSubContractors
                            )
                            ManageUserCardDivider()
                            ManageUserExpandablePermissionToggleRow(
                                iconName: "rosette",
                                iconBackground: ManageUserProfilePalette.chipPinkBg,
                                iconForeground: ManageUserProfilePalette.chipPinkFg,
                                title: "Manage Qualifications",
                                description: "When on, this manager can add and edit organisation qualification templates. When off, Qualifications shows only My Qualifications, and they can still assign templates others have already added.",
                                isOn: $managerTransitionQualifications
                            )
                            ManageUserCardDivider()
                            ManageUserExpandablePermissionToggleRow(
                                iconName: "folder.fill",
                                iconBackground: ManageUserProfilePalette.chipBlueBg,
                                iconForeground: ManageUserProfilePalette.chipBlueFg,
                                title: "Projects",
                                description: "Can create, edit, and add projects. If off, they still see projects they are assigned to as a manager or booked onto — scheduling and other job tools stay available, but they cannot add or edit project details.",
                                isOn: $managerTransitionProjects
                            )
                            ManageUserCardDivider()
                            ManageUserExpandablePermissionToggleRow(
                                iconName: "hammer.fill",
                                iconBackground: ManageUserProfilePalette.chipBlueBg,
                                iconForeground: ManageUserProfilePalette.chipBlueFg,
                                title: "Small Works",
                                description: "Can create, edit, and add small works. If off, they still see small works they are assigned to as a manager or booked onto — scheduling and other job tools stay available, but they cannot add or edit small works details.",
                                isOn: $managerTransitionSmallWorks
                            )
                        }
                        .background(ProjectWorksRevampColors.surface)
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .stroke(ProjectWorksRevampColors.searchBorder, lineWidth: 0.5)
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
                        .background(ProjectWorksRevampColors.surface)
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .stroke(ProjectWorksRevampColors.searchBorder, lineWidth: 0.5)
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
                        if isPromotingToAdministrator {
                            showingPromoteToAdminConfirmation = true
                        } else {
                            Task { await applyChangeUserType() }
                        }
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
                    .accessibilityIdentifier("editUser.apply")
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
                        showingPromoteToAdminConfirmation = false
                    }
                        .accessibilityIdentifier("editUser.close")
                }
            }
        }
        .overlay {
            if showingPromoteToAdminConfirmation {
                promoteToAdminConfirmationOverlay
            }
        }
    }

    private var promoteToAdminConfirmationOverlay: some View {
        ZStack {
            Color.black.opacity(0.4)
                .ignoresSafeArea()
                
                .accessibilityIdentifier("editUser.tap").onTapGesture {
                    guard !isApplyingUserType else { return }
                    showingPromoteToAdminConfirmation = false
                }

            VStack(spacing: 16) {
                Image(systemName: "person.badge.key.fill")
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundStyle(ManageUserProfilePalette.chipPurpleFg)
                    .frame(width: 56, height: 56)
                    .background(ManageUserProfilePalette.chipPurpleBg)
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))

                Text("Make this user an administrator?")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(ManageUserProfilePalette.textPrimary)
                    .multilineTextAlignment(.center)

                Text("\(user.fullName) will get full administrator access, including user management and organisation settings. Only another administrator can change this later.")
                    .font(.system(size: 14))
                    .foregroundStyle(ManageUserProfilePalette.textSecondary)
                    .multilineTextAlignment(.center)

                VStack(spacing: 10) {
                    Button {
                        showingPromoteToAdminConfirmation = false
                        Task { await applyChangeUserType() }
                    } label: {
                        Text("Yes, make administrator")
                            .font(.system(size: 15, weight: .semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                    }
                    .accessibilityIdentifier("editUser.yesMakeAdministrator")
                    .buttonStyle(.borderedProminent)
                    .tint(ManageUserProfilePalette.primaryBlue)
                    .disabled(isApplyingUserType)

                    Button {
                        showingPromoteToAdminConfirmation = false
                    } label: {
                        Text("Cancel")
                            .font(.system(size: 15, weight: .medium))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                    }
                    .accessibilityIdentifier("editUser.cancel4")
                    .buttonStyle(.plain)
                    .foregroundStyle(ManageUserProfilePalette.textSecondary)
                    .disabled(isApplyingUserType)
                }
            }
            .padding(22)
            .frame(maxWidth: 340)
            .background(ProjectWorksRevampColors.surface)
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            .shadow(color: Color.black.opacity(0.16), radius: 24, y: 10)
            .padding(.horizontal, 28)
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
                    skills: false,
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
                    skills: false,
                    qualifications: true,
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
        var newPerms = UserRoleTransitionPolicy.permissions(
            for: changeUserTypeDraft,
            carryingFrom: permissions,
            manager: managerConfig,
            operative: operativeConfig
        )
        newPerms.skills = false
        let nextRole: UserRole
        switch changeUserTypeDraft {
        case .operative: nextRole = .operative
        case .manager: nextRole = .manager
        case .administrator: nextRole = .admin
        }
        _ = nextRole
        // RULEBOOK 1.11.0 §11: `accountTypeChangeWrites` — users/{uid}, members.{uid} and the membership together.
        let level: RulebookPermissionLevel = changeUserTypeDraft == .administrator ? .admin
            : changeUserTypeDraft == .manager ? .manager : .operative
        // RULEBOOK 1.15.0 §11 `accountTypeWritePermissions`: a type change keeps every saved toggle; only the level
        // flags change, and only the toggles this sheet shows for the new level take the screen's values. The old
        // preset (`UserRoleTransitionPolicy`) no longer decides the stored toggles.
        let screen: [String: Bool]
        switch changeUserTypeDraft {
        case .administrator:
            screen = ["annualLeaveSelfBook": managerSelfBookDraft]
        case .manager:
            screen = [
                "annualLeaveSelfBook": managerSelfBookDraft,
                "operatives": managerTransitionOperatives,
                "qualifications": managerTransitionQualifications,
                "weeklyReports": managerTransitionWeeklyReports,
                "dailyOverview": managerTransitionDailyOverview,
                "subContractors": managerTransitionSubContractors,
                "projects": managerTransitionProjects,
                "smallWorks": managerTransitionSmallWorks,
            ]
        case .operative:
            screen = ["materials": operativeTransitionMaterials, "siteAudit": operativeTransitionSiteAudit]
        }
        let storedPerson = userStore.rosterRow(for: user.id) ?? user
        let storedSubject = CanonicalBusinessEngine.permissionSubject(
            permissions: storedPerson.permissions,
            role: storedPerson.role.rawValue,
            isSuperAdmin: storedPerson.isSuperAdmin
        )
        if let kept = CanonicalBusinessEngine.accountTypeWritePermissions(kind: level, person: storedSubject, screen: screen) {
            newPerms = storedPerson.permissions.applying(kept)
        }
        let result = await userStore.changeAccountType(
            userId: user.id,
            kind: level,
            screenPermissions: newPerms,
            sheetToggles: screen,
            holidayStore: holidayStore,
            linkedOperativeUUID: linkedOperativeForUser?.id
        )
        let ok = result.ok
        await MainActor.run {
            isApplyingUserType = false
            if let note = result.note { userTypeChangeMessage = note }
        }
        if ok {
            // `updateUserPermissions` read the saved document back from the server; this screen shows that copy.
            await userStore.loadOrganizationUsers(forceRefresh: true)
            await holidayStore.loadData()
            await MainActor.run {
                if let fresh = userStore.rosterRow(for: user.id) {
                    permissions = fresh.permissions
                    permissionsBaseline = fresh.permissions
                    selectedLineManagerUserIds = LineManagerRulebook.selectedIds(for: fresh, roster: userStore.organizationUsers)
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
                // Refused or not stored: show the stored type again, never the one that was asked for.
                let stored = userStore.rosterRow(for: user.id) ?? user
                permissions = stored.permissions
                permissionsBaseline = stored.permissions
                changeUserTypeDraft = storedAccountKind(of: stored)
                applyDraftsForChangeUserTypeSelection()
                userTypeChangeMessage = userStore.errorMessage ?? "Could not update account type. Nothing was changed."
            }
        }
    }
    
    private var userInfoHeader: some View {
        ManageUserCard {
            VStack(spacing: 12) {
                ZStack(alignment: .bottomTrailing) {
                    ZStack {
                        if let urlString = displayedUser.profilePhotoURL,
                           URL(string: urlString) != nil {
                            // `profilePhotoUpdatedAt` refreshes the cached picture; a stale URL is re-fetched (§12).
                            ProfilePhotoAvatar(urlString: urlString, updatedAt: displayedUser.profilePhotoUpdatedAt) {
                                profileInitialsPlaceholder
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
                        .accessibilityIdentifier("editUser.cameraFill")
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
                    // RULEBOOK §8: employment type is pay (`canChangePersonPay`); 1.13.0 `canViewPersonPay` decides
                    // whether it is shown at all.
                    if !userStore.canViewPay(of: displayedUser) {
                        EmptyView()
                    } else if canEditPermissionsMatrix && userStore.canChangePay(of: displayedUser) {
                        Menu {
                            ForEach(EmploymentType.allCases) { type in
                                Button(type.title) {
                                    employmentTypeDraft = type
                                    employmentTypeConfirmationAccepted = false
                                    payRateFieldError = nil
                                }
                                    .accessibilityIdentifier("editUser.row.\(type.id)")
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
                        .accessibilityIdentifier("editUser.briefcaseFill")
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
                        label: "Employment date",
                        value: employmentTransitionSummary
                    )
                }
            }
        }
    }

    private var operativeAndManagerSetupCard: some View {
        ManageUserCard {
            VStack(spacing: 0) {
                // The Super Admin needs no line manager and never sets their own (RULEBOOK §8, §16).
                if (permissions.operativeMode || permissions.manager || permissions.adminAccess) && !isViewingSuperAdminProfile {
                    lineManagerPickRow
                    ManageUserCardDivider()
                }
                if userStore.canViewPay(of: displayedUser) {
                ManageUserDayRateEditRow(dayRateText: $dayRateText, currencySymbol: localeCurrencySymbol())
                    .onChange(of: dayRateText) { _, newValue in
                        payRateFieldError = nil
                        guard employmentTypeDraft == .paye else { return }
                        guard parseDayRate(newValue) != nil else { return }
                        guard parseDayRate(newValue) != displayedPayrollRate(for: displayedUser) else { return }
                        pendingPayeDayRateText = newValue
                        showingPayeDayRateWarning = true
                    }
                if let payRateFieldError {
                    Text(payRateFieldError)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityIdentifier("editUser.payRateRequired")
                }
                Text(CanonicalBusinessEngine.payBasisSaveNote)
                    .font(.caption2)
                    .foregroundStyle(ManageUserProfilePalette.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 6)
                ManageUserCardDivider()
                }
                tradeTypePickSection
                if userStore.canViewPay(of: displayedUser), (permissions.operativeMode || permissions.manager || permissions.adminAccess) && !dayRateHistory.isEmpty {
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
                        title: "Qualifications",
                        subtitle: openingQualificationsEditor ? "Opening…" : "Manage assigned qualifications",
                        action: { openQualificationsEditor() }
                    )
                    .disabled(openingQualificationsEditor)
                }
            }
        }
    }

    private var taxIdColors: SensitiveFieldColors {
        SensitiveFieldColors(
            primary: ManageUserProfilePalette.textPrimary,
            secondary: ManageUserProfilePalette.textSecondary
        )
    }

    private var billingDetailsCard: some View {
        ManageUserCard {
            VStack(spacing: 0) {
                taxIdRow(
                    iconName: "doc.text.fill",
                    iconBackground: ManageUserProfilePalette.chipPurpleBg,
                    iconForeground: ManageUserProfilePalette.chipPurpleFg,
                    label: "VAT number",
                    placeholder: "If VAT registered",
                    draft: $vatDraft,
                    token: "editUser.vatNumber"
                )
                ManageUserCardDivider()
                taxIdRow(
                    iconName: "number",
                    iconBackground: ManageUserProfilePalette.chipAmberBg,
                    iconForeground: ManageUserProfilePalette.chipAmberFg,
                    label: "UTR number",
                    placeholder: "Unique Taxpayer Reference",
                    draft: $utrDraft,
                    token: "editUser.utrNumber"
                )
            }
        }
        .task(id: user.id) { await loadTaxIds() }
    }

    private func taxIdRow(
        iconName: String,
        iconBackground: Color,
        iconForeground: Color,
        label: String,
        placeholder: String,
        draft: Binding<SensitiveFieldDraft>,
        token: String
    ) -> some View {
        HStack(alignment: .center, spacing: 12) {
            ManageUserIconChip(systemName: iconName, background: iconBackground, foreground: iconForeground)
            Group {
                if !canViewTaxIds {
                    SensitiveFieldHeldByAdmin(label: label, colors: taxIdColors, accessibilityToken: token)
                } else if isLoadingTaxIds {
                    ProgressView()
                } else {
                    SensitiveFieldEditor(
                        label: label,
                        placeholder: placeholder,
                        draft: draft,
                        colors: taxIdColors,
                        accessibilityToken: token
                    )
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 14)
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
        .accessibilityIdentifier("editUser.personBadgePlus")
        .buttonStyle(.plain)
        .sheet(isPresented: $showingLineManagerPicker) {
            LineManagersMultiSelectSheet(
                candidates: lineManagerCandidates.filter { $0.id != user.id },
                selectedIds: $selectedLineManagerUserIds,
                allowNoLineManager: LineManagerRulebook.allowsNoLineManager(for: draftUserForAnnualLeaveValidation),
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
                        .accessibilityIdentifier("editUser.row.\(trade.id)")
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
            .accessibilityIdentifier("editUser.menu")
            .buttonStyle(.plain)

            if tradePresetRaw == StaffTradeType.other.rawValue {
                TextField("Enter trade name", text: $tradeCustomText)
                    .accessibilityIdentifier("editUser.enterTradeName")
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
                    Text(entry.dayRate.map { "\(localeCurrencySymbol())\(String(format: "%.2f", $0))" } ?? "Not set")
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
        guard isPayrollRateDirty(versus: subjectUser) else { return false }
        if permissions.operativeMode { return true }
        if !permissions.operativeMode && (permissions.manager || permissions.adminAccess) { return true }
        return false
    }

    /// Single edit field shows day or hourly — dirty must compare against whichever is currently displayed.
    private func displayedPayrollRate(for user: AppUser) -> Double? {
        UserStore.storedPay(of: user).amount
    }

    /// RULEBOOK 1.13.0 §8 (Q1 step C): pay is read pay profile first (`overlayPayProfile`), users document second —
    /// 1.26.0: only while `privatePay` is on (`UserStore.refreshPayFromPayProfile`); off, the editor is seeded from the
    /// users document. Drafts the editor has not touched follow the pay shown.
    ///
    /// RULEBOOK 1.26.1 §8 (`CanonicalBusinessEngine.payEditorStartingValues`): the record read here is both the drafts'
    /// starting value and every save baseline (`payBaselineUser`). While `privatePay` is on the form and Save wait for it
    /// (`payRecordLoading`), so no save runs on the pre-read value.
    private func refreshPayFromPayProfile() async {
        let started = payLoadGate.generation
        let before = userStore.rosterRow(for: user.id) ?? user
        let after = await userStore.refreshPayFromPayProfile(of: before)
        // A switch change since this read began starts a newer read; this one is dropped.
        guard !Task.isCancelled, payLoadGate.finish(generation: started) else { return }
        let seed = payDraftSeed ?? before
        payRecord = SecuritySwitchContext.privatePay ? after : nil
        payDraftSeed = after
        dayRateText = PayEditorLoadGate.reseeded(
            draft: dayRateText,
            seededWith: Self.formatPayrollRateText(user: seed),
            record: Self.formatPayrollRateText(user: after)
        )
        employmentTypeDraft = PayEditorLoadGate.reseeded(
            draft: employmentTypeDraft,
            seededWith: seed.employmentType,
            record: after.employmentType
        )
    }

    /// True while `privatePay` is on and the editor's starting record has not been read yet.
    private var payRecordLoading: Bool {
        payLoadGate.isLoading(privatePay: SecuritySwitchContext.privatePay)
    }

    /// The save baseline (RULEBOOK 1.26.1 §8): the stored person with the pay fields of the editor's record — the same
    /// record the drafts started from. Without a record (switch off) the stored person, exactly as before.
    private var payBaselineUser: AppUser {
        let stored = userStore.rosterRow(for: user.id) ?? user
        return payRecord.map { stored.withPayFields(of: $0) } ?? stored
    }

    /// `payRateRequiredError` for the person as this save will leave them: the draft employment type and the rate on
    /// the field (the stored rate when the field is untouched), read with the stored basis. Nil when the writer may
    /// not set this person's pay (`canChangePersonPay`) or the rule passes.
    private var payRateRequiredMessageForSave: String? {
        let subject = payBaselineUser
        // The rate field is on the setup card; without it the person could not be given a rate here.
        guard showOperativeSetupCard, userStore.canViewPay(of: subject), userStore.canChangePay(of: subject) else { return nil }
        let stored = UserStore.storedPay(of: subject)
        let amount = isPayrollRateDirty(versus: subject) ? parseDayRate(dayRateText) : stored.amount
        return PayRateRequiredRulebook.error(employmentType: employmentTypeDraft, payBasis: stored.basis, amount: amount)
    }

    private func isPayrollRateDirty(versus user: AppUser) -> Bool {
        parseDayRate(dayRateText) != displayedPayrollRate(for: user)
    }

    private func openQualificationsEditor() {
        guard canEditPermissionsMatrix else { return }
        openingQualificationsEditor = true
        Task {
            let subject = userStore.rosterRow(for: user.id) ?? user
            let op: Operative?
            if let linked = linkedOperativeForUser {
                op = linked
            } else {
                op = await userStore.ensureOperativeProfileForAppUser(subject, operativeStore: operativeStore)
            }
            await MainActor.run {
                openingQualificationsEditor = false
                operativeForQualificationsEditor = op
                if op != nil {
                    showingQualificationsEditor = true
                } else {
                    saveErrorMessage = "Could not create a linked operative profile for qualifications. Check email and try again."
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
                        .disabled(!smartCache.isOnline)
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
                        .disabled(!smartCache.isOnline)
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

                if canOfferChangeSuperAdmin {
                    ManageUserAccountActionButton(
                        iconName: "crown.fill",
                        iconBackground: ManageUserProfilePalette.chipPurpleBg,
                        iconForeground: ManageUserProfilePalette.chipPurpleFg,
                        title: "Change Super Admin",
                        subtitle: "Pick another administrator to take over.",
                        action: {
                            transferSuperAdminMessage = nil
                            pendingSuperAdminUserId = nil
                            showingChangeSuperAdminPicker = true
                        },
                        isBusy: isTransferringSuperAdmin
                    )
                    .disabled(!smartCache.isOnline)
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
                            followStoredPermissionsIfDraftUnchanged()
                            changeUserTypeDraft = storedAccountKind(of: displayedUser)
                            applyDraftsForChangeUserTypeSelection()
                            userTypeChangeMessage = nil
                            showingPromoteToAdminConfirmation = false
                            showingChangeUserType = true
                        }
                    )
                    .disabled(!smartCache.isOnline)
                }

                if canUseAdminAccountTools || canManageThisOperative,
                   !isViewingSuperAdminProfile {
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
                    .disabled(!smartCache.isOnline)

                    if let message = activeStatusMessage {
                        Text(message)
                            .font(.caption)
                            .foregroundStyle(ManageUserProfilePalette.textSecondary)
                            .padding(.leading, 4)
                    }
                }

                if canUseAdminAccountTools || canManageThisOperative,
                   userStore.canDeleteUser(user),
                   !isViewingSuperAdminProfile {
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
                    .disabled(!smartCache.isOnline)
                }
            }
        }
    }

    private func transferSuperAdmin(to newOwner: AppUser) {
        isTransferringSuperAdmin = true
        transferSuperAdminMessage = nil
        pendingSuperAdminUserId = nil
        Task {
            let success = await userStore.transferSuperAdmin(to: newOwner.id)
            await MainActor.run {
                isTransferringSuperAdmin = false
                let name = newOwner.fullName.trimmingCharacters(in: .whitespacesAndNewlines)
                let display = name.isEmpty ? newOwner.email : name
                transferSuperAdminMessage = success
                    ? "✅ Ownership transferred. \(display) is now Super Admin."
                    : (userStore.errorMessage ?? "❌ Failed to transfer ownership.")
                if success { dismiss() }
            }
        }
    }

    private var changeSuperAdminPicker: some View {
        NavigationStack {
            Group {
                if superAdminTransferCandidates.isEmpty {
                    Text("You need another administrator first.")
                        .font(.body)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(ManageUserProfilePalette.textSecondary)
                        .padding(.horizontal, 24)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List(superAdminTransferCandidates) { candidate in
                        Button {
                            pendingSuperAdminUserId = candidate.id
                            showingChangeSuperAdminPicker = false
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(rosterDisplayName(candidate))
                                    .font(.body)
                                    .foregroundStyle(ManageUserProfilePalette.textPrimary)
                                if !candidate.fullName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                    Text(candidate.email)
                                        .font(.caption)
                                        .foregroundStyle(ManageUserProfilePalette.textSecondary)
                                }
                            }
                        }
                            .accessibilityIdentifier("editUser.button")
                    }
                }
            }
            .navigationTitle("Change Super Admin")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { showingChangeSuperAdminPicker = false }
                        .accessibilityIdentifier("editUser.cancel5")
                }
            }
        }
    }

    private func toggleActiveStatus() {
        isUpdatingActiveStatus = true
        activeStatusMessage = nil
        let newValue = !isActive
        let target = userStore.rosterRow(for: user.id) ?? user
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
            if isViewingSuperAdminProfile {
                ManageUserSectionTitle(text: "Permissions")
                ManageUserCard {
                    VStack(alignment: .leading, spacing: 0) {
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
                            Text("The Super Admin's permissions cannot be changed. Super Admin is passed on with Change Super Admin.")
                                .font(.system(size: 11))
                                .foregroundStyle(ManageUserProfilePalette.textSecondary)
                        }
                    }
                    .padding(16)
                    // Owner decision 4 Nov: the Super Admin card shows both self-manage toggles on, greyed out, with a
                    // note (RULEBOOK 1.28.0 `SUPER_ADMIN_SELF_MANAGE_MESSAGE`; the Super Admin reads both on).
                    ManageUserPermissionToggleRow(
                        iconName: "beach.umbrella.fill",
                        iconBackground: ManageUserProfilePalette.chipBlueBg,
                        iconForeground: ManageUserProfilePalette.chipBlueFg,
                        title: "Annual Leave Management",
                        subtitle: "Books their own annual leave without approval.",
                        isOn: .constant(true),
                        isDisabled: true
                    )
                    .accessibilityIdentifier("editUser.superAdmin.annualLeaveSelfBook")
                    ManageUserPermissionToggleRow(
                        iconName: "signature",
                        iconBackground: ManageUserProfilePalette.chipBlueBg,
                        iconForeground: ManageUserProfilePalette.chipBlueFg,
                        title: "Timesheet self-sign",
                        subtitle: "Signs their own timesheet without a line manager.",
                        isOn: .constant(true),
                        isDisabled: true
                    )
                    .accessibilityIdentifier("editUser.superAdmin.timesheetSelfSign")
                    Text(SuperAdminCardCopy.selfManageNote)
                        .font(.caption)
                        .foregroundStyle(ManageUserProfilePalette.textSecondary)
                        .padding(.horizontal, 14)
                        .padding(.bottom, 12)
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
                            }
                        }
                    }
                }
            }
        }
    }

    /// The level the Edit User rows are shown for: `permissionLevelOf` the draft (its role and flags).
    private var editPermissionLevel: RulebookPermissionLevel {
        draftUserForAnnualLeaveValidation.permissionLevel
    }

    /// RULEBOOK 1.11.0 §11: `permissionToggleRows({ level, user: draft, mode: 'edit' })` — the rows Add User and its
    /// summary show for this level. Admins and super admins: every toggle on and greyed out except Annual Leave
    /// Management; managers: Materials and Site audit on and greyed out; operatives: Materials and Site audit.
    /// RULEBOOK 1.28.0: the Super Admin's self-manage rows are on and locked, a PAYE admin's Timesheet self-sign row is
    /// greyed out, and the viewer's own self-manage rows are locked (`viewerIsSubject`); each says why in `note`.
    private func editPermissionRows(level: RulebookPermissionLevel) -> [RulebookPermissionToggleRow] {
        CanonicalBusinessEngine.permissionToggleRows(
            level: level,
            user: draftUserForAnnualLeaveValidation.permissionSubject,
            mode: .edit,
            viewerIsSubject: viewerIsEditedPerson
        )
        .filter(\.visible)
        .filter { !(suppressAdminAccessToggle && $0.field == "adminAccess") }
    }

    /// The signed-in person is the person being edited: their own self-manage rows are locked. Plain id
    /// equality, as web (`EditUserProfile`) and the security rules (`request.auth.uid == userId`) decide it.
    private var viewerIsEditedPerson: Bool {
        guard let viewer = userStore.currentUser else { return false }
        return viewer.id == user.id
    }

    private func editPermissionBinding(_ row: RulebookPermissionToggleRow) -> Binding<Bool> {
        guard row.editable else { return .constant(row.value) }
        return Binding(
            get: { permissions.flag(row.field) ?? row.value },
            set: { permissions.setFlag(row.field, $0) }
        )
    }

    private static func permissionIcon(_ field: String) -> (name: String, background: Color, foreground: Color) {
        switch field {
        case "adminAccess": return ("person.badge.key.fill", ManageUserProfilePalette.chipPurpleBg, ManageUserProfilePalette.chipPurpleFg)
        case "projects": return ("folder.fill", ManageUserProfilePalette.chipBlueBg, ManageUserProfilePalette.chipBlueFg)
        case "smallWorks": return ("hammer.fill", ManageUserProfilePalette.chipBlueBg, ManageUserProfilePalette.chipBlueFg)
        case "weeklyReports": return ("doc.text.fill", ManageUserProfilePalette.chipTealBg, ManageUserProfilePalette.chipTealFg)
        case "dailyOverview": return ("calendar.badge.clock", ManageUserProfilePalette.chipTealBg, ManageUserProfilePalette.chipTealFg)
        case "subContractors": return ("person.2.wave.2.fill", ManageUserProfilePalette.chipTealBg, ManageUserProfilePalette.chipTealFg)
        case "annualLeaveSelfBook": return ("beach.umbrella.fill", ManageUserProfilePalette.chipBlueBg, ManageUserProfilePalette.chipBlueFg)
        case "timesheetSelfSign": return ("signature", ManageUserProfilePalette.chipBlueBg, ManageUserProfilePalette.chipBlueFg)
        case "operatives": return ("person.crop.rectangle.stack.fill", ManageUserProfilePalette.chipPurpleBg, ManageUserProfilePalette.chipPurpleFg)
        case "qualifications": return ("rosette", ManageUserProfilePalette.chipPinkBg, ManageUserProfilePalette.chipPinkFg)
        case "wholesalersOrderHistory": return ("building.2.fill", ManageUserProfilePalette.chipAmberBg, ManageUserProfilePalette.chipAmberFg)
        case "materials": return ("shippingbox.fill", ManageUserProfilePalette.chipAmberBg, ManageUserProfilePalette.chipAmberFg)
        case "siteAudit": return ("checklist", ManageUserProfilePalette.chipTealBg, ManageUserProfilePalette.chipTealFg)
        default: return ("switch.2", ManageUserProfilePalette.chipBlueBg, ManageUserProfilePalette.chipBlueFg)
        }
    }

    @ViewBuilder
    private func editPermissionRowsView(level: RulebookPermissionLevel) -> some View {
        let rows = editPermissionRows(level: level)
        VStack(spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.element.field) { index, row in
                if index > 0 { ManageUserCardDivider() }
                let icon = Self.permissionIcon(row.field)
                if row.field == "annualLeaveSelfBook" {
                    // RULEBOOK 1.28.0: having no line manager no longer self-books anyone; the toggle decides
                    // (`canSelfBookAnnualLeave`), and an admin with no line manager needs both self-manage toggles on
                    // (`lineManagerRequiredError` refuses the save otherwise).
                    ManageUserExpandablePermissionToggleRow(
                        iconName: icon.name,
                        iconBackground: icon.background,
                        iconForeground: icon.foreground,
                        title: row.label,
                        description: row.help,
                        isOn: editPermissionBinding(row),
                        isDisabled: !row.editable,
                        onDisabledTap: lockedPermissionTap(row, level: level)
                    )
                    .onChange(of: permissions.annualLeaveSelfBook) { oldValue, newValue in
                        if oldValue && !newValue {
                            selfBookOffConfirmationAccepted = false
                        }
                    }
                    permissionRowNote(row)
                } else {
                    ManageUserExpandablePermissionToggleRow(
                        iconName: icon.name,
                        iconBackground: icon.background,
                        iconForeground: icon.foreground,
                        title: row.label,
                        description: row.help,
                        isOn: editPermissionBinding(row),
                        isDisabled: !row.editable,
                        onDisabledTap: lockedPermissionTap(row, level: level)
                    )
                    permissionRowNote(row)
                }
            }
        }
    }

    /// RULEBOOK 1.28.0 `permissionToggleRows` `note`: why a self-manage row is greyed out.
    @ViewBuilder
    private func permissionRowNote(_ row: RulebookPermissionToggleRow) -> some View {
        if let note = row.note, !note.isEmpty {
            Text(note)
                .font(.caption)
                .foregroundStyle(ManageUserProfilePalette.textSecondary)
                .padding(.horizontal, 14)
                .padding(.bottom, 8)
                .accessibilityIdentifier("editUser.permissionNote.\(row.field)")
        }
    }

    /// A locked row explains why it cannot be changed.
    private func lockedPermissionTap(_ row: RulebookPermissionToggleRow, level: RulebookPermissionLevel) -> (() -> Void)? {
        guard !row.editable else { return nil }
        let message = row.note ?? (level == .admin
            ? CanonicalBusinessEngine.adminLockedPermissionMessage
            : "\(row.label) is always on for managers.")
        return {
            lockedPermissionMessage = message
            showingAdminAccessLockedMessage = true
        }
    }

    private var operativeMaterialsAndSiteAuditRows: some View {
        editPermissionRowsView(level: .operative)
    }

    /// Every row for an admin or manager (`permissionToggleRows`), in the rulebook's order.
    private var adminAndManagerCapabilityPermissionRows: some View {
        editPermissionRowsView(level: editPermissionLevel == .operative ? .manager : editPermissionLevel)
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
            // RULEBOOK 1.14.0 §8, §11 `payRateRequiredError`: a self-employed person as this save leaves them (including
            // a change to self-employed, immediate or dated) needs a rate above 0. Only when the writer may set pay.
            if let payMessage = payRateRequiredMessageForSave {
                await MainActor.run {
                    isUpdating = false
                    payRateFieldError = payMessage
                    saveErrorMessage = payMessage
                }
                return
            }
            // RULEBOOK 1.12.0 §4.4 `validateLeaveYearMonths`: when this save changes the leave-year months, a year that
            // is not 12 months is refused before anything is written.
            if canEditPermissionsMatrix && annualLeaveEntitlementDirty {
                let saved = userStore.rosterRow(for: user.id) ?? user
                let monthsChanged = annualLeaveStartMonth != saved.annualLeaveYearStartMonth
                    || annualLeaveEndMonth != saved.annualLeaveYearEndMonth
                if monthsChanged,
                   let leaveYearError = CanonicalBusinessEngine.leaveYearMonthsError(
                       startMonth: annualLeaveStartMonth,
                       endMonth: annualLeaveEndMonth
                   ) {
                    await MainActor.run {
                        isUpdating = false
                        saveErrorMessage = leaveYearError
                    }
                    return
                }
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

            let rateSubject = payBaselineUser
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

        // RULEBOOK 1.26.1 §8 (`CanonicalBusinessEngine.payEditorStartingValues`): the baseline is the editor's record.
        let subjectUser = payBaselineUser
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
        if canEditPermissionsMatrix && !isViewingSuperAdminProfile {
            // Only the flags changed on this screen are sent, laid over the stored copy. A draft opened from an
            // older row never writes that row's flags back (an older copy turned an admin's adminAccess off).
            let editedPermissions = UserPermissionsDraftMerge.applyingEdits(
                from: permissionsBaseline,
                to: permissions,
                onto: subjectUser.permissions
            )
            if canUseAdminAccountTools && permissions != permissionsBaseline && editedPermissions != subjectUser.permissions {
                didPersistPermissions = true
                var outgoing = editedPermissions
                outgoing.skills = false
                let staffMaterialsAlwaysOn = subjectUser.isSuperAdmin
                    || outgoing.adminAccess
                    || subjectUser.role == .admin
                    || ((outgoing.manager || subjectUser.role == .manager) && !outgoing.operativeMode)
                if staffMaterialsAlwaysOn {
                    outgoing.materials = true
                    outgoing.siteAudit = true
                }
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
                merged.skills = false
                permissionsSuccess = await userStore.updateUserPermissions(
                    userId: user.id,
                    permissions: merged,
                    holidayStore: holidayStore,
                    linkedOperativeUUID: linkedOpId
                )
            }
        }

        // RULEBOOK 1.12.2 §11 `accountTypeSyncState`: a user type only partly saved (older build, interrupted save) is
        // finished on every record from the profile's level, through the same `accountTypeChangeWrites` plan.
        if canUseAdminAccountTools && !isViewingSuperAdminProfile && permissionsSuccess,
           let repair = subjectUser.accountTypeSyncState(in: firebaseBackend)?.repair {
            let current = userStore.rosterRow(for: user.id) ?? subjectUser
            let repaired = await userStore.changeAccountType(
                userId: user.id,
                kind: repair,
                screenPermissions: current.permissions,
                holidayStore: holidayStore,
                linkedOperativeUUID: linkedOpId
            )
            if !repaired.ok { permissionsSuccess = false }
        }

        var activeSuccess = true
        if (canUseAdminAccountTools || canManageThisOperative) && !isViewingSuperAdminProfile && isActive != subjectUser.isActive {
            activeSuccess = await userStore.updateUserActiveStatus(for: subjectUser, isActive: isActive)
        }

        var operativeDetailsSuccess = true
        // Both sides read through `lineManagerSelectedIds`, so an untouched picker never rewrites the stored ids.
        let managerAssignmentChanged = LineManagerRulebook.selectionChanged(
            selectedLineManagerUserIds, from: subjectUser, roster: userStore.organizationUsers
        )
        let hasNoLineManagerChanged = hasNoLineManagerDraft != subjectUser.hasNoLineManager
        let operativeDayRateChanged = isPayrollRateDirty(versus: subjectUser)
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
                // Only an operative's rate is saved here; staff rates go through `updateManagerDayRate`.
                updateDayRate: permissions.operativeMode && operativeDayRateChanged
            )
        }

        var managerDayRateSuccess = true
        let staffDayRateChanged = !permissions.operativeMode && (permissions.manager || permissions.adminAccess)
            && isPayrollRateDirty(versus: subjectUser)
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

        var employmentStartSuccess = true
        if employmentStartDateDirty {
            employmentStartSuccess = await userStore.updateUserEmploymentStartDate(
                userId: user.id,
                dayKey: employmentStartDateDraft.isEmpty ? nil : employmentStartDateDraft
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
            let writeRemaining = remainingLeaveText != baselineRemainingText
            var yearAllowance: Double?
            var yearAllowanceKey: String?
            if writeRemaining {
                guard let remaining = parsedRemainingForSave() else {
                    await MainActor.run {
                        isUpdating = false
                        saveErrorMessage = "Enter the remaining allowance in steps of 0.5."
                    }
                    return
                }
                let summary = AnnualLeavePolicy.usageSummary(
                    bookings: holidayStore.myBookings(account: subjectUser, operatives: operativeStore.allOperatives),
                    daysPerYear: days,
                    startMonth: annualLeaveStartMonth,
                    endMonth: annualLeaveEndMonth,
                    carriesOver: annualLeaveCarriesOver,
                    annualLeaveEnabled: true,
                    orgDaysPerYear: (firebaseBackend.currentOrganization?.settings.annualLeaveDefaults ?? .default).daysPerYear,
                    orgStartMonth: (firebaseBackend.currentOrganization?.settings.annualLeaveDefaults ?? .default).startMonth,
                    orgEndMonth: (firebaseBackend.currentOrganization?.settings.annualLeaveDefaults ?? .default).endMonth,
                    yearAllowance: subjectUser.annualLeaveYearAllowance,
                    yearAllowanceKey: subjectUser.annualLeaveYearAllowanceKey,
                    employmentStartDayKey: subjectUser.employmentStartDate
                )
                guard let override = CanonicalBusinessEngine.applyRemainingOverride(
                    remaining: remaining,
                    taken: summary.takenDays,
                    pending: summary.pendingDays,
                    yearKey: summary.yearKey
                ) else {
                    await MainActor.run {
                        isUpdating = false
                        saveErrorMessage = "Could not save the remaining allowance."
                    }
                    return
                }
                yearAllowance = override.annualLeaveYearAllowance
                yearAllowanceKey = override.annualLeaveYearAllowanceKey
            }
            annualLeaveSuccess = await userStore.updateUserAnnualLeaveEntitlement(
                userId: user.id,
                daysPerYear: days,
                startMonth: annualLeaveStartMonth,
                endMonth: annualLeaveEndMonth,
                carriesOver: annualLeaveCarriesOver,
                yearAllowance: yearAllowance,
                yearAllowanceKey: yearAllowanceKey,
                writeYearAllowance: writeRemaining
            )
        }

        var billingSuccess = true
        if canViewTaxIds && (vatDraft.isDirty || utrDraft.isDirty) {
            let vat = vatDraft.valueToSave
            let utr = utrDraft.valueToSave
            billingSuccess = await userStore.updateUserBillingProfile(
                userId: user.id,
                vatNumber: vat,
                utrNumber: utr
            )
            if billingSuccess {
                vatDraft.reset(saved: vat)
                utrDraft.reset(saved: utr)
            }
        }

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

        if didPersistPermissions && permissionsSuccess {
            await holidayStore.loadData()
        }

        // Never delete leave (owner decision 4 Nov): switching Annual Leave Management off keeps every approved and
        // pending record; only future leave is requested instead of saved approved.

        await MainActor.run {
            isUpdating = false
            showingDayRateEffectiveChoice = false
            employmentTypeConfirmationAccepted = false
            showingEmploymentTypeEffectiveDatePicker = false
            selfBookOffConfirmationAccepted = false
            if identitySuccess && permissionsSuccess && activeSuccess && operativeDetailsSuccess && managerDayRateSuccess && tradeSuccess && employmentTypeSuccess && employmentStartSuccess && annualLeaveEnabledSuccess && annualLeaveSuccess && billingSuccess {
                dismiss()
            } else {
                if !permissionsSuccess {
                    // A refused permission save shows the stored flags again, never the unsaved ones.
                    let stored = userStore.rosterRow(for: user.id) ?? user
                    permissions = stored.permissions
                    permissionsBaseline = stored.permissions
                }
                saveErrorMessage = userStore.errorMessage ?? "Could not save these user changes. Please try again."
            }
        }
    }

    /// The stored amount for the stored basis (`readStoredRates`), as the single rate field shows it.
    private static func formatPayrollRateText(user: AppUser) -> String {
        guard let amount = UserStore.storedPay(of: user).amount else { return "" }
        return String(format: "%.2f", amount)
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

    /// Organisation currency symbol (RULEBOOK §4.2), stripped from a typed rate.
    private func localeCurrencySymbol() -> String {
        OrgMoney.symbol()
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
        // RULEBOOK 1.12.0 §11 `invitationIsOperativeOnly`: refused here, before the old links are marked used.
        if let refusal = InvitationDocument.resendRefusal(subject: user, inviter: userStore.currentUser) {
            resendEmailMessage = "❌ \(refusal)"
            isResendingEmail = false
            return
        }
        let db = Firestore.firestore()
        do {
            // Mark all existing invitations for this email as used so only the new link works
            let existing = try await db.collection("invitations")
                .whereField("email", isEqualTo: user.email)
                .getDocuments()
            for doc in existing.documents {
                try? await doc.reference.updateData(InvitationDocument.usedFields())
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
                "skills": false,
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
        invitationData["employmentType"] = user.employmentType.rawValue
        
        do {
            // RULEBOOK 1.9.0 §11: created once with `invitationCreateFields`.
            // RULEBOOK 1.23.1 §11 `CanonicalBusinessEngine` `userMissingLevel`: never an invite without a user level.
            try RulebookRosterLists.requireInviteLevel(invitationData)
            try await db.collection("invitations").document(invitationId).setData(InvitationDocument.createFields(from: invitationData))

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
        // RULEBOOK 1.12.0 §11 `invitationIsOperativeOnly`: refused here, before the old links are marked used.
        if let refusal = InvitationDocument.resendRefusal(subject: user, inviter: userStore.currentUser) {
            isSendingSignUpEmail = false
            isResendingEmail = false
            signUpEmailMessage = "❌ \(refusal)"
            resendEmailMessage = "❌ \(refusal)"
            return
        }

        Task {
            let db = Firestore.firestore()
            do {
                // Mark all existing invitations for this email as used so only the new link works
                let existing = try await db.collection("invitations")
                    .whereField("email", isEqualTo: user.email)
                    .getDocuments()
                for doc in existing.documents {
                    try? await doc.reference.updateData(InvitationDocument.usedFields())
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
                        "skills": false,
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
                invitationData["employmentType"] = user.employmentType.rawValue
                // RULEBOOK 1.9.0 §11: created once with `invitationCreateFields`.
                // RULEBOOK 1.23.1 §11 `CanonicalBusinessEngine` `userMissingLevel`: never an invite without a user level.
                try RulebookRosterLists.requireInviteLevel(invitationData)
                try await db.collection("invitations").document(invitationId).setData(InvitationDocument.createFields(from: invitationData))

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
            userStore.errorMessage = nil
            await userStore.deleteUser(user, bookingStore: bookingStore, operativeStore: operativeStore)
            // Reload users after deletion
            await userStore.loadOrganizationUsers()
            await MainActor.run {
                // A refused delete (RULEBOOK 1.31.0 `lineManagerChangeBlock` lists the reports) keeps the screen open.
                if userStore.rosterRow(for: user.id) != nil, let message = userStore.errorMessage {
                    saveErrorMessage = message
                } else {
                    dismiss()
                }
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
        .accessibilityIdentifier("tab.\(AccessibilityID.token(title))")
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
        .environmentObject(SmartCacheService())
}

/// Manage Users opened from Home (decision D2). Home is not inside a navigation stack (ContentView keeps
/// tab 0 out of one), so Home shows this stack with Manage Users already pushed. The system back button
/// pops it, and an empty path closes the stack without animation, so back returns to Home.
struct ManageUsersPushedFromHome: View {
    enum Route: Hashable {
        case manageUsers
    }

    @Binding var isPresented: Bool
    @State private var path: [Route] = [.manageUsers]

    var body: some View {
        NavigationStack(path: $path) {
            PPColor.page
                .ignoresSafeArea()
                .navigationDestination(for: Route.self) { _ in
                    ManageUsersView()
                }
        }
        .onChange(of: path) { _, newValue in
            guard newValue.isEmpty else { return }
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                isPresented = false
            }
        }
    }
}

/// The note under the Super Admin's locked self-manage toggles (`SUPER_ADMIN_SELF_MANAGE_MESSAGE`, RULEBOOK 1.28.0).
enum SuperAdminCardCopy {
    static var selfManageNote: String {
        CanonicalBusinessEngine.constant("SUPER_ADMIN_SELF_MANAGE_MESSAGE", as: String.self)
            ?? "The Super Admin always books their own leave and signs their own timesheet."
    }
}
