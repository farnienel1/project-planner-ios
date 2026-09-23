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
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    SettingsHubChrome.sectionTitle("Change Password")
                    SettingsHubChrome.card {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Enter your current password and choose a new one.")
                                .font(.system(size: 13))
                                .foregroundStyle(ProjectWorksRevampColors.muted)
                                .padding(.top, 12)
                            labeledSecure("Current Password", title: "Enter your current password", text: $currentPassword)
                            Divider().overlay(ProjectWorksRevampColors.border)
                            labeledSecure("New Password", title: "Enter your new password", text: $newPassword)
                            Divider().overlay(ProjectWorksRevampColors.border)
                            labeledSecure("Confirm New Password", title: "Confirm your new password", text: $confirmPassword)
                        }
                        .padding(.bottom, 12)
                    }

                    if let errorMessage = firebaseBackend.errorMessage {
                        Text(errorMessage)
                            .foregroundStyle(ProjectWorksRevampColors.requiredPillFg)
                            .font(.system(size: 12))
                            .padding(.horizontal, 4)
                            .padding(.bottom, 8)
                    }

                    if showingSuccessMessage {
                        Text("Password changed successfully")
                            .foregroundStyle(ProjectWorksRevampColors.activeGreen)
                            .font(.system(size: 12))
                            .padding(.horizontal, 4)
                            .padding(.bottom, 8)
                    }

                    Button(action: changePassword) {
                        HStack {
                            if firebaseBackend.isLoading {
                                ProgressView()
                                    .progressViewStyle(CircularProgressViewStyle(tint: .white))
                                    .scaleEffect(0.8)
                            }
                            Text("Change Password")
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(.white)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(ProjectWorksRevampColors.blue)
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .disabled(firebaseBackend.isLoading || !isFormValid)
                    .opacity(isFormValid ? 1.0 : 0.6)
                    .padding(.top, 8)
                }
                .padding(16)
            }
            .background(ProjectWorksRevampColors.canvas.ignoresSafeArea())
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        presentationMode.wrappedValue.dismiss()
                    }
                }
            }
        }
    }

    private func labeledSecure(_ label: String, title: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(ProjectWorksRevampColors.ink)
            CustomSecureField(title: title, text: text)
        }
        .padding(.vertical, 8)
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
