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

    @State private var showingCompanyDetails = false
    @State private var showingDeleteInfo = false

    private var org: Organization? { firebaseBackend.currentOrganization }

    private var policy: OrgPayrollTimePolicy {
        org?.settings.payrollTimePolicy ?? .default
    }

    private var orgInitials: String {
        guard let n = org?.name, !n.isEmpty else { return "OR" }
        return PlannerUIInitials.from(n, maxLen: 2)
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

    private var countryLabel: String {
        guard let code = org?.countryCode else { return "—" }
        return CountryCapitalDirectory.supported.first(where: { $0.code == code })?.name ?? code
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                orgHeroCard
                    .padding(.top, 8)

                hubSectionTitle("Identity")
                hubCard {
                    hubNavRow(
                        icon: "building.fill",
                        iconBg: ProjectWorksRevampColors.blue.opacity(0.12),
                        iconFg: ProjectWorksRevampColors.blue,
                        title: "Company details",
                        subtitle: "Name, logo, address"
                    ) {
                        showingCompanyDetails = true
                    }
                    Divider().overlay(ProjectWorksRevampColors.border).padding(.leading, 54)
                    hubChevronRow(
                        icon: "sterlingsign.circle.fill",
                        iconBg: ProjectWorksRevampColors.upcomingAmber.opacity(0.18),
                        iconFg: ProjectWorksRevampColors.upcomingAmber,
                        title: "Currency & region",
                        subtitle: "GBP · \(countryLabel)"
                    )
                }

                hubSectionTitle("Defaults for new operatives")
                hubCard {
                    NavigationLink {
                        OrganisationWorkingHoursView()
                            .environmentObject(firebaseBackend)
                    } label: {
                        hubRowLabel(
                            icon: "clock.fill",
                            iconBg: ProjectWorksRevampColors.jobTypePillBg,
                            iconFg: ProjectWorksRevampColors.jobTypePillInk,
                            title: "Working hours & overtime",
                            subtitle: hoursSubtitle
                        )
                    }
                    .buttonStyle(.plain)
                    Divider().overlay(ProjectWorksRevampColors.border).padding(.leading, 54)
                    NavigationLink {
                        HolidayView(showRequests: true)
                            .environmentObject(holidayStore)
                            .environmentObject(userStore)
                            .environmentObject(operativeStore)
                            .environmentObject(firebaseBackend)
                            .environmentObject(notificationService)
                            .environmentObject(appSettings)
                    } label: {
                        hubRowLabel(
                            icon: "beach.umbrella.fill",
                            iconBg: ProjectWorksRevampColors.endDateBg,
                            iconFg: ProjectWorksRevampColors.endDateFg,
                            title: "Annual leave",
                            subtitle: "Allowance, approvals, calendar"
                        )
                    }
                    .buttonStyle(.plain)
                }

                hubSectionTitle("Booking & scheduling")
                hubCard {
                    NavigationLink {
                        MyScheduleGeneralOptionsView()
                            .environmentObject(appSettings)
                    } label: {
                        hubRowLabel(
                            icon: "calendar.badge.clock",
                            iconBg: ProjectWorksRevampColors.pinRoseBg,
                            iconFg: ProjectWorksRevampColors.pinRoseFg,
                            title: "Schedule options",
                            subtitle: scheduleOptionsSubtitle
                        )
                    }
                    .buttonStyle(.plain)
                    Divider().overlay(ProjectWorksRevampColors.border).padding(.leading, 54)
                    HStack(spacing: 12) {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(ProjectWorksRevampColors.upcomingAmber.opacity(0.18))
                            .frame(width: 30, height: 30)
                            .overlay(
                                Image(systemName: "bell.badge.fill")
                                    .font(.system(size: 14, weight: .medium))
                                    .foregroundStyle(ProjectWorksRevampColors.upcomingAmber)
                            )
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Reminders & cut-offs")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(ProjectWorksRevampColors.ink)
                            Text(materialReminderSubtitle)
                                .font(.system(size: 11, weight: .regular))
                                .foregroundStyle(ProjectWorksRevampColors.muted)
                        }
                        Spacer()
                        Toggle("", isOn: Binding(
                            get: { appSettings.settings.notifications.materialOrderCutOff },
                            set: { v in Task { await updateMaterial(v) } }
                        ))
                            .labelsHidden()
                            .tint(ProjectWorksRevampColors.blue)
                    }
                    .padding(.vertical, 11)
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
                    } label: {
                        hubRowLabel(
                            icon: "person.3.fill",
                            iconBg: ProjectWorksRevampColors.activeGreen.opacity(0.15),
                            iconFg: ProjectWorksRevampColors.activeGreen,
                            title: "Roles & permissions",
                            subtitle: roleCountsSubtitle
                        )
                    }
                    .buttonStyle(.plain)
                }

                hubSectionTitle("Danger zone")
                hubCard(border: ProjectWorksRevampColors.requiredPillBg) {
                    Button {
                        showingDeleteInfo = true
                    } label: {
                        HStack(spacing: 12) {
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(ProjectWorksRevampColors.requiredPillBg)
                                .frame(width: 30, height: 30)
                                .overlay(
                                    Image(systemName: "trash.fill")
                                        .font(.system(size: 13, weight: .medium))
                                        .foregroundStyle(ProjectWorksRevampColors.requiredPillFg)
                                )
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Delete organisation")
                                    .font(.system(size: 13, weight: .medium))
                                    .foregroundStyle(ProjectWorksRevampColors.requiredPillFg)
                                Text("Permanent · cannot be undone")
                                    .font(.system(size: 11, weight: .regular))
                                    .foregroundStyle(ProjectWorksRevampColors.muted)
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(ProjectWorksRevampColors.placeholderInk)
                        }
                        .padding(.vertical, 11)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 18)
            .padding(.bottom, 28)
        }
        .background(ProjectWorksRevampColors.canvas.ignoresSafeArea())
        .navigationTitle("Organisation")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                VStack(spacing: 0) {
                    Text("Settings ›")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(ProjectWorksRevampColors.muted)
                    Text("Organisation")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(ProjectWorksRevampColors.ink)
                }
            }
        }
        .appChromeNavigationBarSurface()
        .sheet(isPresented: $showingCompanyDetails) {
            CompanyDetailsEditView()
                .environmentObject(firebaseBackend)
        }
        .alert("Delete organisation", isPresented: $showingDeleteInfo) {
            Button("OK", role: .cancel) { }
        } message: {
            Text("Organisation deletion is not available in the app. Contact support if you need to close an account.")
        }
    }

    private var orgHeroCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 13, style: .continuous)
                        .fill(Color.white.opacity(0.18))
                        .frame(width: 50, height: 50)
                    Text(orgInitials)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(.white)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(org?.name ?? "Organisation")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(.white)
                    Text("\(countryLabel) · Company")
                        .font(.system(size: 11, weight: .regular))
                        .foregroundStyle(.white.opacity(0.88))
                }
                Spacer(minLength: 0)
            }
            Rectangle()
                .fill(Color.white.opacity(0.2))
                .frame(height: 0.5)
            HStack(spacing: 10) {
                ZStack {
                    Circle()
                        .fill(
                            LinearGradient(
                                colors: [ProjectWorksRevampColors.pinRoseFg, Color(red: 0.76, green: 0.33, blue: 0.47)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: 26, height: 26)
                    Text(PlannerUIInitials.from(ownerLine.name))
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.white)
                }
                .overlay(Circle().stroke(Color.white.opacity(0.4), lineWidth: 1.5))
                VStack(alignment: .leading, spacing: 0) {
                    Text("OWNER & SUPER ADMIN")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.white.opacity(0.85))
                        .tracking(0.3)
                    HStack(spacing: 4) {
                        Text(ownerLine.name)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.white)
                        if ownerLine.isYou {
                            Text("· you")
                                .font(.system(size: 10, weight: .regular))
                                .foregroundStyle(.white.opacity(0.75))
                        }
                    }
                }
                Spacer()
                Text(shortCreatedLabel)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.white.opacity(0.95))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Color.white.opacity(0.18))
                    .clipShape(Capsule())
            }
        }
        .padding(16)
        .background(
            LinearGradient(
                colors: [ProjectWorksRevampColors.blue, ProjectWorksRevampColors.blueLight],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
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
        appSettings.settings.notifications.materialOrderCutOff ? "Material cut-off on" : "Material cut-off off"
    }

    private func formatMult(_ v: Double) -> String {
        if v == floor(v) { return String(format: "%.0f", v) }
        return String(format: "%.1f", v)
    }

    private func updateMaterial(_ enabled: Bool) async {
        var updated = appSettings.settings.notifications
        updated.materialOrderCutOff = enabled
        await appSettings.updateNotifications(updated)
        await notificationService.refreshDailyMaterialCutOffReminder()
    }

    private func hubSectionTitle(_ t: String) -> some View {
        Text(t.uppercased())
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(ProjectWorksRevampColors.muted)
            .tracking(0.4)
            .padding(.leading, 4)
            .padding(.top, 18)
            .padding(.bottom, 8)
    }

    private func hubCard(border: Color = ProjectWorksRevampColors.border, @ViewBuilder content: () -> some View) -> some View {
        VStack(spacing: 0) {
            content()
        }
        .padding(.horizontal, 14)
        .background(Color.white)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(border, lineWidth: 0.5)
        )
    }

    private func hubNavRow(
        icon: String,
        iconBg: Color,
        iconFg: Color,
        title: String,
        subtitle: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            hubRowLabel(icon: icon, iconBg: iconBg, iconFg: iconFg, title: title, subtitle: subtitle)
        }
        .buttonStyle(.plain)
    }

    private func hubChevronRow(
        icon: String,
        iconBg: Color,
        iconFg: Color,
        title: String,
        subtitle: String
    ) -> some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(iconBg)
                .frame(width: 30, height: 30)
                .overlay(
                    Image(systemName: icon)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(iconFg)
                )
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 11, weight: .regular))
                    .foregroundStyle(ProjectWorksRevampColors.muted)
                Text(subtitle)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(ProjectWorksRevampColors.ink)
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(ProjectWorksRevampColors.placeholderInk)
        }
        .padding(.vertical, 11)
    }

    private func hubRowLabel(
        icon: String,
        iconBg: Color,
        iconFg: Color,
        title: String,
        subtitle: String
    ) -> some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(iconBg)
                .frame(width: 30, height: 30)
                .overlay(
                    Image(systemName: icon)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(iconFg)
                )
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(ProjectWorksRevampColors.ink)
                Text(subtitle)
                    .font(.system(size: 11, weight: .regular))
                    .foregroundStyle(ProjectWorksRevampColors.muted)
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(ProjectWorksRevampColors.placeholderInk)
        }
        .padding(.vertical, 11)
    }
}
