//
//  PolicyAcceptanceView.swift
//  Project Planner
//
//  Created by Assistant on 06/12/2025.
//

import SwiftUI

struct PolicyAcceptanceView: View {
    @EnvironmentObject var firebaseBackend: FirebaseBackend
    @EnvironmentObject var userStore: UserStore
    @State private var hasScrolledToBottom = false
    
    var body: some View {
        PrivacyPolicyView(isAcceptanceRequired: .constant(true)) {
            acceptPolicy()
        }
        .onAppear {
            // Load current user to check policy status
            Task {
                await userStore.loadCurrentUser()
            }
        }
    }
    
    private func acceptPolicy() {
        Task {
            guard let currentUser = userStore.currentUser else {
                print("🔥🔥🔥 DEBUG: No current user to update policy acceptance")
                return
            }
            
            var updatedUser = currentUser
            updatedUser.policyAccepted = true
            updatedUser.policyAcceptedAt = Date()
            
            do {
                try await firebaseBackend.saveUser(updatedUser)
                await userStore.loadCurrentUser() // Reload to refresh UI
                print("🔥🔥🔥 DEBUG: ✅ Policy accepted and saved")
            } catch {
                print("🔥🔥🔥 DEBUG: ❌ Failed to save policy acceptance: \(error.localizedDescription)")
            }
        }
    }
}

#Preview {
    PolicyAcceptanceView()
        .environmentObject(FirebaseBackend())
        .environmentObject(UserStore())
}

