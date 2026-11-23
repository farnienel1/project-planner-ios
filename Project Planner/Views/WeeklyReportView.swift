import SwiftUI
import UIKit

private enum WeeklyReportColors {
    static let navy = Color(red: 0.043, green: 0.071, blue: 0.125)
    static let cyan = Color(red: 0.055, green: 0.647, blue: 0.914)
    static let blue = Color(red: 0.145, green: 0.388, blue: 0.922)
    static let orange = Color(red: 0.976, green: 0.451, blue: 0.090)
    static let muted = ProjectWorksRevampColors.muted
    static let light = ProjectWorksRevampColors.canvas
    static let mid = AppAdaptiveColor.dynamic(
        light: AppAdaptiveColor.rgb(0.886, 0.922, 0.965),
        dark: AppAdaptiveColor.rgb(0.145, 0.165, 0.216)
    )
    static let redBg = ProjectWorksRevampColors.requiredPillBg
    static let redText = ProjectWorksRevampColors.requiredPillFg
    static let amber = AppAdaptiveColor.dynamic(
        light: AppAdaptiveColor.rgb(0.996, 0.984, 0.922),
        dark: AppAdaptiveColor.rgb(0.239, 0.200, 0.090)
    )
    static let greenBg = AppAdaptiveColor.dynamic(
        light: AppAdaptiveColor.rgb(0.941, 0.992, 0.953),
        dark: AppAdaptiveColor.rgb(0.090, 0.220, 0.165)
    )
    static let greenTx = ProjectWorksRevampColors.activeGreen
}

struct WeeklyReportView: View {
    @Environment(\.dismiss) private var dismiss
    // `let` stores — do NOT use @EnvironmentObject / @ObservedObject here.
    // Subscribing to Home's hot stores while the sheet is open re-renders this
    // whole view on every booking/holiday publish and freezes Simulator (process stays alive).
    let bookingStore: BookingStore
    let managerScheduleStore: ManagerScheduleStore
    let projectStore: ProjectStore
    let operativeStore: OperativeStore
    let holidayStore: HolidayStore
    let userStore: UserStore
    let firebaseBackend: FirebaseBackend
    let subcontractorStore: SubcontractorStore
    let appSettings: AppSettingsStore
    let notificationService: NotificationService
    let taskStore: ProjectTaskStore

    /// Private export/scan service — never observe WarningsService.shared on open.
    @State private var exportWarningsService: WarningsService?
    @State private var showingWarningsDetail = false
    private enum QuickRange: Equatable {
        case thisWeek
        case lastWeek
        case invoicing
        case custom
    }

    @State private var startDate: Date
    @State private var endDate: Date
    @State private var quickRange: QuickRange
    @State private var showStartPicker = false
    @State private var showEndPicker = false
    @State private var isGenerating = false
    @State private var generatedXLSXURL: URL?
    @State private var generatedPDFURL: URL?
    @State private var showGeneratedSuccess = false
    @State private var message: String?
    /// The report was refused because someone's pay could not be loaded: Retry reads the pay profiles again.
    @State private var payGateFailed = false
    @State private var dayRateHistoryCollection = OperativeDayRateHistoryCollection.empty
    @State private var logoImage: UIImage?
    @State private var periodHighCount = 0
    @State private var periodMediumCount = 0
    @State private var periodLowCount = 0
    @State private var periodSummaryReady = false
    @State private var timesheetFeed = WeeklyReportTimesheetFeed.empty
    /// RULEBOOK 1.70.0 §7: `deletedPeople` records (`parseFormerPersonDocument`) for `weeklyReportLeaveRows`.
    @State private var formerPeople: [[String: Any]] = []

    init(
        bookingStore: BookingStore,
        managerScheduleStore: ManagerScheduleStore,
        projectStore: ProjectStore,
        operativeStore: OperativeStore,
        holidayStore: HolidayStore,
        userStore: UserStore,
        firebaseBackend: FirebaseBackend,
        subcontractorStore: SubcontractorStore,
        appSettings: AppSettingsStore,
        notificationService: NotificationService,
        taskStore: ProjectTaskStore
    ) {
        self.bookingStore = bookingStore
        self.managerScheduleStore = managerScheduleStore
        self.projectStore = projectStore
        self.operativeStore = operativeStore
        self.holidayStore = holidayStore
        self.userStore = userStore
        self.firebaseBackend = firebaseBackend
        self.subcontractorStore = subcontractorStore
        self.appSettings = appSettings
        self.notificationService = notificationService
        self.taskStore = taskStore
        // The report week is Monday–Sunday in the organisation zone (§1), not this device's zone.
        let cal = OrganizationRulebookContext.calendar
        let now = cal.startOfDay(for: Date())
        let weekday = cal.component(.weekday, from: now)
        let daysFromMonday = (weekday + 5) % 7
        let monday = cal.startOfDay(for: cal.date(byAdding: .day, value: -daysFromMonday, to: now) ?? now)
        let sunday = cal.date(byAdding: .day, value: 6, to: monday) ?? monday
        _startDate = State(initialValue: monday)
        _endDate = State(initialValue: sunday)
        _quickRange = State(initialValue: .thisWeek)
    }

    private var organizationName: String {
        firebaseBackend.currentOrganization?.name ?? "Organization"
    }

    private var invoicingSettings: OrganizationInvoicingSettings {
        firebaseBackend.currentOrganization?.settings.invoicing ?? .default
    }

    private var invoicingPeriod: InvoicingPeriodInfo {
        InvoicingPeriodResolver.resolve(invoicing: invoicingSettings)
    }

    /// The picked day as organisation-zone midnight, the instant bookings are stored at. The pickers
    /// show the organisation zone, so the picked instant's organisation day key is the day chosen.
    private func londonDay(_ picked: Date) -> Date {
        let key = OrganizationRulebookContext.dayKey(picked)
        return OrganizationRulebookContext.date(fromDayKey: key)
            ?? CanonicalBusinessEngine.businessCalendar.startOfDay(for: picked)
    }

    private var reportStartDay: Date { londonDay(min(startDate, endDate)) }
    private var reportEndDay: Date { londonDay(max(startDate, endDate)) }

    private var reportDateRange: ClosedRange<Date> {
        reportStartDay...reportEndDay
    }

    private var hasReportWarnings: Bool {
        periodHighCount + periodMediumCount + periodLowCount > 0
    }

    private var activeWarningsService: WarningsService {
        exportWarningsService ?? WarningsService.shared
    }

    var body: some View {
        NavigationStack {
            weeklyReportScrollContent
                .navigationBarTitleDisplayMode(.inline)
                .ppNavyNavigationBar()
                .toolbar { weeklyReportToolbar }
                .sheet(isPresented: $showingWarningsDetail) { warningsDetailSheet }
                .sheet(isPresented: $showGeneratedSuccess) {
                    reportGeneratedSuccessSheet
                        .presentationDetents([.medium, .large])
                        .presentationDragIndicator(.visible)
                }
                .onAppear {
                    print("🔥🔥🔥 DEBUG: WEEKLY_REPORT_FORM")
                    // Logo loads on Generate / idle — not on open (Simulator jetsam).
                    if firebaseBackend.noteScheduleNeedsFullHistory() {
                        bookingStore.loadData()
                        managerScheduleStore.loadData(force: true)
                    }
                }
        }
    }

