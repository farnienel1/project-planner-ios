//
//  ResendEmailService.swift
//  Project Planner
//
//  Modern, user-friendly alternative to SendGrid
//

import Foundation
import Combine
import FirebaseCore

class ResendEmailService: ObservableObject {
    @Published var isLoading = false
    @Published var errorMessage: String?
    
    // Using verified domain: info@projectplanner.us
    // Domain has been verified in Resend dashboard
    private let fromEmail = "info@projectplanner.us" // Your verified domain
    private let setupPasswordBaseURL = "https://www.projectplanner.us"
    
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
            htmlContent: createPasswordSetupEmailBody(firstName: firstName, surname: surname, invitationCode: invitationCode, email: email, companyName: fromName ?? ""),
            fromName: fromName
        )
    }

    /// Sends sign-up email with a single setup link. Use organisation name as From so new users see the org.
    /// - Parameter fromName: Organization name shown as the email "From" (e.g. "Acme Ltd"). If nil, uses "Project Planner".
    func sendSignUpEmailWithVerification(to email: String, firstName: String, surname: String, invitationCode: String, fromName: String? = nil) async -> Bool {
        return await sendEmail(
            to: email,
            subject: "Welcome to Project Planner - Set Up Your Account",
            htmlContent: createSignUpEmailWithVerificationBody(firstName: firstName, surname: surname, invitationCode: invitationCode, email: email, companyName: fromName ?? ""),
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

    func sendTimesheetExportEmail(
        to email: String,
        subject: String,
        htmlContent: String,
        pdfAttachment: Data?,
        pdfFileName: String,
        fromName: String?
    ) async -> Bool {
        var attachments: [(fileName: String, data: Data)] = []
        if let pdfAttachment, !pdfFileName.isEmpty {
            attachments.append((pdfFileName, pdfAttachment))
        }
        return await sendTimesheetExportEmail(
            to: email,
            subject: subject,
            htmlContent: htmlContent,
            pdfAttachments: attachments,
            fromName: fromName
        )
    }

    func sendTimesheetExportEmail(
        to email: String,
        subject: String,
        htmlContent: String,
        pdfAttachments: [(fileName: String, data: Data)],
        fromName: String?
    ) async -> Bool {
        await sendEmail(
            to: email,
            subject: subject,
            htmlContent: htmlContent,
            fromName: fromName,
            pdfAttachments: pdfAttachments
        )
    }
    
    func sendEmail(
        to email: String,
        subject: String,
        htmlContent: String,
        cc: String? = nil,
        replyTo: String? = nil,
        fromName: String? = nil,
        pdfAttachment: Data? = nil,
        pdfFileName: String? = nil,
        pdfAttachments: [(fileName: String, data: Data)] = []
    ) async -> Bool {
        let safeSubject = ExportTextEscaping.sanitizeEmailSubject(subject)
        let safeFromName = Self.headerDisplayName(fromName)
        await MainActor.run {
            self.isLoading = true
            self.errorMessage = nil
        }

        var attachments = pdfAttachments
        if let pdfAttachment, let pdfFileName, !pdfFileName.isEmpty {
            attachments.append((pdfFileName, pdfAttachment))
        }
        
        // Production path: always use server-side secret via Firebase Function.
        let sentViaFunction = await sendViaFirebaseFunction(
            to: email,
            subject: safeSubject,
            htmlContent: htmlContent,
            cc: cc,
            replyTo: replyTo,
            fromName: safeFromName,
            pdfAttachments: attachments
        )
        if sentViaFunction {
            await MainActor.run { self.isLoading = false }
            return true
        }
        
#if DEBUG
        // Developer fallback only: allows local testing without function deployment.
        if let directKey = SecureConfig.requiredSecret(named: "RESEND_API_KEY") {
            let directSuccess = await sendDirectViaResend(
                apiKey: directKey,
                to: email,
                subject: safeSubject,
                htmlContent: htmlContent,
                cc: cc,
                replyTo: replyTo,
                fromName: safeFromName,
                pdfAttachments: attachments
            )
            await MainActor.run { self.isLoading = false }
            return directSuccess
        }
#endif
        
        await MainActor.run { self.isLoading = false }
        return false
    }
    
    private func sendDirectViaResend(
        apiKey: String,
        to email: String,
        subject: String,
        htmlContent: String,
        cc: String?,
        replyTo: String?,
        fromName: String?,
        pdfAttachments: [(fileName: String, data: Data)] = []
    ) async -> Bool {
        guard let url = URL(string: "https://api.resend.com/emails") else { return false }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        
        let safeSubject = ExportTextEscaping.sanitizeEmailSubject(subject)
        let safeFromName = Self.headerDisplayName(fromName)
        let fromDisplay = safeFromName.map { "\($0) <\(fromEmail)>" } ?? "Project Planner <\(fromEmail)>"
        var emailData: [String: Any] = [
            "from": fromDisplay,
            "to": [email],
            "subject": safeSubject,
            "html": htmlContent,
            "reply_to": replyTo ?? fromEmail
        ]
        if let cc, !cc.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            emailData["cc"] = [cc]
        }
        if !pdfAttachments.isEmpty {
            emailData["attachments"] = pdfAttachments.map { attachment in
                [
                    "filename": attachment.fileName,
                    "content": attachment.data.base64EncodedString(),
                    "content_type": "application/pdf",
                ]
            }
        }
        
        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: emailData)
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else { return false }
            if httpResponse.statusCode == 200 { return true }
            let body = String(data: data, encoding: .utf8) ?? ""
            await MainActor.run {
                self.errorMessage = "Direct resend fallback failed (\(httpResponse.statusCode)): \(body)"
            }
            return false
        } catch {
            await MainActor.run {
                self.errorMessage = "Direct resend fallback failed: \(error.localizedDescription)"
            }
            return false
        }
    }
    
    private func sendViaFirebaseFunction(
        to email: String,
        subject: String,
        htmlContent: String,
        cc: String?,
        replyTo: String?,
        fromName: String?,
        pdfAttachments: [(fileName: String, data: Data)] = []
    ) async -> Bool {
        guard let projectId = FirebaseApp.app()?.options.projectID,
              let url = URL(string: "https://us-central1-\(projectId).cloudfunctions.net/sendProjectPlannerEmail") else {
            await MainActor.run {
                self.errorMessage = "Email service not configured (missing Firebase project)."
            }
            return false
        }
        
        var payload: [String: Any] = [
            "to": email,
            "subject": subject,
            "html": htmlContent
        ]
        if let cc, !cc.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            payload["cc"] = cc
        }
        if let replyTo, !replyTo.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            payload["replyTo"] = replyTo
        }
        if let fromName, !fromName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            payload["fromName"] = fromName
        }
        if !pdfAttachments.isEmpty {
            payload["attachments"] = pdfAttachments.map { attachment in
                [
                    "filename": attachment.fileName,
                    "content": attachment.data.base64EncodedString(),
                    "type": "application/pdf",
                    "content_type": "application/pdf",
                ]
            }
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        
        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: payload)
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                await MainActor.run {
                    self.errorMessage = "Email fallback failed: invalid response."
                }
                return false
            }
            guard httpResponse.statusCode == 200 else {
                let body = String(data: data, encoding: .utf8) ?? ""
                await MainActor.run {
                    self.errorMessage = "Email fallback failed (\(httpResponse.statusCode)): \(body)"
                }
                return false
            }
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let sent = json["sent"] as? Bool,
               sent == true {
                return true
            }
            await MainActor.run {
                self.errorMessage = "Email fallback failed: provider did not confirm delivery."
            }
            return false
        } catch {
            await MainActor.run {
                self.errorMessage = "Email fallback failed: \(error.localizedDescription)"
            }
            return false
        }
    }
    
    /// Empty after header cleaning means "no display name", so the caller keeps the default From.
    private static func headerDisplayName(_ fromName: String?) -> String? {
        guard let fromName else { return nil }
        let cleaned = ExportTextEscaping.sanitizeFromDisplayName(fromName)
        return cleaned.isEmpty ? nil : cleaned
    }

    // MARK: - Email Body Templates (same as SendGrid)
    
    private func createVerificationEmailBody(verificationCode: String, email: String) -> String {
        let verifyURL = ExportTextEscaping.htmlQueryURL(
            absoluteBase: "https://projectplanner.us/verify",
            queryItems: [("code", verificationCode), ("email", email)]
        )
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
                <a href="\(verifyURL)" 
                   style="background-color: #007AFF; color: white; padding: 15px 30px; text-decoration: none; border-radius: 8px; font-weight: bold; display: inline-block;">
                    Verify Account
                </a>
            </div>
            
            <p style="color: #666; line-height: 1.6;">
                If the button doesn't work, copy and paste this link into your browser:
            </p>
            <p style="word-break: break-all; color: #666; background-color: #f5f5f5; padding: 10px; border-radius: 4px; font-family: monospace;">
                \(verifyURL)
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
        let safeFirstName = ExportTextEscaping.escapeHTML(firstName)
        let url = ExportTextEscaping.htmlQueryURL(
            absoluteBase: "\(setupPasswordBaseURL)/setup-password.html",
            queryItems: [("token", token)]
        )
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
                                        Hello \(safeFirstName),
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
        let url = ExportTextEscaping.htmlQueryURL(
            absoluteBase: "\(setupPasswordBaseURL)/setup-password.html",
            queryItems: [("token", resetCode)]
        )
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
    
    /// files-2.zip welcome HTML from web `lib/email/welcomeEmailPack.ts`.
    /// A blank first name becomes "there". A blank company name is an empty string. Tokens are replaced once.
    static let welcomeEmailHTMLTemplate = #"""
<!DOCTYPE html>
<html lang="en" xmlns="http://www.w3.org/1999/xhtml" xmlns:v="urn:schemas-microsoft-com:vml" xmlns:o="urn:schemas-microsoft-com:office:office">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta http-equiv="X-UA-Compatible" content="IE=edge">
<meta name="x-apple-disable-message-reformatting">
<meta name="format-detection" content="telephone=no, date=no, address=no, email=no">
<meta name="color-scheme" content="light dark">
<meta name="supported-color-schemes" content="light dark">
<title>Welcome to Project Planner</title>
<!--[if mso]>
<noscript><xml><o:OfficeDocumentSettings><o:PixelsPerInch>96</o:PixelsPerInch></o:OfficeDocumentSettings></xml></noscript>
<style>td,th,div,p,a,h1,h2{font-family:Arial,sans-serif;}</style>
<![endif]-->
<style>
  body{margin:0!important;padding:0!important;width:100%!important;background:#EEF2F7;}
  table{border-collapse:collapse;mso-table-lspace:0;mso-table-rspace:0;}
  img{border:0;outline:none;text-decoration:none;-ms-interpolation-mode:bicubic;display:block;}
  a{color:#2563EB;}
  a[x-apple-data-detectors]{color:inherit!important;text-decoration:none!important;}
  u + #body a{color:inherit;text-decoration:none;}

  /* Blueprint grid + depth on the hero, echoing the brand banners. Clients without support keep the solid navy. */
  .hero{
    background-color:#0A1628;
    background-image:
      linear-gradient(rgba(103,232,249,0.05) 1px, transparent 1px),
      linear-gradient(90deg, rgba(103,232,249,0.05) 1px, transparent 1px),
      linear-gradient(135deg, #0A1628 0%, #0F2140 55%, #173563 100%);
    background-size:40px 40px, 40px 40px, 100% 100%;
  }
  .btn-link:hover{background-color:#1D4ED8!important;}

  @media screen and (max-width:620px){
    .container{width:100%!important;}
    .px{padding-left:24px!important;padding-right:24px!important;}
    .hero-pad{padding-top:32px!important;padding-bottom:36px!important;}
    .h1{font-size:28px!important;line-height:34px!important;}
    .logo{width:170px!important;height:auto!important;}
    .btn-table{width:100%!important;}
    .btn-link{display:block!important;text-align:center!important;}
    .bar{width:40px!important;}
    .step-title{font-size:13px!important;line-height:18px!important;}
    .step-desc{font-size:12px!important;line-height:17px!important;}
    .step-gap{padding-right:8px!important;}
  }

  @media (prefers-color-scheme: dark){
    body, .bg-page{background:#050B16!important;}
    .card{background:#0E1A2E!important;}
    .ink{color:#E6EDF6!important;}
    .muted{color:#94A3B8!important;}
    .linkbox{background:#0A1628!important;border-color:#1E3354!important;}
    .linkbox a{color:#67E8F9!important;}
    .rule{border-color:#1E3354!important;}
    .foot-name{color:#E6EDF6!important;}
  }
  /* Outlook.com / Outlook app forced dark mode */
  [data-ogsc] .ink{color:#E6EDF6!important;}
  [data-ogsc] .muted{color:#94A3B8!important;}
  [data-ogsc] .foot-name{color:#E6EDF6!important;}
</style>
</head>
<body id="body" class="bg-page" style="margin:0;padding:0;background:#EEF2F7;">

<!-- Inbox preview text (hidden) -->
<div style="display:none;max-height:0;overflow:hidden;mso-hide:all;font-size:1px;line-height:1px;color:#EEF2F7;opacity:0;">
  {{CompanyName}} has invited you to Project Planner. Set up your password to see your projects and schedule.
  &#847;&zwnj;&nbsp;&#847;&zwnj;&nbsp;&#847;&zwnj;&nbsp;&#847;&zwnj;&nbsp;&#847;&zwnj;&nbsp;&#847;&zwnj;&nbsp;&#847;&zwnj;&nbsp;&#847;&zwnj;&nbsp;&#847;&zwnj;&nbsp;&#847;&zwnj;&nbsp;&#847;&zwnj;&nbsp;&#847;&zwnj;&nbsp;
</div>

<table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0" class="bg-page" style="background:#EEF2F7;">
<tr><td align="center" style="padding:32px 12px 40px 12px;">

  <!--[if mso]><table role="presentation" width="600" cellpadding="0" cellspacing="0" border="0"><tr><td><![endif]-->
  <table role="presentation" class="container" width="600" cellpadding="0" cellspacing="0" border="0" style="width:600px;max-width:600px;">

    <!-- ============ HERO ============ -->
    <tr>
      <td class="hero hero-pad px" bgcolor="#0A1628" style="background-color:#0A1628;border-radius:18px 18px 0 0;padding:40px 44px 44px 44px;">
        <a href="https://www.projectplanner.us" style="text-decoration:none;">
          <img class="logo" src="https://www.projectplanner.us/email-assets/pp-email-logo.png" width="200" height="73" alt="Project Planner" style="width:200px;height:73px;color:#FFFFFF;font-family:Arial,sans-serif;font-size:20px;font-weight:bold;">
        </a>

        <h1 class="h1" style="margin:40px 0 0 0;font-family:'Arial Black','Helvetica Neue',Arial,sans-serif;font-weight:900;font-size:34px;line-height:40px;letter-spacing:-0.5px;color:#FFFFFF;">
          Welcome aboard, {{FirstName}}.
        </h1>

        <table role="presentation" cellpadding="0" cellspacing="0" border="0" style="margin:18px 0 18px 0;">
          <tr><td width="56" height="3" bgcolor="#F59E0B" style="width:56px;height:3px;background:#F59E0B;font-size:0;line-height:0;border-radius:2px;">&nbsp;</td></tr>
        </table>

        <p style="margin:0;font-family:-apple-system,'Segoe UI',Roboto,'Helvetica Neue',Arial,sans-serif;font-size:17px;line-height:26px;color:#B9CCE3;">
          <strong style="color:#FFFFFF;font-weight:700;">{{CompanyName}}</strong> has invited you to join them on Project Planner.
        </p>
      </td>
    </tr>

    <!-- ============ BODY CARD ============ -->
    <tr>
      <td class="card px" bgcolor="#FFFFFF" style="background:#FFFFFF;padding:40px 44px 12px 44px;">

        <p class="ink" style="margin:0 0 28px 0;font-family:-apple-system,'Segoe UI',Roboto,'Helvetica Neue',Arial,sans-serif;font-size:16px;line-height:26px;color:#0F1B2D;">
          Create your password to finish setting up your account. Once you&rsquo;re in, your assigned projects and your schedule will be waiting for you in one place.
        </p>

        <!-- Button (VML for Outlook desktop, styled link everywhere else) -->
        <table role="presentation" cellpadding="0" cellspacing="0" border="0" class="btn-table">
          <tr>
            <td align="center" bgcolor="#2563EB" style="border-radius:10px;background:#2563EB;">
              <!--[if mso]>
              <v:roundrect xmlns:v="urn:schemas-microsoft-com:vml" xmlns:w="urn:schemas-microsoft-com:office:word" href="{{SetupLink}}" style="height:54px;v-text-anchor:middle;width:268px;" arcsize="19%" stroke="f" fillcolor="#2563EB">
                <w:anchorlock/>
                <center style="color:#FFFFFF;font-family:Arial,sans-serif;font-size:16px;font-weight:bold;">Set up your password</center>
              </v:roundrect>
              <![endif]-->
              <!--[if !mso]><!-- -->
              <a class="btn-link" href="{{SetupLink}}" target="_blank" style="display:inline-block;padding:17px 34px;font-family:-apple-system,'Segoe UI',Roboto,'Helvetica Neue',Arial,sans-serif;font-size:16px;line-height:20px;font-weight:700;color:#FFFFFF;text-decoration:none;border-radius:10px;background:#2563EB;mso-padding-alt:0;">Set up your password</a>
              <!--<![endif]-->
            </td>
          </tr>
        </table>

        <p class="muted" style="margin:14px 0 0 0;font-family:-apple-system,'Segoe UI',Roboto,'Helvetica Neue',Arial,sans-serif;font-size:13px;line-height:20px;color:#5B6B82;">
          For your security, this link expires in 7 days.
        </p>

        <!-- divider -->
        <table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0" style="margin:36px 0 32px 0;">
          <tr><td class="rule" style="border-top:1px solid #E3E9F1;font-size:0;line-height:0;">&nbsp;</td></tr>
        </table>

        <h2 class="ink" style="margin:0 0 24px 0;font-family:'Arial Black','Helvetica Neue',Arial,sans-serif;font-weight:900;font-size:18px;line-height:24px;color:#0A1628;">
          Three steps and you&rsquo;re in
        </h2>

        <!-- Steps drawn as the logo's three rising bars -->
        <table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0">
          <tr>
            <td width="33%" valign="bottom" style="height:100px;">
              <table role="presentation" cellpadding="0" cellspacing="0" border="0"><tr>
                <td class="bar" width="56" height="38" valign="top" align="center" bgcolor="#22D3EE" style="width:56px;height:38px;padding-top:8px;background:#22D3EE;background-image:linear-gradient(180deg,#67E8F9 0%,#22D3EE 100%);border-radius:6px 6px 2px 2px;font-family:'Arial Black','Helvetica Neue',Arial,sans-serif;font-weight:900;font-size:15px;line-height:18px;color:#0A1628;">1</td>
              </tr></table>
            </td>
            <td width="33%" valign="bottom" style="height:100px;">
              <table role="presentation" cellpadding="0" cellspacing="0" border="0"><tr>
                <td class="bar" width="56" height="64" valign="top" align="center" bgcolor="#3B82F6" style="width:56px;height:64px;padding-top:8px;background:#3B82F6;background-image:linear-gradient(180deg,#3B82F6 0%,#2563EB 100%);border-radius:6px 6px 2px 2px;font-family:'Arial Black','Helvetica Neue',Arial,sans-serif;font-weight:900;font-size:15px;line-height:18px;color:#FFFFFF;">2</td>
              </tr></table>
            </td>
            <td width="34%" valign="bottom" style="height:100px;">
              <table role="presentation" cellpadding="0" cellspacing="0" border="0"><tr>
                <td class="bar" width="56" height="92" valign="top" align="center" bgcolor="#22D3EE" style="width:56px;height:92px;padding-top:8px;background:#2BB8F0;background-image:linear-gradient(180deg,#22D3EE 0%,#3B82F6 100%);border-radius:6px 6px 2px 2px;font-family:'Segoe UI Symbol','Apple Symbols',Arial,sans-serif;font-weight:900;font-size:18px;line-height:18px;color:#0A1628;">&#10003;</td>
              </tr></table>
            </td>
          </tr>
          <!-- baseline -->
          <tr>
            <td colspan="3" height="4" bgcolor="#67E8F9" style="height:4px;background:#67E8F9;border-radius:2px;font-size:0;line-height:0;">&nbsp;</td>
          </tr>
          <!-- labels -->
          <tr>
            <td class="step-gap" valign="top" style="padding:16px 16px 0 0;">
              <p class="step-title ink" style="margin:0 0 4px 0;font-family:-apple-system,'Segoe UI',Roboto,'Helvetica Neue',Arial,sans-serif;font-size:14px;line-height:20px;font-weight:700;color:#0A1628;">Set your password</p>
              <p class="step-desc muted" style="margin:0;font-family:-apple-system,'Segoe UI',Roboto,'Helvetica Neue',Arial,sans-serif;font-size:13px;line-height:19px;color:#5B6B82;">Use the button above. It only takes a minute.</p>
            </td>
            <td class="step-gap" valign="top" style="padding:16px 16px 0 0;">
              <p class="step-title ink" style="margin:0 0 4px 0;font-family:-apple-system,'Segoe UI',Roboto,'Helvetica Neue',Arial,sans-serif;font-size:14px;line-height:20px;font-weight:700;color:#0A1628;">Sign in</p>
              <p class="step-desc muted" style="margin:0;font-family:-apple-system,'Segoe UI',Roboto,'Helvetica Neue',Arial,sans-serif;font-size:13px;line-height:19px;color:#5B6B82;">Use the email address this invite was sent to.</p>
            </td>
            <td valign="top" style="padding:16px 0 0 0;">
              <p class="step-title ink" style="margin:0 0 4px 0;font-family:-apple-system,'Segoe UI',Roboto,'Helvetica Neue',Arial,sans-serif;font-size:14px;line-height:20px;font-weight:700;color:#0A1628;">See your projects</p>
              <p class="step-desc muted" style="margin:0;font-family:-apple-system,'Segoe UI',Roboto,'Helvetica Neue',Arial,sans-serif;font-size:13px;line-height:19px;color:#5B6B82;">Your assigned projects and schedule, ready to go.</p>
            </td>
          </tr>
        </table>

        <!-- Fallback link -->
        <p class="ink" style="margin:40px 0 10px 0;font-family:-apple-system,'Segoe UI',Roboto,'Helvetica Neue',Arial,sans-serif;font-size:14px;line-height:21px;color:#0F1B2D;">
          Button not working? Copy this link into your browser:
        </p>
        <table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0" style="border-collapse:separate;">
          <tr>
            <td class="linkbox" style="background:#F4F7FB;border:1px solid #E3E9F1;border-radius:10px;padding:14px 16px;font-family:-apple-system,'Segoe UI',Roboto,'Helvetica Neue',Arial,sans-serif;font-size:13px;line-height:20px;word-break:break-all;">
              <a href="{{SetupLink}}" target="_blank" style="color:#2563EB;text-decoration:underline;">{{SetupLink}}</a>
            </td>
          </tr>
        </table>

        <p class="muted" style="margin:32px 0 0 0;font-family:-apple-system,'Segoe UI',Roboto,'Helvetica Neue',Arial,sans-serif;font-size:14px;line-height:22px;color:#5B6B82;">
          Questions about your access? Your administrator at {{CompanyName}} can help. If you weren&rsquo;t expecting this invitation, you can ignore this email.
        </p>
      </td>
    </tr>

    <!-- card bottom radius -->
    <tr>
      <td class="card" bgcolor="#FFFFFF" height="32" style="background:#FFFFFF;height:32px;border-radius:0 0 18px 18px;font-size:0;line-height:0;">&nbsp;</td>
    </tr>

    <!-- ============ FOOTER ============ -->
    <tr>
      <td class="px" style="padding:28px 44px 0 44px;">
        <table role="presentation" cellpadding="0" cellspacing="0" border="0">
          <tr>
            <td valign="middle" style="padding-right:12px;">
              <img src="https://www.projectplanner.us/email-assets/pp-email-icon.png" width="40" height="40" alt="" style="width:40px;height:40px;">
            </td>
            <td valign="middle">
              <p class="foot-name" style="margin:0;font-family:'Arial Black','Helvetica Neue',Arial,sans-serif;font-weight:900;font-size:14px;line-height:18px;color:#0A1628;">Project Planner</p>
              <p class="muted" style="margin:2px 0 0 0;font-family:-apple-system,'Segoe UI',Roboto,'Helvetica Neue',Arial,sans-serif;font-size:13px;line-height:18px;color:#5B6B82;">Built for construction teams</p>
            </td>
          </tr>
        </table>
        <p class="muted" style="margin:18px 0 0 0;font-family:-apple-system,'Segoe UI',Roboto,'Helvetica Neue',Arial,sans-serif;font-size:12px;line-height:19px;color:#7A889C;">
          This email was sent to {{RecipientEmail}} because {{CompanyName}} invited you to Project Planner.<br>
          <a href="https://www.projectplanner.us" style="color:#5B6B82;text-decoration:underline;">projectplanner.us</a>
        </p>
      </td>
    </tr>

  </table>
  <!--[if mso]></td></tr></table><![endif]-->

</td></tr>
</table>
</body>
</html>
"""#

    func welcomeInvitationEmailHTML(firstName: String, companyName: String, invitationCode: String, email: String) -> String {
        let trimmedFirst = firstName.trimmingCharacters(in: .whitespacesAndNewlines)
        let displayFirst = trimmedFirst.isEmpty ? "there" : trimmedFirst
        let trimmedCompany = companyName.trimmingCharacters(in: .whitespacesAndNewlines)
        let setupURL = ExportTextEscaping.htmlQueryURL(
            absoluteBase: "\(setupPasswordBaseURL)/setup-password.html",
            queryItems: [("token", invitationCode)]
        )
        let tokens = [
            "FirstName": ExportTextEscaping.escapeHTML(displayFirst),
            "CompanyName": ExportTextEscaping.escapeHTML(trimmedCompany),
            "SetupLink": setupURL,
            "RecipientEmail": ExportTextEscaping.escapeHTML(email.trimmingCharacters(in: .whitespacesAndNewlines)),
        ]
        return Self.fillWelcomePackTokens(Self.welcomeEmailHTMLTemplate, tokens: tokens)
    }

    static func fillWelcomePackTokens(_ template: String, tokens: [String: String]) -> String {
        let keys: Set<String> = ["FirstName", "CompanyName", "SetupLink", "RecipientEmail"]
        var result = ""
        var index = template.startIndex
        while index < template.endIndex {
            if template[index...].hasPrefix("{{"),
               let close = template[template.index(index, offsetBy: 2)...].range(of: "}}") {
                let key = String(template[template.index(index, offsetBy: 2)..<close.lowerBound])
                if keys.contains(key) {
                    result.append(tokens[key] ?? "")
                    index = close.upperBound
                    continue
                }
            }
            result.append(template[index])
            index = template.index(after: index)
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func createPasswordSetupEmailBody(firstName: String, surname: String, invitationCode: String, email: String, companyName: String) -> String {
        _ = surname
        return welcomeInvitationEmailHTML(
            firstName: firstName,
            companyName: companyName,
            invitationCode: invitationCode,
            email: email
        )
    }

    func createSignUpEmailWithVerificationBody(firstName: String, surname: String, invitationCode: String, email: String, companyName: String) -> String {
        _ = surname
        return welcomeInvitationEmailHTML(
            firstName: firstName,
            companyName: companyName,
            invitationCode: invitationCode,
            email: email
        )
    }

    private func createScheduleEmailBody(scheduleContent: String, weekDate: String?) -> String {
        let safeWeekDate = weekDate.map { ExportTextEscaping.escapeHTML($0) }
        let headerText = safeWeekDate.map { "Your Weekly Schedule - \($0)" } ?? "Your Weekly Schedule"
        let safeSchedule = ExportTextEscaping.escapeHTML(scheduleContent)
            .replacingOccurrences(of: "\n", with: "<br>")
        return """
        <html>
        <body style="font-family: Arial, sans-serif; max-width: 600px; margin: 0 auto; padding: 20px;">
            <div style="background-color: #0d67ed; color: white; padding: 20px; text-align: center; border-radius: 8px 8px 0 0;">
                <h1 style="margin: 0; font-size: 24px;">Project Planner</h1>
            </div>
            <div style="padding: 20px; background-color: #f9f9f9; border-radius: 0 0 8px 8px;">
                <h2 style="color: #0d67ed; margin-top: 0;">\(headerText)</h2>
                <div style="white-space: pre-line; line-height: 1.6; color: #333; background-color: white; padding: 15px; border-radius: 4px;">
                \(safeSchedule)
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
        
        let safeTitle = ExportTextEscaping.escapeHTML(title)
        let safeMessage = ExportTextEscaping.escapeHTML(message)
            .replacingOccurrences(of: "\n", with: "<br>")
        return """
        <html>
        <body style="font-family: Arial, sans-serif; max-width: 600px; margin: 0 auto; padding: 20px;">
            <div style="text-align: center; margin-bottom: 30px;">
                <h1 style="color: #007AFF; margin-bottom: 10px;">Project Planner</h1>
                <h2 style="color: #333; font-weight: normal;">\(safeTitle)</h2>
            </div>
            
            <div style="background-color: \(bgColor); border-left: 4px solid \(iconColor); padding: 20px; border-radius: 4px; margin: 20px 0;">
                <div style="white-space: pre-line; line-height: 1.6; color: #333;">
                \(safeMessage)
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

