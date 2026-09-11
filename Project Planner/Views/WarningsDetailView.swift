//
//  WarningsDetailView.swift
//  Project Planner
//

import SwiftUI

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
    @State private var didScheduleRefresh = false

    var body: some View {
        NavigationStack {
            Group {
                if warningsService.activeWarnings.isEmpty {
                    emptyState
                } else {
                    warningsScroll
                }
            }
            .background(ProjectWorksRevampColors.canvas.ignoresSafeArea())
            .navigationTitle("Warnings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Done") { dismiss() }
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
            .task {
                // Home owns `isWarningsSheetVisible`. Do not compute under this sheet on open —
                // that jetsams Simulator. Prefer shared warnings from Home post-quiet refresh.
                guard !didScheduleRefresh else { return }
                isRefreshing = true
                defer { isRefreshing = false }
                try? await Task.sleep(nanoseconds: 400_000_000)
                guard !Task.isCancelled else { return }

                if !warningsService.activeWarnings.isEmpty {
                    didScheduleRefresh = true
                    print("🔥🔥🔥 DEBUG: WARNINGS_SHEET using existing shared warnings count=\(warningsService.warningCount)")
                    return
                }

                // Wait briefly for Home post-quiet to publish before doing any local work.
                let waitDeadline = Date().addingTimeInterval(35)
                while Date() < waitDeadline {
                    if !warningsService.activeWarnings.isEmpty {
                        didScheduleRefresh = true
                        print("🔥🔥🔥 DEBUG: WARNINGS_SHEET shared warnings arrived count=\(warningsService.warningCount)")
                        return
                    }
                    let quiet = firebaseBackend.launchQuietUntil.map { Date() < $0 } ?? false
                    let hardBusy = bookingStore.isLoading || operativeStore.isLoading || projectStore.isLoading
                    let bootBlocked = firebaseBackend.isBootstrappingOrgDataLoad
                        || !firebaseBackend.hasBootstrappedOrgDataLoad
                        || quiet
                        || hardBusy
                    if !bootBlocked { break }
                    try? await Task.sleep(nanoseconds: 400_000_000)
                    if Task.isCancelled { return }
                }

                if !warningsService.activeWarnings.isEmpty {
                    didScheduleRefresh = true
                    return
                }

                // Still empty after quiet — run one sheet-safe refresh with visibility cleared
                // so we are not stacking a snapshot under the presented sheet chrome.
                let didRun = await refreshWarningsSafelyFromSheet()
                if didRun || !warningsService.activeWarnings.isEmpty {
                    didScheduleRefresh = true
                } else if !Task.isCancelled {
                    print("🔥🔥🔥 DEBUG: WARNINGS_SHEET safe refresh did not publish — retry available")
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
                Text("Checking for warnings…")
                    .font(.title3.weight(.semibold))
                Text("Waiting for schedule data to finish loading.")
                    .font(.subheadline)
                    .foregroundStyle(ProjectWorksRevampColors.muted)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
            } else {
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
                Button("Check again") {
                    didScheduleRefresh = false
                    Task {
                        let didRun = await refreshWarningsSafelyFromSheet()
                        if didRun || !warningsService.activeWarnings.isEmpty {
                            didScheduleRefresh = true
                        }
                    }
                }
                .buttonStyle(.borderedProminent)
                .padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var warningsScroll: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 18) {
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
                let visibleNames = Array(d.names.prefix(40))
                ForEach(Array(visibleNames.enumerated()), id: \.offset) { _, name in
                    Text("• \(name)")
                        .font(.system(size: 12))
                }
                if d.names.count > visibleNames.count {
                    Text("• …and \(d.names.count - visibleNames.count) more")
                        .font(.system(size: 12))
                        .foregroundStyle(ProjectWorksRevampColors.muted)
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
        Task { await refreshWarningsSafelyFromSheet() }
    }

    /// Temporarily clears the sheet-visible flag so one refresh is not stacked under the
    /// presented Warnings chrome (that jetsams Simulator), then restores it.
    @discardableResult
    private func refreshWarningsSafelyFromSheet() async -> Bool {
        isRefreshing = true
        defer { isRefreshing = false }
        WarningsRefreshHelper.isWarningsSheetVisible = false
        defer { WarningsRefreshHelper.isWarningsSheetVisible = true }
        return await refreshAfterLaunchQuietIfNeeded()
    }

    @discardableResult
    private func refreshAfterLaunchQuietIfNeeded() async -> Bool {
        // Wait for launch quiet AND hard stores. Soft stores (holidays / manager schedule)
        // must not block forever — a hung holiday fetch used to leave Warnings empty.
        let deadline = Date().addingTimeInterval(90)
        let softBypassAfter = Date().addingTimeInterval(45)
        while Date() < deadline {
            // Another path (Home post-quiet) may have filled shared warnings while we waited.
            if !warningsService.activeWarnings.isEmpty {
                print("🔥🔥🔥 DEBUG: WARNINGS_SHEET shared warnings arrived while waiting count=\(warningsService.warningCount)")
                return true
            }
            let quiet = firebaseBackend.launchQuietUntil.map { Date() < $0 } ?? false
            let hardBusy = bookingStore.isLoading
                || operativeStore.isLoading
                || projectStore.isLoading
            let softBusy = holidayStore.isLoading || managerScheduleStore.isLoading
            let rosterEmpty = operativeStore.allOperatives.isEmpty && userStore.organizationUsers.isEmpty
            let allowSoftBypass = Date() >= softBypassAfter
            let blocked = firebaseBackend.isBootstrappingOrgDataLoad
                || !firebaseBackend.hasBootstrappedOrgDataLoad
                || quiet
                || hardBusy
                || (softBusy && !allowSoftBypass)
                || (rosterEmpty && !allowSoftBypass)
            if !blocked {
                let didRun = await refreshWarningsAsync(bypassSoftStoreGates: allowSoftBypass || softBusy)
                if didRun { return true }
            } else {
                print("🔥🔥🔥 DEBUG: WARNINGS_SHEET waiting for quiet/stores")
            }
            try? await Task.sleep(nanoseconds: 400_000_000)
            if Task.isCancelled { return false }
        }
        // Final attempt: soft/hard store gates may still be stuck; never bypass quiet/bootstrap.
        if !warningsService.activeWarnings.isEmpty { return true }
        return await refreshWarningsAsync(bypassSoftStoreGates: true, bypassAllStoreGates: true)
    }

    private func refreshWarningsAsync(
        bypassSoftStoreGates: Bool = false,
        bypassAllStoreGates: Bool = false
    ) async -> Bool {
        isRefreshing = true
        defer { isRefreshing = false }
        return await WarningsRefreshHelper.refreshSharedWarnings(
            operativeStore: operativeStore,
            bookingStore: bookingStore,
            projectStore: projectStore,
            userStore: userStore,
            managerScheduleStore: managerScheduleStore,
            holidayStore: holidayStore,
            firebaseBackend: firebaseBackend,
            appSettings: appSettings,
            force: true,
            bypassSoftStoreGates: bypassSoftStoreGates,
            bypassAllStoreGates: bypassAllStoreGates,
            includeMaterialsFetch: false
        )
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
