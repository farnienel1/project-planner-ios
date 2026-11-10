//
//  MyProfileFiguresCard.swift
//  Project Planner
//
//  RULEBOOK 1.35.0 §12 "Personal figures": the "Your figures" card on My Profile. Display only — every number is
//  `CanonicalBusinessEngine.myProfileSummary` (`Core/Rulebook+MyProfile.swift`); this view only lays it out.
//

import Combine
import SwiftUI

struct MyProfileFiguresCard: View {
    @EnvironmentObject var firebaseBackend: FirebaseBackend
    @EnvironmentObject var userStore: UserStore
    @EnvironmentObject var operativeStore: OperativeStore
    @EnvironmentObject var holidayStore: HolidayStore
    @EnvironmentObject var taskStore: ProjectTaskStore
    @EnvironmentObject var bookingStore: BookingStore
    @EnvironmentObject var managerScheduleStore: ManagerScheduleStore
    // The screens each figure opens need these too (as web links each row to its page).
    @EnvironmentObject var projectStore: ProjectStore
    @EnvironmentObject var appSettings: AppSettingsStore
    @EnvironmentObject var notificationService: NotificationService
    @EnvironmentObject var smartCache: SmartCacheService

    /// The screen a figure row opens: web `MyProfileFigures.tsx` links Annual leave, My Schedule, Tasks and
    /// My Qualifications; the line manager row opens nothing.
    enum Destination: String, Identifiable, CaseIterable {
        case annualLeave, mySchedule, tasks, qualifications
        var id: String { rawValue }
    }

    @State private var destination: Destination?

    /// The last answer of `myProfileSummary`. Worked out in `.task(id:)` when a store the figures read changes or the
    /// organisation day changes — never in `body`, so a redraw does not re-encode the stores or re-run the script.
    @State private var summary: RulebookMyProfileSummary?
    /// Bumped whenever one of the six stores announces a change.
    @State private var storeRevision = 0
    /// True once the bank holidays the leave figure needs have loaded (or failed): until then a bank holiday inside a
    /// leave record could still count as leave, so no figures are shown.
    @State private var bankHolidaysReady = false

    private var viewer: AppUser? {
        guard let me = userStore.currentUser else { return nil }
        return userStore.organizationUsers.first(where: { $0.id == me.id }) ?? me
    }

    /// RULEBOOK 1.35.0 `myProfileBankHolidayRange`: the region and the calendar years to load (previous leave year too).
    private var bankHolidayKey: String {
        let region = CanonicalBusinessEngine.resolvedBankHolidayRegion(for: firebaseBackend.currentOrganization)?.id ?? "-"
        let years = CanonicalBusinessEngine.leaveBalanceBankHolidayYears(for: viewer).map(String.init).joined(separator: ",")
        return "\(region)|\(years)"
    }

