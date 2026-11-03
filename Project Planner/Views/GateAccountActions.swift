//
//  GateAccountActions.swift
//  Project Planner
//
//  The way out of every screen that stands in front of the app (customer terms, subscription not active, account
//  deactivated, no organisation): Switch organisation, Sign out and Delete my account (App Review 5.1.1(v): an
//  account can be deleted from inside the app wherever the person is stuck).
//

import SwiftUI

struct GateAccountActions: View {
    @EnvironmentObject var firebaseBackend: FirebaseBackend
    @EnvironmentObject var userStore: UserStore

    var showsSwitchOrganisation = true
    var showsSignOut = true
    /// False on the deleted-organisation screen (RULEBOOK 1.15.0 §20: Sign out, and Switch organisation, only).
    var showsDeleteAccount = true
    var idPrefix: String

    @State private var showingSwitchOrganisation = false
    @State private var showingDeleteAccount = false
    @State private var showingSignOut = false

    var body: some View {
        VStack(spacing: 14) {
            if showsSwitchOrganisation {
                Button("Switch organisation") { showingSwitchOrganisation = true }
                    .accessibilityIdentifier("\(idPrefix).switchOrganisation")
                    .font(.system(size: 15, weight: .semibold))
            }
            if showsSignOut {
                Button("Sign Out") { showingSignOut = true }
                    .accessibilityIdentifier("\(idPrefix).signOut")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Color.red)
            }
            if showsDeleteAccount {
                Button("Delete my account") { showingDeleteAccount = true }
                    .accessibilityIdentifier("\(idPrefix).deleteMyAccount")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Color.red.opacity(0.85))
            }
        }
        .frame(maxWidth: .infinity)
        .signOutConfirmation(
            isPresented: $showingSignOut,
            firebaseBackend: firebaseBackend,
            userStore: userStore,
            idPrefix: "\(idPrefix).signOutConfirm"
        )
        .sheet(isPresented: $showingSwitchOrganisation) {
            NavigationStack {
                SwitchOrganisationView()
                    .environmentObject(firebaseBackend)
                    .environmentObject(userStore)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Close") { showingSwitchOrganisation = false }
                                .accessibilityIdentifier("\(idPrefix).closeSwitch")
                        }
                    }
            }
        }
        .sheet(isPresented: $showingDeleteAccount) {
            NavigationStack {
                DeleteMyAccountView()
                    .environmentObject(firebaseBackend)
                    .environmentObject(userStore)
                    .navigationTitle("Delete my account")
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Close") { showingDeleteAccount = false }
                                .accessibilityIdentifier("\(idPrefix).closeDelete")
                        }
                    }
            }
        }
    }
}

/// Signed in, but the account belongs to no organisation (`FirebaseBackend.sessionHasNoOrganization`).
struct NoOrganisationView: View {
    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Spacer()
                VStack(spacing: 18) {
                    Image(systemName: "building.2")
                        .font(.system(size: 44, weight: .regular))
                        .foregroundStyle(ProjectWorksRevampColors.muted)
                    Text("You're not a member of an organisation yet")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(ProjectWorksRevampColors.ink)
                        .multilineTextAlignment(.center)
                        .accessibilityIdentifier("noOrganisation.title")
                    Text("Ask your company administrator to invite you, then sign in again or switch organisation.")
                        .font(.system(size: 15))
                        .foregroundStyle(ProjectWorksRevampColors.muted)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(24)
                .frame(maxWidth: 420)
                Spacer()
                GateAccountActions(idPrefix: "noOrganisation")
                    .padding(.bottom, 28)
            }
            .padding(.horizontal, 24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(ProjectWorksRevampColors.canvas.ignoresSafeArea())
            .navigationBarHidden(true)
        }
    }
}

/// RULEBOOK 1.15.0 §20: the open organisation is scheduled for erasure or erased (`organizationDeletionState`). Every
/// member sees `organizationDeletedMessage` and nothing else: Sign out, and Switch organisation when they belong to
/// another company. iOS never shows Restore, deletion or billing controls, or prices.
struct OrganizationDeletedView: View {
    @EnvironmentObject var firebaseBackend: FirebaseBackend
    @EnvironmentObject var userStore: UserStore
    let organization: Organization

    @State private var hasAnotherOrganisation = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Spacer()
                VStack(spacing: 18) {
                    Image(systemName: "building.2.crop.circle")
                        .font(.system(size: 44, weight: .regular))
                        .foregroundStyle(ProjectWorksRevampColors.muted)
                    Text(organization.name)
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(ProjectWorksRevampColors.ink)
                        .multilineTextAlignment(.center)
                    Text(organization.deletedMessage)
                        .font(.system(size: 15))
                        .foregroundStyle(ProjectWorksRevampColors.muted)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("organizationDeleted.message")
                }
                .padding(24)
                .frame(maxWidth: 420)
                Spacer()
                GateAccountActions(
                    showsSwitchOrganisation: hasAnotherOrganisation,
                    showsDeleteAccount: false,
                    idPrefix: "organizationDeleted"
                )
                .padding(.bottom, 28)
            }
            .padding(.horizontal, 24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(ProjectWorksRevampColors.canvas.ignoresSafeArea())
            .navigationBarHidden(true)
            .task(id: organization.firestoreDocumentId) {
                let memberships = await firebaseBackend.fetchOrganizationsForCurrentUser()
                hasAnotherOrganisation = memberships.contains {
                    !organizationIdsMatch($0.id, organization.firestoreDocumentId)
                }
            }
        }
    }
}
