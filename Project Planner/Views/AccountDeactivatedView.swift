//
//  AccountDeactivatedView.swift
//  Project Planner
//
//  Blocks the main app when the last-used organisation has deactivated the signed-in user.
//  Firebase Auth stays signed in.
//

import SwiftUI

struct AccountDeactivatedView: View {
    @EnvironmentObject var firebaseBackend: FirebaseBackend
    @EnvironmentObject var userStore: UserStore

    @State private var otherOrganisations: [OrgMembershipSummary] = []
    @State private var isLoadingOrganisations = true
    @State private var showingSwitchOrganisation = false

    private var lastUsedOrganizationId: String {
        userStore.lastUsedOrganizationId
    }

    private var canSwitchOrganisation: Bool {
        !isLoadingOrganisations && !otherOrganisations.isEmpty
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Spacer()
                VStack(spacing: 20) {
                    Image(systemName: "person.crop.circle.badge.xmark")
                        .font(.system(size: 44, weight: .regular))
                        .foregroundStyle(ProjectWorksRevampColors.muted)
                    Text("Your account has been deactivated, please contact your organisation")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(ProjectWorksRevampColors.ink)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                    if isLoadingOrganisations {
                        ProgressView()
                            .padding(.top, 4)
                    } else if canSwitchOrganisation {
                        Button("Switch organisation") {
                            showingSwitchOrganisation = true
                        }
                        .accessibilityIdentifier("accountDeactivated.switchOrganisation")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(ProjectWorksRevampColors.blue)
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
                }
                .padding(24)
                .frame(maxWidth: 420)
                Spacer()
                Button("Sign Out") {
                    AppSignOut.perform(firebaseBackend: firebaseBackend, userStore: userStore)
                }
                .accessibilityIdentifier("accountDeactivated.signOut")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Color.red)
                .padding(.bottom, 28)
            }
            .padding(.horizontal, 24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(ProjectWorksRevampColors.canvas.ignoresSafeArea())
            .navigationBarHidden(true)
            .sheet(isPresented: $showingSwitchOrganisation) {
                NavigationStack {
                    SwitchOrganisationView(excludedOrganizationId: lastUsedOrganizationId)
                        .environmentObject(firebaseBackend)
                        .environmentObject(userStore)
                        .toolbar {
                            ToolbarItem(placement: .cancellationAction) {
                                Button("Close") { showingSwitchOrganisation = false }
                                    .accessibilityIdentifier("accountDeactivated.close")
                            }
                        }
                }
            }
            .task {
                await reloadOtherOrganisations()
            }
            .onChange(of: userStore.lastUsedOrganizationId) { _, _ in
                Task { await reloadOtherOrganisations() }
            }
        }
    }

    @MainActor
    private func reloadOtherOrganisations() async {
        isLoadingOrganisations = true
        let excluded = lastUsedOrganizationId
        let all = await firebaseBackend.fetchOrganizationsForCurrentUser()
        otherOrganisations = all.filter { membership in
            guard !excluded.isEmpty else { return true }
            return membership.id.compare(excluded, options: [.caseInsensitive, .diacriticInsensitive]) != .orderedSame
        }
        isLoadingOrganisations = false
    }
}
