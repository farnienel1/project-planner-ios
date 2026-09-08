//
//  SwitchOrganisationView.swift
//  Project Planner
//
//  Lets any signed-in user switch between organisations they belong to.
//

import SwiftUI

struct SwitchOrganisationView: View {
    @EnvironmentObject var firebaseBackend: FirebaseBackend
    @EnvironmentObject var userStore: UserStore
    @Environment(\.dismiss) private var dismiss

    @State private var memberships: [OrgMembershipSummary] = []
    @State private var isLoading = true
    @State private var isSwitching = false
    @State private var errorMessage: String?
    @State private var switchingOrgId: String?

    private var activeOrgId: String? {
        firebaseBackend.currentOrganization?.firestoreDocumentId
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                introCard
                    .padding(.top, 8)

                if isLoading {
                    ProgressView("Loading organisations…")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 28)
                } else if memberships.isEmpty {
                    emptyState
                } else {
                    sectionTitle("Your organisations")
                    membershipList
                }

                if let errorMessage, !errorMessage.isEmpty {
                    Text(errorMessage)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Color.red)
                        .padding(.top, 12)
                }
            }
            .padding(.horizontal, 18)
            .padding(.bottom, 28)
        }
        .background(ProjectWorksRevampColors.canvas.ignoresSafeArea())
        .navigationTitle("Switch organisation")
        .navigationBarTitleDisplayMode(.inline)
        .appChromeNavigationBarSurface()
        .task {
            await reloadMemberships()
        }
        .refreshable {
            await reloadMemberships()
        }
    }

    private var introCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Work across teams")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(ProjectWorksRevampColors.ink)
            Text("Choose which organisation you want to use in the app. Your schedule, projects, and settings will update to match.")
                .font(.system(size: 12))
                .foregroundStyle(ProjectWorksRevampColors.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .appChromeCardContainer(cornerRadius: 16)
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("No organisations found")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(ProjectWorksRevampColors.ink)
            Text("If you were invited to another organisation, pull to refresh or sign out and sign in again.")
                .font(.system(size: 12))
                .foregroundStyle(ProjectWorksRevampColors.muted)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .appChromeCardContainer(cornerRadius: 16)
        .padding(.top, 16)
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(ProjectWorksRevampColors.muted)
            .tracking(0.4)
            .padding(.leading, 4)
            .padding(.top, 20)
            .padding(.bottom, 10)
    }

    private var membershipList: some View {
        VStack(spacing: 0) {
            ForEach(memberships) { membership in
                membershipRow(membership)
                if membership.id != memberships.last?.id {
                    Divider().background(ProjectWorksRevampColors.border).padding(.leading, 62)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 4)
        .appChromeCardContainer(cornerRadius: 18)
    }

    private func membershipRow(_ membership: OrgMembershipSummary) -> some View {
        let isActive = membership.id == activeOrgId
        let isBusy = isSwitching && switchingOrgId == membership.id
        return Button {
            guard !isActive, !isSwitching else { return }
            Task { await switchToOrganisation(membership) }
        } label: {
            HStack(spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(isActive ? ProjectWorksRevampColors.blue.opacity(0.14) : ProjectWorksRevampColors.jobTypePillBg)
                        .frame(width: 36, height: 36)
                    Image(systemName: "building.2.fill")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(isActive ? ProjectWorksRevampColors.blue : ProjectWorksRevampColors.jobTypePillInk)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(membership.name)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(ProjectWorksRevampColors.ink)
                        .multilineTextAlignment(.leading)
                    HStack(spacing: 6) {
                        Text(membership.roleDisplayName)
                        if membership.isTrial {
                            Text("Trial")
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(ProjectWorksRevampColors.upcomingAmber.opacity(0.18))
                                .clipShape(Capsule())
                        }
                        if membership.trialAccessBlocked {
                            Text("Locked")
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.red.opacity(0.12))
                                .clipShape(Capsule())
                        }
                    }
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(ProjectWorksRevampColors.muted)
                }
                Spacer(minLength: 8)
                if isBusy {
                    ProgressView()
                        .controlSize(.small)
                } else if isActive {
                    Text("Active")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(ProjectWorksRevampColors.blue)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(ProjectWorksRevampColors.blue.opacity(0.12))
                        .clipShape(Capsule())
                } else if !membership.isActive {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color.red.opacity(0.8))
                } else {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(ProjectWorksRevampColors.placeholderInk)
                }
            }
            .padding(.vertical, 13)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isActive || isSwitching || !membership.isActive)
    }

    @MainActor
    private func reloadMemberships() async {
        isLoading = true
        errorMessage = nil
        memberships = await firebaseBackend.fetchOrganizationsForCurrentUser()
        isLoading = false
    }

    @MainActor
    private func switchToOrganisation(_ membership: OrgMembershipSummary) async {
        isSwitching = true
        switchingOrgId = membership.id
        errorMessage = nil
        defer {
            isSwitching = false
            switchingOrgId = nil
        }
        do {
            try await firebaseBackend.switchActiveOrganization(to: membership.id)
            await userStore.loadCurrentUser()
            memberships = await firebaseBackend.fetchOrganizationsForCurrentUser()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
