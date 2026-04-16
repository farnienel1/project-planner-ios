//
//  WarningsDetailView.swift
//  Project Planner
//
//  Created by Assistant on 23/10/2025.
//

import SwiftUI
import FirebaseFirestore

struct WarningsDetailView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var warningsService: WarningsService
    @EnvironmentObject var projectStore: ProjectStore
    @EnvironmentObject var userStore: UserStore
    @EnvironmentObject var operativeStore: OperativeStore
    
    var body: some View {
        NavigationView {
            Group {
                if warningsService.warnings.isEmpty {
                    emptyStateView
                } else {
                    warningsList
                }
            }
            .navigationTitle("Warnings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
    }
    
    private var emptyStateView: some View {
        VStack(spacing: 20) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 60))
                .foregroundColor(.green)
            
            Text("No Warnings")
                .font(.title2)
                .fontWeight(.semibold)
            
            Text("All systems are running smoothly. No warnings to display.")
                .font(.body)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }
    
    private var warningsList: some View {
        ScrollView {
            VStack(spacing: 20) {
                if !qualificationWarnings.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Qualification Expiry")
                            .font(.title3)
                            .fontWeight(.semibold)
                            .padding(.horizontal)
                        
                        ForEach(qualificationWarnings) { warning in
                            WarningTileView(warning: warning)
                                .environmentObject(projectStore)
                        }
                    }
                }
                
                if !bookingClashWarnings.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Booking Clashes")
                            .font(.title3)
                            .fontWeight(.semibold)
                            .padding(.horizontal)
                        
                        ForEach(bookingClashWarnings) { warning in
                            WarningTileView(warning: warning)
                                .environmentObject(projectStore)
                        }
                    }
                }
                
                if !operativeNotVerifiedWarnings.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Unverified Operatives")
                            .font(.title3)
                            .fontWeight(.semibold)
                            .padding(.horizontal)
                        
                        ForEach(operativeNotVerifiedWarnings) { warning in
                            WarningTileView(warning: warning)
                                .environmentObject(projectStore)
                                .environmentObject(userStore)
                                .environmentObject(operativeStore)
                        }
                    }
                }
            }
            .padding(.vertical)
        }
    }
    
    private var qualificationWarnings: [Warning] {
        warningsService.warnings.filter { $0.type == .qualificationExpiry }
            .sorted { severityOrder($0.severity) > severityOrder($1.severity) }
    }
    
    private func severityOrder(_ severity: Warning.WarningSeverity) -> Int {
        switch severity {
        case .low: return 1
        case .medium: return 2
        case .high: return 3
        }
    }
    
    private var bookingClashWarnings: [Warning] {
        warningsService.warnings.filter { $0.type == .bookingClash }
    }
    
    private var operativeNotVerifiedWarnings: [Warning] {
        warningsService.warnings.filter { $0.type == .operativeNotVerified }
    }
}

struct WarningTileView: View {
    let warning: Warning
    @EnvironmentObject var projectStore: ProjectStore
    @EnvironmentObject var userStore: UserStore
    @EnvironmentObject var operativeStore: OperativeStore
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header with icon and severity
            HStack {
                ZStack {
                    Circle()
                        .fill(severityColor.opacity(0.15))
                        .frame(width: 40, height: 40)
                    
                    Image(systemName: iconName)
                        .font(.title3)
                        .foregroundColor(severityColor)
                }
                
                Spacer()
                
                Text(severityText)
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundColor(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(severityColor)
                    .cornerRadius(8)
            }
            
            if warning.type == .bookingClash, let clashDetails = warning.bookingClashDetails {
                // Booking Clash Details
                VStack(alignment: .leading, spacing: 8) {
                    Text("Booking Clash")
                        .font(.headline)
                        .foregroundColor(.primary)
                    
                    Divider()
                    
                    // Users
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Users")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .textCase(.uppercase)
                        Text("\(clashDetails.user1Name) & \(clashDetails.user2Name)")
                            .font(.body)
                            .foregroundColor(.primary)
                    }
                    
                    Divider()
                    
                    // Projects/Small Works
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Projects / Small Works")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .textCase(.uppercase)
                        
                        if let project1Num = clashDetails.project1Number, let project1Name = clashDetails.project1Name {
                            Text("\(project1Num) - \(project1Name)")
                                .font(.body)
                                .foregroundColor(.primary)
                        } else if let smallWork1Num = clashDetails.smallWork1Number, let smallWork1Name = clashDetails.smallWork1Name {
                            Text("\(smallWork1Num) - \(smallWork1Name)")
                                .font(.body)
                                .foregroundColor(.primary)
                        }
                        
                        if let project2Num = clashDetails.project2Number, let project2Name = clashDetails.project2Name {
                            Text("\(project2Num) - \(project2Name)")
                                .font(.body)
                                .foregroundColor(.primary)
                        } else if let smallWork2Num = clashDetails.smallWork2Number, let smallWork2Name = clashDetails.smallWork2Name {
                            Text("\(smallWork2Num) - \(smallWork2Name)")
                                .font(.body)
                                .foregroundColor(.primary)
                        }
                    }
                    
                    Divider()
                    
                    // Time Slots
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Time Slots")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .textCase(.uppercase)
                        Text("\(clashDetails.timeSlot1) & \(clashDetails.timeSlot2)")
                            .font(.body)
                            .foregroundColor(.primary)
                    }
                    
