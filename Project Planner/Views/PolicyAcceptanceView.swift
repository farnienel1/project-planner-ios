//
//  PolicyAcceptanceView.swift
//  Project Planner
//
//  First-sign-in legal pack: SaaS, DPA, AUP, Privacy — matching the web app gate.
//

import SwiftUI
import FirebaseAuth
import FirebaseFirestore
import Combine

struct PolicyAcceptanceView: View {
    @EnvironmentObject var firebaseBackend: FirebaseBackend
    @EnvironmentObject var userStore: UserStore
    @State private var isAccepting = false
    @State private var acceptError: String?
    /// The ticks live outside this view (the root view owns it), so a rebuild of the gate (for example a brief
    /// "Checking your account…" while the server copy arrives) does not clear them.
    @ObservedObject var draft: PolicyAcceptanceDraft

    init(draft: PolicyAcceptanceDraft) {
        self.draft = draft
    }

    private var isSuperAdmin: Bool { userStore.currentUser?.isSuperAdmin == true }
    private var orgName: String {
        firebaseBackend.currentOrganization?.name
            ?? userStore.currentUser?.organizationId
            ?? "your organisation"
    }
    private var allDocsAccepted: Bool {
        CustomerLegalPack.documents.allSatisfy { draft.accepted[$0.id] == true }
    }
    private var canWelcome: Bool {
        allDocsAccepted && (!isSuperAdmin || draft.authorisedToBind) && !isAccepting
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

                    CustomerLegalWebLinks()

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
                            accepted: draft.accepted[document.id] == true
                        ) {
                            draft.accepted[document.id] = true
                        }
                    }

                    if isSuperAdmin {
                        Toggle(isOn: $draft.authorisedToBind) {
                            Text("I confirm that I am authorised to accept these terms on behalf of the organisation named in this account (\(orgName)).")
                                .font(.footnote)
                        }
                        .accessibilityIdentifier("policyAcceptance.iConfirmThatIAmAuthorised")
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
                    .accessibilityIdentifier("policyAcceptance.saving")
                    .disabled(!canWelcome)

                    // A way out without accepting: another organisation, sign out, or delete the account.
                    GateAccountActions(idPrefix: "policyAcceptance")
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
                .accessibilityIdentifier("policyAcceptance.ok")
        } message: {
            Text(acceptError ?? "Please try again.")
        }
        .onAppear {
            draft.keep(for: userStore.currentUser?.id)
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

                // The profile on screen is this phone's session (its company's role and rights); fall back to a
                // fresh read of users/{uid} only when nothing is on screen yet.
                var updatedUser: AppUser
                if let current = userStore.currentUser, current.id == authUser.uid {
                    updatedUser = current
                } else if let loaded = try await firebaseBackend.getUserData(userId: authUser.uid) {
                    updatedUser = loaded
                } else {
                    await MainActor.run {
                        isAccepting = false
                        acceptError = "Could not load your user profile. Please try again."
                    }
                    return
                }

                // One partial update of users/{uid} in web `LegalPackGate`'s shape, `policyAccepted: true` included
                // (`legalPackNeedsAcceptance` reads it). No full profile save: in a company other than
                // users/{uid}.organizationId that save wrote identity fields only and dropped the acceptance.
                let now = Date()
                try await firebaseBackend.recordLegalPackAcceptance(
                    userId: authUser.uid,
                    email: updatedUser.email,
                    organizationName: orgName,
                    authorisedToBind: isSuperAdmin ? draft.authorisedToBind : false,
                    acceptedAt: now
                )
                updatedUser.policyAccepted = true
                updatedUser.policyAcceptedAt = now
                updatedUser.legalPackVersion = CustomerLegalPack.version
                updatedUser.readFromLocalCache = false

                await MainActor.run {
                    userStore.applyLocalCurrentUser(updatedUser)
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
            .accessibilityIdentifier("legalDocumentCard.acknowledgement")
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
                .accessibilityIdentifier("legalDocumentCard.button")
                .buttonStyle(.plain)
            }
        }
        .padding(14)
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

#Preview {
    PolicyAcceptanceView(draft: PolicyAcceptanceDraft())
        .environmentObject(FirebaseBackend())
        .environmentObject(UserStore())
}

/// The legal gate's ticks for one signed-in person, kept across rebuilds of `PolicyAcceptanceView`.
@MainActor
final class PolicyAcceptanceDraft: ObservableObject {
    @Published var accepted: [CustomerLegalPack.DocumentID: Bool] = [
        .saas: false, .dpa: false, .aup: false, .privacy: false
    ]
    @Published var authorisedToBind = false
    private(set) var userId: String?

    /// Clears the ticks when another person is signed in.
    func keep(for userId: String?) {
        guard self.userId != userId else { return }
        self.userId = userId
        accepted = [.saas: false, .dpa: false, .aup: false, .privacy: false]
        authorisedToBind = false
    }
}

/// Shown while a cached `users/{uid}` copy says the terms need accepting and the server copy has not arrived yet
/// (`LegalGateState.checking`). Neutral: neither the app nor the terms, so an accepted account never sees the terms
/// flash and an unaccepted one never sees the app.
struct LegalGateCheckingView: View {
    var body: some View {
        VStack(spacing: 14) {
            ProgressView()
            Text("Checking your account…")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(ProjectWorksRevampColors.canvas)
        .accessibilityElement(children: .combine)
    }
}
