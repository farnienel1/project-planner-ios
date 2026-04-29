//
//  OperativesView.swift
//  Project Planner
//
//  Created by Assistant on 29/09/2025.
//

import SwiftUI
import UIKit

private func defaultCurrencySymbol() -> String {
    Locale.current.currencySymbol ?? "£"
}

struct OperativesView: View {
    @EnvironmentObject var operativeStore: OperativeStore
    @EnvironmentObject var userStore: UserStore
    @EnvironmentObject var bookingStore: BookingStore
    @EnvironmentObject var holidayStore: HolidayStore
    @EnvironmentObject var appSettings: AppSettingsStore
    @Environment(\.dismiss) private var dismiss
    @State private var selectedOperative: Operative? = nil
    @State private var showingEditOperative = false
    @State private var showingFinishSetup = false
    @State private var filterText = ""
    @State private var selectedFilterType: FilterType = .firstName
    @State private var showingFilterOptions = false
    @State private var selectedUserForProfile: AppUser? = nil
    @State private var rosterSegment: UserRosterSegment = .active
    @State private var operativeToDelete: Operative? = nil

    enum FilterType: String, CaseIterable {
        case firstName = "First Name"
        case surname = "Surname"
        case email = "Email"
        case startDate = "Start Date"
        case skills = "Skills"
        case qualifications = "Qualifications"
        case dayRate = "Day Rate"
    }
    
