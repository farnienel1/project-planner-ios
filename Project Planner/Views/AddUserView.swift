//
//  AddUserView.swift
//  Project Planner
//
//  Created by Assistant on 24/10/2025.
//

import SwiftUI

struct AddUserView: View {
    @EnvironmentObject var userStore: UserStore
    @Environment(\.dismiss) private var dismiss

    enum AddUserMode {
        case admin
        case managerAddingOperative
    }
    
    let mode: AddUserMode
    
    @State private var currentStep = 1
    @State private var firstName = ""
    @State private var surname = ""
    @State private var email = ""
    @State private var mobileNumber = ""
    @State private var permissions = UserPermissions()
    @State private var isCreating = false
    @State private var showSuccess = false
    @State private var errorMessage: String?
    
    private let totalSteps = 4
    
    init(mode: AddUserMode = .admin) {
        self.mode = mode
    }
    
    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                // Progress Slider
                progressSlider
                
                // Content
                if showSuccess {
                    successView
                } else {
                    stepContent
                }
                
                // Error Message
                if let errorMessage = errorMessage {
                    Text(errorMessage)
                        .foregroundColor(.red)
                        .padding()
                }
            }
            .navigationTitle(mode == .managerAddingOperative ? "Add Operative" : "Add New User")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
            }
        }
    }
    
    // MARK: - Progress Slider
    
    private var progressSlider: some View {
        VStack(spacing: 16) {
            HStack {
                ForEach(1...totalSteps, id: \.self) { step in
                    Circle()
                        .fill(step <= currentStep ? Color.indigo : Color.gray.opacity(0.3))
                        .frame(width: 12, height: 12)
                    
                    if step < totalSteps {
                        Rectangle()
                            .fill(step < currentStep ? Color.indigo : Color.gray.opacity(0.3))
                            .frame(height: 2)
                    }
                }
            }
            .padding(.horizontal, 40)
            
            Text(stepTitle)
                .font(.headline)
                .foregroundColor(.primary)
        }
        .padding(.vertical, 20)
        .background(Color(.systemGroupedBackground))
    }
    
    private var stepTitle: String {
        switch currentStep {
        case 1: return "User Details"
        case 2: return mode == .managerAddingOperative ? "Operative" : "Permissions"
        case 3: return "Review"
        case 4: return "Success"
        default: return ""
        }
    }
    
    // MARK: - Step Content
    
    @ViewBuilder
    private var stepContent: some View {
        ScrollView {
            VStack(spacing: 24) {
                switch currentStep {
                case 1:
                    step1View
                case 2:
                    step2View
                case 3:
                    step3View
                default:
                    EmptyView()
                }
            }
            .padding(20)
        }
        
        // Navigation Buttons
        VStack(spacing: 12) {
            Divider()
            
            HStack {
                if currentStep > 1 {
                    Button("Back") {
                        withAnimation {
                            currentStep -= 1
                        }
                    }
                    .foregroundColor(.indigo)
                }
                
                Spacer()
                
                Button(currentStep == 3 ? (isCreating ? "Creating..." : "Create User") : "Next") {
                    print("🔥🔥🔥 DEBUG: Button tapped - currentStep: \(currentStep), totalSteps: \(totalSteps)")
                    print("🔥🔥🔥 DEBUG: canProceed: \(canProceed)")
                    if currentStep == 3 {
                        print("🔥🔥🔥 DEBUG: Calling createUser()")
                        createUser()
                    } else {
                        print("🔥🔥🔥 DEBUG: Moving to next step")
                        withAnimation {
                            currentStep += 1
                        }
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(.indigo)
                .disabled(!canProceed || isCreating)
                .opacity((canProceed && !isCreating) ? 1.0 : 0.5)
                .onChange(of: isCreating) { oldValue, newValue in
                    if !newValue && errorMessage == nil && !showSuccess {
                        // Reset if creation failed silently
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
        }
        .background(Color(.systemBackground))
    }
    
    // MARK: - Step 1: User Details
    
    private var step1View: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Enter the user's basic information")
                .font(.subheadline)
                .foregroundColor(.secondary)
            
            VStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("First Name")
                        .font(.headline)
                    TextField("Enter first name", text: $firstName)
                        .textFieldStyle(RoundedBorderTextFieldStyle())
                }
                
                VStack(alignment: .leading, spacing: 8) {
                    Text("Surname")
                        .font(.headline)
                    TextField("Enter surname", text: $surname)
                        .textFieldStyle(RoundedBorderTextFieldStyle())
                }
                
                VStack(alignment: .leading, spacing: 8) {
                    Text("Email Address")
                        .font(.headline)
                    TextField("Enter email address", text: $email)
                        .textFieldStyle(RoundedBorderTextFieldStyle())
                        .keyboardType(.emailAddress)
                        .autocapitalization(.none)
                }
                
                VStack(alignment: .leading, spacing: 8) {
                    Text("Mobile Number")
                        .font(.headline)
                    TextField("Enter mobile number", text: $mobileNumber)
                        .textFieldStyle(RoundedBorderTextFieldStyle())
                        .keyboardType(.phonePad)
                }
            }
        }
    }
    
    // MARK: - Step 2: Permissions
    
    private var step2View: some View {
        VStack(alignment: .leading, spacing: 20) {
            if mode == .managerAddingOperative {
                Text("Managers can only add operatives.")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            } else {
                Text("Select what this user can access")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
            
            VStack(spacing: 16) {
                if mode == .managerAddingOperative {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Image(systemName: "person.fill")
                                .foregroundColor(.indigo)
                            Text("Operative Mode")
                                .font(.headline)
                        }
                        Text("This user will be added as an operative with a limited view of the app.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
                    .background(Color.indigo.opacity(0.08))
                    .cornerRadius(12)
                    .onAppear {
                        permissions.operativeMode = true
                        permissions.adminAccess = false
                        permissions.manager = false
                        permissions.operatives = false
                        permissions.projects = true
                        permissions.smallWorks = true
                    }
                } else {
                PermissionToggle(
                    title: "Admin Access",
                    description: "Can add and manage users.",
                    isOn: $permissions.adminAccess,
                    isDisabled: permissions.operativeMode
                )
                .onChange(of: permissions.adminAccess) { oldValue, newValue in
                    if newValue && permissions.operativeMode {
                        errorMessage = "Operative mode does not allow users to access the above features. Please deselect operative mode to continue with the above features."
                        permissions.adminAccess = false
                    } else if newValue {
                        // Admins are automatically managers and get projects/small works permissions
                        permissions.manager = true
                        permissions.projects = true
                        permissions.smallWorks = true
                    }
                }
                
                PermissionToggle(
                    title: "Manager",
                    description: "Managers will be able to schedule operatives, create new clients, skills, and qualifications, view warnings and manage tasks.",
                    isOn: $permissions.manager,
                    isDisabled: permissions.operativeMode || permissions.adminAccess
                )
                .onChange(of: permissions.manager) { oldValue, newValue in
                    if newValue && permissions.operativeMode {
                        errorMessage = "Operative mode does not allow users to access the above features. Please deselect operative mode to continue with the above features."
                        permissions.manager = false
                    } else if newValue {
                        // Managers automatically get projects and small works permissions
                        permissions.projects = true
                        permissions.smallWorks = true
                    }
                }
                
                PermissionToggle(
                    title: "Projects",
                    description: "Can create and manage projects.",
                    isOn: $permissions.projects,
                    isDisabled: permissions.operativeMode || (!permissions.manager && !permissions.adminAccess)
                )
                .onChange(of: permissions.projects) { oldValue, newValue in
                    if newValue && permissions.operativeMode {
                        errorMessage = "Operative mode does not allow users to access the above features. Please deselect operative mode to continue with the above features."
                        permissions.projects = false
                    }
                }
                
                PermissionToggle(
                    title: "Small Works",
                    description: "Can create and manage small works.",
                    isOn: $permissions.smallWorks,
                    isDisabled: permissions.operativeMode || (!permissions.manager && !permissions.adminAccess)
                )
                .onChange(of: permissions.smallWorks) { oldValue, newValue in
                    if newValue && permissions.operativeMode {
                        errorMessage = "Operative mode does not allow users to access the above features. Please deselect operative mode to continue with the above features."
                        permissions.smallWorks = false
                    }
                }
                
                PermissionToggle(
                    title: "Operative Management",
                    description: "Can manage operatives and view their details. If un-selected the user will only be able to assign operatives to projects and small works.",
                    isOn: $permissions.operatives,
                    isDisabled: permissions.operativeMode
                )
                .onChange(of: permissions.operatives) { oldValue, newValue in
                    if newValue && permissions.operativeMode {
                        errorMessage = "Operative mode does not allow users to access the above features. Please deselect operative mode to continue with the above features."
                        permissions.operatives = false
                    }
                }
                
                Divider()
                    .padding(.vertical, 8)
                
                PermissionToggle(
                    title: "Operative Mode",
                    description: "Limited view mode for operatives. They can only see projects/small works assigned to them, their tasks, as well as their tasks.\n\nOperative skills and qualifications can be added with the manage operatives page later on.",
                    isOn: $permissions.operativeMode
                )
                .onChange(of: permissions.operativeMode) { oldValue, newValue in
                    if newValue {
                        // If operative mode is enabled, disable all other permissions
                        permissions.adminAccess = false
                        permissions.manager = false
                        permissions.operatives = false
                        // Clear error message when operative mode is selected
                        errorMessage = nil
                    } else {
                        // Clear error message when operative mode is deselected
                        errorMessage = nil
                    }
                }
                }
            }
        }
    }
    
    // MARK: - Step 3: Review
    
    private var step3View: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Review user details before creating")
                .font(.subheadline)
                .foregroundColor(.secondary)
            
            VStack(spacing: 16) {
                // User Details
                VStack(alignment: .leading, spacing: 12) {
                    Text("User Details")
                        .font(.headline)
                    
                    HStack {
                        Text("Name:")
                            .foregroundColor(.secondary)
                        Spacer()
                        Text("\(firstName) \(surname)")
                            .fontWeight(.medium)
                    }
                    
                    HStack {
                        Text("Email:")
                            .foregroundColor(.secondary)
                        Spacer()
                        Text(email)
                            .fontWeight(.medium)
                    }
                    
                    if !mobileNumber.isEmpty {
                        HStack {
                            Text("Mobile:")
                                .foregroundColor(.secondary)
                            Spacer()
                            Text(mobileNumber)
                                .fontWeight(.medium)
                        }
                    }
                }
                .padding()
                .background(Color(.systemGray6))
                .cornerRadius(12)
                
                // Permissions
                VStack(alignment: .leading, spacing: 12) {
                    Text("Permissions")
                        .font(.headline)
                    
                    LazyVGrid(columns: [
                        GridItem(.flexible()),
                        GridItem(.flexible())
                    ], spacing: 8) {
                        ForEach(permissionItems, id: \.title) { item in
                            HStack {
                                Image(systemName: item.isEnabled ? "checkmark.circle.fill" : "xmark.circle")
                                    .foregroundColor(item.isEnabled ? .green : .red)
                                Text(item.title)
                                    .font(.caption)
                            }
                        }
                    }
                }
                .padding()
                .background(Color(.systemGray6))
                .cornerRadius(12)
            }
        }
    }
    
    // MARK: - Success View
    
    private var successView: some View {
        VStack(spacing: 24) {
            Spacer()
            
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 80))
                .foregroundColor(.green)
            
            VStack(spacing: 8) {
                Text("User Created Successfully!")
                    .font(.title2)
                    .fontWeight(.bold)
                
                Text("An invitation email has been sent to \(email)")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            }
            
            Spacer()
            
            Button("Done") {
                dismiss()
            }
            .buttonStyle(.borderedProminent)
            .tint(.indigo)
        }
        .padding(20)
    }
    
    // MARK: - Helper Properties
    
    private var canProceed: Bool {
        let result: Bool
        switch currentStep {
        case 1:
            result = !firstName.isEmpty && !surname.isEmpty && !email.isEmpty && isValidEmail(email)
            print("🔥🔥🔥 DEBUG: Step 1 validation - firstName: '\(firstName)', surname: '\(surname)', email: '\(email)', isValidEmail: \(isValidEmail(email)), result: \(result)")
        case 2:
            result = true // At least one permission should be selected, but we'll allow all false for now
            print("🔥🔥🔥 DEBUG: Step 2 validation - result: \(result)")
        case 3:
            result = true
            print("🔥🔥🔥 DEBUG: Step 3 validation - result: \(result)")
        default:
            result = false
            print("🔥🔥🔥 DEBUG: Default validation - result: \(result)")
        }
        return result
    }
    
    private var permissionItems: [(title: String, isEnabled: Bool)] {
        [
            ("Admin Access", permissions.adminAccess),
            ("Manager", permissions.manager),
            ("Operative Management", permissions.operatives),
            ("Operative Mode", permissions.operativeMode)
        ]
    }
    
    // MARK: - Actions
    
    private func createUser() {
        print("🔥🔥🔥 DEBUG: Create User button tapped")
        print("🔥🔥🔥 DEBUG: First Name: \(firstName)")
        print("🔥🔥🔥 DEBUG: Surname: \(surname)")
        print("🔥🔥🔥 DEBUG: Email: \(email)")
        print("🔥🔥🔥 DEBUG: Permissions: \(permissions)")
        
        // Validate permissions - operative mode cannot be combined with other permissions
        if permissions.operativeMode && (permissions.adminAccess || permissions.manager || permissions.operatives) {
            errorMessage = "Operative mode does not allow users to access the above features. Please deselect operative mode to continue with the above features."
            return
        }
        
        guard !isCreating else {
            print("🔥🔥🔥 DEBUG: Already creating user, ignoring duplicate request")
            return
        }
        
        isCreating = true
        errorMessage = nil
        
        Task {
            print("🔥🔥🔥 DEBUG: Calling userStore.inviteUser")
            
            // Check if organization is available via userStore's firebaseBackend
            // We'll check this in the inviteUser function itself
            
            let success = await userStore.inviteUser(
                firstName: firstName,
                surname: surname,
                email: email,
                mobileNumber: mobileNumber.isEmpty ? nil : mobileNumber,
                permissions: permissions
            )
            
            print("🔥🔥🔥 DEBUG: inviteUser returned: \(success)")
            
            await MainActor.run {
                isCreating = false
                if success {
                    print("🔥🔥🔥 DEBUG: Success! Showing success view")
                    withAnimation {
                        showSuccess = true
                    }
                } else {
                    print("🔥🔥🔥 DEBUG: Failed to create user")
                    // Get more specific error message from userStore if available
                    if let storeError = userStore.errorMessage {
                        errorMessage = storeError
                    } else {
                        errorMessage = "Failed to create user. Please check your internet connection and try again."
                    }
                }
            }
        }
    }
    
    private func isValidEmail(_ email: String) -> Bool {
        let emailRegex = "[A-Z0-9a-z._%+-]+@[A-Za-z0-9.-]+\\.[A-Za-z]{2,64}"
        let emailPredicate = NSPredicate(format: "SELF MATCHES %@", emailRegex)
        return emailPredicate.evaluate(with: email)
    }
}

// MARK: - Permission Toggle Component

struct PermissionToggle: View {
    let title: String
    let description: String
    @Binding var isOn: Bool
    var isDisabled: Bool = false
    
    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.headline)
                    .foregroundColor(isDisabled ? .secondary : .primary)
                Text(description)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            
            Spacer()
            
            Toggle("", isOn: $isOn)
                .tint(.indigo)
                .disabled(isDisabled)
        }
        .padding()
        .background(isDisabled ? Color(.systemGray5) : Color(.systemGray6))
        .cornerRadius(12)
        .opacity(isDisabled ? 0.6 : 1.0)
    }
}

#Preview {
    AddUserView()
        .environmentObject(UserStore())
}
