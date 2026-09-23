//
//  PolicyAcceptanceView.swift
//  Project Planner
//
//  First-sign-in legal pack: SaaS, DPA, AUP, Privacy — matching the web app gate.
//

import SwiftUI
import FirebaseAuth
import FirebaseFirestore

struct PolicyAcceptanceView: View {
    @EnvironmentObject var firebaseBackend: FirebaseBackend
    @EnvironmentObject var userStore: UserStore
    @State private var isAccepting = false
    @State private var acceptError: String?
    @State private var accepted: [CustomerLegalPack.DocumentID: Bool] = [
        .saas: false, .dpa: false, .aup: false, .privacy: false
    ]
    @State private var authorisedToBind = false

    private var isSuperAdmin: Bool { userStore.currentUser?.isSuperAdmin == true }
    private var orgName: String {
        firebaseBackend.currentOrganization?.name
            ?? userStore.currentUser?.organizationId
            ?? "your organisation"
    }
    private var allDocsAccepted: Bool {
        CustomerLegalPack.documents.allSatisfy { accepted[$0.id] == true }
    }
    private var canWelcome: Bool {
        allDocsAccepted && (!isSuperAdmin || authorisedToBind) && !isAccepting
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Welcome — please review the customer terms")
                            .font(.title2.weight(.bold))
                        Text("Before you enter \(orgName), scroll through each document and accept it. Privacy is an acknowledgement of receipt, not a blanket consent to processing.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Text(CustomerLegalPack.summary)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Text(CustomerLegalPack.toolboxTalkDisclaimer)
                        .font(.footnote)
                        .foregroundStyle(.primary)
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.orange.opacity(0.12))
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

                    ForEach(CustomerLegalPack.documents) { document in
                        LegalDocumentCard(
                            document: document,
                            accepted: accepted[document.id] == true
                        ) {
                            accepted[document.id] = true
                        }
                    }

                    if isSuperAdmin {
                        Toggle(isOn: $authorisedToBind) {
                            Text("I confirm that I am authorised to accept these terms on behalf of the organisation named in this account (\(orgName)).")
                                .font(.footnote)
                        }
                        .padding(12)
                        .background(Color(.secondarySystemBackground))
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }

                    Button(action: acceptPolicy) {
                        Text(isAccepting ? "Saving…" : "Welcome to Project Planner")
                            .font(.headline)
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(canWelcome ? Color.blue : Color.gray)
                            .cornerRadius(12)
                    }
                    .disabled(!canWelcome)
                    .padding(.bottom, 24)
                }
                .padding(16)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Customer terms")
            .navigationBarTitleDisplayMode(.inline)
        }
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
            Task { await userStore.loadCurrentUser() }
        }
    }

    private func acceptPolicy() {
        guard canWelcome else { return }
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

                let now = Date()
                updatedUser.policyAccepted = true
                updatedUser.policyAcceptedAt = now
                updatedUser.legalPackVersion = CustomerLegalPack.version
                try await firebaseBackend.saveUser(updatedUser)
                try await firebaseBackend.recordLegalPackAcceptance(
                    userId: authUser.uid,
                    email: updatedUser.email,
                    organizationName: orgName,
                    authorisedToBind: isSuperAdmin ? authorisedToBind : false
                )

                await MainActor.run {
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

struct LegalDocumentCard: View {
    let document: CustomerLegalPack.Document
    let accepted: Bool
    let onAccept: () -> Void
    @State private var expanded = true

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                expanded.toggle()
            } label: {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(document.title)
                            .font(.headline)
                            .foregroundStyle(.primary)
                        Text(document.acknowledgeOnly ? "Acknowledgement" : "Agreement")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                        .foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.plain)

            if expanded {
                Text(document.intro)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Text(document.body)
                    .font(.footnote)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            if accepted {
                Label("Accepted", systemImage: "checkmark.circle.fill")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.green)
            } else {
                Button(action: onAccept) {
                    Text(document.acceptLabel)
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(Color.blue)
                        .foregroundStyle(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(14)
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

#Preview {
    PolicyAcceptanceView()
        .environmentObject(FirebaseBackend())
        .environmentObject(UserStore())
}
