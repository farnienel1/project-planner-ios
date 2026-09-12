//
//  WarningsDetailView.swift
//  Project Planner
//

import SwiftUI

/// Build stamp — change when shipping Warnings open fixes so Home/sheet prove the binary.
enum WarningsBuildStamp {
    static let id = "wfix-quiet-4"
    static let homePillTitle = "Warnings · \(id)"
}

struct WarningsDetailView: View {
    @Environment(\.dismiss) private var dismiss
    /// Only the warnings list needs observation. Holding the other stores as `let`
    /// avoids subscribing to ~11 large ObservableObjects (jetsam on Simulator sheet open).
    @ObservedObject var warningsService: WarningsService
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

    @State private var filterChip: WarningsFilterChip = .all
    @State private var openDayDate: IdentifiableDay?
    @State private var openBookLabourDate: IdentifiableDay?
    @State private var warningPendingDismiss: Warning?
    @State private var showingWarningsSettings = false
    @State private var isRefreshing = false

    var body: some View {
        NavigationStack {
            ZStack {
                Color(.systemGroupedBackground).ignoresSafeArea()
                if warningsService.activeWarnings.isEmpty {
                    emptyState
                } else {
                    warningsScroll
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .principal) {
                    VStack(spacing: 1) {
                        Text("Warnings")
                            .font(.headline)
                        Text(WarningsBuildStamp.id)
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                }
                if userStore.hasAdminAccess() {
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
            .overlay(alignment: .top) {
                if isRefreshing {
                    ProgressView()
                        .padding(8)
                        .background(.ultraThinMaterial, in: Capsule())
                        .padding(.top, 8)
                }
            }
            .onAppear {
                print("🔥🔥🔥 DEBUG: WARNINGS_SHEET_APPEARED \(WarningsBuildStamp.id) count=\(warningsService.activeWarnings.count)")
                // Always join a force refresh when empty — helper waits out launch quiet
                // instead of returning count=0 forever (see wfix-quiet-4).
                if warningsService.activeWarnings.isEmpty {
                    Task { @MainActor in
                        try? await Task.sleep(nanoseconds: 350_000_000)
                        guard warningsService.activeWarnings.isEmpty else { return }
                        guard !WarningsRefreshHelper.isWeeklyReportVisible else { return }
                        await refreshWarningsAsync(alreadyShowingSpinner: false)
                    }
                }
            }
            .sheet(isPresented: $showingWarningsSettings) {
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
            .sheet(item: $openDayDate) { day in
                NavigationStack {
                    DailyOverviewView(displayDate: day.date)
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
            .fullScreenCover(item: $openBookLabourDate) { day in
                BookLabourFlowView(bookDate: day.date)
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
            if isRefreshing {
                ProgressView()
                    .padding(.bottom, 4)
                Text("Checking warnings…")
                    .font(.title3.weight(.semibold))
                Text("Finishing detection. This should clear in a few seconds.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
            } else {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 56))
                    .foregroundStyle(.green)
                Text("No active warnings")
                    .font(.title3.weight(.semibold))
                Text("High: operative booking clashes and unbooked labour. Medium: manager/admin overlaps (tick for weekly report). Low: material orders not placed by 16:00.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
                Button("Retry check") {
                    Task { await refreshWarningsAsync(alreadyShowingSpinner: false) }
                }
                .buttonStyle(.borderedProminent)
                .padding(.top, 4)
            }
            Text(WarningsBuildStamp.id)
                .font(.caption2.weight(.medium))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    private var warningsScroll: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                WarningsHeroCard(
                    activeCount: warningsService.warningCount,
                    highCount: warningsService.highCount,
                    mediumCount: warningsService.mediumCount,
                    lowCount: warningsService.lowCount
                )
                WarningsFilterChipsRow(selected: $filterChip, counts: filterCounts)
                ForEach(filteredWarnings) { warning in
                    warningCard(warning)
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 16)
        }
    }

    private var filterCounts: [WarningsFilterChip: Int] {
        let all = warningsService.activeWarnings
        return [
            .all: all.count,
            .clashes: all.filter { $0.type == .operativeBookingClash || $0.type == .managerLocationClash }.count,
            .unbooked: all.filter { $0.type == .unbookedLabour }.count,
            .materials: all.filter { $0.type == .materialsCutoff }.count
        ]
    }

    private var filteredWarnings: [Warning] {
        let sorted = warningsService.warningsSortedByDate()
        switch filterChip {
        case .all: return sorted
        case .clashes:
            return sorted.filter { $0.type == .operativeBookingClash || $0.type == .managerLocationClash }
        case .unbooked:
            return sorted.filter { $0.type == .unbookedLabour }
        case .materials:
            return sorted.filter { $0.type == .materialsCutoff }
        }
    }

    @ViewBuilder
    private func warningCard(_ warning: Warning) -> some View {
        switch warning.type {
        case .operativeBookingClash:
            OperativeClashWarningCard(
                warning: warning,
                onRemoveA: { removeOperativeBooking(warning, bookingId: warning.operativeClash?.bookingAId) },
                onRemoveB: { removeOperativeBooking(warning, bookingId: warning.operativeClash?.bookingBId) },
                onOpenDay: { openDayDate = warning.occurrenceDate.map(IdentifiableDay.init) },
                onRemoveWarning: { requestRemoveWarning(warning) }
            )
        case .managerLocationClash:
            ManagerClashWarningCard(
                warning: warning,
                onRemoveA: { removeManagerBooking(warning, entry: warning.managerClash?.entryA) },
                onRemoveB: { removeManagerBooking(warning, entry: warning.managerClash?.entryB) },
                onApprove: { warningsService.approveWarning(warning) },
                onOpenDay: { openDayDate = warning.occurrenceDate.map(IdentifiableDay.init) },
                onRemoveWarning: { requestRemoveWarning(warning) }
            )
        case .unbookedLabour:
            unbookedCard(warning)
        case .materialsCutoff:
            materialsCard(warning)
        case .qualificationExpiry, .operativeNotVerified:
            legacyCard(warning)
        }
    }

    private func unbookedCard(_ warning: Warning) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(warning.title)
                    .font(.system(size: 14, weight: .medium))
                WarningPriorityBadge(severity: .high)
            }
            Text(warning.message)
                .font(.system(size: 12))
                .foregroundStyle(ProjectWorksRevampColors.muted)
            if let d = warning.unbookedLabour {
                ForEach(Array(d.names.enumerated()), id: \.offset) { _, name in
                    Text("• \(name)")
                        .font(.system(size: 12))
                }
            }
            Button { openDayDate = warning.occurrenceDate.map(IdentifiableDay.init) } label: {
                Text("Open day on Daily Overview")
                    .font(.system(size: 12, weight: .medium))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 9)
            }
            .buttonStyle(.bordered)
            if userStore.hasAdminAccess(), let warningDay = warning.occurrenceDate {
                Button {
                    openBookLabourDate = IdentifiableDay(warningDay)
                } label: {
                    Text("Book labour")
                        .font(.system(size: 12, weight: .semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 9)
                }
                .buttonStyle(.borderedProminent)
            }
            WarningRemoveButton { requestRemoveWarning(warning) }
        }
        .padding(16)
        .background(Color.white)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private func materialsCard(_ warning: Warning) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(warning.title)
                    .font(.system(size: 14, weight: .medium))
                WarningPriorityBadge(severity: .low)
            }
            Text(warning.message)
                .font(.system(size: 12))
                .foregroundStyle(ProjectWorksRevampColors.muted)
            if let m = warning.materialsCutoff {
                Text("\(m.jobNumber) · \(m.siteName)")
                    .font(.system(size: 12, weight: .medium))
            }
            Text("Managers should confirm material lists with site teams.")
                .font(.system(size: 11))
                .foregroundStyle(ProjectWorksRevampColors.muted)
            WarningRemoveButton { requestRemoveWarning(warning) }
        }
        .padding(16)
        .background(Color.white)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private func legacyCard(_ warning: Warning) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(warning.title)
                    .font(.system(size: 14, weight: .medium))
                WarningPriorityBadge(severity: warning.severity)
            }
            Text(warning.message)
                .font(.system(size: 12))
                .foregroundStyle(ProjectWorksRevampColors.muted)
            WarningRemoveButton { requestRemoveWarning(warning) }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
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
        Task {
            await notificationService.notifyWarningRemoved(warning: warning, removedBy: removedBy)
        }
    }

    private func removeOperativeBooking(_ warning: Warning, bookingId: UUID?) {
        guard let id = bookingId,
              let booking = bookingStore.bookings.first(where: { $0.id == id }) else { return }
        Task {
            await bookingStore.deleteBooking(booking)
            refreshWarnings()
        }
    }

    private func removeManagerBooking(_ warning: Warning, entry: Warning.ClashTimelineEntry?) {
        guard let entry else { return }
        if let mgrId = entry.managerBookingId,
           let booking = managerScheduleStore.managerSiteBookings.first(where: { $0.id == mgrId }) {
            Task {
                await managerScheduleStore.deleteBooking(booking)
                refreshWarnings()
            }
            return
        }
        if let opBooking = bookingStore.bookings.first(where: { $0.id == entry.bookingId }) {
            Task {
                await bookingStore.deleteBooking(opBooking)
                refreshWarnings()
            }
        }
    }

    private func refreshWarnings() {
        Task { await refreshWarningsAsync(alreadyShowingSpinner: false) }
    }

    private func refreshWarningsAsync(alreadyShowingSpinner: Bool) async {
        if !alreadyShowingSpinner {
            isRefreshing = true
        }
        defer {
            if !alreadyShowingSpinner {
                isRefreshing = false
            }
        }
        await WarningsRefreshHelper.refreshSharedWarnings(
            operativeStore: operativeStore,
            bookingStore: bookingStore,
            projectStore: projectStore,
            userStore: userStore,
            managerScheduleStore: managerScheduleStore,
            holidayStore: holidayStore,
            firebaseBackend: firebaseBackend,
            appSettings: appSettings,
            force: true
        )
        print(
            "🔥🔥🔥 DEBUG: WARNINGS_SHEET_REFRESHED \(WarningsBuildStamp.id) active=\(warningsService.activeWarnings.count) count=\(warningsService.warningCount)"
        )
    }
}

/// Sheet/item identity for a calendar day without making `Date` globally Identifiable.
/// `nonisolated` + no `Calendar.current` — that API is MainActor-isolated and breaks
/// button / escaping action closures.
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
