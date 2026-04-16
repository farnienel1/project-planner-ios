import SwiftUI
import MessageUI

struct PasswordResetView: View {
    @Binding var email: String
    @Environment(\.dismiss) private var dismiss
    @StateObject private var emailService = EmailVerificationService()
    @State private var isEmailSent = false
    @State private var errorMessage: String?
    @State private var isSending = false
    
    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                // Header
                VStack(spacing: 16) {
                    Image(systemName: "key.fill")
                        .font(.system(size: 60))
                        .foregroundColor(.blue)
                    
                    Text("Reset Password")
                        .font(.largeTitle.weight(.bold))
                    
                    Text("Enter your email address and we'll send you a password reset link.")
                        .multilineTextAlignment(.center)
                        .foregroundColor(.secondary)
                }
                .padding(.top, 40)
                
                if !isEmailSent {
                    // Email Input
                    VStack(spacing: 16) {
                        TextField("Email Address", text: $email)
                            .keyboardType(.emailAddress)
                            .autocapitalization(.none)
                            .disableAutocorrection(true)
                            .textFieldStyle(RoundedBorderTextFieldStyle())
                        
                        if let errorMessage = errorMessage {
                            Text(errorMessage)
                                .foregroundColor(.red)
                                .font(.caption)
                                .multilineTextAlignment(.center)
                        }
                        
                        Button("Send Reset Email") {
                            sendPasswordResetEmail()
                        }
                        .buttonStyle(PrimaryButtonStyle())
                        .disabled(email.isEmpty || !isValidEmail(email) || isSending)
                        
                        if isSending {
                            ProgressView()
                                .padding(.top, 8)
                        }
                    }
                    .padding(.horizontal)
                } else {
                    // Success State
                    VStack(spacing: 16) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 60))
                            .foregroundColor(.green)
                        
                        Text("Reset Email Sent!")
                            .font(.title2.weight(.bold))
                            .foregroundColor(.green)
                        
                        Text("We've sent a password reset link to \(email). Please check your email and follow the instructions to reset your password.")
                            .multilineTextAlignment(.center)
                            .foregroundColor(.secondary)
                        
                        Button("Resend Email") {
                            sendPasswordResetEmail()
                        }
                        .buttonStyle(SecondaryButtonStyle())
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
        .sheet(isPresented: $emailService.isShowingMailView) {
            MailComposeView(
                toRecipients: [email],
                subject: "Reset Your Project Planner Password",
                messageBody: createPasswordResetEmailBody()
            )
        }
    }
    
    private func sendPasswordResetEmail() {
        guard isValidEmail(email) else {
            errorMessage = "Please enter a valid email address."
            return
        }
        
        errorMessage = nil
        isSending = true
        
        Task {
            await emailService.sendPasswordResetEmail(to: email)
            
            await MainActor.run {
                isSending = false
                if emailService.isEmailSent {
                    isEmailSent = true
                } else {
                    errorMessage = emailService.errorMessage ?? "Failed to send email. Please try again."
                }
            }
        }
    }
    
    private func isValidEmail(_ email: String) -> Bool {
        let emailRegex = "[A-Z0-9a-z._%+-]+@[A-Za-z0-9.-]+\\.[A-Za-z]{2,64}"
        let emailPredicate = NSPredicate(format: "SELF MATCHES %@", emailRegex)
        return emailPredicate.evaluate(with: email)
    }
    
    private func createPasswordResetEmailBody() -> String {
        let resetCode = emailService.generateVerificationCode()
        return """
        <html>
        <body>
        <h2>Password Reset Request</h2>
        <p>You requested to reset your password for your Project Planner account. Click the link below to reset your password:</p>
        
        <div style="text-align: center; margin: 30px 0;">
            <a href="https://projectplanner.us/reset?code=\(resetCode)&email=\(email)" 
               style="background-color: #FF3B30; color: white; padding: 15px 30px; text-decoration: none; border-radius: 8px; font-weight: bold;">
                Reset Password
            </a>
        </div>
        
        <p>If the button doesn't work, copy and paste this link into your browser:</p>
        <p style="word-break: break-all; color: #666;">
            https://projectplanner.us/reset?code=\(resetCode)&email=\(email)
        </p>
        
        <p><strong>Reset Code:</strong> \(resetCode)</p>
        
        <p>This password reset link will expire in 1 hour for security reasons.</p>
        
        <hr>
        <p style="color: #666; font-size: 12px;">
            If you didn't request this password reset, please ignore this email and your password will remain unchanged.<br>
            This email was sent by Project Planner - Your Project Management Solution
        </p>
        </body>
        </html>
        """
    }
}


#Preview {
    PasswordResetView(email: .constant("test@example.com"))
}
