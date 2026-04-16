import Foundation
import MessageUI
import Combine

class EmailVerificationService: NSObject, ObservableObject {
    @Published var isShowingMailView = false
    @Published var result: Result<MFMailComposeResult, Error>? = nil
    @Published var isEmailSent = false
    @Published var errorMessage: String?
    
    private let resendService = ResendEmailService()
    private let verificationCodeManager = VerificationCodeManager()
    
    func sendVerificationEmail(to email: String, verificationCode: String? = nil, forceResend: Bool = false) {
        // Reset error state
        errorMessage = nil
        isEmailSent = false
        
        // Generate and store verification code
        let code: String
        if let providedCode = verificationCode {
            code = providedCode
        } else if forceResend {
            code = verificationCodeManager.forceGenerateAndStoreCode(for: email)
        } else {
            code = verificationCodeManager.generateAndStoreCode(for: email)
        }
        
        // Check if rate limited (only for normal requests)
        if code.isEmpty && !forceResend {
            errorMessage = "Too many verification requests. Please wait 1 minute before trying again."
            return
        }
        
        print("📧 Sending verification email to: \(email) with code: \(code)")
        
        // Send verification email via Resend
        Task {
            let success = await resendService.sendVerificationEmail(to: email, verificationCode: code)
            
            await MainActor.run {
                if success {
                    self.isEmailSent = true
                    self.errorMessage = nil
                    print("✅ Verification email sent successfully via Resend")
                } else {
                    // If Resend fails, fall back to system mail composer
                    self.isShowingMailView = true
                    self.isEmailSent = true
                    self.errorMessage = resendService.errorMessage ?? "Failed to send email. Please try again."
                    print("📧 Resend failed: \(resendService.errorMessage ?? "Unknown error")")
                }
            }
        }
    }
    
    
    func createVerificationEmail(to email: String, verificationCode: String) -> MFMailComposeViewController {
        let mailComposer = MFMailComposeViewController()
        mailComposer.mailComposeDelegate = self
        mailComposer.setToRecipients([email])
        mailComposer.setSubject("Verify Your Project Planner Account")
        
        let emailBody = """
        <html>
        <body>
        <h2>Welcome to Project Planner!</h2>
        <p>Thank you for creating your organisation account. To complete your registration, please click the verification link below:</p>
        
        <div style="text-align: center; margin: 30px 0;">
            <a href="https://projectplanner.us/verify?code=\(verificationCode)&email=\(email)" 
               style="background-color: #007AFF; color: white; padding: 15px 30px; text-decoration: none; border-radius: 8px; font-weight: bold;">
                Verify Account
            </a>
        </div>
        
        <p>If the button doesn't work, copy and paste this link into your browser:</p>
        <p style="word-break: break-all; color: #666;">
            https://projectplanner.us/verify?code=\(verificationCode)&email=\(email)
        </p>
        
        <p>This verification link will expire in 24 hours.</p>
        
        <hr>
        <p style="color: #666; font-size: 12px;">
            If you didn't create this account, please ignore this email.<br>
            This email was sent by Project Planner - Your Project Management Solution
        </p>
        </body>
        </html>
        """
        
        mailComposer.setMessageBody(emailBody, isHTML: true)
        return mailComposer
    }
    
    func generateVerificationCode() -> String {
        return String(Int.random(in: 100000...999999))
    }
    
    func verifyCode(_ code: String, for email: String) -> VerificationResult {
        return verificationCodeManager.verifyCode(code, for: email)
    }
    
    
    func sendPasswordResetEmail(to email: String) async {
        let resetCode = generateVerificationCode()
        
        // Send password reset email via Resend
        let success = await resendService.sendPasswordResetEmail(to: email, resetCode: resetCode)
        
        await MainActor.run {
            if success {
                self.isEmailSent = true
                self.errorMessage = nil
                print("✅ Password reset email sent successfully via Resend")
            } else {
                // If Resend fails, fall back to system mail composer
                self.isShowingMailView = true
                self.isEmailSent = true
                self.errorMessage = resendService.errorMessage ?? "Failed to send email. Please try again."
                print("📧 Resend failed: \(resendService.errorMessage ?? "Unknown error")")
            }
        }
    }
    
    func createPasswordResetEmail(to email: String) -> MFMailComposeViewController {
        let mailComposer = MFMailComposeViewController()
        mailComposer.mailComposeDelegate = self
        mailComposer.setToRecipients([email])
        mailComposer.setSubject("Reset Your Project Planner Password")
        
        let resetCode = generateVerificationCode()
        let emailBody = """
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
        
        mailComposer.setMessageBody(emailBody, isHTML: true)
        return mailComposer
    }
}

extension EmailVerificationService: MFMailComposeViewControllerDelegate {
    func mailComposeController(_ controller: MFMailComposeViewController, didFinishWith result: MFMailComposeResult, error: Error?) {
        controller.dismiss(animated: true)
        self.result = .success(result)
        self.isShowingMailView = false
    }
}
