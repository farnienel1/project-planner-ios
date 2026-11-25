//
//  GettingStartedHomeCard.swift
//  Project Planner
//
//  RULEBOOK 1.85.0 §32 (owner 24 Nov): the "Getting started" card at the top of Home for admins of a new company —
//  a progress bar ("3 of 6 done") and six items that tick themselves off from real data, each opening its screen.
//  The items, the words and when the card shows are the script's (`onboardingChecklist`, `onboardingCardVisible`);
//  an admin can hide it for the company (`dismissOnboardingChecklist`). The same list as web Home.
//

import SwiftUI

struct GettingStartedHomeCard: View {
    @EnvironmentObject var firebaseBackend: FirebaseBackend
    @EnvironmentObject var userStore: UserStore
    @EnvironmentObject var projectStore: ProjectStore
    /// Shared with `OrgComplianceHomeReminderCard` (one listener on Home; that card starts and stops it).
    @ObservedObject var complianceStore: OrgComplianceStore
    @State private var openDestination: String?
    @State private var confirmingHide = false
    @State private var hideError: String?

    private var organizationId: String { firebaseBackend.currentOrganization?.firestoreDocumentId ?? "" }

    /// Admins only (the same admin rule as insurance & accreditations, `permissionLevelOf` = admin).
    private var viewerIsAdmin: Bool {
        userStore.displayUser.map { CanonicalBusinessEngine.canManageOrganizationCompliance($0.permissionSubject) } ?? false
    }

    private var checklist: RulebookOnboardingChecklist? {
        guard viewerIsAdmin, let org = firebaseBackend.currentOrganization, org.onboardingDocumentJSON != nil else { return nil }
        let rosterLoaded = organizationIdsMatch(userStore.organizationUsersFinishedLoadOrganizationId, org.firestoreDocumentId)
        let jobsLoaded = organizationIdsMatch(projectStore.finishedLoadOrganizationId, org.firestoreDocumentId)
        let creator = (org.creatorUserId ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        // `organizationUsers` is the folded roster (one row per person, `rosterPeople`), as web Home's `users`; the
        // creator is left out under any id their row goes by.
        let people = rosterLoaded
            ? userStore.organizationUsers.filter { user in
                !([user.id] + user.formerUserIds + user.sameEmailUserIds).contains { $0.lowercased() == creator }
            }.count
            : nil
        let documents = complianceStore.documents.map {
            CanonicalBusinessEngine.orgComplianceCounts($0, todayKey: CanonicalBusinessEngine.orgComplianceTodayKey()).total
        }
        return CanonicalBusinessEngine.onboardingCardVisible(
            organization: OnboardingOrganizationDocument.document(json: org.onboardingDocumentJSON),
            people: people,
            pendingInvites: rosterLoaded ? 0 : nil,
            // `projects` already holds every job, small works included (`smallWorks` is derived from it), as Home's count.
            jobs: jobsLoaded ? projectStore.projects.count : nil,
            complianceDocuments: documents,
            viewerIsAdmin: true
        )
    }

    var body: some View {
        Group {
            if let checklist {
                card(checklist)
            }
        }
        .sheet(item: Binding(get: { openDestination.map { DestinationID(id: $0) } }, set: { openDestination = $0?.id })) { destination in
            sheetContent(destination.id)
                .environmentObject(firebaseBackend)
                .environmentObject(userStore)
                .environmentObject(projectStore)
        }
        .confirmationDialog(
            CanonicalBusinessEngine.onboardingText("ONBOARDING_DISMISS_CONFIRM", fallback: "Hide the Getting started card? You can still do every step from Settings."),
            isPresented: $confirmingHide,
            titleVisibility: .visible
        ) {
            Button(CanonicalBusinessEngine.onboardingText("ONBOARDING_DISMISS_LABEL", fallback: "Hide"), role: .destructive) { hide() }
            Button("Cancel", role: .cancel) {}
        }
    }

    private struct DestinationID: Identifiable { let id: String }

    @ViewBuilder
    private func card(_ checklist: RulebookOnboardingChecklist) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(checklist.title)
                    .font(.headline)
                Spacer()
                Button(CanonicalBusinessEngine.onboardingText("ONBOARDING_DISMISS_LABEL", fallback: "Hide")) {
                    confirmingHide = true
                }
                .font(.subheadline.weight(.semibold))
                .accessibilityIdentifier("home.gettingStarted.hide")
            }
            Text(checklist.subtitle)
                .font(.footnote)
                .foregroundStyle(.secondary)
            ProgressView(value: checklist.progress)
                .tint(PPColor.brand)
                .accessibilityLabel(checklist.progressLabel)
            Text(checklist.progressLabel)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
            ForEach(checklist.items) { item in
                Button {
                    openDestination = item.destination
                } label: {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: item.done ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(item.done ? Color.green : Color.secondary)
                            .font(.body)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.optional ? "\(item.title) · \(CanonicalBusinessEngine.onboardingText("ONBOARDING_OPTIONAL_LABEL", fallback: "Optional"))" : item.title)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(item.done ? .secondary : .primary)
                                .strikethrough(item.done)
                                .multilineTextAlignment(.leading)
                            Text(item.detail)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.leading)
                        }
                        Spacer(minLength: 8)
                        Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(item.title), \(item.done ? "done" : "not done yet")")
                .accessibilityIdentifier("home.gettingStarted.\(item.key)")
            }
            if let hideError {
                Text(hideError).font(.footnote).foregroundStyle(.red)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(PPColor.card)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .accessibilityIdentifier("home.gettingStarted")
    }

    /// `ProjectsView` and `CompanyDetailsEditView` own their NavigationStack (wrapping them again crashes on open,
    /// ContentView); they are presented as they are, as the Organisation hub does. The others get one with Done.
    @ViewBuilder
    private func sheetContent(_ destination: String) -> some View {
        switch destination {
        case "companyDetails": CompanyDetailsEditView()
        case "projects": ProjectsView()
        default:
            NavigationStack {
                destinationView(destination)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Done") { openDestination = nil }
                        }
                    }
            }
        }
    }

    @ViewBuilder
    private func destinationView(_ destination: String) -> some View {
        switch destination {
        case "workingHours": OrganisationWorkingHoursView(showsHistory: true)
        case "paymentRuns": OrganisationInvoicingSettingsView()
        case "manageUsers": ManageUsersView()
        case "insuranceAccreditations": InsuranceAccreditationsView(store: complianceStore)
        default: EmptyView()
        }
    }

    private func hide() {
        hideError = nil
        firebaseBackend.dismissOnboardingChecklist(organizationId: organizationId) { _ in
            hideError = "Could not hide the card. Try again."
        }
    }
}
