import Foundation
import Combine

class SendGridEmailService: ObservableObject {
    @Published var isLoading = false
    @Published var errorMessage: String?
    
    private let apiKeyName = "SENDGRID_API_KEY"
    private let fromEmail = "info@projectplanner.us" // Primary email address
    private let baseURL = "https://api.sendgrid.com/v3/mail/send"
    
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
    
    func sendPasswordSetupEmail(to email: String, firstName: String, surname: String, invitationCode: String) async -> Bool {
        return await sendEmail(
            to: email,
            subject: "Welcome to Project Planner - Set Up Your Account",
            htmlContent: createPasswordSetupEmailBody(firstName: firstName, surname: surname, invitationCode: invitationCode, email: email)
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
    
    
    func sendEmail(to email: String, subject: String, htmlContent: String) async -> Bool {
        DispatchQueue.main.async {
            self.isLoading = true
            self.errorMessage = nil
        }
        
        guard let url = URL(string: baseURL) else {
            DispatchQueue.main.async {
                self.errorMessage = "Invalid URL"
                self.isLoading = false
            }
            return false
        }

        guard let apiKey = SecureConfig.requiredSecret(named: apiKeyName) else {
            DispatchQueue.main.async {
                self.errorMessage = "Email service not configured. Add SENDGRID_API_KEY to your scheme environment variables."
                self.isLoading = false
            }
            return false
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        
        let emailData: [String: Any] = [
            "personalizations": [
                [
                    "to": [["email": email]]
                ]
            ],
            "from": [
                "email": fromEmail,
                "name": "Project Planner"
            ],
            "subject": subject,
            "content": [
                [
                    "type": "text/html",
                    "value": htmlContent
                ]
            ]
        ]
        
        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: emailData)
            
            print("📧 Sending email to: \(email)")
            print("📧 From: \(fromEmail)")
            print("📧 Subject: \(subject)")
            
            let (data, response) = try await URLSession.shared.data(for: request)
            
            if let httpResponse = response as? HTTPURLResponse {
                print("📧 Response status: \(httpResponse.statusCode)")
                
                if httpResponse.statusCode == 202 {
                    print("✅ Email sent successfully to \(email)")
                    DispatchQueue.main.async {
                        self.isLoading = false
                    }
                    return true
                } else {
                    // Log response body for debugging
                    if let responseString = String(data: data, encoding: .utf8) {
                        print("❌ SendGrid error response: \(responseString)")
                    }
                    
                    let errorMessage: String
                    switch httpResponse.statusCode {
                    case 400:
                        errorMessage = "Bad Request - Check email format and content. Verify sender email is authenticated."
                    case 401:
                        errorMessage = "Unauthorized - Invalid API key. Check your SendGrid API key."
                    case 403:
                        errorMessage = "Forbidden - Domain not verified or API key lacks permissions. Verify domain in SendGrid dashboard."
                    case 422:
                        errorMessage = "Unprocessable Entity - Sender email not verified. Add and verify sender in SendGrid."
                    case 429:
                        errorMessage = "Rate Limited - Too many requests. Wait before trying again."
                    default:
                        errorMessage = "Failed to send email. Status: \(httpResponse.statusCode)"
                    }
                    
                    print("❌ \(errorMessage)")
                    
                    DispatchQueue.main.async {
                        self.errorMessage = errorMessage
                    }
                    DispatchQueue.main.async {
                        self.isLoading = false
                    }
                    return false
                }
            }
        } catch {
            print("❌ Email error: \(error)")
            DispatchQueue.main.async {
                self.errorMessage = "Failed to send email: \(error.localizedDescription)"
                self.isLoading = false
            }
            return false
        }
        
        DispatchQueue.main.async {
            self.isLoading = false
        }
        return false
    }
    
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
    
    private func createPasswordResetEmailBody(resetCode: String, email: String) -> String {
        return """
        <html>
        <body style="font-family: Arial, sans-serif; max-width: 600px; margin: 0 auto; padding: 20px;">
            <div style="text-align: center; margin-bottom: 30px;">
                <h1 style="color: #007AFF; margin-bottom: 10px;">Project Planner</h1>
                <h2 style="color: #333; font-weight: normal;">Password Reset Request</h2>
            </div>
            
            <p style="color: #666; line-height: 1.6;">
                You requested to reset your password for your Project Planner account. Click the link below to reset your password:
            </p>
            
            <div style="text-align: center; margin: 30px 0;">
                <a href="https://projectplanner.us/reset?code=\(resetCode)&email=\(email)" 
                   style="background-color: #FF3B30; color: white; padding: 15px 30px; text-decoration: none; border-radius: 8px; font-weight: bold; display: inline-block;">
                    Reset Password
                </a>
            </div>
            
            <p style="color: #666; line-height: 1.6;">
                If the button doesn't work, copy and paste this link into your browser:
            </p>
            <p style="word-break: break-all; color: #666; background-color: #f5f5f5; padding: 10px; border-radius: 4px; font-family: monospace;">
                https://projectplanner.us/reset?code=\(resetCode)&email=\(email)
            </p>
            
            <div style="background-color: #fff3cd; border: 1px solid #ffeaa7; padding: 15px; border-radius: 4px; margin: 20px 0;">
                <p style="margin: 0; color: #856404;">
                    <strong>Reset Code:</strong> <code style="background-color: #f8f9fa; padding: 2px 4px; border-radius: 3px;">\(resetCode)</code>
                </p>
            </div>
            
            <p style="color: #ff6b6b; font-weight: bold;">
                This password reset link will expire in 1 hour for security reasons.
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
