//
//  PolicyAcceptanceView.swift
//  Project Planner
//
//  Created by Assistant on 06/12/2025.
//

import SwiftUI
import FirebaseAuth

struct PolicyAcceptanceView: View {
    @EnvironmentObject var firebaseBackend: FirebaseBackend
    @EnvironmentObject var userStore: UserStore
    @State private var isAccepting = false
    @State private var acceptError: String?
    
    var body: some View {
        PrivacyPolicyView(isAcceptanceRequired: .constant(true)) {
            acceptPolicy()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemGroupedBackground))
        .overlay(alignment: .bottom) {
            if isAccepting {
                ProgressView("Saving acceptance…")
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(.ultraThinMaterial)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .padding(.bottom, 16)
            }
        }
        .alert("Could not save acceptance", isPresented: Binding(
            get: { acceptError != nil },
            set: { if !$0 { acceptError = nil } }
        )) {
            Button("OK", role: .cancel) { acceptError = nil }
        } message: {
            Text(acceptError ?? "Please try again.")
        }
        .onAppear {
            // Load current user to check policy status
            Task {
                await userStore.loadCurrentUser()
            }
        }
    }
    
    private func acceptPolicy() {
        guard !isAccepting else { return }
        isAccepting = true
        acceptError = nil
        Task {
            do {
                guard let authUser = firebaseBackend.currentUser else {
                    await MainActor.run {
                        isAccepting = false
                        acceptError = "You are not signed in. Please sign in again."
                    }
                    return
                }

                var updatedUser: AppUser
                if let loaded = try await firebaseBackend.getUserData(userId: authUser.uid) {
                    updatedUser = loaded
                } else if let current = userStore.currentUser {
                    updatedUser = current
                } else {
                    await MainActor.run {
                        isAccepting = false
                        acceptError = "Could not load your user profile. Please try again."
                    }
                    return
                }

                updatedUser.policyAccepted = true
                updatedUser.policyAcceptedAt = Date()
                try await firebaseBackend.saveUser(updatedUser)

                await MainActor.run {
                    // Update local state immediately so app exits policy screen without waiting on reload.
                    userStore.currentUser = updatedUser
                    isAccepting = false
                }
                await userStore.loadCurrentUser()
            } catch {
                await MainActor.run {
                    isAccepting = false
                    acceptError = error.localizedDescription
                }
            }
        }
    }
}

#Preview {
    PolicyAcceptanceView()
        .environmentObject(FirebaseBackend())
        .environmentObject(UserStore())
}