    var body: some View {
        VStack(spacing: 0) {
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
            
            if rosterSegment == .pending {
                pendingOperativeInviteesList
            } else {
                operativesList
            }
        }
            .navigationTitle("Operatives")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button(action: {
                        NotificationCenter.default.post(name: NSNotification.Name("goBackToPreviousTab"), object: nil)
                    }) {
                        Image(systemName: "chevron.left")
                            .foregroundColor(Color.theme.primary(for: appSettings.settings.colorScheme))
                            .font(.system(size: 17, weight: .semibold))
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(action: { showingFilterOptions.toggle() }) {
                        Image(systemName: "line.3.horizontal.decrease.circle")
                    }
                }
            }
            .navigationBarBackButtonHidden(true)
            .task {
                await userStore.loadOrganizationUsers()
            }
            .refreshable {
                await userStore.loadOrganizationUsers()
            }
        .sheet(isPresented: $showingFilterOptions) {
            OperativeFilterOptionsView(selectedFilter: $selectedFilterType, filterText: $filterText)
        }
        .sheet(item: $selectedUserForProfile) { user in
            EditUserView(user: user)
                .environmentObject(userStore)
                .environmentObject(bookingStore)
                .environmentObject(operativeStore)
                .environmentObject(holidayStore)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("resetNavigationForTab"))) { notification in
            if let userInfo = notification.userInfo, let tab = userInfo["tab"] as? Int, tab == 3 {
                DispatchQueue.main.async { selectedUserForProfile = nil }
            }
        }
        .sheet(isPresented: $showingEditOperative) {
            if let operative = selectedOperative {
                let _ = print("🔥🔥🔥 DEBUG: Presenting EditOperativeView for operative: \(operative.name)")
                EditOperativeView(operative: operative)
                    .environmentObject(operativeStore)
            } else {
                let _ = print("🔥🔥🔥 DEBUG: selectedOperative is nil!")
                Text("Error: No operative selected")
                    .foregroundColor(.red)
            }
        }
    }
    
    
    private var incompleteOperativesCount: Int {
        operativeStore.allOperatives.filter { !isOperativeComplete($0) }.count
    }
    
    private func isOperativeComplete(_ operative: Operative) -> Bool {
        // An operative is complete if they have:
        // - startDate set (not in future)
        // - hourlyRate set
        // - isActive set to true
        return operative.startDate <= Date() &&
               (operative.dayRate != nil || operative.hourlyRate != nil) &&
               operative.isActive
    }
    
    private func openUserProfile(for operative: Operative) {
        // Find the corresponding app user by email and open their profile (EditUserView)
        let matchingUser = userStore.organizationUsers.first { user in
            user.email.lowercased() == operative.email.lowercased()
        }
        if let user = matchingUser {
            selectedUserForProfile = user
        }
        // If no matching user found, do nothing (operative may not have been added as user yet)
    }
    
    private func operativePassesTextFilter(_ operative: Operative) -> Bool {
        guard !filterText.isEmpty else { return true }
        switch selectedFilterType {
        case .firstName:
            return operative.firstName.localizedCaseInsensitiveContains(filterText)
        case .surname:
            return operative.lastName.localizedCaseInsensitiveContains(filterText)
        case .email:
            return operative.email.localizedCaseInsensitiveContains(filterText)
        case .startDate:
            let formatter = DateFormatter()
            formatter.dateStyle = .medium
            return formatter.string(from: operative.startDate).localizedCaseInsensitiveContains(filterText)
        case .skills:
            return operative.skills.contains { $0.localizedCaseInsensitiveContains(filterText) }
        case .qualifications:
            return operative.qualifications.contains { $0.name.localizedCaseInsensitiveContains(filterText) }
        case .dayRate:
            let rate = operative.dayRate ?? operative.hourlyRate
            if let rate {
                return String(format: "%.0f", rate).contains(filterText)
            }
            return false
        }
    }

    private func operativeUserPassesTextFilter(_ user: AppUser) -> Bool {
        guard !filterText.isEmpty else { return true }
        switch selectedFilterType {
        case .firstName:
            return user.firstName.localizedCaseInsensitiveContains(filterText)
        case .surname:
            return user.surname.localizedCaseInsensitiveContains(filterText)
        case .email:
            return user.email.localizedCaseInsensitiveContains(filterText)
        case .startDate:
            if let op = operativeStore.allOperatives.first(where: { $0.email.lowercased() == user.email.lowercased() }) {
                let formatter = DateFormatter()
                formatter.dateStyle = .medium
                return formatter.string(from: op.startDate).localizedCaseInsensitiveContains(filterText)
            }
            return false
        case .skills:
            if let op = operativeStore.allOperatives.first(where: { $0.email.lowercased() == user.email.lowercased() }) {
                return op.skills.contains { $0.localizedCaseInsensitiveContains(filterText) }
            }
            return false
        case .qualifications:
            if let op = operativeStore.allOperatives.first(where: { $0.email.lowercased() == user.email.lowercased() }) {
                return op.qualifications.contains { $0.name.localizedCaseInsensitiveContains(filterText) }
            }
            return false
        case .dayRate:
            if let op = operativeStore.allOperatives.first(where: { $0.email.lowercased() == user.email.lowercased() }) {
                let rate = op.dayRate ?? op.hourlyRate
                if let rate { return String(format: "%.0f", rate).contains(filterText) }
            }
            return false
        }
    }

    /// Source of truth for operative status should mirror Manage Users (AppUser flags).
    private var linkedOperativeRecords: [(user: AppUser, operative: Operative)] {
        let operativeUsers = userStore.organizationUsers.filter { $0.permissions.operativeMode }
        return operativeUsers.compactMap { user in
            guard let op = operativeStore.allOperatives.first(where: {
                $0.email.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) ==
                user.email.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
            }) else {
                return nil
            }
            return (user, op)
        }
    }

    private var displayedOperativeUsers: [AppUser] {
        let base = userStore.organizationUsers.filter {
            $0.permissions.operativeMode && rosterSegment.matches($0)
        }
        return base.filter { operativeUserPassesTextFilter($0) }
    }
    
    /// Operative records from Firestore store, filtered by Active/Inactive segment and search text.
    private var displayedOperatives: [Operative] {
        guard rosterSegment != .pending else { return [] }
        let base = linkedOperativeRecords
            .filter { rosterSegment.matches($0.user) }
            .map(\.operative)
        return base.filter { operativePassesTextFilter($0) }
    }
    
    private var pendingOperativeInvitees: [AppUser] {
        let base = userStore.organizationUsers.filter { $0.permissions.operativeMode && !$0.passwordSet }
        guard !filterText.isEmpty else { return base }
        return base.filter { user in
            switch selectedFilterType {
            case .firstName: return user.firstName.localizedCaseInsensitiveContains(filterText)
            case .surname: return user.surname.localizedCaseInsensitiveContains(filterText)
            case .email: return user.email.localizedCaseInsensitiveContains(filterText)
            case .startDate, .skills, .qualifications, .dayRate: return true
            }
        }
    }
    
    @ViewBuilder
    private var pendingOperativeInviteesList: some View {
        if pendingOperativeInvitees.isEmpty {
            VStack(spacing: 20) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 60))
                    .foregroundColor(.green)
                
                Text("No Pending Operatives")
                    .font(.title2)
                    .fontWeight(.semibold)
                
                Text("All operative invitations are complete or there are no pending invitees.")
                    .font(.body)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
            }
            .padding()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List {
                ForEach(pendingOperativeInvitees) { user in
                    OperativeUserRowView(user: user) {
                        selectedUserForProfile = user
                    }
                    .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                    .listRowSeparator(.hidden)
                }
            }
            .listStyle(PlainListStyle())
            .refreshable {
                await userStore.loadOrganizationUsers()
            }
        }
    }
    
    @ViewBuilder
    private var operativesList: some View {
        if operativeStore.isLoading || userStore.isLoading {
            ProgressView("Loading operatives...")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if displayedOperativeUsers.isEmpty {
            emptyOperativesView
        } else {
            VStack(spacing: 0) {
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
                
                List(displayedOperativeUsers) { user in
                    OperativeUserRowView(user: user) {
                        selectedUserForProfile = user
                    }
                        .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                        .listRowSeparator(.hidden)
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button(action: {
                                if let op = operativeStore.allOperatives.first(where: { $0.email.lowercased() == user.email.lowercased() }) {
                                    operativeToDelete = op
                                }
                            }) {
                                Label("Delete", systemImage: "trash")
                                    .foregroundColor(.white)
                                    .font(.system(size: 16, weight: .medium))
                            }
                            .tint(.red)
                        }
                }
                .listStyle(PlainListStyle())
                .alert("Delete Operative", isPresented: Binding(
                    get: { operativeToDelete != nil },
                    set: { if !$0 { operativeToDelete = nil } }
                )) {
                    Button("Cancel", role: .cancel) { operativeToDelete = nil }
                    Button("Delete", role: .destructive) {
                        guard let op = operativeToDelete else { return }
                        operativeToDelete = nil
                        Task {
                            await operativeStore.deleteOperative(op, bookingStore: bookingStore)
                        }
                    }
                } message: {
                    if let op = operativeToDelete {
                        let count = bookingStore.bookings.filter { $0.operativeId == op.id }.count
                        if count > 0 {
                            Text("Are you sure you want to delete \(op.name)? This will also delete \(count) booking\(count == 1 ? "" : "s"). This cannot be undone.")
                        } else {
                            Text("Are you sure you want to delete \(op.name)? This cannot be undone.")
                        }
                    } else {
                        Text("")
                    }
                }
                .refreshable {
                    operativeStore.loadData()
                }
            }
        }
    }
    
    private var emptyOperativesView: some View {
        VStack(spacing: 20) {
            Image(systemName: "person.2.fill")
                .font(.system(size: 60))
                .foregroundColor(.gray)
            
            Text("No Operatives Added Yet")
                .font(.title2)
                .fontWeight(.semibold)
            
            Text("Add operatives to your organisation. Operatives can be assigned to projects and tasks.")
                .font(.body)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
            
            Text("Operatives must be created via the 'Add User' button in Manage Users.")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
        }
        .padding()
    }
}

