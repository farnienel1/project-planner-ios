//
//  SubscriptionLapsedView.swift
//  Project Planner
//
//  Replaces the main experience while the current organisation's canonical hasAccess is false.
//  The signed-in session stays. Renewal is not a link, and this screen does not transfer super admin.
//

import SwiftUI

struct SubscriptionLapsedView: View {
    @EnvironmentObject var firebaseBackend: FirebaseBackend
    @EnvironmentObject var userStore: UserStore

    @State private var showingSwitchOrganisation = false

    private var isSuperAdmin: Bool {
        userStore.currentUser?.isSuperAdmin == true
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Spacer()
                VStack(spacing: 20) {
                    Image(systemName: "exclamationmark.circle")
                        .font(.system(size: 44, weight: .regular))
                        .foregroundStyle(ProjectWorksRevampColors.muted)
                    Text(SubscriptionLapsedCopy.headline)
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(ProjectWorksRevampColors.ink)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("subscriptionLapsed.headline")
                    Text(SubscriptionLapsedCopy.detail(isSuperAdmin: isSuperAdmin))
                        .font(.system(size: 15, weight: .regular))
                        .foregroundStyle(ProjectWorksRevampColors.muted)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("subscriptionLapsed.detail")
                    Button("Switch organisation") {
                        showingSwitchOrganisation = true
                    }
                    .accessibilityIdentifier("subscriptionLapsed.switchOrganisation")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(ProjectWorksRevampColors.blue)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                .padding(24)
                .frame(maxWidth: 420)
                Spacer()
                Button("Sign Out") {
                    AppSignOut.perform(firebaseBackend: firebaseBackend, userStore: userStore)
                }
                .accessibilityIdentifier("subscriptionLapsed.signOut")
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
                    SwitchOrganisationView()
                        .environmentObject(firebaseBackend)
                        .environmentObject(userStore)
                        .toolbar {
                            ToolbarItem(placement: .cancellationAction) {
                                Button("Close") { showingSwitchOrganisation = false }
                                    .accessibilityIdentifier("subscriptionLapsed.close")
                            }
                        }
                }
            }
        }
    }
}
