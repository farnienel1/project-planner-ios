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
    
    // Get managers from users - includes admins (who are automatically managers) and users with manager permission
    private var allManagers: [AppUser] {
        userStore.organizationUsers.filter { user in
            guard !user.permissions.operativeMode else { return false }
            // Match Manage Users → Managers tab: admins and manager-role accounts only
            return (user.permissions.adminAccess || user.isSuperAdmin) || user.permissions.manager
        }
    }
    
    private var filteredManagers: [AppUser] {
        var managers = allManagers
        
        managers = managers.filter { rosterSegment.matches($0) }
        
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
            HStack {
                Button(action: {
                    NotificationCenter.default.post(name: NSNotification.Name("goBackToPreviousTab"), object: nil)
                }) {
                    Image(systemName: "chevron.left")
                        .foregroundColor(Color.theme.primary(for: appSettings.settings.colorScheme))
                        .font(.system(size: 17, weight: .semibold))
                }
                Spacer()
                Text("Managers")
                    .font(.headline)
                Spacer()
                Button(action: { showingFilterOptions.toggle() }) {
                    Image(systemName: "line.3.horizontal.decrease.circle")
                        .foregroundColor(.primary)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(Color(.systemBackground))
            
            managersList
        }
            .toolbar(.hidden, for: .navigationBar)
            .navigationBarBackButtonHidden(true)
            .sheet(item: $selectedUser) { user in
                EditUserView(user: user)
                    .environmentObject(userStore)
                    .environmentObject(bookingStore)
                    .environmentObject(operativeStore)
                    .environmentObject(holidayStore)
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
    
    @ViewBuilder
    private var managersList: some View {
        VStack(spacing: 0) {
            // Active / Inactive / Pending tab bar stays fixed at top.
            HStack(spacing: 0) {
                ForEach(UserRosterSegment.allCases) { seg in
                    OperativeTabButton(title: seg.title, isSelected: rosterSegment == seg) {
                        rosterSegment = seg
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .background(Color(.systemGroupedBackground))
            
            // Filter bar
            if !filterText.isEmpty {
                HStack {
                    Text("Filter: \(selectedFilterType.rawValue) - \(filterText)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Spacer()
                    Button("Clear") {
                        filterText = ""
                    }
                    .font(.caption)
                }
                .padding(.horizontal)
                .padding(.vertical, 8)
                .background(Color(.systemGray6))
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
                            selectedUser = user
                        }
                    }
                    .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                    .listRowSeparator(.hidden)
                }
                .listStyle(PlainListStyle())
            }
        }
    }
    
    private var emptyManagersView: some View {
        VStack(spacing: 20) {
            Image(systemName: "person.2.fill")
                .font(.system(size: 60))
                .foregroundColor(.gray)
            
            Text(emptyManagersTitle)
                .font(.title2)
                .fontWeight(.semibold)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
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
                    HStack {
                        Text(user.fullName)
                            .font(.headline)
                            .foregroundColor(.primary)
                        
                        // Show Admin badge if user is admin
                        if user.permissions.adminAccess || user.isSuperAdmin {
                            Text("Admin")
                                .font(.caption2)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.green.opacity(0.2))
                                .foregroundColor(.green)
                                .cornerRadius(4)
                        }
                    }
                    
                    Text(user.email)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                    
                    if let mobileNumber = user.mobileNumber, !mobileNumber.isEmpty {
                        HStack {
                            Image(systemName: "phone")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                            Text(mobileNumber)
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                    
                    HStack {
                        Text(user.isActive ? "Active" : "Inactive")
                            .font(.caption)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(user.isActive ? Color.green.opacity(0.2) : Color.red.opacity(0.2))
                            .foregroundColor(user.isActive ? .green : .red)
                            .cornerRadius(8)
                        
                        if !user.passwordSet {
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
                
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundColor(.gray)
            }
            .padding(.vertical, 8)
        }
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
                }
                
                Section("Search") {
                    TextField("Enter search term", text: $filterText)
                }
            }
            .navigationTitle("Filter Managers")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
    }
}

#Preview {
    ManagersView()
        .environmentObject(UserStore())
}
