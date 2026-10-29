//
//  ManagersView.swift
//  Project Planner
//
//  Created by Assistant on 23/10/2025.
//

import SwiftUI
import UIKit

struct ManagersView: View {
    @EnvironmentObject var userStore: UserStore
    @EnvironmentObject var bookingStore: BookingStore
    @EnvironmentObject var operativeStore: OperativeStore
    @EnvironmentObject var holidayStore: HolidayStore
    @EnvironmentObject var firebaseBackend: FirebaseBackend
    @EnvironmentObject var notificationService: NotificationService
    @EnvironmentObject var appSettings: AppSettingsStore
    @Environment(\.dismiss) private var dismiss
    @State private var selectedUser: AppUser?
    @State private var showingEditUser = false
    @State private var filterText = ""
    @State private var selectedFilterType: FilterType = .firstName
    @State private var showingFilterOptions = false
    @State private var rosterSegment: UserRosterSegment = .active
    
    enum FilterType: String, CaseIterable {
        case firstName = "First Name"
        case surname = "Surname"
        case email = "Email"
        case mobileNumber = "Mobile Number"
    }
    
    // Get managers from users — exclude administrators (they appear under Admins / Manage Users).
    private var allManagers: [AppUser] {
        userStore.organizationUsers.filter { $0.appearsOnManagersList }
    }
    
    private var filteredManagers: [AppUser] {
        var managers = allManagers
        
        managers = CanonicalBusinessEngine.listedRosterUsers(
            managers,
            claimedEmails: userStore.organizationUserEmailClaims
        ) ?? []
        managers = managers.filter { CanonicalBusinessEngine.rosterSegment($0) == rosterSegment.canonicalSegment }
        
        // Filter by search text
        guard !filterText.isEmpty else { return managers }
        
        return managers.filter { user in
            switch selectedFilterType {
            case .firstName:
                return user.firstName.localizedCaseInsensitiveContains(filterText)
            case .surname:
                return user.surname.localizedCaseInsensitiveContains(filterText)
            case .email:
                return user.email.localizedCaseInsensitiveContains(filterText)
            case .mobileNumber:
                return (user.mobileNumber ?? "").localizedCaseInsensitiveContains(filterText)
            }
        }
    }
    
    private var hasAnyManagersInOrganization: Bool {
        !allManagers.isEmpty
    }
    
    private var emptyManagersTitle: String {
        if !hasAnyManagersInOrganization {
            return "No Managers Added Yet"
        }
        switch rosterSegment {
        case .active:
            return "No Active Managers"
        case .inactive:
            return "No Inactive Managers"
        case .pending:
            return "No Pending Managers"
        }
    }
    
