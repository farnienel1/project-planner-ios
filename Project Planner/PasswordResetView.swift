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
                        .buttonStyle(PrimaryButtonStyle())
                        .disabled(email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !isValidEmail(email) || isSending)

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
                }
            }
        }
    }

    private func sendPasswordReset() {
        let trimmed = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isValidEmail(trimmed) else {
            errorMessage = "Please enter a valid email address."
            return
        }

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

    private func isValidEmail(_ email: String) -> Bool {
        let emailRegex = "[A-Z0-9a-z._%+-]+@[A-Za-z0-9.-]+\\.[A-Za-z]{2,64}"
        let emailPredicate = NSPredicate(format: "SELF MATCHES %@", emailRegex)
        return emailPredicate.evaluate(with: email)
    }
}

#Preview {
    PasswordResetView(email: .constant("test@example.com"))
        .environmentObject(FirebaseBackend())
}
