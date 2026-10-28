//
//  OrganisationSettingsHubView.swift
//  Project Planner
//
//  Admin hub — layer 2 of settings (see DesignReference/project_planner_settings_two_layers.html).
//

import SwiftUI

struct OrganisationSettingsHubView: View {
    @EnvironmentObject var firebaseBackend: FirebaseBackend
    @EnvironmentObject var userStore: UserStore
    @EnvironmentObject var appSettings: AppSettingsStore
    @EnvironmentObject var notificationService: NotificationService
    @EnvironmentObject var holidayStore: HolidayStore
    @EnvironmentObject var operativeStore: OperativeStore
    @EnvironmentObject var bookingStore: BookingStore
    @EnvironmentObject var projectStore: ProjectStore
    @EnvironmentObject var managerScheduleStore: ManagerScheduleStore

    @State private var showingCompanyDetails = false
    @State private var showingDeleteInfo = false

    private var org: Organization? { firebaseBackend.currentOrganization }

    private var policy: OrgPayrollTimePolicy {
        org?.settings.payrollTimePolicy ?? .default
    }

    private var orgInitials: String {
        OrganizationDocumentAbbreviation.display(
            abbreviation: org?.documentAbbreviation,
            organizationName: org?.name
        )
    }

    private var ownerLine: (name: String, isYou: Bool) {
        let users = userStore.organizationUsers
        if let cid = org?.creatorUserId,
           let u = users.first(where: { $0.id == cid }) {
            return (u.fullName.isEmpty ? u.email : u.fullName, u.id == userStore.currentUser?.id)
        }
        if let u = users.first(where: { $0.isSuperAdmin }) {
            return (u.fullName.isEmpty ? u.email : u.fullName, u.id == userStore.currentUser?.id)
        }
        return ("—", false)
    }

    private var roleCountsSubtitle: String {
        let users = userStore.organizationUsers.filter(\.isActive)
        let admins = users.filter { $0.isSuperAdmin || $0.permissions.adminAccess }.count
        let managers = users.filter { !$0.permissions.adminAccess && $0.permissions.manager && !$0.permissions.operativeMode }.count
        let ops = users.filter(\.permissions.operativeMode).count
        return "\(admins) admin · \(managers) managers · \(ops) ops"
    }

    private var currencySubtitle: String {
        let code = org?.settings.currencyCode
        let option = OrganizationCurrencyCatalog.option(for: code?.isEmpty == false ? code : OrganizationCurrencyCatalog.defaultCode(forCountryCode: org?.countryCode ?? "GB"))
        return "\(option.symbol) \(option.code)"
    }

    private var countryLabel: String {
        guard let code = org?.countryCode else { return "—" }
        return CountryCapitalDirectory.supported.first(where: { $0.code == code })?.name ?? code
    }

    /// Signed-in organisation super admin. `isRosterAdmin` also includes ordinary admins, who can open this alert.
    private var signedInUserIsOrganisationSuperAdmin: Bool {
        userStore.currentUser?.isSuperAdmin == true
    }

