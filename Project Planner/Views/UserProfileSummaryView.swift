//
//  UserProfileSummaryView.swift
//  Project Planner
//
//  Owner issue #17 (17 Nov, web `components/users/UserProfileSummary.tsx`): tapping a person on Manage Users, the
//  Operatives page or the Managers page opens a read-only profile summary first — name, level, status, contact, trade,
//  line manager, employment and rate (only when `canViewPersonPay` allows) and their qualifications (#18) — with an
//  "Edit profile" button that opens the existing Edit user screen. When the viewer may not edit the person the button
//  reads "View full profile" and opens the same screen read-only, exactly as tapping the row did before, so nothing
//  that screen shows (annual leave, permissions, account actions) is lost.
//
//  Rulebook functions: `userLevelLabel`, `rosterSegment` (`GhostRulebook.segment`), `ghostBadgeLabel`,
//  `lineManagerSummary` (`LineManagerRulebook.summary`), `canViewPersonPay` (`UserStore.canViewPay`),
//  `payEditorStartingValues` (`UserStore.payEditorRecord`), `readStoredRates` (`UserStore.storedPay`), `formatMoney`,
//  and for the qualifications `taskPersonKeys`, `qualificationExpiryRows`, `qualificationCertificateUrl`,
//  `safeExternalUrl` (`PersonQualifications`). Display only: nothing here writes.
//

import SwiftUI

struct UserProfileSummaryView: View {
    @EnvironmentObject var userStore: UserStore
    @EnvironmentObject var operativeStore: OperativeStore
    @EnvironmentObject var bookingStore: BookingStore
    @EnvironmentObject var holidayStore: HolidayStore
    @EnvironmentObject var firebaseBackend: FirebaseBackend
    @EnvironmentObject var notificationService: NotificationService
    @EnvironmentObject private var smartCache: SmartCacheService
    @Environment(\.dismiss) private var dismiss

    let user: AppUser
    /// Passed through to Edit user (the Managers shortcut hides Admin Access there).
    var suppressAdminAccessToggle: Bool = false

    @State private var payRecord: AppUser?
    @State private var showingEditor = false
    @State private var certificateViewerURL: IdentifiableURL?

    /// Set once the person has been seen on the roster; if they then leave it (deleted from Edit user), the page says so.
    @State private var seenInRoster = false

    /// The live roster row (a save on Edit user shows here on return), else the row the screen was opened with.
    private var person: AppUser? {
        if let row = userStore.rosterRow(for: user.id) { return row }
        return seenInRoster ? nil : user
    }

