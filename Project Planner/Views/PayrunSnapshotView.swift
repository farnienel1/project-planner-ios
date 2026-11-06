//
//  PayrunSnapshotView.swift
//  Project Planner
//
//  RULEBOOK 1.33.0 §7 (owner decision 6 Nov "Payrun Snapshot: build it"): Weekly report → Payrun Snapshot (admins only,
//  `canOpenWeeklyReport`). A period picker (current PAYE period, current payment run period, custom range) and one row
//  per person with their Timesheet, Overtime, Expenses and Price work state — the same screen as web
//  `components/weekly-report/PayrunSnapshot.tsx`. Every period, row, label, colour tone and link target comes from
//  `payrunSnapshotPeriods`, `payrunSnapshotCustomPeriod`, `parsePayrunSnapshotSheet` and `payrunSnapshotRows`
//  (`Rulebook+PayrunSnapshot.swift`); this view only draws them. A cell opens the person's timesheet for that pay run,
//  or Users' Overtime / Expenses / Price work for that person and range. Read-only, nothing stored, no export. Online
//  only (it reads once on open).
//

import SwiftUI

struct PayrunSnapshotView: View {
    // `let` stores, as `WeeklyReportView`: this screen must not re-render on every booking publish.
    let firebaseBackend: FirebaseBackend
    let userStore: UserStore
    let bookingStore: BookingStore
    let managerScheduleStore: ManagerScheduleStore
    let projectStore: ProjectStore
    let operativeStore: OperativeStore
    let notificationService: NotificationService

    @State private var kind = "paye"
    @State private var customStart = Date()
    @State private var customEnd = Date()
    @State private var inputs: PayrunSnapshotInputs?
    @State private var loadError: String?
    @State private var rows: [PayrunSnapshotRow] = []
    @State private var opened: PayrunSnapshotLink?
    @State private var didPickDefault = false

    init(
        firebaseBackend: FirebaseBackend,
        userStore: UserStore,
        bookingStore: BookingStore,
        managerScheduleStore: ManagerScheduleStore,
        projectStore: ProjectStore,
        operativeStore: OperativeStore,
        notificationService: NotificationService
    ) {
        self.firebaseBackend = firebaseBackend
        self.userStore = userStore
        self.bookingStore = bookingStore
        self.managerScheduleStore = managerScheduleStore
        self.projectStore = projectStore
        self.operativeStore = operativeStore
        self.notificationService = notificationService
    }

    private var organization: [String: Any] { PayrunSnapshotPeople.organization(firebaseBackend.currentOrganization) }
    private var todayKey: String { OrganizationRulebookContext.dayKey(Date()) }
    private var periods: PayrunSnapshotPeriods {
        CanonicalBusinessEngine.payrunSnapshotPeriods(organization: organization, todayKey: todayKey)
    }

    /// The picked period (`payrunSnapshotCustomPeriod` for the custom range), or nil while it cannot be used.
    private func period(_ periods: PayrunSnapshotPeriods) -> PayrunSnapshotPeriod? {
        switch kind {
        case "paye": return periods.paye
        case "paymentRun": return periods.paymentRun
        default:
            return CanonicalBusinessEngine.payrunSnapshotCustomPeriod(
                start: OrganizationRulebookContext.dayKey(customStart),
                end: OrganizationRulebookContext.dayKey(customEnd)
            )
        }
    }

    var body: some View {
        let periods = self.periods
        let current = period(periods)
        let labels = CanonicalBusinessEngine.payrunSnapshotPeriodLabels
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                PPGroupLabel(text: "Period")
                PPSegmentedPills(
                    items: [
                        PPSegmentItem(id: "paye", title: labels["paye"] ?? "Current PAYE period", isEnabled: periods.paye != nil, accessibilityIdentifier: "payrunSnapshot.period.paye"),
                        PPSegmentItem(id: "paymentRun", title: labels["paymentRun"] ?? "Current payment run period", isEnabled: periods.paymentRun != nil, accessibilityIdentifier: "payrunSnapshot.period.paymentRun"),
                        PPSegmentItem(id: "custom", title: labels["custom"] ?? "Custom range", accessibilityIdentifier: "payrunSnapshot.period.custom"),
                    ],
                    isSelected: { $0 == kind },
                    onSelect: { kind = $0 }
                )
                if kind == "custom" {
                    PPGroupedCard {
                        DatePicker("Start", selection: $customStart, displayedComponents: .date)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .accessibilityIdentifier("payrunSnapshot.custom.start")
                        PPRowDivider()
                        DatePicker("End", selection: $customEnd, in: customStart..., displayedComponents: .date)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .accessibilityIdentifier("payrunSnapshot.custom.end")
                    }
                    .padding(.top, 10)
                }
                Text(periodNote(current, periods: periods))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 10)
                    .accessibilityIdentifier("payrunSnapshot.periodLabel")

