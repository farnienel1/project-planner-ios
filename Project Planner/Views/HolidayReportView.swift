import SwiftUI

struct HolidayReportView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var holidayStore: HolidayStore
    @EnvironmentObject var operativeStore: OperativeStore
    @EnvironmentObject var userStore: UserStore
    @EnvironmentObject var firebaseBackend: FirebaseBackend
    /// RULEBOOK 1.40.0 / 1.54.0: the employment type of the person's balance, from the pay record (`privatePay`).
    @StateObject private var leaveEmploymentModel = AnnualLeaveEmploymentModel()

    let user: AppUser

    /// The chosen leave year's start day key; nil = the current leave year.
    @State private var selectedYearStart: String?

    init(user: AppUser) {
        self.user = user
    }

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    VStack(alignment: .leading, spacing: 18) {
                        header
                        yearPicker
                    }
                    .padding(.horizontal, PPMetrics.screenGutter)
                    .padding(.top, 16)
                    .padding(.bottom, PPMetrics.headerBottomPadding)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .ppNavyHeader()

                    VStack(alignment: .leading, spacing: 0) {
                        summaryCard
                        bookingsList
                    }
                    .padding(.top, 20)
                    .padding(.bottom, 28)
                    .ppContentSheet()
                }
            }
            .background(PPColor.page.ignoresSafeArea())
            .navigationTitle("Annual leave report")
            .navigationBarTitleDisplayMode(.inline)
            .ppNavyNavigationBar()
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { dismiss() }
                        .accessibilityIdentifier("holidayReport.done")
                        .fontWeight(.semibold)
                        .foregroundStyle(.white)
                }
            }
            .task {
                await holidayStore.loadData()
            }
        }
    }

    private var header: some View {
        PPNavyPageTitle(eyebrow: "Annual leave report", title: user.fullName, subtitle: user.email)
    }

    private var joinDate: Date {
        // The person's own row (`personDedupeKey`): a ghost's row kept under its id, never another no-email row.
        if let operative = operativeStore.operativeRow(for: user) {
            return operative.startDate
        }
        return user.createdAt
    }

    /// RULEBOOK 1.54.0 §9 `CanonicalBusinessEngine.annualLeaveReportYearMonths`: the leave year the report counts is
    /// the one `annualLeaveBalance` counts for this person on this screen — their own leave year while they have an
    /// allowance today, else the organisation's — from the same inputs as the balance (Edit User). Nil until the
    /// employment type (pay record) is known or when the script did not answer: the report then shows nothing rather
    /// than a different year.
    private var reportYearStartMonth: Int? {
        let employment = leaveEmploymentModel.employment(for: user, backend: firebaseBackend)
        guard employment.ready else { return nil }
        let org = firebaseBackend.currentOrganization?.settings.annualLeaveDefaults ?? .default
        return CanonicalBusinessEngine.annualLeaveReportYearMonths(
            annualLeaveEnabled: user.annualLeaveEnabled,
            startMonth: user.annualLeaveYearStartMonth,
            endMonth: user.annualLeaveYearEndMonth,
            orgStartMonth: org.startMonth,
            orgEndMonth: org.endMonth,
            onDayKey: OrganizationRulebookContext.dayKey(Date()),
            employment: employment.employment
        )?.startMonth
    }

    /// RULEBOOK 1.22.0 §9 `CanonicalBusinessEngine.leaveReportYears`: the person's leave years (1.54.0: the balance's
    /// leave-year start month, `reportYearStartMonth`), from their start date to today, newest first.
    private var availableYears: [RulebookLeaveYear] {
        guard let startMonth = reportYearStartMonth else { return [] }
        return CanonicalBusinessEngine.leaveReportYears(
            firstDayKey: OrganizationRulebookContext.dayKey(joinDate),
            todayDayKey: OrganizationRulebookContext.dayKey(Date()),
            startMonth: startMonth
        ) ?? []
    }

    private var selectedYear: RulebookLeaveYear? {
        let years = availableYears
        return years.first { $0.startDayKey == selectedYearStart } ?? years.first
    }

    /// "2026" for a calendar leave year, else "2026/27".
    private func yearTitle(_ year: RulebookLeaveYear) -> String {
        let start = String(year.startDayKey.prefix(4))
        if year.startDayKey.hasSuffix("-01-01") { return start }
        return "\(start)/\(year.endDayKey.dropFirst(2).prefix(2))"
    }

    /// RULEBOOK 1.22.0 §9 `CanonicalBusinessEngine.leaveReportRows`: approved leave in the leave year, matched under
    /// every id the person goes by (`personIdSet` plus operative ids on their email), weekends and bank holidays out of
    /// multi-day records and half days 0.5 — the count `annualLeaveBalance` takes.
    private var report: RulebookLeaveReport? {
        guard let year = selectedYear, let startMonth = reportYearStartMonth else { return nil }
        let email = user.email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let operativeIds = operativeStore.allOperatives
            .filter { !email.isEmpty && $0.email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == email }
            .map(\.id.uuidString)
        let personIds = RulebookPeople.ownerIds(for: user, users: userStore.organizationUsers) + operativeIds
        let records = holidayStore.bookings.map { booking in
            RulebookLeaveReportRecord(
                id: booking.documentId,
                userId: booking.userId,
                operativeId: booking.operativeIdRaw ?? booking.operativeId?.uuidString,
                startDayKey: booking.startDayKey,
                endDayKey: booking.endDayKey,
                timeSlot: booking.timeSlot.rawValue,
                status: booking.status.rawValue
            )
        }
        return CanonicalBusinessEngine.leaveReportRows(
            records: records,
            personIds: personIds,
            onDayKey: year.startDayKey,
            startMonth: startMonth,
            nonWorkingDayKeys: OrganizationBankHolidays.dayKeys
        )
    }

    private func formatDays(_ days: Double) -> String {
        let text = days == days.rounded() ? String(Int(days)) : String(format: "%.1f", days)
        return "\(text) day\(days == 1 ? "" : "s")"
    }

    /// A leave day key (organisation zone, `CanonicalBusinessEngine.leaveReportRows`) shown in the company's time zone,
    /// never the phone's, so the day printed is the day the report counted.
    private func dayText(_ key: String) -> String {
        guard let date = OrganizationRulebookContext.date(fromDayKey: key) else { return key }
        let formatter = DateFormatter()
        formatter.calendar = OrganizationRulebookContext.calendar
        formatter.timeZone = OrganizationRulebookContext.timeZone
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter.string(from: date)
    }

    private var yearPicker: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(availableYears, id: \.self) { year in
                    let isSelected = selectedYear == year
                    Button {
                        selectedYearStart = year.startDayKey
                    } label: {
                        Text(yearTitle(year))
                            .font(.system(.subheadline, design: .rounded))
                            .fontWeight(.bold)
                            .monospacedDigit()
                            .foregroundStyle(isSelected ? PPColor.navy : Color.white)
                            .padding(.horizontal, 16)
                            .frame(height: 34)
                            .background(
                                Capsule().fill(isSelected ? Color.white : PPColor.onNavyFill)
                            )
                            .overlay(
                                Capsule().strokeBorder(PPColor.onNavyStroke, lineWidth: isSelected ? 0 : 0.5)
                            )
                    }
                        .accessibilityIdentifier("holidayReport.row.\(year.startDayKey.prefix(4))")
                        .buttonStyle(PPPressableButtonStyle())
                }
            }
        }
    }

    private var summaryCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            PPGroupLabel(text: "Summary")
            PPGroupedCard {
                HStack(spacing: 13) {
                    PPIconTile(symbol: "sun.max.fill", family: .plan, size: 38)
                    Text("\(formatDays(report?.totalDays ?? 0)) approved in \(selectedYear.map(yearTitle) ?? "—")")
                        .font(.body.weight(.semibold))
                        .monospacedDigit()
                        .foregroundStyle(.primary)
                    Spacer(minLength: 0)
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var bookingsList: some View {
        VStack(alignment: .leading, spacing: 0) {
            PPGroupLabel(text: "Approved annual leave")
            let rows = report?.rows ?? []
            if rows.isEmpty {
                PPGroupedCard {
                    HStack(spacing: 13) {
                        PPIconTile(symbol: "calendar", family: .system, size: PPMetrics.menuIcon)
                        Text("No approved annual leave for \(selectedYear.map(yearTitle) ?? "this year").")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Spacer(minLength: 0)
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(rows, id: \.id) { row in
                        HStack(spacing: 13) {
                            PPIconTile(symbol: "sun.max.fill", family: .plan, size: PPMetrics.menuIcon)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("\(dayText(row.startDayKey)) – \(dayText(row.endDayKey))")
                                    .font(.body)
                                    .foregroundStyle(.primary)
                                Text(formatDays(row.days))
                                    .font(.footnote)
                                    .monospacedDigit()
                                    .foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 11)
                        .frame(minHeight: 54)
                        .background(PPColor.card, in: RoundedRectangle(cornerRadius: PPMetrics.rowCardRadius, style: .continuous))
                    }
                }
            }
        }
    }
}

#Preview {
    HolidayReportView(user: AppUser(id: "1", email: "test@example.com", organizationId: "org", role: .manager, createdAt: Date(), firstName: "Test", surname: "User", isActive: true, passwordSet: true, permissions: UserPermissions(manager: true), isSuperAdmin: false))
        .environmentObject(HolidayStore())
        .environmentObject(OperativeStore())
        .environmentObject(UserStore())
}

