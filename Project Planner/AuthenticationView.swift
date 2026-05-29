//
//  AuthenticationView.swift
//  Project Planner
//
//  Created by Assistant on 29/09/2025.
//

import SwiftUI
import FirebaseAuth

struct AuthenticationView: View {
    @EnvironmentObject var firebaseBackend: FirebaseBackend
    @EnvironmentObject var userStore: UserStore
    @State private var isSignUp = false
    @State private var email = ""
    @State private var password = ""
    @State private var confirmPassword = ""
    @State private var organizationName = ""
    @State private var showingForgotPassword = false
    
    var body: some View {
        ZStack {
            Color(.systemGroupedBackground).ignoresSafeArea()
            ScrollView {
                VStack(spacing: 28) {
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
                    .padding(.top, 30)

                    VStack(spacing: 18) {
                        if isSignUp {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("Organization Name")
                                    .font(.headline)
                                    .foregroundColor(.primary)
                                TextField("Enter your organization name", text: $organizationName)
                                    .textFieldStyle(RoundedBorderTextFieldStyle())
                            }
                        }

                        VStack(alignment: .leading, spacing: 8) {
                            Text("Email")
                                .font(.headline)
                                .foregroundColor(.primary)
                            TextField("Enter your email", text: $email)
                                .textFieldStyle(RoundedBorderTextFieldStyle())
                                .keyboardType(.emailAddress)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .submitLabel(.next)
                        }

                        VStack(alignment: .leading, spacing: 8) {
                            Text("Password")
                                .font(.headline)
                                .foregroundColor(.primary)
                            CustomSecureField(title: "Enter your password", text: $password)
                        }

                        if isSignUp {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("Confirm Password")
                                    .font(.headline)
                                    .foregroundColor(.primary)
                                CustomSecureField(title: "Confirm your password", text: $confirmPassword)
                            }
                        }
                    }
                    .padding(.horizontal, 32)

                    if let errorMessage = firebaseBackend.errorMessage {
                        Text(errorMessage)
                            .foregroundColor(.red)
                            .font(.caption)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 32)
                    }
                    if let errorMessage = userStore.errorMessage, !errorMessage.isEmpty, firebaseBackend.errorMessage == nil {
                        Text(errorMessage)
                            .foregroundColor(.red)
                            .font(.caption)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 32)
                    }

                    VStack(spacing: 14) {
                        Button(action: {
                            if isSignUp { signUp() } else { signIn() }
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
                        .disabled(firebaseBackend.isLoading)
                        .opacity(firebaseBackend.isLoading ? 0.6 : 1.0)
                        .padding(.horizontal, 32)

                        if !isSignUp {
                            Button("Forgot Password?") {
                                showingForgotPassword = true
                            }
                            .font(.subheadline)
                            .foregroundColor(.blue)
                        }
                    }

                    Button(action: { isSignUp.toggle() }) {
                        Text(isSignUp ? "Already have an account? Sign In" : "Don't have an account? Sign Up")
                            .font(.callout)
                            .foregroundColor(.secondary)
                    }
                    .padding(.bottom, 20)
                }
                .frame(maxWidth: .infinity)
            }
            .scrollDismissesKeyboard(.interactively)
        }
        .onAppear {
            // Safety reset: if a previous auth attempt was interrupted, keep login interactive.
            firebaseBackend.isLoading = false
        }
        .onSubmit {
            if isSignUp {
                if isFormValid { signUp() }
            } else {
                if isFormValid { signIn() }
            }
        }
        .onChange(of: email) { _, _ in
            firebaseBackend.errorMessage = nil
            userStore.errorMessage = nil
        }
        .onChange(of: password) { _, _ in
            firebaseBackend.errorMessage = nil
            userStore.errorMessage = nil
        }
        .sheet(isPresented: $showingForgotPassword) {
            PasswordResetView(email: $email)
                .environmentObject(firebaseBackend)
        }
    }
    
    private var isFormValid: Bool {
        let trimmedEmail = email.trimmingCharacters(in: .whitespacesAndNewlines)
        if isSignUp {
            return !trimmedEmail.isEmpty && password.count >= 6 && password == confirmPassword && !organizationName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        // Keep sign-in permissive so users can always submit and receive a concrete backend error.
        return !trimmedEmail.isEmpty && !password.isEmpty
    }
    
    private func signUp() {
        let trimmedEmail = email.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedOrg = organizationName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedEmail.isEmpty else {
            firebaseBackend.errorMessage = "Please enter your email address."
            return
        }
        guard password.count >= 6 else {
            firebaseBackend.errorMessage = "Password must be at least 6 characters."
            return
        }
        guard password == confirmPassword else {
            firebaseBackend.errorMessage = "Passwords do not match."
            return
        }
        guard !trimmedOrg.isEmpty else {
            firebaseBackend.errorMessage = "Please enter your organization name."
            return
        }

        userStore.errorMessage = nil
        Task { @MainActor in
            do {
                firebaseBackend.shouldShowSetupFlow = true
                firebaseBackend.isNewOrganization = true

                try await firebaseBackend.signUp(
                    email: email,
                    password: password,
                    organizationName: organizationName
                )

                if let uid = Auth.auth().currentUser?.uid, !uid.isEmpty {
                    NotificationCenter.default.post(name: .firebaseAuthUIDChanged, object: nil, userInfo: ["uid": uid])
                }

                await userStore.loadCurrentUser()

                firebaseBackend.shouldShowSetupFlow = true
                firebaseBackend.isNewOrganization = true
            } catch {
                // firebaseBackend.errorMessage set by backend
            }
        }
    }
    
    private func signIn() {
        let trimmedEmail = email.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedPassword = password.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedEmail.isEmpty else {
            firebaseBackend.errorMessage = "Please enter your email address."
            return
        }
        guard !trimmedPassword.isEmpty else {
            firebaseBackend.errorMessage = "Please enter your password."
            return
        }

        userStore.errorMessage = nil
        Task { @MainActor in
            do {
                try await firebaseBackend.signIn(
                    email: trimmedEmail,
                    password: trimmedPassword
                )
                if let uid = Auth.auth().currentUser?.uid, !uid.isEmpty {
                    NotificationCenter.default.post(name: .firebaseAuthUIDChanged, object: nil, userInfo: ["uid": uid])
                }
                // Don’t block leaving the login screen on Firestore; profile loads on the main shell.
                Task { await userStore.loadCurrentUser() }
            } catch {
                if firebaseBackend.errorMessage?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true {
                    firebaseBackend.errorMessage = "Sign in failed. Please check your email/password and try again."
                }
            }
        }
    }
    
    private func resetPassword() {
        Task { @MainActor in
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
        .environmentObject(UserStore())
}