                if let loadError {
                    Text(loadError)
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(PPColor.danger)
                        .padding(.top, 12)
                } else if inputs == nil {
                    ProgressView("Loading…")
                        .frame(maxWidth: .infinity)
                        .padding(.top, 24)
                } else if current != nil {
                    PPGroupLabel(text: CanonicalBusinessEngine.payrunSnapshotText("PAYRUN_SNAPSHOT_LABEL", fallback: "Payrun Snapshot"))
                    if rows.isEmpty {
                        Text(CanonicalBusinessEngine.payrunSnapshotText("PAYRUN_SNAPSHOT_EMPTY_MESSAGE", fallback: "Nobody to show for this period."))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    LazyVStack(spacing: 10) {
                        ForEach(rows) { row in
                            PayrunSnapshotRowCard(row: row, columns: CanonicalBusinessEngine.payrunSnapshotColumns) { link in
                                opened = link
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, PPMetrics.screenGutter)
            .padding(.bottom, 24)
        }
        .background(PPColor.page.ignoresSafeArea())
        .navigationTitle(CanonicalBusinessEngine.payrunSnapshotText("PAYRUN_SNAPSHOT_LABEL", fallback: "Payrun Snapshot"))
        .navigationBarTitleDisplayMode(.inline)
        .ppNavyNavigationBar()
        .task { await load() }
        .onChange(of: kind) { _, _ in recompute() }
        .onChange(of: customStart) { _, _ in recompute() }
        .onChange(of: customEnd) { _, _ in recompute() }
        .navigationDestination(item: $opened) { link in
            destination(link)
        }
    }

    private func periodNote(_ period: PayrunSnapshotPeriod?, periods: PayrunSnapshotPeriods) -> String {
        if let period {
            let note = CanonicalBusinessEngine.payrunSnapshotText("PAYRUN_SNAPSHOT_EMPLOYMENT_NOTE", fallback: "")
            return note.isEmpty ? period.label : "\(period.label) · \(note)"
        }
        switch kind {
        case "paye": return periods.payeMessage ?? ""
        case "paymentRun": return periods.paymentRunMessage ?? ""
        default: return CanonicalBusinessEngine.payrunSnapshotText("PAYRUN_SNAPSHOT_CUSTOM_INVALID_MESSAGE", fallback: "Choose a start and end date.")
        }
    }

    // MARK: Load and rows

    /// Reads everything once (web `loadPayrunSnapshotInputs`): every overtime request, review and report, every claim
    /// report, price work and expense item, and the timesheets of everyone on the roster.
    private func load() async {
        if !didPickDefault {
            didPickDefault = true
            let periods = self.periods
            kind = periods.paye != nil ? "paye" : (periods.paymentRun != nil ? "paymentRun" : "custom")
            if let paye = periods.paye,
               let start = OrganizationRulebookContext.date(fromDayKey: paye.start),
               let end = OrganizationRulebookContext.date(fromDayKey: paye.end) {
                customStart = start
                customEnd = end
            }
        }
        loadError = nil
        do {
            let users = userStore.organizationUsers
            let ids = users.flatMap { [$0.id] + $0.formerUserIds }
            async let overtime = firebaseBackend.loadAllOvertimeRecords()
            async let claims = firebaseBackend.loadPayrunSnapshotClaims()
            async let sheets = firebaseBackend.loadPayrunSnapshotSheets(userIds: ids)
            let (overtimeRecords, claimRecords, sheetRows) = try await (overtime, claims, sheets)
            inputs = PayrunSnapshotInputs(
                sheets: sheetRows,
                overtimeRequests: overtimeRecords.requests,
                overtimeReviews: overtimeRecords.reviews,
                overtimeReports: overtimeRecords.reports,
                payeClaimReports: claimRecords.reports,
                priceWork: claimRecords.priceWork,
                expenses: claimRecords.expenses
            )
            recompute()
        } catch {
            loadError = error.localizedDescription.isEmpty ? "The snapshot could not be loaded." : error.localizedDescription
        }
    }

    /// `payrunSnapshotRows` for the picked period, with every booking as overtime inputs (the reports' out-of-date check).
    private func recompute() {
        guard let inputs, let current = period(periods) else {
            rows = []
            return
        }
        let jobs = projectStore.projects + projectStore.smallWorks
        let bookings = OvertimeBookingInputs.withJobs(
            bookingStore.bookings.map { OvertimeBookingInputs.labour($0) }
                + managerScheduleStore.managerSiteBookings.map { OvertimeBookingInputs.managerSite($0) },
            jobs: jobs
        )
        let operatives: [[String: Any]] = operativeStore.allOperatives.map { ["id": $0.documentId, "email": $0.email] as [String: Any] }
        rows = CanonicalBusinessEngine.payrunSnapshotRows(
            roster: PayrunSnapshotPeople.roster(userStore.organizationUsers),
            organization: organization,
            period: current,
            inputs: inputs,
            bookings: bookings,
            operatives: operatives
        )
    }

    // MARK: Where a cell opens

    @ViewBuilder
    private func destination(_ link: PayrunSnapshotLink) -> some View {
        let range = OvertimeDayRange(start: link.start, end: link.end)
        Group {
            switch link.kind {
            case "timesheet":
                let settings = firebaseBackend.currentOrganization?.settings.invoicing ?? .default
                OperativeTimesheetsView(settings: settings, week: week(for: link, settings: settings), initialReviewUserId: link.personId)
            case "overtime":
                OvertimeLinesView(subjectId: link.personId, scope: .review, range: range)
            case "expenses":
                PayeClaimsRangeView(kind: .expense, subjectId: link.personId, scope: .review, range: range)
            default:
                PayeClaimsRangeView(kind: .priceWork, subjectId: link.personId, scope: .review, range: range)
            }
        }
        .environmentObject(firebaseBackend)
        .environmentObject(userStore)
        .environmentObject(bookingStore)
        .environmentObject(operativeStore)
        .environmentObject(projectStore)
        .environmentObject(managerScheduleStore)
        .environmentObject(notificationService)
    }

    /// The pay run a timesheet link names, as the timesheet screens read a stored period.
    private func week(for link: PayrunSnapshotLink, settings: OrganizationInvoicingSettings) -> WeekRange? {
        guard let start = OrganizationRulebookContext.date(fromDayKey: link.start) else { return nil }
        return TimesheetPayrollPolicy.periodMatchingStoredStart(
            start,
            storedEnd: OrganizationRulebookContext.date(fromDayKey: link.end),
            settings: settings
        )
    }
}

/// One person: name, user level and employment type, then the four cells. Look only: the label and tone of each cell
/// are the rulebook's; a cell with a link opens it.
struct PayrunSnapshotRowCard: View {
    let row: PayrunSnapshotRow
    /// `PAYRUN_SNAPSHOT_COLUMNS` (Name, User level, Employment type, Timesheet, Overtime, Expenses, Price work).
    let columns: [String]
    let onOpen: (PayrunSnapshotLink) -> Void

    private func title(_ index: Int, fallback: String) -> String {
        index < columns.count ? columns[index] : fallback
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                PPIconTile(symbol: "person.fill", family: .plan, size: 38)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(row.name)
                            .font(.body.weight(.semibold))
                            .foregroundStyle(.primary)
                        if !row.active {
                            Text("not active")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Text("\(row.levelLabel) · \(row.employmentLabel)")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    if !row.employmentNote.isEmpty {
                        Text(row.employmentNote)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
            }
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
                cell(title(3, fallback: "Timesheet"), row.cells.timesheet, id: "timesheet")
                cell(title(4, fallback: "Overtime"), row.cells.overtime, id: "overtime")
                cell(title(5, fallback: "Expenses"), row.cells.expenses, id: "expenses")
                cell(title(6, fallback: "Price work"), row.cells.priceWork, id: "priceWork")
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(PPColor.card, in: RoundedRectangle(cornerRadius: PPMetrics.cardRadius, style: .continuous))
        .accessibilityIdentifier("payrunSnapshot.row.\(row.personId)")
    }

    private func cell(_ title: String, _ cell: PayrunSnapshotCell, id: String) -> some View {
        let style = PayrunSnapshotCellStyle(tone: cell.tone)
        let content = VStack(alignment: .leading, spacing: 3) {
            Text(title.uppercased())
                .font(.caption2.weight(.semibold))
                .tracking(0.6)
                .foregroundStyle(style.caption)
            HStack(spacing: 4) {
                Text(cell.label)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(style.text)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                if cell.link != nil {
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(style.caption)
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, minHeight: 58, alignment: .topLeading)
        .background(style.fill, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        return Group {
            if let link = cell.link {
                Button { onOpen(link) } label: { content }
                    .buttonStyle(.plain)
            } else {
                content
            }
        }
        .accessibilityIdentifier("payrunSnapshot.cell.\(id)")
    }
}

/// The colours of a cell tone (look only): `good` green, `warn` amber, `blocked` solid red, `neutral` plain.
struct PayrunSnapshotCellStyle {
    let fill: Color
    let text: Color
    let caption: Color

    init(tone: String) {
        switch tone {
        case "good":
            fill = Color.green.opacity(0.14)
            text = Color.green
            caption = Color.green.opacity(0.8)
        case "warn":
            fill = Color.orange.opacity(0.16)
            text = Color.orange
            caption = Color.orange.opacity(0.85)
        case "blocked":
            fill = PPColor.danger
            text = .white
            caption = Color.white.opacity(0.8)
        default:
            fill = PPColor.well
            text = .primary
            caption = .secondary
        }
    }
}
