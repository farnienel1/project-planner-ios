import SwiftUI

/// Login-screen password reset. Uses Firebase Auth’s built-in reset email (no Resend API, no Mail.app required).
struct PasswordResetView: View {
    @Binding var email: String
    @EnvironmentObject var firebaseBackend: FirebaseBackend
    @Environment(\.dismiss) private var dismiss

    @State private var isEmailSent = false
    @State private var errorMessage: String?
    @State private var isSending = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                VStack(spacing: 16) {
                    Image(systemName: "key.fill")
                        .font(.system(size: 60))
                        .foregroundColor(.blue)

                    Text("Reset Password")
                        .font(.largeTitle.weight(.bold))

                    Text("Enter your email and we’ll send a link from Firebase to reset your password. Check spam if you don’t see it.")
                        .multilineTextAlignment(.center)
                        .foregroundColor(.secondary)
                        .font(.subheadline)
                }
                .padding(.top, 40)

                if !isEmailSent {
                    VStack(spacing: 16) {
                        TextField("Email Address", text: $email)
                            .accessibilityIdentifier("passwordReset.emailAddress")
                            .keyboardType(.emailAddress)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .textFieldStyle(RoundedBorderTextFieldStyle())

                        if let errorMessage {
                            Text(errorMessage)
                                .foregroundColor(.red)
                                .font(.caption)
                                .multilineTextAlignment(.center)
                        }

                        Button("Send Reset Link") {
                            sendPasswordReset()
                        }
                        .accessibilityIdentifier("passwordReset.sendResetLink")
                        .buttonStyle(PrimaryButtonStyle())
                        .disabled(isSending)

                        if isSending {
                            ProgressView()
                                .padding(.top, 8)
                        }
                    }
                    .padding(.horizontal)
                } else {
                    VStack(spacing: 16) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 60))
                            .foregroundColor(.green)

                        Text("Check your email")
                            .font(.title2.weight(.bold))
                            .foregroundColor(.green)

                        Text("If an account exists for \(email.trimmingCharacters(in: .whitespacesAndNewlines)), you’ll receive a password reset link shortly.")
                            .multilineTextAlignment(.center)
                            .foregroundColor(.secondary)

                        Button("Done") {
                            dismiss()
                        }
                        .accessibilityIdentifier("passwordReset.done")
                        .buttonStyle(PrimaryButtonStyle())
                    }
                    .padding(.horizontal)
                }

                Spacer()
            }
            .padding()
            .navigationTitle("Reset Password")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") {
                        dismiss()
                    }
                        .accessibilityIdentifier("passwordReset.cancel")
                }
            }
        }
    }

    private func sendPasswordReset() {
        if let emailError = AuthFormValidation.emailMessage(for: email) {
            errorMessage = emailError
            return
        }
        let trimmed = email.trimmingCharacters(in: .whitespacesAndNewlines)

        errorMessage = nil
        isSending = true

        Task {
            do {
                try await firebaseBackend.sendPasswordResetEmailFromLogin(email: trimmed)
                await MainActor.run {
                    isSending = false
                    isEmailSent = true
                }
            } catch {
                await MainActor.run {
                    isSending = false
                    errorMessage = error.localizedDescription
                }
            }
        }
    }

}

#Preview {
    PasswordResetView(email: .constant("test@example.com"))
        .environmentObject(FirebaseBackend())
}