// MARK: - Operative User Row (same style as Managers; links to Edit User)
struct OperativeUserRowView: View {
    let user: AppUser
    let onTap: () -> Void
    
    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 12) {
                Circle()
                    .fill(user.isActive ? Color.indigo : Color.gray)
                    .frame(width: 50, height: 50)
                    .overlay(
                        Text(user.firstName.prefix(1) + user.surname.prefix(1))
                            .font(.headline)
                            .foregroundColor(.white)
                    )
                VStack(alignment: .leading, spacing: 4) {
                    Text(user.fullName)
                        .font(.headline)
                        .foregroundColor(.primary)
                    Text(user.email)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                    if !user.passwordSet {
                        Text("Pending")
                            .font(.caption2)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.orange.opacity(0.2))
                            .foregroundColor(.orange)
                            .cornerRadius(4)
                    }
                    if !user.isActive {
                        Text("Inactive")
                            .font(.caption2)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.red.opacity(0.2))
                            .foregroundColor(.red)
                            .cornerRadius(4)
                    }
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }
}

// MARK: - Operative filter options (name, surname, email – same pattern as Managers)
struct OperativeFilterOptionsView: View {
    @Binding var selectedFilter: OperativesView.FilterType
    @Binding var filterText: String
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        NavigationView {
            List {
                ForEach(OperativesView.FilterType.allCases, id: \.self) { type in
                    Button(action: {
                        selectedFilter = type
                        dismiss()
                    }) {
                        HStack {
                            Text(type.rawValue)
                            if selectedFilter == type {
                                Spacer()
                                Image(systemName: "checkmark")
                                    .foregroundColor(.blue)
                            }
                        }
                    }
                }
                Section("Search text") {
                    TextField("Filter by \(selectedFilter.rawValue)", text: $filterText)
                }
            }
            .navigationTitle("Filter")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

struct OperativeDetailRowView: View {
    let operative: Operative
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(operative.name)
                        .font(.headline)
                        .fontWeight(.bold)
                    
                    Text(operative.email)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                    
                    if let dayRate = (operative.dayRate ?? operative.hourlyRate), dayRate > 0 {
                        let currencySymbol = operative.currencySymbol ?? defaultCurrencySymbol()
                        Text("\(currencySymbol)\(String(format: "%.0f", dayRate))/day")
                            .font(.caption)
                            .foregroundColor(.blue)
                            .fontWeight(.medium)
                    }
                }
                
                Spacer()
                
                HStack(spacing: 8) {
                    VStack(alignment: .trailing, spacing: 4) {
                        Text(operative.isActive ? "Active" : "Inactive")
                            .font(.caption)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 2)
                            .background(operative.isActive ? Color.green.opacity(0.2) : Color.red.opacity(0.2))
                            .foregroundColor(operative.isActive ? .green : .red)
                            .cornerRadius(4)
                    }
                    
                    Image(systemName: "gearshape.fill")
                        .foregroundColor(.secondary)
                        .font(.caption)
                }
            }
            
            // Skills
            if !operative.skills.isEmpty {
                let _ = print("🔥🔥🔥 DEBUG: Displaying skills for \(operative.name): \(Array(operative.skills))")
                VStack(alignment: .leading, spacing: 4) {
                    Text("Skills")
                        .font(.caption)
                        .fontWeight(.medium)
                        .foregroundColor(.secondary)
                    
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 2), spacing: 4) {
                        ForEach(Array(operative.skills.prefix(4)), id: \.self) { skill in
                            Text(skill)
                                .font(.caption)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color(.systemGray5))
                                .cornerRadius(4)
                        }
                        
                        if operative.skills.count > 4 {
                            Text("+\(operative.skills.count - 4) more")
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color(.systemGray5))
                                .cornerRadius(4)
                        }
                    }
                }
            }
            
            // Qualifications
            if !operative.qualifications.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Qualifications")
                        .font(.caption)
                        .fontWeight(.medium)
                        .foregroundColor(.secondary)
                    
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 2), spacing: 4) {
                        ForEach(Array(operative.qualifications.prefix(4)), id: \.id) { qualification in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(qualification.name)
                                    .font(.caption)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Color(.systemGray5))
                                    .cornerRadius(4)
                                
                                if qualification.hasEndDate, let endDate = qualification.endDate {
                                    Text("Expires: \(endDate, style: .date)")
                                        .font(.caption2)
                                        .foregroundColor(.orange)
                                }
                            }
                        }
                        
                        if operative.qualifications.count > 4 {
                            Text("+\(operative.qualifications.count - 4) more")
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color(.systemGray5))
                                .cornerRadius(4)
                        }
                    }
                }
            }
        }
        .padding()
        .background(Color(.systemBackground))
        .cornerRadius(12)
        .shadow(color: .black.opacity(0.1), radius: 2, x: 0, y: 1)
    }
}

