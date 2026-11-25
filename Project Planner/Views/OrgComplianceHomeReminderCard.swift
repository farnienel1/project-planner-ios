//
//  OrgComplianceHomeReminderCard.swift
//  Project Planner
//
//  RULEBOOK 1.83.0 §31 (owner decision 24 Nov): admins see one card on Home when an insurance or accreditation
//  document has expired or expires within 30 days. Whether to show it and its words are the rulebook's
//  (`orgComplianceReminder` over `orgComplianceCounts`, the one status rule); tapping it opens Insurance &
//  accreditations. Nothing shows for anyone else (the listener is started only for admins; the rules refuse others).
//

import Foundation
import SwiftUI
import Combine

struct OrgComplianceHomeReminderCard: View {
    @EnvironmentObject var firebaseBackend: FirebaseBackend
    @EnvironmentObject var userStore: UserStore
    /// Owned by Home and shared with `GettingStartedHomeCard` (one listener); this card starts and stops it.
    @ObservedObject var store: OrgComplianceStore
    @State private var showingPage = false

    private var organizationId: String { firebaseBackend.currentOrganization?.firestoreDocumentId ?? "" }

    private var allowed: Bool {
        userStore.displayUser.map { CanonicalBusinessEngine.canManageOrganizationCompliance($0.permissionSubject) } ?? false
    }

    private var reminder: RulebookOrgComplianceReminder? {
        guard allowed, let documents = store.documents else { return nil }
        let today = CanonicalBusinessEngine.orgComplianceTodayKey()
        return CanonicalBusinessEngine.orgComplianceReminder(CanonicalBusinessEngine.orgComplianceCounts(documents, todayKey: today))
    }

    var body: some View {
        Group {
            if let reminder {
                Button {
                    showingPage = true
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "checkmark.shield")
                            .font(.title3)
                            .foregroundStyle(.orange)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(reminder.title)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.primary)
                                .multilineTextAlignment(.leading)
                            Text(reminder.detail)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.leading)
                        }
                        Spacer(minLength: 8)
                        Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(PPColor.card)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .accessibilityIdentifier("home.orgComplianceReminder")
                .accessibilityHint("Opens insurance and accreditations")
            }
        }
        .onAppear { startOrStop() }
        .onChange(of: organizationId) { _, _ in startOrStop() }
        .onChange(of: allowed) { _, _ in startOrStop() }
        .onDisappear { store.stop() }
        .sheet(isPresented: $showingPage) {
            NavigationStack {
                InsuranceAccreditationsView(store: store)
                    .environmentObject(firebaseBackend)
                    .environmentObject(userStore)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Done") { showingPage = false }
                        }
                    }
            }
        }
    }

    private func startOrStop() {
        guard allowed, !organizationId.isEmpty else {
            store.stop()
            return
        }
        store.start(organizationId: organizationId, db: firebaseBackend.db)
    }
}
