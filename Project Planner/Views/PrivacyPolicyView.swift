//
//  PrivacyPolicyView.swift
//  Project Planner
//
//  Created by Assistant on 06/12/2025.
//

import SwiftUI

struct PrivacyPolicyView: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var isAcceptanceRequired: Bool
    var onAccept: (() -> Void)?
    
    var body: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    // Header
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Privacy Policy & Data Protection")
                            .font(.title)
                            .fontWeight(.bold)
                        
                        Text("Last Updated: December 2025")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                    .padding(.horizontal)
                    .padding(.top)
                    
                    // Introduction
                    SectionView(title: "1. Introduction") {
                        Text("Project Planner ('we', 'our', or 'us') is committed to protecting your privacy and personal data. This Privacy Policy explains how we collect, use, store, and protect your personal information in accordance with the UK General Data Protection Regulation (UK GDPR) and the Data Protection Act 2018.")
                    }
                    
                    // Data Controller
                    SectionView(title: "2. Data Controller") {
                        Text("Project Planner is the data controller for the personal data we process. If you have any questions about this policy or our data practices, please contact us.")
                    }
                    
                    // Information We Collect
                    SectionView(title: "3. Information We Collect") {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("We collect the following types of personal data:")
                            
                            BulletPoint(text: "Name, email address, and contact information")
                            BulletPoint(text: "Mobile phone number (if provided)")
                            BulletPoint(text: "Job role, permissions, and access levels")
                            BulletPoint(text: "Project and task information")
                            BulletPoint(text: "Booking and scheduling data")
                            BulletPoint(text: "Operative skills, qualifications, and work history")
                            BulletPoint(text: "Client and project details")
                            BulletPoint(text: "Images and files uploaded in relation to tasks")
                            BulletPoint(text: "Location data for project sites")
                        }
                    }
                    
                    // How We Use Your Data
                    SectionView(title: "4. How We Use Your Data") {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("We use your personal data for the following purposes:")
                            
                            BulletPoint(text: "To provide and manage the Project Planner service")
                            BulletPoint(text: "To assign tasks and schedule work")
                            BulletPoint(text: "To communicate with you about projects and tasks")
                            BulletPoint(text: "To manage user accounts and permissions")
                            BulletPoint(text: "To generate reports and analytics")
                            BulletPoint(text: "To comply with legal obligations")
                            BulletPoint(text: "To improve our services")
                        }
                    }
                    
                    // Legal Basis
                    SectionView(title: "5. Legal Basis for Processing") {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("We process your personal data under the following legal bases:")
                            
                            BulletPoint(text: "Contract: To fulfill our service agreement with your organization")
                            BulletPoint(text: "Legitimate Interest: To manage projects, tasks, and operations efficiently")
                            BulletPoint(text: "Consent: Where you have provided explicit consent (e.g., for notifications)")
                            BulletPoint(text: "Legal Obligation: To comply with applicable laws and regulations")
                        }
                    }
                    
                    // Data Storage
                    SectionView(title: "6. Data Storage and Security") {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Your data is stored securely using:")
                            
                            BulletPoint(text: "Firebase (Google Cloud Platform) for data storage")
                            BulletPoint(text: "Encrypted data transmission (HTTPS/TLS)")
                            BulletPoint(text: "Access controls and authentication")
                            BulletPoint(text: "Regular security updates and monitoring")
                            
                            Text("\nData is stored within the European Economic Area (EEA) or in jurisdictions with adequate data protection laws.")
                                .padding(.top, 8)
                        }
                    }
                    
                    // Data Sharing
                    SectionView(title: "7. Data Sharing") {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("We may share your data with:")
                            
                            BulletPoint(text: "Other users within your organization (based on permissions)")
                            BulletPoint(text: "Service providers (e.g., Firebase, email services) who assist in operating the app")
                            BulletPoint(text: "Legal authorities if required by law")
                            
                            Text("\nWe do not sell your personal data to third parties.")
                                .padding(.top, 8)
                        }
                    }
                    
                    // Your Rights
                    SectionView(title: "8. Your Rights Under UK GDPR") {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("You have the following rights:")
                            
                            BulletPoint(text: "Right of Access: Request a copy of your personal data")
                            BulletPoint(text: "Right to Rectification: Correct inaccurate data")
                            BulletPoint(text: "Right to Erasure: Request deletion of your data (subject to legal requirements)")
                            BulletPoint(text: "Right to Restrict Processing: Limit how we use your data")
                            BulletPoint(text: "Right to Data Portability: Receive your data in a portable format")
                            BulletPoint(text: "Right to Object: Object to certain types of processing")
                            BulletPoint(text: "Rights Related to Automated Decision Making: Not applicable to our service")
                            
                            Text("\nTo exercise these rights, please contact your organization's administrator or contact us directly.")
                                .padding(.top, 8)
                        }
                    }
                    
                    // Data Retention
                    SectionView(title: "9. Data Retention") {
                        Text("We retain your personal data for as long as necessary to provide our services and comply with legal obligations. When you leave an organization or your account is deleted, we will delete or anonymize your personal data within 30 days, unless we are required to retain it for legal purposes.")
                    }
                    
                    // Cookies and Tracking
                    SectionView(title: "10. Cookies and Tracking") {
                        Text("Project Planner uses essential cookies and local storage to maintain your session and preferences. We do not use third-party tracking cookies or advertising trackers.")
                    }
                    
                    // International Transfers
                    SectionView(title: "11. International Data Transfers") {
                        Text("Your data may be processed outside the UK/EEA by our service providers (e.g., Firebase/Google Cloud). We ensure appropriate safeguards are in place, including Standard Contractual Clauses and adequacy decisions.")
                    }
                    
                    // Children's Data
                    SectionView(title: "12. Children's Data") {
                        Text("Project Planner is intended for business use and is not directed at individuals under 18 years of age. We do not knowingly collect personal data from children.")
                    }
                    
                    // Changes to Policy
                    SectionView(title: "13. Changes to This Policy") {
                        Text("We may update this Privacy Policy from time to time. We will notify you of significant changes and update the 'Last Updated' date. Continued use of the app after changes constitutes acceptance of the updated policy.")
                    }
                    
                    // Contact
                    SectionView(title: "14. Contact Us") {
                        Text("If you have questions about this Privacy Policy or wish to exercise your rights, please contact:\n\nYour Organization Administrator\n\nOr the Project Planner support team.")
                    }
                    
                    // Acceptance Button (only if required)
                    if isAcceptanceRequired {
                        VStack(spacing: 16) {
                            Divider()
                                .padding(.vertical)
                            
                            Button(action: {
                                onAccept?()
                            }) {
                                Text("I Accept")
                                    .font(.headline)
                                    .foregroundColor(.white)
                                    .frame(maxWidth: .infinity)
                                    .padding()
                                    .background(Color.blue)
                                    .cornerRadius(12)
                            }
                            .padding(.horizontal)
                            .padding(.bottom)
                        }
                    }
                }
            }
            .navigationTitle("Privacy Policy")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if !isAcceptanceRequired {
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button("Done") {
                            dismiss()
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Supporting Views

struct SectionView<Content: View>: View {
    let title: String
    let content: Content
    
    init(title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.headline)
                .fontWeight(.semibold)
            
            content
                .font(.body)
                .foregroundColor(.primary)
        }
        .padding(.horizontal)
    }
}

struct BulletPoint: View {
    let text: String
    
    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Text("•")
                .font(.body)
            Text(text)
                .font(.body)
        }
    }
}

#Preview {
    PrivacyPolicyView(isAcceptanceRequired: .constant(true))
}

