import Foundation
import SwiftUI
import Combine

// MARK: - Admin Support System for User Management

class AdminSupportSystem: ObservableObject {
    @Published var users: [AppUser] = []
    @Published var supportRequests: [SupportRequest] = []
    
    private let supportEmail = "info@projectplanner.us" // Primary support email
    
    // MARK: - User Management Functions
    
    /// Reset a user's password (Admin function)
    func resetUserPassword(email: String, newPassword: String) async -> Bool {
        // This would connect to your backend server
        // For now, we'll simulate the process
        
        print("🔧 Admin: Resetting password for \(email)")
        
        // In a real implementation, this would:
        // 1. Connect to your backend database
        // 2. Verify the admin has permission
        // 3. Hash the new password
        // 4. Update the user's password in the database
        // 5. Send confirmation email to user
        
        return true
    }
    
    /// Get all users (Admin function)
    func getAllUsers() async -> [AppUser] {
        // Connect to your backend and fetch all users
        // This would require proper authentication and admin privileges
        return []
    }
    
    /// Suspend/Activate user account
    func toggleUserAccount(email: String, isActive: Bool) async -> Bool {
        print("🔧 Admin: \(isActive ? "Activating" : "Suspending") account for \(email)")
        // Update user status in backend
        return true
    }
    
    // MARK: - Support Request Management
    
    /// Create a support request
    func createSupportRequest(userEmail: String, subject: String, message: String) async -> Bool {
        let request = SupportRequest(
            id: UUID(),
            userEmail: userEmail,
            subject: subject,
            message: message,
            status: .open,
            createdAt: Date()
        )
        
        supportRequests.append(request)
        
        // Send email to support team
        await sendSupportEmail(request: request)
        
        return true
    }
    
    /// Send support email notification
    private func sendSupportEmail(request: SupportRequest) async {
        let emailBody = """
        New Support Request
        
        From: \(request.userEmail)
        Subject: \(request.subject)
        Message: \(request.message)
        
        Request ID: \(request.id.uuidString)
        Created: \(request.createdAt)
        
        Please respond to this request within 24 hours.
        """
        
        // In a real implementation, this would use SendGrid, AWS SES, or similar
        print("📧 Support email sent to \(supportEmail)")
        print("📧 Email body: \(emailBody)")
    }
}

// MARK: - Support Request Model

struct SupportRequest: Identifiable, Codable {
    let id: UUID
    let userEmail: String
    let subject: String
    let message: String
    var status: SupportRequestStatus
    let createdAt: Date
    var respondedAt: Date?
    var response: String?
}

enum SupportRequestStatus: String, CaseIterable, Codable {
    case open = "Open"
    case inProgress = "In Progress"
    case resolved = "Resolved"
    case closed = "Closed"
}

// MARK: - Admin Dashboard View

struct AdminDashboardView: View {
    @StateObject private var adminSystem = AdminSupportSystem()
    @State private var showingUserManagement = false
    @State private var showingSupportRequests = false
    
    var body: some View {
        NavigationView {
            VStack(spacing: 20) {
                Text("Admin Dashboard")
                    .font(.largeTitle)
                    .fontWeight(.bold)
                
                VStack(spacing: 15) {
                    // User Management Section
                    AdminActionCard(
                        title: "User Management",
                        description: "Reset passwords, manage accounts",
                        icon: "person.2.fill",
                        color: .blue
                    ) {
                        showingUserManagement = true
                    }
                    
                    // Support Requests Section
                    AdminActionCard(
                        title: "Support Requests",
                        description: "View and respond to user requests",
                        icon: "envelope.fill",
                        color: .green
                    ) {
                        showingSupportRequests = true
                    }
                    
                    // System Status Section
                    AdminActionCard(
                        title: "System Status",
                        description: "Monitor app performance and usage",
                        icon: "chart.line.uptrend.xyaxis",
                        color: .orange
                    ) {
                        // Navigate to system status
                    }
                }
                .padding()
                
                Spacer()
            }
            .navigationBarHidden(true)
        }
        .sheet(isPresented: $showingUserManagement) {
            UserManagementView(adminSystem: adminSystem)
        }
        .sheet(isPresented: $showingSupportRequests) {
            SupportRequestsView(adminSystem: adminSystem)
        }
    }
}