struct AddOperativeView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var operativeStore: OperativeStore
    
    @State private var firstName = ""
    @State private var lastName = ""
    @State private var email = ""
    @State private var phone = ""
    @State private var startDate = Date()
    @State private var selectedSkills: Set<String> = []
    @State private var selectedQualifications: Set<Qualification> = []
    @State private var hourlyRate = ""
    @State private var notes = ""
    
    var body: some View {
        NavigationView {
            Form {
                Section("Personal Information") {
                    TextField("First Name", text: $firstName)
                    TextField("Last Name", text: $lastName)
                    TextField("Email", text: $email)
                        .keyboardType(.emailAddress)
                        .autocapitalization(.none)
                    TextField("Phone", text: $phone)
                        .keyboardType(.phonePad)
                    DatePicker("Start Date", selection: $startDate, displayedComponents: .date)
                }
                
                Section("Skills") {
                    if operativeStore.skills.isEmpty {
                        Text("No skills added yet.")
                            .foregroundColor(.secondary)
                            .font(.subheadline)
                    } else {
                        ForEach(Array(operativeStore.skills.sorted()), id: \.self) { skill in
                            HStack {
                                Text(skill)
                                Spacer()
                                if selectedSkills.contains(skill) {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundColor(.blue)
                                }
                            }
                            .contentShape(Rectangle())
                            .onTapGesture {
                                if selectedSkills.contains(skill) {
                                    selectedSkills.remove(skill)
                                } else {
                                    selectedSkills.insert(skill)
                                }
                            }
                        }
                    }
                }
                
                Section("Qualifications") {
                    if operativeStore.qualifications.isEmpty {
                        Text("No qualifications added yet.")
                            .foregroundColor(.secondary)
                            .font(.subheadline)
                    } else {
                        ForEach(operativeStore.qualifications, id: \.id) { qualification in
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(qualification.name)
                                        .font(.body)
                                    
                                    if qualification.hasEndDate, let endDate = qualification.endDate {
                                        Text("Expires: \(endDate, style: .date)")
                                            .font(.caption)
                                            .foregroundColor(.orange)
                                    } else {
                                        Text("No expiration")
                                            .font(.caption)
                                            .foregroundColor(.green)
                                    }
                                }
                                
                                Spacer()
                                
                                if selectedQualifications.contains(qualification) {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundColor(.blue)
                                }
                            }
                            .contentShape(Rectangle())
                            .onTapGesture {
                                if selectedQualifications.contains(qualification) {
                                    selectedQualifications.remove(qualification)
                                } else {
                                    selectedQualifications.insert(qualification)
                                }
                            }
                        }
                    }
                }
                
                Section("Additional Info") {
                    TextField("Day Rate (e.g., £45, $50)", text: $hourlyRate)
                    TextField("Notes", text: $notes, axis: .vertical)
                        .lineLimit(3...6)
                }
            }
            .navigationTitle("Add Operative")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
                
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Save") {
                        saveOperative()
                    }
                    .disabled(!isFormValid)
                }
            }
        }
    }
    
    private var isFormValid: Bool {
        !firstName.isEmpty && !lastName.isEmpty && !email.isEmpty
    }
    
    private func saveOperative() {
        // Parse the hourly rate, preserving currency symbols
        let parsedRate = parseCurrencyAmount(hourlyRate)
        
        let operative = Operative(
            firstName: firstName.trimmingCharacters(in: .whitespaces),
            lastName: lastName.trimmingCharacters(in: .whitespaces),
            email: email.trimmingCharacters(in: .whitespaces),
            phone: phone.isEmpty ? nil : phone.trimmingCharacters(in: .whitespaces),
            startDate: startDate,
            skills: selectedSkills,
            qualifications: Array(selectedQualifications),
            hourlyRate: parsedRate.amount,
            dayRate: parsedRate.amount,
            currencySymbol: parsedRate.symbol
        )
        
        Task {
            await operativeStore.addOperative(operative)
            await MainActor.run {
                dismiss()
            }
        }
    }
    
    private func parseCurrencyAmount(_ input: String) -> (amount: Double?, symbol: String?) {
        if input.isEmpty { return (nil, nil) }
        
        // Extract currency symbol
        let currencyPattern = "[£$€¥₹₽₩₪₫₨₴₸₺₼₾₿]"
        let regex = try! NSRegularExpression(pattern: currencyPattern)
        let range = NSRange(location: 0, length: input.utf16.count)
        let matches = regex.matches(in: input, range: range)
        
        var currencySymbol: String?
        if let match = matches.first, let symbolRange = Range(match.range, in: input) {
            currencySymbol = String(input[symbolRange])
        }
        
        // Remove currency symbols and extract the number
        let cleanedInput = input.replacingOccurrences(of: currencyPattern, with: "", options: .regularExpression)
            .replacingOccurrences(of: ",", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        
        return (Double(cleanedInput), currencySymbol ?? defaultCurrencySymbol())
    }
}

