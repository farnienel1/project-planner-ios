//
//  FixPermissionsView.swift
//  Project Planner
//
//  Created to help fix Firestore permission issues
//

import SwiftUI
import FirebaseFirestore
import FirebaseAuth

struct FixPermissionsView: View {
    @EnvironmentObject var firebaseBackend: FirebaseBackend
    @EnvironmentObject var userStore: UserStore
    @Environment(\.dismiss) private var dismiss
    
    @State private var isChecking = false
    @State private var isFixing = false
    @State private var isTestingRules = false
    @State private var statusMessage = ""
    @State private var currentUserData: [String: Any] = [:]
    @State private var showingFixConfirmation = false
    
    var body: some View {
        NavigationView {
            Form {
                Section("Current User Permissions") {
                    if isChecking {
                        HStack {
                            ProgressView()
                            Text("Checking permissions...")
                        }
                    } else if !currentUserData.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("User ID: \(firebaseBackend.currentUser?.uid ?? "N/A")")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            
                            Divider()
                            
                            PermissionRow(
                                title: "isSuperAdmin",
                                value: currentUserData["isSuperAdmin"],
                                expectedType: "Boolean"
                            )
                            
                            PermissionRow(
                                title: "adminAccess",
                                value: currentUserData["adminAccess"],
                                expectedType: "Boolean"
                            )
                            
                            PermissionRow(
                                title: "role",
                                value: currentUserData["role"],
                                expectedType: "String"
                            )
                            
                            if hasPermissionIssue {
                                Text("⚠️ Permission Issue Detected")
                                    .foregroundColor(.red)
                                    .font(.headline)
                                    .padding(.top, 8)
                                
                                Text("One or more permission fields have incorrect types. This will cause Firestore rules to fail.")
                                    .font(.caption)
                                    .foregroundColor(.red)
                            } else if hasAdminPermissions {
                                Text("✅ Admin Permissions Detected")
                                    .foregroundColor(.green)
                                    .font(.headline)
                                    .padding(.top, 8)
                                
                                Text("Your user has admin permissions. If you still get permission errors, the Firestore rules may not be deployed.")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            } else {
                                Text("❌ No Admin Permissions")
                                    .foregroundColor(.red)
                                    .font(.headline)
                                    .padding(.top, 8)
                                
                                Text("Your user does not have admin permissions. Click 'Fix Permissions' to grant admin access.")
                                    .font(.caption)
                                    .foregroundColor(.red)
                            }
                        }
                    }
                    
                    Button(action: {
                        Task {
                            await checkPermissions()
                        }
                    }) {
                        HStack {
                            Text("Check Permissions")
                            Spacer()
                            if isChecking {
                                ProgressView()
                            }
                        }
                    }
                    .disabled(isChecking)
                }
                
                if hasPermissionIssue || !hasAdminPermissions {
                    Section("Fix Permissions") {
                        Button(action: {
                            showingFixConfirmation = true
                        }) {
                            HStack {
                                Spacer()
                                if isFixing {
                                    ProgressView()
                                    Text("Fixing...")
                                } else {
                                    Text("Fix Permissions")
                                }
                                Spacer()
                            }
                        }
                        .disabled(isFixing || isChecking)
                    }
                }
                
                Section("Test Firestore Rules") {
                    Button(action: {
                        Task {
                            await testRules()
                        }
                    }) {
                        HStack {
                            Text("Test Rules Deployment")
                            Spacer()
                            if isTestingRules {
                                ProgressView()
                            }
                        }
                    }
                    .disabled(isTestingRules || isChecking)
                }
                
                Section("Instructions") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("1. Click 'Check Permissions' to see your current permissions")
                        Text("2. If permissions are wrong, click 'Fix Permissions'")
                        Text("3. Verify Firestore rules are deployed in Firebase Console")
                        Text("4. Wait 2-3 minutes after deploying rules")
                        Text("5. Try creating a user again")
                    }
                    .font(.caption)
                    .foregroundColor(.secondary)
                }
                
                if !statusMessage.isEmpty {
                    Section("Status") {
                        Text(statusMessage)
                            .font(.caption)
                            .foregroundColor(statusMessage.contains("✅") ? .green : .red)
                    }
                }
            }
            .navigationTitle("Fix Permissions")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
        .alert("Fix Permissions", isPresented: $showingFixConfirmation) {
            Button("Cancel", role: .cancel) { }
            Button("Fix", role: .destructive) {
                Task {
                    await fixPermissions()
                }
            }
        } message: {
            Text("This will update your user document in Firebase to grant admin permissions. This should fix the 'Permission denied' error when creating users.")
        }
        .task {
            await checkPermissions()
        }
    }
    
    private var hasPermissionIssue: Bool {
        guard !currentUserData.isEmpty else { return false }
        
        // Check if isSuperAdmin is not a boolean
        if let isSuperAdmin = currentUserData["isSuperAdmin"] {
            if !(isSuperAdmin is Bool) {
                return true
            }
        }
        
        // Check if adminAccess is not a boolean
        if let adminAccess = currentUserData["adminAccess"] {
            if !(adminAccess is Bool) {
                return true
            }
        }
        
        return false
    }
    
    private var hasAdminPermissions: Bool {
        guard !currentUserData.isEmpty else { return false }
        
        let isSuperAdmin = currentUserData["isSuperAdmin"] as? Bool ?? false
        let adminAccess = currentUserData["adminAccess"] as? Bool ?? false
        let role = currentUserData["role"] as? String ?? ""
        
        return isSuperAdmin || adminAccess || role == "admin"
    }
    
    private func checkPermissions() async {
        isChecking = true
        statusMessage = ""
        
        guard let userId = firebaseBackend.currentUser?.uid else {
            await MainActor.run {
                statusMessage = "❌ No user ID available"
                isChecking = false
            }
            return
        }
        
        do {
            let db = Firestore.firestore()
            let userDoc = try await db.collection("users").document(userId).getDocument()
            
            if let data = userDoc.data() {
                await MainActor.run {
                    currentUserData = data
                    print("🔥🔥🔥 DEBUG: [FixPermissions] User document data:")
                    print("🔥🔥🔥 DEBUG: - isSuperAdmin: \(data["isSuperAdmin"] ?? "N/A") (type: \(type(of: data["isSuperAdmin"])))")
                    print("🔥🔥🔥 DEBUG: - adminAccess: \(data["adminAccess"] ?? "N/A") (type: \(type(of: data["adminAccess"])))")
                    print("🔥🔥🔥 DEBUG: - role: \(data["role"] ?? "N/A") (type: \(type(of: data["role"])))")
                    isChecking = false
                }
            } else {
                await MainActor.run {
                    statusMessage = "❌ User document not found in Firestore"
                    isChecking = false
                }
            }
        } catch {
            await MainActor.run {
                statusMessage = "❌ Error checking permissions: \(error.localizedDescription)"
                isChecking = false
            }
        }
    }
    
    private func fixPermissions() async {
        isFixing = true
        statusMessage = ""
        
        guard let userId = firebaseBackend.currentUser?.uid else {
            await MainActor.run {
                statusMessage = "❌ No user ID available"
                isFixing = false
            }
            return
        }
        
        do {
            let db = Firestore.firestore()
            
            // Update user document with correct permissions
            try await db.collection("users").document(userId).updateData([
                "isSuperAdmin": true,
                "adminAccess": true,
                "role": "admin"
            ])
            
            print("🔥🔥🔥 DEBUG: [FixPermissions] ✅ Updated user document with admin permissions")
            
            // Reload user data
            await userStore.loadCurrentUser()
            
            // Re-check permissions
            await checkPermissions()
            
            await MainActor.run {
                statusMessage = "✅ Permissions fixed! Your user now has admin access. Try creating a user again."
                isFixing = false
            }
        } catch {
            print("🔥🔥🔥 DEBUG: [FixPermissions] ❌ Error fixing permissions: \(error)")
            await MainActor.run {
                statusMessage = "❌ Failed to fix permissions: \(error.localizedDescription)\n\nMake sure Firestore rules allow you to update your own document."
                isFixing = false
            }
        }
    }
    
    private func testRules() async {
        isTestingRules = true
        statusMessage = ""
        
        let result = await firebaseBackend.testFirestoreRules()
        
        await MainActor.run {
            statusMessage = result.message
            isTestingRules = false
        }
    }
}

struct PermissionRow: View {
    let title: String
    let value: Any?
    let expectedType: String
    
    var body: some View {
        HStack {
            Text(title)
                .font(.subheadline)
            
            Spacer()
            
            VStack(alignment: .trailing, spacing: 2) {
                if let value = value {
                    Text("\(String(describing: value))")
                        .font(.caption)
                        .foregroundColor(.primary)
                    
                    let actualType = String(describing: type(of: value))
                    let isCorrectType = (expectedType == "Boolean" && value is Bool) || 
                                       (expectedType == "String" && value is String)
                    
                    Text(actualType)
                        .font(.caption2)
                        .foregroundColor(isCorrectType ? .green : .red)
                } else {
                    Text("Not set")
                        .font(.caption)
                        .foregroundColor(.orange)
                }
            }
        }
        .padding(.vertical, 4)
    }
}

#Preview {
    FixPermissionsView()
        .environmentObject(FirebaseBackend())
        .environmentObject(UserStore())
}

