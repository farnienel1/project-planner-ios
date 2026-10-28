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

    /// When set, that organisation is omitted from the list (last-used org on the deactivated gate).
    var excludedOrganizationId: String? = nil

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

                if isLoading && memberships.isEmpty {
                    ProgressView("Loading organisations…")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 28)
                } else if memberships.isEmpty {
                    emptyState
                } else {
                    sectionTitle("Your organisations")
                    membershipList
                }

                webSetupNote
                    .padding(.top, 16)

                if let errorMessage, !errorMessage.isEmpty {
                    Text(errorMessage)
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(Color.red)
                        .padding(.top, 12)
                }
            }
            .padding(.horizontal, PPMetrics.screenGutter)
            .padding(.bottom, 28)
        }
        .background(PPColor.page.ignoresSafeArea())
        .navigationTitle("Switch organisation")
        .navigationBarTitleDisplayMode(.inline)
        .ppNavyNavigationBar()
        .onAppear {
            paintKnownCompanies()
        }
        .task {
            paintKnownCompanies()
            await reloadMemberships()
        }
        .refreshable {
            await reloadMemberships()
        }
    }

    private var introCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Work across teams")
                .font(.body.weight(.semibold))
                .foregroundStyle(Color.primary)
            Text("Choose which organisation you want to use in the app. Your schedule, projects, and settings will update to match.")
                .font(.footnote)
                .foregroundStyle(Color.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(PPColor.card, in: RoundedRectangle(cornerRadius: PPMetrics.cardRadius, style: .continuous))
    }

    private var webSetupNote: some View {
        Text("New organisations are set up using the Project Planner web app, which can be reached at www.projectplanner.us.")
            .font(.footnote)
            .foregroundStyle(Color.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(PPColor.well)
            .clipShape(RoundedRectangle(cornerRadius: PPMetrics.cardRadius, style: .continuous))
            .allowsHitTesting(false)
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("No organisations found")
                .font(.body.weight(.semibold))
                .foregroundStyle(Color.primary)
            Text("If you were invited to another organisation, pull to refresh or sign out and sign in again.")
                .font(.footnote)
                .foregroundStyle(Color.secondary)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(PPColor.card, in: RoundedRectangle(cornerRadius: PPMetrics.cardRadius, style: .continuous))
        .padding(.top, 16)
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.footnote.weight(.semibold))
            .foregroundStyle(Color.secondary)
            .tracking(0.8)
            .padding(.leading, 4)
            .padding(.top, 22)
            .padding(.bottom, 8)
    }

    private var membershipList: some View {
        VStack(spacing: 0) {
            ForEach(memberships) { membership in
                membershipRow(membership)
                if membership.id != memberships.last?.id {
                    Divider().background(Color(.separator)).padding(.leading, PPMetrics.menuIcon + 13)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 4)
        .background(PPColor.card, in: RoundedRectangle(cornerRadius: PPMetrics.cardRadius, style: .continuous))
    }

    private func membershipRow(_ membership: OrgMembershipSummary) -> some View {
        let isCurrent = membership.id == activeOrgId
        let isBusy = isSwitching && switchingOrgId == membership.id
        let canEnter = membership.isActive && membership.subscriptionHasAccess
        return Button {
            guard !isCurrent, !isSwitching, canEnter else { return }
            Task { await switchToOrganisation(membership) }
        } label: {
            HStack(spacing: 13) {
                PPIconTile(symbol: "building.2.fill", family: isCurrent ? .plan : .system)
                VStack(alignment: .leading, spacing: 3) {
                    Text(membership.name)
                        .font(.body)
                        .foregroundStyle(Color.primary)
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
                    .font(.caption.weight(.medium))
                    .foregroundStyle(Color.secondary)
                    if !membership.subscriptionHasAccess {
                        Text(SubscriptionLapsedCopy.phrase)
                            .font(.caption.weight(.medium))
                            .foregroundStyle(Color.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 8)
                if isBusy {
                    ProgressView()
                        .controlSize(.small)
                } else if isCurrent {
                    Text("Active")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(PPColor.brand)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(PPColor.brand.opacity(0.12))
                        .clipShape(Capsule())
                } else if !membership.subscriptionHasAccess {
                    EmptyView()
                } else if !membership.isActive {
                    Image(systemName: "lock.fill")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Color.red.opacity(0.8))
                } else {
                    Image(systemName: "chevron.right")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Color(.tertiaryLabel))
                }
            }
            .padding(.vertical, 13)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .accessibilityIdentifier("switchOrganisation.building2Fill")
        .buttonStyle(.plain)
        .disabled(isCurrent || isSwitching || !canEnter)
    }

    @MainActor
    private func filteredMemberships() async -> [OrgMembershipSummary] {
        excluding(await firebaseBackend.fetchOrganizationsForCurrentUser())
    }

    @MainActor
    private func paintKnownCompanies() {
        let known = excluding(firebaseBackend.knownOrganizationMembershipsBeforeScan())
        guard !known.isEmpty else { return }
        memberships = known
        isLoading = false
    }

    @MainActor
    private func reloadMemberships() async {
        errorMessage = nil
        if memberships.isEmpty { isLoading = true }
        memberships = await filteredMemberships()
        isLoading = false
    }

    private func excluding(_ rows: [OrgMembershipSummary]) -> [OrgMembershipSummary] {
        guard let excluded = excludedOrganizationId?.trimmingCharacters(in: .whitespacesAndNewlines),
              !excluded.isEmpty else {
            return rows
        }
        return rows.filter {
            $0.id.compare(excluded, options: [.caseInsensitive, .diacriticInsensitive]) != .orderedSame
        }
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
        firebaseBackend.queueOrganizationSwitch(to: membership.id)
    }
}