struct EditOperativeView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var operativeStore: OperativeStore
    @EnvironmentObject var bookingStore: BookingStore
    let operative: Operative
    
    @State private var firstName: String
    @State private var lastName: String
    @State private var email: String
    @State private var phone: String
    @State private var startDate: Date
    @State private var selectedSkills: Set<String>
    @State private var selectedQualifications: Set<Qualification>
    @State private var dayRate: String
    @State private var notes: String
    @State private var isActive: Bool
    @State private var showingDeleteConfirmation = false
    
    init(operative: Operative) {
        self.operative = operative
        self._firstName = State(initialValue: operative.firstName)
        self._lastName = State(initialValue: operative.lastName)
        self._email = State(initialValue: operative.email)
        self._phone = State(initialValue: operative.phone ?? "")
        self._startDate = State(initialValue: operative.startDate)
        self._selectedSkills = State(initialValue: operative.skills)
        self._selectedQualifications = State(initialValue: operative.qualifications)
        self._dayRate = State(initialValue: {
            let amount = operative.dayRate ?? operative.hourlyRate
            guard let amount else { return "" }
            let symbol = operative.currencySymbol ?? defaultCurrencySymbol()
            return "\(symbol)\(String(format: "%.0f", amount))"
        }())
        self._notes = State(initialValue: operative.notes ?? "")
        self._isActive = State(initialValue: operative.isActive)
        
        print("🔥🔥🔥 DEBUG: EditOperativeView initialized for operative: \(operative.name)")
        print("🔥🔥🔥 DEBUG: Operative skills: \(operative.skills)")
        print("🔥🔥🔥 DEBUG: Operative qualifications: \(operative.qualifications)")
    }
    
    var body: some View {
        let _ = print("🔥🔥🔥 DEBUG: EditOperativeView body called - skills count: \(operativeStore.skills.count), qualifications count: \(operativeStore.qualifications.count)")
        let _ = print("🔥🔥🔥 DEBUG: EditOperativeView - operative name: \(operative.name)")
        let _ = print("🔥🔥🔥 DEBUG: EditOperativeView - operative email: \(operative.email)")
        
        NavigationView {
            VStack {
                Text("Edit Operative: \(operative.name)")
                    .font(.headline)
                    .padding()
                
                Text("Skills: \(operativeStore.skills.count), Qualifications: \(operativeStore.qualifications.count)")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .padding(.bottom)
                
                Text("Debug: View is rendering")
                    .font(.caption)
                    .foregroundColor(.blue)
                    .padding(.bottom)
                
                Form {
                    Section("Personal Information") {
                        TextField("First Name", text: $firstName)
                        TextField("Last Name", text: $lastName)
                        TextField("Email", text: $email)
                            .keyboardType(.emailAddress)
                            .autocapitalization(.none)
                        TextField("Phone", text: $phone)
                            .keyboardType(.phonePad)
                        DatePicker("Start Date", selection: $startDate, displayedComponents: .date)
                        Toggle("Active", isOn: $isActive)
                    }
                
                Section("Skills") {
                    if operativeStore.skills.isEmpty {
                        Text("No skills added yet.")
                            .foregroundColor(.secondary)
                            .font(.subheadline)
                    } else {
                        ForEach(Array(operativeStore.skills.sorted()), id: \.self) { skill in
                            HStack {
                                Text(skill)
                                Spacer()
                                if selectedSkills.contains(skill) {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundColor(.blue)
                                }
                            }
                            .contentShape(Rectangle())
                            .onTapGesture {
                                if selectedSkills.contains(skill) {
                                    selectedSkills.remove(skill)
                                } else {
                                    selectedSkills.insert(skill)
                                }
                            }
                        }
                    }
                }
                
                Section("Qualifications") {
                    if operativeStore.qualifications.isEmpty {
                        Text("No qualifications added yet.")
                            .foregroundColor(.secondary)
                            .font(.subheadline)
                    } else {
                        ForEach(operativeStore.qualifications, id: \.id) { qualification in
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(qualification.name)
                                        .font(.body)
                                    
                                    if qualification.hasEndDate, let endDate = qualification.endDate {
                                        Text("Expires: \(endDate, style: .date)")
                                            .font(.caption)
                                            .foregroundColor(.orange)
                                    } else {
                                        Text("No expiration")
                                            .font(.caption)
                                            .foregroundColor(.green)
                                    }
                                }
                                
                                Spacer()
                                
                                if selectedQualifications.contains(qualification) {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundColor(.blue)
                                }
                            }
                            .contentShape(Rectangle())
                            .onTapGesture {
                                if selectedQualifications.contains(qualification) {
                                    selectedQualifications.remove(qualification)
                                } else {
                                    selectedQualifications.insert(qualification)
                                }
                            }
                        }
                    }
                }
                
                Section("Additional Info") {
                    TextField("Day Rate (e.g., £45, $50)", text: $dayRate)
                    TextField("Notes", text: $notes, axis: .vertical)
                        .lineLimit(3...6)
                }
                
                Section {
                    Button("Delete Operative") {
                        showingDeleteConfirmation = true
                    }
                    .foregroundColor(.red)
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(Color.red.opacity(0.1))
                    .cornerRadius(10)
                    .disabled(false) // Delete button is always enabled
                }
                }
            }
            .navigationTitle("Edit Operative")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
                
                        ToolbarItem(placement: .navigationBarTrailing) {
                            Button("Save") {
                                updateOperative()
                            }
                            .disabled(!isFormValid)
                        }
            }
        }
        .alert("Delete Operative", isPresented: $showingDeleteConfirmation) {
            Button("Cancel", role: .cancel) { }
            Button("Delete", role: .destructive) {
                Task {
                    await operativeStore.deleteOperative(operative, bookingStore: bookingStore)
                    await MainActor.run {
                        dismiss()
                    }
                }
            }
        } message: {
            let bookingCount = bookingStore.bookings.filter { $0.operativeId == operative.id }.count
            if bookingCount > 0 {
                Text("Are you sure you want to delete \(operative.name)?\n\nThis will also delete \(bookingCount) booking\(bookingCount == 1 ? "" : "s") associated with this operative.\n\nThis action cannot be undone.")
            } else {
                Text("Are you sure you want to delete \(operative.name)? This action cannot be undone.")
            }
        }
    }
    
    private var isFormValid: Bool {
        !firstName.isEmpty && !lastName.isEmpty && !email.isEmpty
    }
    
    private func updateOperative() {
        // Parse the hourly rate, preserving currency symbols
        let parsedRate = parseCurrencyAmount(dayRate)
        
        var updatedOperative = operative
        updatedOperative.firstName = firstName.trimmingCharacters(in: .whitespaces)
        updatedOperative.lastName = lastName.trimmingCharacters(in: .whitespaces)
        updatedOperative.email = email.trimmingCharacters(in: .whitespaces)
        updatedOperative.phone = phone.isEmpty ? nil : phone.trimmingCharacters(in: .whitespaces)
        updatedOperative.startDate = startDate
        updatedOperative.skills = selectedSkills
        updatedOperative.qualifications = selectedQualifications
        updatedOperative.dayRate = parsedRate.amount
        updatedOperative.hourlyRate = parsedRate.amount
        updatedOperative.currencySymbol = parsedRate.symbol
        updatedOperative.notes = notes.isEmpty ? nil : notes
        updatedOperative.isActive = isActive
        updatedOperative.updatedAt = Date()
        
        Task {
            await operativeStore.updateOperative(updatedOperative)
            await MainActor.run {
                dismiss()
            }
        }
    }
    
    private func parseCurrencyAmount(_ input: String) -> (amount: Double?, symbol: String?) {
        if input.isEmpty { return (nil, nil) }
        
        // Extract currency symbol
        let currencyPattern = "[£$€¥₹₽₩₪₫₨₴₸₺₼₾₿]"
        let regex = try! NSRegularExpression(pattern: currencyPattern)
        let range = NSRange(location: 0, length: input.utf16.count)
        let matches = regex.matches(in: input, range: range)
        
        var currencySymbol: String?
        if let match = matches.first, let symbolRange = Range(match.range, in: input) {
            currencySymbol = String(input[symbolRange])
        }
        
        // Remove currency symbols and extract the number
        let cleanedInput = input.replacingOccurrences(of: currencyPattern, with: "", options: .regularExpression)
            .replacingOccurrences(of: ",", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        
        return (Double(cleanedInput), currencySymbol ?? defaultCurrencySymbol())
    }
    
    private func formatCurrencyDisplay(amount: Double?, symbol: String?) -> String {
        guard let amount = amount else { return "" }
        let symbol = symbol ?? defaultCurrencySymbol()
        return "\(symbol)\(String(format: "%.0f", amount))"
    }
}