    private func loadBankHolidays() async {
        // Offline the fetch can take a while (20 s per year): after 5 s show the figures with the bank holidays already
        // cached; they are worked out again when the load finishes.
        let waitCap = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            guard !Task.isCancelled, !bankHolidaysReady else { return }
            bankHolidaysReady = true
            storeRevision &+= 1
        }
        defer { waitCap.cancel() }
        if let region = CanonicalBusinessEngine.resolvedBankHolidayRegion(for: firebaseBackend.currentOrganization) {
            await BankHolidayService.shared.ensureLoaded(
                region: region,
                alsoYears: CanonicalBusinessEngine.leaveBalanceBankHolidayYears(for: viewer)
            )
        }
        bankHolidaysReady = true
        storeRevision &+= 1
    }

    private func computeSummary() -> RulebookMyProfileSummary? {
        guard bankHolidaysReady, let viewer else { return nil }
        let input = MyProfileSummaryInput.build(
            user: viewer,
            roster: userStore.organizationUsers,
            operatives: operativeStore.allOperatives,
            managers: operativeStore.allManagers,
            holidays: holidayStore.bookings,
            tasks: taskStore.tasks,
            bookings: bookingStore.bookings,
            managerBookings: managerScheduleStore.managerSiteBookings
        )
        return CanonicalBusinessEngine.myProfileSummary(input)
    }

    /// Changes when a store changed or the organisation day moved on (checked on the next redraw).
    private var recomputeKey: String {
        "\(storeRevision)|\(OrganizationRulebookContext.dayKey(Date()))|\(OrganizationRulebookContext.timeZoneIdentifier)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Zero-height anchor so `.task` runs even before the first answer exists.
            Color.clear.frame(height: 0)
            figures
        }
        .task(id: bankHolidayKey) { await loadBankHolidays() }
        .task(id: recomputeKey) { summary = computeSummary() }
        .onReceive(userStore.objectWillChange) { _ in storeRevision &+= 1 }
        .onReceive(operativeStore.objectWillChange) { _ in storeRevision &+= 1 }
        .onReceive(holidayStore.objectWillChange) { _ in storeRevision &+= 1 }
        .onReceive(taskStore.objectWillChange) { _ in storeRevision &+= 1 }
        .onReceive(bookingStore.objectWillChange) { _ in storeRevision &+= 1 }
        .onReceive(managerScheduleStore.objectWillChange) { _ in storeRevision &+= 1 }
        .sheet(item: $destination) { destinationView($0) }
    }

    /// Each destination with every store it reads, injected explicitly (the card is also shown inside the Home sheet).
    @ViewBuilder
    private func destinationView(_ destination: Destination) -> some View {
        switch destination {
        case .annualLeave:
            HolidayView(showRequests: false, presentedAsSheet: true)
                .environmentObject(holidayStore)
                .environmentObject(userStore)
                .environmentObject(operativeStore)
                .environmentObject(firebaseBackend)
                .environmentObject(notificationService)
                .environmentObject(appSettings)
                .environmentObject(smartCache)
        case .mySchedule:
            MyScheduleView()
                .environmentObject(firebaseBackend)
                .environmentObject(bookingStore)
                .environmentObject(projectStore)
                .environmentObject(operativeStore)
                .environmentObject(userStore)
                .environmentObject(managerScheduleStore)
                .environmentObject(holidayStore)
                .environmentObject(appSettings)
                .environmentObject(notificationService)
                .environmentObject(smartCache)
        case .tasks:
            TasksDetailView()
                .environmentObject(taskStore)
                .environmentObject(projectStore)
                .environmentObject(operativeStore)
                .environmentObject(userStore)
                .environmentObject(holidayStore)
                .environmentObject(notificationService)
                .environmentObject(firebaseBackend)
                .environmentObject(bookingStore)
                .environmentObject(smartCache)
        case .qualifications:
            OperativeQualificationsReadOnlyView()
                .environmentObject(operativeStore)
                .environmentObject(userStore)
                .environmentObject(firebaseBackend)
                .environmentObject(notificationService)
                .environmentObject(smartCache)
        }
    }

    @ViewBuilder
    private var figures: some View {
        if let summary {
            VStack(alignment: .leading, spacing: 0) {
                SettingsHubChrome.sectionTitle("Your figures")
                SettingsHubChrome.card {
                    figureRow("Annual leave this year", leaveValue(summary), leaveDetail(summary), id: "myProfileFigures.leave", opens: .annualLeave)
                    SettingsHubChrome.divider()
                    figureRow(
                        "Hours booked this week",
                        Self.hoursText(summary.hoursThisWeek),
                        "Mon–Sun, unpaid breaks taken off",
                        id: "myProfileFigures.hours",
                        opens: .mySchedule
                    )
                    SettingsHubChrome.divider()
                    figureRow(
                        "Open tasks",
                        "\(summary.openTasks)",
                        "\(summary.overdueTasks) overdue · \(summary.tasksDueThisWeek) due this week",
                        id: "myProfileFigures.tasks",
                        opens: .tasks
                    )
                    SettingsHubChrome.divider()
                    figureRow("Qualifications", qualificationsValue(summary), nil, id: "myProfileFigures.qualifications", opens: .qualifications)
                    SettingsHubChrome.divider()
                    lineManagerRow(summary)
                }
            }
            .accessibilityIdentifier("myProfileFigures.card")
        }
    }

    // MARK: Text (display only)

    static func daysText(_ days: Double) -> String {
        let rounded = (days * 10).rounded() / 10
        let number = rounded == rounded.rounded() ? String(Int(rounded)) : String(format: "%.1f", rounded)
        return "\(number) \(rounded == 1 ? "day" : "days")"
    }

    static func hoursText(_ hours: Double) -> String {
        let rounded = (hours * 100).rounded() / 100
        return rounded == rounded.rounded() ? "\(Int(rounded))h" : "\(rounded)h"
    }

    private func leaveValue(_ summary: RulebookMyProfileSummary) -> String {
        if summary.leave.hasAllowance, let remaining = summary.leave.remaining {
            return "\(Self.daysText(remaining)) left"
        }
        let used = Self.daysText(summary.leave.usedThisYear).replacingOccurrences(of: " days", with: "").replacingOccurrences(of: " day", with: "")
        return "Days taken this leave year: \(used)"
    }

    private func leaveDetail(_ summary: RulebookMyProfileSummary) -> String? {
        guard summary.leave.hasAllowance, summary.leave.pending > 0 else { return nil }
        return "after \(Self.daysText(summary.leave.pending)) awaiting approval"
    }

    private func qualificationsValue(_ summary: RulebookMyProfileSummary) -> String {
        guard summary.qualificationsTotal > 0 else { return "None" }
        var parts: [String] = []
        if summary.qualificationsExpired > 0 { parts.append("\(summary.qualificationsExpired) expired") }
        if summary.qualificationsExpiringSoon > 0 { parts.append("\(summary.qualificationsExpiringSoon) expiring soon") }
        return parts.joined(separator: " · ")
    }

    // MARK: Rows

    private func figureRow(_ title: String, _ value: String, _ detail: String?, id: String, opens: Destination) -> some View {
        Button {
            destination = opens
        } label: {
            figureRowContent(title, value, detail)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier(id)
    }

    private func figureRowContent(_ title: String, _ value: String, _ detail: String?) -> some View {
        HStack(alignment: .top) {
            Text(title)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(Color.primary)
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(value)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.primary)
                    .multilineTextAlignment(.trailing)
                if let detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(Color.secondary)
                        .multilineTextAlignment(.trailing)
                }
            }
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Color.secondary)
                .padding(.top, 3)
                .accessibilityHidden(true)
        }
        .padding(.vertical, 12)
        .contentShape(Rectangle())
    }

    private func lineManagerRow(_ summary: RulebookMyProfileSummary) -> some View {
        HStack(alignment: .top) {
            Text(summary.lineManagers.count > 1 ? "Line managers" : "Line manager")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(Color.primary)
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                if summary.lineManagers.isEmpty {
                    Text(summary.lineManagerLabel)
                        .font(.subheadline.weight(.semibold))
                } else {
                    // Owner Q5: every line manager by name, never "First +N more".
                    ForEach(summary.lineManagers, id: \.id) { manager in
                        Text(manager.name)
                            .font(.subheadline.weight(.semibold))
                    }
                }
            }
            .foregroundStyle(Color.primary)
        }
        .padding(.vertical, 12)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("myProfileFigures.lineManager")
    }
}
