//
//  PasswordSetupView.swift
//  Project Planner
//
//  Created by Assistant on 24/10/2025.
//

import SwiftUI
import FirebaseAuth

struct PasswordSetupView: View {
    @EnvironmentObject var userStore: UserStore
    @EnvironmentObject var firebaseBackend: FirebaseBackend
    
    @State private var password = ""
    @State private var confirmPassword = ""
    @State private var isSettingUp = false
    @State private var errorMessage: String?
    @State private var showSuccess = false
    
    let invitationToken: String
    
    var body: some View {
        NavigationView {
            VStack(spacing: 24) {
                Spacer()
                
                // Header
                VStack(spacing: 16) {
                    Image(systemName: "person.badge.plus")
                        .font(.system(size: 60))
                        .foregroundColor(.indigo)
                    
                    Text("Welcome to Project Planner")
                        .font(.title)
                        .fontWeight(.bold)
                    
                    Text("Set up your password to complete your account")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                }
                
                if showSuccess {
                    successView
                } else {
                    passwordForm
                }
                
                Spacer()
            }
            .padding(20)
            .navigationBarHidden(true)
        }
    }
    
    // MARK: - Password Form
    
    private var passwordForm: some View {
        VStack(spacing: 20) {
            VStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Password")
                        .font(.headline)
                    CustomSecureField(title: "Enter your password", text: $password)
                }
                
                VStack(alignment: .leading, spacing: 8) {
                    Text("Confirm Password")
                        .font(.headline)
                    CustomSecureField(title: "Confirm your password", text: $confirmPassword)
                }
            }
            
            if let errorMessage = errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundColor(.red)
                    .multilineTextAlignment(.center)
            }
            
            Button("Set Up Password") {
                setupPassword()
            }
            .buttonStyle(.borderedProminent)
            .tint(.indigo)
            .disabled(!canProceed || isSettingUp)
        }
    }
    
    // MARK: - Success View
    
    private var successView: some View {
        VStack(spacing: 24) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 80))
                .foregroundColor(.green)
            
            VStack(spacing: 8) {
                Text("Account Set Up Complete!")
                    .font(.title2)
                    .fontWeight(.bold)
                
                Text("You can now access your Project Planner account")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            }
            
            Button("Continue to App") {
                // This would navigate to the main app
                // For now, we'll just dismiss or show a success message
            }
            .buttonStyle(.borderedProminent)
            .tint(.indigo)
        }
    }
    
    // MARK: - Helper Properties
    
    private var canProceed: Bool {
        !password.isEmpty && 
        !confirmPassword.isEmpty && 
        password == confirmPassword && 
        password.count >= 6
    }
    
    // MARK: - Actions
    
    private func setupPassword() {
        guard canProceed else { return }
        
        isSettingUp = true
        errorMessage = nil
        
        Task {
            let success = await userStore.acceptInvitation(
                invitationToken: invitationToken,
                password: password
            )
            
            await MainActor.run {
                isSettingUp = false
                if success {
                    showSuccess = true
                } else {
                    errorMessage = userStore.errorMessage ?? "Failed to set up password. Please try again."
                }
            }
        }
    }
}

#Preview {
    PasswordSetupView(invitationToken: "sample-token")
        .environmentObject(UserStore())
        .environmentObject(FirebaseBackend())
}