    private var weeklyReportScrollContent: some View {
        ZStack {
            PPColor.page.ignoresSafeArea()
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 0) {
                    brandHeader
                    VStack(spacing: 24) {
                        // RULEBOOK §2: read-only offline, labelled "Last updated". The label observes
                        // SmartCacheService itself (renders nothing online), so this view still observes no store.
                        LastUpdatedOfflineLabel()
                            .frame(maxWidth: .infinity, alignment: .leading)
                        quickSelectCard
                        invoicingPeriodCard
                        payrunSnapshotButton
                        Text("Period warnings and pay breakdown are calculated when you tap Generate — this is separate from Home Warnings (live ops from today forward). Live bookings from projects, small works and daily overview feed this snapshot until a timesheet is counter-signed (or self-signed when the person has no line manager). Agreed timesheet figures then replace those days, including price work and expenses.")
                            .font(.system(size: 12))
                            .foregroundStyle(WeeklyReportColors.muted)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 8)
                        generateSection
                        if let message {
                            Text(message)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                        }
                        if payGateFailed {
                            Button("Retry") {
                                payGateFailed = false
                                message = nil
                                userStore.retryPayProfiles()
                            }
                            .font(.footnote.weight(.semibold))
                            .accessibilityIdentifier("weeklyReport.payRetry")
                        }
                        Spacer(minLength: 24)
                    }
                    .padding(.top, 20)
                    .padding(.bottom, 20)
                    .ppContentSheet()
                }
            }
        }
    }

    /// RULEBOOK 1.33.0 §7: Payrun Snapshot (admins only, `canOpenWeeklyReport`; the page itself already asks it). One row
    /// per person with their Timesheet, Overtime, Expenses and Price work state (`payrunSnapshotRows`).
    @ViewBuilder
    private var payrunSnapshotButton: some View {
        if userStore.canOpenWeeklyReport() {
            reportSectionCard(title: "Payrun", icon: "list.bullet.rectangle.portrait.fill", iconColor: WeeklyReportColors.cyan) {
                NavigationLink {
                    PayrunSnapshotView(
                        firebaseBackend: firebaseBackend,
                        userStore: userStore,
                        bookingStore: bookingStore,
                        managerScheduleStore: managerScheduleStore,
                        projectStore: projectStore,
                        operativeStore: operativeStore,
                        notificationService: notificationService
                    )
                } label: {
                    PPMenuRowLabel(
                        title: CanonicalBusinessEngine.payrunSnapshotText("PAYRUN_SNAPSHOT_LABEL", fallback: "Payrun Snapshot"),
                        symbol: "list.bullet.rectangle.portrait.fill",
                        family: .plan,
                        subtitle: "Where everyone's timesheet, overtime, expenses and price work stand"
                    )
                }
                .buttonStyle(PPMenuRowButtonStyle())
                .accessibilityIdentifier("weeklyReport.payrunSnapshot")
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
                        .font(.system(size: 15, weight: .semibold))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Capsule().fill(PPColor.onNavyFill))
                .overlay(Capsule().strokeBorder(PPColor.onNavyStroke, lineWidth: 0.5))
            }
                .accessibilityIdentifier("weeklyReport.close")
        }
        ToolbarItem(placement: .principal) {
            Text("Weekly Report")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.white)
        }
    }

    private var warningsDetailSheet: some View {
        WarningsDetailView(
            warningsService: WarningsService.shared,
            projectStore: projectStore,
            userStore: userStore,
            operativeStore: operativeStore,
            bookingStore: bookingStore,
            managerScheduleStore: managerScheduleStore,
            firebaseBackend: firebaseBackend,
            appSettings: appSettings,
            holidayStore: holidayStore,
            notificationService: notificationService,
            subcontractorStore: subcontractorStore,
            taskStore: taskStore
        )
    }

    // MARK: - UI sections

    private var brandHeader: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 10) {
                    barChartIcon.frame(width: 36, height: 36)
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 0) {
                            Text("PROJECT").font(.system(size: 16, weight: .black)).foregroundStyle(.white).tracking(1.2)
                            Text(" PLANNER").font(.system(size: 16, weight: .black)).foregroundStyle(WeeklyReportColors.cyan).tracking(1.2)
                        }
                        Text(organizationName)
                            .font(.footnote.weight(.medium))
                            .foregroundStyle(PPColor.onNavySecondary)
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
                .padding(.top, 8)
            }

            PPOnNavyPill(
                text: "\(formatDate(startDate))  →  \(formatDate(endDate))",
                symbol: "calendar.badge.clock"
            )
            .padding(.top, 16)
        }
        .padding(.horizontal, PPMetrics.screenGutter)
        .padding(.top, 16)
        .padding(.bottom, PPMetrics.headerBottomPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .ppNavyHeader()
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
                quickWeekRow(label: "This Week", subLabel: rangeLabel(thisWeekRange), selection: .thisWeek)
                Divider().padding(.leading, 16)
                quickWeekRow(label: "Last Week", subLabel: rangeLabel(lastWeekRange), selection: .lastWeek)
                Divider().padding(.leading, 16)
                quickWeekRow(
                    label: "Current invoicing period",
                    subLabel: invoicingPeriod.currentPeriodLabel,
                    selection: .invoicing
                )
                Divider().padding(.leading, 16)
                quickWeekRow(
                    label: "Custom range",
                    subLabel: rangeLabel((start: startDate, end: endDate)),
                    selection: .custom
                )
                if quickRange == .custom {
                    Divider().padding(.leading, 16)
                    dateRow(label: "Start", date: customDateBinding(isEnd: false), isExpanded: $showStartPicker)
                    Divider().padding(.leading, 16)
                    dateRow(label: "End", date: customDateBinding(isEnd: true), isExpanded: $showEndPicker)
                }
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

                Button {
                    applyQuickRange(.invoicing)
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("CURRENT INVOICING PERIOD")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(WeeklyReportColors.greenTx)
                        Text(invoicingPeriod.currentPeriodLabel)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.primary)
                        Text("Tap to use this range · configured in Settings → Invoicing.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .background(WeeklyReportColors.greenBg)
                }
                .accessibilityIdentifier("weeklyReport.currentINVOICINGPERIOD")
                .buttonStyle(.plain)
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
                .accessibilityIdentifier("weeklyReport.exclamationmarkTriangle")
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
        .accessibilityIdentifier("weeklyReport.arrowRightCircleFill")
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
            .background(PPColor.card)
            .clipShape(Capsule())

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
                .background(PPFamily.plan.gradient)
                .clipShape(RoundedRectangle(cornerRadius: PPMetrics.rowCardRadius, style: .continuous))
                .shadow(color: PPFamily.plan.bottom.opacity(0.35), radius: 10, x: 0, y: 5)
            }
            .accessibilityIdentifier("weeklyReport.generatingReport")
            .buttonStyle(PPPressableButtonStyle())
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
                exportSharePanel(title: "Excel", subtitle: ".xlsx", systemImage: "tablecells.fill", tint: WeeklyReportColors.greenTx, url: generatedXLSXURL)
                exportSharePanel(title: "PDF", subtitle: ".pdf", systemImage: "doc.richtext.fill", tint: WeeklyReportColors.blue, url: generatedPDFURL)
            }
            .padding(.horizontal, 20)

            Spacer(minLength: 0)
        }
        .padding(.top, 12)
        .padding(.bottom, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemGroupedBackground))
    }

    private func exportSharePanel(title: String, subtitle: String, systemImage: String, tint: Color, url: URL?) -> some View {
        VStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(.system(size: 28))
                .foregroundStyle(tint)
            Text(title).font(.headline)
            Text(subtitle).font(.caption).foregroundStyle(.secondary)
            if let url {
                // ShareLink presents from this sheet — avoids nested .sheet ("only presenting a single sheet").
                ShareLink(item: url) {
                    Label("Share", systemImage: "square.and.arrow.up")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                }
                .accessibilityIdentifier("weeklyReport.share")
                .buttonStyle(.borderedProminent)
                .tint(tint)
            } else {
                Text("File not ready")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }


    private func reportSectionCard<Content: View>(title: String, icon: String, iconColor: Color, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: icon).font(.footnote.weight(.semibold)).foregroundStyle(iconColor)
                Text(title.uppercased()).font(.footnote.weight(.semibold)).foregroundStyle(.secondary).tracking(0.8)
            }
            .padding(.horizontal, 4)
            .padding(.bottom, 8)

            VStack(spacing: 0) { content() }
                .background(PPColor.card)
                .clipShape(RoundedRectangle(cornerRadius: PPMetrics.cardRadius, style: .continuous))
        }
    }

    private func quickWeekRow(label: String, subLabel: String, selection: QuickRange) -> some View {
        Button {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                applyQuickRange(selection)
            }
        } label: {
            HStack(spacing: 12) {
                PPIconTile(
                    symbol: selection == .custom ? "calendar.badge.plus" : "calendar",
                    family: .plan,
                    size: PPMetrics.menuIcon
                )
                VStack(alignment: .leading, spacing: 1) {
                    Text(label).font(.body).foregroundStyle(.primary)
                    Text(subLabel).font(.footnote).foregroundStyle(.secondary)
                }
                Spacer()
                let selected = quickRange == selection
                ZStack {
                    Circle().fill(selected ? PPColor.brand : WeeklyReportColors.mid.opacity(0.4)).frame(width: 22, height: 22)
                    if selected {
                        Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundStyle(.white)
                    }
                }
            }
            .padding(.horizontal, 14)
            .frame(minHeight: 60)
            .contentShape(Rectangle())
        }
        .accessibilityIdentifier("weeklyReport.calendarBadgePlus")
        .buttonStyle(PPMenuRowButtonStyle())
    }

    /// Editing either date leaves the preset and uses exactly these two days.
    private func customDateBinding(isEnd: Bool) -> Binding<Date> {
        Binding(
            get: { isEnd ? endDate : startDate },
            set: { newValue in
                if isEnd {
                    endDate = newValue
                } else {
                    startDate = newValue
                    if endDate < newValue {
                        endDate = newValue
                    }
                }
                quickRange = .custom
            }
        )
    }

    private func applyQuickRange(_ selection: QuickRange) {
        switch selection {
        case .thisWeek:
            let range = thisWeekRange
            startDate = range.start
            endDate = range.end
            showStartPicker = false
            showEndPicker = false
        case .lastWeek:
            let range = lastWeekRange
            startDate = range.start
            endDate = range.end
            showStartPicker = false
            showEndPicker = false
        case .invoicing:
            startDate = invoicingPeriod.currentPeriodStart
            endDate = invoicingPeriod.currentPeriodEnd
            showStartPicker = false
            showEndPicker = false
        case .custom:
            break
        }
        quickRange = selection
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
            .accessibilityIdentifier("weeklyReport.start")
            .buttonStyle(.plain)

            if isExpanded.wrappedValue {
                Divider().padding(.leading, 16)
                if label == "End" {
                    DatePicker("", selection: date, in: startDate..., displayedComponents: .date)
                        .accessibilityIdentifier("weeklyReport.dateRow")
                        .environment(\.timeZone, OrganizationRulebookContext.timeZone)
                        .datePickerStyle(.graphical)
                        .tint(WeeklyReportColors.blue)
                        .padding(.horizontal, 12)
                        .padding(.bottom, 8)
                } else {
                    DatePicker("", selection: date, displayedComponents: .date)
                        .accessibilityIdentifier("weeklyReport.dateRow2")
                        .environment(\.timeZone, OrganizationRulebookContext.timeZone)
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
        if periodHighCount > 0 {
            items.append(.init(label: "High", count: periodHighCount, foreground: WeeklyReportColors.redText, background: WeeklyReportColors.redBg))
        }
        if periodMediumCount > 0 {
            items.append(.init(label: "Medium", count: periodMediumCount, foreground: Color(red: 0.573, green: 0.251, blue: 0.055), background: WeeklyReportColors.amber))
        }
        if periodLowCount > 0 {
            items.append(.init(label: "Low", count: periodLowCount, foreground: WeeklyReportColors.greenTx, background: WeeklyReportColors.greenBg))
        }
        return items
    }

    private func loadOrganizationLogo() async {
        guard let logoURL = firebaseBackend.currentOrganization?.companyLogoURL,
              let url = CanonicalBusinessEngine.safeExternalURL(logoURL) else { return }
        if let (data, _) = try? await URLSession.shared.data(from: url),
           let image = UIImage(data: data) {
            await MainActor.run { logoImage = image }
        }
    }

    /// RULEBOOK §5, §7: the report's warnings are scanned for the chosen range (not copied from the live
    /// detection window), on the private export service so Home's live list is untouched. The scan is the shared
    /// one (`WarningsComputation`): `operativeClashGroups` (High), `managerClashGroups` (Medium) and
    /// `unbookedLabourRows` over the range's days (weekends only with include-weekends) — as web
    /// `weeklyReportData`. Approved clashes (`isClashApproved` / `isClashGroupApproved`) are listed separately
    /// and are not counted as open. Returns false when the scan could not run (the reason is in `message`).
    private func refreshReportWarnings() async -> Bool {
        let service = exportWarningsService ?? WarningsService(hydrateFromDisk: false)
        exportWarningsService = service
        let range = reportDateRange
        let cal = CanonicalBusinessEngine.businessCalendar

        // Missing bookings must never become unbooked warnings: say why and stop.
        if let reason = WarningsDataCompleteness.blockingReason(
            bookingsLoadFailed: bookingStore.lastLoadFailed,
            managerBookingsLoadFailed: managerScheduleStore.lastLoadFailed,
            bookingDecode: firebaseBackend.lastBookingDecodeReport
        ) {
            periodHighCount = 0
            periodMediumCount = 0
            periodLowCount = 0
            periodSummaryReady = true
            message = reason
            return false
        }

        let start = cal.startOfDay(for: range.lowerBound)
        let end = cal.startOfDay(for: range.upperBound)
        let settings = firebaseBackend.currentOrganization?.settings
        let bookings = bookingStore.bookings.filter {
            let day = cal.startOfDay(for: $0.date)
            return day >= start && day <= end
        }
        let managerBookings = managerScheduleStore.managerSiteBookings.filter {
            let day = cal.startOfDay(for: $0.date)
            return day >= start && day <= end
        }
        // The reader's organisation-zone day keys (`parseHolidayDocument`).
        let startKey = OrganizationRulebookContext.dayKey(start)
        let endKey = OrganizationRulebookContext.dayKey(end)
        let holidays = holidayStore.bookings.filter { $0.endDayKey >= startKey && $0.startDayKey <= endKey }

        await service.updateWarningsAsync(
            // RULEBOOK 1.53.0 (A5): every operative; the rules skip inactive people themselves (`isActive` passed).
            operatives: operativeStore.allOperatives,
            bookings: bookings,
            projects: projectStore.projects,
            users: userStore.organizationUsers,
            managerSiteBookings: managerBookings,
            holidayBookings: holidays,
            payrollTimePolicy: settings?.payrollTimePolicy ?? .default,
            warningDetection: settings?.warningDetection ?? .default,
            invoicingSettings: settings?.invoicing ?? .default,
            labourCoverageStart: start,
            labourCoverageEnd: end,
            unbookedCoverageEnd: end,
            // The material cut-off is a live "tomorrow" warning; it is not part of a period report.
            materialOrderCutOffEnabled: false,
            publishToLiveCache: false
        )
        periodHighCount = service.operativeBookingClashes(in: range, source: .period).count
            + service.unbookedLabourWarnings(in: range, source: .period).count
        periodMediumCount = service.unresolvedManagerClashes(in: range, source: .period).count
        periodLowCount = 0
        periodSummaryReady = true
        print("🔥🔥🔥 DEBUG: WEEKLY_REPORT period scan high=\(periodHighCount) medium=\(periodMediumCount) approved=\(service.approvedManagerClashes(in: range, source: .period).count)")
        return true
    }

    private var thisWeekRange: (start: Date, end: Date) {
        let cal = OrganizationRulebookContext.calendar
        let now = Date()
        let weekday = cal.component(.weekday, from: now)
        let daysFromMonday = (weekday + 5) % 7
        let monday = cal.startOfDay(for: cal.date(byAdding: .day, value: -daysFromMonday, to: now) ?? now)
        let sunday = cal.date(byAdding: .day, value: 6, to: monday) ?? monday
        return (monday, sunday)
    }

    private var lastWeekRange: (start: Date, end: Date) {
        let thisWeek = thisWeekRange
        let start = OrganizationRulebookContext.calendar.date(byAdding: .day, value: -7, to: thisWeek.start) ?? thisWeek.start
        let end = OrganizationRulebookContext.calendar.date(byAdding: .day, value: -7, to: thisWeek.end) ?? thisWeek.end
        return (start, end)
    }

    private func rangeLabel(_ range: (start: Date, end: Date)) -> String {
        "\(formatDate(range.start)) - \(formatDate(range.end))"
    }

    private func generateReports() {
        isGenerating = true
        message = nil
        payGateFailed = false
        showGeneratedSuccess = false
        Task {
            // The report's own range is scanned (§7); the live Warnings window is not used.
            guard await refreshReportWarnings() else {
                await MainActor.run { isGenerating = false }
                return
            }
            // A failed pay-history read is a failure, never an empty history (`PayInputsLoad`): no report with
            // pay worked out from rates that did not load.
            let payInputs = await PayInputsLoad.loadHistory(firebaseBackend)
            if let blocked = PayInputsLoad.blockMessage(state: payInputs.state, organization: firebaseBackend.currentOrganization, scope: .othersPay) {
                await MainActor.run {
                    message = blocked
                    isGenerating = false
                }
                return
            }
            if let history = payInputs.history { dayRateHistoryCollection = history }
            if logoImage == nil {
                await loadOrganizationLogo()
            }
            // RULEBOOK 1.70.0 §7: a deleted person's leave reads "Former: <name>"; a failed read is an empty list.
            if let orgId = firebaseBackend.currentOrganization?.firestoreDocumentId {
                let former = await firebaseBackend.loadFormerPeople(organizationId: orgId)
                await MainActor.run { formerPeople = former }
            }
            let feed = await WeeklyReportTimesheetFeed.load(
                users: userStore.organizationUsers,
                range: reportDateRange,
                settings: invoicingSettings,
                firebaseBackend: firebaseBackend,
                bookingStore: bookingStore,
                managerScheduleStore: managerScheduleStore,
                operativeStore: operativeStore,
                projectStore: projectStore,
                dayRateHistory: dayRateHistoryCollection,
                payrollPolicy: firebaseBackend.currentOrganization?.settings.payrollTimePolicy ?? .default,
                scheduleOptions: appSettings.settings.myScheduleOptions
            )
            timesheetFeed = feed
            // RULEBOOK 1.46.0: an approved week the rulebook could not check stops the report (never priced live).
            if let failed = feed.calculationFailedMessage {
                await MainActor.run {
                    message = failed
                    isGenerating = false
                }
                return
            }
            // RULEBOOK §8 (pay strip, web #342): only the people this report prices are waited for; anyone of them whose
            // pay could not be loaded is named, never priced as "Rate not set" or £0.
            let gate = reportPayGate()
            if gate.status != .ready {
                await MainActor.run {
                    message = gate.message ?? PrivatePayOverlayReadiness.loadingMessage
                    payGateFailed = gate.status == .failed
                    isGenerating = false
                }
                return
            }
            do {
                let sections = try buildExportSections()
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

    private func buildExportSections() throws -> [WeeklyReportExportBuilder.Section] {
        let range = reportDateRange
        var sections: [WeeklyReportExportBuilder.Section] = []
        // RULEBOOK 1.51.0 §7: one call prices the Pay Summary, every check line and every booking's paid days.
        let pay = try weeklyReportPay()

        // RULEBOOK 1.51.0 §7 (Q4d): an open warning reads `WEEKLY_REPORT_WARNING_OPEN` ("Open").
        let open = CanonicalBusinessEngine.weeklyReportWarningOpen
        var warningRows: [[String]] = []
        for warning in activeWarningsService.unresolvedBookingClashes(in: range) {
            warningRows.append(clashExportCells(warning, status: open))
        }
        for warning in activeWarningsService.unbookedLabourWarnings(in: range) {
            warningRows.append(clashExportCells(warning, status: open))
        }
        for warning in activeWarningsService.approvedManagerClashes(in: range) {
            warningRows.append(clashExportCells(warning, status: "Ticked — on report"))
        }
        for warning in activeWarningsService.materialsCutoffWarnings(in: range) {
            warningRows.append(clashExportCells(warning, status: open))
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

        // RULEBOOK 1.51.0 §7 (Q4a): Hours and Paid days from `paidDays` (uncapped, so they tie to the Pay Summary).
        let projectKinds: Set<String> = [ManagerLocationType.project.rawValue, ManagerLocationType.smallWork.rawValue]
        let projectRows = workRows(pay.built, pay.result.paidDays.filter { projectKinds.contains($0.locationKind) })
        let grouped = Dictionary(grouping: projectRows) { "\($0.projectName)|\($0.jobNumber)" }
        var projectCells: [[String]] = []
        var projectHours = 0.0
        var projectDays = 0.0
        for key in grouped.keys.sorted() {
            guard let group = grouped[key] else { continue }
            var groupHours = 0.0
            var groupDays = 0.0
            for row in group.sorted(by: projectWorkRowSort) {
                let tradeCell = row.tradeDisplay == "—" ? "" : row.tradeDisplay
                projectCells.append([row.projectName, row.jobNumber, row.personName, tradeCell, row.role, hoursText(row.hours), daysText(row.days)])
                groupHours += row.hours
                groupDays += row.days
            }
            projectHours += groupHours
            projectDays += groupDays
            projectCells.append(["", "", "", "", "Project Total", hoursText(groupHours), daysText(groupDays)])
        }
        sections.append(
            WeeklyReportExportBuilder.Section(
                title: "🏗  Project Breakdown",
                headers: ["Project", "Job No.", "Person", "Trade", "Role", "Hours", "Paid days"],
                rows: projectCells,
                totalRow: ["", "", "", "", "All Project Work Total", hoursText(projectHours), daysText(projectDays)]
            )
        )

        var subcontractorTotal = 0.0
        let subRows = try subcontractorRows().map { row -> [String] in
            subcontractorTotal += row.days
            return [row.projectName, row.jobNumber, row.subcontractorName, row.subcontractorType, row.timeSlotLabel, daysText(row.days)]
        }
        sections.append(
            WeeklyReportExportBuilder.Section(
                title: "🔧  Sub Contractors",
                headers: ["Project", "Job No.", "Sub Contractor", "Type", "Time", "Days"],
                rows: subRows,
                totalRow: ["", "", "", "", "Sub Contractor Total", daysText(subcontractorTotal)]
            )
        )

        // RULEBOOK 1.51.0 §7 (Q4b): `weeklyReportLeaveRows` — per person under every id and email.
        let leave = CanonicalBusinessEngine.weeklyReportLeaveRows(
            records: WeeklyReportPayInputs.leaveRecords(holidayStore.bookings),
            people: WeeklyReportPayInputs.leavePeople(pay.built.people),
            startDayKey: OrganizationRulebookContext.dayKey(reportStartDay),
            endDayKey: OrganizationRulebookContext.dayKey(reportEndDay),
            nonWorkingDayKeys: OrganizationBankHolidays.dayKeys,
            formerPeople: formerPeople
        ) ?? (rows: [], total: 0)
        sections.append(
            WeeklyReportExportBuilder.Section(
                title: "🌴  Annual Leave",
                headers: ["Person", "Role", "Days", "Type"],
                rows: leave.rows.map { [$0.person, $0.role, daysText($0.days), $0.type] },
                totalRow: ["", "", daysText(leave.total), "Annual Leave Total"]
            )
        )

        // RULEBOOK 1.51.0 §7 (Q4a): the places that are not jobs, from `paidDays`.
        let additionalKinds: Set<String> = [
            ManagerLocationType.office.rawValue,
            ManagerLocationType.workingFromHome.rawValue,
            ManagerLocationType.siteSurvey.rawValue,
            ManagerLocationType.custom.rawValue,
        ]
        let managerByKey = Dictionary(
            managerScheduleStore.managerSiteBookings.map { ($0.documentKey.lowercased(), $0) },
            uniquingKeysWith: { first, _ in first }
        )
        var scheduleHours = 0.0
        var scheduleDays = 0.0
        var scheduleEntries: [(name: String, location: String, cells: [String])] = []
        for day in pay.result.paidDays where additionalKinds.contains(day.locationKind) {
            let person = reportPerson(pay.built, day)
            let booking = managerByKey[day.bookingId.lowercased()]
            let location = additionalLocation(day, booking: booking)
            scheduleHours += day.hours
            scheduleDays += day.days
            let cells: [String] = [person.name, person.role, location, day.time, hoursText(day.hours), daysText(day.days)]
            scheduleEntries.append((name: person.name, location: location, cells: cells))
        }
        scheduleEntries.sort { lhs, rhs in
            if lhs.name == rhs.name { return lhs.location < rhs.location }
            return lhs.name < rhs.name
        }
        let scheduleRows: [[String]] = scheduleEntries.map { $0.cells }
        sections.append(
            WeeklyReportExportBuilder.Section(
                title: "📅  Manager / Admin Additional Schedule",
                headers: ["Person", "Role", "Location", "Time", "Hours", "Paid days"],
                rows: scheduleRows,
                totalRow: ["", "", "Total", "", hoursText(scheduleHours), daysText(scheduleDays)]
            )
        )

        // RULEBOOK 1.29.0 §7: PAYE overtime per person per job (hours only). 1.32.0: per multiplier, "2h at ×1.5 = 3h",
        // a row changed from the organisation rate marked (`payeOvertimeHoursCell`).
        let payeRows = payeOvertimeRows()
        let payeTotal = (payeRows.reduce(0) { $0 + $1.overtimeHours } * 100).rounded() / 100
        sections.append(
            WeeklyReportExportBuilder.Section(
                title: "⏱  PAYE overtime",
                headers: ["Person", "Job No.", "Job", "Overtime hours"],
                rows: payeRows.isEmpty
                    ? [["No PAYE overtime in this period", "", "", ""]]
                    : payeRows.map { [$0.name, $0.jobNumber, $0.jobName, payeOvertimeHoursCell($0)] },
                totalRow: payeRows.isEmpty ? nil : ["", "", "Total", "\(ScheduleCoverageFormat.hours(payeTotal))h"]
            )
        )

        let priceWorkRows = timesheetMoneyRows(\.priceWork)
        var priceWorkTotal = 0.0
        let priceWorkExportRows = priceWorkRows.map { row -> [String] in
            priceWorkTotal += row.amount
            return [row.personName, row.title, row.jobNumber, formatDate(row.date), row.details, formatCurrency(row.amount)]
        }
        sections.append(
            WeeklyReportExportBuilder.Section(
                title: "🧱  Price Work",
                headers: ["Person", "Title", "Job No.", "Date", "Details", "Amount"],
                rows: priceWorkExportRows,
                totalRow: ["", "", "", "", "Price Work Total", formatCurrency(priceWorkTotal)]
            )
        )

        let expenseRows = timesheetMoneyRows(\.expenses)
        var expenseTotal = 0.0
        let expenseExportRows = expenseRows.map { row -> [String] in
            expenseTotal += row.amount
            return [row.personName, row.title, row.jobNumber, formatDate(row.date), row.details, formatCurrency(row.amount)]
        }
        sections.append(
            WeeklyReportExportBuilder.Section(
                title: "🧾  Expenses",
                headers: ["Person", "Title", "Job No.", "Date", "Details", "Amount"],
                rows: expenseExportRows,
                totalRow: ["", "", "", "", "Expenses Total", formatCurrency(expenseTotal)]
            )
        )

        sections.append(Self.paySummarySection(pay.result))
        return sections
    }

    /// RULEBOOK 1.51.0 §7 (Q1–Q3): the Pay Summary as `weeklyReportPayRows` returns it — Person | Role | Dates | Line |
    /// Hours | Days | Rate | Pay (`WEEKLY_REPORT_PAY_COLUMNS`); then "<name> total" and the person's invoice check line
    /// (amber when it does not match); then the Grand Total and `PAY_HIDDEN_NOTE` when someone's pay is hidden. Pay is
    /// already shown per `reportPayForViewer` (inside the rule); nothing is priced or hidden here.
    static func paySummarySection(_ pay: RulebookWeeklyReportPay) -> WeeklyReportExportBuilder.Section {
        var rows: [[String]] = []
        var warnRows = Set<Int>()
        var spanRows = Set<Int>()
        for person in pay.people {
            for line in person.lines {
                let claim = line.source == "claim"
                rows.append([
                    person.person,
                    person.role,
                    line.dates,
                    line.line,
                    claim ? "" : reportHoursText(line.hours),
                    claim ? "" : CanonicalBusinessEngine.weeklyReportDaysText(line.daysExact ?? line.days, kind: line.kind),
                    line.rateText,
                    line.payLabel ?? OrgMoney.format(line.pay),
                ])
            }
            rows.append(["", "", "", "\(person.person) total", "", "", "", person.personTotalLabel ?? OrgMoney.format(person.personTotal)])
            if let check = person.check {
                if check.tone == "warn" { warnRows.insert(rows.count) }
                spanRows.insert(rows.count)
                rows.append(["", "", "", check.label, "", "", "", ""])
            }
        }
        var section = WeeklyReportExportBuilder.Section(
            title: "💷  Pay Summary",
            headers: CanonicalBusinessEngine.weeklyReportPayColumns,
            rows: rows,
            totalRow: ["", "", "", "Grand Total", "", "", "", OrgMoney.format(pay.grandTotal)],
            note: paySummaryNote(pay)
        )
        section.warnRows = warnRows
        section.spanRows = spanRows
        return section
    }

    /// RULEBOOK 1.53.0 (A9): `weeklyReportPaySummaryNote` ("Days are rounded; Pay is worked out from the exact hours.")
    /// and, when some pay is hidden from the viewer, `PAY_HIDDEN_NOTE`.
    static func paySummaryNote(_ pay: RulebookWeeklyReportPay) -> String? {
        let rounded = CanonicalBusinessEngine.weeklyReportPaySummaryNote(pay.people.flatMap(\.lines))
        let hidden = pay.hiddenPeople > 0 ? (CanonicalBusinessEngine.payHiddenNote ?? "") : ""
        let note = [rounded, hidden].filter { !$0.isEmpty }.joined(separator: " ")
        return note.isEmpty ? nil : note
    }

    /// The weekly report's `weeklyReportPayRows` answer for the report range, with the people it names. Throws when
    /// the rulebook did not answer (pay is never shown from a partial calculation).
    /// Web #342: the pay gate over the people this report prices (`pricedUserIds`) and the PAYE people of its overtime
    /// section. Ready when the switch is off.
    private func reportPayGate() -> ReportPayGate {
        guard let built = try? weeklyReportPayInputs() else {
            // The pricing itself fails later with its own calculation message.
            return ReportPayGate(status: .ready, message: nil)
        }
        var ids = WeeklyReportPayInputs.pricedUserIds(built)
        ids.formUnion(payeOvertimePeopleIds())
        let people = userStore.organizationUsers.filter { ids.contains($0.id) }
        return PrivatePayOverlayReadiness.reportGate(people: people)
    }

    /// The users whose ids name an overtime booking in the range (the PAYE overtime section reads their employment type).
    private func payeOvertimePeopleIds() -> Set<String> {
        let cal = CanonicalBusinessEngine.businessCalendar
        let inRange: (Date) -> Bool = { date in
            let day = cal.startOfDay(for: date)
            return day >= reportStartDay && day <= reportEndDay
        }
        var keys = Set(bookingStore.bookings.filter { inRange($0.date) }.map { $0.storedOperativeId.lowercased() })
        for booking in managerScheduleStore.managerSiteBookings where inRange(booking.date) {
            keys.insert(booking.userId.lowercased())
        }
        let users = userStore.organizationUsers
        let operatives = operativeStore.allOperatives
        var out = Set<String>()
        for user in users where !user.isAnonymisedDeletedProfile {
            let ids = OvertimeScreenSupport.personIds(for: user, users: users, operatives: operatives)
            if ids.contains(where: { keys.contains($0.lowercased()) }) { out.insert(user.id) }
        }
        return out
    }

    private func weeklyReportPayInputs() throws -> WeeklyReportPayInputs.Built {
        // The working-hours state with its history (§4.3): never one policy for every day. While it has not loaded the
        // report fails with its calculation error rather than price days on the wrong rules (review of #235).
        guard let organization = CanonicalBusinessEngine.openOrganizationPayrollPolicyState else { throw PayCalculationError() }
        return WeeklyReportPayInputs.build(WeeklyReportPayInputs.Sources(
            users: userStore.organizationUsers,
            bookingNameUsers: userStore.bookingNameUsers,
            operatives: operativeStore.allOperatives,
            bookings: bookingStore.bookings,
            managerBookings: managerScheduleStore.managerSiteBookings,
            projects: projectStore.projects,
            smallWorks: projectStore.smallWorks,
            history: dayRateHistoryCollection,
            organization: organization,
            startDayKey: OrganizationRulebookContext.dayKey(reportStartDay),
            endDayKey: OrganizationRulebookContext.dayKey(reportEndDay),
            timesheetWeeks: timesheetFeed.rulebookWeeksJSON(),
            sheets: timesheetFeed.sheets,
            viewer: userStore.payViewerRow,
            // RULEBOOK 1.53.0: the Role column is the user level (`userLevelLabel`); a person with no account is an operative.
            roleLabel: { user in Self.userLevelText(user) }
        ))
    }

    private func weeklyReportPay() throws -> (result: RulebookWeeklyReportPay, built: WeeklyReportPayInputs.Built) {
        let built = try weeklyReportPayInputs()
        guard let result = CanonicalBusinessEngine.weeklyReportPayRows(built.input) else { throw PayCalculationError() }
        return (result, built)
    }

    /// A paid-days row's person (name, role, trade); "Person not found (id …)" when the booking named nobody.
    private func reportPerson(_ built: WeeklyReportPayInputs.Built, _ day: RulebookWeeklyReportPaidDay) -> (name: String, role: String, user: AppUser?) {
        if let id = day.personId, let person = built.people[id] {
            return (person.name, person.role, person.user)
        }
        let notFound = CanonicalBusinessEngine.constant("WEEKLY_REPORT_PERSON_NOT_FOUND", as: String.self) ?? "Person not found"
        return ("\(notFound) (id \(day.bookingPersonId))", "—", nil)
    }

    /// Project Breakdown rows: one per job and person, hours and paid days added up.
    private func workRows(_ built: WeeklyReportPayInputs.Built, _ days: [RulebookWeeklyReportPaidDay]) -> [ProjectWorkRow] {
        var map: [String: ProjectWorkRow] = [:]
        for day in days {
            let person = reportPerson(built, day)
            let projectName = day.jobName.isEmpty ? "Unknown" : day.jobName
            let jobNumber = day.jobNumber.isEmpty ? "N/A" : day.jobNumber
            let key = "\(projectName)|\(jobNumber)|\(day.personId ?? day.bookingPersonId)"
            var row = map[key] ?? ProjectWorkRow(
                projectName: projectName,
                jobNumber: jobNumber,
                personName: person.name,
                tradeDisplay: StaffEmailIdentity.reportTrade(for: person.user),
                tradeSortKey: StaffTradeType.sortKey(presetRaw: person.user?.tradeTypePreset, custom: person.user?.tradeTypeCustom),
                role: person.role,
                hours: 0,
                days: 0
            )
            row.hours += day.hours
            row.days += day.days
            map[key] = row
        }
        return Array(map.values)
    }

    /// The Additional Schedule's place: a custom place's own name, else the kind's name.
    private func additionalLocation(_ day: RulebookWeeklyReportPaidDay, booking: ManagerSiteBooking?) -> String {
        if day.locationKind == ManagerLocationType.custom.rawValue {
            let custom = (booking?.customLocationName ?? day.jobName).trimmingCharacters(in: .whitespacesAndNewlines)
            return custom.isEmpty || custom == "—" ? "Custom" : custom
        }
        return ManagerLocationType(rawValue: day.locationKind)?.displayName ?? day.jobName
    }

    private func projectWorkRowSort(_ lhs: ProjectWorkRow, _ rhs: ProjectWorkRow) -> Bool {
        if lhs.tradeSortKey != rhs.tradeSortKey {
            return lhs.tradeSortKey < rhs.tradeSortKey
        }
        return lhs.personName.localizedCaseInsensitiveCompare(rhs.personName) == .orderedAscending
    }

    /// Throws `PayCalculationError` when a booking's day value could not be worked out (review of #235: never a guessed 0.5).
    private func subcontractorRows() throws -> [SubcontractorWorkRow] {
        let cal = CanonicalBusinessEngine.businessCalendar
        let filtered = subcontractorStore.bookings.filter {
            let day = cal.startOfDay(for: $0.date)
            return day >= reportStartDay
                && day <= reportEndDay
                && $0.status.occupiesDay  // RULEBOOK `bookingOccupiesDay`
        }
        // RULEBOOK 1.53.0: a booking whose job or firm was deleted still counts, under `bookingJobLabel` ("Deleted job").
        return try filtered.map { booking in
            let project = projectStore.projects.first(where: { $0.id == booking.projectId })
                ?? projectStore.smallWorks.first(where: { $0.id == booking.projectId })
            let subcontractor = subcontractorStore.subcontractors.first(where: { $0.id == booking.subcontractorId })
            let jobName = project.map { $0.siteName.isEmpty ? $0.jobNumber : $0.siteName }
            return SubcontractorWorkRow(
                projectName: CanonicalBusinessEngine.bookingJobLabel(jobName),
                jobNumber: project.map { $0.jobNumber.isEmpty ? "—" : $0.jobNumber } ?? "—",
                subcontractorName: subcontractor?.name ?? "Sub contractor",
                subcontractorType: subcontractor.map { $0.subcontractorType.isEmpty ? "—" : $0.subcontractorType } ?? "—",
                timeSlotLabel: booking.timeSlot.displayName,
                days: try subcontractorDayValue(booking)
            )
        }
        .sorted {
            if $0.projectName == $1.projectName {
                return $0.subcontractorName < $1.subcontractorName
            }
            return $0.projectName < $1.projectName
        }
    }

    /// RULEBOOK 1.51.0 §7 (Q4c) `subcontractorDayValue(timeSlot, { hours, standardDayHours })`: custom hours are the hours
    /// worked (`payrollHoursResult` under that day's working hours) ÷ that day's paid day (`weekdayPaidHours`).
    private func subcontractorDayValue(_ booking: SubcontractorBooking) throws -> Double {
        let policy = firebaseBackend.payrollPolicy(for: booking.date)
        let hours = CanonicalBusinessEngine.payrollHoursResult(RulebookPayrollHoursInput(
            booking: CanonicalPayrollBooking(
                timeSlot: booking.timeSlot.rawValue,
                workStartTime: booking.workStartTime,
                workEndTime: booking.workEndTime,
                isBreakRemoved: booking.isBreakRemoved,
                otMultiplierOverride: nil
            ),
            dayKey: OrganizationRulebookContext.dayKey(booking.date),
            policy: policy
        ))
        guard let paidDay = CanonicalBusinessEngine.weekdayPaidHours(policy),
              let days = CanonicalBusinessEngine.subcontractorDayValue(
                booking.timeSlot.rawValue,
                workedHours: hours?.workedHours,
                standardDayHours: paidDay
              ) else { throw PayCalculationError() }
        return days
    }

    /// RULEBOOK 1.29.0 §7 `weeklyReportPayeOvertime`: one row per PAYE person per job with their overtime hours in the
    /// range, live from the labour and job-linked manager site bookings.
    private func payeOvertimeRows() -> [WeeklyReportPayeOvertimeRow] {
        let cal = CanonicalBusinessEngine.businessCalendar
        let labour = bookingStore.bookings.filter {
            let day = cal.startOfDay(for: $0.date)
            return day >= reportStartDay && day <= reportEndDay
        }.map { OvertimeBookingInputs.labour($0) }
        let manager = managerScheduleStore.managerSiteBookings.filter {
            let day = cal.startOfDay(for: $0.date)
            return day >= reportStartDay && day <= reportEndDay
                && ($0.locationType == .project || $0.locationType == .smallWork) && $0.locationId != nil
        }.map { OvertimeBookingInputs.managerSite($0) }
        let bookings = OvertimeBookingInputs.withJobs(labour + manager, jobs: projectStore.projects + projectStore.smallWorks)
        let users = userStore.organizationUsers
        let operatives = operativeStore.allOperatives
        let people: [[String: Any]] = users.compactMap { user in
            guard !user.isAnonymisedDeletedProfile else { return nil }
            var row = user.overtimeEmploymentPayload
            row["id"] = user.id
            row["name"] = user.fullName.isEmpty ? user.email : user.fullName
            row["ids"] = OvertimeScreenSupport.personIds(for: user, users: users, operatives: operatives)
            return row
        }
        return CanonicalBusinessEngine.weeklyReportPayeOvertime(
            people: people,
            bookings: bookings,
            organization: OvertimeOrganizationDocument.document(firebaseBackend.currentOrganization),
            range: (OrganizationRulebookContext.dayKey(reportStartDay), OrganizationRulebookContext.dayKey(reportEndDay))
        )
    }


    /// RULEBOOK 1.32.0 §7: a PAYE overtime row's hours cell — `multiplierText` ("2h at ×1.5 = 3h"), and on a row whose
    /// bookings carry their own rate (`changedFromOrganization`) `OVERTIME_RATE_CHANGED_MARK` with the organisation's
    /// rate, as web's weekly report shows it.
    private func payeOvertimeHoursCell(_ row: WeeklyReportPayeOvertimeRow) -> String {
        guard row.changedFromOrganization, let mark = CanonicalBusinessEngine.overtimeRateChangedMark else { return row.multiplierText }
        return "\(row.multiplierText) (\(mark), ×\(ScheduleCoverageFormat.hours(row.organizationMultiplier)))"
    }


    /// RULEBOOK 1.53.0 `userLevelLabel(person)`: Admin / Manager / Operative, the Super Admin "Admin (Super Admin)".
    static func userLevelText(_ user: AppUser?) -> String {
        guard let user else { return CanonicalBusinessEngine.userLevelLabel(["role": "operative", "operativeMode": true]) ?? "Operative" }
        return CanonicalBusinessEngine.userLevelLabel(RulebookPeople.person(user)) ?? "—"
    }


    /// RULEBOOK 1.46.0: a booking the rulebook could not price (`bookingPaySlices` did not answer) stops the report with
    /// `TimesheetPayrollSummary.calculationFailedMessage` — pay is never understated by leaving a booking out.
    struct PayCalculationError: LocalizedError {
        var errorDescription: String? { TimesheetPayrollSummary.calculationFailedMessage }
    }


    private func timesheetMoneyRows(
        _ keyPath: KeyPath<TimesheetWeeklyReportOverride, [TimesheetWeeklyReportMoneyLine]>
    ) -> [TimesheetMoneyExportRow] {
        timesheetFeed.moneyLines(keyPath, in: reportDateRange).map { week, line in
            TimesheetMoneyExportRow(
                personName: week.personName,
                title: line.title,
                jobNumber: line.jobNumber,
                date: line.date,
                details: line.details,
                amount: line.amount
            )
        }
        .sorted {
            if $0.personName == $1.personName {
                return $0.date < $1.date
            }
            return $0.personName < $1.personName
        }
    }


    private func formatDate(_ date: Date) -> String {
        date.formatted(Date.FormatStyle(date: .abbreviated, time: .omitted, timeZone: OrganizationRulebookContext.timeZone))
    }

    /// Paid days on the report: two decimals (`WeeklyReportPayRow.days` is already rounded by the rule).
    nonisolated static func reportDaysText(_ value: Double) -> String {
        String(format: "%.2f", value)
    }

    /// Paid hours on the report ("12.5h").
    nonisolated static func reportHoursText(_ value: Double) -> String {
        // As web (`${round2(hours)}h`): two decimals at most, trailing zeros dropped.
        let hundredths = (value * 100).rounded()
        if hundredths.truncatingRemainder(dividingBy: 100) == 0 { return String(format: "%.0fh", hundredths / 100) }
        if hundredths.truncatingRemainder(dividingBy: 10) == 0 { return String(format: "%.1fh", hundredths / 100) }
        return String(format: "%.2fh", hundredths / 100)
    }

    private func daysText(_ value: Double) -> String { Self.reportDaysText(value) }

    private func hoursText(_ value: Double) -> String { Self.reportHoursText(value) }

    private func formatCurrency(_ value: Double?) -> String {
        guard let value else { return "" }
        return OrgMoney.format(value)
    }

    private func clashTypeLabel(_ type: Warning.WarningType) -> String {
        switch type {
        case .operativeBookingClash: return "Operative booking clash"
        case .managerLocationClash: return "Manager booking clash"
        case .unbookedLabour: return "Unbooked labour"
        case .annualLeave: return "Annual leave"
        case .materialsCutoff: return "Material order not placed"
        default: return type.rawValue
        }
    }

    private func clashExportCells(_ warning: Warning, status: String) -> [String] {
        [
            status,
            warning.severity.rawValue.capitalized,
            warning.clashPersonKind?.bookingClashTitle ?? clashTypeLabel(warning.type),
            warning.occurrenceDate.map(formatDate) ?? "",
            warning.title,
            clashDetail(warning),
            warning.affectedPersonNames,
        ]
    }

    /// RULEBOOK 1.51.0 §7 (Q4d): a clash row's Detail is `weeklyReportClashDetail` — the day and each place with its
    /// times, facts only; never the Warnings screen's message ("Approve if it's intentional…"). Other warnings keep
    /// their message.
    private func clashDetail(_ warning: Warning) -> String {
        let entries = warning.clashEntries
        guard !entries.isEmpty else { return warning.message }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_GB")
        formatter.timeZone = OrganizationRulebookContext.timeZone
        formatter.dateFormat = "d MMM yyyy"
        let dayText = (warning.clashDate ?? warning.occurrenceDate).map { formatter.string(from: $0) } ?? ""
        let places = entries.map { entry -> (label: String, time: String) in
            let site = entry.siteName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return (site.isEmpty ? entry.locationLabel : site, entry.timeLabel)
        }
        return CanonicalBusinessEngine.weeklyReportClashDetail(dayText: dayText, places: places) ?? warning.message
    }
}

private struct TimesheetMoneyExportRow {
    let personName: String
    let title: String
    let jobNumber: String
    let date: Date
    let details: String
    let amount: Double
}

private struct ProjectWorkRow {
    let projectName: String
    let jobNumber: String
    let personName: String
    let tradeDisplay: String
    let tradeSortKey: String
    let role: String
    var hours: Double
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

private struct WeeklyReportShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
