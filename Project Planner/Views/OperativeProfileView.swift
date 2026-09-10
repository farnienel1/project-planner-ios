//
//  OperativeProfileView.swift
//  Project Planner
//
//  Read-only profile opened from Manage Operatives / Operatives.
//  Settings cog opens EditUserView — the same Manage Users editor — so
//  operative detail changes stay linked to the shared AppUser + Operative records.
//

import SwiftUI

struct OperativeProfileView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var userStore: UserStore
    @EnvironmentObject var bookingStore: BookingStore
    @EnvironmentObject var operativeStore: OperativeStore
    @EnvironmentObject var holidayStore: HolidayStore
    @EnvironmentObject var firebaseBackend: FirebaseBackend
    @EnvironmentObject var notificationService: NotificationService

    let user: AppUser

    @State private var showingEdit = false
    @State private var profileRefreshToken = 0
    @State private var certificateViewerURL: IdentifiableURL?

    /// Admins, or managers with the Operatives permission — same gate as Manage Operatives.
    private var canOpenOperativeSettings: Bool {
        userStore.canManageUsers()
            || userStore.isActingManagerOperativeManagementOnly()
            || userStore.canViewOperatives()
    }

    private var displayedUser: AppUser {
        let _ = profileRefreshToken
        return userStore.organizationUsers.first(where: { $0.id == user.id }) ?? user
    }

    private var linkedOperative: Operative? {
        let _ = profileRefreshToken
        let key = displayedUser.email.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return nil }
        return operativeStore.allOperatives.first {
            $0.email.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) == key
        }
    }

    private var displayName: String {
        let full = displayedUser.fullName.trimmingCharacters(in: .whitespacesAndNewlines)
        return full.isEmpty ? displayedUser.email : full
    }

    private var initials: String {
        let parts = displayName.split(separator: " ").prefix(2)
        let letters = parts.compactMap { $0.first }.map(String.init).joined()
        return letters.isEmpty ? "U" : letters.uppercased()
    }

    private var telephoneValue: String {
        let mobile = displayedUser.mobileNumber?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !mobile.isEmpty { return mobile }
        let operativePhone = linkedOperative?.phone?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return operativePhone.isEmpty ? "Not set" : operativePhone
    }

    private var lineManagerValue: String {
        if displayedUser.hasNoLineManager || displayedUser.lineManagerUserIds.isEmpty {
            return "No line manager"
        }
        let names = displayedUser.lineManagerUserIds.compactMap { id -> String? in
            guard let manager = userStore.organizationUsers.first(where: { $0.id == id }) else { return nil }
            let name = manager.fullName.trimmingCharacters(in: .whitespacesAndNewlines)
            return name.isEmpty ? manager.email : name
        }
        if names.isEmpty { return "Assigned (details unavailable)" }
        return names.joined(separator: ", ")
    }

    private var dayRateValue: String {
        let standardHours = firebaseBackend.currentOrganization?.settings.payrollTimePolicy.standardPaidHours ?? 8
        let resolved = PayrollRateResolver.resolveCurrentProfileRate(
            user: displayedUser,
            operative: linkedOperative,
            standardDayHours: max(standardHours, 0.01)
        )
        if let label = resolved.displayRateLabel(currencySymbol: "£") {
            return label
        }
        return "Not set"
    }

    private var dayRateLabel: String {
        let standardHours = firebaseBackend.currentOrganization?.settings.payrollTimePolicy.standardPaidHours ?? 8
        let resolved = PayrollRateResolver.resolveCurrentProfileRate(
            user: displayedUser,
            operative: linkedOperative,
            standardDayHours: max(standardHours, 0.01)
        )
        switch resolved.basis {
        case .hourly where resolved.hasRate:
            return "Hourly rate"
        default:
            return "Day rate"
        }
    }

    private var qualificationRows: [(id: UUID, title: String, detail: String?, certificateURL: URL?)] {
        guard let operative = linkedOperative else { return [] }
        let sorted = operative.qualifications.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
        return sorted.map { qualification in
            let expiry = operative.qualificationExpiryDates[qualification.id]
                ?? qualification.endDate
            let detail: String?
            if let expiry {
                detail = "Expires \(expiry.formatted(date: .abbreviated, time: .omitted))"
            } else if qualification.hasEndDate {
                detail = "End date required"
            } else {
                detail = nil
            }
            let certString = operative.qualificationCertificateURLs[qualification.id]?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let certURL = certString.isEmpty ? nil : URL(string: certString)
            return (qualification.id, qualification.name, detail, certURL)
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    heroCard
                    detailsCard
                    qualificationsCard
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 28)
            }
            .background(ManageUserProfilePalette.pageBackground.ignoresSafeArea())
            .navigationTitle("Profile")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
                if canOpenOperativeSettings {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            showingEdit = true
                        } label: {
                            Image(systemName: "gearshape.fill")
                                .font(.system(size: 17, weight: .semibold))
                                .foregroundStyle(ManageUserProfilePalette.listBlue)
                        }
                        .accessibilityLabel("Operative settings")
                    }
                }
            }
            // Same Manage Users editor — keeps AppUser + linked Operative in sync.
            .sheet(isPresented: $showingEdit, onDismiss: {
                Task {
                    await userStore.loadOrganizationUsers()
                    operativeStore.loadData()
                    await MainActor.run { profileRefreshToken += 1 }
                }
            }) {
                EditUserView(user: displayedUser)
                    .environmentObject(userStore)
                    .environmentObject(bookingStore)
                    .environmentObject(operativeStore)
                    .environmentObject(holidayStore)
                    .environmentObject(firebaseBackend)
                    .environmentObject(notificationService)
            }
            .sheet(item: $certificateViewerURL) { item in
                InAppRemoteDocumentViewer(remoteURL: item.url, title: "Certificate")
            }
        }
    }

    // MARK: - Hero

    private var heroCard: some View {
        ManageUserCard {
            VStack(spacing: 14) {
                avatarView
                    .frame(width: 104, height: 104)
                    .opacity(displayedUser.isActive ? 1 : 0.55)

                VStack(spacing: 8) {
                    Text(displayName)
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(ManageUserProfilePalette.textPrimary)
                        .multilineTextAlignment(.center)

                    HStack(spacing: 8) {
                        statusChip(
                            text: displayedUser.isActive ? "Active" : "Inactive",
                            systemImage: displayedUser.isActive ? "checkmark.circle.fill" : "pause.circle.fill",
                            foreground: displayedUser.isActive
                                ? ManageUserProfilePalette.chipTealFg
                                : ManageUserProfilePalette.textSecondary,
                            background: displayedUser.isActive
                                ? ManageUserProfilePalette.chipTealBg
                                : ManageUserProfilePalette.segmentedBackground
                        )
                        statusChip(
                            text: displayedUser.passwordSet ? "Verified" : "Pending",
                            systemImage: displayedUser.passwordSet ? "checkmark.seal.fill" : "clock.fill",
                            foreground: displayedUser.passwordSet
                                ? ManageUserProfilePalette.chipBlueFg
                                : ManageUserProfilePalette.chipAmberFg,
                            background: displayedUser.passwordSet
                                ? ManageUserProfilePalette.chipBlueBg
                                : ManageUserProfilePalette.chipAmberBg
                        )
                    }
                }
            }
            .padding(.vertical, 24)
            .padding(.horizontal, 20)
            .frame(maxWidth: .infinity)
        }
    }

    @ViewBuilder
    private var avatarView: some View {
        ZStack {
            if let urlString = displayedUser.profilePhotoURL,
               let url = URL(string: urlString),
               !urlString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .empty:
                        ProgressView().tint(.white)
                    case .success(let image):
                        image
                            .resizable()
                            .scaledToFill()
                    case .failure:
                        initialsPlaceholder
                    @unknown default:
                        initialsPlaceholder
                    }
                }
            } else {
                initialsPlaceholder
            }
        }
        .clipShape(Circle())
        .overlay(
            Circle()
                .stroke(Color.white, lineWidth: 3)
                .shadow(color: Color.black.opacity(0.08), radius: 6, y: 2)
        )
    }

    private var initialsPlaceholder: some View {
        Circle()
            .fill(
                LinearGradient(
                    colors: [
                        ManageUserProfilePalette.avatarGradientTop,
                        ManageUserProfilePalette.avatarGradientBottom,
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .overlay(
                Text(initials)
                    .font(.system(size: 34, weight: .medium))
                    .foregroundStyle(.white)
                    .tracking(0.6)
            )
    }

    private func statusChip(
        text: String,
        systemImage: String,
        foreground: Color,
        background: Color
    ) -> some View {
        HStack(spacing: 5) {
            Image(systemName: systemImage)
                .font(.system(size: 11, weight: .semibold))
            Text(text)
                .font(.system(size: 12, weight: .semibold))
        }
        .foregroundStyle(foreground)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(background)
        .clipShape(Capsule(style: .continuous))
    }

    // MARK: - Details

    private var detailsCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            ManageUserSectionTitle(text: "Details")
            ManageUserCard {
                VStack(spacing: 0) {
                    ManageUserDetailStaticRow(
                        iconName: "envelope.fill",
                        iconBackground: ManageUserProfilePalette.chipBlueBg,
                        iconForeground: ManageUserProfilePalette.chipBlueFg,
                        label: "Email",
                        value: displayedUser.email.isEmpty ? "Not set" : displayedUser.email
                    )
                    ManageUserCardDivider()
                    ManageUserDetailStaticRow(
                        iconName: "phone.fill",
                        iconBackground: ManageUserProfilePalette.chipTealBg,
                        iconForeground: ManageUserProfilePalette.chipTealFg,
                        label: "Telephone number",
                        value: telephoneValue
                    )
                    ManageUserCardDivider()
                    ManageUserDetailStaticRow(
                        iconName: "person.2.fill",
                        iconBackground: ManageUserProfilePalette.chipPurpleBg,
                        iconForeground: ManageUserProfilePalette.chipPurpleFg,
                        label: "Line manager",
                        value: lineManagerValue
                    )
                    ManageUserCardDivider()
                    ManageUserDetailStaticRow(
                        iconName: "banknote.fill",
                        iconBackground: ManageUserProfilePalette.chipAmberBg,
                        iconForeground: ManageUserProfilePalette.chipAmberFg,
                        label: dayRateLabel,
                        value: dayRateValue
                    )
                }
            }
        }
    }

    // MARK: - Qualifications

    private var qualificationsCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            ManageUserSectionTitle(text: "Qualifications")
            ManageUserCard {
                if qualificationRows.isEmpty {
                    HStack(spacing: 12) {
                        ManageUserIconChip(
                            systemName: "graduationcap.fill",
                            background: ManageUserProfilePalette.chipBlueBg,
                            foreground: ManageUserProfilePalette.chipBlueFg
                        )
                        VStack(alignment: .leading, spacing: 2) {
                            Text("No qualifications yet")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(ManageUserProfilePalette.textPrimary)
                            Text("Add them from Edit when needed.")
                                .font(.system(size: 11))
                                .foregroundStyle(ManageUserProfilePalette.textSecondary)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.vertical, 14)
                    .padding(.horizontal, 14)
                } else {
                    VStack(spacing: 0) {
                        ForEach(Array(qualificationRows.enumerated()), id: \.element.id) { index, row in
                            HStack(alignment: .top, spacing: 12) {
                                ManageUserIconChip(
                                    systemName: "checkmark.seal.fill",
                                    background: ManageUserProfilePalette.chipTealBg,
                                    foreground: ManageUserProfilePalette.chipTealFg
                                )
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(row.title)
                                        .font(.system(size: 13, weight: .semibold))
                                        .foregroundStyle(ManageUserProfilePalette.textPrimary)
                                    if let detail = row.detail {
                                        Text(detail)
                                            .font(.system(size: 11))
                                            .foregroundStyle(ManageUserProfilePalette.textSecondary)
                                    }
                                    if let certificateURL = row.certificateURL {
                                        Button("View certificate") {
                                            certificateViewerURL = IdentifiableURL(certificateURL)
                                        }
                                        .font(.system(size: 12, weight: .medium))
                                    }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .padding(.vertical, 12)
                            .padding(.horizontal, 14)

                            if index < qualificationRows.count - 1 {
                                ManageUserCardDivider()
                            }
                        }
                    }
                }
            }
        }
    }
}
