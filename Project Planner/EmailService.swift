//
//  EmailService.swift
//  Project Planner
//
//  Created by Assistant on 30/09/2025.
//

import Foundation
import MessageUI
import Combine

class EmailService: NSObject, ObservableObject {
    static let shared = EmailService()
    
    @Published var isSending = false
    @Published var lastError: String?
    
    private override init() {
        super.init()
    }
    
    // Microsoft 365 Email Configuration
    private let fromEmail = "info@raccordmep.co.uk"
    private let fromPassword = "Raccord50!"
    private let smtpServer = "smtp.office365.com"
    private let smtpPort = 587
    
    // Cloud-based email sending using SMTP
    func sendEmail(recipient: String, subject: String, body: String) async -> Bool {
        await MainActor.run {
            isSending = true
            lastError = nil
        }
        
        let success = await sendEmailViaSMTP(recipient: recipient, subject: subject, body: body)
        
        await MainActor.run {
            isSending = false
        }
        
        return success
    }
    
    private func sendEmailViaSMTP(recipient: String, subject: String, body: String) async -> Bool {
        // Use the cloud email service for sending
        return await CloudEmailService.shared.sendEmail(
            recipient: recipient,
            subject: subject,
            body: body
        )
    }
    
    // Fallback to device mail composer if cloud email fails
    func createEmailComposer(recipient: String, subject: String, body: String) -> UIViewController {
        if MFMailComposeViewController.canSendMail() {
            let mailComposer = MFMailComposeViewController()
            mailComposer.mailComposeDelegate = self
            
            // Set up the email
            mailComposer.setToRecipients([recipient])
            mailComposer.setSubject(subject)
            mailComposer.setMessageBody(body, isHTML: false)
            
            return mailComposer
        } else {
            // Show an alert if mail is not available
            let alert = UIAlertController(
                title: "Email Not Available",
                message: "Email sending is not available on this device. The schedule has been prepared but cannot be sent automatically.",
                preferredStyle: .alert
            )
            alert.addAction(UIAlertAction(title: "OK", style: .default))
            return alert
        }
    }
}

// MARK: - MFMailComposeViewControllerDelegate
extension EmailService: MFMailComposeViewControllerDelegate {
    func mailComposeController(_ controller: MFMailComposeViewController, didFinishWith result: MFMailComposeResult, error: Error?) {
        controller.dismiss(animated: true)
    }
}

// MARK: - Email Configuration Helper
struct EmailConfiguration {
    static let smtpServer = "smtp.office365.com"
    static let smtpPort = 587
    static let fromEmail = "info@raccordmep.co.uk"
    static let fromPassword = "Raccord50!"
    static let useTLS = true
    static let useAuth = true
}