    var body: some View {
        VStack(spacing: 0) {
            managersNavyHeader
            
            managersList
                .padding(.top, 10)
                .modifier(ManagersListSheet())
        }
            .background(PPColor.page.ignoresSafeArea())
            .toolbar(.hidden, for: .navigationBar)
            .navigationBarBackButtonHidden(true)
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
            }
            .sheet(isPresented: $showingFilterOptions) {
                ManagerFilterOptionsView(selectedFilter: $selectedFilterType, filterText: $filterText)
            }
            .task {
                await userStore.loadOrganizationUsers()
            }
            .refreshable {
                await userStore.loadOrganizationUsers()
            }
            .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("resetNavigationForTab"))) { notification in
                if let userInfo = notification.userInfo,
                   let tab = userInfo["tab"] as? Int,
                   tab == 4 {
                    // Reset to managers list (already at root)
                    // Use async to prevent state update during view update
                    DispatchQueue.main.async {
                        selectedUser = nil
                    }
                }
            }
    }
    
    /// Home-style navy header: back, title and filter, roster numbers, then the Active / Inactive / Pending tabs.
    private var managersNavyHeader: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 12) {
                Button(action: {
                    NotificationCenter.default.post(name: NSNotification.Name("goBackToPreviousTab"), object: nil)
                }) {
                    Image(systemName: "chevron.left")
                }
                    .buttonStyle(PPOnNavyCircleButtonStyle(size: 36))
                    .accessibilityIdentifier("managers.gobacktoprevioustab")
                PPNavyPageTitle(title: "Managers")
                Spacer(minLength: 8)
                Button(action: { showingFilterOptions.toggle() }) {
                    Image(systemName: "line.3.horizontal.decrease.circle")
                }
                    .buttonStyle(PPOnNavyCircleButtonStyle(size: 36))
                    .accessibilityIdentifier("managers.filter")
            }
            
            managersStatsRow(managerRosterCounts)
                .padding(.top, 18)
            
            // Active / Inactive / Pending tab bar stays fixed at top.
            HStack(spacing: 4) {
                ForEach(UserRosterSegment.allCases) { seg in
                    OperativeTabButton(title: seg.title, isSelected: rosterSegment == seg) {
                        rosterSegment = seg
                    }
                }
            }
            .padding(4)
            .background(Capsule().fill(PPColor.onNavyFill))
            .overlay(Capsule().strokeBorder(PPColor.onNavyStroke, lineWidth: 0.5))
            .padding(.top, 20)
        }
        .padding(.horizontal, PPMetrics.screenGutter)
        .padding(.top, 8)
        .padding(.bottom, PPMetrics.headerBottomPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .ppNavyHeader()
    }
    
    /// Header numbers. Same `listedRosterUsers` / `rosterSegment` calls the list itself uses, before the search filter.
    private var managerRosterCounts: ManagersRosterCounts {
        let listed = CanonicalBusinessEngine.listedRosterUsers(
            allManagers,
            claimedEmails: userStore.organizationUserEmailClaims
        ) ?? []
        let segments = listed.map { CanonicalBusinessEngine.rosterSegment($0) }
        return ManagersRosterCounts(
            active: segments.filter { $0 == UserRosterSegment.active.canonicalSegment }.count,
            inactive: segments.filter { $0 == UserRosterSegment.inactive.canonicalSegment }.count,
            pending: segments.filter { $0 == UserRosterSegment.pending.canonicalSegment }.count
        )
    }
    
    private func managersStatsRow(_ counts: ManagersRosterCounts) -> some View {
        HStack(alignment: .top, spacing: 12) {
            PPStat(value: "\(counts.active)", label: "Active")
            PPStatDivider()
            PPStat(value: "\(counts.inactive)", label: "Inactive")
            PPStatDivider()
            PPStat(value: "\(counts.pending)", label: "Pending invite", highlight: counts.pending > 0)
        }
        .fixedSize(horizontal: false, vertical: true)
    }
    
    @ViewBuilder
    private var managersList: some View {
        VStack(spacing: 0) {
            // Filter bar
            if !filterText.isEmpty {
                HStack(spacing: 8) {
                    Image(systemName: "line.3.horizontal.decrease")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(PPColor.brand)
                    Text("Filter: \(selectedFilterType.rawValue) - \(filterText)")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    Button("Clear") {
                        filterText = ""
                    }
                    .accessibilityIdentifier("managers.clear")
                    .font(.footnote.weight(.semibold))
                    .tint(PPColor.brand)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(PPColor.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .padding(.horizontal, PPMetrics.screenGutter)
                .padding(.bottom, 6)
            }
            
            if userStore.isLoading {
                ProgressView("Loading managers...")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if filteredManagers.isEmpty {
                emptyManagersView
            } else {
                List(filteredManagers) { user in
                    ManagerUserRowView(user: user) {
                        // Use async to prevent state update during view update
                        DispatchQueue.main.async {
                            guard user.isStoredUserDocument else { return }
                            selectedUser = user
                        }
                    }
                    .listRowInsets(EdgeInsets(top: 5, leading: 16, bottom: 5, trailing: 16))
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
                }
                .listStyle(PlainListStyle())
                .scrollContentBackground(.hidden)
            }
        }
    }
    
    private var emptyManagersView: some View {
        VStack(spacing: 14) {
            PPIconTile(symbol: "person.2.fill", family: .people, size: PPMetrics.quickActionIcon, lifted: true)
            
            Text(emptyManagersTitle)
                .font(.system(.title3, design: .rounded))
                .fontWeight(.semibold)
                .foregroundStyle(.primary)
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, 24)
        .padding(.top, 40)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
    
}

/// Numbers shown in the Managers navy header.
private struct ManagersRosterCounts {
    let active: Int
    let inactive: Int
    let pending: Int
}

/// Light rounded sheet under the navy header that holds the list (Home's content sheet, sized for a List).
private struct ManagersListSheet: ViewModifier {
    func body(content: Content) -> some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background(PPColor.page)
            .clipShape(
                UnevenRoundedRectangle(
                    topLeadingRadius: PPMetrics.contentCornerRadius,
                    topTrailingRadius: PPMetrics.contentCornerRadius,
                    style: .continuous
                )
            )
            .padding(.top, -PPMetrics.contentOverlap)
    }
}

/// Gradient initials circle (Home icon-tile colours).
private struct ManagerInitialsAvatar: View {
    let initials: String
    let family: PPFamily
    var size: CGFloat = 46
    
    var body: some View {
        Text(initials)
            .font(.system(size: size * 0.36, weight: .bold, design: .rounded))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(family.gradient, in: Circle())
            .overlay(Circle().strokeBorder(Color.white.opacity(0.22), lineWidth: 0.5))
    }
}

/// Small tinted capsule for the existing Admin and roster status labels.
private struct ManagerStatusPill: View {
    let text: String
    let tint: Color
    
    var body: some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(tint)
            .lineLimit(1)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(tint.opacity(0.14), in: Capsule())
    }
}

// MARK: - Manager User Row View
struct ManagerUserRowView: View {
    let user: AppUser
    let onTap: () -> Void
    
    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 12) {
                // Avatar
                ManagerInitialsAvatar(
                    initials: String(user.firstName.prefix(1)) + String(user.surname.prefix(1)),
                    family: user.isActive ? .people : .system
                )
                
                // User Info
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(user.fullName)
                            .font(.body.weight(.semibold))
                            .foregroundStyle(.primary)
                        
                        // Show Admin badge if user is admin
                        if user.permissions.adminAccess || user.isSuperAdmin {
                            ManagerStatusPill(text: "Admin", tint: .green)
                        }
                    }
                    
                    Text(user.email)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    
                    if user.displayTradeType != "—" {
                        Text(user.displayTradeType)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    
                    if let mobileNumber = user.mobileNumber, !mobileNumber.isEmpty {
                        HStack(spacing: 4) {
                            Image(systemName: "phone")
                                .font(.caption2)
                            Text(mobileNumber)
                                .font(.footnote)
                        }
                        .foregroundStyle(.secondary)
                    }
                    
                    if let segment = user.rosterSegment {
                        ManagerStatusPill(
                            text: segment.title,
                            tint: segment == .pending ? .orange : (segment == .active ? .green : .red)
                        )
                        .padding(.top, 2)
                    }
                }
                
                Spacer(minLength: 8)
                
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(PPColor.card, in: RoundedRectangle(cornerRadius: PPMetrics.rowCardRadius, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: PPMetrics.rowCardRadius, style: .continuous))
        }
        .accessibilityIdentifier("managerUserRow.admin")
        .buttonStyle(PlainButtonStyle())
    }
}

// MARK: - Manager Filter Options View
struct ManagerFilterOptionsView: View {
    @Binding var selectedFilter: ManagersView.FilterType
    @Binding var filterText: String
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        NavigationView {
            Form {
                Section("Filter By") {
                    Picker("Filter Type", selection: $selectedFilter) {
                        ForEach(ManagersView.FilterType.allCases, id: \.self) { type in
                            Text(type.rawValue).tag(type)
                        }
                    }
                        .accessibilityIdentifier("managerFilterOptions.filterType")
                }
                
                Section("Search") {
                    TextField("Enter search term", text: $filterText)
                        .accessibilityIdentifier("managerFilterOptions.enterSearchTerm")
                }
            }
            .navigationTitle("Filter Managers")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                        .accessibilityIdentifier("managerFilterOptions.done")
                }
            }
        }
    }
}

#Preview {
    ManagersView()
        .environmentObject(UserStore())
        .environmentObject(BookingStore())
        .environmentObject(OperativeStore())
        .environmentObject(HolidayStore())
        .environmentObject(FirebaseBackend())
        .environmentObject(NotificationService())
        .environmentObject(AppSettingsStore())
}
