//
//  WarningsDetailView.swift
//  Project Planner
//
//  Display-only sheet: presents a frozen snapshot so opening never observes
//  WarningsService (or rebuilds heavy clash cards when the shared service publishes).
//

import SwiftUI

/// Value copy of warnings at the moment the sheet is presented.
struct WarningsDisplaySnapshot: Identifiable, Equatable {
    let id: UUID
    let warnings: [Warning]
    let activeCount: Int
    let highCount: Int
    let mediumCount: Int
    let lowCount: Int
    /// False when Home has not finished a detection pass yet — empty list is not "all clear".
    let detectionCompleted: Bool

    init(
        id: UUID = UUID(),
        warnings: [Warning],
        activeCount: Int,
        highCount: Int,
        mediumCount: Int,
        lowCount: Int,
        detectionCompleted: Bool = true
    ) {
        self.id = id
        self.warnings = warnings
        self.activeCount = activeCount
        self.highCount = highCount
        self.mediumCount = mediumCount
        self.lowCount = lowCount
        self.detectionCompleted = detectionCompleted
    }

    @MainActor
    init(from service: WarningsService, detectionCompleted: Bool, id: UUID = UUID()) {
        self.id = id
        self.warnings = service.warningsSortedByDate()
        self.activeCount = service.warningCount
        self.highCount = service.highCount
        self.mediumCount = service.mediumCount
        self.lowCount = service.lowCount
        self.detectionCompleted = detectionCompleted
    }
}

struct WarningsDetailView: View {
    private static let maxVisibleRows = 60
    private static let maxUnbookedNames = 12

    @Environment(\.dismiss) private var dismiss

    let snapshot: WarningsDisplaySnapshot
    /// Used only for dismiss/approve mutations — never observed while the sheet is open.
    let warningsService: WarningsService
    let projectStore: ProjectStore
    let userStore: UserStore
    let operativeStore: OperativeStore
    let bookingStore: BookingStore
    let managerScheduleStore: ManagerScheduleStore
    let firebaseBackend: FirebaseBackend
    let appSettings: AppSettingsStore
    let holidayStore: HolidayStore
    let notificationService: NotificationService
    let subcontractorStore: SubcontractorStore
    let taskStore: ProjectTaskStore

    @State private var displayedWarnings: [Warning]
    @State private var filterChip: WarningsFilterChip = .all
    @State private var openDayDate: IdentifiableDay?
    @State private var openBookLabourDate: IdentifiableDay?
    @State private var warningPendingDismiss: Warning?
    @State private var showingWarningsSettings = false
    @State private var selectedWarning: Warning?
    @State private var canManageAdminActions: Bool

    init(
        snapshot: WarningsDisplaySnapshot,
        warningsService: WarningsService,
        projectStore: ProjectStore,
        userStore: UserStore,
        operativeStore: OperativeStore,
        bookingStore: BookingStore,
        managerScheduleStore: ManagerScheduleStore,
        firebaseBackend: FirebaseBackend,
        appSettings: AppSettingsStore,
        holidayStore: HolidayStore,
        notificationService: NotificationService,
        subcontractorStore: SubcontractorStore,
        taskStore: ProjectTaskStore
    ) {
        self.snapshot = snapshot
        self.warningsService = warningsService
        self.projectStore = projectStore
        self.userStore = userStore
        self.operativeStore = operativeStore
        self.bookingStore = bookingStore
        self.managerScheduleStore = managerScheduleStore
        self.firebaseBackend = firebaseBackend
        self.appSettings = appSettings
        self.holidayStore = holidayStore
        self.notificationService = notificationService
        self.subcontractorStore = subcontractorStore
        self.taskStore = taskStore
        _displayedWarnings = State(initialValue: snapshot.warnings)
        _canManageAdminActions = State(initialValue: userStore.hasAdminAccess())
    }

