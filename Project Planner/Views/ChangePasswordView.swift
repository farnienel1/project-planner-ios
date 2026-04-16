//
//  ChangePasswordView.swift
//  Project Planner
//
//  Created by Assistant on 29/09/2025.
//

import SwiftUI

struct ChangePasswordView: View {
    @EnvironmentObject var firebaseBackend: FirebaseBackend
    @Environment(\.presentationMode) var presentationMode
    
    @State private var currentPassword = ""
    @State private var newPassword = ""
    @State private var confirmPassword = ""
    @State private var showingSuccessMessage = false
    
    var body: some View {
        NavigationView {
            VStack(spacing: 30) {
                // Header
                VStack(spacing: 16) {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 60))
                        .foregroundColor(.blue)
                    
                    Text("Change Password")
                        .font(.largeTitle)
                        .fontWeight(.bold)
                        .foregroundColor(.blue)
                    
                    Text("Enter your current password and choose a new one.")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding(.top, 40)
                
                // Form
                VStack(spacing: 20) {
                    // Current Password
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Current Password")
                            .font(.headline)
                            .foregroundColor(.primary)
                        
                        CustomSecureField(title: "Enter your current password", text: $currentPassword)
                    }
                    
                    // New Password
                    VStack(alignment: .leading, spacing: 8) {
                        Text("New Password")
                            .font(.headline)
                            .foregroundColor(.primary)
                        
                        CustomSecureField(title: "Enter your new password", text: $newPassword)
                    }
                    
                    // Confirm New Password
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Confirm New Password")
                            .font(.headline)
                            .foregroundColor(.primary)
                        
                        CustomSecureField(title: "Confirm your new password", text: $confirmPassword)
                    }
                }
                .padding(.horizontal, 40)
                
                // Error Message
                if let errorMessage = firebaseBackend.errorMessage {
                    Text(errorMessage)
                        .foregroundColor(.red)
                        .font(.caption)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 40)
                }
                
                // Success Message
                if showingSuccessMessage {
                    Text("Password changed successfully")
                        .foregroundColor(.green)
                        .font(.caption)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 40)
                }
                
                // Change Password Button
                Button(action: changePassword) {
                    HStack {
                        if firebaseBackend.isLoading {
                            ProgressView()
                                .progressViewStyle(CircularProgressViewStyle(tint: .white))
                                .scaleEffect(0.8)
                        }
                        
                        Text("Change Password")
                            .font(.headline)
                            .foregroundColor(.white)
                    }
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(Color.blue)
                    .cornerRadius(12)
                }
                .disabled(firebaseBackend.isLoading || !isFormValid)
                .opacity(isFormValid ? 1.0 : 0.6)
                .padding(.horizontal, 40)
                
                Spacer()
            }
            .navigationBarTitleDisplayMode(.inline)
            .navigationBarItems(
                leading: Button("Cancel") {
                    presentationMode.wrappedValue.dismiss()
                }
            )
        }
    }
    
    private var isFormValid: Bool {
        return !currentPassword.isEmpty && 
               !newPassword.isEmpty && 
               newPassword == confirmPassword &&
               newPassword.count >= 6
    }
    
    private func changePassword() {
        Task {
            do {
                try await firebaseBackend.changePassword(
                    currentPassword: currentPassword,
                    newPassword: newPassword
                )
                showingSuccessMessage = true
                clearForm()
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                    presentationMode.wrappedValue.dismiss()
                }
            } catch {
                // Error is handled by firebaseBackend.errorMessage
            }
        }
    }
    
    private func clearForm() {
        currentPassword = ""
        newPassword = ""
        confirmPassword = ""
    }
}

#Preview {
    ChangePasswordView()
        .environmentObject(SimpleAuthManager())
}