    private var deleteOrganisationAlertMessage: String {
        if signedInUserIsOrganisationSuperAdmin {
            return "Project Planner is £149 a month or £1,490 a year. VAT is not charged. After the 30-day free trial the plan renews automatically at that price until cancelled. The organisation super admin turns off renewal in the web app, under Settings → Billing. To delete the organisation entirely, email info@projectplanner.us."
        }
        return "Subscriptions can be turned off via the web app. To delete an organisation entirely, please contact info@projectplanner.us"
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                orgHeroCard

                VStack(alignment: .leading, spacing: 0) {
                    hubSectionTitle("Identity")
                    hubCard {
                        hubNavRow(
                            icon: "building.fill",
                            family: .plan,
                            title: "Company details",
                            subtitle: "Name, logo, address"
                        ) {
                            showingCompanyDetails = true
                        }
                        PPRowDivider()
                        NavigationLink {
                            OrganisationCurrencyView()
                                .environmentObject(firebaseBackend)
                        } label: {
                            hubRowLabel(
                                icon: "sterlingsign.circle.fill",
                                family: .trade,
                                title: "Currency",
                                subtitle: currencySubtitle
                            )
                        }
                        .accessibilityIdentifier("organisationSettingsHub.sterlingsignCircleFill")
                        .buttonStyle(PPMenuRowButtonStyle())
                    }

                    hubSectionTitle("Defaults for new operatives")
                    hubCard {
                        NavigationLink {
                            OrganisationWorkingHoursView()
                                .environmentObject(firebaseBackend)
                        } label: {
                            hubRowLabel(
                                icon: "clock.fill",
                                family: .plan,
                                title: "Working hours & overtime",
                                subtitle: hoursSubtitle
                            )
                        }
                        .accessibilityIdentifier("organisationSettingsHub.clockFill")
                        .buttonStyle(PPMenuRowButtonStyle())
                        PPRowDivider()
                        NavigationLink {
                            OrganisationAnnualLeaveDefaultsView()
                                .environmentObject(firebaseBackend)
                        } label: {
                            hubRowLabel(
                                icon: "beach.umbrella.fill",
                                family: .sites,
                                title: "Annual leave",
                                subtitle: annualLeaveDefaultsSubtitle
                            )
                        }
                        .accessibilityIdentifier("organisationSettingsHub.beachUmbrellaFill")
                        .buttonStyle(PPMenuRowButtonStyle())
                    }

                    hubSectionTitle("Booking & scheduling")
                    hubCard {
                        NavigationLink {
                            MyScheduleGeneralOptionsView()
                                .environmentObject(appSettings)
                        } label: {
                            hubRowLabel(
                                icon: "calendar.badge.clock",
                                family: .plan,
                                title: "Schedule options",
                                subtitle: scheduleOptionsSubtitle
                            )
                        }
                        .accessibilityIdentifier("organisationSettingsHub.calendarBadgeClock")
                        .buttonStyle(PPMenuRowButtonStyle())
                        PPRowDivider()
                        NavigationLink {
                            OrganisationWarningsSettingsView()
                                .environmentObject(firebaseBackend)
                                .environmentObject(operativeStore)
                                .environmentObject(bookingStore)
                                .environmentObject(projectStore)
                                .environmentObject(managerScheduleStore)
                                .environmentObject(userStore)
                                .environmentObject(holidayStore)
                                .environmentObject(appSettings)
                        } label: {
                            hubRowLabel(
                                icon: "exclamationmark.triangle.fill",
                                family: .alert,
                                title: "Warnings",
                                subtitle: "Change and alter warning defaults"
                            )
                        }
                        .accessibilityIdentifier("organisationSettingsHub.exclamationmarkTriangleFill")
                        .buttonStyle(PPMenuRowButtonStyle())
                        PPRowDivider()
                        NavigationLink {
                            OrganisationMaterialCutOffSettingsView()
                                .environmentObject(appSettings)
                                .environmentObject(notificationService)
                        } label: {
                            hubRowLabel(
                                icon: "bell.badge.fill",
                                family: .trade,
                                title: "Material cut-off",
                                subtitle: materialReminderSubtitle
                            )
                        }
                        .accessibilityIdentifier("organisationSettingsHub.bellBadgeFill")
                        .buttonStyle(PPMenuRowButtonStyle())
                    }

                    hubSectionTitle("Payment runs & timesheets", sentenceCase: true)
                    hubCard {
                        NavigationLink {
                            OrganisationInvoicingSettingsView()
                                .environmentObject(firebaseBackend)
                        } label: {
                            hubRowLabel(
                                icon: "doc.text.fill",
                                family: .plan,
                                title: "Payment runs & timesheets",
                                subtitle: invoicingSubtitle
                            )
                        }
                        .accessibilityIdentifier("organisationSettingsHub.docTextFill")
                        .buttonStyle(PPMenuRowButtonStyle())
                    }

                    hubSectionTitle("Team")
                    hubCard {
                        NavigationLink {
                            ManageUsersView()
                                .environmentObject(userStore)
                                .environmentObject(bookingStore)
                                .environmentObject(operativeStore)
                                .environmentObject(holidayStore)
                                .environmentObject(firebaseBackend)
                                .environmentObject(notificationService)
                        } label: {
                            hubRowLabel(
                                icon: "person.3.fill",
                                family: .people,
                                title: "Roles & permissions",
                                subtitle: roleCountsSubtitle
                            )
                        }
                        .accessibilityIdentifier("organisationSettingsHub.person3Fill")
                        .buttonStyle(PPMenuRowButtonStyle())
                    }

                    hubSectionTitle("Danger zone")
                    hubCard(border: PPColor.danger.opacity(0.35)) {
                        Button {
                            showingDeleteInfo = true
                        } label: {
                            HStack(spacing: 13) {
                                PPIconTile(symbol: "trash.fill", family: .alert, size: PPMetrics.menuIcon)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text("Delete Organisation and Cancel Project Planner Membership")
                                        .font(.body)
                                        .foregroundStyle(PPColor.danger)
                                        .fixedSize(horizontal: false, vertical: true)
                                    Text("Permanent · cannot be undone")
                                        .font(.footnote)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer(minLength: 8)
                                Image(systemName: "chevron.right")
                                    .font(.footnote.weight(.semibold))
                                    .foregroundStyle(.tertiary)
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 11)
                            .frame(minHeight: 64)
                            .contentShape(Rectangle())
                        }
                        .accessibilityIdentifier("organisationSettingsHub.delete")
                        .buttonStyle(PPMenuRowButtonStyle())
                    }
                }
                .padding(.bottom, 28)
                .ppContentSheet()
            }
        }
        .background(PPColor.page.ignoresSafeArea())
        .navigationTitle("Organisation")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                VStack(spacing: 0) {
                    Text("Settings ›")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(PPColor.onNavySecondary)
                    Text("Organisation")
                        .font(.headline)
                        .foregroundStyle(.white)
                }
            }
        }
        .ppNavyNavigationBar()
        .sheet(isPresented: $showingCompanyDetails) {
            CompanyDetailsEditView()
                .environmentObject(firebaseBackend)
        }
        .alert("Delete Organisation and Cancel Project Planner Membership", isPresented: $showingDeleteInfo) {
            Button("OK", role: .cancel) { }
                .accessibilityIdentifier("organisationSettingsHub.ok")
        } message: {
            Text(deleteOrganisationAlertMessage)
        }
    }

    /// Home-style navy header: company badge, name, country, owner and start date.
    private var orgHeroCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .center, spacing: 14) {
                Text(orgInitials)
                    .font(.system(orgInitials.count >= 3 ? .headline : .title2, design: .rounded))
                    .fontWeight(.bold)
                    .minimumScaleFactor(0.7)
                    .lineLimit(1)
                    .foregroundStyle(.white)
                    .frame(width: 60, height: 60)
                    .background(PPFamily.plan.gradient, in: RoundedRectangle(cornerRadius: 17, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 17, style: .continuous)
                            .strokeBorder(PPColor.onNavyStroke, lineWidth: 1)
                    )
                PPNavyPageTitle(
                    title: CanonicalBusinessEngine.displayOrganizationName(org?.name) ?? (org?.name ?? ""),
                    subtitle: "\(countryLabel) · Company"
                )
                Spacer(minLength: 0)
            }
            HStack(spacing: 10) {
                Text(PlannerUIInitials.from(ownerLine.name))
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.white)
                    .frame(width: 30, height: 30)
                    .background(PPFamily.people.gradient, in: Circle())
                    .overlay(Circle().strokeBorder(PPColor.onNavyStroke, lineWidth: 1))
                VStack(alignment: .leading, spacing: 1) {
                    Text("OWNER & SUPER ADMIN")
                        .font(.caption2.weight(.semibold))
                        .tracking(1.1)
                        .foregroundStyle(PPColor.onNavySecondary)
                    HStack(spacing: 4) {
                        Text(ownerLine.name)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.white)
                        if ownerLine.isYou {
                            Text("· you")
                                .font(.footnote)
                                .foregroundStyle(PPColor.onNavySecondary)
                        }
                    }
                    .lineLimit(1)
                }
                Spacer(minLength: 8)
                PPOnNavyPill(text: shortCreatedLabel)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(PPColor.onNavyFill)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(PPColor.onNavyStroke, lineWidth: 0.5)
            )
        }
        .padding(.horizontal, PPMetrics.screenGutter)
        .padding(.top, 16)
        .padding(.bottom, PPMetrics.headerBottomPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .ppNavyHeader()
    }

    private var shortCreatedLabel: String {
        let cal = Calendar.current
        let c = org?.createdAt ?? Date()
        let y = cal.component(.year, from: c)
        let m = cal.component(.month, from: c)
        let months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
        let mon = (m >= 1 && m <= 12) ? months[m - 1] : ""
        return "Since \(mon) '\(String(format: "%02d", y % 100))"
    }

    private var hoursSubtitle: String {
        let p = policy
        let wk = formatMult(p.weekdayOutsideStandardMultiplier)
        return "\(p.standardDayStart)–\(p.standardDayEnd) · \(Int(p.standardPaidHours))h · weekday OT \(wk)×"
    }

    private var annualLeaveDefaultsSubtitle: String {
        let d = org?.settings.annualLeaveDefaults ?? .default
        let months = AnnualLeavePolicy.shortMonthSymbols()
        let start = months[max(0, min(11, d.startMonth - 1))]
        let end = months[max(0, min(11, d.endMonth - 1))]
        let daysText = d.daysPerYear.truncatingRemainder(dividingBy: 1) == 0
            ? String(Int(d.daysPerYear))
            : String(format: "%.1f", d.daysPerYear)
        let region = BankHolidayRegionDirectory.resolvedRegion(for: org)
        return "\(daysText) days · \(start)→\(end) · \(region.title)"
    }

    private var scheduleOptionsSubtitle: String {
        let o = appSettings.settings.myScheduleOptions
        var n = 0
        if o.showOffice { n += 1 }
        if o.showWorkingFromHome { n += 1 }
        if o.showSiteSurvey { n += 1 }
        n += o.customItems.count
        return "\(n) location option\(n == 1 ? "" : "s") in My Schedule"
    }

    private var materialReminderSubtitle: String {
        guard let clock = OrgMaterialCutOff.resolve(
            stored: org?.settings.materialCutOff,
            organizationLoaded: org != nil
        ) else {
            return "Company material cut-off"
        }
        guard clock.materialOrderCutOff else { return "Notifications off" }
        guard let label = CanonicalBusinessEngine.formatMaterialCutOffClock(clock) else {
            return "Daily reminder"
        }
        return "Daily at \(label)"
    }

    private func formatMult(_ v: Double) -> String {
        if v == floor(v) { return String(format: "%.0f", v) }
        return String(format: "%.1f", v)
    }

    private var invoicingSubtitle: String {
        let invoicing = org?.settings.invoicing ?? .default
        switch invoicing.paymentRunMode {
        case .dateRanges:
            return invoicing.normalizedRanges
                .map { "\($0.startDay)-\($0.endDay)" }
                .joined(separator: " · ")
        case .recurringTimeframe:
            return "Recurring: \(invoicing.recurringRunStartDay.title)-\(invoicing.recurringRunEndDay.title)"
        }
    }
    private func hubSectionTitle(_ t: String, sentenceCase: Bool = false) -> some View {
        PPGroupLabel(text: t)
    }

    private func hubCard(border: Color? = nil, @ViewBuilder content: () -> some View) -> some View {
        VStack(spacing: 0) {
            content()
        }
        .background(PPColor.card)
        .clipShape(RoundedRectangle(cornerRadius: PPMetrics.cardRadius, style: .continuous))
        .overlay {
            if let border {
                RoundedRectangle(cornerRadius: PPMetrics.cardRadius, style: .continuous)
                    .strokeBorder(border, lineWidth: 1)
            }
        }
    }

    private func hubNavRow(
        icon: String,
        family: PPFamily,
        title: String,
        subtitle: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            hubRowLabel(icon: icon, family: family, title: title, subtitle: subtitle)
        }
        .accessibilityIdentifier("organisationSettingsHub.\(AccessibilityID.token(title))")
        .buttonStyle(PPMenuRowButtonStyle())
    }

    private func hubRowLabel(
        icon: String,
        family: PPFamily,
        title: String,
        subtitle: String
    ) -> some View {
        PPMenuRowLabel(title: title, symbol: icon, family: family, subtitle: subtitle)
    }
}
