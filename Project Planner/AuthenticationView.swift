//
//  AuthenticationView.swift
//  Project Planner
//
//  Created by Assistant on 29/09/2025.
//

import SwiftUI

struct AuthenticationView: View {
    @EnvironmentObject var firebaseBackend: FirebaseBackend
    @State private var isSignUp = false
    @State private var email = ""
    @State private var password = ""
    @State private var confirmPassword = ""
    @State private var organizationName = ""
    @State private var showingForgotPassword = false
    
    var body: some View {
        NavigationView {
            VStack(spacing: 30) {
                // Header
                VStack(spacing: 16) {
                    Image(systemName: "building.2.crop.circle.fill")
                        .font(.system(size: 80))
                        .foregroundColor(.blue)
                    
                    Text("Project Planner")
                        .font(.largeTitle)
                        .fontWeight(.bold)
                        .foregroundColor(.blue)
                    
                    Text(isSignUp ? "Create your organization account" : "Welcome back")
                        .font(.headline)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding(.top, 40)
                
                // Form
                VStack(spacing: 20) {
                    // Organization Name (Sign Up only)
                    if isSignUp {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Organization Name")
                                .font(.headline)
                                .foregroundColor(.primary)
                            
                            TextField("Enter your organization name", text: $organizationName)
                                .textFieldStyle(RoundedBorderTextFieldStyle())
                        }
                    }
                    
                    // Email
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Email")
                            .font(.headline)
                            .foregroundColor(.primary)
                        
                        TextField("Enter your email", text: $email)
                            .textFieldStyle(RoundedBorderTextFieldStyle())
                            .keyboardType(.emailAddress)
                            .autocapitalization(.none)
                    }
                    
                    // Password
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Password")
                            .font(.headline)
                            .foregroundColor(.primary)
                        
                        CustomSecureField(title: "Enter your password", text: $password)
                    }
                    
                    // Confirm Password (Sign Up only)
                    if isSignUp {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Confirm Password")
                                .font(.headline)
                                .foregroundColor(.primary)
                            
                            CustomSecureField(title: "Confirm your password", text: $confirmPassword)
                        }
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
                
                // Action Buttons
                VStack(spacing: 16) {
                    // Primary Action Button
                    Button(action: {
                        print("DEBUG: Button tapped - isSignUp: \(isSignUp)")
                        if isSignUp {
                            signUp()
                        } else {
                            signIn()
                        }
                    }) {
                        HStack {
                            if firebaseBackend.isLoading {
                                ProgressView()
                                    .progressViewStyle(CircularProgressViewStyle(tint: .white))
                                    .scaleEffect(0.8)
                            }
                            
                            Text(isSignUp ? "Create Account" : "Sign In")
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
                    
                    // Forgot Password (Sign In only)
                    if !isSignUp {
                        Button("Forgot Password?") {
                            showingForgotPassword = true
                        }
                        .font(.subheadline)
                        .foregroundColor(.blue)
                    }
                }
                
                Spacer()
                
                // Toggle Sign Up / Sign In
                Button(action: {
                    isSignUp.toggle()
                }) {
                    Text(isSignUp ? "Already have an account? Sign In" : "Don't have an account? Sign Up")
                        .font(.callout)
                        .foregroundColor(.secondary)
                }
                .padding(.bottom, 20)
            }
            .navigationTitle(isSignUp ? "Sign Up" : "Sign In")
            .sheet(isPresented: $showingForgotPassword) {
                PasswordResetView(email: $email)
                    .environmentObject(firebaseBackend)
            }
        }
    }
    
    private var isFormValid: Bool {
        if isSignUp {
            let valid = !email.isEmpty && password.count >= 6 && password == confirmPassword && !organizationName.isEmpty
            print("DEBUG: Form validation (signup) - email: '\(email)', password length: \(password.count), passwords match: \(password == confirmPassword), org: '\(organizationName)', valid: \(valid)")
            return valid
        } else {
            let valid = !email.isEmpty && password.count >= 6
            print("DEBUG: Form validation (signin) - email: '\(email)', password length: \(password.count), valid: \(valid)")
            return valid
        }
    }
    
    private func signUp() {
        print("DEBUG: signUp() called with email: \(email), password length: \(password.count), organization: \(organizationName)")
        Task {
            do {
                // BEFORE sign up, ensure setup flow will show
                await MainActor.run {
                    firebaseBackend.shouldShowSetupFlow = true
                    firebaseBackend.isNewOrganization = true
                    print("DEBUG: Pre-signup: shouldShowSetupFlow set to true")
                }
                
                try await firebaseBackend.signUp(
                    email: email,
                    password: password,
                    organizationName: organizationName
                )
                
                // AFTER sign up, explicitly set it again to ensure it persists
                await MainActor.run {
                    firebaseBackend.shouldShowSetupFlow = true
                    firebaseBackend.isNewOrganization = true
                    print("DEBUG: Post-signup: shouldShowSetupFlow confirmed as true")
                }
                
                print("DEBUG: signUp() completed successfully")
            } catch {
                print("DEBUG: signUp() failed with error: \(error)")
                // Error is handled by firebaseBackend.errorMessage
            }
        }
    }
    
    private func signIn() {
        Task {
            do {
                try await firebaseBackend.signIn(
                    email: email,
                    password: password
                )
            } catch {
                // Error is handled by firebaseBackend.errorMessage
            }
        }
    }
    
    private func resetPassword() {
        Task {
            do {
                try await firebaseBackend.resetPassword(email: email)
            } catch {
                // Error is handled by firebaseBackend.errorMessage
            }
        }
    }
}

#Preview {
    AuthenticationView()
        .environmentObject(FirebaseBackend())
}