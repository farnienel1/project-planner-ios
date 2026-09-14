//
//  WarningsDetailView.swift
//  Project Planner
//

import SwiftUI

/// Build stamp — change when shipping Warnings open fixes so Home/sheet prove the binary.
enum WarningsBuildStamp {
    static let id = "wfix-ux-3"
    /// Small stamp in pill value / sheet proves the binary. Pill title stays “Warnings”.
    static let homePillTitle = "Warnings"
    static let homePillValueWhenClear = "\(id) · All clear"
    static func homePillValue(activeCount: Int) -> String {
        activeCount == 0 ? homePillValueWhenClear : "\(id) · \(activeCount) active"
    }
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
    @State private var isRefreshingWarnings = false
    @State private var refreshMessage: String?

    var body: some View {
        NavigationStack {
            Group {
                if warningsService.activeWarnings.isEmpty {
                    emptyState
                } else {
                    warningsScroll
                }
            }
            .overlay(alignment: .bottom) {
                if let refreshMessage {
                    Text(refreshMessage)
                        .font(.caption.weight(.medium))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(.ultraThinMaterial, in: Capsule())
                        .padding(.bottom, 16)
                }
            }
            .background(ProjectWorksRevampColors.canvas.ignoresSafeArea())
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
                ToolbarItem(placement: .navigationBarTrailing) {
                    HStack(spacing: 12) {
                        Button {
                            Task { await refreshWarningsTodayOnly() }
                        } label: {
                            if isRefreshingWarnings {
                                ProgressView()
                            } else {
                                Image(systemName: "arrow.clockwise")
                                    .font(.system(size: 17, weight: .medium))
                            }
                        }
                        .disabled(isRefreshingWarnings)
                        .accessibilityLabel("Refresh warnings")
                        if userStore.hasAdminAccess() {
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
            }
            .appChromeNavigationBarSurface()
            .onAppear {
                WarningsRefreshHelper.isWarningsSheetVisible = true
                print(
                    "🔥🔥🔥 DEBUG: WARNINGS_SHEET_APPEARED \(WarningsBuildStamp.id) count=\(warningsService.activeWarnings.count) completed=\(warningsService.hasCompletedLiveDetection) — display only, no scan"
                )
            }
            .onDisappear {
                WarningsRefreshHelper.isWarningsSheetVisible = false
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
            if warningsService.hasCompletedLiveDetection {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 56))
                    .foregroundStyle(ProjectWorksRevampColors.activeGreen)
                Text("No active warnings")
                    .font(.title3.weight(.semibold))
                Text("High: operative booking clashes and unbooked labour. Medium: manager/admin overlaps (tick for weekly report). Low: material orders not placed by 16:00.")
                    .font(.subheadline)
                    .foregroundStyle(ProjectWorksRevampColors.muted)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
            } else {
                Image(systemName: "hourglass")
                    .font(.system(size: 56))
                    .foregroundStyle(ProjectWorksRevampColors.muted)
                Text("Check for warnings")
                    .font(.title3.weight(.semibold))
                Text("Tap Refresh to scan today and tomorrow. Results are saved, so Home and Weekly Report can open instantly from cache.")
                    .font(.subheadline)
                    .foregroundStyle(ProjectWorksRevampColors.muted)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
                Button("Refresh now") {
                    Task { await refreshWarningsTodayOnly() }
                }
                .buttonStyle(.borderedProminent)
                .padding(.top, 4)
            }
            Text(WarningsBuildStamp.id)
                .font(.caption2.weight(.medium))
                .foregroundStyle(ProjectWorksRevampColors.muted)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
            // Never rescan while the sheet is open — hide this row and ask Home to refresh after dismiss.
            warningsService.dismissWarning(warning)
            NotificationCenter.default.post(name: .warningsNeedsHomeRefresh, object: nil)
        }
    }

    private func removeManagerBooking(_ warning: Warning, entry: Warning.ClashTimelineEntry?) {
        guard let entry else { return }
        if let mgrId = entry.managerBookingId,
           let booking = managerScheduleStore.managerSiteBookings.first(where: { $0.id == mgrId }) {
            Task {
                await managerScheduleStore.deleteBooking(booking)
                warningsService.dismissWarning(warning)
                NotificationCenter.default.post(name: .warningsNeedsHomeRefresh, object: nil)
            }
            return
        }
        if let opBooking = bookingStore.bookings.first(where: { $0.id == entry.bookingId }) {
            Task {
                await bookingStore.deleteBooking(opBooking)
                warningsService.dismissWarning(warning)
                NotificationCenter.default.post(name: .warningsNeedsHomeRefresh, object: nil)
            }
        }
    }

    @MainActor
    private func refreshWarningsTodayOnly() async {
        guard !isRefreshingWarnings else { return }
        isRefreshingWarnings = true
        refreshMessage = nil
        defer { isRefreshingWarnings = false }
        print("🔥🔥🔥 DEBUG: WARNINGS_MANUAL_REFRESH_START \(WarningsBuildStamp.id)")
        // Manual path may run even if sheet visible — temporarily clear the sheet gate.
        let did = await WarningsRefreshHelper.refreshSharedWarnings(
            operativeStore: operativeStore,
            bookingStore: bookingStore,
            projectStore: projectStore,
            userStore: userStore,
            managerScheduleStore: managerScheduleStore,
            holidayStore: holidayStore,
            firebaseBackend: firebaseBackend,
            appSettings: appSettings,
            force: true,
            manualUserInitiated: true
        )
        // no sheet-gate dance needed with manualUserInitiated
        refreshMessage = did
            ? "Updated · \(warningsService.activeWarnings.count) active"
            : "Could not refresh yet (still loading). Try again in a few seconds."
        print("🔥🔥🔥 DEBUG: WARNINGS_MANUAL_REFRESH_DONE did=\(did) active=\(warningsService.activeWarnings.count)")
        NotificationCenter.default.post(name: .warningsDidRecompute, object: nil, userInfo: ["count": warningsService.warningCount])
    }
}

/// Sheet/item identity for a calendar day without making `Date` globally Identifiable.
private struct IdentifiableDay: Identifiable, Hashable {
    let date: Date
    var id: TimeInterval { Calendar.current.startOfDay(for: date).timeIntervalSince1970 }

    init(_ date: Date) {
        self.date = Calendar.current.startOfDay(for: date)
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