// MARK: - Admin Action Card

struct AdminActionCard: View {
    let title: String
    let description: String
    let icon: String
    let color: Color
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            HStack {
                Image(systemName: icon)
                    .font(.title2)
                    .foregroundColor(color)
                    .frame(width: 30)
                
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.headline)
                        .foregroundColor(.primary)
                    
                    Text(description)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                
                Spacer()
                
                Image(systemName: "chevron.right")
                    .foregroundColor(.secondary)
            }
            .padding()
            .background(Color(.systemGray6))
            .cornerRadius(10)
        }
        .buttonStyle(PlainButtonStyle())
    }
}

// MARK: - User Management View

struct UserManagementView: View {
    @ObservedObject var adminSystem: AdminSupportSystem
    @State private var searchText = ""
    @State private var showingPasswordReset = false
    @State private var selectedUserEmail = ""
    @State private var newPassword = ""
    
    var filteredUsers: [AppUser] {
        if searchText.isEmpty {
            return adminSystem.users
        } else {
            return adminSystem.users.filter { $0.email.localizedCaseInsensitiveContains(searchText) }
        }
    }
    
    var body: some View {
        NavigationView {
            VStack {
                // Search Bar
                SearchBar(text: $searchText)
                
                // Users List
                List(filteredUsers) { user in
                    UserRowView(user: user) {
                        selectedUserEmail = user.email
                        showingPasswordReset = true
                    }
                }
                .listStyle(PlainListStyle())
            }
            .navigationTitle("User Management")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") {
                        // Dismiss view
                    }
                }
            }
        }
        .sheet(isPresented: $showingPasswordReset) {
            AdminPasswordResetView(
                userEmail: selectedUserEmail,
                adminSystem: adminSystem
            )
        }
    }
}

// MARK: - User Row View

struct UserRowView: View {
    let user: AppUser
    let onPasswordReset: () -> Void
    
    var body: some View {
        HStack {
            VStack(alignment: .leading) {
                Text(user.email)
                    .font(.headline)
                
                Text("Role: \(user.role.rawValue.capitalized)")
                    .font(.caption)
                    .foregroundColor(.secondary)
                
                Text("Joined: \(user.createdAt, style: .date)")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            
            Spacer()
            
            Button("Reset Password") {
                onPasswordReset()
            }
            .font(.caption)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Color.blue)
            .foregroundColor(.white)
            .cornerRadius(8)
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Password Reset View

struct AdminPasswordResetView: View {
    let userEmail: String
    @ObservedObject var adminSystem: AdminSupportSystem
    @State private var newPassword = ""
    @State private var confirmPassword = ""
    @State private var isLoading = false
    @State private var showingSuccess = false
    @Environment(\.presentationMode) var presentationMode
    
    var body: some View {
        NavigationView {
            VStack(spacing: 20) {
                Text("Reset Password")
                    .font(.title2)
                    .fontWeight(.bold)
                
                Text("Reset password for: \(userEmail)")
                    .foregroundColor(.secondary)
                
                VStack(spacing: 15) {
                    CustomSecureField(title: "New Password", text: $newPassword)
                    
                    CustomSecureField(title: "Confirm Password", text: $confirmPassword)
                }
                
                Button("Reset Password") {
                    Task {
                        await resetPassword()
                    }
                }
                .disabled(newPassword.isEmpty || newPassword != confirmPassword || isLoading)
                .padding()
                .frame(maxWidth: .infinity)
                .background(Color.blue)
                .foregroundColor(.white)
                .cornerRadius(10)
                
                Spacer()
            }
            .padding()
            .navigationTitle("Password Reset")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Cancel") {
                        presentationMode.wrappedValue.dismiss()
                    }
                }
            }
        }
        .alert("Password Reset Successful", isPresented: $showingSuccess) {
            Button("OK") {
                presentationMode.wrappedValue.dismiss()
            }
        } message: {
            Text("The password has been reset successfully. The user will receive an email notification.")
        }
    }
    
