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
    @State private var email = ""
    @State private var password = ""
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

                        Text("Welcome back")
                            .font(.headline)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .padding(.top, 30)

                    VStack(spacing: 18) {
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
                        Button(action: signIn) {
                            HStack {
                                if firebaseBackend.isLoading {
                                    ProgressView()
                                        .progressViewStyle(CircularProgressViewStyle(tint: .white))
                                        .scaleEffect(0.8)
                                }
                                Text("Sign In")
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

                        Button("Forgot Password?") {
                            showingForgotPassword = true
                        }
                        .font(.subheadline)
                        .foregroundColor(.blue)
                    }

                    VStack(spacing: 10) {
                        Text("New organisation?")
                            .font(.callout)
                            .foregroundColor(.secondary)

                        Button(action: { AppBranding.openOrganisationSetup() }) {
                            HStack(spacing: 8) {
                                Image(systemName: "safari")
                                Text("Set up on the web")
                                    .font(.headline)
                            }
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(Color.white)
                            .foregroundColor(.blue)
                            .overlay(
                                RoundedRectangle(cornerRadius: 12)
                                    .stroke(Color.blue, lineWidth: 1.5)
                            )
                        }
                        .padding(.horizontal, 32)
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
            if isFormValid { signIn() }
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
        // Keep sign-in permissive so users can always submit and receive a concrete backend error.
        return !trimmedEmail.isEmpty && !password.isEmpty
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
}

#Preview {
    AuthenticationView()
        .environmentObject(FirebaseBackend())
        .environmentObject(UserStore())
}