    var body: some View {
        NavigationStack {
            Group {
                if displayedWarnings.isEmpty {
                    emptyState
                } else {
                    warningsList
                }
            }
            .background(ProjectWorksRevampColors.canvas.ignoresSafeArea())
            .navigationTitle("Warnings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Done") { dismiss() }
                }
                if canManageAdminActions {
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button {
                            showingWarningsSettings = true
                        } label: {
                            Image(systemName: "gearshape")
                                .font(.system(size: 17, weight: .medium))
                        }
                        .accessibilityLabel("Warning settings")
                    }
                }
            }
            .appChromeNavigationBarSurface()
            .sheet(isPresented: $showingWarningsSettings) {
                warningsSettingsSheet
            }
            .sheet(item: $openDayDate) { day in
                dailyOverviewSheet(for: day.date)
            }
            .fullScreenCover(item: $openBookLabourDate) { day in
                bookLabourCover(for: day.date)
            }
            .sheet(item: $selectedWarning) { warning in
                warningActionSheet(warning)
            }
            .alert(
                "Remove this warning?",
                isPresented: Binding(
                    get: { warningPendingDismiss != nil },
                    set: { if !$0 { warningPendingDismiss = nil } }
                ),
                presenting: warningPendingDismiss
            ) { warning in
                Button("Cancel", role: .cancel) {
                    warningPendingDismiss = nil
                }
                Button("Remove warning", role: .destructive) {
                    confirmRemoveWarning(warning)
                }
            } message: { warning in
                Text("Are you sure you want to remove this warning? It will be hidden from the list and other admins will be notified. You may still need to resolve the issue manually.\n\n\(warning.removalNotificationDetail)")
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: snapshot.detectionCompleted ? "checkmark.circle.fill" : "hourglass")
                .font(.system(size: 56))
                .foregroundStyle(snapshot.detectionCompleted
                                 ? ProjectWorksRevampColors.activeGreen
                                 : ProjectWorksRevampColors.muted)
            Text(snapshot.detectionCompleted ? "All clear" : "Still checking…")
                .font(.title3.weight(.semibold))
            Text(snapshot.detectionCompleted
                 ? "High: operative booking clashes and unbooked labour. Medium: manager/admin overlaps (tick for weekly report). Low: material orders not placed by 16:00."
                 : "Warnings are calculated on Home after launch settles. Close this screen, wait a few seconds on Home, then reopen.")
                .font(.subheadline)
                .foregroundStyle(ProjectWorksRevampColors.muted)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
            Button("Close & refresh") {
                NotificationCenter.default.post(name: .warningsNeedsHomeRefresh, object: nil)
                dismiss()
            }
            .buttonStyle(.borderedProminent)
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var warningsList: some View {
        List {
            Section {
                WarningsHeroCard(
                    activeCount: snapshot.activeCount,
                    highCount: snapshot.highCount,
                    mediumCount: snapshot.mediumCount,
                    lowCount: snapshot.lowCount
                )
                .listRowInsets(EdgeInsets(top: 12, leading: 16, bottom: 8, trailing: 16))
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)

                WarningsFilterChipsRow(selected: $filterChip, counts: filterCounts)
                    .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 8, trailing: 16))
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
            }

            Section {
                ForEach(visibleFilteredWarnings) { warning in
                    Button {
                        selectedWarning = warning
                    } label: {
                        warningRow(warning)
                    }
                    .buttonStyle(.plain)
                    .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
                }

                if filteredWarnings.count > Self.maxVisibleRows {
                    Text("Showing first \(Self.maxVisibleRows) of \(filteredWarnings.count). Close & refresh on Home for a full recompute.")
                        .font(.system(size: 12))
                        .foregroundStyle(ProjectWorksRevampColors.muted)
                        .listRowBackground(Color.clear)
                }
            }

            Section {
                Button("Close & refresh") {
                    NotificationCenter.default.post(name: .warningsNeedsHomeRefresh, object: nil)
                    dismiss()
                }
                .frame(maxWidth: .infinity)
                .listRowBackground(Color.clear)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
    }

    private var filterCounts: [WarningsFilterChip: Int] {
        let all = displayedWarnings
        return [
            .all: all.count,
            .clashes: all.filter { $0.type == .operativeBookingClash || $0.type == .managerLocationClash }.count,
            .unbooked: all.filter { $0.type == .unbookedLabour }.count,
            .materials: all.filter { $0.type == .materialsCutoff }.count
        ]
    }

    private var filteredWarnings: [Warning] {
        switch filterChip {
        case .all: return displayedWarnings
        case .clashes:
            return displayedWarnings.filter { $0.type == .operativeBookingClash || $0.type == .managerLocationClash }
        case .unbooked:
            return displayedWarnings.filter { $0.type == .unbookedLabour }
        case .materials:
            return displayedWarnings.filter { $0.type == .materialsCutoff }
        }
    }

    private var visibleFilteredWarnings: [Warning] {
        Array(filteredWarnings.prefix(Self.maxVisibleRows))
    }

    private func warningRow(_ warning: Warning) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(warning.title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(ProjectWorksRevampColors.ink)
                    .multilineTextAlignment(.leading)
                Spacer(minLength: 0)
                WarningPriorityBadge(severity: warning.severity)
            }
            if let date = warning.occurrenceDate {
                Text(date, format: .dateTime.weekday(.abbreviated).day().month(.abbreviated))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(ProjectWorksRevampColors.muted)
            }
            Text(warning.message)
                .font(.system(size: 12))
                .foregroundStyle(ProjectWorksRevampColors.muted)
                .multilineTextAlignment(.leading)
            if warning.type == .unbookedLabour, let names = warning.unbookedLabour?.names {
                let visible = Array(names.prefix(Self.maxUnbookedNames))
                Text(visible.map { "• \($0)" }.joined(separator: "\n"))
                    .font(.system(size: 12))
                    .foregroundStyle(ProjectWorksRevampColors.ink)
                if names.count > visible.count {
                    Text("• …and \(names.count - visible.count) more")
                        .font(.system(size: 12))
                        .foregroundStyle(ProjectWorksRevampColors.muted)
                }
            } else if warning.type == .materialsCutoff, let m = warning.materialsCutoff {
                Text("\(m.jobNumber) · \(m.siteName)")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(ProjectWorksRevampColors.ink)
            }
            Text("Tap for actions")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(ProjectWorksRevampColors.blue)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    @ViewBuilder
    private func warningActionSheet(_ warning: Warning) -> some View {
        NavigationStack {
            List {
                Section {
                    Text(warning.title)
                        .font(.headline)
                    Text(warning.message)
                        .font(.subheadline)
                        .foregroundStyle(ProjectWorksRevampColors.muted)
                }

                if warning.occurrenceDate != nil {
                    Section("Day") {
                        Button("Open day on Daily Overview") {
                            selectedWarning = nil
                            openDayDate = warning.occurrenceDate.map { IdentifiableDay($0) }
                        }
                        if canManageAdminActions, warning.type == .unbookedLabour {
                            Button("Book labour") {
                                selectedWarning = nil
                                if let day = warning.occurrenceDate {
                                    openBookLabourDate = IdentifiableDay(day)
                                }
                            }
                        }
                    }
                }

                if warning.type == .operativeBookingClash || warning.type == .managerLocationClash {
                    Section("Bookings") {
                        Button("Remove first booking", role: .destructive) {
                            selectedWarning = nil
                            if warning.type == .operativeBookingClash {
                                removeOperativeBooking(warning, bookingId: warning.operativeClash?.bookingAId)
                            } else {
                                removeManagerBooking(warning, entry: warning.managerClash?.entryA)
                            }
                        }
                        Button("Remove second booking", role: .destructive) {
                            selectedWarning = nil
                            if warning.type == .operativeBookingClash {
                                removeOperativeBooking(warning, bookingId: warning.operativeClash?.bookingBId)
                            } else {
                                removeManagerBooking(warning, entry: warning.managerClash?.entryB)
                            }
                        }
                    }
                }

                if warning.requiresWeeklyReportApproval {
                    Section {
                        Button("Tick for weekly report") {
                            warningsService.approveWarning(warning)
                            removeFromDisplayed(warning)
                            selectedWarning = nil
                        }
                    }
                }

                Section {
                    Button("Remove warning", role: .destructive) {
                        selectedWarning = nil
                        requestRemoveWarning(warning)
                    }
                }
            }
            .navigationTitle("Warning")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { selectedWarning = nil }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private var warningsSettingsSheet: some View {
        NavigationStack {
            OrganisationWarningsSettingsView(
                exitsToHomeOnBack: true,
                onExitToHome: {
                    showingWarningsSettings = false
                    dismiss()
                },
                onSaved: {
                    showingWarningsSettings = false
                }
            )
            .environmentObject(firebaseBackend)
            .environmentObject(operativeStore)
            .environmentObject(bookingStore)
            .environmentObject(projectStore)
            .environmentObject(userStore)
            .environmentObject(managerScheduleStore)
            .environmentObject(holidayStore)
            .environmentObject(appSettings)
        }
    }

    private func dailyOverviewSheet(for date: Date) -> some View {
        NavigationStack {
            DailyOverviewView(displayDate: date)
                .environmentObject(bookingStore)
                .environmentObject(projectStore)
                .environmentObject(operativeStore)
                .environmentObject(userStore)
                .environmentObject(holidayStore)
                .environmentObject(managerScheduleStore)
                .environmentObject(subcontractorStore)
                .environmentObject(firebaseBackend)
                .environmentObject(appSettings)
                .environmentObject(taskStore)
                .environmentObject(notificationService)
        }
    }

    private func bookLabourCover(for date: Date) -> some View {
        BookLabourFlowView(bookDate: date)
            .environmentObject(appSettings)
            .environmentObject(bookingStore)
            .environmentObject(projectStore)
            .environmentObject(operativeStore)
            .environmentObject(userStore)
            .environmentObject(holidayStore)
            .environmentObject(managerScheduleStore)
            .environmentObject(firebaseBackend)
            .environmentObject(notificationService)
    }

    private func requestRemoveWarning(_ warning: Warning) {
        warningPendingDismiss = warning
    }

    private func confirmRemoveWarning(_ warning: Warning) {
        warningPendingDismiss = nil
        let removedBy = userStore.currentUser?.fullName
            ?? userStore.currentUser?.email
            ?? "An admin"
        warningsService.dismissWarning(warning)
        removeFromDisplayed(warning)
        Task {
            await notificationService.notifyWarningRemoved(warning: warning, removedBy: removedBy)
        }
    }

    private func removeFromDisplayed(_ warning: Warning) {
        displayedWarnings.removeAll { $0.id == warning.id }
    }

    private func removeOperativeBooking(_ warning: Warning, bookingId: UUID?) {
        guard let id = bookingId,
              let booking = bookingStore.bookings.first(where: { $0.id == id }) else { return }
        Task {
            await bookingStore.deleteBooking(booking)
            requestRefreshAfterDismiss()
        }
    }

    private func removeManagerBooking(_ warning: Warning, entry: Warning.ClashTimelineEntry?) {
        guard let entry else { return }
        if let mgrId = entry.managerBookingId,
           let booking = managerScheduleStore.managerSiteBookings.first(where: { $0.id == mgrId }) {
            Task {
                await managerScheduleStore.deleteBooking(booking)
                requestRefreshAfterDismiss()
            }
            return
        }
        if let opBooking = bookingStore.bookings.first(where: { $0.id == entry.bookingId }) {
            Task {
                await bookingStore.deleteBooking(opBooking)
                requestRefreshAfterDismiss()
            }
        }
    }

    private func requestRefreshAfterDismiss() {
        NotificationCenter.default.post(name: .warningsNeedsHomeRefresh, object: nil)
        dismiss()
    }
}

/// Sheet/item identity for a calendar day without making `Date` globally Identifiable.
/// `nonisolated` + no `Calendar.current` — that API is MainActor-isolated and breaks
/// button / escaping action closures (`init(_:)` in a nonisolated context).
private struct IdentifiableDay: Identifiable, Hashable, Sendable {
    let date: Date
    var id: TimeInterval { date.timeIntervalSince1970 }

    /// Warning `occurrenceDate` values are already start-of-day from computation.
    nonisolated init(_ date: Date) {
        self.date = date
    }
}

#Preview {
    WarningsDetailView(
        snapshot: WarningsDisplaySnapshot(
            warnings: [],
            activeCount: 0,
            highCount: 0,
            mediumCount: 0,
            lowCount: 0
        ),
        warningsService: WarningsService(),
        projectStore: ProjectStore(),
        userStore: UserStore(),
        operativeStore: OperativeStore(),
        bookingStore: BookingStore(),
        managerScheduleStore: ManagerScheduleStore(),
        firebaseBackend: FirebaseBackend(),
        appSettings: AppSettingsStore(),
        holidayStore: HolidayStore(),
        notificationService: NotificationService(),
        subcontractorStore: SubcontractorStore(),
        taskStore: ProjectTaskStore()
    )
}