    private func resetPassword() async {
        isLoading = true
        
        let success = await adminSystem.resetUserPassword(
            email: userEmail,
            newPassword: newPassword
        )
        
        isLoading = false
        
        if success {
            showingSuccess = true
        }
    }
}

// MARK: - Support Requests View

struct SupportRequestsView: View {
    @ObservedObject var adminSystem: AdminSupportSystem
    @State private var selectedRequest: SupportRequest?
    
    var body: some View {
        NavigationView {
            List(adminSystem.supportRequests) { request in
                SupportRequestRowView(request: request) {
                    selectedRequest = request
                }
            }
            .navigationTitle("Support Requests")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") {
                        // Dismiss view
                    }
                }
            }
        }
        .sheet(item: $selectedRequest) { request in
            SupportRequestDetailView(request: request, adminSystem: adminSystem)
        }
    }
}

// MARK: - Support Request Row View

struct SupportRequestRowView: View {
    let request: SupportRequest
    let onTap: () -> Void
    
    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(request.subject)
                        .font(.headline)
                        .foregroundColor(.primary)
                    
                    Spacer()
                    
                    Text(request.status.rawValue)
                        .font(.caption)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(statusColor)
                        .foregroundColor(.white)
                        .cornerRadius(4)
                }
                
                Text("From: \(request.userEmail)")
                    .font(.caption)
                    .foregroundColor(.secondary)
                
                Text(request.message)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(2)
            }
        }
        .buttonStyle(PlainButtonStyle())
    }
    
    private var statusColor: Color {
        switch request.status {
        case .open:
            return .red
        case .inProgress:
            return .orange
        case .resolved:
            return .green
        case .closed:
            return .gray
        }
    }
}

// MARK: - Support Request Detail View

struct SupportRequestDetailView: View {
    let request: SupportRequest
    @ObservedObject var adminSystem: AdminSupportSystem
    @State private var responseText = ""
    @Environment(\.presentationMode) var presentationMode
    
    var body: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 15) {
                    Text("Subject: \(request.subject)")
                        .font(.headline)
                    
                    Text("From: \(request.userEmail)")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                    
                    Text("Message:")
                        .font(.subheadline)
                        .fontWeight(.semibold)
                    
                    Text(request.message)
                        .padding()
                        .background(Color(.systemGray6))
                        .cornerRadius(8)
                    
                    Text("Response:")
                        .font(.subheadline)
                        .fontWeight(.semibold)
                    
                    TextEditor(text: $responseText)
                        .frame(height: 100)
                        .padding()
                        .background(Color(.systemGray6))
                        .cornerRadius(8)
                }
                .padding()
            }
            .navigationTitle("Support Request")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") {
                        presentationMode.wrappedValue.dismiss()
                    }
                }
                
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Send Response") {
                        sendResponse()
                    }
                    .disabled(responseText.isEmpty)
                }
            }
        }
    }
    
    private func sendResponse() {
        // Send response to user
        // Update request status
        presentationMode.wrappedValue.dismiss()
    }
}

// MARK: - Search Bar

struct SearchBar: View {
    @Binding var text: String
    
    var body: some View {
        HStack {
            Image(systemName: "magnifyingglass")
                .foregroundColor(.secondary)
            
            TextField("Search users...", text: $text)
                .textFieldStyle(PlainTextFieldStyle())
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color(.systemGray6))
        .cornerRadius(8)
        .padding(.horizontal)
    }
}

#Preview {
    AdminDashboardView()
}