    var body: some View {
        Group {
            if let person {
                ScrollView {
                    content(for: person)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 16)
                }
            } else {
                notFound
            }
        }
        .background(ManageUserProfilePalette.pageBackground.ignoresSafeArea())
        .navigationTitle("User profile")
        .navigationBarTitleDisplayMode(.inline)
        .ppNavyNavigationBar()
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
                Button("Close") { dismiss() }
                    .accessibilityIdentifier("userProfile.close")
                    .tint(.white)
            }
        }
        // Review of #269 item 1: Edit user owns its NavigationStack, so it is presented on its own (as the list sheets
        // did before), never pushed inside this stack. Its Cancel / Save / Delete close it and come back here; after a
        // delete this page says "User not found" (`seenInRoster`).
        .sheet(isPresented: $showingEditor) {
            EditUserView(user: person ?? user, suppressAdminAccessToggle: suppressAdminAccessToggle)
                .environmentObject(userStore)
                .environmentObject(bookingStore)
                .environmentObject(operativeStore)
                .environmentObject(holidayStore)
                .environmentObject(firebaseBackend)
                .environmentObject(notificationService)
                .environmentObject(smartCache)
        }
        .sheet(item: $certificateViewerURL) { item in
            InAppRemoteDocumentViewer(remoteURL: item.url, title: "Certificate")
        }
        .onAppear { noteRoster() }
        .onChange(of: userStore.revision) { _, _ in noteRoster() }
        .task(id: payTaskKey) {
            await loadPayRecord()
        }
    }

    private func noteRoster() {
        if userStore.rosterRow(for: user.id) != nil { seenInRoster = true }
    }

    // MARK: Content

    @ViewBuilder
    private func content(for person: AppUser) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            header(for: person)
            editButton(for: person)
            VStack(alignment: .leading, spacing: 8) {
                ManageUserSectionTitle(text: "Details")
                ManageUserCard {
                    VStack(spacing: 0) {
                        ForEach(Array(detailRows(for: person).enumerated()), id: \.offset) { index, row in
                            if index > 0 { ManageUserCardDivider() }
                            ManageUserDetailStaticRow(
                                iconName: row.icon,
                                iconBackground: ManageUserProfilePalette.chipBlueBg,
                                iconForeground: ManageUserProfilePalette.chipBlueFg,
                                label: row.label,
                                value: row.value
                            )
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                        }
                    }
                }
            }
            qualificationsSection(for: person)
        }
    }

    private func header(for person: AppUser) -> some View {
        HStack(alignment: .center, spacing: 14) {
            ProfilePhotoAvatar(urlString: person.profilePhotoURL, updatedAt: person.profilePhotoUpdatedAt) {
                ZStack {
                    LinearGradient(
                        colors: [ManageUserProfilePalette.avatarGradientTop, ManageUserProfilePalette.avatarGradientBottom],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    Text(initials(person))
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(.white)
                }
            }
            .frame(width: 64, height: 64)
            .clipShape(Circle())
            VStack(alignment: .leading, spacing: 6) {
                Text(displayName(person))
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(ManageUserProfilePalette.textPrimary)
                    .lineLimit(2)
                    .accessibilityIdentifier("userProfile.name")
                HStack(spacing: 6) {
                    ForEach(Array(chips(for: person).enumerated()), id: \.offset) { _, chip in
                        Text(chip)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(ManageUserProfilePalette.chipBlueFg)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Capsule().fill(ManageUserProfilePalette.chipBlueBg))
                    }
                }
            }
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private func editButton(for person: AppUser) -> some View {
        let canEdit = userStore.canOpenEditProfile(person, opened: user)
        Button {
            showingEditor = true
        } label: {
            Label(canEdit ? "Edit profile" : "View full profile", systemImage: canEdit ? "pencil" : "person.text.rectangle")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(ManageUserProfilePalette.primaryBlue)
                )
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(canEdit ? "userProfile.edit" : "userProfile.viewFull")
        if !canEdit {
            Text("View only")
                .font(.footnote)
                .foregroundStyle(ManageUserProfilePalette.textSecondary)
                .frame(maxWidth: .infinity, alignment: .center)
        }
    }

    @ViewBuilder
    private func qualificationsSection(for person: AppUser) -> some View {
        let rows = PersonQualifications.rows(
            for: person,
            users: userStore.organizationUsers,
            operatives: operativeStore.allOperatives,
            preferredRowId: operativeStore.operativeRow(for: person)?.documentId
        )
        VStack(alignment: .leading, spacing: 8) {
            ManageUserSectionTitle(text: "Qualifications")
            ManageUserCard {
                VStack(spacing: 0) {
                    if let rows, !rows.isEmpty {
                        ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                            if index > 0 { ManageUserCardDivider() }
                            qualificationRow(row)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 10)
                        }
                    } else {
                        Text(rows == nil ? "Qualifications could not be loaded. Try again." : "No qualifications yet.")
                            .font(.system(size: 13))
                            .foregroundStyle(ManageUserProfilePalette.textSecondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(14)
                            .accessibilityIdentifier("userProfile.noQualifications")
                    }
                }
            }
        }
    }

    private func qualificationRow(_ row: PersonQualificationRow) -> some View {
        HStack(alignment: .center, spacing: 12) {
            ManageUserIconChip(
                systemName: "graduationcap.fill",
                background: ManageUserProfilePalette.chipAmberBg,
                foreground: ManageUserProfilePalette.chipAmberFg
            )
            VStack(alignment: .leading, spacing: 4) {
                Text(row.name)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(ManageUserProfilePalette.textPrimary)
                    .lineLimit(2)
                Text(PersonQualifications.expiryText(row))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(expiryForeground(row.tone))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(expiryBackground(row.tone)))
                    .accessibilityIdentifier("userProfile.qualificationExpiry")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if let url = row.certificateURL {
                Button("View certificate") {
                    certificateViewerURL = IdentifiableURL(url)
                }
                .font(.system(size: 12, weight: .semibold))
                .buttonStyle(.borderless)
                .accessibilityIdentifier("userProfile.viewCertificate")
            } else {
                Text("No certificate")
                    .font(.system(size: 11))
                    .foregroundStyle(ManageUserProfilePalette.textSecondary)
            }
        }
    }

    private func expiryForeground(_ tone: PersonQualificationRow.Tone) -> Color {
        switch tone {
        case .expired: return ManageUserProfilePalette.chipRedFg
        case .expiringSoon: return ManageUserProfilePalette.chipAmberFg
        case .none: return ManageUserProfilePalette.textSecondary
        }
    }

    private func expiryBackground(_ tone: PersonQualificationRow.Tone) -> Color {
        switch tone {
        case .expired: return ManageUserProfilePalette.chipRedBg
        case .expiringSoon: return ManageUserProfilePalette.chipAmberBg
        case .none: return ManageUserProfilePalette.segmentedBackground
        }
    }

    private var notFound: some View {
        VStack(spacing: 12) {
            Text("User not found")
                .font(.headline)
            Text("That profile is not in this organisation.")
                .font(.subheadline)
                .foregroundStyle(ManageUserProfilePalette.textSecondary)
            Button("Go back") { dismiss() }
                .accessibilityIdentifier("userProfile.goBack")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Values

    private struct DetailRow {
        let icon: String
        let label: String
        let value: String
    }

    private func detailRows(for person: AppUser) -> [DetailRow] {
        var rows: [DetailRow] = []
        // RULEBOOK 1.34.0 §11: a ghost has no email, phone or login (an invited ghost shows the invitation email).
        if !person.isGhost || !person.email.isEmpty {
            rows.append(DetailRow(icon: "envelope.fill", label: "Email", value: person.email.isEmpty ? "—" : person.email))
        }
        if !person.isGhost {
            let mobile = person.mobileNumber?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            rows.append(DetailRow(icon: "phone.fill", label: "Mobile", value: mobile.isEmpty ? "—" : mobile))
            rows.append(DetailRow(icon: "clock.fill", label: "Last active", value: lastActiveText(person.lastSeenAt)))
        }
        rows.append(DetailRow(icon: "hammer.fill", label: "Trade", value: person.displayTradeType))
        if payVisible(person) {
            // Review of #269 item 5: while `privatePay` is on the users document may hold an old rate (or none), so
            // nothing is shown until the pay record (`payEditorRecord`) has loaded for this person.
            let record: AppUser? = SecuritySwitchContext.privatePay
                ? payRecord.flatMap { $0.id == person.id ? $0 : nil }
                : (payRecord ?? person)
            if let record {
                rows.append(DetailRow(icon: "briefcase.fill", label: "Employment", value: record.employmentType.title))
                if let rate = rateRow(record) {
                    rows.append(DetailRow(icon: "sterlingsign.circle.fill", label: rate.label, value: rate.value))
                }
            } else {
                rows.append(DetailRow(icon: "briefcase.fill", label: "Employment and rate", value: "Loading…"))
            }
        }
        rows.append(DetailRow(
            icon: "person.2.fill",
            label: "Line manager",
            value: LineManagerRulebook.summary(for: person, roster: userStore.organizationUsers)
        ))
        return rows
    }

    /// RULEBOOK 1.13.0 / 1.32.0 §8 `canViewPersonPay` in the profile context.
    private func payVisible(_ person: AppUser) -> Bool {
        userStore.canViewPay(of: person, context: .profile)
    }

    /// Web `profileRateRow`: "Day rate £250.00/day" or "Hourly rate £30.00/hr"; nothing when no rate is set.
    private func rateRow(_ record: AppUser) -> (label: String, value: String)? {
        let stored = UserStore.storedPay(of: record)
        guard let amount = stored.amount else { return nil }
        if stored.basis == "hourly" {
            return ("Hourly rate", "\(OrgMoney.format(amount))/hr")
        }
        return ("Day rate", "\(OrgMoney.format(amount))/day")
    }

    private var payTaskKey: String {
        guard let person else { return "" }
        // Read again when Edit user closes, so a pay change made there shows here.
        return "\(person.id)|\(payVisible(person))|\(SecuritySwitchContext.privatePay)|\(showingEditor)"
    }

    /// RULEBOOK 1.26.1 §8: the pay shown is the pay editor's record (`payEditorRecord`; the stored document while
    /// `privatePay` is off). Read only when the viewer may see it.
    private func loadPayRecord() async {
        payRecord = nil
        guard let person, payVisible(person) else { return }
        payRecord = await userStore.payEditorRecord(for: person)
    }

    private func chips(for person: AppUser) -> [String] {
        var chips: [String] = []
        if let level = CanonicalBusinessEngine.userLevelLabel(RulebookPeople.person(person)), !level.isEmpty {
            chips.append(level)
        }
        let ghostBadge = GhostRulebook.badge(person)
        if !ghostBadge.isEmpty {
            chips.append(ghostBadge)
        } else {
            chips.append(person.passwordSet ? "Verified" : "Pending")
        }
        if let segment = GhostRulebook.segment(person), let tab = UserRosterSegment(canonicalSegment: segment),
           !chips.contains(tab.title) {
            chips.append(tab.title)
        }
        return chips
    }

    private func displayName(_ person: AppUser) -> String {
        let name = person.fullName.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? (person.email.isEmpty ? "—" : person.email) : name
    }

    private func initials(_ person: AppUser) -> String {
        let letters = [person.firstName, person.surname].compactMap { $0.trimmingCharacters(in: .whitespaces).first }
        return letters.isEmpty ? "?" : String(letters).uppercased()
    }

    private func lastActiveText(_ date: Date?) -> String {
        guard let date else { return "—" }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_GB")
        formatter.timeZone = OrganizationRulebookContext.timeZone
        formatter.dateFormat = "d MMM yyyy 'at' HH:mm"
        return formatter.string(from: date)
    }
}
