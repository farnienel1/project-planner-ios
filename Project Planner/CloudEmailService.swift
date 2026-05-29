//
//  CloudEmailService.swift
//  Project Planner
//
//  Created by Assistant on 30/09/2025.
//

import Foundation

class CloudEmailService {
    static let shared = CloudEmailService()
    
    private init() {}
    
    // Email configuration - credentials are stored in backend .env file
    // Backend uses: EMAIL_USER and EMAIL_PASSWORD from environment variables
    
    func sendEmail(recipient: String, subject: String, body: String) async -> Bool {
        // Use Resend as primary email service
        print("📧 Attempting to send email via Resend to: \(recipient)")
        print("📧 Subject: \(subject)")
        
        let resendService = ResendEmailService()
        
        // Convert plain text body to HTML for Resend
        let htmlBody = """
        <html>
        <body style="font-family: Arial, sans-serif; max-width: 600px; margin: 0 auto; padding: 20px;">
            <div style="white-space: pre-line; line-height: 1.6; color: #333;">
            \(body.replacingOccurrences(of: "\n", with: "<br>"))
            </div>
        </body>
        </html>
        """
        
        let success = await resendService.sendEmail(
            to: recipient,
            subject: subject,
            htmlContent: htmlBody
        )
        
        if success {
            print("✅ Email sent successfully via Resend to: \(recipient)")
        } else {
            print("❌ Failed to send email via Resend to: \(recipient)")
        }
        
        return success
    }
    
    // Fallback method using Resend API (free tier available)
    private func sendEmailViaResend(recipient: String, subject: String, body: String) async -> Bool {
        let resendAPIKey = "<RESEND_API_KEY>" // Set via runtime config
        let fromEmail = "info@projectplanner.us" // Primary email address
        
        guard let url = URL(string: "https://api.resend.com/emails") else {
            print("❌ Invalid Resend URL")
            return false
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(resendAPIKey)", forHTTPHeaderField: "Authorization")
        
        let resendPayload: [String: Any] = [
            "from": "Project Planner <\(fromEmail)>",
            "to": [recipient],
            "subject": subject,
            "text": body
        ]
        
        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: resendPayload)
            
            let (data, response) = try await URLSession.shared.data(for: request)
            
            if let httpResponse = response as? HTTPURLResponse {
                if httpResponse.statusCode == 200 {
                    print("✅ Email sent successfully via Resend")
                    return true
                } else {
                    print("❌ Resend error: \(httpResponse.statusCode)")
                    if let responseData = String(data: data, encoding: .utf8) {
                        print("Response: \(responseData)")
                    }
                }
            }
        } catch {
            print("❌ Resend error: \(error.localizedDescription)")
        }
        
        // If backend fails, log the error
        print("📧 Email sending failed via backend")
        print("   To: \(recipient)")
        print("   Subject: \(subject)")
        
        return false
    }
    
    // Alternative: Use Microsoft Graph API (requires app registration)
    func sendEmailViaGraphAPI(recipient: String, subject: String, body: String) async -> Bool {
        // This would require:
        // 1. Azure App Registration
        // 2. Microsoft Graph API credentials
        // 3. Proper authentication flow
        
        // For now, fallback to basic SMTP simulation
        return await sendEmail(recipient: recipient, subject: subject, body: body)
    }
}

// MARK: - Production Implementation Notes
/*
 
 To implement real cloud email sending, you have several options:
 
 1. **Backend API + SMTP** (Recommended):
    - Create a backend service (Node.js, Python, etc.)
    - Use SMTP library to send emails
    - App sends email data to your backend
    - Backend sends email via SMTP
 
 2. **Microsoft Graph API**:
    - Register app in Azure
    - Use Microsoft Graph API to send emails
    - Requires OAuth2 authentication
 
 3. **Third-party Email Services**:
    - SendGrid, Mailgun, AWS SES
    - Send email data to their API
    - They handle SMTP delivery
 
 4. **Firebase Functions + SMTP**:
    - Use Firebase Cloud Functions
    - Implement SMTP sending in the function
    - Call function from the app
 
 Example backend implementation (Node.js):
 
 ```javascript
 const nodemailer = require('nodemailer');
 
 const transporter = nodemailer.createTransport({
   host: 'smtp.office365.com',
   port: 587,
   secure: false,
   auth: {
     user: 'info@raccordmep.co.uk',
    pass: '<EMAIL_PASSWORD>'
   }
 });
 
 app.post('/send-email', async (req, res) => {
   const { to, subject, text } = req.body;
   
   try {
     await transporter.sendMail({
       from: 'info@raccordmep.co.uk',
       to: to,
       subject: subject,
       text: text
     });
     
     res.json({ success: true });
   } catch (error) {
     res.status(500).json({ success: false, error: error.message });
   }
 });
 ```
 
 */