// MARK: - Finish Operative Setup View

struct FinishOperativeSetupView: View {
    @EnvironmentObject var operativeStore: OperativeStore
    @EnvironmentObject var userStore: UserStore
    @Environment(\.dismiss) private var dismiss
    
    private var incompleteOperatives: [Operative] {
        operativeStore.allOperatives.filter { operative in
            // An operative is incomplete if they're missing required fields:
            // - startDate is in the future (not set properly) OR
            // - hourlyRate is nil OR
            // - isActive is false (needs to be set)
            let hasStartDate = operative.startDate <= Date()
            let hasDayRate = operative.hourlyRate != nil
            let isActiveSet = operative.isActive
            
            return !hasStartDate || !hasDayRate || !isActiveSet
        }
    }
    
    var body: some View {
        NavigationView {
            List {
                ForEach(incompleteOperatives) { operative in
                    NavigationLink(destination: EditOperativeView(operative: operative)
                        .environmentObject(operativeStore)) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(operative.name)
                                .font(.headline)
                            
                            Text(operative.email)
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                            
                            // Highlight missing fields
                            VStack(alignment: .leading, spacing: 4) {
                                if operative.startDate > Date() {
                                    Label("Start date required", systemImage: "exclamationmark.circle.fill")
                                        .font(.caption)
                                        .foregroundColor(.red)
                                }
                                if operative.hourlyRate == nil {
                                    Label("Day rate required", systemImage: "exclamationmark.circle.fill")
                                        .font(.caption)
                                        .foregroundColor(.red)
                                }
                                if !operative.isActive {
                                    Label("Set as Active", systemImage: "exclamationmark.circle.fill")
                                        .font(.caption)
                                        .foregroundColor(.red)
                                }
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }
            }
            .navigationTitle("Finish Operative Setup")
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

// MARK: - Filter Options View

struct FilterOptionsView: View {
    @Binding var selectedFilter: OperativesView.FilterType
    @Binding var filterText: String
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        NavigationView {
            Form {
                Section("Filter By") {
                    Picker("Filter Type", selection: $selectedFilter) {
                        ForEach(OperativesView.FilterType.allCases, id: \.self) { type in
                            Text(type.rawValue).tag(type)
                        }
                    }
                }
                
                Section("Search") {
                    TextField("Enter search term", text: $filterText)
                }
            }
            .navigationTitle("Filter Operatives")
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

// MARK: - Tab Button

struct OperativeTabButton: View {
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

// MARK: - Pending User Row View

struct PendingUserRowView: View {
    let user: AppUser
    let onTap: () -> Void
    
    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 12) {
                // Avatar
                Circle()
                    .fill(Color.orange)
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
                        Text("Pending")
                            .font(.caption)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Color.orange.opacity(0.2))
                            .foregroundColor(.orange)
                            .cornerRadius(8)
                    }
                }
                
                Spacer()
                
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding(.vertical, 8)
        }
        .buttonStyle(PlainButtonStyle())
    }
}

#Preview("Operatives View") {
    OperativesView()
        .environmentObject(OperativeStore())
        .environmentObject(UserStore())
}
