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

    private var qualificationRows: [(id: String, title: String, detail: String?, certificateURL: URL?)] {
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
            let certString = CanonicalBusinessEngine.qualificationCertificateUrl(
                urls: operative.qualificationCertificateURLs,
                qualificationId: qualification.id
            )?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let certURL = certString.isEmpty ? nil : URL(string: certString)
            return (qualification.id, qualification.name, detail, certURL)
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 0) {
                    heroCard
                    VStack(spacing: 0) {
                        detailsCard
                        qualificationsCard
                    }
                    .padding(.bottom, 28)
                    .ppContentSheet()
                }
            }
            .background(PPColor.page.ignoresSafeArea())
            .navigationTitle("Profile")
            .navigationBarTitleDisplayMode(.inline)
            .ppNavyNavigationBar()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                        .fontWeight(.semibold)
                        .foregroundStyle(.white)
                        .accessibilityIdentifier("operativeProfile.close")
                }
                if canOpenOperativeSettings {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            showingEdit = true
                        } label: {
                            Image(systemName: "gearshape.fill")
                        }
                        .buttonStyle(PPOnNavyCircleButtonStyle(size: 36))
                        .accessibilityIdentifier("operativeProfile.settings")
                        .accessibilityLabel("Settings")
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

    /// Navy header (Home style): avatar, name and the existing Active / Verified status chips.
    private var heroCard: some View {
        VStack(spacing: 14) {
            avatarView
                .frame(width: 96, height: 96)
                .opacity(displayedUser.isActive ? 1 : 0.55)

            VStack(spacing: 10) {
                Text(displayName)
                    .font(.system(.title2, design: .rounded))
                    .fontWeight(.bold)
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)

                HStack(spacing: 8) {
                    PPOnNavyPill(
                        text: displayedUser.isActive ? "Active" : "Inactive",
                        symbol: displayedUser.isActive ? "checkmark.circle.fill" : "pause.circle.fill"
                    )
                    PPOnNavyPill(
                        text: displayedUser.passwordSet ? "Verified" : "Pending",
                        symbol: displayedUser.passwordSet ? "checkmark.seal.fill" : "clock.fill"
                    )
                }
            }
        }
        .padding(.horizontal, PPMetrics.screenGutter)
        .padding(.top, 16)
        .padding(.bottom, PPMetrics.headerBottomPadding)
        .frame(maxWidth: .infinity)
        .ppNavyHeader()
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
                .stroke(Color.white.opacity(0.9), lineWidth: 3)
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

    // MARK: - Details

    private var detailsCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            PPGroupLabel(text: "Details")
            PPGroupedCard {
                PPDetailRowLabel(
                    title: "Email",
                    value: displayedUser.email.isEmpty ? "Not set" : displayedUser.email,
                    symbol: "envelope.fill",
                    family: .plan
                )
                PPRowDivider()
                PPDetailRowLabel(
                    title: "Telephone number",
                    value: telephoneValue,
                    symbol: "phone.fill",
                    family: .sites
                )
                PPRowDivider()
                PPDetailRowLabel(
                    title: "Line manager",
                    value: lineManagerValue,
                    symbol: "person.2.fill",
                    family: .people
                )
                PPRowDivider()
                PPDetailRowLabel(
                    title: dayRateLabel,
                    value: dayRateValue,
                    symbol: "banknote.fill",
                    family: .trade
                )
            }
        }
    }

    // MARK: - Qualifications

    private var qualificationsCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            PPGroupLabel(text: "Qualifications")
            PPGroupedCard {
                if qualificationRows.isEmpty {
                    HStack(spacing: 13) {
                        PPIconTile(symbol: "graduationcap.fill", family: .people, size: PPMetrics.menuIcon)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("No qualifications yet")
                                .font(.body)
                                .foregroundStyle(.primary)
                            Text("Add them from Edit when needed.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.vertical, 11)
                    .padding(.horizontal, 14)
                    .frame(minHeight: 60)
                } else {
                    VStack(spacing: 0) {
                        ForEach(Array(qualificationRows.enumerated()), id: \.element.id) { index, row in
                            HStack(alignment: .top, spacing: 13) {
                                PPIconTile(symbol: "checkmark.seal.fill", family: .sites, size: PPMetrics.menuIcon)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(row.title)
                                        .font(.body.weight(.semibold))
                                        .foregroundStyle(.primary)
                                    if let detail = row.detail {
                                        Text(detail)
                                            .font(.footnote)
                                            .foregroundStyle(.secondary)
                                    }
                                    if let certificateURL = row.certificateURL {
                                        Button("View certificate") {
                                            certificateViewerURL = IdentifiableURL(certificateURL)
                                        }
                                        .accessibilityIdentifier("operativeProfile.row.\(row.id).viewCertificate")
                                        .font(.footnote.weight(.semibold))
                                        .tint(PPColor.brand)
                                        .padding(.top, 2)
                                    }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .padding(.vertical, 11)
                            .padding(.horizontal, 14)

                            if index < qualificationRows.count - 1 {
                                PPRowDivider()
                            }
                        }
                    }
                }
            }
        }
    }
}
