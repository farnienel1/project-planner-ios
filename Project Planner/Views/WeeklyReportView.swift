import SwiftUI
import UIKit

private enum WeeklyReportColors {
    static let navy = Color(red: 0.043, green: 0.071, blue: 0.125)
    static let cyan = Color(red: 0.055, green: 0.647, blue: 0.914)
    static let blue = Color(red: 0.145, green: 0.388, blue: 0.922)
    static let orange = Color(red: 0.976, green: 0.451, blue: 0.090)
    static let muted = Color(red: 0.392, green: 0.455, blue: 0.545)
    static let light = Color(red: 0.941, green: 0.969, blue: 1.000)
    static let mid = Color(red: 0.886, green: 0.922, blue: 0.965)
    static let redBg = Color(red: 0.996, green: 0.949, blue: 0.949)
    static let redText = Color(red: 0.600, green: 0.106, blue: 0.106)
    static let amber = Color(red: 0.996, green: 0.984, blue: 0.922)
    static let greenBg = Color(red: 0.941, green: 0.992, blue: 0.953)
    static let greenTx = Color(red: 0.086, green: 0.400, blue: 0.204)
}

struct WeeklyReportView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var bookingStore: BookingStore
    @EnvironmentObject var managerScheduleStore: ManagerScheduleStore
    @EnvironmentObject var projectStore: ProjectStore
    @EnvironmentObject var operativeStore: OperativeStore
    @EnvironmentObject var holidayStore: HolidayStore
    @EnvironmentObject var userStore: UserStore
    @EnvironmentObject var firebaseBackend: FirebaseBackend
    @EnvironmentObject var subcontractorStore: SubcontractorStore
    @EnvironmentObject var appSettings: AppSettingsStore

    @StateObject private var warningsService = WarningsService()
    @State private var showingWarningsDetail = false
    @State private var startDate: Date = Calendar.current.startOfDay(for: Date())
    @State private var endDate: Date = Calendar.current.startOfDay(for: Date())
    @State private var showStartPicker = false
    @State private var showEndPicker = false
    @State private var isGenerating = false
    @State private var generatedXLSXURL: URL?
    @State private var generatedPDFURL: URL?
    @State private var showShareXLSX = false
    @State private var showSharePDF = false
    @State private var showGeneratedSuccess = false
    @State private var message: String?
    @State private var dayRateHistoryCollection = OperativeDayRateHistoryCollection.empty
    @State private var logoImage: UIImage?

    private var organizationName: String {
        firebaseBackend.currentOrganization?.name ?? "Organization"
    }

    private var invoicingSettings: OrganizationInvoicingSettings {
        firebaseBackend.currentOrganization?.settings.invoicing ?? .default
    }

    private var invoicingPeriod: InvoicingPeriodInfo {
        InvoicingPeriodResolver.resolve(invoicing: invoicingSettings)
    }

    private var reportDateRange: ClosedRange<Date> {
        let cal = Calendar.current
        let start = cal.startOfDay(for: startDate)
        let end = cal.startOfDay(for: endDate)
        return start...end
    }

    private var hasReportWarnings: Bool {
        let range = reportDateRange
        return !warningsService.operativeBookingClashes(in: range).isEmpty
            || !warningsService.unresolvedManagerClashes(in: range).isEmpty
            || !warningsService.approvedManagerClashes(in: range).isEmpty
            || !warningsService.unbookedLabourWarnings(in: range).isEmpty
            || !warningsService.materialsCutoffWarnings(in: range).isEmpty
    }

    var body: some View {
        NavigationStack {
            weeklyReportScrollContent
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { weeklyReportToolbar }
                .sheet(isPresented: $showingWarningsDetail) { warningsDetailSheet }
                .sheet(isPresented: $showShareXLSX) {
                    if let generatedXLSXURL {
                        WeeklyReportShareSheet(items: [generatedXLSXURL])
                    }
                }
                .sheet(isPresented: $showSharePDF) {
                    if let generatedPDFURL {
                        WeeklyReportShareSheet(items: [generatedPDFURL])
                    }
                }
                .sheet(isPresented: $showGeneratedSuccess) {
                    reportGeneratedSuccessSheet
                        .presentationDetents([.medium, .large])
                        .presentationDragIndicator(.visible)
                }
                .onAppear {
                    setThisWeekRange()
                    refreshReportWarnings()
                    Task { await loadOrganizationLogo() }
                }
                .onChange(of: startDate) { _, _ in refreshReportWarnings() }
                .onChange(of: endDate) { _, _ in refreshReportWarnings() }
                .onChange(of: bookingStore.bookings) { _, _ in refreshReportWarnings() }
                .onChange(of: managerScheduleStore.managerSiteBookings) { _, _ in refreshReportWarnings() }
        }
    }

    private var weeklyReportScrollContent: some View {
        ZStack {
            Color(.systemGroupedBackground).ignoresSafeArea()
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 24) {
                    brandHeader
                    quickSelectCard
                    customRangeCard
                    invoicingPeriodCard
                    warningsCard
                    generateSection
                    if let message {
                        Text(message)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    Spacer(minLength: 24)
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 20)
            }
        }
    }

    @ToolbarContentBuilder
    private var weeklyReportToolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Button { dismiss() } label: {
                HStack(spacing: 4) {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .semibold))
                    Text("Close")
                        .font(.system(size: 15, weight: .medium))
                }
                .foregroundStyle(WeeklyReportColors.blue)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(WeeklyReportColors.light)
                .clipShape(Capsule())
            }
        }
        ToolbarItem(placement: .principal) {
            Text("Weekly Report")
                .font(.system(size: 17, weight: .semibold))
        }
    }

    private var warningsDetailSheet: some View {
        WarningsDetailView(warningsService: warningsService)
            .environmentObject(projectStore)
            .environmentObject(userStore)
            .environmentObject(operativeStore)
            .environmentObject(bookingStore)
            .environmentObject(managerScheduleStore)
            .environmentObject(firebaseBackend)
            .environmentObject(appSettings)
            .environmentObject(holidayStore)
    }

    // MARK: - UI sections

    private var brandHeader: some View {
        ZStack {
            LinearGradient(
                colors: [WeeklyReportColors.navy, Color(red: 0.043, green: 0.118, blue: 0.224)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 10) {
                    barChartIcon.frame(width: 36, height: 36)
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 0) {
                            Text("PROJECT").font(.system(size: 16, weight: .black)).foregroundStyle(.white).tracking(1.2)
                            Text(" PLANNER").font(.system(size: 16, weight: .black)).foregroundStyle(WeeklyReportColors.cyan).tracking(1.2)
                        }
                        Text(organizationName)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(Color.white.opacity(0.5))
                    }
                    Spacer()
                    if let logoImage {
                        Image(uiImage: logoImage)
                            .resizable()
                            .scaledToFit()
                            .frame(width: 56, height: 44)
                    } else {
                        VStack(alignment: .trailing, spacing: 2) {
                            Text("WEEKLY").font(.system(size: 10, weight: .heavy)).foregroundStyle(WeeklyReportColors.cyan).tracking(2)
                            Text("REPORT").font(.system(size: 10, weight: .heavy)).foregroundStyle(.white.opacity(0.7)).tracking(2)
                        }
                    }
                }
                HStack(spacing: 0) {
                    WeeklyReportColors.orange.frame(width: 40, height: 2)
                    WeeklyReportColors.cyan.frame(height: 2)
                }
                .clipShape(Capsule())
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 16)
        }
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .shadow(color: WeeklyReportColors.navy.opacity(0.35), radius: 12, x: 0, y: 6)
    }

    private var barChartIcon: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.white.opacity(0.08))
            HStack(alignment: .bottom, spacing: 3) {
                ForEach([0.45, 0.9, 0.65, 0.4], id: \.self) { h in
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(WeeklyReportColors.cyan.opacity(0.85))
                        .frame(width: 5, height: 20 * h)
                }
            }
        }
    }

    private var quickSelectCard: some View {
        reportSectionCard(title: "Quick Select", icon: "bolt.fill", iconColor: WeeklyReportColors.cyan) {
            VStack(spacing: 0) {
                quickWeekRow(label: "This Week", subLabel: rangeLabel(thisWeekRange), range: thisWeekRange)
                Divider().padding(.leading, 16)
                quickWeekRow(label: "Last Week", subLabel: rangeLabel(lastWeekRange), range: lastWeekRange)
            }
        }
    }

    private var customRangeCard: some View {
        reportSectionCard(title: "Custom Range", icon: "calendar", iconColor: WeeklyReportColors.blue) {
            VStack(spacing: 0) {
                dateRow(label: "Start", date: $startDate, isExpanded: $showStartPicker)
                Divider().padding(.leading, 16)
                dateRow(label: "End", date: $endDate, isExpanded: $showEndPicker)
            }
        }
    }

    private var invoicingPeriodCard: some View {
        reportSectionCard(title: "Invoicing Period", icon: "calendar.badge.clock", iconColor: WeeklyReportColors.blue) {
            VStack(alignment: .leading, spacing: 12) {
                if invoicingSettings.paymentRunMode == .dateRanges {
                    ForEach(Array(invoicingPeriod.scheduleRows.enumerated()), id: \.offset) { index, row in
                        if index > 0 { Divider() }
                        HStack {
                            Text(row.label).font(.subheadline).foregroundStyle(.secondary)
                            Spacer()
                            Text(row.summary).font(.subheadline.weight(.medium))
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                    }
                    Divider().padding(.leading, 16)
                } else {
                    HStack {
                        Text("Schedule").font(.subheadline).foregroundStyle(.secondary)
                        Spacer()
                        Text(invoicingSettings.recurringRunDisplaySummary)
                            .font(.subheadline.weight(.medium))
                            .multilineTextAlignment(.trailing)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    Divider().padding(.leading, 16)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("CURRENT INVOICING PERIOD")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(WeeklyReportColors.greenTx)
                    Text(invoicingPeriod.currentPeriodLabel)
                        .font(.subheadline.weight(.semibold))
                    Text("Organisation payment runs are configured in Settings → Invoicing.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(WeeklyReportColors.greenBg)
            }
        }
    }

    private var warningsCard: some View {
        reportSectionCard(
            title: "Warnings in Period",
            icon: "exclamationmark.triangle.fill",
            iconColor: hasReportWarnings ? WeeklyReportColors.orange : WeeklyReportColors.greenTx
        ) {
            if !hasReportWarnings {
                HStack(spacing: 10) {
                    ZStack {
                        Circle().fill(WeeklyReportColors.greenBg).frame(width: 36, height: 36)
                        Image(systemName: "checkmark.shield.fill").foregroundStyle(WeeklyReportColors.greenTx)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text("All Clear").font(.subheadline.weight(.semibold)).foregroundStyle(WeeklyReportColors.greenTx)
                        Text("No warnings for this period").font(.caption).foregroundStyle(WeeklyReportColors.muted)
                    }
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
                Divider().padding(.leading, 16)
                Button { showingWarningsDetail = true } label: {
                    HStack {
                        Image(systemName: "exclamationmark.triangle")
                        Text("Open Warnings").font(.subheadline.weight(.medium))
                        Spacer()
                        Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(WeeklyReportColors.muted)
                    }
                    .foregroundStyle(WeeklyReportColors.blue)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                }
                .buttonStyle(.plain)
            } else {
                warningsSummaryContent
            }
        }
    }

    @ViewBuilder
    private var warningsSummaryContent: some View {
        let range = reportDateRange
        let summaries = periodWarningSummaries(in: range)
        HStack(spacing: 8) {
            ForEach(summaries, id: \.label) { item in
                HStack(spacing: 4) {
                    Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 10))
                    Text("\(item.count) \(item.label)").font(.system(size: 11, weight: .semibold))
                }
                .foregroundStyle(item.foreground)
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .background(item.background)
                .clipShape(Capsule())
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        Divider().padding(.leading, 16)
        Button { showingWarningsDetail = true } label: {
            HStack {
                Image(systemName: "arrow.right.circle.fill")
                Text("View All Warnings").font(.subheadline.weight(.medium))
                Spacer()
                Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(WeeklyReportColors.muted)
            }
            .foregroundStyle(WeeklyReportColors.blue)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .buttonStyle(.plain)
    }

    private var generateSection: some View {
        VStack(spacing: 12) {
            HStack(spacing: 6) {
                Image(systemName: "calendar.badge.clock").font(.system(size: 12, weight: .medium)).foregroundStyle(WeeklyReportColors.muted)
                Text("\(formatDate(startDate))  →  \(formatDate(endDate))")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(WeeklyReportColors.muted)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background(Color(.systemBackground))
            .clipShape(Capsule())
            .overlay(Capsule().strokeBorder(WeeklyReportColors.mid, lineWidth: 0.5))

            Button {
                generateReports()
            } label: {
                ZStack {
                    if isGenerating {
                        HStack(spacing: 10) {
                            ProgressView().tint(.white).scaleEffect(0.85)
                            Text("Generating Report…").font(.system(size: 16, weight: .semibold)).foregroundStyle(.white)
                        }
                    } else {
                        HStack(spacing: 8) {
                            Image(systemName: "doc.badge.plus").font(.system(size: 17, weight: .semibold))
                            Text("Generate Report").font(.system(size: 16, weight: .semibold))
                        }
                        .foregroundStyle(.white)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
                .background(LinearGradient(colors: [WeeklyReportColors.blue, WeeklyReportColors.cyan], startPoint: .topLeading, endPoint: .bottomTrailing))
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .shadow(color: WeeklyReportColors.blue.opacity(0.4), radius: 10, x: 0, y: 5)
            }
            .buttonStyle(.plain)
            .disabled(isGenerating)

            Text("Generates Excel (.xlsx) and PDF files ready to share.")
                .font(.system(size: 11))
                .foregroundStyle(WeeklyReportColors.muted)
                .multilineTextAlignment(.center)
        }
    }

    private var reportGeneratedSuccessSheet: some View {
        VStack(spacing: 0) {
            VStack(spacing: 10) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 44))
                    .foregroundStyle(WeeklyReportColors.greenTx)
                    .padding(.top, 8)
                Text("Report Generated Successfully")
                    .font(.title3.weight(.bold))
                Text("Your weekly report is ready to share.")
                    .font(.subheadline)
                    .foregroundStyle(WeeklyReportColors.muted)
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 20)

            HStack(spacing: 12) {
                exportSharePanel(title: "Excel", subtitle: ".xlsx", systemImage: "tablecells.fill", tint: WeeklyReportColors.greenTx) {
                    showShareXLSX = true
                }
                exportSharePanel(title: "PDF", subtitle: ".pdf", systemImage: "doc.richtext.fill", tint: WeeklyReportColors.blue) {
                    showSharePDF = true
                }
            }
            .padding(.horizontal, 20)

            Spacer(minLength: 0)
        }
        .padding(.top, 12)
        .padding(.bottom, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemGroupedBackground))
    }

    private func exportSharePanel(title: String, subtitle: String, systemImage: String, tint: Color, action: @escaping () -> Void) -> some View {
        VStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(.system(size: 28))
                .foregroundStyle(tint)
            Text(title).font(.headline)
            Text(subtitle).font(.caption).foregroundStyle(.secondary)
            Button(action: action) {
                Label("Share", systemImage: "square.and.arrow.up")
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
            }
            .buttonStyle(.borderedProminent)
            .tint(tint)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func reportSectionCard<Content: View>(title: String, icon: String, iconColor: Color, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: icon).font(.system(size: 11, weight: .semibold)).foregroundStyle(iconColor)
                Text(title.uppercased()).font(.system(size: 11, weight: .semibold)).foregroundStyle(WeeklyReportColors.muted).tracking(0.6)
            }
            .padding(.horizontal, 4)
            .padding(.bottom, 8)

            VStack(spacing: 0) { content() }
                .background(Color(.systemBackground))
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .shadow(color: Color.black.opacity(0.05), radius: 8, x: 0, y: 2)
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(WeeklyReportColors.mid.opacity(0.6), lineWidth: 0.5))
        }
    }

    private func quickWeekRow(label: String, subLabel: String, range: (start: Date, end: Date)) -> some View {
        Button {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                startDate = range.start
                endDate = range.end
                showStartPicker = false
                showEndPicker = false
            }
        } label: {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8, style: .continuous).fill(WeeklyReportColors.light).frame(width: 36, height: 36)
                    Image(systemName: "calendar").foregroundStyle(WeeklyReportColors.blue)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(label).font(.system(size: 15, weight: .semibold))
                    Text(subLabel).font(.system(size: 12)).foregroundStyle(WeeklyReportColors.muted)
                }
                Spacer()
                let selected = Calendar.current.isDate(startDate, inSameDayAs: range.start)
                ZStack {
                    Circle().fill(selected ? WeeklyReportColors.blue : WeeklyReportColors.mid.opacity(0.4)).frame(width: 22, height: 22)
                    if selected {
                        Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundStyle(.white)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func dateRow(label: String, date: Binding<Date>, isExpanded: Binding<Bool>) -> some View {
        VStack(spacing: 0) {
            Button {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.75)) {
                    if label == "Start" { showEndPicker = false } else { showStartPicker = false }
                    isExpanded.wrappedValue.toggle()
                }
            } label: {
                HStack {
                    Text(label).font(.system(size: 15, weight: .medium))
                    Spacer()
                    Text(formatDate(date.wrappedValue))
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(WeeklyReportColors.blue)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 5)
                        .background(WeeklyReportColors.light)
                        .clipShape(Capsule())
                    Image(systemName: isExpanded.wrappedValue ? "chevron.up" : "chevron.down")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(WeeklyReportColors.muted)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 13)
            }
            .buttonStyle(.plain)

            if isExpanded.wrappedValue {
                Divider().padding(.leading, 16)
                if label == "End" {
                    DatePicker("", selection: date, in: startDate..., displayedComponents: .date)
                        .datePickerStyle(.graphical)
                        .tint(WeeklyReportColors.blue)
                        .padding(.horizontal, 12)
                        .padding(.bottom, 8)
                } else {
                    DatePicker("", selection: date, displayedComponents: .date)
                        .datePickerStyle(.graphical)
                        .tint(WeeklyReportColors.blue)
                        .padding(.horizontal, 12)
                        .padding(.bottom, 8)
                }
            }
        }
    }

    private struct PeriodWarningChip {
        let label: String
        let count: Int
        let foreground: Color
        let background: Color
    }

    private func periodWarningSummaries(in range: ClosedRange<Date>) -> [PeriodWarningChip] {
        var items: [PeriodWarningChip] = []
        let high = warningsService.operativeBookingClashes(in: range).count + warningsService.unbookedLabourWarnings(in: range).count
        let medium = warningsService.unresolvedManagerClashes(in: range).count + warningsService.approvedManagerClashes(in: range).count
        let low = warningsService.materialsCutoffWarnings(in: range).count
        if high > 0 { items.append(.init(label: "High", count: high, foreground: WeeklyReportColors.redText, background: WeeklyReportColors.redBg)) }
        if medium > 0 { items.append(.init(label: "Medium", count: medium, foreground: Color(red: 0.573, green: 0.251, blue: 0.055), background: WeeklyReportColors.amber)) }
        if low > 0 { items.append(.init(label: "Low", count: low, foreground: WeeklyReportColors.greenTx, background: WeeklyReportColors.greenBg)) }
        return items
    }

    private func loadOrganizationLogo() async {
        guard let logoURL = firebaseBackend.currentOrganization?.companyLogoURL,
              let url = URL(string: logoURL) else { return }
        if let (data, _) = try? await URLSession.shared.data(from: url),
           let image = UIImage(data: data) {
            await MainActor.run { logoImage = image }
        }
    }

    private func refreshReportWarnings() {
        Task {
            let cal = Calendar.current
            let today = cal.startOfDay(for: Date())
            let tomorrow = cal.startOfDay(for: cal.date(byAdding: .day, value: 1, to: today) ?? today)
            let tomorrowProjectIds = Set(
                bookingStore.bookings
                    .filter {
                        cal.isDate($0.date, inSameDayAs: tomorrow) &&
                            ($0.status == .confirmed || $0.status == .tentative)
                    }
                    .map(\.projectId)
            )
            let allProjects = projectStore.projects
            let projectsTomorrow = allProjects.filter { tomorrowProjectIds.contains($0.id) }
            let warningDetection = firebaseBackend.currentOrganization?.settings.warningDetection ?? .default
            let invoicingSettings = firebaseBackend.currentOrganization?.settings.invoicing ?? .default
            let activeOperatives = operativeStore.activeOperatives.isEmpty
                ? operativeStore.allOperatives.filter(\.isActive)
                : operativeStore.activeOperatives
            var materialItemsForTomorrow: [MaterialItem] = []
            if let orgId = firebaseBackend.currentOrganization?.firestoreDocumentId {
                for project in projectsTomorrow {
                    if let items = try? await firebaseBackend.loadMaterialItems(
                        organizationId: orgId,
                        projectId: project.id
                    ) {
                        materialItemsForTomorrow.append(
                            contentsOf: items.filter { cal.isDate($0.date, inSameDayAs: tomorrow) }
                        )
                    }
                }
            }
            await warningsService.updateWarningsAsync(
                operatives: activeOperatives,
                bookings: bookingStore.bookings,
                projects: allProjects,
                users: userStore.organizationUsers,
                managerSiteBookings: managerScheduleStore.managerSiteBookings,
                holidayBookings: holidayStore.bookings,
                payrollTimePolicy: firebaseBackend.currentOrganization?.settings.payrollTimePolicy ?? .default,
                warningDetection: warningDetection,
                invoicingSettings: invoicingSettings,
                labourCoverageStart: startDate,
                labourCoverageEnd: endDate,
                materialOrderCutOffEnabled: appSettings.settings.notifications.materialOrderCutOff,
                materialCutOffOnSaturday: appSettings.settings.notifications.materialCutOffOnSaturday,
                materialCutOffOnSunday: appSettings.settings.notifications.materialCutOffOnSunday,
                projectsWithTomorrowBookings: projectsTomorrow,
                materialItemsForTomorrow: materialItemsForTomorrow
            )
        }
    }

    private func setThisWeekRange() {
        let thisWeek = thisWeekRange
        startDate = thisWeek.start
        endDate = thisWeek.end
    }

    private func setLastWeekRange() {
        let lastWeek = lastWeekRange
        startDate = lastWeek.start
        endDate = lastWeek.end
    }

    private var thisWeekRange: (start: Date, end: Date) {
        let cal = Calendar.current
        let now = Date()
        let weekday = cal.component(.weekday, from: now)
        let daysFromMonday = (weekday + 5) % 7
        let monday = cal.startOfDay(for: cal.date(byAdding: .day, value: -daysFromMonday, to: now) ?? now)
        let sunday = cal.date(byAdding: .day, value: 6, to: monday) ?? monday
        return (monday, sunday)
    }

    private var lastWeekRange: (start: Date, end: Date) {
        let thisWeek = thisWeekRange
        let start = Calendar.current.date(byAdding: .day, value: -7, to: thisWeek.start) ?? thisWeek.start
        let end = Calendar.current.date(byAdding: .day, value: -7, to: thisWeek.end) ?? thisWeek.end
        return (start, end)
    }

    private func rangeLabel(_ range: (start: Date, end: Date)) -> String {
        "\(formatDate(range.start)) - \(formatDate(range.end))"
    }

    private func generateReports() {
        isGenerating = true
        message = nil
        showGeneratedSuccess = false
        Task {
            if let orgId = firebaseBackend.currentOrganization?.firestoreDocumentId {
                dayRateHistoryCollection = (try? await firebaseBackend.loadOperativeDayRateHistory(organizationId: orgId)) ?? .empty
            }
            if logoImage == nil {
                await loadOrganizationLogo()
            }
            do {
                let sections = buildExportSections()
                let exports = try WeeklyReportExportBuilder.makeExports(
                    context: WeeklyReportExportBuilder.Context(
                        organizationName: organizationName,
                        periodStart: startDate,
                        periodEnd: endDate,
                        invoicingPeriodLabel: invoicingPeriod.currentPeriodLabel,
                        logoImage: logoImage,
                        sections: sections
                    )
                )
                await MainActor.run {
                    generatedXLSXURL = exports.xlsx
                    generatedPDFURL = exports.pdf
                    showGeneratedSuccess = true
                    message = nil
                    isGenerating = false
                }
            } catch {
                await MainActor.run {
                    message = "Failed to generate report: \(error.localizedDescription)"
                    isGenerating = false
                }
            }
        }
    }

    private func buildExportSections() -> [WeeklyReportExportBuilder.Section] {
        let range = reportDateRange
        var sections: [WeeklyReportExportBuilder.Section] = []

        var warningRows: [[String]] = []
        for warning in warningsService.operativeBookingClashes(in: range) {
            warningRows.append(clashExportCells(warning, status: "Active — remove booking"))
        }
        for warning in warningsService.unbookedLabourWarnings(in: range) {
            warningRows.append(clashExportCells(warning, status: "Active"))
        }
        for warning in warningsService.unresolvedManagerClashes(in: range) {
            warningRows.append(clashExportCells(warning, status: "Not ticked for report"))
        }
        for warning in warningsService.approvedManagerClashes(in: range) {
            warningRows.append(clashExportCells(warning, status: "Ticked — on report"))
        }
        for warning in warningsService.materialsCutoffWarnings(in: range) {
            warningRows.append(clashExportCells(warning, status: "Active"))
        }
        if warningRows.isEmpty {
            warningRows.append(["", "", "", "", "No warnings in period", "", ""])
        }
        sections.append(
            WeeklyReportExportBuilder.Section(
                title: "⚠  Warnings Summary",
                headers: ["Status", "Priority", "Type", "Date", "Description", "Detail", "For"],
                rows: warningRows,
                totalRow: nil
            )
        )

        let operativeRows = operativeProjectRows()
        let managerRows = managerProjectRows()
        let allProjectRows = consolidateProjectRows(operativeRows + managerRows)
        let grouped = Dictionary(grouping: allProjectRows) { "\($0.projectName)|\($0.jobNumber)" }
        var projectRows: [[String]] = []
        var projectGrandTotal = 0.0
        for key in grouped.keys.sorted() {
            guard let group = grouped[key] else { continue }
            var projectTotal = 0.0
            for row in group.sorted(by: projectWorkRowSort) {
                let tradeCell = row.tradeDisplay == "—" ? "" : row.tradeDisplay
                projectRows.append([row.projectName, row.jobNumber, row.personName, tradeCell, row.role, formatDays(row.days)])
                projectTotal += row.days
                projectGrandTotal += row.days
            }
            projectRows.append(["", "", "", "", "Project Total", formatDays(projectTotal)])
        }
        sections.append(
            WeeklyReportExportBuilder.Section(
                title: "🏗  Project Breakdown",
                headers: ["Project", "Job No.", "Person", "Trade", "Role", "Days"],
                rows: projectRows,
                totalRow: ["", "", "", "", "All Project Work Total", formatDays(projectGrandTotal)]
            )
        )

        var subcontractorTotal = 0.0
        let subRows = subcontractorRows().map { row -> [String] in
            subcontractorTotal += row.days
            return [row.projectName, row.jobNumber, row.subcontractorName, row.subcontractorType, row.timeSlotLabel, formatDays(row.days)]
        }
        sections.append(
            WeeklyReportExportBuilder.Section(
                title: "🔧  Sub Contractors",
                headers: ["Project", "Job No.", "Sub Contractor", "Type", "Time", "Days"],
                rows: subRows,
                totalRow: ["", "", "", "", "Sub Contractor Total", formatDays(subcontractorTotal)]
            )
        )

        var annualLeaveTotal = 0.0
        let leaveRows = annualLeaveRows().map { leave -> [String] in
            annualLeaveTotal += leave.days
            return [leave.personName, leave.role, formatDays(leave.days), "Approved"]
        }
        sections.append(
            WeeklyReportExportBuilder.Section(
                title: "🌴  Annual Leave",
                headers: ["Person", "Role", "Days", "Type"],
                rows: leaveRows,
                totalRow: ["", "", formatDays(annualLeaveTotal), "Annual Leave Total"]
            )
        )

        var additionalScheduleTotal = 0.0
        let scheduleRows = managerAdditionalScheduleRows().map { row -> [String] in
            additionalScheduleTotal += row.days
            return [row.personName, row.role, row.location, row.timeSlotLabel, formatDays(row.days)]
        }
        sections.append(
            WeeklyReportExportBuilder.Section(
                title: "📅  Manager / Admin Additional Schedule",
                headers: ["Person", "Role", "Location", "Time", "Days"],
                rows: scheduleRows,
                totalRow: ["", "", "Total", "", formatDays(additionalScheduleTotal)]
            )
        )

        var totalAmount = 0.0
        var payRows: [[String]] = []
        for person in payrollPersonSummaries() {
            for line in person.lines {
                payRows.append([
                    person.name,
                    person.role,
                    line.rateTypeLabel,
                    formatDays(line.days),
                    formatCurrency(line.rate),
                    formatCurrency(line.pay),
                ])
                totalAmount += line.pay ?? 0
            }
            payRows.append(["", "", "\(person.name) total", "", "", formatCurrency(person.totalPay)])
        }
        sections.append(
            WeeklyReportExportBuilder.Section(
                title: "💷  Pay Summary",
                headers: ["Person", "Role", "Rate Type", "Days", "Rate", "Pay"],
                rows: payRows,
                totalRow: ["", "", "Grand Total", "", "", formatCurrency(totalAmount)]
            )
        )

        return sections
    }

    private func buildCSV() -> String {
        var rows: [[String]] = []
        rows.append(["Weekly Report"])
        rows.append(["From", formatDate(startDate), "To", formatDate(endDate)])
        rows.append([])
        let range = reportDateRange
        rows.append(["WARNINGS SUMMARY"])
        rows.append(["Status", "Priority", "Type", "Date", "Description", "Detail", "For"])

        for warning in warningsService.operativeBookingClashes(in: range) {
            rows.append(clashExportCells(warning, status: "Active — remove booking"))
        }
        for warning in warningsService.unbookedLabourWarnings(in: range) {
            rows.append(clashExportCells(warning, status: "Active"))
        }
        for warning in warningsService.unresolvedManagerClashes(in: range) {
            rows.append(clashExportCells(warning, status: "Not ticked for report"))
        }
        for warning in warningsService.approvedManagerClashes(in: range) {
            rows.append(clashExportCells(warning, status: "Ticked — on report"))
        }
        for warning in warningsService.materialsCutoffWarnings(in: range) {
            rows.append(clashExportCells(warning, status: "Active"))
        }
        if warningsService.operativeBookingClashes(in: range).isEmpty
            && warningsService.unbookedLabourWarnings(in: range).isEmpty
            && warningsService.unresolvedManagerClashes(in: range).isEmpty
            && warningsService.approvedManagerClashes(in: range).isEmpty
            && warningsService.materialsCutoffWarnings(in: range).isEmpty {
            rows.append(["", "", "", "", "No warnings in period", ""])
        }
        rows.append([])
        rows.append(["PROJECT BREAKDOWN"])
        rows.append(["Project", "Job Number", "Person", "Trade", "Role", "Days"])

        let operativeRows = operativeProjectRows()
        let managerRows = managerProjectRows()
        let allProjectRows = consolidateProjectRows(operativeRows + managerRows)
        let grouped = Dictionary(grouping: allProjectRows) { "\($0.projectName)|\($0.jobNumber)" }

        var projectGrandTotal = 0.0
        for key in grouped.keys.sorted() {
            guard let group = grouped[key] else { continue }
            var projectTotal = 0.0
            for row in group.sorted(by: projectWorkRowSort) {
                let tradeCell = row.tradeDisplay == "—" ? "" : row.tradeDisplay
                rows.append([row.projectName, row.jobNumber, row.personName, tradeCell, row.role, formatDays(row.days)])
                projectTotal += row.days
                projectGrandTotal += row.days
            }
            rows.append(["", "", "", "", "Project Total", formatDays(projectTotal)])
            rows.append([])
        }
        rows.append(["", "", "", "", "All Project Work Total", formatDays(projectGrandTotal)])
        rows.append([])
        
        rows.append(["SUB CONTRACTORS"])
        rows.append(["Project", "Job Number", "Sub Contractor", "Type", "Time", "Days"])
        var subcontractorTotal = 0.0
        for row in subcontractorRows() {
            rows.append([
                row.projectName,
                row.jobNumber,
                row.subcontractorName,
                row.subcontractorType,
                row.timeSlotLabel,
                formatDays(row.days)
            ])
            subcontractorTotal += row.days
        }
        rows.append(["", "", "", "", "Sub Contractor Total", formatDays(subcontractorTotal)])
        rows.append([])

        rows.append(["ANNUAL LEAVE"])
        rows.append(["Person", "Role", "Days", "Type"])
        var annualLeaveTotal = 0.0
        for leave in annualLeaveRows() {
            rows.append([leave.personName, leave.role, formatDays(leave.days), "Approved"])
            annualLeaveTotal += leave.days
        }
        rows.append(["", "", formatDays(annualLeaveTotal), "Annual Leave Total"])
        rows.append([])
        
        rows.append(["MANAGER/ADMIN ADDITIONAL SCHEDULE"])
        rows.append(["Person", "Role", "Location", "Time", "Days"])
        var additionalScheduleTotal = 0.0
        for row in managerAdditionalScheduleRows() {
            rows.append([row.personName, row.role, row.location, row.timeSlotLabel, formatDays(row.days)])
            additionalScheduleTotal += row.days
        }
        rows.append(["", "", "Total", "", formatDays(additionalScheduleTotal)])
        rows.append([])

        rows.append(["PAY SUMMARY"])
        rows.append(["Person", "Role", "Rate Type", "Days", "Rate", "Pay"])
        var totalAmount = 0.0
        for person in payrollPersonSummaries() {
            for line in person.lines {
                rows.append([
                    person.name,
                    person.role,
                    line.rateTypeLabel,
                    formatDays(line.days),
                    formatCurrency(line.rate),
                    formatCurrency(line.pay)
                ])
                totalAmount += line.pay ?? 0
            }
            rows.append([
                "",
                "",
                "\(person.name) total",
                "",
                "",
                formatCurrency(person.totalPay)
            ])
        }
        rows.append(["", "", "Grand Total", "", "", formatCurrency(totalAmount)])

        return rows.map { $0.map(csvEscape).joined(separator: ",") }.joined(separator: "\n")
    }

    private func projectWorkRowSort(_ lhs: ProjectWorkRow, _ rhs: ProjectWorkRow) -> Bool {
        if lhs.tradeSortKey != rhs.tradeSortKey {
            return lhs.tradeSortKey < rhs.tradeSortKey
        }
        return lhs.personName.localizedCaseInsensitiveCompare(rhs.personName) == .orderedAscending
    }

    private func operativeProjectRows() -> [ProjectWorkRow] {
        let cal = Calendar.current
        let filtered = bookingStore.bookings.filter { booking in
            let day = cal.startOfDay(for: booking.date)
            return day >= cal.startOfDay(for: startDate)
                && day <= cal.startOfDay(for: endDate)
                && booking.status != .cancelled
        }
        var totals: [String: Double] = [:]
        var rowsMap: [String: ProjectWorkRow] = [:]
        for booking in filtered {
            guard let operative = operativeStore.allOperatives.first(where: { $0.id == booking.operativeId }) else { continue }
            let linkedUser = linkedAppUser(for: operative)
            let project = projectStore.projects.first(where: { $0.id == booking.projectId })
                ?? projectStore.smallWorks.first(where: { $0.id == booking.projectId })
            let projectName = project?.siteName ?? "Unknown"
            let jobNumber = project?.jobNumber ?? "N/A"
            let personName = linkedUser?.fullName.isEmpty == false ? (linkedUser?.fullName ?? operative.name) : operative.name
            let roleLabel = reportRoleLabel(for: linkedUser, fallback: "Operative")
            let key = "\(projectName)|\(jobNumber)|\(personName)|\(roleLabel)"
            let dayValue = bookingDayValue(from: booking)
            totals[key, default: 0] += dayValue
            rowsMap[key] = ProjectWorkRow(
                projectName: projectName,
                jobNumber: jobNumber,
                personName: personName,
                tradeDisplay: operative.displayTradeType,
                tradeSortKey: StaffTradeType.sortKey(presetRaw: operative.tradeTypePreset, custom: operative.tradeTypeCustom),
                role: roleLabel,
                days: totals[key] ?? 0
            )
        }
        return Array(rowsMap.values)
    }

    private func managerProjectRows() -> [ProjectWorkRow] {
        let cal = Calendar.current
        let filtered = managerScheduleStore.managerSiteBookings.filter { booking in
            let day = cal.startOfDay(for: booking.date)
            return day >= cal.startOfDay(for: startDate)
                && day <= cal.startOfDay(for: endDate)
                && (booking.locationType == .project || booking.locationType == .smallWork)
        }
        var totals: [String: Double] = [:]
        var rowsMap: [String: ProjectWorkRow] = [:]
        for booking in filtered {
            guard let user = userStore.organizationUsers.first(where: { $0.id == booking.userId }) else { continue }
            let project = projectStore.projects.first(where: { $0.id == booking.locationId })
                ?? projectStore.smallWorks.first(where: { $0.id == booking.locationId })
            let projectName = project?.siteName ?? "Unknown"
            let jobNumber = project?.jobNumber ?? "N/A"
            let personName = user.fullName
            let roleLabel = reportRoleLabel(for: user, fallback: "Manager")
            let key = "\(projectName)|\(jobNumber)|\(personName)|\(roleLabel)"
            let dayValue = managerDayValue(from: booking)
            totals[key, default: 0] += dayValue
            rowsMap[key] = ProjectWorkRow(
                projectName: projectName,
                jobNumber: jobNumber,
                personName: personName,
                tradeDisplay: user.displayTradeType,
                tradeSortKey: StaffTradeType.sortKey(presetRaw: user.tradeTypePreset, custom: user.tradeTypeCustom),
                role: roleLabel,
                days: totals[key] ?? 0
            )
        }
        return Array(rowsMap.values)
    }

    private func annualLeaveRows() -> [AnnualLeaveRow] {
        let cal = Calendar.current
        let approved = holidayStore.bookings.filter {
            $0.status == .approved && $0.cancellationRequestedAt == nil
        }
        var totals: [String: AnnualLeaveRow] = [:]
        for booking in approved {
            let days = overlappingDays(for: booking, calendar: cal)
            guard days > 0 else { continue }
            let dayValue = days * booking.timeSlot.dayValue
            if let uid = booking.userId, let u = userStore.organizationUsers.first(where: { $0.id == uid }) {
                let key = "\(u.fullName)|\(u.permissions.manager ? "Manager" : "User")"
                var row = totals[key] ?? AnnualLeaveRow(personName: u.fullName, role: u.permissions.manager ? "Manager" : "User", days: 0)
                row.days += dayValue
                totals[key] = row
            } else if let oid = booking.operativeId,
                      let op = operativeStore.allOperatives.first(where: { $0.id == oid }) {
                let key = "\(op.name)|Operative"
                var row = totals[key] ?? AnnualLeaveRow(personName: op.name, role: "Operative", days: 0)
                row.days += dayValue
                totals[key] = row
            }
        }
        return Array(totals.values).sorted(by: { $0.personName < $1.personName })
    }

    private func labourRateSummaries() -> [LabourRateSummary] {
        let cal = Calendar.current
        let operativeBookings = bookingStore.bookings.filter {
            let day = cal.startOfDay(for: $0.date)
            return day >= cal.startOfDay(for: startDate)
                && day <= cal.startOfDay(for: endDate)
                && $0.status != .cancelled
        }
        let managerBookings = managerScheduleStore.managerSiteBookings.filter {
            let day = cal.startOfDay(for: $0.date)
            return day >= cal.startOfDay(for: startDate)
                && day <= cal.startOfDay(for: endDate)
        }
        
        var totals: [String: LabourRateSummary] = [:]
        for booking in operativeBookings {
            guard let operative = operativeStore.allOperatives.first(where: { $0.id == booking.operativeId }) else { continue }
            let opEmail = operative.email.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
            let user = userStore.organizationUsers.first(where: {
                $0.email.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) == opEmail
            })
            let rate = dayRateForOperativeBooking(user: user, operative: operative, on: booking.date)
            let days = bookingDayValue(from: booking)
            let key = labourRateKey(name: operative.name, role: "Operative", rate: rate)
            var summary = totals[key] ?? LabourRateSummary(name: operative.name, role: "Operative", rate: rate, days: 0)
            summary.days += days
            totals[key] = summary
        }
        
        for booking in managerBookings {
            guard appSettings.settings.myScheduleOptions.includesManagerScheduleLocation(booking) else { continue }
            guard let manager = userStore.organizationUsers.first(where: { $0.id == booking.userId }) else { continue }
            let managerName = manager.fullName.isEmpty ? manager.email : manager.fullName
            let rate = dayRateForUserOnDay(userId: manager.id, fallback: manager.dayRate, date: booking.date)
            let days = managerDayValue(from: booking)
            let key = labourRateKey(name: managerName, role: "Manager", rate: rate)
            var summary = totals[key] ?? LabourRateSummary(name: managerName, role: "Manager", rate: rate, days: 0)
            summary.days += days
            totals[key] = summary
        }
        
        return Array(totals.values)
    }
    
    private func managerAdditionalScheduleRows() -> [ManagerAdditionalScheduleRow] {
        let cal = Calendar.current
        let opts = appSettings.settings.myScheduleOptions
        let filtered = managerScheduleStore.managerSiteBookings.filter {
            let day = cal.startOfDay(for: $0.date)
            return day >= cal.startOfDay(for: startDate)
                && day <= cal.startOfDay(for: endDate)
                && ($0.locationType == .office || $0.locationType == .workingFromHome || $0.locationType == .siteSurvey || $0.locationType == .custom)
                && opts.includesManagerScheduleLocation($0)
        }
        return filtered.compactMap { booking in
            guard let person = userStore.organizationUsers.first(where: { $0.id == booking.userId }) else { return nil }
            let personName = person.fullName.isEmpty ? person.email : person.fullName
            let roleLabel = reportRoleLabel(for: person, fallback: "Manager")
            let locationName: String
            if booking.locationType == .custom {
                let custom = booking.customLocationName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                locationName = custom.isEmpty ? "Custom" : custom
            } else {
                locationName = booking.locationType.displayName
            }
            return ManagerAdditionalScheduleRow(
                personName: personName,
                role: roleLabel,
                location: locationName,
                timeSlotLabel: booking.scheduleLabel(policy: firebaseBackend.payrollPolicy(for: booking.date)),
                days: managerDayValue(from: booking)
            )
        }
        .sorted {
            if $0.personName == $1.personName {
                return $0.location < $1.location
            }
            return $0.personName < $1.personName
        }
    }
    
    private func subcontractorRows() -> [SubcontractorWorkRow] {
        let cal = Calendar.current
        let filtered = subcontractorStore.bookings.filter {
            let day = cal.startOfDay(for: $0.date)
            return day >= cal.startOfDay(for: startDate)
                && day <= cal.startOfDay(for: endDate)
                && $0.status != .cancelled
        }
        return filtered.compactMap { booking in
            let project = projectStore.projects.first(where: { $0.id == booking.projectId })
                ?? projectStore.smallWorks.first(where: { $0.id == booking.projectId })
            let subcontractor = subcontractorStore.subcontractors.first(where: { $0.id == booking.subcontractorId })
            guard let project, let subcontractor else { return nil }
            return SubcontractorWorkRow(
                projectName: project.siteName,
                jobNumber: project.jobNumber,
                subcontractorName: subcontractor.name,
                subcontractorType: subcontractor.subcontractorType,
                timeSlotLabel: booking.timeSlot.displayName,
                days: subcontractorDayValue(from: booking.timeSlot)
            )
        }
        .sorted {
            if $0.projectName == $1.projectName {
                return $0.subcontractorName < $1.subcontractorName
            }
            return $0.projectName < $1.projectName
        }
    }
    
    private func labourRateKey(name: String, role: String, rate: Double?) -> String {
        if let rate {
            return "\(name)|\(role)|\(rate)"
        }
        return "\(name)|\(role)|NO_RATE"
    }

    private func calendarDayStart(_ date: Date) -> Date {
        Calendar.current.startOfDay(for: date)
    }

    /// Uses day-rate history keyed by user id; compares **calendar days** so a change effective “tomorrow” does not apply to today’s bookings.
    private func resolvedPayrollRate(user: AppUser?, operative: Operative?, on date: Date) -> ResolvedPayrollRate {
        let policy = firebaseBackend.payrollPolicy(for: date)
        let standardDayHours = max(policy.standardPaidHours, 8)
        return PayrollRateResolver.resolveForTimesheetDay(
            user: user,
            operative: operative,
            on: date,
            history: dayRateHistoryCollection,
            standardDayHours: standardDayHours
        )
    }

    private func dayRateForUserOnDay(userId: String, fallback: Double?, date: Date) -> Double? {
        let user = userStore.organizationUsers.first(where: { $0.id == userId })
        let resolved = resolvedPayrollRate(user: user, operative: nil, on: date)
        return resolved.reportRateValue() ?? fallback
    }

    private func dayRateForOperativeBooking(user: AppUser?, operative: Operative, on date: Date) -> Double? {
        let resolved = resolvedPayrollRate(user: user, operative: operative, on: date)
        return resolved.reportRateValue()
    }

    private func overlappingDays(for booking: HolidayBooking, calendar: Calendar) -> Double {
        let rangeStart = calendar.startOfDay(for: startDate)
        let rangeEnd = calendar.startOfDay(for: endDate)
        let start = max(calendar.startOfDay(for: booking.startDate), rangeStart)
        let end = min(calendar.startOfDay(for: booking.endDate), rangeEnd)
        guard start <= end else { return 0 }
        let days = (calendar.dateComponents([.day], from: start, to: end).day ?? 0) + 1
        return Double(days)
    }

    private func bookingDayValue(from booking: Booking) -> Double {
        booking.reportDayValue(policy: firebaseBackend.payrollPolicy(for: booking.date))
    }

    private func subcontractorDayValue(from timeSlot: TimeSlot) -> Double {
        switch timeSlot {
        case .fullDay: return 1
        case .morning, .afternoon: return 0.5
        default: return 0.5
        }
    }

    private func managerDayValue(from booking: ManagerSiteBooking) -> Double {
        booking.reportDayValue(policy: firebaseBackend.payrollPolicy(for: booking.date))
    }

    private func linkedAppUser(for operative: Operative) -> AppUser? {
        let email = operative.email.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !email.isEmpty else { return nil }
        return userStore.organizationUsers.first {
            $0.email.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) == email
        }
    }

    private func reportRoleLabel(for user: AppUser?, fallback: String) -> String {
        guard let user else { return fallback }
        let adminLike = user.isSuperAdmin || user.permissions.adminAccess || user.role == .admin || user.role == .manager || user.permissions.manager
        return adminLike ? "Admin User" : fallback
    }

    private func consolidateProjectRows(_ rows: [ProjectWorkRow]) -> [ProjectWorkRow] {
        var map: [String: ProjectWorkRow] = [:]
        for row in rows {
            let key = "\(row.projectName)|\(row.jobNumber)|\(row.personName)|\(row.role)"
            if var existing = map[key] {
                existing.days += row.days
                if existing.tradeDisplay == "—", row.tradeDisplay != "—" {
                    existing = ProjectWorkRow(
                        projectName: existing.projectName,
                        jobNumber: existing.jobNumber,
                        personName: existing.personName,
                        tradeDisplay: row.tradeDisplay,
                        tradeSortKey: row.tradeSortKey,
                        role: existing.role,
                        days: existing.days
                    )
                }
                map[key] = existing
            } else {
                map[key] = row
            }
        }
        return Array(map.values)
    }

    private func payrollPersonSummaries() -> [PayrollPersonSummary] {
        struct Acc {
            var name: String
            var role: String
            var resolved: ResolvedPayrollRate
            var normalHours: Double = 0
            var otHours: Double = 0
            var otMultiplier: Double
            var standardDayHours: Double
        }
        var byKey: [String: Acc] = [:]
        let cal = Calendar.current

        let operativeBookings = bookingStore.bookings.filter {
            let day = cal.startOfDay(for: $0.date)
            return day >= cal.startOfDay(for: startDate)
                && day <= cal.startOfDay(for: endDate)
                && $0.status != .cancelled
        }
        for booking in operativeBookings {
            guard let operative = operativeStore.allOperatives.first(where: { $0.id == booking.operativeId }) else { continue }
            let policy = firebaseBackend.payrollPolicy(for: booking.date)
            let linkedUser = linkedAppUser(for: operative)
            let role = reportRoleLabel(for: linkedUser, fallback: "Operative")
            let name = (linkedUser?.fullName.isEmpty == false) ? (linkedUser?.fullName ?? operative.name) : operative.name
            let resolved = resolvedPayrollRate(user: linkedUser, operative: operative, on: booking.date)
            let paid = booking.paidBookedHours(policy: policy)
            let otHours = booking.overtimeHoursBeyondPaidStandard(policy: policy)
            let normalHours = max(0, paid - otHours)
            let otMultiplier = booking.effectiveWeekdayOtMultiplier(policy: policy)
            let standardDayHours = max(policy.standardPaidHours, 0.01)
            let rateKey = resolved.basis == .hourly
                ? "hr-\(resolved.hourlyRate.map { String(format: "%.4f", $0) } ?? "no-rate")"
                : "day-\(resolved.dayRate.map { String(format: "%.4f", $0) } ?? "no-rate")"
            let key = "\(name)|\(role)|\(rateKey)|\(String(format: "%.3f", otMultiplier))"
            var acc = byKey[key] ?? Acc(name: name, role: role, resolved: resolved, otMultiplier: otMultiplier, standardDayHours: standardDayHours)
            acc.normalHours += normalHours
            acc.otHours += otHours
            byKey[key] = acc
        }

        let managerBookings = managerScheduleStore.managerSiteBookings.filter {
            let day = cal.startOfDay(for: $0.date)
            return day >= cal.startOfDay(for: startDate)
                && day <= cal.startOfDay(for: endDate)
                && appSettings.settings.myScheduleOptions.includesManagerScheduleLocation($0)
        }
        for booking in managerBookings {
            guard let manager = userStore.organizationUsers.first(where: { $0.id == booking.userId }) else { continue }
            let policy = firebaseBackend.payrollPolicy(for: booking.date)
            let role = reportRoleLabel(for: manager, fallback: "Manager")
            let name = manager.fullName.isEmpty ? manager.email : manager.fullName
            let linkedOperative = operativeStore.allOperatives.first {
                $0.email.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
                    == manager.email.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
            }
            let resolved = resolvedPayrollRate(user: manager, operative: linkedOperative, on: booking.date)
            let paid = booking.paidBookedHours(policy: policy)
            let otHours = booking.overtimeHoursBeyondPaidStandard(policy: policy)
            let normalHours = max(0, paid - otHours)
            let otMultiplier = booking.effectiveWeekdayOtMultiplier(policy: policy)
            let standardDayHours = max(policy.standardPaidHours, 0.01)
            let rateKey = resolved.basis == .hourly
                ? "hr-\(resolved.hourlyRate.map { String(format: "%.4f", $0) } ?? "no-rate")"
                : "day-\(resolved.dayRate.map { String(format: "%.4f", $0) } ?? "no-rate")"
            let key = "\(name)|\(role)|\(rateKey)|\(String(format: "%.3f", otMultiplier))"
            var acc = byKey[key] ?? Acc(name: name, role: role, resolved: resolved, otMultiplier: otMultiplier, standardDayHours: standardDayHours)
            acc.normalHours += normalHours
            acc.otHours += otHours
            byKey[key] = acc
        }

        let groupedByPerson = Dictionary(grouping: byKey.values) { "\($0.name)|\($0.role)" }
        var summaries: [PayrollPersonSummary] = []
        for (_, entries) in groupedByPerson {
            guard let first = entries.first else { continue }
            var lines: [PayrollRateLine] = []
            var total = 0.0
            for entry in entries.sorted(by: {
                ($0.resolved.reportRateValue() ?? -1) < ($1.resolved.reportRateValue() ?? -1)
            }) {
                if entry.normalHours > 0.0001 {
                    let standard = entry.standardDayHours
                    let pay = entry.resolved.payForHours(entry.normalHours, standardDayHours: standard)
                    let days = entry.normalHours / standard
                    let rateLabel = entry.resolved.basis == .hourly ? "Normal (hourly)" : "Normal"
                    lines.append(
                        PayrollRateLine(
                            rateTypeLabel: rateLabel,
                            days: days,
                            rate: entry.resolved.reportRateValue(),
                            pay: pay
                        )
                    )
                    total += pay
                }
                if entry.otHours > 0.0001 {
                    let standard = entry.standardDayHours
                    let otPay = entry.resolved.payForHours(
                        entry.otHours,
                        standardDayHours: standard,
                        otMultiplier: entry.otMultiplier
                    )
                    let otDays = entry.otHours / standard
                    let otRate: Double?
                    switch entry.resolved.basis {
                    case .dayRate:
                        otRate = entry.resolved.dayRate.map { $0 * entry.otMultiplier }
                    case .hourly:
                        otRate = entry.resolved.hourlyRate.map { $0 * entry.otMultiplier }
                    }
                    let label = abs(entry.otMultiplier - entry.otMultiplier.rounded()) < 0.001
                        ? "OT x\(Int(entry.otMultiplier.rounded()))"
                        : String(format: "OT x%.1f", entry.otMultiplier)
                    let otLabel = entry.resolved.basis == .hourly ? "\(label) (hourly)" : label
                    lines.append(
                        PayrollRateLine(
                            rateTypeLabel: otLabel,
                            days: otDays,
                            rate: otRate,
                            pay: otPay
                        )
                    )
                    total += otPay
                }
            }
            summaries.append(PayrollPersonSummary(name: first.name, role: first.role, lines: lines, totalPay: total))
        }
        return summaries.sorted {
            if $0.name == $1.name { return $0.role < $1.role }
            return $0.name < $1.name
        }
    }

    private func formatDate(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .omitted)
    }

    private func formatDays(_ value: Double) -> String {
        String(format: "%.2f", value)
    }

    private func formatCurrency(_ value: Double?) -> String {
        guard let value else { return "" }
        return String(format: "£%.2f", value)
    }

    private func csvEscape(_ input: String) -> String {
        if input.contains(",") || input.contains("\"") || input.contains("\n") {
            return "\"\(input.replacingOccurrences(of: "\"", with: "\"\""))\""
        }
        return input
    }

    private func clashExportCells(_ warning: Warning, status: String) -> [String] {
        [
            status,
            warning.severity.rawValue.capitalized,
            clashTypeLabel(warning.type),
            warning.occurrenceDate.map(formatDate) ?? "",
            warning.title,
            warning.message,
            warning.affectedPersonNames,
        ]
    }

    private func clashTypeLabel(_ type: Warning.WarningType) -> String {
        switch type {
        case .operativeBookingClash: return "Operative booking clash"
        case .managerLocationClash: return "Manager/admin clash"
        case .unbookedLabour: return "Unbooked labour"
        case .materialsCutoff: return "Material order not placed"
        default: return type.rawValue
        }
    }
}

private struct ProjectWorkRow {
    let projectName: String
    let jobNumber: String
    let personName: String
    let tradeDisplay: String
    let tradeSortKey: String
    let role: String
    var days: Double
}

private struct AnnualLeaveRow {
    let personName: String
    let role: String
    var days: Double
}

private struct LabourRateSummary {
    let name: String
    let role: String
    let rate: Double?
    var days: Double
}

private struct SubcontractorWorkRow {
    let projectName: String
    let jobNumber: String
    let subcontractorName: String
    let subcontractorType: String
    let timeSlotLabel: String
    let days: Double
}

private struct ManagerAdditionalScheduleRow {
    let personName: String
    let role: String
    let location: String
    let timeSlotLabel: String
    let days: Double
}

private struct PayrollRateLine {
    let rateTypeLabel: String
    let days: Double
    let rate: Double?
    let pay: Double?
}

private struct PayrollPersonSummary {
    let name: String
    let role: String
    let lines: [PayrollRateLine]
    let totalPay: Double
}

private struct WeeklyReportShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
