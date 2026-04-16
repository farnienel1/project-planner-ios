//
//  ResendEmailService.swift
//  Project Planner
//
//  Modern, user-friendly alternative to SendGrid
//

import Foundation
import Combine

class ResendEmailService: ObservableObject {
    @Published var isLoading = false
    @Published var errorMessage: String?
    
    // Get your API key from: https://resend.com/api-keys
    // Free tier: 3,000 emails/month
    private let apiKey = "re_Ego1WWNt_JdEJ2gep6SKvzWKU2ZB46JV1"
    
    // Using verified domain: info@projectplanner.us
    // Domain has been verified in Resend dashboard
    private let fromEmail = "info@projectplanner.us" // Your verified domain
    
    private let baseURL = "https://api.resend.com/emails"
    
    func sendVerificationEmail(to email: String, verificationCode: String) async -> Bool {
        return await sendEmail(
            to: email,
            subject: "Verify Your Project Planner Account",
            htmlContent: createVerificationEmailBody(verificationCode: verificationCode, email: email)
        )
    }
    
    func sendPasswordResetEmail(to email: String, resetCode: String) async -> Bool {
        return await sendEmail(
            to: email,
            subject: "Reset Your Project Planner Password",
            htmlContent: createPasswordResetEmailBody(resetCode: resetCode, email: email)
        )
    }
    
    /// Sends a password reset email with a single link. No code required – user clicks the button and sets new password on the website.
    /// - Parameter fromName: Organization name shown as the email "From" (e.g. "Acme Ltd"). If nil, uses "Project Planner".
    func sendPasswordResetLinkEmail(to email: String, firstName: String, surname: String, token: String, fromName: String? = nil) async -> Bool {
        return await sendEmail(
            to: email,
            subject: "Reset Your Project Planner Password",
            htmlContent: createPasswordResetLinkEmailBody(firstName: firstName, surname: surname, token: token),
            fromName: fromName
        )
    }

    /// Sends the welcome/set-up account email with setup link. Use organisation name as From so new users see the org.
    /// - Parameter fromName: Organization name shown as the email "From" (e.g. "Acme Ltd"). If nil, uses "Project Planner".
    func sendPasswordSetupEmail(to email: String, firstName: String, surname: String, invitationCode: String, fromName: String? = nil) async -> Bool {
        return await sendEmail(
            to: email,
            subject: "Welcome to Project Planner - Set Up Your Account",
            htmlContent: createPasswordSetupEmailBody(firstName: firstName, surname: surname, invitationCode: invitationCode, email: email),
            fromName: fromName
        )
    }

    /// Sends sign-up email with a single setup link and one verification code (the invitation token). Use organisation name as From so new users see the org.
    /// - Parameter fromName: Organization name shown as the email "From" (e.g. "Acme Ltd"). If nil, uses "Project Planner".
    func sendSignUpEmailWithVerification(to email: String, firstName: String, surname: String, invitationCode: String, fromName: String? = nil) async -> Bool {
        return await sendEmail(
            to: email,
            subject: "Welcome to Project Planner - Set Up Your Account",
            htmlContent: createSignUpEmailWithVerificationBody(firstName: firstName, surname: surname, invitationCode: invitationCode, email: email),
            fromName: fromName
        )
    }
    
    func sendScheduleEmail(to email: String, scheduleContent: String, weekDate: String? = nil) async -> Bool {
        let subject = weekDate != nil ? "Your Weekly Schedule - \(weekDate!)" : "Your Weekly Schedule"
        return await sendEmail(
            to: email,
            subject: subject,
            htmlContent: createScheduleEmailBody(scheduleContent: scheduleContent, weekDate: weekDate)
        )
    }
    
    func sendNotificationEmail(to email: String, title: String, message: String, notificationType: String = "General") async -> Bool {
        return await sendEmail(
            to: email,
            subject: title,
            htmlContent: createNotificationEmailBody(title: title, message: message, notificationType: notificationType)
        )
    }
    
