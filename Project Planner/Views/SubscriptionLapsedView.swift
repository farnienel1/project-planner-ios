//
//  SubscriptionLapsedView.swift
//  Project Planner
//
//  Replaces the main experience while `subscriptionAccess` (RULEBOOK 1.13.0 §19) is not `open`: everyone sees
//  `SUBSCRIPTION_LAPSED_MESSAGE` only, admins included (1.14.0; the admin note is web only). The session stays; Sign out,
//  Switch organisation and Delete my account remain. Never a link or a price; nothing is deleted.
//

import SwiftUI

struct SubscriptionLapsedView: View {
    @EnvironmentObject var firebaseBackend: FirebaseBackend
    @EnvironmentObject var userStore: UserStore

    @State private var showingSwitchOrganisation = false

    private var isAdmin: Bool {
        userStore.currentUser?.isRosterAdmin == true
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
                    if let detail = SubscriptionLapsedCopy.detail(isAdmin: isAdmin) {
                        Text(detail)
                            .font(.system(size: 15, weight: .regular))
                            .foregroundStyle(ProjectWorksRevampColors.muted)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("subscriptionLapsed.detail")
                    }
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
                // Sign out (asks first) and Delete my account (App Review 5.1.1(v)).
                GateAccountActions(showsSwitchOrganisation: false, idPrefix: "subscriptionLapsed")
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