                    Divider()
                    
                    // Date
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Date")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .textCase(.uppercase)
                        Text(clashDetails.date, style: .date)
                            .font(.body)
                            .foregroundColor(.primary)
                    }
                    
                    Divider()
                    
                    // Operative
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Operative")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .textCase(.uppercase)
                        Text(clashDetails.operativeName)
                            .font(.body)
                            .foregroundColor(.primary)
                    }
                }
            } else if warning.type == .operativeNotVerified {
                // Operative Not Verified Warning
                VStack(alignment: .leading, spacing: 12) {
                    Text(warning.message)
                        .font(.body)
                        .foregroundColor(.primary)
                    
                    // Resend verification button (only for admins/super admins)
                    if userStore.hasAdminAccess() {
                        Button(action: {
                            resendVerificationEmail(for: warning)
                        }) {
                            HStack {
                                Image(systemName: "envelope.fill")
                                Text("Resend Verification Email")
                            }
                            .font(.subheadline)
                            .fontWeight(.semibold)
                            .foregroundColor(.white)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 10)
                            .background(Color.blue)
                            .cornerRadius(10)
                        }
                    }
                }
            } else {
                // Qualification Expiry or other warnings
                Text(warning.message)
                    .font(.body)
                    .foregroundColor(.primary)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.systemBackground))
        .cornerRadius(16)
        .shadow(color: severityColor.opacity(0.2), radius: 8, x: 0, y: 2)
        .padding(.horizontal)
    }
    
    private var iconName: String {
        switch warning.type {
        case .qualificationExpiry:
            return "exclamationmark.triangle.fill"
        case .bookingClash:
            return "calendar.badge.exclamationmark"
        case .operativeNotVerified:
            return "person.crop.circle.badge.exclamationmark"
        }
    }
    
    private func resendVerificationEmail(for warning: Warning) {
        // Use the stored operative email from the warning
        guard let operativeEmail = warning.operativeEmail else { return }
        
        // Find the AppUser for this operative
        if let operativeUser = userStore.organizationUsers.first(where: { user in
            user.email.lowercased() == operativeEmail.lowercased() && user.permissions.operativeMode
        }) {
            // Always create a brand new invitation and send (never reuse old link)
            Task {
                let db = Firestore.firestore()
                do {
                    // Mark all existing invitations for this email as used so only the new link works
                    let existing = try await db.collection("invitations")
                        .whereField("email", isEqualTo: operativeUser.email)
                        .getDocuments()
                    for doc in existing.documents {
                        try? await doc.reference.updateData(["isUsed": true])
                    }

                    let invitationId = UUID().uuidString
                    var invitationData: [String: Any] = [
                        "email": operativeUser.email,
                        "organizationId": operativeUser.organizationId,
                        "invitedBy": userStore.currentUser?.email ?? "System",
                        "firstName": operativeUser.firstName,
                        "surname": operativeUser.surname,
                        "permissions": [
                            "adminAccess": operativeUser.permissions.adminAccess,
                            "manager": operativeUser.permissions.manager,
                            "operatives": operativeUser.permissions.operatives,
                            "skills": operativeUser.permissions.skills,
                            "qualifications": operativeUser.permissions.qualifications,
                            "projects": operativeUser.permissions.projects,
                            "smallWorks": operativeUser.permissions.smallWorks,
                            "operativeMode": operativeUser.permissions.operativeMode
                        ],
                        "createdAt": Timestamp(date: Date()),
                        "isUsed": false
                    ]
                    if let mobileNumber = operativeUser.mobileNumber {
                        invitationData["mobileNumber"] = mobileNumber
                    }
                    try await db.collection("invitations").document(invitationId).setData(invitationData)

                    await userStore.resendInvitationEmail(
                        email: operativeUser.email,
                        firstName: operativeUser.firstName,
                        surname: operativeUser.surname,
                        invitationId: invitationId
                    )
                } catch {
                    print("🔥🔥🔥 DEBUG: Error creating/sending invitation: \(error)")
                }
            }
        }
    }
    
    private var severityColor: Color {
        switch warning.severity {
        case .low:
            return .yellow
        case .medium:
            return .orange
        case .high:
            return .red
        }
    }
    
    private var severityText: String {
        switch warning.severity {
        case .low:
            return "Low Priority"
        case .medium:
            return "Medium Priority"
        case .high:
            return "High Priority"
        }
    }
}


#Preview {
    let service = WarningsService()
    service.warnings = [
        Warning(type: .qualificationExpiry, message: "John Doe's CSCS Card expires in 15 days", severity: .medium),
        Warning(type: .bookingClash, message: "Manager A, Manager B: Project1, Project2 - AM", severity: .high)
    ]
    return WarningsDetailView(warningsService: service)
}

