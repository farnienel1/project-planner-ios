//
//  ChangePasswordView.swift
//  Project Planner
//
//  Created by Assistant on 29/09/2025.
//

import SwiftUI

struct ChangePasswordView: View {
    @EnvironmentObject var firebaseBackend: FirebaseBackend
    @Environment(\.dismiss) private var dismiss
    
    @State private var currentPassword = ""
    @State private var newPassword = ""
    @State private var confirmPassword = ""
    @State private var showingSuccessMessage = false

    private var isDirty: Bool {
        !currentPassword.isEmpty || !newPassword.isEmpty || !confirmPassword.isEmpty
    }
    
    var body: some View {
        ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    SettingsHubChrome.sectionTitle("Change password", sentenceCase: true)
                    SettingsHubChrome.card {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Enter your current password and choose a new one.")
                                .font(.subheadline)
                                .foregroundStyle(Color.secondary)
                                .padding(.top, 12)
                            labeledSecure("Current password", title: "Enter your current password", text: $currentPassword)
                            Divider().overlay(Color(.separator))
                            labeledSecure("New password", title: "Enter your new password", text: $newPassword)
                            Divider().overlay(Color(.separator))
                            labeledSecure("Confirm new password", title: "Confirm your new password", text: $confirmPassword)
                        }
                        .padding(.bottom, 12)
                    }

                    if let errorMessage = firebaseBackend.errorMessage {
                        Text(errorMessage)
                            .foregroundStyle(PPColor.danger)
                            .font(.footnote)
                            .padding(.horizontal, 4)
                            .padding(.bottom, 8)
                    }

                    if showingSuccessMessage {
                        Text("Password changed successfully")
                            .foregroundStyle(ProjectWorksRevampColors.activeGreen)
                            .font(.footnote)
                            .padding(.horizontal, 4)
                            .padding(.bottom, 8)
                    }

                }
                .padding(16)
            }
            .background(PPColor.page.ignoresSafeArea())
            .navigationTitle("Sign-in & password")
            .navigationBarTitleDisplayMode(.inline)
            .ppNavyNavigationBar()
            .safeAreaInset(edge: .bottom) {
                SettingsStickySaveBar(title: "Save", isDirty: isDirty, isSaving: firebaseBackend.isLoading) {
                    changePassword()
                }
            }
            .settingsUnsavedLeave(isDirty: isDirty) {
                clearForm()
                dismiss()
            }
    }

    private func labeledSecure(_ label: String, title: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(Color.primary)
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
        guard isFormValid else { return }
        Task {
            do {
                try await firebaseBackend.changePassword(
                    currentPassword: currentPassword,
                    newPassword: newPassword
                )
                showingSuccessMessage = true
                clearForm()
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                    dismiss()
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