    func sendEmail(to email: String, subject: String, htmlContent: String, cc: String? = nil, replyTo: String? = nil, fromName: String? = nil) async -> Bool {
        await MainActor.run {
            self.isLoading = true
            self.errorMessage = nil
        }
        
        guard let url = URL(string: baseURL) else {
            await MainActor.run {
                self.errorMessage = "Invalid URL"
                self.isLoading = false
            }
            return false
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        
        let fromDisplay = fromName.map { "\($0) <\(fromEmail)>" } ?? "Project Planner <\(fromEmail)>"
        var emailData: [String: Any] = [
            "from": fromDisplay,
            "to": [email],
            "subject": subject,
            "html": htmlContent
        ]
        
        // Add CC if provided
        if let ccEmail = cc {
            emailData["cc"] = [ccEmail]
        }
        
        // Reply-To: use provided address (e.g. user's email for material requests) so replies go to the user; otherwise default to from
        emailData["reply_to"] = replyTo ?? fromEmail
        
        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: emailData)
            
            print("📧 [Resend] Sending email to: \(email)")
            print("📧 [Resend] From: \(fromEmail)")
            print("📧 [Resend] Subject: \(subject)")
            
            let (data, response) = try await URLSession.shared.data(for: request)
            
            if let httpResponse = response as? HTTPURLResponse {
                print("📧 [Resend] Response status: \(httpResponse.statusCode)")
                
                if httpResponse.statusCode == 200 {
                    if let responseData = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                       let responseId = responseData["id"] as? String {
                        print("✅ [Resend] Email sent successfully! ID: \(responseId)")
                    } else {
                        print("✅ [Resend] Email sent successfully!")
                    }
                    
                    await MainActor.run {
                        self.isLoading = false
                    }
                    return true
                } else {
                    // Log response body for debugging
                    if let responseString = String(data: data, encoding: .utf8) {
                        print("❌ [Resend] Error response: \(responseString)")
                        
                        // Try to parse error message
                        if let errorData = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                            // Check for different error message formats
                            var errorMessage: String?
                            
                            if let message = errorData["message"] as? String {
                                errorMessage = message
                            } else if let errors = errorData["errors"] as? [[String: Any]],
                                      let firstError = errors.first,
                                      let message = firstError["message"] as? String {
                                errorMessage = message
                            } else if let error = errorData["error"] as? [String: Any],
                                      let message = error["message"] as? String {
                                errorMessage = message
                            }
                            
                            if let message = errorMessage {
                                print("❌ [Resend] Parsed error: \(message)")
                                await MainActor.run {
                                    self.errorMessage = message
                                }
                            }
                        }
                    }
                    
                    let errorMessage: String
                    switch httpResponse.statusCode {
                    case 400:
                        errorMessage = "Bad Request - Check email format"
                    case 401:
                        errorMessage = "Unauthorized - Invalid API key. Get your key from https://resend.com/api-keys"
                    case 403:
                        errorMessage = "Forbidden - API key lacks permissions"
                    case 422:
                        errorMessage = "Unprocessable - Invalid email address or content"
                    case 429:
                        errorMessage = "Rate Limited - Too many requests"
                    default:
                        errorMessage = "Failed to send email. Status: \(httpResponse.statusCode)"
                    }
                    
                    print("❌ [Resend] \(errorMessage)")
                    
                    await MainActor.run {
                        if self.errorMessage == nil {
                            self.errorMessage = errorMessage
                        }
                        self.isLoading = false
                    }
                    return false
                }
            }
        } catch {
            print("❌ [Resend] Email error: \(error)")
            await MainActor.run {
                self.errorMessage = "Failed to send email: \(error.localizedDescription)"
                self.isLoading = false
            }
            return false
        }
        
        await MainActor.run {
            self.isLoading = false
        }
        return false
    }
    
    // MARK: - Email Body Templates (same as SendGrid)
    
    private func createVerificationEmailBody(verificationCode: String, email: String) -> String {
        return """
        <html>
        <body style="font-family: Arial, sans-serif; max-width: 600px; margin: 0 auto; padding: 20px;">
            <div style="text-align: center; margin-bottom: 30px;">
                <h1 style="color: #007AFF; margin-bottom: 10px;">Project Planner</h1>
                <h2 style="color: #333; font-weight: normal;">Welcome to Project Planner!</h2>
            </div>
            
            <p style="color: #666; line-height: 1.6;">
                Thank you for creating your organisation account. To complete your registration, please click the verification link below:
            </p>
            
            <div style="text-align: center; margin: 30px 0;">
                <a href="https://projectplanner.us/verify?code=\(verificationCode)&email=\(email)" 
                   style="background-color: #007AFF; color: white; padding: 15px 30px; text-decoration: none; border-radius: 8px; font-weight: bold; display: inline-block;">
                    Verify Account
                </a>
            </div>
            
            <p style="color: #666; line-height: 1.6;">
                If the button doesn't work, copy and paste this link into your browser:
            </p>
            <p style="word-break: break-all; color: #666; background-color: #f5f5f5; padding: 10px; border-radius: 4px; font-family: monospace;">
                https://projectplanner.us/verify?code=\(verificationCode)&email=\(email)
            </p>
            
            <p style="color: #ff6b6b; font-weight: bold;">
                This verification link will expire in 24 hours.
            </p>
            
            <hr style="border: none; border-top: 1px solid #eee; margin: 30px 0;">
            <p style="color: #999; font-size: 12px; text-align: center;">
                If you didn't create this account, please ignore this email.<br>
                This email was sent by Project Planner - Your Project Management Solution
            </p>
        </body>
        </html>
        """
    }
    
    /// Reset email with link only – no code. User clicks the button and sets new password on the website.
    private func createPasswordResetLinkEmailBody(firstName: String, surname: String, token: String) -> String {
        let url = "https://projectplanner.us/setup-password.html?token=\(token)"
        return """
        <!DOCTYPE html>
        <html>
        <head>
            <meta charset="utf-8">
            <meta name="viewport" content="width=device-width, initial-scale=1.0">
        </head>
        <body style="margin: 0; padding: 0; font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, 'Helvetica Neue', Arial, sans-serif; background-color: #f4f4f5; -webkit-font-smoothing: antialiased;">
            <table role="presentation" width="100%" cellspacing="0" cellpadding="0" style="background-color: #f4f4f5; padding: 40px 20px;">
                <tr>
                    <td align="center">
                        <table role="presentation" width="600" cellspacing="0" cellpadding="0" style="max-width: 600px; width: 100%; background-color: #ffffff; border-radius: 12px; box-shadow: 0 4px 24px rgba(0,0,0,0.08); overflow: hidden;">
                            <!-- Brand header -->
                            <tr>
                                <td style="background: linear-gradient(135deg, #007AFF 0%, #5856D6 100%); padding: 28px 32px; text-align: center;">
                                    <h1 style="margin: 0; color: #ffffff; font-size: 24px; font-weight: 700; letter-spacing: -0.5px;">Project Planner</h1>
                                    <p style="margin: 6px 0 0 0; color: rgba(255,255,255,0.9); font-size: 14px; font-weight: 400;">Project Management for Construction Teams</p>
                                </td>
                            </tr>
                            <!-- Content -->
                            <tr>
                                <td style="padding: 40px 32px 32px 32px;">
                                    <h2 style="margin: 0 0 24px 0; color: #111827; font-size: 20px; font-weight: 600;">Reset your password</h2>
                                    <p style="margin: 0 0 16px 0; color: #4b5563; font-size: 16px; line-height: 1.6;">
                                        Hello \(firstName),
                                    </p>
                                    <p style="margin: 0 0 28px 0; color: #4b5563; font-size: 16px; line-height: 1.6;">
                                        We received a request to reset the password for your Project Planner account. Click the button below to choose a new password. No verification code is required.
                                    </p>
                                    <table role="presentation" width="100%" cellspacing="0" cellpadding="0">
                                        <tr>
                                            <td align="center" style="padding: 8px 0 28px 0;">
                                                <a href="\(url)" style="display: inline-block; background: linear-gradient(135deg, #007AFF 0%, #0051D5 100%); color: #ffffff; padding: 16px 36px; text-decoration: none; font-size: 16px; font-weight: 600; border-radius: 8px; box-shadow: 0 2px 8px rgba(0,122,255,0.35);">Reset password</a>
                                            </td>
                                        </tr>
                                    </table>
                                    <p style="margin: 0 0 8px 0; color: #6b7280; font-size: 13px; line-height: 1.5;">
                                        If the button doesn't work, copy and paste this link into your browser:
                                    </p>
                                    <p style="margin: 0 0 24px 0; word-break: break-all; color: #007AFF; font-size: 13px; background-color: #f8fafc; padding: 12px 14px; border-radius: 6px; border-left: 3px solid #007AFF;">
                                        \(url)
                                    </p>
                                    <div style="background-color: #fef3c7; border: 1px solid #fcd34d; border-radius: 8px; padding: 14px 16px;">
                                        <p style="margin: 0; color: #92400e; font-size: 13px; line-height: 1.5;">
                                            <strong>Security note:</strong> This link expires in 7 days. If you didn't request a password reset, you can safely ignore this email and your password will remain unchanged.
                                        </p>
                                    </div>
                                </td>
                            </tr>
                            <!-- Footer -->
                            <tr>
                                <td style="padding: 24px 32px; background-color: #f9fafb; border-top: 1px solid #e5e7eb;">
                                    <p style="margin: 0; color: #9ca3af; font-size: 12px; line-height: 1.5; text-align: center;">
                                        This email was sent by Project Planner. If you have questions, contact your organisation administrator.
                                    </p>
                                    <p style="margin: 8px 0 0 0; color: #9ca3af; font-size: 11px; text-align: center;">
                                        © Project Planner · Your password was not changed unless you used the link above.
                                    </p>
                                </td>
                            </tr>
                        </table>
                    </td>
                </tr>
            </table>
        </body>
        </html>
        """
    }

    private func createPasswordResetEmailBody(resetCode: String, email: String) -> String {
        let url = "https://projectplanner.us/setup-password.html?token=\(resetCode)"
        return """
        <html>
        <body style="font-family: Arial, sans-serif; max-width: 600px; margin: 0 auto; padding: 20px;">
            <div style="text-align: center; margin-bottom: 30px;">
                <h1 style="color: #007AFF; margin-bottom: 10px;">Project Planner</h1>
                <h2 style="color: #333; font-weight: normal;">Password Reset Request</h2>
            </div>
            
            <p style="color: #666; line-height: 1.6;">
                You requested to reset your password. Click the link below to set a new password on the website. No code required.
            </p>
            
            <div style="text-align: center; margin: 30px 0;">
                <a href="\(url)"
                   style="background-color: #007AFF; color: white; padding: 15px 30px; text-decoration: none; border-radius: 8px; font-weight: bold; display: inline-block;">
                    Reset Password
                </a>
            </div>
            
            <p style="color: #666; line-height: 1.6;">
                If the button doesn't work, copy and paste this link into your browser:
            </p>
            <p style="word-break: break-all; color: #666; background-color: #f5f5f5; padding: 10px; border-radius: 4px; font-family: monospace;">
                \(url)
            </p>
            
            <p style="color: #ff6b6b; font-weight: bold;">
                This link will expire in 7 days for security reasons.
            </p>
            
            <hr style="border: none; border-top: 1px solid #eee; margin: 30px 0;">
            <p style="color: #999; font-size: 12px; text-align: center;">
                If you didn't request this password reset, please ignore this email and your password will remain unchanged.<br>
                This email was sent by Project Planner - Your Project Management Solution
            </p>
        </body>
        </html>
        """
    }
    
    private func createPasswordSetupEmailBody(firstName: String, surname: String, invitationCode: String, email: String) -> String {
        return """
        <html>
        <body style="font-family: Arial, sans-serif; max-width: 600px; margin: 0 auto; padding: 20px;">
            <div style="text-align: center; margin-bottom: 30px;">
                <h1 style="color: #007AFF; margin-bottom: 10px;">Project Planner</h1>
                <h2 style="color: #333; font-weight: normal;">Welcome, \(firstName)!</h2>
            </div>
            
            <p style="color: #666; line-height: 1.6;">
                Hello \(firstName) \(surname),
            </p>
            
            <p style="color: #666; line-height: 1.6;">
                You have been invited to join the Project Planner system. To complete your account setup and create your password, please click the link below:
            </p>
            
            <div style="text-align: center; margin: 30px 0;">
                <a href="https://projectplanner.us/setup-password.html?token=\(invitationCode)" 
                   style="background-color: #007AFF; color: white; padding: 15px 30px; text-decoration: none; border-radius: 8px; font-weight: bold; display: inline-block;">
                    Set Up Your Password
                </a>
            </div>
            
            <p style="color: #666; line-height: 1.6;">
                If the button doesn't work, you can also visit:
            </p>
            <p style="word-break: break-all; color: #666; background-color: #f5f5f5; padding: 10px; border-radius: 4px; font-family: monospace;">
                https://projectplanner.us/setup-password.html
            </p>
            
            <p style="color: #666; line-height: 1.6;">
                Or enter this verification code:
            </p>
            <div style="background-color: #fff3cd; border: 1px solid #ffeaa7; padding: 15px; border-radius: 4px; margin: 20px 0; text-align: center;">
                <p style="margin: 0; color: #856404; font-size: 18px; font-weight: bold; font-family: monospace;">
                    \(invitationCode)
                </p>
            </div>
            
            <p style="color: #666; line-height: 1.6;">
                Once you've set up your password, you'll be able to access the Project Planner system and view your assigned projects and schedule.
            </p>
            
            <p style="color: #ff6b6b; font-weight: bold;">
                This verification code will expire in 7 days for security reasons.
            </p>
            
            <hr style="border: none; border-top: 1px solid #eee; margin: 30px 0;">
            <p style="color: #999; font-size: 12px; text-align: center;">
                If you have any questions, please contact your administrator.<br>
                This email was sent by Project Planner - Your Project Management Solution
            </p>
        </body>
        </html>
        """
    }
    
    private func createScheduleEmailBody(scheduleContent: String, weekDate: String?) -> String {
        let headerText = weekDate != nil ? "Your Weekly Schedule - \(weekDate!)" : "Your Weekly Schedule"
        return """
        <html>
        <body style="font-family: Arial, sans-serif; max-width: 600px; margin: 0 auto; padding: 20px;">
            <div style="background-color: #0d67ed; color: white; padding: 20px; text-align: center; border-radius: 8px 8px 0 0;">
                <h1 style="margin: 0; font-size: 24px;">Project Planner</h1>
            </div>
            <div style="padding: 20px; background-color: #f9f9f9; border-radius: 0 0 8px 8px;">
                <h2 style="color: #0d67ed; margin-top: 0;">\(headerText)</h2>
                <div style="white-space: pre-line; line-height: 1.6; color: #333; background-color: white; padding: 15px; border-radius: 4px;">
                \(scheduleContent.replacingOccurrences(of: "\n", with: "<br>"))
                </div>
            </div>
            <div style="background-color: #139cfe; color: white; padding: 15px; text-align: center; font-size: 14px; margin-top: 20px; border-radius: 8px;">
                <p style="margin: 0;">This email was sent from the Project Planner system</p>
            </div>
        </body>
        </html>
        """
    }
    
    /// One verification code only: the invitation token. Used for the link and for manual entry.
    private func createSignUpEmailWithVerificationBody(firstName: String, surname: String, invitationCode: String, email: String) -> String {
        return """
        <html>
        <body style="font-family: Arial, sans-serif; max-width: 600px; margin: 0 auto; padding: 20px;">
            <div style="text-align: center; margin-bottom: 30px;">
                <h1 style="color: #007AFF; margin-bottom: 10px;">Project Planner</h1>
                <h2 style="color: #333; font-weight: normal;">Welcome, \(firstName)!</h2>
            </div>
            
            <p style="color: #666; line-height: 1.6;">
                Hello \(firstName) \(surname),
            </p>
            
            <p style="color: #666; line-height: 1.6;">
                You have been invited to join the Project Planner system. To set up your account and create your password, click the button below:
            </p>
            
            <div style="text-align: center; margin: 30px 0;">
                <a href="https://projectplanner.us/setup-password.html?token=\(invitationCode)" 
                   style="background-color: #007AFF; color: white; padding: 15px 30px; text-decoration: none; border-radius: 8px; font-weight: bold; display: inline-block;">
                    Set Up Your Password
                </a>
            </div>
            
            <p style="color: #666; line-height: 1.6;">
                If the button doesn't work, go to <strong>https://projectplanner.us/setup-password.html</strong> and enter this verification code when prompted:
            </p>
            <div style="background-color: #e7f3ff; border: 1px solid #b3d9ff; padding: 15px; border-radius: 4px; margin: 20px 0; text-align: center;">
                <p style="margin: 0; color: #004085; font-size: 16px; font-weight: bold; font-family: monospace; word-break: break-all;">
                    \(invitationCode)
                </p>
            </div>
            
            <p style="color: #666; line-height: 1.6;">
                Once you've set up your password, you'll be able to access the Project Planner system and view your assigned projects and schedule.
            </p>
            
            <p style="color: #ff6b6b; font-weight: bold;">
                This link and code will expire in 7 days for security reasons.
            </p>
            
            <hr style="border: none; border-top: 1px solid #eee; margin: 30px 0;">
            <p style="color: #999; font-size: 12px; text-align: center;">
                If you have any questions, please contact your administrator.<br>
                This email was sent by Project Planner - Your Project Management Solution
            </p>
        </body>
        </html>
        """
    }
    
    private func createNotificationEmailBody(title: String, message: String, notificationType: String) -> String {
        let iconColor: String
        let bgColor: String
        
        switch notificationType.lowercased() {
        case "alert", "warning":
            iconColor = "#FF3B30"
            bgColor = "#fff3cd"
        case "success":
            iconColor = "#34C759"
            bgColor = "#d4edda"
        case "info":
            iconColor = "#007AFF"
            bgColor = "#d1ecf1"
        default:
            iconColor = "#007AFF"
            bgColor = "#f9f9f9"
        }
        
        return """
        <html>
        <body style="font-family: Arial, sans-serif; max-width: 600px; margin: 0 auto; padding: 20px;">
            <div style="text-align: center; margin-bottom: 30px;">
                <h1 style="color: #007AFF; margin-bottom: 10px;">Project Planner</h1>
                <h2 style="color: #333; font-weight: normal;">\(title)</h2>
            </div>
            
            <div style="background-color: \(bgColor); border-left: 4px solid \(iconColor); padding: 20px; border-radius: 4px; margin: 20px 0;">
                <div style="white-space: pre-line; line-height: 1.6; color: #333;">
                \(message.replacingOccurrences(of: "\n", with: "<br>"))
                </div>
            </div>
            
            <hr style="border: none; border-top: 1px solid #eee; margin: 30px 0;">
            <p style="color: #999; font-size: 12px; text-align: center;">
                This email was sent by Project Planner - Your Project Management Solution
            </p>
        </body>
        </html>
        """
    }
}

